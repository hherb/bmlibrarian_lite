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
import XCTest
@testable import BioMedLit

/// What a failure is reduced to, and the sentence it reaches the reader in (#256).
///
/// A failed source is not an empty one: every clause here is the contract's
/// (`doc/cross_platform/search_failure_reporting.md`), shared word for word
/// with Python and Android, so a test that relaxes one is a parity change.
final class SearchShortfallTests: XCTestCase {
    // MARK: - The persisted values

    /// The stored strings are the contract's, which Python and Android write too.
    func testThePersistedValuesAreTheContracts() {
        XCTAssertEqual(RequestFailureKind.timeout.rawValue, "timeout")
        XCTAssertEqual(RequestFailureKind.connection.rawValue, "connection")
        XCTAssertEqual(RequestFailureKind.httpStatus.rawValue, "http_status")
        XCTAssertEqual(RequestFailureKind.redirectRefused.rawValue, "redirect_refused")
        XCTAssertEqual(RequestFailureKind.serviceError.rawValue, "service_error")
        XCTAssertEqual(RequestFailureKind.malformedResponse.rawValue, "malformed_response")
        XCTAssertEqual(RequestFailureKind.incompleteResponse.rawValue, "incomplete_response")
        XCTAssertEqual(RequestFailureKind.requestFailed.rawValue, "request_failed")
    }

    /// A stored source reads back, and the stored spelling is not `SearchProvider`'s.
    func testTheStoredSourceIsTheContractsSpelling() {
        XCTAssertEqual(SearchSource.pubmed.rawValue, "pubmed")
        XCTAssertEqual(SearchSource.europePMC.rawValue, "europepmc")
        XCTAssertNotEqual(SearchSource.europePMC.rawValue, SearchProvider.europePMC.rawValue)
        XCTAssertEqual(SearchSource(rawValue: "europepmc"), .europePMC)
    }

    /// A search of both providers names no single source, so no shortfall can name one.
    func testBothProvidersIsNoSource() {
        XCTAssertNil(SearchSource(provider: .both))
        XCTAssertEqual(SearchSource(provider: .pubmed), .pubmed)
        XCTAssertEqual(SearchSource(provider: .europePMC), .europePMC)
        XCTAssertEqual(SearchSource.europePMC.provider, .europePMC)
    }

    // MARK: - The reason each kind reads as

    /// Every kind has its own reason, and none of them is empty.
    func testEachKindHasItsOwnReason() {
        let reasons: [RequestFailureKind: String] = [
            .timeout: "the request timed out",
            .connection: "the connection failed",
            .serviceError: "the service reported an error",
            .malformedResponse: "the response could not be read",
            .incompleteResponse: "the response was incomplete",
            .requestFailed: "the request failed",
        ]
        for (kind, reason) in reasons {
            XCTAssertEqual(RequestFailure.restored(kind: kind, statusCode: nil).describe(), reason)
        }
        XCTAssertEqual(RequestFailure.forHTTPStatus(503).describe(), "HTTP 503 Service Unavailable")
        XCTAssertEqual(RequestFailure.redirectRefused(statusCode: 307).describe(), "a redirect (HTTP 307) was refused")
        // No two kinds read as the same reason, asked of the production side:
        // asserting it of `reasons` above would only check the literal above.
        let described = RequestFailureKind.allCases.map {
            RequestFailure.restored(kind: $0, statusCode: nil).describe()
        }
        XCTAssertEqual(Set(described).count, RequestFailureKind.allCases.count)
    }

