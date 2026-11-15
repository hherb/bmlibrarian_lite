// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

#if os(macOS)
import Foundation
import Observation

/// The app's one library session: resumes the library at launch, holds access
/// until the app quits, and carries out the Library setting's *Choose…* and
/// *Stop using this library*. Its `state` is what the setting shows.
///
/// The disk work (bmlib's calls, the bookmark) runs off the main actor; the
/// state changes on it. A resume or re-check never undoes a choice or *Stop
/// using* made while it ran (#792 item 4): its outcome is dropped, and any
/// access it opened stopped.
@MainActor
@Observable
public final class LibrarySession {

    /// What the setting shows.
    public private(set) var state: LibraryState = .notChosen

    /// The open library with access held, or nil.
    public private(set) var access: LibraryAccess?

    /// Why the last *Choose…* failed, shown under the button; nil after a
    /// success.
    public private(set) var lastError: String?

    /// True while a choice or the launch's resume is running: what disables
    /// the Library setting's buttons. A re-check does not count (a missing
    /// volume can be slow to resolve); a choice made during one stands.
    public var isWorking: Bool { running > 0 }

    /// How many choices and launch resumes are running.
    private var running = 0

    /// How many re-checks are running.
    @ObservationIgnored private var rechecking = 0

    /// Bumped by each choice made and each *Stop using*: a resume or re-check
    /// that started under an older one is out of date when it ends.
    @ObservationIgnored private var generation = 0

    @ObservationIgnored private let store: LibrarySettingsStore

    /// How a stored bookmark is reached: ``LibrarySetup/resume(bookmark:sandboxed:)``.
    @ObservationIgnored private let resume: @Sendable (Data) -> LibraryResume

    /// Why a held library's folder is not the library any more, or nil:
    /// ``LibrarySetup/lostReason(of:)``.
    @ObservationIgnored private let recheckFolder: @Sendable (URL) -> String?

    /// A session over `store`, where the bookmark and installation id live.
    public convenience init(store: LibrarySettingsStore) {
        self.init(store: store, resume: { LibrarySetup.resume(bookmark: $0) })
    }

    /// A session with how a bookmark is reached and a held folder re-checked
    /// passed in, so a test can hold either while it acts.
    init(
        store: LibrarySettingsStore,
        resume: @escaping @Sendable (Data) -> LibraryResume,
        recheckFolder: @escaping @Sendable (URL) -> String? = { LibrarySetup.lostReason(of: $0) }
    ) {
        self.store = store
        self.resume = resume
        self.recheckFolder = recheckFolder
    }

    /// This installation's id: the stored one when bmlib accepts it, else a
    /// new one, stored (an id in another form, such as upper case, is made
    /// again).
    public func installationID() -> String {
        if let id = store.libraryInstallationID, LibraryInstallation.isValidID(id) { return id }
        let id = LibraryInstallation.newID()
        store.libraryInstallationID = id
        return id
    }

    /// At launch: reach the stored library, if any. An unreachable one keeps
    /// its bookmark (a drive may be plugged back in) and shows why.
    public func resumeAtLaunch() async {
        running += 1
        defer { running -= 1 }
        await resumeStored()
    }

    /// Reach the stored library, if any; an outcome out of date when it ends
    /// is dropped.
    private func resumeStored() async {
        guard let bookmark = store.libraryBookmark else {
            state = .notChosen
            return
        }
        let startedAt = generation
        let resume = self.resume
        let outcome = await Task.detached { resume(bookmark) }.value
        guard generation == startedAt else {
            if case let .held(access, _) = outcome { access.stop() }
            return
        }
        switch outcome {
        case let .held(access, renewed):
            hold(access)
            if let renewed { store.libraryBookmark = renewed }
        case let .lost(reason):
            state = .unreachable(reason: reason)
        }
    }

    /// Make `url`, a folder the user picked, the library. On failure nothing
    /// changes but `lastError`: the previous library, if any, stays set.
    public func choose(_ url: URL) async {
        _ = installationID()
        running += 1
        defer { running -= 1 }
        let result = await Task.detached { () -> Result<LibraryChoice, Error> in
            Result { try LibrarySetup.choose(url) }
        }.value
        switch result {
        case let .success(choice):
            generation += 1
            access?.stop()
            store.libraryBookmark = choice.bookmark
            hold(choice.access)
            lastError = nil
        case let .failure(error):
            lastError = String(describing: error)
        }
    }

    /// *Stop using this library*: access stops and the bookmark is dropped;
    /// the folder itself is never changed, and the installation id is kept.
    public func stopUsing() {
        generation += 1
        stopAccess()
        store.libraryBookmark = nil
        state = .notChosen
        lastError = nil
    }

    /// When the app becomes active (design §4.6): a held library whose folder
    /// is gone (its drive unplugged) becomes unreachable, its bookmark kept
    /// and access stopped, and is resumed once at once (a drive remounted
    /// elsewhere); an unreachable one is resumed again, as at launch; with
    /// none set nothing happens. Skipped while a choice, the launch's resume
    /// or another re-check runs.
    public func recheck() async {
        guard !isWorking, rechecking == 0 else { return }
        rechecking += 1
        defer { rechecking -= 1 }
        switch state {
        case .notChosen:
            return
        case .unreachable:
            await resumeStored()
        case .reachable:
            guard let held = access else { return }
            let startedAt = generation
            let recheckFolder = self.recheckFolder
            let lost = await Task.detached { recheckFolder(held.folderURL) }.value
            guard generation == startedAt, access === held, let lost else { return }
            stopAccess()
            state = .unreachable(reason: lost)
            await resumeStored()
        }
    }

    /// The library a fetch goes through while the one set cannot be reached:
    /// one that fails with the reason, so a source fetched waits for it
    /// (design §4.6). nil unless the state is unreachable.
    public var unreachableLibrary: UnreachableLibrary? {
        guard case let .unreachable(reason) = state else { return nil }
        return UnreachableLibrary(reason: reason)
    }

    /// Stop access to the folder (at quit), keeping the setting.
    public func stopAccess() {
        access?.stop()
        access = nil
    }

    private func hold(_ new: LibraryAccess) {
        access = new
        state = .reachable(folderName: new.folderName, path: new.folderURL.path)
    }
}
#endif
