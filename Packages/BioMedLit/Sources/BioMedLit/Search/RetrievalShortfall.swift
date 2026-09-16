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

// MARK: - Why a request produced no usable answer

/// Why a request to a literature source produced no usable answer (#256, #255).
///
/// A failed source is not a source with no evidence: each kind reads
/// differently to the user, and none of them as a search that matched nothing.
/// The raw values are the strings stored in a session's retrieval shortfalls
/// and are the contract's, shared with Python and Android
/// (`doc/cross_platform/search_failure_reporting.md`): never rename one.
public enum RequestFailureKind: String, Sendable, Codable, CaseIterable {
    /// The request timed out after its retries.
    case timeout

    /// No connection could be made, or it broke.
    case connection

    /// The source answered with an HTTP error status.
    case httpStatus = "http_status"

    /// E-utilities answered with a redirect, which is never followed (#243).
    case redirectRefused = "redirect_refused"

    /// The source answered, but said the request failed: an `ERROR` inside an HTTP 200 (#255).
    case serviceError = "service_error"

    /// The answer could not be read.
    case malformedResponse = "malformed_response"

    /// The answer was readable but held less than it counted.
    case incompleteResponse = "incomplete_response"

    /// Anything else.
    case requestFailed = "request_failed"

    /// Whether a failure of this kind is an HTTP answer, and so can name its status.
    public var carriesStatusCode: Bool {
        self == .httpStatus || self == .redirectRefused
    }
}

// MARK: - The failure record

/// A request that failed after its retries, reduced to what is safe to show.
///
/// Only the kind and the HTTP status are kept. An answer's body is not: NCBI's
/// 400 for a bad key repeats the key, and a decoder's error quotes the body it
/// could not read. Nothing built from this type can therefore print either.
///
/// The memberwise initializer is private, so a kind that carries no status can
/// never be given one: each kind is reached through the factory that suits it.
public struct RequestFailure: Sendable, Equatable, Hashable {
    /// The statuses an HTTP answer can carry: every three-digit code.
    private static let statusCodeRange = 100...999

    /// What went wrong.
    public let kind: RequestFailureKind

    /// The HTTP status, for ``RequestFailureKind/httpStatus`` and
    /// ``RequestFailureKind/redirectRefused``; `nil` otherwise or when unknown.
    public let statusCode: Int?

    /// Build a failure of a kind that carries no status, or one already checked.
    ///
    /// - Parameters:
    ///   - kind: What went wrong.
    ///   - statusCode: The HTTP status, already checked against ``statusCodeRange``.
    private init(kind: RequestFailureKind, statusCode: Int?) {
        self.kind = kind
        self.statusCode = statusCode
    }

    // MARK: Kinds that carry no status

    /// The request timed out after its retries.
    public static let timeout = RequestFailure(kind: .timeout, statusCode: nil)

    /// No connection could be made, or it broke.
    public static let connection = RequestFailure(kind: .connection, statusCode: nil)

    /// The source answered an HTTP 200 that reports an error instead of a result.
    public static let serviceError = RequestFailure(kind: .serviceError, statusCode: nil)

    /// The answer could not be read.
    public static let malformedResponse = RequestFailure(kind: .malformedResponse, statusCode: nil)

    /// The answer was readable but held less than it counted.
    public static let incompleteResponse = RequestFailure(kind: .incompleteResponse, statusCode: nil)

    /// Anything else, including a kind this build could not tell apart.
    public static let requestFailed = RequestFailure(kind: .requestFailed, statusCode: nil)

    // MARK: Kinds that carry a status

    /// The failure for an unsuccessful status from a source whose redirects are followed.
    ///
    /// Europe PMC's requests carry no credential, so its redirects are followed
    /// and a 3xx reaching this point is an answer like any other.
    ///
    /// - Parameter statusCode: The status the source answered with.
    /// - Returns: An HTTP error naming the status, or naming none when it is not
    ///   a status an HTTP answer can carry.
    public static func httpStatus(_ statusCode: Int) -> RequestFailure {
        RequestFailure(kind: .httpStatus, statusCode: checkedStatusCode(statusCode))
    }

