// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// A stored record of what a search was missing that cannot be read (#256).
///
/// Refused rather than skipped: a dropped shortfall would let a report claim a
/// complete search. The reason names the shape that was wrong and never quotes
/// the stored value.
public struct DamagedShortfallRecordError: LocalizedError, Sendable, Equatable {
    /// What was wrong with the stored value.
    public let reason: String

    /// Record a stored value that could not be read.
    ///
    /// - Parameter reason: What was wrong with its shape.
    public init(reason: String) {
        self.reason = reason
    }

    public var errorDescription: String? { reason }
}

/// A failed source is not an empty one (#256, the Swift half of #247).
///
/// Pure functions that carry a search failure to the reader: they combine the
/// ``RetrievalShortfall``s a search records, turn them into the notice, the
/// Methodology line, the warning and the failure message the user sees, and
/// keep them in a session. The sentences are the contract's
/// (`doc/cross_platform/search_failure_reporting.md`), shared verbatim with
/// Python's `search_failures.py` and Android's `SearchFailureReporting`;
/// Python runs no alternative queries, so it writes none of their clauses.
public enum SearchFailureReporting {
    // MARK: - Persisted keys

    /// The key naming the source that failed.
    private static let keyProvider = "provider"

    /// The key holding why it failed.
    private static let keyFailure = "failure"

    /// The key naming the kind of failure.
    private static let keyKind = "kind"

    /// The key holding the failure's HTTP status.
    private static let keyStatusCode = "status_code"

    /// The key holding how many records are missing.
    private static let keyRecordsMissing = "records_missing"

    /// The key naming which query the shortfall belongs to.
    private static let keyQuery = "query"

    // MARK: - Combining

    /// Report the same failure of the same source once, its counts added.
    ///
    /// A session that meets one failure page after page, or alternative query
    /// after alternative query, would otherwise repeat one clause each time.
    ///
    /// - Parameter shortfalls: What a search is missing, in the order it was recorded.
    /// - Returns: The shortfalls in first-seen order. Those naming the same
    ///   source, failure and query have their counts added, unless the sum is
    ///   more than a count holds: then they stay apart, so no count is cut
    ///   short. A source that could not be searched at all (no count) is never
    ///   merged into a count, and is reported once for each failure and query
    ///   however often it failed.
    public static func combined(_ shortfalls: [RetrievalShortfall]) -> [RetrievalShortfall] {
        var combined: [RetrievalShortfall] = []
        for shortfall in shortfalls {
            let index = combined.firstIndex { earlier in
                earlier.source == shortfall.source
                    && earlier.failure == shortfall.failure
                    && earlier.query == shortfall.query
                    && countsCombine(earlier.recordsMissing, shortfall.recordsMissing)
            }
            guard let index else {
                combined.append(shortfall)
                continue
            }
            // A source that could not be searched is already reported
            guard let earlierMissing = combined[index].recordsMissing,
                  let laterMissing = shortfall.recordsMissing else { continue }
            combined[index] = combined[index].missing(earlierMissing + laterMissing)
        }
        return combined
    }

    /// Whether two shortfalls of the same source, failure and query read as one clause.
    ///
    /// - Parameters:
    ///   - earlier: The count already reported, or `nil` for a source not searched.
    ///   - later: The count to report, or `nil` for a source not searched.
    /// - Returns: `true` for two sources not searched, or two counts whose sum a
    ///   count can hold; `false` when one has a count and the other has none.
    private static func countsCombine(_ earlier: Int?, _ later: Int?) -> Bool {
        guard let earlier, let later else { return earlier == nil && later == nil }
        let (_, overflowed) = earlier.addingReportingOverflow(later)
        return !overflowed
    }

    // MARK: - Telling the reader

    /// Join every shortfall's clause, in order.
    ///
    /// - Parameter shortfalls: What the search is missing.
    /// - Returns: The clauses separated by semicolons, or `""` when there are none.
    public static func describe(_ shortfalls: [RetrievalShortfall]) -> String {
        shortfalls.map { $0.describe() }.joined(separator: SearchFailureConstants.clauseSeparator)
    }

    /// Build the notice that precedes whatever an incomplete search produced.
    ///
    /// - Parameter shortfalls: What the search is missing.
    /// - Returns: A Markdown block quote, or `""` when the search was complete,
    ///   so a complete search never reads as a qualified one.
    public static func notice(for shortfalls: [RetrievalShortfall]) -> String {
        guard !shortfalls.isEmpty else { return "" }
        return SearchFailureConstants.noticeOpening
            + describe(shortfalls)
            + "."
            + SearchFailureConstants.noticeClosing
    }

