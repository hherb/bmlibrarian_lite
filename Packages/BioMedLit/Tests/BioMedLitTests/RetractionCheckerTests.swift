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

import XCTest
import BmlibCore
@testable import BioMedLit

/// Each paper's verdict from the index, Crossref and its own label, decided by
/// bmlib; and the stored-verdict rules the desktop's `retraction_checks.py`
/// applies (reuse, and an outage never erasing what an answer established).
final class RetractionCheckerTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        StubURLProtocol.stubbed = (200, Self.crossrefBody(""))
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private static func crossrefBody(_ items: String) -> Data {
        Data(#"{"status":"ok","message-type":"work-list","message":{"items":[\#(items)]}}"#.utf8)
    }

    private func checker(index: RetractionIndex?) -> RetractionChecker {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let lookup = RetractionCrossrefLookup(email: "t@example.org", session: URLSession(configuration: config))
        return RetractionChecker(index: index, crossref: lookup)
    }

    private func check(_ paper: RetractionPaper, index: RetractionIndex?) async throws -> PaperRetractionCheck {
        let out = try await checker(index: index).check([paper], now: RetractionFixture.now)
        return try XCTUnwrap(out[paper])
    }

    // MARK: - The checker

    func testNoIdentifierIsUncheckedAndCounted() async throws {
        let paper = RetractionPaper(doi: nil, pmid: nil, publicationTypes: [])
        let out = try await checker(index: try RetractionFixture.index()).check([paper], now: RetractionFixture.now)
        XCTAssertEqual(out.count, 1, "a paper with no identifier still gets a check")
        XCTAssertEqual(out[paper]?.status, "unchecked")
        XCTAssertTrue(out[paper]?.isUnchecked ?? false)
        XCTAssertFalse(out[paper]?.isClear ?? true)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty, "Crossref is not asked without a DOI")
    }

    func testNoIndexMeansExportNotConsulted() async throws {
        let result = try await check(RetractionPaper(doi: "10.1000/x", pmid: nil, publicationTypes: []), index: nil)
        XCTAssertTrue(result.unanswered.contains("retraction_watch_export"), "\(result.unanswered)")
        XCTAssertNotEqual(result.status, "clear")
        XCTAssertNil(result.exportDataAsOf)
    }

    func testRetractedByIndexAlone() async throws {
        // A padded PMID is canonicalised, as the desktop's `canonical_pmid` does.
        let paper = RetractionPaper(doi: nil, pmid: "0111", publicationTypes: [])
        let result = try await check(paper, index: try RetractionFixture.index())
        XCTAssertEqual(result.status, "retracted")
        XCTAssertTrue(result.isRetracted)
        XCTAssertEqual(result.retractionStatus, .retracted)
        XCTAssertEqual(result.deciding?.source, "retraction_watch_export")
        XCTAssertFalse(result.isDecidedByLabel)
        XCTAssertEqual(result.deciding?.kind, "retraction")
        XCTAssertEqual(result.deciding?.recordID, "1")
        XCTAssertEqual(result.deciding?.noticeDOI, "10.1000/notice1")
        XCTAssertEqual(result.exportDataAsOf, RetractionFixture.today)
        XCTAssertNil(result.crossrefFailure)
        XCTAssertTrue(StubURLProtocol.requestedURLs.isEmpty)
    }

    func testLabelAloneRetracts() async throws {
        let paper = RetractionPaper(doi: nil, pmid: nil, publicationTypes: ["Retracted Publication"])
        let result = try await check(paper, index: nil)
        XCTAssertEqual(result.status, "retracted")
        XCTAssertEqual(result.deciding?.source, "pubmed_label")
        XCTAssertTrue(result.isDecidedByLabel)
    }

    /// The reason Crossref is asked at all: a retraction newer than the export.
    func testRetractedByCrossrefAlone() async throws {
        StubURLProtocol.stubbed = (200, Self.crossrefBody(#"""
            {"DOI": "10.1000/newer", "updated-by": [{"DOI": "10.1000/newnotice", "type": "retraction",
             "label": "retraction", "source": "retraction-watch", "updated": {"date-parts": [[2026, 10, 1]]},
             "record-id": 77}]}
            """#))
        let result = try await check(RetractionPaper(doi: "10.1000/newer", pmid: nil, publicationTypes: []),
                                     index: try RetractionFixture.index())
        XCTAssertEqual(result.status, "retracted")
        XCTAssertEqual(result.deciding?.source, "crossref_retraction_watch")
        XCTAssertEqual(result.deciding?.noticeDOI, "10.1000/newnotice")
        XCTAssertEqual(result.deciding?.date, "2026-10-01")
        XCTAssertFalse(result.isDecidedByLabel)
        XCTAssertTrue(result.unanswered.isEmpty)
    }

    func testDocumentsSharingADOIAreAskedOnce() async throws {
        StubURLProtocol.stubbed = (200, Self.crossrefBody(#"{"DOI": "10.1000/shared"}"#))
        let first = RetractionPaper(doi: "10.1000/Shared", pmid: "5", publicationTypes: [])
        let second = RetractionPaper(doi: "https://doi.org/10.1000/shared", pmid: nil, publicationTypes: [])
        let out = try await checker(index: try RetractionFixture.index()).check([first, second], now: RetractionFixture.now)
        XCTAssertEqual(out.count, 2)
        XCTAssertEqual(StubURLProtocol.requestedURLs.count, 1)
        let url = try XCTUnwrap(StubURLProtocol.requestedURLs.first)
        XCTAssertEqual(url.components(separatedBy: "10.1000/shared").count - 1, 1, url)
        XCTAssertEqual(out[first]?.status, "clear")
        XCTAssertEqual(out[second]?.status, "clear")
    }

    /// Control: a served Crossref answer and a consulted, empty index clear a paper.
    func testServedCrossrefAndConsultedEmptyIndexIsClear() async throws {
        StubURLProtocol.stubbed = (200, Self.crossrefBody(#"{"DOI": "10.1000/unknown"}"#))
        let result = try await check(RetractionPaper(doi: "10.1000/unknown", pmid: nil, publicationTypes: []),
                                     index: try RetractionFixture.index())
        XCTAssertEqual(result.status, "clear")
        XCTAssertTrue(result.isClear)
        XCTAssertTrue(result.unanswered.isEmpty)
        XCTAssertEqual(result.exportDataAsOf, RetractionFixture.today)
        XCTAssertNil(result.crossrefFailure)
    }

    func testCrossrefFailureIsStoredAsTheAppsOwnWords() async throws {
        StubURLProtocol.stubbed = (200, Data("not json".utf8))
        let result = try await check(RetractionPaper(doi: "10.1000/unknown", pmid: nil, publicationTypes: []),
                                     index: try RetractionFixture.index())
        XCTAssertEqual(result.unanswered, ["crossref"])
        XCTAssertNotEqual(result.status, "clear")
        XCTAssertEqual(result.crossrefFailure, RequestFailure.malformedResponse.describe())
    }

    func testConcernByIndex() async throws {
        let result = try await check(RetractionPaper(doi: "10.1000/concerned", pmid: nil, publicationTypes: []),
                                     index: try RetractionFixture.index())
        XCTAssertEqual(result.status, "concern")
        XCTAssertTrue(result.isConcern)
    }

    // MARK: - The stored form

    func testStoredCheckRoundTripsThroughJSON() async throws {
        let result = try await check(RetractionPaper(doi: nil, pmid: "111", publicationTypes: []),
                                     index: try RetractionFixture.index())
        let decoded = try JSONDecoder().decode(PaperRetractionCheck.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(decoded, result)
    }

    func testFailedCheckIsUncheckedWithBothLookupsUnanswered() {
        let failed = PaperRetractionCheck.failed(at: RetractionFixture.now)
        XCTAssertEqual(failed.status, "unchecked")
        XCTAssertTrue(failed.isUnchecked)
        XCTAssertNil(failed.deciding)
        XCTAssertEqual(failed.unanswered, ["retraction_watch_export", "crossref"])
        XCTAssertNil(failed.crossrefFailure)
        XCTAssertNil(failed.exportDataAsOf)
        XCTAssertEqual(failed.checkedAt, RetractionFixture.now)
    }

    /// The desktop's `_label_check`: a failed check still retracts by the record's own label.
    func testAFailedCheckStillRetractsByTheRecordsOwnLabel() {
        let labelled = PaperRetractionCheck.failed(
            for: RetractionPaper(doi: "10.1000/x", pmid: nil, publicationTypes: ["Retracted Publication"]),
            at: RetractionFixture.now)
        XCTAssertTrue(labelled.isRetracted)
        XCTAssertTrue(labelled.isDecidedByLabel)
        XCTAssertEqual(labelled.checkedAt, RetractionFixture.now)
        // nothing was asked, so it is never reused in place of asking
        XCTAssertEqual(labelled.unanswered, ["retraction_watch_export", "crossref"])
        // control: without the label a failed check is unchecked, never clear
        XCTAssertEqual(
            PaperRetractionCheck.failed(
                for: RetractionPaper(doi: "10.1000/x", pmid: nil, publicationTypes: ["Journal Article"]),
                at: RetractionFixture.now),
            PaperRetractionCheck.failed(at: RetractionFixture.now))
    }

    func testAnUnknownStatusNameIsUnchecked() {
        let odd = stored(status: "not-a-status")
        XCTAssertEqual(odd.retractionStatus, .unchecked)
        XCTAssertTrue(odd.isUnchecked)
        XCTAssertFalse(odd.isClear)
    }

    // MARK: - Reuse (retraction_checks.py `check`)

    private func stored(
        status: String,
        unanswered: [String] = [],
        daysOld: Double = 1
    ) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status,
            deciding: nil,
            unanswered: unanswered,
            checkedAt: RetractionFixture.now.addingTimeInterval(-daysOld * TransparencyConstants.secondsPerDay),
            exportDataAsOf: nil,
            crossrefFailure: nil
        )
    }

    func testAYoungAnsweredCheckIsReused() {
        XCTAssertTrue(stored(status: "clear").isReusable(now: RetractionFixture.now, publicationTypes: []))
        XCTAssertTrue(stored(status: "clear", daysOld: 7).isReusable(now: RetractionFixture.now, publicationTypes: []))
    }

    func testAnOldCheckIsAskedAgain() {
        XCTAssertFalse(stored(status: "clear", daysOld: 7.01).isReusable(now: RetractionFixture.now, publicationTypes: []))
    }

    func testACheckWithALookupUnansweredIsAskedAgain() {
        XCTAssertFalse(stored(status: "concern", unanswered: ["crossref"])
            .isReusable(now: RetractionFixture.now, publicationTypes: []))
    }

    /// A newer build's status (synced from another device) is checked again,
    /// as the desktop drops such a row; `testAYoungAnsweredCheckIsReused` is the control.
    func testAnUnknownStatusIsAskedAgain() {
        XCTAssertFalse(stored(status: "not-a-status").isReusable(now: RetractionFixture.now, publicationTypes: []))
    }

    /// A newer build's status or lookup name makes a stored check unreadable,
    /// as the desktop's `_decode` (#669).
    func testOnlyKnownStatusAndLookupNamesAreReadable() {
        XCTAssertTrue(stored(status: "concern", unanswered: ["retraction_watch_export", "crossref"]).isReadable)
        XCTAssertFalse(stored(status: "not-a-status").isReadable)
        XCTAssertFalse(stored(status: "retracted", unanswered: ["not-a-lookup"]).isReadable)
    }

    func testAFreshLabelIsNeverHiddenBehindAStoredClear() {
        let types = ["Retracted Publication"]
        XCTAssertFalse(stored(status: "clear").isReusable(now: RetractionFixture.now, publicationTypes: types))
        XCTAssertFalse(stored(status: "concern").isReusable(now: RetractionFixture.now, publicationTypes: types))
        XCTAssertTrue(stored(status: "retracted").isReusable(now: RetractionFixture.now, publicationTypes: types))
    }

    // MARK: - An outage never erases an answer (retraction_checks.py `_keeps`)

    func testAStoredClearStandsAgainstAnOutage() {
        let fresh = stored(status: "unchecked", unanswered: ["crossref"], daysOld: 0)
        XCTAssertTrue(stored(status: "clear").standsAgainst(fresh))
        XCTAssertTrue(stored(status: "retracted").standsAgainst(fresh))
    }

    /// Control: a fresh retraction is news even while a lookup is down.
    func testAFreshRetractionReplacesAStoredClearDuringAnOutage() {
        let fresh = stored(status: "retracted", unanswered: ["crossref"], daysOld: 0)
        XCTAssertFalse(stored(status: "clear").standsAgainst(fresh))
    }

    func testAFreshConcernReplacesAStoredClearDuringAnOutage() {
        let fresh = stored(status: "concern", unanswered: ["crossref"], daysOld: 0)
        XCTAssertFalse(stored(status: "clear").standsAgainst(fresh))
        XCTAssertTrue(stored(status: "retracted").standsAgainst(fresh), "a concern does not outrank a retraction")
    }

    func testAFreshAnswerWithNoNewOutageReplacesTheStoredOne() {
        XCTAssertFalse(stored(status: "retracted").standsAgainst(stored(status: "clear", daysOld: 0)))
        let alreadyDown = stored(status: "concern", unanswered: ["crossref"])
        XCTAssertFalse(alreadyDown.standsAgainst(stored(status: "unchecked", unanswered: ["crossref"], daysOld: 0)))
    }

    // MARK: - What the reader is shown (retraction_checks.py `old if kept else fresh`)

    func testAStoredClearIsNotShownDuringAnOutage() {
        let fresh = stored(status: "unchecked", unanswered: ["crossref"], daysOld: 0)
        let old = stored(status: "clear")
        XCTAssertTrue(old.standsAgainst(fresh), "the stored row is kept")
        XCTAssertEqual(old.shown(against: fresh), fresh, "but the reader sees unchecked, never a stale clear")
    }

    func testAStoredWarningIsShownDuringAnOutage() {
        let fresh = stored(status: "unchecked", unanswered: ["crossref"], daysOld: 0)
        for status in ["retracted", "concern"] {
            let old = stored(status: status)
            XCTAssertEqual(old.shown(against: fresh), old, status)
        }
    }

    func testAFreshCheckThatReplacesTheStoredOneIsShown() {
        let retraction = stored(status: "retracted", unanswered: ["crossref"], daysOld: 0)
        XCTAssertEqual(stored(status: "clear").shown(against: retraction), retraction)
        let answered = stored(status: "clear", daysOld: 0)
        XCTAssertEqual(stored(status: "retracted").shown(against: answered), answered)
    }
}
