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

    /// CORE's extracted text, asked last by DOI with the user's own key (#480, stage C).
    case core = "core"

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
        case .core: return BioMedLitConstants.coreServiceName
        }
    }
}

/// Why a lookup of the open-access chain left the question of a free copy open.
///
/// Python records these as a `SourceLookupFailure`, or a `SourceLookupSkipped`
/// with `LookupSkipReason.NOT_CONFIGURED` or `LookupSkipReason.KEY_REFUSED`.
public enum OpenAccessUnsettledReason: Sendable, Equatable, Hashable {
    /// The lookup was made and did not settle it; why, by kind and status only.
    case failed(RequestFailure)

    /// Unpaywall was never asked: there is no contact email it would accept.
    /// Only ``OpenAccessSource/unpaywall`` is ever skipped so; see
    /// ``OpenAccessShortfall/unpaywallNotConfigured``.
    case notConfigured

    /// CORE was not asked: it refused the key the settings hold, on this fetch
    /// or earlier this session (#498). Only ``OpenAccessSource/core`` is ever
    /// skipped so; see ``OpenAccessShortfall/coreKeyRefused``. Configured, so
    /// it earns no configuration nudge.
    case keyRefused

    /// The reason as the reader is told it, in the sentence's parenthesis
    /// (Python's `RequestFailure.describe()` or `SourceLookupSkipped.describe()`).
    public var described: String {
        switch self {
        case .failed(let failure): return failure.describe()
        case .notConfigured: return OpenAccessShortfall.notConfiguredDescription
        case .keyRefused: return BioMedLitConstants.coreKeyRefusedReason
        }
    }
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
    /// The stored form's schema version for one lookup without an address.
    private static let schemaVersion: Int64 = 1

    /// The stored form's schema version for a list (#480).
    private static let schemaVersionList: Int64 = 2

    /// The key holding the stored form's schema version.
    private static let keySchemaVersion = "schema_version"

    /// The key naming the lookup that went unsettled.
    private static let keySource = "source"

    /// The key holding why, for a lookup that was made.
    private static let keyFailure = "failure"

    /// The key holding why, for a lookup that was not made.
    private static let keySkipped = "skipped"

    /// The key holding the list of entries (schema 2).
    private static let keyEntries = "entries"

    /// The key holding a tried PDF's address.
    private static let keyAddress = "address"

    /// Python's `LookupSkipReason.NOT_CONFIGURED`, as stored.
    private static let skippedNotConfigured = "not_configured"

    /// Python's `LookupSkipReason.KEY_REFUSED`, as stored (#498).
    private static let skippedKeyRefused = "key_refused"

    /// Python's `SourceLookupSkipped.describe()` for that reason.
    fileprivate static let notConfiguredDescription = "not configured"

    /// One lookup, or one PDF a source named, that left the question open.
    public struct Entry: Sendable, Equatable, Hashable {
        /// Which lookup, or whose PDF.
        public let source: OpenAccessSource

        /// Why: a failed lookup, an Unpaywall that was not configured, or
        /// CORE's refused key.
        public let reason: OpenAccessUnsettledReason

        /// The PDF's address, for a PDF a source named (#480); `nil` for a
        /// service's own lookup. Trimmed; blank is `nil`.
        public let address: String?

        /// Create an entry for a lookup or a PDF that was tried and failed.
        ///
        /// - Parameters:
        ///   - source: Which lookup, or whose PDF.
        ///   - failure: Why.
        ///   - address: The PDF's address, if it is a PDF's entry.
        public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil) {
            self.init(source: source, reason: .failed(failure), address: address)
        }