    /// Put the incomplete-search notice in front of text a reader will see.
    ///
    /// - Parameters:
    ///   - text: A report, or a message standing in for one.
    ///   - shortfalls: What the search behind it is missing.
    /// - Returns: The notice, a blank line and the text; or the text unchanged
    ///   when the search was complete.
    public static func withNotice(_ text: String, shortfalls: [RetrievalShortfall]) -> String {
        let notice = notice(for: shortfalls)
        guard !notice.isEmpty else { return text }
        return notice + SearchFailureConstants.noticeSeparator + text
    }

    /// Separate the incomplete-search notice from the text behind it.
    ///
    /// For a renderer that draws the notice ahead of what it shows before the
    /// report's own text, such as the verdict: the notice is moved, never
    /// dropped.
    ///
    /// - Parameter text: A report, with or without the notice.
    /// - Returns: The notice as ``withNotice(_:shortfalls:)`` wrote it and the
    ///   text after it; or `nil` and the text unchanged when it does not open
    ///   with one.
    public static func splitNotice(_ text: String) -> (notice: String?, body: String) {
        guard text.hasPrefix(SearchFailureConstants.noticeOpening),
              let separator = text.range(of: SearchFailureConstants.noticeSeparator) else {
            return (nil, text)
        }
        return (String(text[text.startIndex..<separator.lowerBound]), String(text[separator.upperBound...]))
    }

    /// Whether a text opens with the incomplete-search notice.
    ///
    /// For a surface that shows a report's verdict without its text, such as the
    /// history list, and must still say the evidence base was partial.
    ///
    /// - Parameter text: A report, with or without the notice.
    /// - Returns: `true` when it opens with one.
    public static func isIncompleteSearchReport(_ text: String) -> Bool {
        splitNotice(text).notice != nil
    }

    /// Render a notice as plain text, for a surface that draws no Markdown.
    ///
    /// - Parameter notice: A notice from ``notice(for:)``.
    /// - Returns: The same sentence without its block-quote and bold markup.
    public static func plainNotice(_ notice: String) -> String {
        guard notice.hasPrefix(SearchFailureConstants.noticeOpening) else { return notice }
        return SearchFailureConstants.plainNoticeOpening
            + notice.dropFirst(SearchFailureConstants.noticeOpening.count)
    }

    /// Separate the notice from the text behind it, the notice as plain text.
    ///
    /// For a surface that draws the notice ahead of the verdict and draws no
    /// Markdown for it: the shared text and the exported PDF.
    ///
    /// - Parameter text: A report, with or without the notice.
    /// - Returns: The notice as ``plainNotice(_:)`` renders it and the text
    ///   after it; or `nil` and the text unchanged when it does not open with one.
    public static func splitPlainNotice(_ text: String) -> (notice: String?, body: String) {
        let (notice, body) = splitNotice(text)
        return (notice.map(plainNotice), body)
    }

    /// Build the persistent warning an incomplete search shows while its session goes on.
    ///
    /// - Parameter shortfalls: What the session's searches failed to retrieve.
    /// - Returns: `"Incomplete search: {clauses}."`, or `nil` when the searches
    ///   were complete.
    public static func incompleteSearchWarning(_ shortfalls: [RetrievalShortfall]) -> String? {
        guard !shortfalls.isEmpty else { return nil }
        return SearchFailureConstants.plainNoticeOpening + describe(shortfalls) + "."
    }

    /// Build the report's Methodology section for an incomplete search.
    ///
    /// The app's report has no Methodology section of its own — the model
    /// writes the analysis and the workflow appends the references — so this
    /// holds only the contract's Search Completeness line (user's decision,
    /// 2026-09-15).
    ///
    /// - Parameter shortfalls: What the search behind the report is missing.
    /// - Returns: The section, or `""` when the search was complete.
    public static func searchCompletenessMethodology(_ shortfalls: [RetrievalShortfall]) -> String {
        guard !shortfalls.isEmpty else { return "" }
        return SearchFailureConstants.methodologyHeading
            + SearchFailureConstants.noticeSeparator
            + SearchFailureConstants.searchCompletenessLabel
            + describe(shortfalls)
    }