    /// The failure for an answer with an unsuccessful status, redirects refused.
    ///
    /// - Parameter statusCode: The status the source answered with.
    /// - Returns: A refused redirect for a 3xx, which the PubMed client never
    ///   follows; an HTTP error otherwise. A status outside 100–999 is not one
    ///   an HTTP answer can carry, so it is dropped and only the kind is kept.
    public static func forHTTPStatus(_ statusCode: Int) -> RequestFailure {
        let kind: RequestFailureKind = BioMedLitConstants.httpRedirectStatusCodes.contains(statusCode)
            ? .redirectRefused
            : .httpStatus
        return RequestFailure(kind: kind, statusCode: checkedStatusCode(statusCode))
    }

    /// The failure for a redirect the client refused to follow (#243).
    ///
    /// - Parameter statusCode: The redirect's status, when it is known.
    /// - Returns: A refused redirect naming the status, or naming none when it
    ///   is unknown or is not a status an HTTP answer can carry.
    public static func redirectRefused(statusCode: Int?) -> RequestFailure {
        RequestFailure(kind: .redirectRefused, statusCode: checkedStatusCode(statusCode))
    }

    // MARK: Restoring a stored failure

    /// Rebuild a failure read back from storage, degrading rather than refusing.
    ///
    /// - Parameters:
    ///   - kind: The kind the stored value named.
    ///   - statusCode: The stored status, untrusted.
    /// - Returns: The failure, with the status dropped when its kind carries
    ///   none or it is not a status an HTTP answer can carry.
    static func restored(kind: RequestFailureKind, statusCode: Int?) -> RequestFailure {
        RequestFailure(
            kind: kind,
            statusCode: kind.carriesStatusCode ? checkedStatusCode(statusCode) : nil
        )
    }

    /// Keep a status only when it is one an HTTP answer can carry.
    ///
    /// - Parameter statusCode: The status, untrusted.
    /// - Returns: The status when it is an integer from 100 to 999, else `nil`.
    private static func checkedStatusCode(_ statusCode: Int?) -> Int? {
        guard let statusCode, statusCodeRange.contains(statusCode) else { return nil }
        return statusCode
    }

    /// Whether a value is a three-digit HTTP status code.
    ///
    /// - Parameter value: The value, which may be wider than `Int`.
    /// - Returns: `true` for 100 to 999.
    static func isHTTPStatusCode(_ value: Int64) -> Bool {
        value >= Int64(statusCodeRange.lowerBound) && value <= Int64(statusCodeRange.upperBound)
    }

    // MARK: Whether to try again

    /// Whether another attempt may succeed.
    ///
    /// A timeout and a broken connection may pass; so may a status the retry
    /// policy counts as transient, such as 429 or 503. A refused redirect is
    /// not among them: re-sending would re-send the API key with it.
    public var isRetryable: Bool {
        if kind == .timeout || kind == .connection { return true }
        guard kind == .httpStatus, let statusCode else { return false }
        return BioMedLitConstants.retryableStatusCodes.contains(statusCode)
    }

    // MARK: Telling the user

    /// Describe the failure as a clause for a sentence shown to the user.
    ///
    /// - Returns: For example `"HTTP 429 Too Many Requests"` or `"the request timed out"`.
    public func describe() -> String {
        switch kind {
        case .httpStatus:
            return statusCode.map(Self.httpStatusLabel) ?? "an HTTP error"
        case .redirectRefused:
            let status = statusCode.map { " (HTTP \($0))" } ?? ""
            return "a redirect\(status) was refused"
        case .timeout:
            return "the request timed out"
        case .connection:
            return "the connection failed"
        case .serviceError:
            return "the service reported an error"
        case .malformedResponse:
            return "the response could not be read"
        case .incompleteResponse:
            return "the response was incomplete"
        case .requestFailed:
            return "the request failed"
        }
    }

    /// Label an HTTP status with its reason phrase when the contract names one.
    ///
    /// The phrases are the contract's, in RFC 9110 wording, rather than a
    /// platform library's: Foundation's are lowercase and localised, and
    /// Python's have been renamed between releases.
    ///
    /// - Parameter statusCode: The status code.
    /// - Returns: For example `"HTTP 503 Service Unavailable"`, or `"HTTP 599"`.
    private static func httpStatusLabel(_ statusCode: Int) -> String {
        guard let phrase = SearchFailureConstants.httpReasonPhrases[statusCode] else {
            return "HTTP \(statusCode)"
        }
        return "HTTP \(statusCode) \(phrase)"
    }
}

// MARK: - The source a shortfall names

