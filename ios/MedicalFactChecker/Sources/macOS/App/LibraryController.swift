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

/// The app's one shared-paper-library session, with its launch and quit:
/// access to the library folder is started at launch and stopped at exit
/// (design §4.1). Its logic is `LibrarySession`'s (BioMedLit, tested there).
@MainActor
enum LibraryController {

    /// The session the Library setting shows and later steps read.
    static let session = LibrarySession(store: AppSettings.shared)

    private static var started = false

    /// Resume the library and arrange to stop access when the app quits.
    /// Called once from the app's `init`; a second call does nothing.
    static func startAtLaunch() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { session.stopAccess() }
        }
        Task { await session.resumeAtLaunch() }
    }
}
#endif