    /// Say what the user can do about a failed search.
    ///
    /// - Parameter shortfalls: What failed.
    /// - Returns: One or more sentences, each at most once, in this order:
    ///   waiting out a rate limit (and, for PubMed, adding an NCBI API key);
    ///   checking the NCBI API key PubMed refused; rephrasing a question the
    ///   service could not process; checking the connection. Otherwise, trying
    ///   again later.
    public static func advice(for shortfalls: [RetrievalShortfall]) -> String {
        var advice: [String] = []
        let rateLimited = shortfalls.filter {
            $0.hasHTTPStatus(in: [BioMedLitConstants.httpStatusRateLimited])
        }
        if !rateLimited.isEmpty {
            advice.append(SearchFailureConstants.rateLimitAdvice)
            if rateLimited.contains(where: { $0.source == .pubmed }) {
                advice.append(SearchFailureConstants.pubMedKeyAdvice)
            }
        }
        if shortfalls.contains(where: {
            $0.source == .pubmed && $0.hasHTTPStatus(in: SearchFailureConstants.refusedKeyStatuses)
        }) {
            advice.append(SearchFailureConstants.pubMedRefusedKeyAdvice)
        }
        if shortfalls.contains(where: { $0.failure.kind == .serviceError }) {
            advice.append(SearchFailureConstants.serviceErrorAdvice)
        }
        if shortfalls.contains(where: { $0.failure.kind == .timeout || $0.failure.kind == .connection }) {
            advice.append(SearchFailureConstants.connectivityAdvice)
        }
        guard !advice.isEmpty else { return SearchFailureConstants.fallbackAdvice }
        return advice.joined(separator: SearchFailureConstants.adviceSeparator)
    }

    /// Say what a failed search could not do, and what to do next.
    ///
    /// - Parameter error: The failed search.
    /// - Returns: The error's sentence, a blank line, and the advice.
    public static func failureMessage(_ error: SearchFailedError) -> String {
        let sentence = error.errorDescription ?? SearchFailureConstants.searchFailedOpening
        return sentence + SearchFailureConstants.noticeSeparator + advice(for: error.shortfalls)
    }

    // MARK: - The persisted form

    /// Build the value a report stores for what the search behind it lost.
    ///
    /// Unlike a session's, a report's record is written for a complete search
    /// too, as the contract's `[]`: a report that recorded nothing at all is one
    /// saved before the record existed, and only its own text can be asked
    /// (``ReportSearchCompleteness``).
    ///
    /// Write it before anything is spent on the report. A record that cannot be
    /// written must stop the report being made, not be stored as `nil` — which
    /// is how a complete search is stored, and would have the report claim one.
    ///
    /// - Parameter shortfalls: What the search behind the report is missing.
    /// - Returns: `"[]"` for a complete search, otherwise the contract's JSON array.
    /// - Throws: ``DamagedShortfallRecordError`` when what is missing could not
    ///   be written down.
    public static func reportRecord(for shortfalls: [RetrievalShortfall]) throws -> String {
        guard !shortfalls.isEmpty else { return SearchFailureConstants.completeSearchRecord }
        guard let record = json(from: shortfalls) else {
            throw DamagedShortfallRecordError(
                reason: "What the search behind this report failed to retrieve could not be written down."
            )
        }
        return record
    }

