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

import Foundation

/// What the Library setting shows (design §4.1, §4.6).
public enum LibraryState: Equatable, Sendable {
    /// No folder is set: papers stay in the app's own storage, as before.
    case notChosen
    /// The library is open: its folder's name and path.
    case reachable(folderName: String, path: String)
    /// A folder is set but cannot be reached now; why, for the user.
    case unreachable(reason: String)
}

/// Where the app keeps what the shared paper library needs across launches:
/// the folder's bookmark and this installation's id. The app's settings
/// adopt it; a test holds them in memory.
public protocol LibrarySettingsStore: AnyObject {
    /// The library folder's security-scoped bookmark, or nil for no library.
    var libraryBookmark: Data? { get set }
    /// This installation's id in the library's records, made once
    /// (``LibraryInstallation/newID()``) and kept, also when the library is
    /// changed or dropped: a new id would orphan this installation's records.
    var libraryInstallationID: String? { get set }
}
