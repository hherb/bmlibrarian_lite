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

/// Service for searching the Europe PMC literature database.
///
/// Europe PMC provides access to biomedical and life sciences literature,
/// including articles from PubMed, PubMed Central, and other sources.
///
/// Usage:
/// ```swift
/// let service = EuropePMCService()
/// let results = try await service.search(query: "COVID-19 treatment")
/// ```
public actor EuropePMCService {
    // MARK: - Properties

    /// The cursor that asks for a search's first page.
    static let initialCursor = "*"

    private let session: URLSession
    private let baseURL: String

    // MARK: - Initialization

    /// Initialize the Europe PMC service.
    ///
    /// - Parameter session: URLSession to use for requests. Defaults to shared session.
    public init(session: URLSession? = nil) {
        self.baseURL = BioMedLitConstants.europePMCBaseURL

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.searchRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - Search

    /// Search Europe PMC for one page of articles matching the query.
    ///
    /// A failed request is never an empty page (#256): whatever of the page the
    /// answer loses is reported with the articles that arrived, as
    /// ``SearchResult/shortfalls``, and a page that failures leave with nothing
    /// throws ``SourceRequestError``.
    ///
    /// - Parameters:
    ///   - query: Search query string (supports Europe PMC query syntax).
    ///   - pageSize: Number of results per page (default: 25, max: 1000).
    ///   - cursor: Cursor for pagination (use "*" for first page).
    ///   - includePreprints: Whether to include preprints in results.
    ///   - requireAbstract: Whether to only return articles with abstracts.
    ///   - recordsReceived: How many records the search's earlier pages held,
    ///     readable or not; 0 for a first page, and `nil` when nobody counted
    ///     them — a session saved before the count was kept, whose cursor can
    ///     outlive its last hit, so nothing in particular is expected of the page.
    /// - Returns: The page's articles, the search's hit count, what the page
    ///   failed to retrieve, and the cursor of the next page — `nil` once the
    ///   cursor ends.
    /// - Throws: ``SourceRequestError`` if the request failed after its retries,
    ///   the answer cannot be read, or it holds no record where the hit count
    ///   says it should hold some.
    public func search(
        query: String,
        pageSize: Int = BioMedLitConstants.europePMCDefaultPageSize,
        cursor: String = "*",
        includePreprints: Bool = false,
        requireAbstract: Bool = true,
        recordsReceived: Int? = 0
    ) async throws -> SearchResult {
        // Build the full query with filters
        var fullQuery = query

        // Exclude preprints unless requested
        if !includePreprints && !query.uppercased().contains("SRC:PPR") {
            fullQuery += " NOT SRC:PPR"
        }

        // Require abstracts unless the query already specifies
        if requireAbstract && !query.uppercased().contains("HAS_ABSTRACT") {
            fullQuery += " AND HAS_ABSTRACT:Y"
        }

        let data = try await requestPage(query: fullQuery, pageSize: pageSize, cursor: cursor)
        let page = try readPage(data, cursor: cursor, pageSize: pageSize, recordsReceived: recordsReceived)

        BioMedLitLib.logger?.info(
            "Europe PMC search returned \(page.articles.count) of \(page.hitCount) results",
            category: .search
        )

        return SearchResult(
            articles: page.articles,
            totalCount: page.hitCount,
            nextCursor: page.nextCursor,
            query: fullQuery,
            provider: .europePMC,
            shortfalls: page.shortfalls,
            recordsReceived: page.recordsReceived
        )
    }

    // MARK: - Lookup

    /// Look one known article up by its own identifier.
    ///
    /// A lookup is not a page of a search, and the two ask opposite things of a
    /// record. Discovery shows a reader what the literature holds, so a record
    /// with no title is one it cannot show and reports as missing; a lookup asks
    /// Europe PMC what it holds about *this* article, and a record that names a
    /// PMC accession answers that question whether or not it carries a title.
    /// Nothing is expected of the page either: one hit is asked for, and the
    /// hit count says how many other articles match a query nobody is paging.
    ///
    /// - Parameters:
    ///   - query: The identifier query, sent as it is.
    ///   - pageSize: How many records to ask for.
    /// - Returns: The records Europe PMC answered with, in its order; empty when
    ///   it holds none.
    /// - Throws: ``SourceRequestError`` if the request failed after its retries
    ///   or the answer cannot be read, so "Europe PMC has nothing for this
    ///   article" and "we could not ask Europe PMC" stay opposite answers (#186).
    public func lookup(query: String, pageSize: Int = 1) async throws -> [SearchArticle] {
        let data = try await requestPage(query: query, pageSize: pageSize, cursor: Self.initialCursor)

        guard let answer = try? JSONDecoder().decode(EuropePMCResponse.self, from: data) else {
            throw unreadableAnswer("lookup answer is not Europe PMC's JSON")
        }
        // No hit count is asked of a lookup: it says how many articles match a
        // query nobody is paging, and a lookup asks for one known article
        guard let records = answer.resultList?.result else {
            throw unreadableAnswer("lookup answer has no resultList.result list")
        }
        return records.compactMap { $0.value }.map(EuropePMCService.searchArticle(from:))
    }

    // MARK: - One Page

    /// One search page as read.
    private struct SearchPage {
        /// The articles that could be read.
        let articles: [SearchArticle]

        /// How many records the answer held, readable or not.
        let recordsReceived: Int

        /// The search's hit count.
        let hitCount: Int

        /// The cursor of the next page, or `nil` once the cursor ends.
        let nextCursor: String?

        /// What the page failed to retrieve.
        let shortfalls: [RetrievalShortfall]
    }

    /// Request one search page and refuse an unsuccessful answer.
    ///
    /// - Parameters:
    ///   - query: The query as it is sent, filters included.
    ///   - pageSize: Number of results per page.
    ///   - cursor: The cursor to send.
    /// - Returns: The body of a 200 response.
    /// - Throws: ``SourceRequestError`` if the endpoint is not a URL, the
    ///   request failed after its retries, or the status is not 200.
    private func requestPage(query: String, pageSize: Int, cursor: String) async throws -> Data {
        guard var components = URLComponents(string: BioMedLitConstants.europePMCSearchURL) else {
            BioMedLitLib.logger?.error(
                "The Europe PMC search endpoint is not a URL", category: .search
            )
            throw SourceRequestError(source: .europePMC, failure: .requestFailed)
        }
        components.queryItems = [
            URLQueryItem(name: "query", value: query),
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "pageSize", value: String(min(pageSize, BioMedLitConstants.europePMCMaxPageSize))),
            URLQueryItem(name: "cursorMark", value: cursor),
            URLQueryItem(name: "resultType", value: "core")
        ]

        guard let url = components.url else {
            BioMedLitLib.logger?.error(
                "The Europe PMC search query could not be written into a URL", category: .search
            )
            throw SourceRequestError(source: .europePMC, failure: .requestFailed)
        }

        BioMedLitLib.logger?.debug("Europe PMC search URL: \(url.absoluteString)", category: .search)

        let session = self.session
        do {
            return try await RetryHelper.retry(
                config: .networkDefault,
                shouldRetry: RetryHelper.retryOnlyTransient
            ) {
                let (data, response) = try await session.data(from: url)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw SourceRequestError(source: .europePMC, failure: .requestFailed)
                }

                guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                    throw SourceRequestError(
                        source: .europePMC, failure: .httpStatus(httpResponse.statusCode)
                    )
                }

                return data
            }
        } catch let error as SourceRequestError {
            BioMedLitLib.logger?.warning(
                "Europe PMC search failed: \(error.failure.describe())", category: .search
            )
            throw error
        } catch where error.isCancellation {
            // A cancelled request is the user's doing, not the source's
            throw CancellationError()
        } catch {
            throw SourceRequestError(source: .europePMC, failure: SearchTransport.failure(for: error))
        }
    }

    /// Read a search page Europe PMC answered, checking it holds what it counts.
    ///
    /// Checked live on 2026-09-14: an unknown `cursorMark` answers HTTP 200 with
    /// only a `version` field, which has no hit count and is therefore an answer
    /// that cannot be read rather than a search that matched nothing (#255).
    ///
    /// - Parameters:
    ///   - data: The answer's body.
    ///   - cursor: The cursor the page was requested with.
    ///   - pageSize: The page size asked for.
    ///   - recordsReceived: How many records the search's earlier pages held, or
    ///     `nil` when nobody counted them.
    /// - Returns: The page's readable articles, its cursor and its shortfalls.
    /// - Throws: ``SourceRequestError`` if the answer cannot be read, or holds no
    ///   record where the hit count says it should hold some.
    private func readPage(
        _ data: Data,
        cursor: String,
        pageSize: Int,
        recordsReceived: Int?
    ) throws -> SearchPage {
        // The decoder's error quotes the body it could not read, so it is dropped here
        guard let answer = try? JSONDecoder().decode(EuropePMCResponse.self, from: data) else {
            throw unreadableAnswer("search answer is not Europe PMC's JSON")
        }
        guard let hitCount = answer.hitCount, hitCount >= 0 else {
            throw unreadableAnswer("search answer has no non-negative integer hitCount")
        }
        guard let records = answer.resultList?.result else {
            throw unreadableAnswer("search answer has no resultList.result list")
        }

        // Unknown when nobody counted what came before: then nothing is expected of the page
        let expected = recordsReceived.map {
            SearchPaging.expectedEuropePMCPage(hitCount: hitCount, recordsReceived: $0, pageSize: pageSize)
        } ?? 0
        if records.isEmpty && expected > 0 {
            BioMedLitLib.logger?.error(
                "Europe PMC sent an empty page after \(recordsReceived ?? 0) of \(hitCount) results",
                category: .search
            )
            throw SourceRequestError(source: .europePMC, failure: .incompleteResponse)
        }

        // nextCursorMark repeats the cursor sent when there are no more results
        let nextCursor = answer.nextCursorMark.flatMap { next -> String? in
            guard next != cursor, next != Self.initialCursor, !records.isEmpty else { return nil }
            return next
        }

        // The cursor ends only once every hit was sent (checked live 2026-09-15).
        // Nothing past an ended cursor can be asked for, so every hit not received
        // is missing, including those an earlier page left out while its cursor went on
        let cutShort: Int
        if nextCursor == nil, let recordsReceived {
            cutShort = max(0, hitCount - (recordsReceived + records.count))
            if cutShort > 0 {
                BioMedLitLib.logger?.error(
                    "Europe PMC's cursor ended after \(recordsReceived + records.count) of \(hitCount) results",
                    category: .search
                )
            }
        } else {
            cutShort = 0
        }

        let articles = records.compactMap { record -> SearchArticle? in
            guard let result = record.value,
                  let title = result.title,
                  !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return EuropePMCService.searchArticle(from: result)
        }
        let unreadable = records.count - articles.count
        if unreadable > 0 {
            BioMedLitLib.logger?.warning(
                "Europe PMC sent \(unreadable) records that could not be read or have no title",
                category: .search
            )
        }

        return SearchPage(
            articles: articles,
            recordsReceived: records.count,
            hitCount: hitCount,
            nextCursor: nextCursor,
            shortfalls: [
                RetrievalShortfall.missingRecords(cutShort, from: .europePMC, failure: .incompleteResponse),
                RetrievalShortfall.missingRecords(unreadable, from: .europePMC, failure: .malformedResponse),
            ].compactMap { $0 }
        )
    }

    /// Build the error for a search answer that cannot be read, and log why.
    ///
    /// - Parameter reason: What was wrong, naming fields only, never their values.
    /// - Returns: The error to throw.
    private func unreadableAnswer(_ reason: String) -> SourceRequestError {
        BioMedLitLib.logger?.error("Unreadable Europe PMC answer: \(reason)", category: .search)
        return SourceRequestError(source: .europePMC, failure: .malformedResponse)
    }

    // MARK: - Result Mapping

    /// One Europe PMC record as a search article.
    ///
    /// The primary identifier slot is `pmid ?? id ?? ""`, which is why it does
    /// not hold one kind of thing: a MEDLINE record fills it with a PubMed ID, a
    /// preprint with a `PPR…` accession, a PMC-only record with a PMC accession,
    /// and a record with neither leaves it empty (#202).
    ///
    /// The record's own `source` field says which, and travels with the article
    /// as ``SearchArticle/identifierKind``. It used to be decoded and dropped
    /// here, leaving the retrieval chain to reconstruct the kind from the
    /// accession's shape — a reconstruction that cannot name the sources it was
    /// never taught, and asks for each of them under `src:med`, where they match
    /// nothing (#209).
    ///
    /// - Parameter result: One decoded Europe PMC search result.
    /// - Returns: The article, carrying the kind the record stated.
    static func searchArticle(from result: EuropePMCResult) -> SearchArticle {
        SearchArticle(
            pmid: result.pmid ?? result.id ?? "",
            pmcId: result.pmcid,
            doi: result.doi,
            title: result.title ?? "",
            abstract: cleanAbstract(result.abstractText),
            authors: result.authorString ?? "",
            journal: result.journalTitle ?? result.journalInfo?.journal?.title ?? "",
            year: result.pubYear ?? "",
            publicationDate: result.firstPublicationDate,
            hasFullText: result.inPMC == "Y",
            isOpenAccess: result.isOpenAccess == "Y",
            source: .europePMC,
            pdfRenderURL: extractFreePDFURL(from: result),
            identifierKind: ArticleIdentifierKind(europePMCSource: result.source)
        )
    }

    // MARK: - Free PDF Selection

    /// Extract a free PDF URL from a result's ``fullTextUrlList``.
    ///
    /// The search API includes `fullTextUrlList` with `?pdf=render` entries for
    /// PDFs Europe PMC serves itself, even when JATS XML is unavailable — which
    /// is exactly when the PDF tier needs one.
    ///
    /// Entries that are PDFs but not downloadable are logged rather than dropped
    /// silently, so "a PDF entry was seen and not taken" is visible in a trace.
    ///
    /// - Parameter result: One Europe PMC search result.
    /// - Returns: The first downloadable PDF URL, or `nil` if the result offers none.
    ///
    /// - SeeAlso: ``reportRejectedPDFEntry(_:)`` for how a rejection is reported.
    static func extractFreePDFURL(from result: EuropePMCResult) -> String? {
        guard let entries = result.fullTextUrlList?.fullTextUrl else { return nil }

        for entry in entries
        where entry.documentStyle == BioMedLitConstants.europePMCPDFDocumentStyle {
            guard entry.isFreeToDownload else {
                reportRejectedPDFEntry(entry)
                continue
            }
            if let url = entry.url { return url }
        }
        return nil
    }

    /// Report a PDF entry that was seen and not taken.
    ///
    /// The two reasons are not equally interesting, so they are not logged at the
    /// same level. A recognised paywall code is the allow-list working as designed
    /// and stays at debug. A code in neither the allow-list nor the known-paywalled
    /// set means Europe PMC has started publishing a value this build has never
    /// evaluated: the allow-list then rejects it fail-closed, silently costing
    /// free PDFs, which is exactly how bmlib issue #79 happened. That warrants a
    /// warning naming the code, so the fix is a one-line constant edit rather than
    /// another measurement campaign.
    ///
    /// - Parameter entry: The rejected `fullTextUrl` entry.
    private static func reportRejectedPDFEntry(_ entry: EuropePMCFullTextUrlEntry) {
        let code = entry.availabilityCode ?? ""
        let label = entry.availability ?? "nil"

        guard !code.isEmpty,
              !BioMedLitConstants.europePMCFreePDFAvailabilityCodes.contains(code),
              !BioMedLitConstants.europePMCKnownUnavailablePDFCodes.contains(code) else {
            BioMedLitLib.logger?.debug(
                "Skipping Europe PMC PDF entry: availability=\(label) code=\(code.isEmpty ? "nil" : code)",
                category: .fullText
            )
            return
        }

        BioMedLitLib.logger?.warning(
            """
            Unrecognised Europe PMC availabilityCode '\(code)' (availability=\(label)); \
            the PDF was rejected fail-closed. If this is a free tier, add it to \
            BioMedLitConstants.europePMCFreePDFAvailabilityCodes.
            """,
            category: .fullText
        )
    }

    // MARK: - Helpers

    /// Clean abstract text by removing HTML tags.
    private static func cleanAbstract(_ text: String?) -> String {
        guard let text = text else { return "" }

        // Convert <h4>Section</h4> to **Section:**
        var result = text
        if let regex = try? NSRegularExpression(pattern: "<h4>([^<]+)</h4>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\n\n**$1:** "
            )
        }

        // Remove paragraph tags
        result = result.replacingOccurrences(of: "<p>", with: "\n\n")
        result = result.replacingOccurrences(of: "</p>", with: "")

        // Remove any remaining HTML tags
        if let regex = try? NSRegularExpression(pattern: "<[^>]+>", options: .caseInsensitive) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: ""
            )
        }

        // Clean up whitespace
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)

        return result
    }
}