        /// Create an entry from any reason, a skipped lookup's included.
        ///
        /// Kept to this file so that only ``OpenAccessShortfall`` makes a
        /// `.notConfigured` entry, and only for Unpaywall, or a `.keyRefused`
        /// entry, and only for CORE, without an address. The address is
        /// trimmed, and a blank one becomes `nil`, so an entry with an address
        /// is always a tried PDF.
        ///
        /// - Parameters:
        ///   - source: Which lookup, or whose PDF.
        ///   - reason: Why it left the question open.
        ///   - address: The PDF's address, if it is a PDF's entry.
        fileprivate init(source: OpenAccessSource, reason: OpenAccessUnsettledReason, address: String?) {
            let trimmed = address?.trimmingCharacters(in: .whitespacesAndNewlines)
            let kept = (trimmed?.isEmpty ?? true) ? nil : trimmed
            // A skip is a service's own lookup, and only its own service's: any other
            // would be written as one that reads back as another source's (Kotlin's `require`)
            switch reason {
            case .notConfigured:
                precondition(source == .unpaywall && kept == nil, "a not-configured skip is Unpaywall's own lookup")
            case .keyRefused:
                precondition(source == .core && kept == nil, "a refused-key skip is CORE's own lookup")
            case .failed:
                break
            }
            self.source = source
            self.reason = reason
            self.address = kept
        }

        /// The failure, or `nil` for a lookup that was never made.
        public var failure: RequestFailure? {
            if case .failed(let failure) = reason { return failure }
            return nil
        }

        /// Whether it could not be asked (#435), which decides the ending.
        fileprivate var couldNotBeAsked: Bool { failure.map { !$0.isAnswer } ?? true }

