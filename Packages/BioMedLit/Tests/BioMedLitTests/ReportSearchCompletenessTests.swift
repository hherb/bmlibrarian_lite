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
import XCTest
@testable import BioMedLit

/// What a report records about the search behind it, as data rather than prose (#284).
///
/// A report used to answer "was the search complete?" by matching its own
/// rendered text, so anything that rewrote the text answered for it: a
/// regeneration, an export round-trip, or a model whose analysis happened to
/// open with the notice's own words.
final class ReportSearchCompletenessTests: XCTestCase {
    /// PubMed refused a request because too many arrived.
    private let pubMedRateLimited = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))

    // MARK: - The record a report keeps

    /// A complete search is written down, so it can be told from a report that
    /// records nothing at all.
    func testACompleteSearchIsRecordedAsAnEmptyList() throws {
        XCTAssertEqual(try SearchFailureReporting.reportRecord(for: []), "[]")
    }

    /// What was lost is written in the contract's persisted form.
    func testAnIncompleteSearchRecordsWhatItLost() throws {
        let record = try SearchFailureReporting.reportRecord(for: [pubMedRateLimited])
        XCTAssertEqual(try SearchFailureReporting.shortfalls(fromJSON: record), [pubMedRateLimited])
    }

    // MARK: - Reading it back

    /// The stored record answers, not the text.
    func testARecordedCompleteSearchReadsAsCompleteWhateverTheTextSays() {
        let completeness = ReportSearchCompleteness(
            record: "[]",
            reportText: SearchFailureConstants.noticeOpening
                + "PubMed could not be searched."
                + SearchFailureConstants.noticeClosing
                + SearchFailureConstants.noticeSeparator
                + "The analysis."
        )

        XCTAssertFalse(completeness.wasIncomplete)
        XCTAssertNil(completeness.notice)
    }

    /// A model that opens its analysis with the notice's own words does not make
    /// a complete search read as incomplete, and none of its text is taken away.
    func testACompleteSearchsReportKeepsEveryWordOfItsText() {
        let analysis = SearchFailureConstants.noticeOpening
            + "the phrase this model chose."
            + SearchFailureConstants.noticeSeparator
            + "The analysis."
        let completeness = ReportSearchCompleteness(record: "[]", reportText: analysis)

        XCTAssertEqual(completeness.bodyAfterNotice, analysis)
    }

    /// An incomplete search's notice is taken off the body for the surfaces that
    /// draw it ahead of the verdict, exactly as before.
    func testAnIncompleteSearchsNoticeIsStillSeparatedFromTheBody() throws {
        let text = SearchFailureReporting.withNotice("The analysis.", shortfalls: [pubMedRateLimited])
        let completeness = ReportSearchCompleteness(
            record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited]),
            reportText: text
        )

        XCTAssertTrue(completeness.wasIncomplete)
        XCTAssertEqual(
            completeness.notice,
            SearchFailureReporting.plainNotice(SearchFailureReporting.notice(for: [pubMedRateLimited]))
        )
        XCTAssertEqual(completeness.bodyAfterNotice, "The analysis.")
    }

    /// A report whose text no longer opens with the notice — rewritten, or saved
    /// back from an export that moved it — still tells the reader what was lost,
    /// because the record says so and the notice can be written again from it.
    func testAnIncompleteSearchWhoseTextLostItsNoticeStillShowsOne() throws {
        let completeness = ReportSearchCompleteness(
            record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited]),
            reportText: "The analysis."
        )

        XCTAssertTrue(completeness.wasIncomplete)
        XCTAssertEqual(
            completeness.notice,
            SearchFailureReporting.plainNotice(SearchFailureReporting.notice(for: [pubMedRateLimited]))
        )
        XCTAssertEqual(completeness.bodyAfterNotice, "The analysis.")
    }

    // MARK: - Reports written before the record existed

    /// A report saved before this shipped records nothing, and its own text is
    /// all there is to read: it is the text the app itself wrote.
    func testAReportWithNoRecordIsReadOffItsText() {
        let text = SearchFailureReporting.withNotice("The analysis.", shortfalls: [pubMedRateLimited])
        let completeness = ReportSearchCompleteness(record: nil, reportText: text)

        XCTAssertTrue(completeness.wasIncomplete)
        XCTAssertEqual(
            completeness.notice,
            SearchFailureReporting.plainNotice(SearchFailureReporting.notice(for: [pubMedRateLimited]))
        )
        XCTAssertEqual(completeness.bodyAfterNotice, "The analysis.")
    }

    /// And one whose text carries no notice reads as complete, as it did before.
    func testAReportWithNoRecordAndNoNoticeReadsAsComplete() {
        let completeness = ReportSearchCompleteness(record: nil, reportText: "The analysis.")

        XCTAssertFalse(completeness.wasIncomplete)
        XCTAssertNil(completeness.notice)
        XCTAssertEqual(completeness.bodyAfterNotice, "The analysis.")
    }

    // MARK: - A record that cannot be read

    /// A damaged record never reads as a complete search: the report cannot say
    /// what its evidence base was missing, and says that instead.
    func testADamagedRecordIsNotACompleteSearch() {
        let completeness = ReportSearchCompleteness(record: "{not json", reportText: "The analysis.")

        XCTAssertTrue(completeness.wasIncomplete)
        XCTAssertEqual(completeness.notice, SearchFailureConstants.unreadableRecordNotice)
    }

    /// A record naming a provider no build knows is damaged in the same way: the
    /// reading side refuses it rather than dropping the entry (#256).
    func testARecordNamingNoKnownProviderIsDamaged() {
        let completeness = ReportSearchCompleteness(
            record: #"[{"provider":"scopus","failure":{"kind":"timeout"}}]"#,
            reportText: "The analysis."
        )

        XCTAssertTrue(completeness.wasIncomplete)
        XCTAssertEqual(completeness.notice, SearchFailureConstants.unreadableRecordNotice)
    }

    /// A damaged record leaves the text alone: nothing may be taken off a body
    /// on the strength of a record that could not be read.
    func testADamagedRecordLeavesTheTextAlone() {
        let text = SearchFailureReporting.withNotice("The analysis.", shortfalls: [pubMedRateLimited])
        let completeness = ReportSearchCompleteness(record: "{not json", reportText: text)

        XCTAssertEqual(completeness.bodyAfterNotice, text)
    }
}
