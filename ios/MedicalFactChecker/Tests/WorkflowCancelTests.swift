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
/// stop them, and a cancel beside a standing report recorded "Cancelled by
/// user" as the session's failure, under a red retry.
///
/// Every test cancels from `onProgress`, which the workflow calls from
/// inside the work it is doing, so `Task.isCancelled` there says whether the
/// cancel reached that work. The language model points at a closed loopback
/// port: nothing here reaches the network.
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

    private static func offlineLLM() -> LLMService {
        LLMService(baseURL: closedPort, apiKey: "test-key", model: "test-model")
    }

    /// A session with a finished report made from `reportedCitations`
    /// citations, and one relevant document holding `citations`.
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
    private func restore(_ session: FactCheckSession) -> FactCheckWorkflow {
        let workflow = FactCheckWorkflow(
            modelContext: context, modelContainer: container, settings: .shared
        )
        workflow.restoreForViewing(session)
        workflow.useServices(
            llm: Self.offlineLLM(), pubMed: BMLPubMedService.create(from: .shared)
        )
        return workflow
    }

    /// Cancels the first time the workflow reports `message`, and records
    /// whether the work reporting it was the task the cancel reached.
    private func cancel(
        _ workflow: FactCheckWorkflow, at message: String
    ) -> () -> Bool? {
        var reached: Bool?
        workflow.onProgress = { [weak workflow] _, reported in
            guard reached == nil, reported == message else { return }
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
    /// smart search is untried, so the fetch asks the model next.
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
        XCTAssertNil(workflow.smartSearchNotice, "a stop is not smart search failing")
    }

    // MARK: - Regenerating the report

    /// Stopped while the new report's request was in flight: the request
    /// ends in `URLError(.cancelled)`, which was recorded as a failed run
    /// with a red retry. The report stands, and the citations it lacks are
    /// still offered.
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
    }

    // MARK: - Without a report

    /// Control: with no report to stand, a cancelled run waits on the user,
    /// says why it stopped, and offers to resume.
    func testACancelWithoutAReportWaitsToResume() async {
        let session = makeSession(citations: 1, reportedCitations: nil)
        session.currentStep = .awaitingUserDecision
        let workflow = restore(session)
        let reached = cancel(workflow, at: "No documents to analyze for transparency")

        await workflow.proceedWithCurrentDocuments()

        XCTAssertEqual(reached(), true)
        XCTAssertEqual(session.currentStep, .awaitingUserDecision)
        XCTAssertEqual(session.errorMessage, "Cancelled by user")
        XCTAssertEqual(session.stopReason, .userCancelled)
        XCTAssertNil(session.report, "the run stopped before its report")
        XCTAssertTrue(workflow.awaitingUserDecision)
        XCTAssertTrue(workflow.userDecisionPrompt.hasPrefix("Processing cancelled."))
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
        XCTAssertNil(session.errorMessage, "the stopped run wrote nothing over the next work")
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
}
