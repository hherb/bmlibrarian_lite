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

/// What a cancel reaches, and what it leaves behind (#462).
///
/// macOS showed a Cancel button that did nothing and iOS had none. Wiring
/// them up was not enough on its own: fetching more evidence, retrying the
/// report and smart search ran in tasks nothing stored, so no cancel could
/// stop them, and a cancel recorded "Cancelled by user" as the session's
/// failure, under a red retry.
///
/// Every test that stops a run does so from `onProgress`, which the workflow
/// calls from inside the work it is doing, so `Task.isCancelled` there says
/// whether the stop reached that work. The language model points at a closed
/// loopback port, or at a scheme nothing serves: nothing here reaches the
/// network.
@MainActor
final class WorkflowCancelTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// Nothing listens here, so a request that is sent anyway fails at once
    /// on this machine.
    private static let closedPort = URL(string: "http://127.0.0.1:9")!

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

    /// No transport serves this scheme, so a request fails at once with
    /// `URLError(.unsupportedURL)`, which LLMService does not retry.
    private static let unservedScheme = URL(string: "nosuch-scheme://x")!

    private static func offlineLLM(_ url: URL = closedPort) -> LLMService {
        LLMService(baseURL: url, apiKey: "test-key", model: "test-model")
    }

    /// A session with a finished report made from `reportedCitations`
    /// citations (no report when `nil`), and one relevant document holding
    /// `citations` (no document when `documents` is false).
    private func makeSession(
        citations: Int, reportedCitations: Int?, documents: Bool = true
    ) -> FactCheckSession {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        session.pubmedQuery = "aspirin AND stroke"
        context.insert(session)
        if documents {
            // A bare number states no PubMed ID and there is no DOI, so the
            // transparency step has nothing to send anywhere
            let document = Document(pmid: "12345678", title: "A Study", abstract: "An abstract.")
            // The top score, so the user's threshold setting cannot exclude it
            document.relevanceScore = 5
            // Nothing for automatic full-text retrieval to fetch, whatever
            // the test runner's settings say
            document.markFullTextUnavailable()
            context.insert(document)
            document.session = session
            for index in 0..<citations {
                let citation = Citation(passage: "Passage \(index).")
                context.insert(citation)
                citation.document = document
            }
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
            session.currentStep = .completed
        }
        return session
    }

    /// A workflow showing `session`, with services that need no API key.
    private func restore(
        _ session: FactCheckSession, llm: URL = closedPort
    ) -> FactCheckWorkflow {
        let workflow = FactCheckWorkflow(
            modelContext: context, modelContainer: container, settings: .shared
        )
        workflow.restoreForViewing(session)
        workflow.useServices(
            llm: Self.offlineLLM(llm), pubMed: BMLPubMedService.create(from: .shared)
        )
        return workflow
    }

    /// Cancels the first time the workflow reports a message starting with
    /// `message`, and records whether the work reporting it was the task the
    /// cancel reached.
    private func cancel(
        _ workflow: FactCheckWorkflow, at message: String
    ) -> () -> Bool? {
        var reached: Bool?
        workflow.onProgress = { [weak workflow] _, reported in
            guard reached == nil, reported.hasPrefix(message) else { return }
            workflow?.cancelFactCheck()
            reached = Task.isCancelled
        }
        return { reached }
    }

    // MARK: - Fetching more evidence

    /// "Get More Evidence" ran in a task the view started and nothing stored,
    /// so the cancel could not reach it, and the stop wrote "Cancelled by
    /// user" beside the report it left standing.
    ///
    /// No documents, so refreshing the search state has no page to fetch;
    /// smart search is untried, so the fetch turns to it, and the cancel
    /// lands before its queries are asked for.
    func testCancellingAFetchMoreReachesItAndLeavesTheReport() async throws {
        let session = makeSession(citations: 0, reportedCitations: 0, documents: false)
        let report = try XCTUnwrap(session.report)
        let workflow = restore(session)
        let reached = cancel(workflow, at: "Trying alternative search strategies...")

        await workflow.fetchMoreEvidence()

        XCTAssertEqual(reached(), true, "the cancel reaches the fetch's own task")
        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.report === report)
        XCTAssertFalse(workflow.awaitingUserDecision)
        XCTAssertEqual(workflow.userDecisionPrompt, "")
        XCTAssertFalse(workflow.isRunning)
        XCTAssertEqual(
            workflow.stopNotice, FactCheckWorkflow.stopNoticeText(.user),
            "the screen says the fetch was stopped, not that it found nothing"
        )
        XCTAssertFalse(session.smartSearchEnabled, "a stopped smart search stays available")
    }

    // MARK: - Regenerating the report

    /// Stopped just before the new report's request is sent: whatever that
    /// request then throws was recorded as a failed run with a red retry.
    /// The report stands, and the citations it lacks are still offered.
    func testCancellingARegenerationBesideAReportRecordsNoFailure() async throws {
        let session = makeSession(citations: 3, reportedCitations: 1)
        let report = try XCTUnwrap(session.report)
        let workflow = restore(session)
        XCTAssertNotNil(workflow.unreportedCitationsNotice, "control: the regeneration is offered")
        let reached = cancel(workflow, at: "Retrying report generation...")

        await workflow.retryReportGeneration()

        XCTAssertEqual(reached(), true, "the cancel reaches the regeneration's own task")
        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertTrue(session.report === report)
        XCTAssertEqual(
            workflow.unreportedCitationsNotice, "2 new citations are not in the report yet."
        )
        XCTAssertFalse(workflow.awaitingUserDecision)
        XCTAssertEqual(workflow.stopNotice, FactCheckWorkflow.stopNoticeText(.user))
    }

    // MARK: - Without a report

    /// With no report to stand, a cancelled run waits on the user and says
    /// how to carry on. Nothing failed: no "Report Generation Failed" beside
    /// the decision, though the session holds the citations for a report.
    func testACancelWithoutAReportWaitsToResume() async {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        let reached = cancel(workflow, at: "No documents to analyze for transparency")

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(reached(), true)
        XCTAssertEqual(session.currentStep, .awaitingUserDecision)
        XCTAssertNil(session.errorMessage, "a stop is not a failure")
        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertEqual(session.stopReason, .userCancelled)
        XCTAssertNil(session.report, "the run stopped before its report")
        XCTAssertTrue(workflow.awaitingUserDecision)
        XCTAssertTrue(workflow.userDecisionPrompt.hasPrefix("Processing cancelled."))
        XCTAssertNil(workflow.stopNotice, "the decision says it: there is no report to qualify")
        XCTAssertFalse(workflow.isRunning)
    }

    /// A cancel with nothing running changes nothing.
    func testACancelWithNothingRunningIsIgnored() {
        let session = makeSession(citations: 1, reportedCitations: 1)
        let workflow = restore(session)

        workflow.cancelFactCheck()

        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNil(session.errorMessage)
        XCTAssertNil(session.stopReason)
    }

    // MARK: - After a cancel

    /// Work started the moment a run is cancelled waits for that run to wind
    /// down, so the old run's last writes cannot land on it, and is not
    /// itself cancelled.
    ///
    /// The cancelled run is still waiting on its abandoned request when the
    /// next work is started; it clears `isCancelling` only as it ends.
    func testWorkStartedDuringACancelWaitsForTheStoppedRun() async {
        let session = makeSession(citations: 3, reportedCitations: 1)
        let workflow = restore(session)
        var next: Task<Void, Never>?
        var oldRunStillEnding: Bool?
        var nextWasCancelled: Bool?
        workflow.onProgress = { [weak workflow] _, message in
            guard let workflow, next == nil, message == "Retrying report generation..." else { return }
            workflow.cancelFactCheck()
            next = Task {
                await workflow.runAsWorkflowTask {
                    oldRunStillEnding = workflow.isCancelling
                    nextWasCancelled = Task.isCancelled
                }
            }
        }

        await workflow.retryReportGeneration()
        await next?.value

        XCTAssertEqual(oldRunStillEnding, false, "the next work ran only once the stopped run ended")
        XCTAssertEqual(nextWasCancelled, false)
        XCTAssertNil(session.errorMessage, "no failure was recorded")
    }

    // MARK: - Controls: a failure is still a failure

    /// Control for the stop handling: a report request that fails with no
    /// stop requested is a failed run, under the red retry.
    func testARegenerationThatFailsWithoutAStopIsAFailure() async {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.currentStep = .failed
        let workflow = restore(session, llm: Self.unservedScheme)
        var reported: Error?
        workflow.onError = { reported = $0 }

        await workflow.retryReportGeneration()

        XCTAssertEqual(session.currentStep, .failed)
        XCTAssertNotNil(session.errorMessage)
        XCTAssertEqual(session.stopReason, .apiError)
        XCTAssertTrue(workflow.canRetryReportGeneration)
        XCTAssertNotNil(reported)
        XCTAssertNil(workflow.stopNotice)
    }

    /// Control: a fetch whose smart search cannot reach the model, with no
    /// stop requested, keeps the report and says what went wrong (#256).
    func testAFetchMoreThatFailsWithoutAStopSaysSo() async throws {
        let session = makeSession(citations: 0, reportedCitations: 0, documents: false)
        let report = try XCTUnwrap(session.report)
        let workflow = restore(session, llm: Self.unservedScheme)

        await workflow.fetchMoreEvidence()

        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNotNil(session.errorMessage, "a failure, not a stop")
        XCTAssertTrue(session.report === report)
        XCTAssertNil(workflow.stopNotice)
    }

    // MARK: - Smart search

    /// "Try Smart Search" ran in a task nothing stored. The cancel reaches
    /// it, and smart search stays available: its queries never ran.
    func testCancellingSmartSearchReachesIt() async {
        let session = makeSession(citations: 0, reportedCitations: nil)
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        let reached = cancel(workflow, at: "Generating alternative search queries...")

        await workflow.continueWithSmartSearch()

        XCTAssertEqual(reached(), true, "the cancel reaches smart search's own task")
        XCTAssertEqual(session.currentStep, .awaitingUserDecision)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(session.smartSearchEnabled)
        XCTAssertTrue(workflow.awaitingUserDecision)
        XCTAssertFalse(workflow.isRunning)
    }

    // MARK: - Background expiry

    /// Posts the background expiry notice the first time the workflow reports
    /// `message`. The workflow handles it on the main actor once the work
    /// yields it, here as the report request goes to the language model.
    private func expireBackgroundTime(_ workflow: FactCheckWorkflow, at message: String) -> () -> Bool {
        var posted = false
        workflow.onProgress = { _, reported in
            guard !posted, reported == message else { return }
            posted = true
            NotificationCenter.default.post(name: .backgroundTaskExpiring, object: nil)
        }
        return { posted }
    }

    /// Background time ran out during a regeneration beside a report: nothing
    /// to resume and nothing failed, and the screen says the report did not
    /// change rather than leaving no trace of the stop.
    func testBackgroundExpiryBesideAReportLeavesItStanding() async throws {
        let session = makeSession(citations: 3, reportedCitations: 1)
        let report = try XCTUnwrap(session.report)
        let workflow = restore(session)
        let posted = expireBackgroundTime(workflow, at: "Retrying report generation...")

        await workflow.retryReportGeneration()

        XCTAssertTrue(posted())
        XCTAssertEqual(session.currentStep, .completed)
        XCTAssertNil(session.errorMessage)
        XCTAssertTrue(session.report === report)
        XCTAssertFalse(workflow.wasPausedByBackground, "no banner offering to resume")
        XCTAssertFalse(workflow.awaitingUserDecision)
        XCTAssertEqual(workflow.stopNotice, FactCheckWorkflow.stopNoticeText(.background))
    }

    /// Control: without a report, background expiry pauses the run for the
    /// user to carry on, with no failure beside the decision.
    func testBackgroundExpiryWithoutAReportPausesToResume() async {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.currentStep = .failed
        let workflow = restore(session)
        let posted = expireBackgroundTime(workflow, at: "Retrying report generation...")

        await workflow.retryReportGeneration()

        XCTAssertTrue(posted())
        XCTAssertEqual(session.currentStep, .awaitingUserDecision)
        XCTAssertNil(session.errorMessage)
        XCTAssertFalse(workflow.canRetryReportGeneration)
        XCTAssertTrue(workflow.wasPausedByBackground)
        XCTAssertTrue(workflow.awaitingUserDecision)
        XCTAssertTrue(workflow.userDecisionPrompt.hasPrefix("Processing paused"))
        XCTAssertNil(workflow.stopNotice)
    }

    // MARK: - Carrying a stopped run on

    /// "Proceed with Current" skipped citation extraction, so the report was
    /// written without the citations of the documents it proceeded with.
    func testProceedingExtractsTheCitationsOfTheRelevantDocuments() async {
        let session = makeSession(citations: 0, reportedCitations: nil)
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        var reached: Bool?
        workflow.onProgress = { [weak workflow] step, _ in
            guard reached == nil, step == .extractingCitations else { return }
            workflow?.cancelFactCheck()
            reached = Task.isCancelled
        }

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(reached, true, "the run reached citation extraction")
        XCTAssertNil(session.report)
    }

    /// A run stopped while scoring carries on with the documents it left
    /// unscored, rather than writing its report without them.
    func testProceedingAfterAStopScoresWhatTheStopLeft() async throws {
        let session = makeSession(citations: 0, reportedCitations: nil)
        let document = try XCTUnwrap(session.documents?.first)
        document.relevanceScore = nil
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        let reached = cancel(workflow, at: "Scoring 1 documents")

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(reached(), true, "the run went back to scoring")
        XCTAssertNil(document.relevanceScore)
        XCTAssertFalse(document.scoreParseFailed, "a stopped scoring records no failure")
    }

    /// A run stopped before it found a document has nothing to proceed with:
    /// it goes back to the step it stopped in.
    func testProceedingWithoutDocumentsGoesBackToTheStepThatFoundNone() async {
        XCTAssertEqual(
            FactCheckWorkflow.stepToProceedFrom(hasDocuments: true, hasQuery: true), .extractingCitations
        )
        XCTAssertEqual(
            FactCheckWorkflow.stepToProceedFrom(hasDocuments: false, hasQuery: true), .searchingPubMed
        )
        XCTAssertEqual(
            FactCheckWorkflow.stepToProceedFrom(hasDocuments: false, hasQuery: false), .idle
        )

        let session = makeSession(citations: 0, reportedCitations: nil, documents: false)
        session.pubmedQuery = nil
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        let reached = cancel(workflow, at: "Analyzing claim...")

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(reached(), true, "the run went back to the claim")
    }

    /// Reopened with nothing left to fetch, a stopped session used to show no
    /// decision at all: the red retry, reading the stop as a failure, was the
    /// only way on. The decision now offers "Proceed with Current" alone.
    func testAStoppedSessionReopenedWithNothingToFetchOffersToProceed() {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.currentStep = .awaitingUserDecision
        session.smartSearchEnabled = true
        session.searchProvider = SearchProvider.pubmed.rawValue
        session.pubmedHasMore = false
        // As an earlier build stored the stop
        session.errorMessage = "Cancelled by user"

        let workflow = restore(session)

        XCTAssertTrue(workflow.awaitingUserDecision)
        XCTAssertFalse(workflow.decisionOffersFetchMore)
        XCTAssertFalse(workflow.canRetryReportGeneration, "a stored stop is not a failure")
    }

    /// What the decision says after a stop, by who stopped the run.
    func testTheStopPromptNamesWhatIsLeft() {
        XCTAssertEqual(
            FactCheckWorkflow.stopPrompt(.user, scored: 3, remaining: 2),
            "Processing cancelled. 3 document(s) scored, 2 remaining. "
                + "Proceed with Current continues from where it stopped."
        )
        XCTAssertEqual(
            FactCheckWorkflow.stopPrompt(.background, scored: 0, remaining: 0),
            "Processing paused when the app was backgrounded. "
                + "Proceed with Current continues from where it stopped."
        )
    }
}

