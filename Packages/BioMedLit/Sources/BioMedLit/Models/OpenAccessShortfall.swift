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
    /// Unpaywall itself: it was not asked, its answer did not arrive or could
    /// not be read, or it answered with an error status other than 404.
    case unpaywall = "unpaywall"

    /// The landing page Unpaywall named in place of a PDF (#464).
    case landingPage = "unpaywall_landing_page"

    /// The PDF Unpaywall named, its `url_for_pdf` or the one its landing page
    /// declares, when it could not be obtained: an address the tier cannot
    /// fetch, a download that failed, or a body that is not a PDF (#478).
    /// Unpaywall answered; the copy it pointed at went unassessed.
    case pdf = "unpaywall_pdf"

    /// OpenAlex's record of the work, asked for the PDFs Unpaywall did not
    /// name (#480, stage B).
    case openAlex = "openalex"

    /// A PDF OpenAlex named that could not be obtained: OpenAlex answered, the
    /// copy went unassessed (#478's rule).
    case openAlexPDF = "openalex_pdf"

    /// The source as the reader is told of it, worded to sit mid-sentence.
    ///
    /// Python's `SERVICE_UNPAYWALL`, `SERVICE_UNPAYWALL_LANDING_PAGE` and
    /// `SERVICE_UNPAYWALL_PDF`, `SERVICE_OPENALEX` and `SERVICE_OPENALEX_PDF`.
    public var serviceName: String {
        switch self {
        case .unpaywall: return "Unpaywall"
        case .landingPage: return "the open-access copy's landing page"
        case .pdf: return "the open-access copy's PDF"
        case .openAlex: return "OpenAlex"
        case .openAlexPDF: return "OpenAlex's copy"
        }
    }
}

/// Why a lookup of the Unpaywall tier left the question of a free copy open.
///
/// Python records the two as a `SourceLookupFailure` and a `SourceLookupSkipped`
/// with `LookupSkipReason.NOT_CONFIGURED`.
public enum OpenAccessUnsettledReason: Sendable, Equatable, Hashable {
    /// The lookup was made and did not settle it; why, by kind and status only.
    case failed(RequestFailure)

    /// Unpaywall was never asked: there is no contact email it would accept.
    /// Only ``OpenAccessSource/unpaywall`` is ever skipped so; see
    /// ``OpenAccessShortfall/unpaywallNotConfigured``.
    case notConfigured
}

/// Why the open-access copy Unpaywall may know of went unassessed (#464, #466).
///
/// Unpaywall, the landing page it named, or the PDF it named (#478) could not settle whether a free
/// copy exists, so the chain ended on a fallback without learning it. That is
/// not "no open-access copy": the reader is told so (``notice``), and the app
/// keeps it beside the document's full text (``persisted()``). Python records
/// the same event as a `SourceLookupFailure` (or, for an Unpaywall with no
/// usable email, a `SourceLookupSkipped`) and words it the same way.
///
/// The contract is `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`.
public struct OpenAccessShortfall: Sendable, Equatable, Hashable {
    /// The stored form's schema version.
    private static let schemaVersion: Int64 = 1

    /// The key holding the stored form's schema version.
    private static let keySchemaVersion = "schema_version"

    /// The key naming the lookup that went unsettled.
    private static let keySource = "source"

    /// The key holding why, for a lookup that was made.
    private static let keyFailure = "failure"

    /// The key holding why, for a lookup that was not made.
    private static let keySkipped = "skipped"

    /// Python's `LookupSkipReason.NOT_CONFIGURED`, as stored.
    private static let skippedNotConfigured = "not_configured"

    /// Python's `SourceLookupSkipped.describe()` for that reason.
    private static let notConfiguredDescription = "not configured"

    /// Unpaywall, never asked for want of a contact email it would accept.
    public static let unpaywallNotConfigured = OpenAccessShortfall(
        source: .unpaywall, reason: .notConfigured
    )