    /// Build the value a session stores for what its search is missing.
    ///
    /// - Parameter shortfalls: What the search is missing.
    /// - Returns: A JSON array in the contract's form, or `nil` when there are
    ///   none, so a complete search stores nothing.
    public static func json(from shortfalls: [RetrievalShortfall]) -> String? {
        guard !shortfalls.isEmpty else { return nil }
        let entries: [[String: Any]] = shortfalls.map { shortfall in
            var failure: [String: Any] = [keyKind: shortfall.failure.kind.rawValue]
            failure[keyStatusCode] = shortfall.failure.statusCode ?? NSNull()
            var entry: [String: Any] = [
                keyProvider: shortfall.source.rawValue,
                keyFailure: failure,
                keyRecordsMissing: shortfall.recordsMissing ?? NSNull(),
            ]
            if let marker = shortfall.query.persistedValue {
                entry[keyQuery] = marker
            }
            return entry
        }
        guard let data = try? JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            // Every value written here is a string, an integer or null, so this
            // is unreachable; saying so beats a silent empty record (#252).
            BioMedLitLib.logger?.error(
                "Could not write \(shortfalls.count) retrieval shortfall(s) as JSON",
                category: .search
            )
            return nil
        }
        return text
    }

    /// Read what a session stored about its search's shortfalls.
    ///
    /// The failure, the count and the query degrade: an unknown kind, or a
    /// failure that is missing or not an object, reads as a failed request; a
    /// status code that is not a whole number from 100 to 999, or that belongs
    /// to a kind carrying none, reads as `nil`; a count that is not a whole
    /// number of at least one reads as `nil`, and a query marker this build does
    /// not know reads as the original query — both of which claim more is
    /// missing, never less.
    ///
    /// - Parameter stored: The stored value, untrusted; `nil` when nothing was
    ///   stored (a complete search, or a session saved before this shipped).
    /// - Returns: The shortfalls.
    /// - Throws: ``DamagedShortfallRecordError`` if the value is not a JSON
    ///   array (the JSON literal `null` included), or an entry is not an object
    ///   naming PubMed or Europe PMC. Nothing is skipped: a dropped shortfall
    ///   would let a report claim a complete search.
    public static func shortfalls(fromJSON stored: String?) throws -> [RetrievalShortfall] {
        guard let stored else { return [] }
        guard let entries = decodedJSON(stored) as? [Any] else {
            throw DamagedShortfallRecordError(reason: "Recorded retrieval shortfalls must be a JSON array")
        }
        return try entries.map(shortfall(from:))
    }

    /// Decode JSON without keeping the decoder's error, whose message quotes the input.
    ///
    /// - Parameter text: The stored text.
    /// - Returns: The decoded value, or `nil` when the text is not JSON.
    private static func decodedJSON(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    /// Read one stored shortfall.
    ///
    /// - Parameter entry: The stored entry.
    /// - Returns: The shortfall.
    /// - Throws: ``DamagedShortfallRecordError`` if the entry is not an object
    ///   naming PubMed or Europe PMC.
    private static func shortfall(from entry: Any) throws -> RetrievalShortfall {
        guard let fields = entry as? [String: Any] else {
            throw DamagedShortfallRecordError(reason: "A retrieval shortfall must be a JSON object")
        }
        guard let name = fields[keyProvider] as? String, let source = SearchSource(rawValue: name) else {
            throw DamagedShortfallRecordError(reason: "A retrieval shortfall must name PubMed or Europe PMC")
        }
        // An unknown marker reads as the original query, whose clause claims more is missing
        let query: ShortfallQuery = (fields[keyQuery] as? String) == ShortfallQuery.alternative.persistedValue
            ? .alternative
            : .original
        let failure = restoredFailure(fields[keyFailure])
        guard let missing = wholeNumber(fields[keyRecordsMissing]),
              missing >= 1, missing <= Int64(Int.max),
              let shortfall = RetrievalShortfall.missingRecords(
                  Int(missing), from: source, failure: failure, query: query
              ) else {
            return RetrievalShortfall(source: source, failure: failure, query: query)
        }
        return shortfall
    }

    /// Read a stored failure, degrading rather than refusing.
    ///
    /// - Parameter value: The stored value, untrusted.
    /// - Returns: The failure, as specific as the stored value allows.
    private static func restoredFailure(_ value: Any?) -> RequestFailure {
        guard let fields = value as? [String: Any],
              let name = fields[keyKind] as? String,
              let kind = RequestFailureKind(rawValue: name) else {
            return .requestFailed
        }
        let status = wholeNumber(fields[keyStatusCode])
            .flatMap { RequestFailure.isHTTPStatusCode($0) ? Int($0) : nil }
        return RequestFailure.restored(kind: kind, statusCode: status)
    }

    /// Read a stored whole number.
    ///
    /// `JSONSerialization` hands back every number as an `NSNumber`, where
    /// `true` is indistinguishable from `1` by value and `5.5` from `5` by
    /// `intValue`. Both are asked about directly: a boolean by its CoreFoundation
    /// type, a fraction by the number's own storage type.
    ///
    /// - Parameter value: The stored value, untrusted.
    /// - Returns: The number, or `nil` for anything else: a string, a boolean, a
    ///   fraction, `null`, or a number too large to hold.
    private static func wholeNumber(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number as CFTypeRef) != CFBooleanGetTypeID() else { return nil }
        let storage = String(cString: number.objCType)
        guard storage != "f", storage != "d" else { return nil }
        return number.int64Value
    }
}

// MARK: - Shortfall helpers

private extension RetrievalShortfall {
    /// Whether the shortfall is an HTTP error answer with one of the statuses.
    ///
    /// - Parameter statuses: The status codes to look for.
    /// - Returns: `true` for an ``RequestFailureKind/httpStatus`` failure whose
    ///   status is among them.
    func hasHTTPStatus(in statuses: Set<Int>) -> Bool {
        guard failure.kind == .httpStatus, let status = failure.statusCode else { return false }
        return statuses.contains(status)
    }
}
