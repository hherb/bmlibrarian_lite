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

/// How an incomplete search reaches the reader, and how it is kept (#256).
///
/// The notice, the Methodology line, the advice and the stored form are the
/// contract's (`doc/cross_platform/search_failure_reporting.md`); Android and
/// Python hold the same ones.
final class SearchFailureReportingTests: XCTestCase {
    /// PubMed refused a request because too many arrived.
    private let pubMedRateLimited = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))

    /// Europe PMC did not answer in time.
    private let europePMCTimedOut = RetrievalShortfall(source: .europePMC, failure: .timeout)

    // MARK: - Combining

    /// The same failure of the same source is reported once, its counts added.
    func testTheSameFailureOfTheSameSourceIsReportedOnce() {
        let combined = SearchFailureReporting.combined([
            RetrievalShortfall.missingRecords(10, from: .pubmed, failure: .timeout),
            RetrievalShortfall.missingRecords(15, from: .pubmed, failure: .timeout),
            RetrievalShortfall.missingRecords(5, from: .europePMC, failure: .timeout),
        ].compactMap { $0 })

        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined[0].source, .pubmed)
        XCTAssertEqual(combined[0].recordsMissing, 25)
        XCTAssertEqual(combined[1].source, .europePMC)
        XCTAssertEqual(combined[1].recordsMissing, 5)
    }

    /// Two failures of different kinds stay apart, each with its own reason.
    func testDifferentFailuresOfOneSourceStayApart() {
        let combined = SearchFailureReporting.combined([
            RetrievalShortfall.missingRecords(10, from: .pubmed, failure: .timeout),
            RetrievalShortfall.missingRecords(4, from: .pubmed, failure: .malformedResponse),
        ].compactMap { $0 })

        XCTAssertEqual(combined.map { $0.recordsMissing }, [10, 4])
    }

    /// A source that could not be searched is never merged into a count.
    func testASourceThatCouldNotBeSearchedIsNotMergedIntoACount() {
        let counted = RetrievalShortfall.missingRecords(10, from: .pubmed, failure: .timeout)
        let notSearched = RetrievalShortfall(source: .pubmed, failure: .timeout)

        let combined = SearchFailureReporting.combined([counted, notSearched].compactMap { $0 })

        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined.map { $0.recordsMissing }, [10, nil])
    }

    /// A source that could not be searched is reported once, however often it failed.
    func testASourceThatCouldNotBeSearchedIsReportedOnce() {
        let combined = SearchFailureReporting.combined([
            pubMedRateLimited, pubMedRateLimited, pubMedRateLimited,
        ])

        XCTAssertEqual(combined, [pubMedRateLimited])
    }

    /// An alternative search that failed the same way is reported once, however many queries failed.
    func testAnAlternativeSearchIsReportedOnceHoweverManyQueriesFailed() {
        let failed = pubMedRateLimited.belongingTo(.alternative)

        let combined = SearchFailureReporting.combined([failed, failed, failed])

        XCTAssertEqual(combined, [failed])
        XCTAssertEqual(
            SearchFailureReporting.describe(combined),
            "an alternative search of PubMed could not be completed (HTTP 429 Too Many Requests)"
        )
    }

    /// An alternative search's loss is never merged into the original query's.
    func testAnAlternativeSearchsLossIsNotMergedIntoTheOriginalQuerys() {
        let original = RetrievalShortfall.missingRecords(10, from: .pubmed, failure: .timeout)
        let alternative = RetrievalShortfall.missingRecords(
            5, from: .pubmed, failure: .timeout, query: .alternative
        )

        let combined = SearchFailureReporting.combined([original, alternative].compactMap { $0 })

        XCTAssertEqual(combined.count, 2)
        XCTAssertEqual(combined.map { $0.query }, [.original, .alternative])
        XCTAssertEqual(combined.map { $0.recordsMissing }, [10, 5])
    }

    /// Counts too large to add stay apart, neither overflowing nor cut short (golden rule 6).
    func testCountsTooLargeToAddAreKeptApart() {
        let huge = RetrievalShortfall.missingRecords(Int.max, from: .pubmed, failure: .timeout)
        let one = RetrievalShortfall.missingRecords(1, from: .pubmed, failure: .timeout)

        let combined = SearchFailureReporting.combined([huge, one].compactMap { $0 })

        XCTAssertEqual(combined.map { $0.recordsMissing }, [Int.max, 1])
    }

    /// Every shortfall's clause survives, in the order it was recorded.
    func testTheCombinedDescriptionKeepsEveryShortfallInOrder() {
        XCTAssertEqual(
            SearchFailureReporting.describe([pubMedRateLimited, europePMCTimedOut]),
            "PubMed could not be searched (HTTP 429 Too Many Requests); "
                + "Europe PMC could not be searched (the request timed out)"
        )
        XCTAssertEqual(SearchFailureReporting.describe([]), "")
    }

    // MARK: - The notice

    /// A complete search adds no notice, so it never reads as a qualified one.
    func testNoShortfallAddsNoNotice() {
        XCTAssertEqual(SearchFailureReporting.notice(for: []), "")
        XCTAssertEqual(SearchFailureReporting.withNotice("The report.", shortfalls: []), "The report.")
        XCTAssertNil(SearchFailureReporting.incompleteSearchWarning([]))
        XCTAssertFalse(SearchFailureReporting.isIncompleteSearchReport("The report."))
    }

    /// The notice says the search was incomplete, why, and what the text below rests on.
    func testTheNoticeSaysTheSearchWasIncompleteAndWhy() {
        XCTAssertEqual(
            SearchFailureReporting.notice(for: [pubMedRateLimited]),
            "> **Incomplete search:** PubMed could not be searched (HTTP 429 Too Many Requests). "
                + "Everything below rests only on the records that were retrieved."
        )
    }

    /// The notice is followed by a blank line and the text it precedes.
    func testTheNoticeIsFollowedByABlankLineAndTheText() {
        let text = SearchFailureReporting.withNotice("The report.", shortfalls: [pubMedRateLimited])

        XCTAssertTrue(text.hasSuffix("\n\nThe report."), text)
        XCTAssertTrue(SearchFailureReporting.isIncompleteSearchReport(text))
    }

    /// The notice and the text behind it can be told apart again.
    func testTheNoticeAndTheTextBehindItCanBeToldApart() {
        let text = SearchFailureReporting.withNotice("The report.\n\nMore.", shortfalls: [pubMedRateLimited])

        let (notice, body) = SearchFailureReporting.splitNotice(text)

        XCTAssertEqual(notice, SearchFailureReporting.notice(for: [pubMedRateLimited]))
        XCTAssertEqual(body, "The report.\n\nMore.")
    }

    /// A text without the notice is left alone.
    func testATextWithoutTheNoticeIsLeftAlone() {
        let (notice, body) = SearchFailureReporting.splitNotice("The report.\n\nMore.")

        XCTAssertNil(notice)
        XCTAssertEqual(body, "The report.\n\nMore.")
    }

    /// The notice reads as plain text for a surface that draws no Markdown.
    func testTheNoticeReadsAsPlainTextForAScreenOrAPDF() {
        let text = SearchFailureReporting.withNotice("The report.", shortfalls: [pubMedRateLimited])

        let (notice, body) = SearchFailureReporting.splitPlainNotice(text)

        XCTAssertEqual(
            notice,
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests). "
                + "Everything below rests only on the records that were retrieved."
        )
        XCTAssertEqual(body, "The report.")
    }

    /// The warning an incomplete search shows while it proceeds names what failed.
    func testTheWarningAnIncompleteSearchShowsNamesWhatFailed() {
        XCTAssertEqual(
            SearchFailureReporting.incompleteSearchWarning([pubMedRateLimited]),
            "Incomplete search: PubMed could not be searched (HTTP 429 Too Many Requests)."
        )
    }

    // MARK: - The Methodology line

    /// The Methodology section records what is missing, and only that.
    func testTheMethodologyRecordsWhatIsMissing() {
        XCTAssertEqual(
            SearchFailureReporting.searchCompletenessMethodology([pubMedRateLimited]),
            "## Methodology\n\n- **Search Completeness:** Incomplete: "
                + "PubMed could not be searched (HTTP 429 Too Many Requests)"
        )
    }

    /// A complete search adds no Methodology section.
    func testACompleteSearchAddsNoMethodology() {
        XCTAssertEqual(SearchFailureReporting.searchCompletenessMethodology([]), "")
    }

    // MARK: - What to do next

    /// The failure message adds the advice after a blank line.
    func testTheFailureMessageAddsTheAdviceAfterABlankLine() {
        let error = SearchFailedError(shortfalls: [pubMedRateLimited])

        XCTAssertEqual(
            error.map(SearchFailureReporting.failureMessage),
            "The search could not be completed: PubMed could not be searched (HTTP 429 Too Many Requests).\n\n"
                + "The service is limiting how often it can be searched: wait a minute and try again. "
                + "An NCBI API key, set in Settings, raises PubMed's limit."
        )
    }

    /// The advice fits the failure, each sentence at most once and in the contract's order.
    func testTheAdviceFitsTheFailure() {
        let europePMCRateLimited = RetrievalShortfall(source: .europePMC, failure: .forHTTPStatus(429))
        let pubMedRefused = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(400))
        let serviceError = RetrievalShortfall(source: .pubmed, failure: .serviceError)
        let connectionFailed = RetrievalShortfall(source: .europePMC, failure: .connection)

        XCTAssertEqual(
            SearchFailureReporting.advice(for: [europePMCRateLimited]),
            "The service is limiting how often it can be searched: wait a minute and try again."
        )
        XCTAssertEqual(
            SearchFailureReporting.advice(for: [pubMedRefused]),
            "If an NCBI API key is set in Settings, check that it is correct: "
                + "PubMed refuses a request whose key it does not accept."
        )
        XCTAssertEqual(
            SearchFailureReporting.advice(for: [serviceError]),
            "If it happens again, rephrase the question: the service may be unable to process the query."
        )
        XCTAssertEqual(
            SearchFailureReporting.advice(for: [connectionFailed, europePMCTimedOut]),
            "Check the internet connection and try again."
        )
        XCTAssertEqual(
            SearchFailureReporting.advice(for: [RetrievalShortfall(source: .pubmed, failure: .malformedResponse)]),
            "Try again later."
        )
        XCTAssertEqual(SearchFailureReporting.advice(for: []), "Try again later.")
        XCTAssertEqual(
            SearchFailureReporting.advice(for: [pubMedRateLimited, serviceError, connectionFailed]),
            "The service is limiting how often it can be searched: wait a minute and try again. "
                + "An NCBI API key, set in Settings, raises PubMed's limit. "
                + "If it happens again, rephrase the question: the service may be unable to process the query. "
                + "Check the internet connection and try again."
        )
    }

    /// Only PubMed's own refusal asks about the NCBI key.
    func testOnlyPubMedsRefusalAsksAboutTheKey() {
        let europePMCRefused = RetrievalShortfall(source: .europePMC, failure: .forHTTPStatus(403))

        XCTAssertEqual(SearchFailureReporting.advice(for: [europePMCRefused]), "Try again later.")
    }

    // MARK: - The stored form

    /// Shortfalls survive the round trip, every field included.
    func testShortfallsSurviveTheRoundTrip() throws {
        let shortfalls = [
            pubMedRateLimited,
            RetrievalShortfall.missingRecords(1200, from: .europePMC, failure: .incompleteResponse),
            RetrievalShortfall(source: .pubmed, failure: .redirectRefused(statusCode: 307), query: .alternative),
        ].compactMap { $0 }

        let stored = try XCTUnwrap(SearchFailureReporting.json(from: shortfalls))

        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: stored), shortfalls)
    }

    /// The stored form is the contract's: its keys, its values, its provider strings.
    func testTheStoredFormIsTheContracts() throws {
        let stored = try XCTUnwrap(SearchFailureReporting.json(from: [pubMedRateLimited]))
        let entries = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(stored.utf8)) as? [[String: Any]]
        )

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries[0]["provider"] as? String, "pubmed")
        XCTAssertTrue(entries[0]["records_missing"] is NSNull)
        XCTAssertNil(entries[0]["query"], "the original query stores no marker")
        let failure = try XCTUnwrap(entries[0]["failure"] as? [String: Any])
        XCTAssertEqual(failure["kind"] as? String, "http_status")
        XCTAssertEqual(failure["status_code"] as? Int, 429)
    }

    /// An alternative search's shortfall is marked, and the original query's is not.
    func testAnAlternativeSearchsShortfallIsMarked() throws {
        let stored = try XCTUnwrap(
            SearchFailureReporting.json(from: [pubMedRateLimited.belongingTo(.alternative)])
        )

        XCTAssertTrue(stored.contains("\"query\":\"alternative\""), stored)
        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: stored).map { $0.query }, [.alternative])
    }

    /// A query marker this build does not know reads as the original query.
    ///
    /// Its clause claims more is missing, never less.
    func testAnUnknownQueryMarkerReadsAsTheOriginalQuery() throws {
        let stored = """
            [{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":null,"query":"supplementary"}]
            """

        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: stored).map { $0.query }, [.original])
    }

    /// A complete search stores nothing, and nothing stored reads as complete.
    func testACompleteSearchStoresNothing() throws {
        XCTAssertNil(SearchFailureReporting.json(from: []))
        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: nil), [])
        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: "[]"), [])
    }

    /// An unreadable field degrades, and the shortfall stays.
    func testAnUnreadableFieldDegradesButTheShortfallStays() throws {
        let cases: [(stored: String, kind: RequestFailureKind, status: Int?, missing: Int?)] = [
            (#"[{"provider":"pubmed","failure":{"kind":"teapot"}}]"#, .requestFailed, nil, nil),
            (#"[{"provider":"pubmed"}]"#, .requestFailed, nil, nil),
            (#"[{"provider":"pubmed","failure":"timeout"}]"#, .requestFailed, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"http_status","status_code":true}}]"#, .httpStatus, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"http_status","status_code":42}}]"#, .httpStatus, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"http_status","status_code":"429"}}]"#, .httpStatus, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"timeout","status_code":429}}]"#, .timeout, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":true}]"#, .timeout, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":0}]"#, .timeout, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":1.5}]"#, .timeout, nil, nil),
            (#"[{"provider":"pubmed","failure":{"kind":"timeout"},"records_missing":7}]"#, .timeout, nil, 7),
        ]

        for (stored, kind, status, missing) in cases {
            let shortfalls = try SearchFailureReporting.shortfalls(fromJSON: stored)

            XCTAssertEqual(shortfalls.count, 1, stored)
            XCTAssertEqual(shortfalls.first?.failure.kind, kind, stored)
            XCTAssertEqual(shortfalls.first?.failure.statusCode, status, stored)
            XCTAssertEqual(shortfalls.first?.recordsMissing, missing, stored)
        }
    }

    /// A malformed record is refused, not dropped: a report must not claim a complete search.
    func testAMalformedEntryIsRefusedNotDropped() {
        let refused = [
            "not json",
            "null",
            #"{"provider":"pubmed"}"#,
            #"["pubmed"]"#,
            #"[{"provider":"both"}]"#,
            #"[{"provider":"europePMC"}]"#,
            #"[{"provider":null}]"#,
        ]

        for stored in refused {
            XCTAssertThrowsError(try SearchFailureReporting.shortfalls(fromJSON: stored), stored) { error in
                XCTAssertTrue(error is DamagedShortfallRecordError, stored)
            }
        }
    }
}
