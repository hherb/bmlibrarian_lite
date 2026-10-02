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
import SwiftData
@testable import MedicalFactChecker

/// What the screen offers beside a standing report: a red retry only for a
/// failure, and an amber regenerate for citations the report was not made
/// from (#459's review).
@MainActor
final class ReportRetryOfferTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    override func setUp() async throws {
        StringArrayTransformer.register()
        container = try ModelContainer(
            for: Schema(versionedSchema: SchemaV2.self),
            configurations: ModelConfiguration(isStoredInMemoryOnly: true)
        )
        context = ModelContext(container)
    }

    override func tearDown() async throws {
        context = nil
        container = nil
    }

    /// A session holding `citations` citations on one relevant document and,
    /// when `reportedCitations` is given, a report made from that many.
    private func makeSession(citations: Int, reportedCitations: Int?) -> FactCheckSession {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        let document = Document(pmid: "12345678", title: "A Study", abstract: "An abstract.")
        // The top score, so the user's threshold setting cannot exclude it
        document.relevanceScore = 5
        context.insert(document)
        document.session = session
        for index in 0..<citations {
            let citation = Citation(passage: "Passage \(index).")
            context.insert(citation)
            citation.document = document
        }
        if let reportedCitations {
            let report = EvidenceReport(
                verdict: .supported,
                summary: "A summary.",
                fullReport: "## Analysis\n\nThe evidence.",
                citationCount: reportedCitations,
                uniqueSourceCount: 1,
                documentsReviewed: 1,
                searchShortfallsRecord: nil
            )
            report.session = session
            context.insert(report)
            session.report = report
        }
        return session
    }

    private func restore(_ session: FactCheckSession) -> FactCheckWorkflow {
        let workflow = FactCheckWorkflow(
            modelContext: context, modelContainer: container, settings: .shared
        )
        workflow.restoreForViewing(session)
        return workflow
    }

    // MARK: - Citations the report was not made from

    /// Fetching more evidence extracted citations and stopped before its
    /// report: they are offered for a new one, and nothing reads as failed.
    func testCitationsTheReportLacksAreOfferedNotFailed() {
        let workflow = restore(makeSession(citations: 3, reportedCitations: 1))

        XCTAssertEqual(workflow.unreportedCitationCount, 2)
        XCTAssertEqual(workflow.unreportedCitationsNotice, "2 new citations are not in the report yet.")
        XCTAssertFalse(workflow.canRetryReportGeneration)
    }

    func testOneNewCitationIsSingular() {
        let workflow = restore(makeSession(citations: 2, reportedCitations: 1))

        XCTAssertEqual(workflow.unreportedCitationsNotice, "1 new citation is not in the report yet.")
    }

    func testNothingIsOfferedWhenTheReportHasEveryCitation() {
        let workflow = restore(makeSession(citations: 2, reportedCitations: 2))

        XCTAssertEqual(workflow.unreportedCitationCount, 0)
        XCTAssertNil(workflow.unreportedCitationsNotice)
    }

    /// Without a report there is nothing to regenerate.
    func testNothingIsOfferedWithoutAReport() {
        let workflow = restore(makeSession(citations: 2, reportedCitations: nil))

        XCTAssertEqual(workflow.unreportedCitationCount, 0)
        XCTAssertNil(workflow.unreportedCitationsNotice)
    }

    /// Beside a failure the red section's retry regenerates from the same
    /// citations; offering both would ask twice.
    func testAFailureIsOfferedOnlyItsRetry() {
        let session = makeSession(citations: 3, reportedCitations: 1)
        session.errorMessage = "Report generation timed out"
        let workflow = restore(session)

        XCTAssertTrue(workflow.canRetryReportGeneration)
        XCTAssertNil(workflow.unreportedCitationsNotice)
    }

    // MARK: - Messages earlier builds stored

    /// A stopped fetch-more left this beside a report that stood. It is not a
    /// failure, and any citations the batch extracted are offered instead.
    func testAStoredFetchCancelledBesideAReportIsNoFailure() {
        let session = makeSession(citations: 3, reportedCitations: 1)
        session.errorMessage = "Additional evidence fetch cancelled"
        let workflow = restore(session)

        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertNotNil(workflow.unreportedCitationsNotice)
    }

    /// Control: the same text with no report keeps the retry.
    func testAStoredFetchCancelledWithoutAReportKeepsTheRetry() {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.errorMessage = "Additional evidence fetch cancelled"

        XCTAssertTrue(restore(session).canRetryReportGeneration)
    }

    // MARK: - A completed run carries no stop message

    /// A message written to the slot during a run, after the run cleared the
    /// last one, is forgotten when the run completes. Earlier builds wrote a
    /// background pause there while the step under way could still finish.
    ///
    /// The model is unreachable at once and the document's full text is
    /// marked unavailable: extraction fails without a request, which does not
    /// fail the run, and the report says no evidence was found.
    func testAPauseWrittenDuringARunThatCompletesIsForgotten() async throws {
        let session = makeSession(citations: 0, reportedCitations: nil)
        try XCTUnwrap(session.documents?.first).markFullTextUnavailable()
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        workflow.useServices(
            llm: LLMService(
                baseURL: URL(string: "nosuch-scheme://x")!, apiKey: "test-key", model: "test-model"
            ),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        workflow.onProgress = { _, _ in
            session.errorMessage = "Paused: App was backgrounded"
        }

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNil(session.errorMessage)
    }
}