    /// The reason phrases are the contract's, not a library's.
    ///
    /// Foundation's phrases are lowercase and localised, and Python renamed
    /// three of its own, so a platform's own table would read differently on
    /// each platform.
    func testTheReasonPhrasesAreTheContracts() {
        // Every row of the contract's table, spelled out rather than looped over
        // the production table, which would assert only that it equals itself.
        let expected = [
            400: "HTTP 400 Bad Request",
            401: "HTTP 401 Unauthorized",
            403: "HTTP 403 Forbidden",
            404: "HTTP 404 Not Found",
            408: "HTTP 408 Request Timeout",
            413: "HTTP 413 Content Too Large",
            414: "HTTP 414 URI Too Long",
            429: "HTTP 429 Too Many Requests",
            500: "HTTP 500 Internal Server Error",
            502: "HTTP 502 Bad Gateway",
            503: "HTTP 503 Service Unavailable",
            504: "HTTP 504 Gateway Timeout",
            // Not in the table: the status alone, never a library's phrase
            422: "HTTP 422",
            599: "HTTP 599",
        ]
        for (status, clause) in expected {
            XCTAssertEqual(RequestFailure.forHTTPStatus(status).describe(), clause)
        }
    }

    /// An unsuccessful status is an HTTP error, and a redirect a refused one (#243).
    func testAnUnsuccessfulStatusIsAnHTTPErrorAndARedirectARefusedOne() {
        XCTAssertEqual(RequestFailure.forHTTPStatus(429).kind, .httpStatus)
        XCTAssertEqual(RequestFailure.forHTTPStatus(500).kind, .httpStatus)
        for status in [301, 302, 303, 307, 308] {
            XCTAssertEqual(RequestFailure.forHTTPStatus(status).kind, .redirectRefused, "HTTP \(status)")
            XCTAssertEqual(RequestFailure.forHTTPStatus(status).statusCode, status)
        }
    }

    /// A status no HTTP answer could carry is dropped, and the kind stays.
    func testAStatusThatIsNoHTTPStatusIsDropped() {
        XCTAssertNil(RequestFailure.forHTTPStatus(99).statusCode)
        XCTAssertNil(RequestFailure.forHTTPStatus(1000).statusCode)
        XCTAssertNil(RequestFailure.redirectRefused(statusCode: nil).statusCode)
        XCTAssertEqual(RequestFailure.forHTTPStatus(1000).describe(), "an HTTP error")
        XCTAssertEqual(RequestFailure.redirectRefused(statusCode: nil).describe(), "a redirect was refused")
    }

    /// A kind that is no HTTP answer keeps no status, however it is restored.
    func testAStatusOnAFailureThatIsNoHTTPAnswerIsDropped() {
        for kind in RequestFailureKind.allCases where !kind.carriesStatusCode {
            XCTAssertNil(RequestFailure.restored(kind: kind, statusCode: 429).statusCode, kind.rawValue)
        }
        XCTAssertEqual(RequestFailure.restored(kind: .httpStatus, statusCode: 429).statusCode, 429)
    }

    // MARK: - The clause a shortfall reads as