        /// Its reason as the reader is told it.
        fileprivate var described: String { reason.described }
    }

    /// What went unsettled, in the order it was met; never empty.
    public let entries: [Entry]

    /// Create a shortfall of one lookup, or one PDF, that failed.
    ///
    /// - Parameters:
    ///   - source: Which lookup, or whose PDF.
    ///   - failure: Why.
    ///   - address: The PDF's address, if it is a PDF's entry.
    public init(source: OpenAccessSource, failure: RequestFailure, address: String? = nil) {
        self.init(entries: [Entry(source: source, failure: failure, address: address)])
    }

    /// Create a shortfall of the given entries, in the order they were met.
    ///
    /// The precondition guards the invariant every reader relies on: a
    /// shortfall always names at least one thing that went unsettled, so
    /// ``notice`` never has nothing to say and the first-entry accessors
    /// (``source``, ``reason``, ``failure``) never index an empty list. The
    /// callers keep it: the public initialiser passes one entry, `appending`
    /// two non-empty lists, and `restored(fromPersisted:)` a non-empty list.
    ///
    /// - Parameter entries: What went unsettled; must not be empty.
    private init(entries: [Entry]) {
        precondition(!entries.isEmpty, "a shortfall names what went unsettled")
        self.entries = entries
    }

    /// Unpaywall, never asked for want of a contact email it would accept.
    public static let unpaywallNotConfigured = OpenAccessShortfall(
        entries: [Entry(source: .unpaywall, reason: .notConfigured, address: nil)]
    )

    /// CORE, not asked because it refused the key the settings hold (#498).
    /// Told as "CORE (the key in the settings was refused) could not be asked";
    /// it keeps the absence unsettled, as any source not asked does.
    public static let coreKeyRefused = OpenAccessShortfall(
        entries: [Entry(source: .core, reason: .keyRefused, address: nil)]
    )

    /// The first entry's source, for callers that log one; decide nothing from
    /// it alone.
    ///
    /// A shortfall may hold several entries (#480); what the reader is told,
    /// and whether a copy may exist, depends on all of them (``entries``).
    public var source: OpenAccessSource { entries[0].source }

    /// The first entry's reason, for callers that log one; decide nothing from
    /// it alone.
    ///
    /// A shortfall may hold several entries (#480); what the reader is told,
    /// and whether a copy may exist, depends on all of them (``entries``).
    public var reason: OpenAccessUnsettledReason { entries[0].reason }

    /// The first entry's failure, for callers that log one; decide nothing from
    /// it alone.
    ///
    /// A shortfall may hold several entries (#480); what the reader is told,
    /// and whether a copy may exist, depends on all of them (``entries``).
    public var failure: RequestFailure? { entries[0].failure }

    /// This shortfall, then `other`'s entries.
    public func appending(_ other: OpenAccessShortfall) -> OpenAccessShortfall {
        OpenAccessShortfall(entries: entries + other.entries)
    }

    /// `next` added after whatever is held: how the chain records each lookup
    /// and each PDF that went unsettled, in the order met.
    public static func adding(_ next: OpenAccessShortfall, to existing: OpenAccessShortfall?) -> OpenAccessShortfall {
        existing?.appending(next) ?? next
    }

    // MARK: - Telling the reader

    /// The open-access chain's sources in the order they are tried (#480).
    static let chainOrder: [OpenAccessSource] = [
        .unpaywall, .landingPage, .pdf, .openAlex, .openAlexPDF, .core,
    ]

    /// Who named a tried PDF.
    private static func namedBy(_ source: OpenAccessSource) -> String {
        switch source {
        case .pdf: return OpenAccessSource.unpaywall.serviceName
        case .openAlexPDF: return OpenAccessSource.openAlex.serviceName
        default: return source.serviceName
        }
    }

    /// How the tried-sources statement begins (the contract's `lead`).
    private static let triedSourcesLead = "Failed to obtain a PDF from the following tried sources: "

    /// The grouped statement's ending when some lookup could not be asked.
    private static let mayExistEnding =
        "so a freely available copy may exist. Whether this document is open access was not established."

    /// The grouped statement's ending when every lookup answered.
    private static let answeredEnding = "so whether this document is open access was not established."

    /// The tried-sources statement's ending when some entry could not be asked.
    private static let triedUnaskedEnding =
        "A freely available copy may exist. Whether this document is open access was not established."

    /// The tried-sources statement's ending when every entry answered.
    private static let triedAnsweredEnding = "Whether this document is open access was not established."

    /// What the reader is told (Python's `unestablished_access_clause`, word
    /// for word): with a tried PDF, every source tried (#480); otherwise each
    /// lookup grouped by its verb (#435). One lookup reads as it always has.
    /// An unconfigured Unpaywall adds the one cause the reader can change.
    public var notice: String {
        withNudge(entries.contains { $0.address != nil } ? triedSourcesStatement : groupedStatement)
    }

    /// Python's `_unsettled`: each service once, by its first failure unless
    /// a later one could not be asked; a skipped service is named only if it
    /// never failed.
    private static func unsettled(
        _ lookups: [Entry]
    ) -> (unasked: [(String, String)], answered: [(String, String)]) {
        var unasked: [(String, String)] = []
        var answered: [(String, String)] = []
        for entry in lookups where entry.failure != nil {
            let name = entry.source.serviceName
            if unasked.contains(where: { $0.0 == name }) { continue }
            if entry.couldNotBeAsked {
                answered.removeAll { $0.0 == name }
                unasked.append((name, entry.described))
            } else if !answered.contains(where: { $0.0 == name }) {
                answered.append((name, entry.described))
            }
        }
        for entry in lookups where entry.failure == nil {
            let name = entry.source.serviceName
            if !answered.contains(where: { $0.0 == name }), !unasked.contains(where: { $0.0 == name }) {
                unasked.append((name, entry.described))
            }
        }
        return (unasked, answered)
    }

    /// Python's `_joined`: "A (x)", "A (x) and B (y)", "A (x), B (y) and C (z)".
    private static func joined(_ named: [(String, String)]) -> String {
        let clauses = named.map { "\($0.0) (\($0.1))" }
        guard let last = clauses.last, clauses.count > 1 else { return clauses.first ?? "" }
        return clauses.dropLast().joined(separator: ", ") + " and " + last
    }

    /// Lookups only: each grouped by the verb it earns.
    private var groupedStatement: String {
        let (unasked, answered) = Self.unsettled(entries)
        var clauses: [String] = []
        if !unasked.isEmpty { clauses.append("\(Self.joined(unasked)) could not be asked") }
        if !answered.isEmpty { clauses.append("\(Self.joined(answered)) did not serve it") }
        let ending = unasked.isEmpty ? Self.answeredEnding : Self.mayExistEnding
        return Self.sentenceStart("\(clauses.joined(separator: ", and ")), \(ending)")
    }

    /// Python's `tried_sources_statement`; identical entries are told once.
    private var triedSourcesStatement: String {
        let lookups = entries.filter { $0.address == nil }
        let (unasked, answered) = Self.unsettled(lookups)
        let reasons = Dictionary(
            (answered + unasked).map { ($0.0, $0.1) }, uniquingKeysWith: { _, last in last }
        )
        var services: [OpenAccessSource] = []
        for entry in lookups.filter({ $0.failure != nil }) + lookups.filter({ $0.failure == nil })
        where !services.contains(entry.source) {
            services.append(entry.source)
        }
        var items: [(rank: Int, position: Int, text: String, unasked: Bool)] = []
        for (position, service) in services.enumerated() {
            let name = service.serviceName
            items.append((
                Self.chainOrder.firstIndex(of: service) ?? -1, position,
                "\(name) (\(reasons[name] ?? ""))", unasked.contains { $0.0 == name }
            ))
        }
        for (offset, entry) in entries.filter({ $0.address != nil }).enumerated() {
            let host = Self.host(of: entry.address ?? "")
            items.append((
                Self.chainOrder.firstIndex(of: entry.source) ?? -1, services.count + offset,
                "\(host), named by \(Self.namedBy(entry.source)) (\(entry.described))",
                entry.couldNotBeAsked
            ))
        }
        items.sort { ($0.rank, $0.position) < ($1.rank, $1.position) }
        let ending = items.contains { $0.unasked } ? Self.triedUnaskedEnding : Self.triedAnsweredEnding
        // Two PDFs on one host refused alike read the same: told once, the
        // first after sorting, as Python's `dict.fromkeys` keeps it.
        var texts: [String] = []
        for item in items where !texts.contains(item.text) { texts.append(item.text) }
        return Self.triedSourcesLead + texts.joined(separator: "; ") + ". " + ending
    }

    /// Python's `configuration_nudge`: only Unpaywall is ever not configured. A
    /// refused CORE key is configured, so it earns none (#498).
    private func withNudge(_ sentence: String) -> String {
        guard entries.contains(where: { $0.reason == .notConfigured }) else { return sentence }
        return "\(sentence) Configuring \(OpenAccessSource.unpaywall.serviceName) "
            + "would add an open-access route this search did not have."
    }

    /// Python's `address_host`: the host, lower-cased and without a port;
    /// else the address trimmed. A scheme-relative `//host/…` names its host,
    /// as in urlsplit; an authority with an unbalanced '[' or ']' has none, as
    /// urlsplit refuses it, while a well-formed `[…]` names the address within.
    ///
    /// - Parameter address: The PDF's address, as the source gave it.
    /// - Returns: The name a tried PDF is told by.
    public static func host(of address: String) -> String {
        let trimmed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        // `scheme://`, or a bare `//` (scheme-relative), as urlsplit reads both.
        guard let start = trimmed.range(
            of: "^(?:[A-Za-z][A-Za-z0-9+.-]*:)?//", options: .regularExpression
        ) else {
            return trimmed
        }
        let rest = trimmed[start.upperBound...]
        var authority = rest[..<(rest.firstIndex { "/?#".contains($0) } ?? rest.endIndex)]
        // urlsplit refuses an authority (user info included) with a '[' and
        // no ']', or a ']' and no '[': such an address has no host.
        if authority.contains("[") != authority.contains("]") { return trimmed }
        if let at = authority.lastIndex(of: "@") { authority = authority[authority.index(after: at)...] }
        var host: Substring
        if authority.hasPrefix("["), let close = authority.firstIndex(of: "]") {
            host = authority[authority.index(after: authority.startIndex)..<close]
        } else if let colon = authority.firstIndex(of: ":") {
            host = authority[..<colon]
        } else {
            host = authority
        }
        return host.isEmpty ? trimmed : host.lowercased()
    }

    /// Python's `not_saved_note` (#480): a PDF served and not saved is ours to
    /// fix, so it is a note of its own, never in the tried-sources list.
    ///
    /// - Parameters:
    ///   - address: The PDF's address.
    ///   - linkKept: Whether the PDF's link is what the reader is given.
    /// - Returns: The sentence and its advice.
    public static func notSavedNote(address: String, linkKept: Bool) -> String {
        let outcome = linkKept ? "only its link is kept" : "it could not be read"
        return "A PDF of this article was found at \(host(of: address)) but could not be saved on this device, "
            + "so \(outcome). Check the free storage space and try again."
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
    /// One lookup without an address keeps schema 1:
    /// `{"failure":{"kind":…,"status_code":…},"schema_version":1,"source":…}`
    /// (for a lookup not made, `"skipped":"not_configured"` or
    /// `"skipped":"key_refused"` in its place).
    /// Anything else is schema 2: `{"entries":[…],"schema_version":2}`, each
    /// entry in the same shape plus the PDF's `address`.
    ///
    /// - Returns: JSON text.
    public func persisted() -> String {
        let object: [String: Any]
        if entries.count == 1, entries[0].address == nil {
            var single = Self.storedEntry(entries[0])
            single[Self.keySchemaVersion] = Self.schemaVersion
            object = single
        } else {
            object = [
                Self.keySchemaVersion: Self.schemaVersionList,
                Self.keyEntries: entries.map(Self.storedEntry),
            ]
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

    /// One entry as stored: its source, address if any, and why.
    private static func storedEntry(_ entry: Entry) -> [String: Any] {
        var object: [String: Any] = [keySource: entry.source.rawValue]
        if let address = entry.address { object[keyAddress] = address }
        switch entry.reason {
        case .failed(let failure): object[keyFailure] = SearchFailureReporting.failureObject(failure)
        case .notConfigured: object[keySkipped] = skippedNotConfigured
        case .keyRefused: object[keySkipped] = skippedKeyRefused
        }
        return object
    }

    /// Read back what a document stored, degrading rather than refusing.
    ///
    /// The field is written only when something went unsettled, so every stored
    /// value is some shortfall and none reads as "nothing to say". What cannot
    /// be interpreted, a schema this build does not know and an `entries` that
    /// is not a non-empty list included, reads as a failed request to
    /// Unpaywall, the tier every open-access lookup belongs to. An unknown
    /// source reads as Unpaywall too; the failure degrades as a search
    /// shortfall's does (`search_failure_reporting.md`, "Persisted form"). A
    /// stored `not_configured` skip is Unpaywall's and a stored `key_refused`
    /// skip CORE's, whatever source it names: only they are skipped so. Any
    /// other skip reads by its failure.
    ///
    /// - Parameter stored: The stored value, untrusted.
    /// - Returns: The shortfall, as specific as the stored value allows.
    public static func restored(fromPersisted stored: String) -> OpenAccessShortfall {
        let uninterpretable = OpenAccessShortfall(source: .unpaywall, failure: .requestFailed)
        guard let fields = SearchFailureReporting.decodedJSON(stored) as? [String: Any] else {
            return uninterpretable
        }
        switch SearchFailureReporting.wholeNumber(fields[keySchemaVersion]) {
        case schemaVersion:
            return OpenAccessShortfall(entries: [restoredEntry(fields)])
        case schemaVersionList:
            guard let stored = fields[keyEntries] as? [Any], !stored.isEmpty else { return uninterpretable }
            return OpenAccessShortfall(entries: stored.map { element in
                guard let object = element as? [String: Any] else {
                    return Entry(source: .unpaywall, failure: .requestFailed)
                }
                return restoredEntry(object)
            })
        default:
            return uninterpretable
        }
    }

    /// One stored entry, as specific as it allows.
    private static func restoredEntry(_ fields: [String: Any]) -> Entry {
        switch fields[keySkipped] as? String {
        case skippedNotConfigured:
            return Entry(source: .unpaywall, reason: .notConfigured, address: nil)
        case skippedKeyRefused:
            return Entry(source: .core, reason: .keyRefused, address: nil)
        default:
            break
        }
        let source = (fields[keySource] as? String).flatMap(OpenAccessSource.init(rawValue:)) ?? .unpaywall
        return Entry(
            source: source,
            failure: SearchFailureReporting.restoredFailure(fields[keyFailure]),
            address: fields[keyAddress] as? String
        )
    }
}