/// One literature source a search can lose (#256).
///
/// A shortfall names a source, never a search: ``SearchProvider/both`` is a
/// choice of what to search, and a failure always belongs to one of the two
/// sources behind it. Keeping them in separate types is what makes "a
/// shortfall naming both" unwritable rather than merely refused.
///
/// The raw values are the strings the contract persists, which are **not**
/// ``SearchProvider``'s: its `europePMC` case encodes as `"europePMC"`.
public enum SearchSource: String, Sendable, Codable, CaseIterable {
    /// PubMed, via NCBI E-utilities.
    case pubmed

    /// Europe PMC.
    case europePMC = "europepmc"

    /// The source's name as the user's sentences name it.
    public var displayName: String {
        switch self {
        case .pubmed:
            return "PubMed"
        case .europePMC:
            return "Europe PMC"
        }
    }

    /// The provider that searches only this source.
    public var provider: SearchProvider {
        switch self {
        case .pubmed:
            return .pubmed
        case .europePMC:
            return .europePMC
        }
    }

    /// The source a provider searches, when it searches only one.
    ///
    /// - Parameter provider: The provider.
    /// - Returns: The source, or `nil` for ``SearchProvider/both``.
    public init?(provider: SearchProvider) {
        switch provider {
        case .pubmed:
            self = .pubmed
        case .europePMC:
            self = .europePMC
        case .both:
            return nil
        }
    }
}

// MARK: - Which query a shortfall belongs to

/// Which query of a fact-check a shortfall belongs to.
///
/// Smart search runs alternative queries when the claim's own query finds too
/// little. An alternative search that fails must not read as the source never
/// having been searched, since the original query's results from that source
/// are in the report (user's decision, 2026-09-15).
public enum ShortfallQuery: Sendable, Equatable, Hashable, CaseIterable {
    /// The query the claim was converted to. It stores no marker.
    case original

    /// An alternative query smart search generated.
    case alternative

    /// The stored marker, or `nil` for the original query, which stores none.
    public var persistedValue: String? {
        switch self {
        case .original:
            return nil
        case .alternative:
            return "alternative"
        }
    }
}

// MARK: - What a failure left out

/// Part of a search that a failure left out (#256).
///
/// A search proceeds on what was retrieved, and the user is told what is
/// missing: never silently, and never as a search that found nothing.
public struct RetrievalShortfall: Sendable, Equatable {
    /// The source that failed.
    public let source: SearchSource

    /// Why.
    public let failure: RequestFailure

    /// How many records could not be retrieved, at least one; or `nil` when the
    /// source could not be searched at all, so how many it holds is unknown.
    public let recordsMissing: Int?

    /// Whether the loss belongs to the claim's own query or to an alternative
    /// query smart search ran.
    public let query: ShortfallQuery

    /// Record a source that could not be searched at all.
    ///
    /// - Parameters:
    ///   - source: The source that failed.
    ///   - failure: Why.
    ///   - query: Which query was being searched.
    public init(source: SearchSource, failure: RequestFailure, query: ShortfallQuery = .original) {
        self.source = source
        self.failure = failure
        self.recordsMissing = nil
        self.query = query
    }

    /// Build a shortfall with a count, which the factories check first.
    ///
    /// - Parameters:
    ///   - source: The source that failed.
    ///   - failure: Why.
    ///   - recordsMissing: How many records are missing, at least one.
    ///   - query: Which query was being searched.
    private init(source: SearchSource, failure: RequestFailure, recordsMissing: Int, query: ShortfallQuery) {
        self.source = source
        self.failure = failure
        self.recordsMissing = recordsMissing
        self.query = query
    }

    /// Record records a failure left out, if it left any out.
    ///
    /// A shortfall with nothing missing is not built: it would tell the user a
    /// complete search was incomplete.
    ///
    /// - Parameters:
    ///   - count: How many records are missing.
    ///   - source: The source that failed.
    ///   - failure: Why records are missing, or `nil` when no reason was kept,
    ///     which is recorded as a failed request: the count degrades, it is
    ///     never dropped.
    ///   - query: Which query was being searched.
    /// - Returns: The shortfall, or `nil` when nothing is missing.
    public static func missingRecords(
        _ count: Int,
        from source: SearchSource,
        failure: RequestFailure?,
        query: ShortfallQuery = .original
    ) -> RetrievalShortfall? {
        guard count >= 1 else { return nil }
        return RetrievalShortfall(
            source: source,
            failure: failure ?? .requestFailed,
            recordsMissing: count,
            query: query
        )
    }