/// A cancel stops scoring without recording the documents it stopped as
/// failed (#462).
///
/// A request abandoned by the cancel was returned as a failure, which is
/// checkpointed and marks the document so that no later run scores it.
final class ScoringCancelTests: XCTestCase {
    /// Counts the results the service hands on.
    private actor Reported {
        var count = 0
        func add() { count += 1 }
    }

    func testAScoringTheCancelStoppedIsNotAFailure() async throws {
        // Nothing listens on this port: each attempt fails and LLMService
        // backs off for at least 0.75 s before retrying, so at the cancel the
        // first document is under way and no result exists yet
        let llm = LLMService(
            baseURL: URL(string: "http://127.0.0.1:9")!, apiKey: "test-key", model: "test-model"
        )
        let service = ParallelScoringService(llmService: llm, maxConcurrent: 1)
        let inputs = ["1", "2"].map {
            ScoringInput(
                pmid: $0, title: "Title \($0)", abstract: "Abstract.",
                authors: "Author A", year: 2020, journal: "Journal"
            )
        }
        let reported = Reported()

        let run = Task {
            await service.scoreDocuments(
                inputs,
                claim: "Aspirin prevents stroke",
                onProgress: { _, _, _ in },
                onResult: { _ in await reported.add() }
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        let results = await run.value

        XCTAssertTrue(results.isEmpty, "got \(results.map { $0.errorMessage ?? "a score" })")
        let count = await reported.count
        XCTAssertEqual(count, 0)
    }

    /// Control: with no cancel, a request that fails is a failure for every
    /// document, each handed on. A stop handler that caught it would leave
    /// the documents unscored and re-billed on every run.
    func testAScoringThatFailsWithoutACancelIsAFailure() async {
        // No transport serves this scheme, and LLMService does not retry it
        let llm = LLMService(
            baseURL: URL(string: "nosuch-scheme://x")!, apiKey: "test-key", model: "test-model"
        )
        let service = ParallelScoringService(llmService: llm, maxConcurrent: 1)
        let inputs = ["1", "2"].map {
            ScoringInput(
                pmid: $0, title: "Title \($0)", abstract: "Abstract.",
                authors: "Author A", year: 2020, journal: "Journal"
            )
        }
        let reported = Reported()

        let results = await service.scoreDocuments(
            inputs,
            claim: "Aspirin prevents stroke",
            onProgress: { _, _, _ in },
            onResult: { _ in await reported.add() }
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.isError })
        let count = await reported.count
        XCTAssertEqual(count, 2)
    }
}

/// A cancel stops citation extraction without recording the documents it
/// stopped as failed (#462): they keep no citations, so a later run extracts
/// them.
@MainActor
final class CitationCancelTests: XCTestCase {
    /// Two documents with no full text, so each is one request.
    private static func inputs() -> [CitationInput] {
        ["1", "2"].map {
            CitationInput(
                pmid: $0, title: "Title \($0)", abstract: "Abstract.",
                authors: "Author A", year: 2020
            )
        }
    }

