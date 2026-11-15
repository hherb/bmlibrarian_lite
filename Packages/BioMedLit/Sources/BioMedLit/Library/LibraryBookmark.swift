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

/// Where a bookmark led, and whether it should be made again.
public struct ResolvedBookmark {
    /// The folder the bookmark resolved to (its current path, after a move or
    /// a rename).
    public let url: URL
    /// True when macOS says the bookmark is out of date (as after a volume
    /// was remounted); it should be made again from `url`.
    public let isStale: Bool
}

/// A security-scoped bookmark of the library folder, which a sandboxed app
/// needs to reach a folder the user chose once it relaunches (design §4.1;
/// entitlement `com.apple.security.files.bookmarks.app-scope`). The same
/// options as StudyAnalyzer's `bookmark.rs`.
public enum LibraryBookmark {

    /// A security-scoped bookmark of `url`, a folder this process can reach
    /// now (one the user just chose, or one resolved from a bookmark).
    ///
    /// - Throws: Foundation's error when the bookmark cannot be made.
    public static func make(for url: URL) throws -> Data {
        try url.bookmarkData(
            options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    /// Resolve `data` without showing any UI. Access is not started here; the
    /// caller starts it on the returned URL.
    ///
    /// - Throws: Foundation's error when the bookmark does not resolve (the
    ///   folder was deleted, its volume is not mounted, the data is not a
    ///   bookmark).
    public static func resolve(_ data: Data) throws -> ResolvedBookmark {
        var stale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI],
            relativeTo: nil, bookmarkDataIsStale: &stale)
        return ResolvedBookmark(url: url, isStale: stale)
    }
}
#endif
