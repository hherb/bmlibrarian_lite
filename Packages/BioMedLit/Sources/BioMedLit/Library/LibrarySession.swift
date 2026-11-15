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
/// state changes on it.
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

    /// True while a choice or a launch's resume is running.
    public private(set) var isWorking = false

    @ObservationIgnored private let store: LibrarySettingsStore

    /// A session over `store`, where the bookmark and installation id live.
    public init(store: LibrarySettingsStore) {
        self.store = store
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
        guard let bookmark = store.libraryBookmark else {
            state = .notChosen
            return
        }
        isWorking = true
        defer { isWorking = false }
        let outcome = await Task.detached { LibrarySetup.resume(bookmark: bookmark) }.value
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
        isWorking = true
        defer { isWorking = false }
        let result = await Task.detached { () -> Result<LibraryChoice, Error> in
            Result { try LibrarySetup.choose(url) }
        }.value
        switch result {
        case let .success(choice):
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
        stopAccess()
        store.libraryBookmark = nil
        state = .notChosen
        lastError = nil
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
