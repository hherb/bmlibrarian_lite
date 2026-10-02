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
import BioMedLit
@testable import MedicalFactChecker

/// Where a per-document transparency failure is reported (#459).
///
/// It used to be written to the session's `errorMessage`, which the screen
/// reads as a failed run: a finished report sat under a red "Report
/// Generation Failed" section with a retry button.
@MainActor
final class TransparencyNoticeTests: XCTestCase {
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

    private struct Boom: Error {}

    /// A session whose one document is scored, cited and analysable, held by a
    /// workflow as a finished run is.
    private func makeWorkflow(title: String = "A Study") -> (FactCheckWorkflow, FactCheckSession) {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        let document = Document(pmid: "12345678", title: title, abstract: "An abstract.")
        // The top score, so the user's threshold setting cannot exclude it
        document.relevanceScore = 5
        // A DOI, not the PMID slot: a bare number does not state a PubMed ID
        document.doi = "10.1000/example"
        context.insert(document)
        document.session = session
        let citation = Citation(passage: "A passage.")
        context.insert(citation)
        citation.document = document

        let workflow = FactCheckWorkflow(
            modelContext: context, modelContainer: container, settings: .shared
        )
        workflow.restoreForViewing(session)
        return (workflow, session)
    }

    private func result() -> TransparencyResult {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        return builder.build()
    }

    func testAFailedAnalysisIsANoticeNotAFailedRun() async {
        let (workflow, session) = makeWorkflow(title: "Alpha")

        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })

        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertEqual(workflow.transparencyNotice, "Transparency analysis failed for: Alpha")
    }

    /// Control: the fixture is one the retry section is offered for, so the
    /// test above is not passing on a session that could never show it.
    func testTheFixtureOffersARetryWhenTheRunFailed() {
        let (workflow, session) = makeWorkflow()

        session.errorMessage = "Report generation timed out"

        XCTAssertTrue(workflow.canRetryReportGeneration)
    }

    /// The run's own failure and the per-document notice are both shown;
    /// neither takes the other's place.
    func testARunFailureIsKeptBesideTheNotice() async {
        let (workflow, session) = makeWorkflow(title: "Alpha")
        session.errorMessage = "Report generation timed out"

        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })

        XCTAssertEqual(session.errorMessage, "Report generation timed out")
        XCTAssertNotNil(workflow.transparencyNotice)
    }

    func testASuccessfulPassStoresTheResultAndClearsTheNotice() async throws {
        let (workflow, session) = makeWorkflow()
        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })
        XCTAssertNotNil(workflow.transparencyNotice)

        await workflow.analyzeTransparency(using: { [result = result()] _, _, _ in result })

        XCTAssertNil(workflow.transparencyNotice)
        let document = try XCTUnwrap(session.documents?.first)
        XCTAssertTrue(document.hasTransparencyAnalysis)
    }

    /// A result that cannot be encoded leaves the document without a badge,
    /// as a thrown error does, so the reader is told about it the same way.
    func testAResultThatCannotBeStoredIsReported() async {
        let (workflow, _) = makeWorkflow(title: "Alpha")
        var builder = TransparencyResultBuilder(pmid: "12345678")
        // JSONEncoder refuses a non-finite number
        builder.industryFundingConfidence = .nan
        let unstorable = builder.build()

        await workflow.analyzeTransparency(using: { _, _, _ in unstorable })

        XCTAssertEqual(workflow.transparencyNotice, "Transparency analysis failed for: Alpha")
    }

    func testCancellingIsNotReportedAsAFailure() async {
        let (workflow, session) = makeWorkflow()

        await workflow.analyzeTransparency(using: { _, _, _ in throw CancellationError() })

        XCTAssertNil(workflow.transparencyNotice)
        XCTAssertNil(session.errorMessage)
    }

    // MARK: - Sessions stored by earlier builds

    /// Builds before #459 stored the notice as the session's `errorMessage`.
    func testAStoredNoticeOffersNoRetryAndIsShownAsTheNotice() {
        let (_, session) = makeWorkflow()
        let stored = FactCheckWorkflow.transparencyFailureNotice(for: ["Alpha"])
        session.errorMessage = stored

        let workflow = FactCheckWorkflow(
            modelContext: context, modelContainer: container, settings: .shared
        )
        workflow.restoreForViewing(session)

        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertEqual(workflow.transparencyNotice, stored)
        // Viewing does not rewrite the store
        XCTAssertEqual(session.errorMessage, stored)
    }

    func testBothStoredFormsAreRecognised() {
        XCTAssertTrue(FactCheckWorkflow.isStoredTransparencyNotice(
            FactCheckWorkflow.transparencyFailureNotice(for: ["Alpha"])
        ))
        XCTAssertTrue(FactCheckWorkflow.isStoredTransparencyNotice(
            FactCheckWorkflow.transparencyFailureNotice(for: ["a", "b", "c", "d"])
        ))
    }

    /// Control: a run's own failure is not mistaken for one.
    func testARunFailureIsNotAStoredNotice() {
        XCTAssertFalse(FactCheckWorkflow.isStoredTransparencyNotice("Report generation timed out"))
        XCTAssertFalse(FactCheckWorkflow.isStoredTransparencyNotice("Cancelled"))
    }

    // MARK: - Wording

    // Pinned whole: earlier builds stored these exact sentences, and a session
    // holding one is recognised only while the wording still matches.

    func testAShortFailureListIsNamed() {
        XCTAssertEqual(
            FactCheckWorkflow.transparencyFailureNotice(for: ["Alpha", "Beta"]),
            "Transparency analysis failed for: Alpha; Beta"
        )
    }

    func testALongFailureListIsCounted() {
        XCTAssertEqual(
            FactCheckWorkflow.transparencyFailureNotice(for: ["a", "b", "c", "d"]),
            "Transparency analysis could not be completed for 4 documents"
        )
    }
}