    /// Which lookup could not settle it.
    public let source: OpenAccessSource

    /// Why: a failed lookup, or an Unpaywall that was not configured.
    public let reason: OpenAccessUnsettledReason

    /// The failure, or `nil` for a lookup that was never made.
    public var failure: RequestFailure? {
        if case .failed(let failure) = reason { return failure }
        return nil
    }

    /// Create a shortfall for a lookup that was made and failed.
    ///
    /// - Parameters:
    ///   - source: Which lookup could not settle it.
    ///   - failure: Why.
    public init(source: OpenAccessSource, failure: RequestFailure) {
        self.init(source: source, reason: .failed(failure))
    }

    /// Create a shortfall from its parts; ``unpaywallNotConfigured`` is the only
    /// skip, so this stays private.
    ///
    /// - Parameters:
    ///   - source: Which lookup could not settle it.
    ///   - reason: Why.
    private init(source: OpenAccessSource, reason: OpenAccessUnsettledReason) {
        self.source = source
        self.reason = reason
    }

    // MARK: - Telling the reader

    /// What the reader is told: which lookup went unsettled, and what that
    /// leaves open about access.
    ///
    /// The verb follows #435 (``RequestFailure/isAnswer``). A lookup that could
    /// not be asked may have missed a free copy, and the reader is told so; one
    /// that answered without serving the copy is no reason to think one exists.
    /// An Unpaywall that was not configured could not be asked, and the reader
    /// is also told that configuring it would help, the one cause they can
    /// change. Python's `analysis_failures.unestablished_access_clause`, word
    /// for word.
    public var notice: String {
        let name = Self.sentenceStart(source.serviceName)
        let mayExist = """
            could not be asked, so a freely available copy may exist. \
            Whether this document is open access was not established.
            """
        switch reason {
        case .failed(let failure):
            let named = "\(name) (\(failure.describe()))"
            if failure.isAnswer {
                return "\(named) did not serve it, so whether this document is open access was not established."
            }
            return "\(named) \(mayExist)"
        case .notConfigured:
            return """
                \(name) (\(Self.notConfiguredDescription)) \(mayExist) \
                Configuring \(source.serviceName) would add an open-access route this search did not have.
                """
        }
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
    /// the failure in the shape a search shortfall stores it; for a lookup that
    /// was not configured, `{"schema_version":1,"skipped":"not_configured","source":"unpaywall"}`.
    ///
    /// - Returns: JSON text.
    public func persisted() -> String {
        var object: [String: Any] = [
            Self.keySchemaVersion: Self.schemaVersion,
            Self.keySource: source.rawValue,
        ]
        switch reason {
        case .failed(let failure):
            object[Self.keyFailure] = SearchFailureReporting.failureObject(failure)
        case .notConfigured:
            object[Self.keySkipped] = Self.skippedNotConfigured
        }
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
    /// A stored skip is Unpaywall's, whatever source it names: only Unpaywall is
    /// skipped.
    ///
    /// - Parameter stored: The stored value, untrusted.
    /// - Returns: The shortfall, as specific as the stored value allows.
    public static func restored(fromPersisted stored: String) -> OpenAccessShortfall {
        let uninterpretable = OpenAccessShortfall(source: .unpaywall, failure: .requestFailed)
        guard let fields = SearchFailureReporting.decodedJSON(stored) as? [String: Any],
              SearchFailureReporting.wholeNumber(fields[keySchemaVersion]) == schemaVersion else {
            return uninterpretable
        }
        if fields[keySkipped] as? String == skippedNotConfigured {
            return unpaywallNotConfigured
        }
        let source = (fields[keySource] as? String).flatMap(OpenAccessSource.init(rawValue:)) ?? .unpaywall
        return OpenAccessShortfall(
            source: source,
            failure: SearchFailureReporting.restoredFailure(fields[keyFailure])
        )
    }
}