    /// A source that could not be searched is named, and nothing is claimed about its records.
    func testASourceThatCouldNotBeSearchedIsNamed() {
        let shortfall = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))

        XCTAssertNil(shortfall.recordsMissing)
        XCTAssertEqual(shortfall.describe(), "PubMed could not be searched (HTTP 429 Too Many Requests)")
    }

    /// A partial retrieval counts what is missing, thousands grouped.
    func testAPartialRetrievalCountsWhatIsMissing() {
        let shortfall = RetrievalShortfall.missingRecords(1200, from: .europePMC, failure: .timeout)

        XCTAssertEqual(
            shortfall?.describe(),
            "1,200 Europe PMC records could not be retrieved (the request timed out)"
        )
    }

    /// One missing record is singular.
    func testOneMissingRecordIsSingular() {
        let shortfall = RetrievalShortfall.missingRecords(1, from: .pubmed, failure: .malformedResponse)

        XCTAssertEqual(shortfall?.describe(), "1 PubMed record could not be retrieved (the response could not be read)")
    }

    /// Nothing missing is not a shortfall: it would call a complete search incomplete.
    func testNothingMissingIsNotAShortfall() {
        XCTAssertNil(RetrievalShortfall.missingRecords(0, from: .pubmed, failure: .timeout))
        XCTAssertNil(RetrievalShortfall.missingRecords(-1, from: .pubmed, failure: .timeout))
    }

    /// A loss with no reason kept is still recorded, as a failed request.
    func testALossWithoutAReasonIsStillRecorded() {
        let shortfall = RetrievalShortfall.missingRecords(3, from: .pubmed, failure: nil)

        XCTAssertEqual(shortfall?.failure, .requestFailed)
        XCTAssertEqual(shortfall?.recordsMissing, 3)
    }

    /// A shortfall belongs to the search's own query unless it says otherwise.
    func testAShortfallBelongsToTheSearchsOwnQueryUnlessItSaysOtherwise() {
        XCTAssertEqual(RetrievalShortfall(source: .pubmed, failure: .timeout).query, .original)
        XCTAssertEqual(
            RetrievalShortfall.missingRecords(2, from: .pubmed, failure: .timeout)?.query,
            .original
        )
        XCTAssertNil(ShortfallQuery.original.persistedValue)
        XCTAssertEqual(ShortfallQuery.alternative.persistedValue, "alternative")
    }

    /// An alternative search that could not be run says so, not that the source was never searched.
    ///
    /// The original query's results from that source are in the report, so
    /// "PubMed could not be searched" would overstate (user's decision, 2026-09-15).
    func testAnAlternativeSearchThatCouldNotBeRunSaysSo() {
        let shortfall = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429), query: .alternative)

        XCTAssertEqual(
            shortfall.describe(),
            "an alternative search of PubMed could not be completed (HTTP 429 Too Many Requests)"
        )
    }

    /// Records an alternative search lost are counted as its own.
    func testRecordsAnAlternativeSearchLostAreCountedAsItsOwn() {
        let shortfall = RetrievalShortfall.missingRecords(
            25, from: .europePMC, failure: .incompleteResponse, query: .alternative
        )

        XCTAssertEqual(
            shortfall?.describe(),
            "25 Europe PMC records from an alternative search could not be retrieved (the response was incomplete)"
        )
    }

    /// A shortfall can be re-recorded against the query that was being searched.
    func testAShortfallCanBeRecordedAgainstAnotherQuery() {
        let notSearched = RetrievalShortfall(source: .pubmed, failure: .timeout).belongingTo(.alternative)
        let counted = RetrievalShortfall.missingRecords(4, from: .pubmed, failure: .timeout)?
            .belongingTo(.alternative)

        XCTAssertEqual(notSearched.query, .alternative)
        XCTAssertNil(notSearched.recordsMissing)
        XCTAssertEqual(counted?.query, .alternative)
        XCTAssertEqual(counted?.recordsMissing, 4)
    }

    // MARK: - The errors a search raises

    /// A source error names the source and the reason, and carries the shortfall it leaves.
    func testASourceErrorNamesTheSourceAndTheReason() {
        let error = SourceRequestError(source: .europePMC, failure: .forHTTPStatus(503))

        XCTAssertEqual(
            error.errorDescription,
            "Europe PMC could not be searched (HTTP 503 Service Unavailable)"
        )
        XCTAssertEqual(error.shortfall, RetrievalShortfall(source: .europePMC, failure: .forHTTPStatus(503)))
    }

    /// A failed search's message names every shortfall, in order.
    func testAFailedSearchsMessageNamesEveryShortfall() {
        let error = SearchFailedError(shortfalls: [
            RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429)),
            RetrievalShortfall(source: .europePMC, failure: .timeout),
        ])

        XCTAssertEqual(
            error?.errorDescription,
            "The search could not be completed: PubMed could not be searched (HTTP 429 Too Many Requests); "
                + "Europe PMC could not be searched (the request timed out)."
        )
    }

    /// A failed search naming nothing is not a failure: it would tell the user nothing.
    func testAFailedSearchNamingNothingIsRefused() {
        XCTAssertNil(SearchFailedError(shortfalls: []))
    }
}