    /// The same shortfall, recorded against another query.
    ///
    /// - Parameter query: The query the loss belongs to.
    /// - Returns: A copy naming that query.
    public func belongingTo(_ query: ShortfallQuery) -> RetrievalShortfall {
        guard let recordsMissing else {
            return RetrievalShortfall(source: source, failure: failure, query: query)
        }
        return RetrievalShortfall(source: source, failure: failure, recordsMissing: recordsMissing, query: query)
    }

    /// The same shortfall, missing a different number of records.
    ///
    /// - Parameter count: How many records are missing, at least one.
    /// - Returns: A copy missing that many records.
    func missing(_ count: Int) -> RetrievalShortfall {
        RetrievalShortfall(source: source, failure: failure, recordsMissing: max(1, count), query: query)
    }

    /// Describe the shortfall as a clause for a sentence shown to the user.
    ///
    /// - Returns: For example `"PubMed could not be searched (HTTP 429 Too Many
    ///   Requests)"`, `"1,200 Europe PMC records could not be retrieved (the
    ///   request timed out)"`, or for an alternative query `"an alternative
    ///   search of PubMed could not be completed (HTTP 429 Too Many Requests)"`.
    public func describe() -> String {
        let name = source.displayName
        let reason = failure.describe()
        let isAlternative = query == .alternative
        guard let recordsMissing else {
            return isAlternative
                ? "an alternative search of \(name) could not be completed (\(reason))"
                : "\(name) could not be searched (\(reason))"
        }
        let noun = recordsMissing == 1 ? "record" : "records"
        let origin = isAlternative ? " from an alternative search" : ""
        let count = SearchFailureConstants.groupedNumber(recordsMissing)
        return "\(count) \(name) \(noun)\(origin) could not be retrieved (\(reason))"
    }
}

// MARK: - Errors a search raises

/// A literature source could not answer a request (#256).
///
/// Thrown by the PubMed and Europe PMC clients when a request fails after its
/// retries, the source answers with an error instead of a result, or its answer
/// cannot be read or lists none of what it counts. It is never an empty result;
/// an answer that holds part of what it counts is a page with shortfalls instead.
///
/// Only the source and a ``RequestFailure`` are kept, never a cause: the
/// message cannot carry a request or an answer body. The message is for logs;
/// text shown to the user comes from ``RetrievalShortfall/describe()``, which
/// also covers a failed page rather than a whole search.
public struct SourceRequestError: LocalizedError, RetryableError, Sendable, Equatable {
    /// The source that failed.
    public let source: SearchSource

    /// Why, reduced to its kind and HTTP status.
    public let failure: RequestFailure

    /// Record a failed request to one source.
    ///
    /// - Parameters:
    ///   - source: The source that failed.
    ///   - failure: Why.
    public init(source: SearchSource, failure: RequestFailure) {
        self.source = source
        self.failure = failure
    }

    /// The shortfall this failure leaves when the source could not be searched.
    public var shortfall: RetrievalShortfall {
        RetrievalShortfall(source: source, failure: failure)
    }

    /// Whether another attempt may succeed, which is ``RequestFailure/isRetryable``.
    ///
    /// ``RetryHelper`` asks this, so a 429 or a 503 is retried with backoff
    /// before the search gives up on the source (golden rule 7).
    public var isRetryable: Bool { failure.isRetryable }

    public var errorDescription: String? {
        "\(source.displayName) could not be searched (\(failure.describe()))"
    }
}

/// A search that failures left with nothing to proceed on (#256).
///
/// A search that loses part of its sources proceeds on the rest and says what
/// is missing. When the failures leave no documents at all, the honest answer
/// is not "No documents found" — nobody knows whether there are any — so the
/// search fails with this instead.
public struct SearchFailedError: LocalizedError, Sendable, Equatable {
    /// What failed, in the order it was recorded. Never empty: a failure that
    /// names nothing tells the user nothing.
    public let shortfalls: [RetrievalShortfall]

    /// Record a search that failures left with nothing.
    ///
    /// - Parameter shortfalls: What failed. An empty list yields `nil`, since a
    ///   search with nothing to report did not fail.
    public init?(shortfalls: [RetrievalShortfall]) {
        guard !shortfalls.isEmpty else { return nil }
        self.shortfalls = shortfalls
    }

    public var errorDescription: String? {
        "The search could not be completed: \(SearchFailureReporting.describe(shortfalls))."
    }
}
