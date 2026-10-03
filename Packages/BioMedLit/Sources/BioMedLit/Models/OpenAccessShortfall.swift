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

/// Which lookup of the Unpaywall tier could not settle whether an open-access
/// copy exists.
///
/// The raw values are persisted (see ``OpenAccessShortfall/persisted()``) and
/// shared with Android: never rename one.
public enum OpenAccessSource: String, Sendable, CaseIterable {
    /// Unpaywall itself: its answer did not arrive, or could not be read.
    case unpaywall = "unpaywall"

    /// The landing page Unpaywall named in place of a PDF (#464).
    case landingPage = "unpaywall_landing_page"

    /// The source as the reader is told of it, worded to sit mid-sentence.
    ///
    /// Python's `SERVICE_UNPAYWALL` and `SERVICE_UNPAYWALL_LANDING_PAGE`.
    public var serviceName: String {
        switch self {
        case .unpaywall: return "Unpaywall"
        case .landingPage: return "the open-access copy's landing page"
        }
    }
}

/// Why the open-access copy Unpaywall may know of went unassessed (#464, #466).
///
/// Unpaywall, or the landing page it named, could not answer, so the chain
/// ended on a fallback without learning whether a free copy exists. That is
/// not "no open-access copy": the reader is told so (``notice``), and the app
/// keeps it beside the document's full text (``persisted()``). Python records
/// the same event as a `SourceLookupFailure` and words it the same way.
///
/// The contract is `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`.
public struct OpenAccessShortfall: Sendable, Equatable, Hashable {
    /// The stored form's schema version.
    static let schemaVersion: Int64 = 1

    /// The key holding the stored form's schema version.
    private static let keySchemaVersion = "schema_version"

    /// The key naming the lookup that went unsettled.
    private static let keySource = "source"

    /// The key holding why.
    private static let keyFailure = "failure"

    /// Which lookup could not settle it.
    public let source: OpenAccessSource

    /// Why, by kind and status only.
    public let failure: RequestFailure

    /// Create a shortfall.
    ///
    /// - Parameters:
    ///   - source: Which lookup could not settle it.
    ///   - failure: Why.
    public init(source: OpenAccessSource, failure: RequestFailure) {
        self.source = source
        self.failure = failure
    }

    // MARK: - Telling the reader

    /// What the reader is told: which lookup went unsettled, and what that
    /// leaves open about access.
    ///
    /// The verb follows #435 (``RequestFailure/isAnswer``). A lookup that could
    /// not be asked may have missed a free copy, and the reader is told so; one
    /// that answered without serving the copy is no reason to think one exists.
    /// Python's `analysis_failures.unestablished_access_clause`, word for word.
    public var notice: String {
        let named = "\(Self.sentenceStart(source.serviceName)) (\(failure.describe()))"
        if failure.isAnswer {
            return "\(named) did not serve it, so whether this document is open access was not established."
        }
        return """
            \(named) could not be asked, so a freely available copy may exist. \
            Whether this document is open access was not established.
            """
    }

    /// Capitalise a leading "the", as Python's `_sentence_start` does; a name
    /// such as "Unpaywall" keeps its own case.
    ///
    /// - Parameter name: A service name.
    /// - Returns: The name, fit to begin a sentence.
    private static func sentenceStart(_ name: String) -> String {
        let article = "the "
        guard name.hasPrefix(article) else { return name }
        return "The " + name.dropFirst(article.count)
    }

    // MARK: - Stored form

    /// The value a document stores for this shortfall.
    ///
    /// `{"failure":{"kind":…,"status_code":…},"schema_version":1,"source":…}`,
    /// the failure in the shape a search shortfall stores it.
    ///
    /// - Returns: JSON text.
    public func persisted() -> String {
        let object: [String: Any] = [
            Self.keySchemaVersion: Self.schemaVersion,
            Self.keySource: source.rawValue,
            Self.keyFailure: SearchFailureReporting.failureObject(failure),
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            // Every value written here is a string, an integer or null, so this
            // is unreachable. Should it happen, the stored text still reads back
            // as a shortfall (see `restored(fromPersisted:)`), never as none.
            BioMedLitLib.logger?.error(
                "Could not write an open-access shortfall as JSON", category: .fullText
            )
            return ""
        }
        return text
    }

    /// Read back what a document stored, degrading rather than refusing.
    ///
    /// The field is written only when something went unsettled, so every stored
    /// value is some shortfall and none reads as "nothing to say". What cannot
    /// be interpreted, a schema this build does not know included, reads as a
    /// failed request to Unpaywall, the tier every open-access lookup belongs
    /// to. An unknown source reads as Unpaywall too; the failure degrades as a
    /// search shortfall's does (`search_failure_reporting.md`, "Persisted form").
    ///
    /// - Parameter stored: The stored value, untrusted.
    /// - Returns: The shortfall, as specific as the stored value allows.
    public static func restored(fromPersisted stored: String) -> OpenAccessShortfall {
        let uninterpretable = OpenAccessShortfall(source: .unpaywall, failure: .requestFailed)
        guard let fields = SearchFailureReporting.decodedJSON(stored) as? [String: Any],
              SearchFailureReporting.wholeNumber(fields[keySchemaVersion]) == schemaVersion else {
            return uninterpretable
        }
        let source = (fields[keySource] as? String).flatMap(OpenAccessSource.init(rawValue:)) ?? .unpaywall
        return OpenAccessShortfall(
            source: source,
            failure: SearchFailureReporting.restoredFailure(fields[keyFailure])
        )
    }
}
