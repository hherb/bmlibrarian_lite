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


import BioMedLit
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// What a session keeps about a failed source, and what the reader is shown (#256).
///
/// A failed source is not an empty one: the session records what was lost, the
/// report opens with the notice, and every surface that shows a verdict without
/// the report's text still says the evidence base was partial.
final class SearchShortfallReportingTests: XCTestCase {
    /// The app registers this at launch; a test that builds a `Document` has to
    /// do it too, or its transformable attributes trap.
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    /// PubMed refused a request because too many arrived.
    private let pubMedRateLimited = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))

    /// A report whose text was assembled with these shortfalls.
    private func report(shortfalls: [RetrievalShortfall]) -> EvidenceReport {
        EvidenceReport(
            verdict: .supported,
            summary: "A summary.",
            fullReport: ReportFormatter.fullReport(
                analysis: "## Analysis\n\nThe evidence.",
                references: "1. Smith et al., 2016.",
                shortfalls: shortfalls
            ),
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1
        )
    }

    // MARK: - What the session keeps

    /// What a page lost is kept, and reads back as it was recorded.
    func testWhatAPageLostIsKept() throws {
        let session = FactCheckSession(claim: "A claim")

        try session.recordRetrievalShortfalls([pubMedRateLimited])

        XCTAssertEqual(try session.retrievalShortfalls(), [pubMedRateLimited])
    }

    /// A complete search keeps nothing, so it never reads as a qualified one.
    func testACompleteSearchKeepsNothing() throws {
        let session = FactCheckSession(claim: "A claim")

        try session.recordRetrievalShortfalls([])

        XCTAssertEqual(try session.retrievalShortfalls(), [])
    }

    /// One failure met page after page is kept as one clause, its counts added.
    func testOneFailureMetPageAfterPageIsKeptOnce() throws {
        let session = FactCheckSession(claim: "A claim")
        let firstPage = try XCTUnwrap(
            RetrievalShortfall.missingRecords(10, from: .europePMC, failure: .timeout)
        )
        let secondPage = try XCTUnwrap(
            RetrievalShortfall.missingRecords(15, from: .europePMC, failure: .timeout)
        )

        try session.recordRetrievalShortfalls([firstPage])
        try session.recordRetrievalShortfalls([secondPage])

        let kept = try session.retrievalShortfalls()
        XCTAssertEqual(kept.count, 1)
        XCTAssertEqual(kept.first?.recordsMissing, 25)
    }

    /// An alternative query's loss stays apart from the original query's.
    func testAnAlternativeQuerysLossStaysApart() throws {
        let session = FactCheckSession(claim: "A claim")

        try session.recordRetrievalShortfalls([
            pubMedRateLimited, pubMedRateLimited.belongingTo(.alternative),
        ])

        let kept = try session.retrievalShortfalls()
        XCTAssertEqual(kept.map { $0.query }, [.original, .alternative])
        XCTAssertEqual(
            SearchFailureReporting.describe(kept),
            "PubMed could not be searched (HTTP 429 Too Many Requests); "
                + "an alternative search of PubMed could not be completed (HTTP 429 Too Many Requests)"
        )
    }

    // MARK: - What the reader is shown

    /// An incomplete search's report opens with the notice and records the gap.
    func testTheReportOpensWithTheNoticeAndRecordsTheGap() {
        let text = report(shortfalls: [pubMedRateLimited]).fullReport

        XCTAssertTrue(text.hasPrefix("> **Incomplete search:** PubMed could not be searched"), text)
        XCTAssertTrue(
            text.contains("## Methodology\n\n- **Search Completeness:** Incomplete: "
                + "PubMed could not be searched (HTTP 429 Too Many Requests)"),
            text
        )
        XCTAssertTrue(text.contains("## References"), text)
        XCTAssertLessThan(
            try XCTUnwrap(text.range(of: "## Methodology")).lowerBound,
            try XCTUnwrap(text.range(of: "## References")).lowerBound,
            "the gap is recorded before the references"
        )
    }

    /// A complete search's report is unchanged: no notice, no Methodology section.
    func testACompleteSearchsReportIsUnchanged() {
        let complete = report(shortfalls: [])

        XCTAssertEqual(
            complete.fullReport,
            "## Analysis\n\nThe evidence.\n\n## References\n\n1. Smith et al., 2016."
        )
        XCTAssertNil(complete.incompleteSearchNotice)
        XCTAssertFalse(complete.searchWasIncomplete)
        XCTAssertFalse(complete.plainTextReport.contains("Incomplete search"))
    }

    /// The notice is drawn before the verdict, and taken off the body it opened.
    func testTheNoticeIsDrawnBeforeTheVerdict() throws {
        let incomplete = report(shortfalls: [pubMedRateLimited])

        let notice = try XCTUnwrap(incomplete.incompleteSearchNotice)

        XCTAssertTrue(notice.hasPrefix("Incomplete search: "), notice)
        XCTAssertFalse(notice.contains("**"), "the screen and the PDF draw no Markdown for it")
        XCTAssertTrue(incomplete.reportBodyAfterNotice.hasPrefix("## Analysis"))
        XCTAssertTrue(incomplete.searchWasIncomplete)
    }

    /// The shared text opens with the notice, before the verdict.
    func testTheSharedTextOpensWithTheNotice() throws {
        let shared = report(shortfalls: [pubMedRateLimited]).plainTextReport

        let noticeAt = try XCTUnwrap(shared.range(of: "Incomplete search: ")).lowerBound
        let verdictAt = try XCTUnwrap(shared.range(of: "VERDICT:")).lowerBound

        XCTAssertLessThan(noticeAt, verdictAt)
        XCTAssertFalse(shared.contains("> **Incomplete search:**"), "the shared text draws no Markdown")
    }

    /// A message standing in for a report opens with the same notice.
    func testAMessageStandingInForAReportOpensWithTheNotice() {
        let text = ReportFormatter.standInReport(
            "No documents scored 3 or higher.", shortfalls: [pubMedRateLimited]
        )

        XCTAssertTrue(text.hasPrefix("> **Incomplete search:** "), text)
        XCTAssertTrue(text.hasSuffix("\n\nNo documents scored 3 or higher."), text)
    }
}