// MARK: - Response Types

/// Europe PMC search response.
struct EuropePMCResponse: Codable {
    let hitCount: Int?
    let nextCursorMark: String?
    let resultList: EuropePMCResultList?
}

/// Europe PMC result list wrapper.
///
/// A missing `result` list stays missing rather than reading as an empty one: a
/// page with no list is an answer that cannot be read, and a page with an empty
/// list is a source saying it sent nothing (#255). The two are opposite
/// answers, and only one of them is the evidence base's own.
struct EuropePMCResultList: Codable {
    let result: [DecodedOrNil<EuropePMCResult>]?
}

/// One element of a list, decoded if it can be.
///
/// A record Europe PMC sends that this build cannot decode is one record
/// missing, not a page that cannot be read: decoding the list strictly would
/// throw away every other record on the page with it.
struct DecodedOrNil<Wrapped: Codable>: Codable {
    /// The decoded element, or `nil` when it could not be decoded.
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }

    /// Encode the element, or nothing where there was nothing to decode.
    ///
    /// Only ``EuropePMCResultList``'s conformance asks for this; the app never
    /// sends Europe PMC a result list.
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        guard let value else {
            try container.encodeNil()
            return
        }
        try container.encode(value)
    }
}

/// Europe PMC article result.
struct EuropePMCResult: Codable {
    let id: String?
    let source: String?
    let pmid: String?
    let pmcid: String?
    let doi: String?
    let title: String?
    let authorString: String?
    let journalTitle: String?
    let journalInfo: EuropePMCJournalInfo?
    let pubYear: String?
    let firstPublicationDate: String?
    let abstractText: String?
    let isOpenAccess: String?
    let inPMC: String?
    let hasPDF: String?
    let fullTextUrlList: EuropePMCFullTextUrlList?
}

