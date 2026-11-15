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
import BmlibCore
import Foundation

/// bmlib's own wording for a library error, read by `errorDescription` (the
/// binding's doc asks the app for this conformance; UniFFI 0.32.2 leaves it
/// out).
extension LibraryError: CustomStringConvertible {}

/// An open library folder with access to it started: what the app holds from
/// launch (or a choice) until it quits or the user stops using the library.
///
/// No BmlibCore type is public here (the rule of `BmlibJATSAdapter`): the app
/// sees the folder, and the library calls of later steps go through BioMedLit.
public final class LibraryAccess: @unchecked Sendable {

    /// The folder, as resolved (its current path).
    public let folderURL: URL

    /// The folder's name, as the setting shows it.
    public var folderName: String { folderURL.lastPathComponent }

    /// bmlib's library at `folderURL`. Every call does disk I/O on the calling
    /// thread, so call it off the main thread.
    let library: PaperLibrary

    /// Whether `stopAccessingSecurityScopedResource` is still owed.
    private var accessStarted: Bool
    private let lock = NSLock()

    init(folderURL: URL, library: PaperLibrary, accessStarted: Bool) {
        self.folderURL = folderURL
        self.library = library
        self.accessStarted = accessStarted
    }

    /// Stop access to the folder, once; later calls do nothing.
    public func stop() {
        lock.lock()
        defer { lock.unlock() }
        if accessStarted {
            folderURL.stopAccessingSecurityScopedResource()
            accessStarted = false
        }
    }

    deinit { stop() }
}

/// A folder made (or found to be) a library, with its bookmark to store.
public struct LibraryChoice: Sendable {
    /// Access to the folder, started.
    public let access: LibraryAccess
    /// The bookmark the app stores to reach the folder after a relaunch.
    public let bookmark: Data
}

/// What a launch found through the stored bookmark.
public enum LibraryResume: Sendable {
    /// The library is open and access is held. `renewedBookmark` is the
    /// bookmark made again from where the folder is now, which covers a stale
    /// bookmark and a moved folder; the caller stores it. It is nil only when
    /// making it again failed (logged; the old bookmark still works).
    case held(LibraryAccess, renewedBookmark: Data?)
    /// The library cannot be reached; `reason` says why, for the user. The
    /// caller keeps the bookmark: a drive may be plugged back in.
    case lost(reason: String)
}

/// Why a folder could not be made the library: a sentence for the user, the
/// folder named.
public struct LibrarySetupError: Error, CustomStringConvertible {
    public let description: String
}

/// Choosing a library folder and reaching it again at launch (design §4.1,
/// §4.6), with StudyAnalyzer's rules (`library_setting.rs`): a folder in the
/// Trash is refused, a moved folder is followed, a stale bookmark is made
/// again, and a failed start of access is lost only in a sandbox.
public enum LibrarySetup {

    /// Whether this process is sandboxed, so that reaching a chosen folder
    /// needs the bookmark's grant.
    public static var isSandboxed: Bool {
        ProcessInfo.processInfo.environment[BioMedLitConstants.sandboxContainerEnvironmentKey] != nil
    }

    /// Make `url`, a folder the user just picked, the library: bmlib creates
    /// it in an empty folder and refuses one holding other files. Call it off
    /// the main thread.
    ///
    /// - Throws: `LibrarySetupError` when the folder is in the Trash, is not a
    ///   library and not empty, cannot be written, or cannot be bookmarked.
    ///   Access is stopped again before it throws.
    public static func choose(_ url: URL) throws -> LibraryChoice {
        try choose(url, startAccess: { $0.startAccessingSecurityScopedResource() })
    }

