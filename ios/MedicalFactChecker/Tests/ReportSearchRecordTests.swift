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


import BioMedLit
import Foundation
import SwiftData
import XCTest
@testable import MedicalFactChecker

/// A stored report answers for its own search from what it recorded (#284).
///
/// The history list's marker, the notice every report surface draws before the
/// verdict, and the body the reader is shown all used to be decided by matching
/// the report's own text. The record decides now; the text is asked only where
/// its notice ends, and only for a report that recorded nothing.
final class ReportSearchRecordTests: XCTestCase {
    /// PubMed refused a request because too many arrived.
    private let pubMedRateLimited = RetrievalShortfall(source: .pubmed, failure: .forHTTPStatus(429))

    private func report(text: String, record: String?) -> EvidenceReport {
        EvidenceReport(
            verdict: .supported,
            summary: "A summary.",
            fullReport: text,
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1,
            searchShortfallsRecord: record
        )
    }

    // MARK: - A complete search

    /// A model whose analysis opens with the notice's own words does not make a
    /// complete search read as incomplete, and keeps every word of its text.
    func testAModelWritingTheNoticesWordsDoesNotMakeTheSearchIncomplete() throws {
        let analysis = "> **Incomplete search:** is a phrase this model chose.\n\nThe analysis."
        let stored = report(text: analysis, record: try SearchFailureReporting.reportRecord(for: []))

        XCTAssertFalse(stored.searchWasIncomplete)
        XCTAssertNil(stored.incompleteSearchNotice)
        XCTAssertEqual(stored.reportBodyAfterNotice, analysis)
    }

    // MARK: - An incomplete search

    /// What the search lost is stored with the report and read back from it.
    func testAnIncompleteSearchsReportSaysSoFromItsRecord() throws {
        let text = ReportFormatter.standInReport("The analysis.", shortfalls: [pubMedRateLimited])
        let stored = report(
            text: text, record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited])
        )

        XCTAssertTrue(stored.searchWasIncomplete)
        XCTAssertEqual(
            stored.incompleteSearchNotice,
            SearchFailureReporting.plainNotice(SearchFailureReporting.notice(for: [pubMedRateLimited]))
        )
        XCTAssertEqual(stored.reportBodyAfterNotice, "The analysis.")
    }

    /// A report whose text was rewritten without its notice — saved back from an
    /// export that moved it, or regenerated — still tells the reader what was
    /// lost, because the record still says so.
    func testAReportWhoseTextLostItsNoticeStillCarriesOne() throws {
        let stored = report(
            text: "The analysis.",
            record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited])
        )

        XCTAssertTrue(stored.searchWasIncomplete)
        XCTAssertNotNil(stored.incompleteSearchNotice)
    }

    /// The shared text carries the notice ahead of the verdict, wherever the
    /// notice came from — here, from the record rather than the text.
    func testTheSharedTextCarriesTheNoticeBeforeTheVerdict() throws {
        let stored = report(
            text: "The analysis.",
            record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited])
        )
        let shared = stored.plainTextReport

        let notice = try XCTUnwrap(shared.range(of: try XCTUnwrap(stored.incompleteSearchNotice)))
        let verdict = try XCTUnwrap(shared.range(of: "VERDICT:"))
        XCTAssertLessThan(notice.lowerBound, verdict.lowerBound)
    }

    // MARK: - Reports saved before the record existed

    /// Such a report has only its own text, which this app wrote, notice included.
    func testAReportSavedBeforeTheRecordIsReadOffItsText() {
        let text = ReportFormatter.standInReport("The analysis.", shortfalls: [pubMedRateLimited])
        let stored = report(text: text, record: nil)

        XCTAssertTrue(stored.searchWasIncomplete)
        XCTAssertEqual(stored.reportBodyAfterNotice, "The analysis.")
    }

    /// And one that carries no notice reads as complete, as it did before.
    func testAReportSavedBeforeTheRecordWithNoNoticeReadsAsComplete() {
        let stored = report(text: "The analysis.", record: nil)

        XCTAssertFalse(stored.searchWasIncomplete)
        XCTAssertNil(stored.incompleteSearchNotice)
    }

    // MARK: - A record that cannot be read

    /// A damaged record never reads as a complete search.
    func testADamagedRecordNeverReadsAsACompleteSearch() {
        let stored = report(text: "The analysis.", record: "{not json")

        XCTAssertTrue(stored.searchWasIncomplete)
        XCTAssertEqual(stored.incompleteSearchNotice, ReportSearchCompleteness.unreadableRecordNotice)
    }

    // MARK: - Writing the record

    /// The record survives being stored and read back through SwiftData, which
    /// is the hop that decides what every later surface sees.
    func testTheRecordSurvivesTheStore() throws {
        StringArrayTransformer.register()
        let schema = Schema(versionedSchema: SchemaV2.self)
        let container = try ModelContainer(
            for: schema,
            configurations: [ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)]
        )
        let context = ModelContext(container)
        let stored = report(
            text: "The analysis.",
            record: try SearchFailureReporting.reportRecord(for: [pubMedRateLimited])
        )
        context.insert(stored)
        try context.save()

        let readBack = try XCTUnwrap(try context.fetch(FetchDescriptor<EvidenceReport>()).first)
        XCTAssertTrue(readBack.searchWasIncomplete)
    }
}
