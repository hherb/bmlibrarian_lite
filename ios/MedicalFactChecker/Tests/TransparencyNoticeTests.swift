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

/// Where a missing transparency rating is reported (#459).
///
/// A per-document failure used to be written to the session's `errorMessage`,
/// which the screen reads as a failed run: a finished report sat under a red
/// "Report Generation Failed" section with a retry button.
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

    /// A scored, cited document the transparency step analyses.
    ///
    /// Its DOI, not its PMID slot, makes it analysable: a bare number states
    /// no PubMed ID, so without a DOI ``Document/canAnalyzeTransparency``
    /// would exclude it.
    @discardableResult
    private func addDocument(
        _ title: String, doi: String? = nil, to session: FactCheckSession
    ) -> Document {
        let document = Document(pmid: "12345678", title: title, abstract: "An abstract.")
        // The top score, so the user's threshold setting cannot exclude it
        document.relevanceScore = 5
        document.doi = doi ?? "10.1000/\(title)"
        context.insert(document)
        document.session = session
        let citation = Citation(passage: "A passage.")
        context.insert(citation)
        citation.document = document
        return document
    }

    private func attachReport(to session: FactCheckSession) {
        let report = EvidenceReport(
            verdict: .supported,
            summary: "A summary.",
            fullReport: "## Analysis\n\nThe evidence.",
            citationCount: 1,
            uniqueSourceCount: 1,
            documentsReviewed: 1,
            searchShortfallsRecord: nil
        )
        report.session = session
        context.insert(report)
        session.report = report
    }

    /// A session reopened from history, holding the named documents and,
    /// unless told otherwise, the report a finished run made.
    private func makeSession(
        titles: [String] = ["A Study"], withReport: Bool = true
    ) -> FactCheckSession {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        for title in titles {
            addDocument(title, to: session)
        }
        if withReport {
            attachReport(to: session)
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

    private func result() -> TransparencyResult {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        return builder.build()
    }

    // MARK: - A failure is a notice, not a failed run

    func testAFailedAnalysisIsANoticeNotAFailedRun() async {
        let session = makeSession(titles: ["Alpha"])
        let workflow = restore(session)

        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })

        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertEqual(
            workflow.transparencyNotice,
            "No transparency rating for: Alpha. Open a study to analyse it."
        )
    }

    /// Control: the fixture is one the retry section is offered for, so the
    /// test above is not passing on a session that could never show it.
    func testTheFixtureOffersARetryWhenTheRunFailed() {
        let session = makeSession()
        let workflow = restore(session)

        session.errorMessage = "Report generation timed out"

        XCTAssertTrue(workflow.canRetryReportGeneration)
    }

    /// The run's own failure and the notice are both shown; neither takes the
    /// other's place, and the failure keeps its retry.
    func testARunFailureIsKeptBesideTheNotice() async {
        let session = makeSession(titles: ["Alpha"])
        session.errorMessage = "Report generation timed out"
        let workflow = restore(session)

        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })

        XCTAssertEqual(session.errorMessage, "Report generation timed out")
        XCTAssertTrue(workflow.canRetryReportGeneration)
        XCTAssertNotNil(workflow.transparencyNotice)
    }

    /// Reopened from history, a session still explains its missing badge. The
    /// notice used to live only as long as the run that set it.
    func testAReopenedSessionStillNamesItsUnratedStudy() async {
        let session = makeSession(titles: ["Alpha"])
        await restore(session).analyzeTransparency(using: { _, _, _ in throw Boom() })

        let reopened = restore(session)

        XCTAssertEqual(
            reopened.transparencyNotice,
            "No transparency rating for: Alpha. Open a study to analyse it."
        )
    }

    func testOnlyTheStudiesLeftUnratedAreNamed() async throws {
        let session = makeSession(titles: ["Alpha", "Beta"])
        let workflow = restore(session)

        await workflow.analyzeTransparency(using: { [result = result()] doi, _, _ in
            if doi == "10.1000/Beta" { throw Boom() }
            return result
        })

        XCTAssertEqual(
            workflow.transparencyNotice,
            "No transparency rating for: Beta. Open a study to analyse it."
        )
        let alpha = try XCTUnwrap(session.documents?.first { $0.title == "Alpha" })
        XCTAssertTrue(alpha.hasTransparencyAnalysis)
    }

    /// A study rated afterwards, by a later pass or from its detail sheet,
    /// drops out of the notice.
    func testRatingTheMissingStudyClearsTheNotice() async throws {
        let session = makeSession()
        let workflow = restore(session)
        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })
        XCTAssertNotNil(workflow.transparencyNotice)

        let document = try XCTUnwrap(session.documents?.first)
        XCTAssertTrue(document.storeTransparencyResult(result()))

        XCTAssertNil(workflow.transparencyNotice)
    }

    /// A result that cannot be encoded leaves the document without a rating,
    /// as a thrown error does, so the reader is told about it the same way.
    func testAResultThatCannotBeStoredIsReported() async {
        let session = makeSession(titles: ["Alpha"])
        let workflow = restore(session)
        var builder = TransparencyResultBuilder(pmid: "12345678")
        // JSONEncoder refuses a non-finite number
        builder.industryFundingConfidence = .nan
        let unstorable = builder.build()

        await workflow.analyzeTransparency(using: { _, _, _ in unstorable })

        XCTAssertEqual(
            workflow.transparencyNotice,
            "No transparency rating for: Alpha. Open a study to analyse it."
        )
    }

    /// Before the report exists the pass has not finished its run, and the
    /// screen's progress, not this notice, says where it stands.
    func testNoNoticeBeforeTheRunHasAReport() async {
        let session = makeSession(titles: ["Alpha"], withReport: false)
        let workflow = restore(session)

        await workflow.analyzeTransparency(using: { _, _, _ in throw Boom() })

        XCTAssertNil(workflow.transparencyNotice)
    }

    func testCancellingStopsThePassWithoutFailingTheRun() async {
        let session = makeSession(titles: ["Alpha", "Beta", "Gamma"])
        let workflow = restore(session)
        var calls = 0

        let run = Task { @MainActor in
            await workflow.analyzeTransparency(using: { _, _, _ in
                calls += 1
                if calls == 2 {
                    // What the user's cancel does: the task under way is
                    // cancelled, and its request throws as it is abandoned
                    withUnsafeCurrentTask { $0?.cancel() }
                    throw CancellationError()
                }
                throw Boom()
            })
        }
        await run.value

        XCTAssertEqual(calls, 2, "no study is analysed after the user stops the run")
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(workflow.canRetryReportGeneration)
    }

    /// Control: a `CancellationError` the user never asked for is one
    /// study's failed analysis, not a stop. BioMedLit turns every
    /// `URLError(.cancelled)` into one, so read as a stop it would end the
    /// pass and leave the remaining studies unrated without a word (#462).
    func testACancellationErrorWithoutACancelIsAFailedAnalysis() async {
        let session = makeSession(titles: ["Alpha", "Beta", "Gamma"])
        let workflow = restore(session)
        var calls = 0

        await workflow.analyzeTransparency(using: { _, _, _ in
            calls += 1
            if calls == 2 { throw CancellationError() }
            throw Boom()
        })

        XCTAssertEqual(calls, 3, "the pass goes on to the next study")
    }

    // MARK: - Fetching more evidence (#461)

    /// "Get More Evidence" used to go from citations straight to the report,
    /// so a study the batch made relevant was cited but never rated. Only the
    /// new study is analysed: the one rated by the first run keeps its result.
    ///
    /// No LLM service is set up here, so citation extraction and report
    /// generation return without work; the transparency step is the one under
    /// test.
    func testFetchingMoreEvidenceRatesTheStudiesTheBatchAdded() async throws {
        let session = makeSession(titles: ["Rated", "Added"])
        let rated = try XCTUnwrap(session.documents?.first { $0.title == "Rated" })
        XCTAssertTrue(rated.storeTransparencyResult(result()))
        let workflow = restore(session)
        XCTAssertEqual(
            workflow.transparencyNotice,
            "No transparency rating for: Added. Open a study to analyse it.",
            "control: the added study starts unrated"
        )

        var analysed: [String?] = []
        try await workflow.regenerateReportWithNewEvidence(
            analyzeTransparencyUsing: { [result = result()] doi, _, _ in
                analysed.append(doi)
                return result
            }
        )

        XCTAssertEqual(analysed, ["10.1000/Added"])
        XCTAssertNil(workflow.transparencyNotice)
    }

    /// The previous report is deleted only once another has replaced it.
    /// Here none was generated, so the reader keeps the one they had.
    func testARegenerationThatMadeNoReportKeepsTheOldOne() async throws {
        let session = makeSession()
        let report = try XCTUnwrap(session.report)
        let workflow = restore(session)

        try await workflow.regenerateReportWithNewEvidence(
            analyzeTransparencyUsing: { [result = result()] _, _, _ in result }
        )
        try context.save()

        XCTAssertTrue(session.report === report)
        XCTAssertFalse(report.isDeleted)
    }

    // MARK: - What the analyser is given

    /// The analyser takes its three values by position, so swapping two
    /// `String?`s compiles. Each document here differs from the raw fields in
    /// one way the call site must respect (#212).
    func testTheAnalyserIsGivenWhatEachDocumentStates() async {
        let session = makeSession(titles: [], withReport: false)

        // A declared PubMed ID beside a DOI; its stored text is an abstract
        let declared = addDocument("Declared", doi: "10.1000/declared", to: session)
        declared.pmid = "11111111"
        declared.identifierKind = .pubmed
        declared.fullTextContent = "Only the abstract."
        declared.fullTextContentKindRaw = "abstract"

        // A bare number in the PMID slot, which states no PubMed ID
        let bare = addDocument("Bare", doi: "10.1000/bare", to: session)
        bare.pmid = "22222222"
        bare.fullTextContent = "The body."
        bare.fullTextContentKindRaw = "extracted"

        // An empty DOI straight from a provider's JSON
        let emptyDOI = addDocument("Empty DOI", doi: "", to: session)
        emptyDOI.pmid = "33333333"
        emptyDOI.identifierKind = .pubmed

        var given: [String] = []
        await restore(session).analyzeTransparency(using: { [result = result()] doi, pmid, fullText in
            given.append("\(doi ?? "-") | \(pmid ?? "-") | \(fullText ?? "-")")
            return result
        })

        XCTAssertEqual(given.sorted(), [
            "- | 33333333 | -",
            "10.1000/bare | - | The body.",
            "10.1000/declared | 11111111 | -",
        ])
    }

    // MARK: - Which studies the notice counts

    func testAStudyTheStepWouldNotAnalyseIsNotCounted() {
        let session = makeSession(titles: [], withReport: false)
        let unidentifiable = addDocument("No identifier", to: session)
        unidentifiable.doi = nil
        let irrelevant = addDocument("Irrelevant", to: session)
        irrelevant.relevanceScore = 1

        XCTAssertNil(Document.unratedTransparencyNotice(
            in: [unidentifiable, irrelevant], minScore: 3
        ))
    }

    /// The boundary: three are still named, four are counted.
    func testUpToThreeStudiesAreNamedAndMoreAreCounted() {
        let session = makeSession(titles: [], withReport: false)
        let documents = ["a", "b", "c", "d"].map { addDocument($0, to: session) }

        XCTAssertEqual(
            Document.unratedTransparencyNotice(in: Array(documents.prefix(3)), minScore: 3),
            "No transparency rating for: a; b; c. Open a study to analyse it."
        )
        XCTAssertEqual(
            Document.unratedTransparencyNotice(in: documents, minScore: 3),
            "No transparency rating for 4 documents. Open a study to analyse it."
        )
    }

    // MARK: - A run continued after it stopped

    /// "Cancelled by user" outlived the run it described: continued to its
    /// report, the session still offered to retry a report it had made.
    ///
    /// Gone from the start, not only at the end: a continued run that stops
    /// short of completing, or is killed, must not leave the old reason.
    func testContinuingACancelledRunForgetsWhyItStopped() async {
        let session = makeSession(titles: [], withReport: false)
        session.currentStep = .awaitingUserDecision
        session.errorMessage = "Cancelled by user"
        let workflow = restore(session)
        workflow.useServices(
            llm: LLMService(
                baseURL: URL(string: "nosuch-scheme://x")!, apiKey: "test-key", model: "test-model"
            ),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        var messageWhileRunning: String?? = .none
        workflow.onProgress = { [weak workflow] _, _ in
            guard case .none = messageWhileRunning else { return }
            messageWhileRunning = .some(session.errorMessage)
            // With no documents the run goes back to the claim; stopped here,
            // it records nothing of its own
            workflow?.cancelFactCheck()
        }

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(messageWhileRunning, .some(nil), "cleared by the time the run reports progress")
        XCTAssertNil(session.errorMessage)
    }

    // MARK: - Sessions stored by earlier builds

    /// Builds before #459 stored the notice as the session's `errorMessage`.
    func testAStoredNoticeBesideAReportOffersNoRetry() {
        let session = makeSession(titles: ["Alpha"])
        let stored = "Transparency analysis failed for: Alpha"
        session.errorMessage = stored

        let workflow = restore(session)

        XCTAssertFalse(workflow.canRetryReportGeneration)
        // Shown as this build words it, from the documents as they are now
        XCTAssertEqual(
            workflow.transparencyNotice,
            "No transparency rating for: Alpha. Open a study to analyse it."
        )
        // Viewing does not rewrite the store
        XCTAssertEqual(session.errorMessage, stored)
    }

    /// Without a report the stored notice does not show the run finished: one
    /// killed while generating the report still needs the retry.
    func testAStoredNoticeWithoutAReportKeepsTheRetry() {
        let session = makeSession(titles: ["Alpha"], withReport: false)
        session.errorMessage = "Transparency analysis failed for: Alpha"

        XCTAssertTrue(restore(session).canRetryReportGeneration)
    }

    /// Control: restoring a session whose run really failed keeps its retry.
    func testARestoredRunFailureKeepsItsRetry() {
        let session = makeSession()
        session.errorMessage = "Report generation timed out"

        let workflow = restore(session)

        XCTAssertTrue(workflow.canRetryReportGeneration)
        XCTAssertNotEqual(workflow.transparencyNotice, "Report generation timed out")
    }

    // Written out, not built: earlier builds stored these exact sentences, and
    // a session holding one is recognised only while each still begins as it
    // did there.

    func testBothStoredFormsAreRecognised() {
        XCTAssertTrue(FactCheckWorkflow.isStoredTransparencyNotice(
            "Transparency analysis failed for: Alpha; Beta"
        ))
        XCTAssertTrue(FactCheckWorkflow.isStoredTransparencyNotice(
            "Transparency analysis could not be completed for 4 documents"
        ))
    }

    /// Control: a run's own failure is not mistaken for one.
    func testARunFailureIsNotAStoredNotice() {
        XCTAssertFalse(FactCheckWorkflow.isStoredTransparencyNotice("Report generation timed out"))
        XCTAssertFalse(FactCheckWorkflow.isStoredTransparencyNotice("Cancelled"))
    }
}