    /// ``choose(_:)`` with how access is started passed in, so a test can make
    /// the start fail. A start that does not happen is not a refusal here: the
    /// folder panel's grant already reaches the folder (StudyAnalyzer's choose
    /// allows it too); `started` only says whether a stop is owed.
    static func choose(_ url: URL, startAccess: (URL) -> Bool) throws -> LibraryChoice {
        let name = url.lastPathComponent
        if isInTrash(url) {
            log(.warning, "\(url.path) is in the Trash; it is not made the library")
            throw LibrarySetupError(description:
                "“\(name)” is in the Trash, and emptying the Trash would delete the library. Choose another folder.")
        }
        let started = startAccess(url)
        if !started { log(.info, "access to \(url.path) was not started; the panel's grant is used") }
        let stopIfStarted = { if started { url.stopAccessingSecurityScopedResource() } }
        let library: PaperLibrary
        do {
            library = try PaperLibrary.open(root: url.path)
        } catch {
            stopIfStarted()
            log(.warning, "\(url.path) was not made the library: \(error)")
            throw LibrarySetupError(description: "“\(name)” cannot be the library: \(error)")
        }
        let bookmark: Data
        do {
            bookmark = try LibraryBookmark.make(for: url)
        } catch {
            stopIfStarted()
            log(.error, "no bookmark of \(url.path): \(error)")
            throw LibrarySetupError(description:
                "“\(name)” could not be remembered for the next launch: \(error.localizedDescription)")
        }
        log(.info, "the library is \(url.path)")
        return LibraryChoice(
            access: LibraryAccess(folderURL: url, library: library, accessStarted: started),
            bookmark: bookmark)
    }

    /// At launch: reach the library through its stored bookmark. Never
    /// throws; what went wrong is the `.lost` reason. Call it off the main
    /// thread.
    public static func resume(bookmark: Data, sandboxed: Bool = LibrarySetup.isSandboxed) -> LibraryResume {
        let resolved: ResolvedBookmark
        do {
            resolved = try LibraryBookmark.resolve(bookmark)
        } catch {
            log(.warning, "the library's bookmark did not resolve: \(error)")
            return .lost(reason: "the folder could not be found (\(error.localizedDescription))")
        }
        let url = resolved.url
        if isInTrash(url) {
            log(.warning, "the library \(url.path) is in the Trash")
            return .lost(reason: "the folder is in the Trash; put it back, or choose another folder")
        }
        let started = url.startAccessingSecurityScopedResource()
        if accessRefused(started: started, sandboxed: sandboxed) {
            log(.warning, "access to the library \(url.path) was not started")
            return .lost(reason: "macOS did not grant access to the folder; choose it again")
        }
        if let reason = lostReason(of: url) {
            if started { url.stopAccessingSecurityScopedResource() }
            return .lost(reason: reason)
        }
        let library: PaperLibrary
        do {
            library = try PaperLibrary.open(root: url.path)
        } catch {
            if started { url.stopAccessingSecurityScopedResource() }
            log(.warning, "the library \(url.path) did not open: \(error)")
            return .lost(reason: String(describing: error))
        }
        if resolved.isStale { log(.info, "the library's bookmark was stale; making it again") }
        var renewed: Data?
        do {
            renewed = try LibraryBookmark.make(for: url)
        } catch {
            log(.error, "the library's bookmark was not made again: \(error)")
        }
        return .held(
            LibraryAccess(folderURL: url, library: library, accessStarted: started),
            renewedBookmark: renewed)
    }

    /// Why the library at `url`, a folder this process can reach, is not
    /// there any more (logged at warning), or nil when it is. A bookmark is
    /// stored only after bmlib made or found the library, so a folder without
    /// its marker is not the library any more (deleted and made again empty,
    /// say; or its drive unplugged): opening it would make a new, empty
    /// library. Disk I/O: call it off the main thread.
    public static func lostReason(of url: URL) -> String? {
        let marker = url.appendingPathComponent(BioMedLitConstants.libraryMarkerFileName)
        guard !FileManager.default.fileExists(atPath: marker.path) else { return nil }
        log(.warning, "\(url.path) no longer holds the paper library")
        return "the folder no longer holds the paper library (is its drive unplugged?)"
    }

    /// Whether a failed start of access means the folder cannot be used: only
    /// in a sandbox, which needs the grant. Unsandboxed it is harmless.
    static func accessRefused(started: Bool, sandboxed: Bool) -> Bool {
        !started && sandboxed
    }

    /// Whether `url` is in a Trash: the home Trash (`.Trash`) or a volume's
    /// (`.Trashes/<uid>`, where Finder moves items trashed on an external
    /// drive), told by a whole path component after resolving links, as
    /// StudyAnalyzer's `in_trash` does.
    static func isInTrash(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL.pathComponents
            .contains { BioMedLitConstants.trashFolderNames.contains($0) }
    }

    private enum Level { case info, warning, error }

    private static func log(_ level: Level, _ message: String) {
        guard let logger = BioMedLitLib.logger else { return }
        switch level {
        case .info: logger.info(message, category: .library)
        case .warning: logger.warning(message, category: .library)
        case .error: logger.error(message, category: .library)
        }
    }
}
#endif
