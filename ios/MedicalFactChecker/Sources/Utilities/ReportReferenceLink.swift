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

/// Where a tapped reference in an on-screen report points.
///
/// SwiftUI's `Text` hands a tap on a link back only as a URL. The renderer
/// therefore writes what a reference points at into a `docref://` URL, the
/// app's `OpenURLAction` intercepts that scheme and posts
/// `.documentReferenceClicked`, and the report view reads the URL back here to
/// decide which document to open.
///
/// Both halves live in this one type. The URL used to be built by string
/// interpolation in one file and parsed in two others, and the builder encoded
/// its value with `.urlQueryAllowed`, which leaves `&` alone: a citation of
/// `[Smith & Jones, 2016]` looked up `"Smith "` and the tap did nothing.
enum ReportReferenceLink: Equatable {
    /// A reference that names its document: resolved by exact identity match.
    case documentIdentity(String)

    /// A citation with no target: resolved by the author and year in its text.
    case citationText(String)

    /// The scheme the app's `OpenURLAction` intercepts rather than handing to
    /// the system.
    static let scheme = "docref"

    /// The URL's host. Carried for the URL's shape; nothing reads it back.
    private static let host = "lookup"

    /// Query item naming which kind of lookup the value is for.
    private static let kindItemName = "type"

    /// Query item carrying the identity or citation text.
    private static let valueItemName = "value"

    /// ``kindItemName`` value for ``documentIdentity(_:)``.
    private static let identityKind = "id"

    /// ``kindItemName`` value for ``citationText(_:)``.
    private static let citationKind = "ref"

    /// The URL a renderer attaches to the reference's text.
    ///
    /// Built from `URLComponents` query items, which percent-encode whatever
    /// the query syntax would otherwise read — `&`, `=`, `+`, `#`, `%`.
    /// `nil` only if Foundation refuses to assemble the URL at all, in which
    /// case the renderer shows the reference as plain text.
    var url: URL? {
        let (kind, value): (String, String) = switch self {
        case .documentIdentity(let identity): (Self.identityKind, identity)
        case .citationText(let text): (Self.citationKind, text)
        }

        var components = URLComponents()
        components.scheme = Self.scheme
        components.host = Self.host
        components.queryItems = [
            URLQueryItem(name: Self.kindItemName, value: kind),
            URLQueryItem(name: Self.valueItemName, value: value),
        ]
        return components.url
    }

    /// Reads a tapped URL back, or `nil` when it is not a report reference.
    ///
    /// Refuses any other scheme, a lookup kind this build does not know, and a
    /// URL with no value. `URLComponents` decodes the value exactly once.
    ///
    /// - Parameter url: The URL the tap delivered.
    init?(url: URL) {
        guard url.scheme == Self.scheme,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              let value = items.first(where: { $0.name == Self.valueItemName })?.value else {
            return nil
        }

        switch items.first(where: { $0.name == Self.kindItemName })?.value {
        case Self.identityKind: self = .documentIdentity(value)
        case Self.citationKind: self = .citationText(value)
        default: return nil
        }
    }
}
