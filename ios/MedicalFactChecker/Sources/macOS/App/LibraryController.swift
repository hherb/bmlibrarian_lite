#if os(macOS)
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

import AppKit
import BioMedLit
import SystemConfiguration

/// The app's one shared-paper-library session, with its launch and quit:
/// access to the library folder is started at launch and stopped at exit
/// (design §4.1). Its logic is `LibrarySession`'s (BioMedLit, tested there).
@MainActor
enum LibraryController {

    /// The session the Library setting shows and later steps read.
    static let session = LibrarySession(store: AppSettings.shared)

    private static var started = false

    /// This Mac's name for the installation's label, read once.
    /// `SCDynamicStoreCopyComputerName` rather than `Host.current().localizedName`:
    /// `Host.current()` resolves the host's names and addresses, which can
    /// block on DNS (#792); the computer name is a local lookup. Primed off
    /// the main actor at launch; `nil` when the system gives none, and the
    /// label is then the app's name alone.
    nonisolated private static let machineName: String? = SCDynamicStoreCopyComputerName(nil, nil) as String?

    /// Resume the library, re-check it each time the app becomes active
    /// (design §4.6: a drive unplugged or plugged back in meanwhile), and
    /// arrange to stop access when the app quits. Called once from the app's
    /// `init`; a second call does nothing.
    static func startAtLaunch() {
        guard !started else { return }
        started = true
        BMLFullTextService.appLibrary = library
        Task.detached(priority: .utility) { _ = machineName }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { session.stopAccess() }
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            Task { @MainActor in await session.recheck() }
        }
        Task { await session.resumeAtLaunch() }
    }

    /// The library a full-text fetch goes through (design §4.5): a
    /// `LibrarySource` over the held access as this installation, or `nil`
    /// when no access is held, or when bmlib refuses the installation (logged
    /// at error with bmlib's reason). Without one the fetch runs as it does
    /// with no library set.
    static func library() -> (any FullTextLibrary)? {
        guard let access = session.access else { return nil }
        do {
            return try LibrarySource(
                access: access,
                installationID: session.installationID(),
                label: LibraryInstallation.label(machineName: machineName)
            )
        } catch {
            AppLogger.fullText.error(
                "The paper library is not used for this fetch: \(String(describing: error), privacy: .public)"
            )
            return nil
        }
    }

    /// Find `document`'s PDF again in the library when its stored path is
    /// gone (design §4.4: a stored library path is only a hint), and store
    /// the file found. Does nothing for a document with no library PDF, a
    /// file still where it was, or no library held. The disk work runs off
    /// the main actor.
    static func refindPDF(of document: Document) async {
        guard let file = document.libraryPDFReference, let path = document.localPDFFilePath else { return }
        // The common case, the file still there, builds no library
        let gone = await Task.detached(priority: .userInitiated) { !FileManager.default.fileExists(atPath: path) }.value
        guard gone, let library = library() else { return }
        let found = await Task.detached(priority: .userInitiated) { library.path(of: file) }.value
        guard let refound = found else {
            AppLogger.fullText.warning(
                "The PDF at \(path, privacy: .public) is gone and the library holds no \(file.sha256, privacy: .public)"
            )
            return
        }
        // A fetch meanwhile stored another file: that one stands
        guard document.localPDFFilePath == path else { return }
        AppLogger.fullText.info(
            "The library PDF \(file.sha256, privacy: .public) moved from \(path, privacy: .public) to \(refound, privacy: .public)"
        )
        document.storeRefoundLibraryPDF(at: refound)
    }
}
#endif