/// Europe PMC full-text URL list wrapper.
struct EuropePMCFullTextUrlList: Codable {
    let fullTextUrl: [EuropePMCFullTextUrlEntry]?
}

/// Europe PMC full-text URL entry.
struct EuropePMCFullTextUrlEntry: Codable {
    let documentStyle: String?
    let site: String?
    let url: String?
    let availability: String?
    let availabilityCode: String?
}

extension EuropePMCFullTextUrlEntry {
    /// Whether this entry is one the app may download.
    ///
    /// `true` when the entry's access code is one of
    /// ``BioMedLitConstants/europePMCFreePDFAvailabilityCodes``, or — for an entry
    /// carrying no code — its display string is one of
    /// ``BioMedLitConstants/europePMCFreePDFAvailabilityLabels``.
    ///
    /// A code that is present but unrecognised returns `false` **without**
    /// consulting the string: falling back there would let a future code the app
    /// has never evaluated through on the strength of a label, which is the
    /// opposite of the under-credit rule the allow-list exists to keep.
    var isFreeToDownload: Bool {
        if let code = availabilityCode, !code.isEmpty {
            return BioMedLitConstants.europePMCFreePDFAvailabilityCodes.contains(code)
        }
        guard let availability = availability else { return false }
        return BioMedLitConstants.europePMCFreePDFAvailabilityLabels.contains(availability)
    }
}

/// Europe PMC journal info.
struct EuropePMCJournalInfo: Codable {
    let journal: EuropePMCJournal?
}

/// Europe PMC journal details.
struct EuropePMCJournal: Codable {
    let title: String?
    let medlineAbbreviation: String?
}