    /// A document the cancel stopped is handed on as nothing: not a failure,
    /// and no later document is started.
    func testAnExtractionTheCancelStoppedIsNotAFailure() async throws {
        // Nothing listens on this port: LLMService backs off for at least
        // 0.75 s before retrying, so at the cancel the first document is under
        // way and no result exists yet
        let llm = LLMService(
            baseURL: URL(string: "http://127.0.0.1:9")!, apiKey: "test-key", model: "test-model"
        )
        let service = ParallelCitationService(llmService: llm, maxConcurrent: 1)
        var handedOn = 0

        let run = Task {
            await service.extractCitations(
                Self.inputs(),
                claim: "Aspirin prevents stroke",
                onProgress: { _, _, _ in },
                onResult: { _ in handedOn += 1 }
            )
        }
        try await Task.sleep(for: .milliseconds(200))
        run.cancel()
        let results = await run.value

        XCTAssertTrue(results.isEmpty, "got \(results.map { $0.errorMessage ?? "citations" })")
        XCTAssertEqual(handedOn, 0)
    }

    /// Control: with no cancel, a request that fails is a failure for every
    /// document.
    func testAnExtractionThatFailsWithoutACancelIsAFailure() async {
        let llm = LLMService(
            baseURL: URL(string: "nosuch-scheme://x")!, apiKey: "test-key", model: "test-model"
        )
        let service = ParallelCitationService(llmService: llm, maxConcurrent: 1)

        let results = await service.extractCitations(
            Self.inputs(),
            claim: "Aspirin prevents stroke",
            onProgress: { _, _, _ in },
            onResult: nil
        )

        XCTAssertEqual(results.count, 2)
        XCTAssertTrue(results.allSatisfy { $0.isError })
    }
}
