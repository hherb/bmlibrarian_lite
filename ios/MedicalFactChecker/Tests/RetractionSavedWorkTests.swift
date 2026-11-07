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

/// A restored session says when its papers were last checked, warns of a
/// cited paper retracted since without asking anyone, and *Check again*
/// stores new answers without touching the run's record or its report.
@MainActor
final class RetractionSavedWorkTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// No transport serves this scheme, and LLMService does not retry it.
    private static let unservedScheme = URL(string: "nosuch-scheme://x")!
    private nonisolated static let runDay = Date(timeIntervalSince1970: 1_792_315_800) // 2026-10-18 09:30 UTC
    private static let day: TimeInterval = 24 * 60 * 60
    /// How long ``waitUntil(_:)`` waits for a check to start before failing.
    private static let startDeadline: Duration = .seconds(5)

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

    // MARK: - Fixtures

    private static let notice = StoredRetractionEvidence(
        source: "retraction_watch_export", kind: "retraction", date: "2026-10-19",
        noticeDOI: "10.1000/notice", recordID: "42", rawKind: "Retraction"
    )

    private static func check(_ status: String, at date: Date = runDay) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: status, deciding: status == "retracted" ? notice : nil,
            unanswered: status == "unchecked" ? ["retraction_watch_export", "crossref"] : [],
            checkedAt: date, exportDataAsOf: nil, crossrefFailure: nil
        )
    }

    /// A completed session with a report, one document per DOI, each cited
    /// when `cited` holds its index, each checked by the run as `run` says
    /// (no entry: the run recorded no check).
    private func makeSession(
        _ dois: [String], cited: Set<Int>, run: [Int: PaperRetractionCheck]
    ) -> (FactCheckSession, [Document]) {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        session.pubmedQuery = "aspirin AND stroke"
        context.insert(session)
        let documents = dois.enumerated().map { index, doi in
            let document = Document(pmid: "2000000\(index)", title: "Study \(index)", abstract: "An abstract.")
            document.doi = doi
            document.publicationTypes = ["Journal Article"]
            document.relevanceScore = 4
            document.scoredAt = Self.runDay
            context.insert(document)
            document.session = session
            if cited.contains(index) {
                let citation = Citation(passage: "Passage \(index).")
                context.insert(citation)
                citation.document = document
            }
            if let check = run[index] { document.retractionCheck = check }
            return document
        }
        _ = session.recordRetractionSnapshot(Dictionary(uniqueKeysWithValues: run.map { (documents[$0.key].id, $0.value) }))
        let report = EvidenceReport(
            verdict: .supported, summary: "Supported.", fullReport: "The saved report.",
            citationCount: cited.count, uniqueSourceCount: cited.count, documentsReviewed: dois.count,
            searchShortfallsRecord: nil
        )
        context.insert(report)
        report.session = session
        session.report = report
        session.stopReason = .completed
        session.documentsFound = documents.count
        try? context.save()
        return (session, documents)
    }

    /// Another session's `check` of `doi`, as its run leaves it: on its
    /// document and on the paper's record (#651). `json` replaces the stored text.
    private func storeElsewhere(_ doi: String, _ check: PaperRetractionCheck, json: String? = nil) {
        let other = FactCheckSession(claim: "Another claim")
        context.insert(other)
        let document = Document(pmid: "3000000", title: "Same paper", abstract: "An abstract.")
        document.doi = doi
        context.insert(document)
        document.session = other
        document.retractionCheck = check
        if let json { document.retractionCheckJSON = json }
        try? RetractionCheckRecord.share(from: [document], in: context)
        try? context.save()
    }

    /// Counts the papers asked about, answering each from `answers` by DOI.
    private final class Asked: @unchecked Sendable {
        var calls = 0
    }

    /// The papers asked about.
    private final class AskedPapers: @unchecked Sendable {
        var papers: [RetractionPaper] = []
    }

    private func restore(
        _ session: FactCheckSession, asked: Asked = Asked(), answers: [String: PaperRetractionCheck] = [:]
    ) -> FactCheckWorkflow {
        let workflow = FactCheckWorkflow(modelContext: context, modelContainer: container, settings: .shared)
        workflow.useServices(
            llm: LLMService(baseURL: Self.unservedScheme, apiKey: "test-key", model: "test-model"),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        workflow.useRetractionCheck { papers in
            asked.calls += 1
            var out: [RetractionPaper: PaperRetractionCheck] = [:]
            for paper in papers { out[paper] = paper.doi.flatMap { answers[$0] } }
            return out
        }
        workflow.restoreForViewing(session)
        return workflow
    }

    private struct CheckFailed: Error {}

    /// A secret store with no key, in place of the Keychain: a new claim's
    /// services cannot be made, so its run stops there, before any request.
    private final class NoSecrets: SecretStore {
        func load(key: String) throws -> String? { nil }
        func save(key: String, value: String) -> Bool { false }
        func delete(key: String) -> Bool { true }
    }

    // MARK: - Restored

    func testNeverCheckedSessionSaysSo() {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [:])
        let workflow = restore(session)
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status never checked")
        XCTAssertNil(workflow.retractionSavedWorkWarning)
    }

    func testOldestCheckedAtIsShown() {
        let (session, _) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c"], cited: [0], run: [
            0: Self.check("clear", at: Self.runDay.addingTimeInterval(Self.day)),
            1: Self.check("retracted"),
            2: Self.check("unchecked", at: Self.runDay.addingTimeInterval(-Self.day)),
        ])
        let workflow = restore(session)
        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; 1 paper could not be checked",
            "the oldest decided check; an unchecked answer's time is never a check time")
    }

    func testNewerKnowledgeWarnsForACitedPaperWithoutARequest() {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        storeElsewhere("https://doi.org/10.1000/A", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        let asked = Asked()

        let workflow = restore(session, asked: asked)

        XCTAssertEqual(asked.calls, 0, "no request is made")
        XCTAssertEqual(
            workflow.retractionSavedWorkWarning,
            "Since this report was written, 1 paper this report cites has a retraction warning:\n"
                + "• Study 0: Retracted on 2026-10-19 (notice 10.1000/notice)\n"
                + "The report has not been changed; re-run the question to bring it up to date.")
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-18",
                       "another session's check is a warning, not this run's record")
    }

    /// The run's own check failed, so it knew nothing: a retraction another
    /// session found before it is still news.
    func testARunWhoseCheckFailedWarnsOfAnEarlierRetraction() {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("unchecked")])
        storeElsewhere("10.1000/a", Self.check("retracted", at: Self.runDay.addingTimeInterval(-Self.day)))

        let workflow = restore(session)

        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
    }

    /// A retraction every lookup answered, and a newer concern resting on a
    /// Crossref outage: the warning reads the retraction, as the screen
    /// (``RetractionCheckRecord/standing(_:)``) does, not the newer check (#693).
    func testAnAnsweredRetractionWarnsOverANewerOutageConcern() {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        storeElsewhere("10.1000/a", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        documents[0].retractionCheck = PaperRetractionCheck(
            status: "concern", deciding: nil, unanswered: ["crossref"],
            checkedAt: Self.runDay.addingTimeInterval(9 * Self.day), exportDataAsOf: nil, crossrefFailure: nil)

        let warning = restore(session).retractionSavedWorkWarning ?? ""

        XCTAssertTrue(warning.contains("• Study 0: Retracted"), warning)
    }

    /// The control: a newer clear every lookup answered replaces the older
    /// retraction, as on the screen, so nothing warns.
    func testANewerAnsweredClearReplacesAnOlderRetraction() {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        storeElsewhere("10.1000/a", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        documents[0].retractionCheck = Self.check("clear", at: Self.runDay.addingTimeInterval(9 * Self.day))

        XCTAssertNil(restore(session).retractionSavedWorkWarning)
    }

    /// A stored check this build cannot read may hold a retraction: the line
    /// says later checks could not be read, for this session's and another's.
    func testAnUnreadableStoredCheckSaysSo() {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        XCTAssertEqual(restore(session).retractionSavedWorkLine, "Retraction status checked 2026-10-18", "control")

        documents[0].retractionCheckJSON = "{\"status\": 7}"
        XCTAssertEqual(
            restore(session).retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; later checks could not be read")

        documents[0].retractionCheck = Self.check("clear")
        storeElsewhere("10.1000/a", Self.check("clear"), json: "{\"status\": 7}")
        XCTAssertEqual(
            restore(session).retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; later checks could not be read")
    }

    func testUncitedPaperChangeWarnsNothing() {
        let (session, _) = makeSession(["10.1000/a", "10.1000/b"], cited: [0], run: [
            0: Self.check("clear"), 1: Self.check("clear"),
        ])
        storeElsewhere("10.1000/b", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        storeElsewhere("10.1000/a", Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)))

        let workflow = restore(session)

        XCTAssertNil(workflow.retractionSavedWorkWarning, "an uncited paper, and an outage, warn of nothing")
    }

    // MARK: - Worked on again

    /// Scoring the session again screens it: its report is no longer the
    /// saved one, so the saved-work line and warning go.
    func testWorkingOnTheSessionAgainClearsTheSavedWorkLineAndWarning() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        storeElsewhere("10.1000/a", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        let workflow = restore(session)
        XCTAssertNotNil(workflow.retractionSavedWorkLine, "control")
        XCTAssertNotNil(workflow.retractionSavedWorkWarning, "control")

        await workflow.retryFailedDocuments(pmids: [documents[0].pmid])

        XCTAssertNil(workflow.retractionSavedWorkLine)
        XCTAssertNil(workflow.retractionSavedWorkWarning)
    }

    /// A workflow whose new claim stops at its services, before any request:
    /// its secret store holds no key. The provider is read from the standard
    /// defaults (setting it would write there), so a machine set to a keyless
    /// one skips: its claim would run for real.
    private func keylessWorkflow(checking check: @escaping RetractionCheck = { _ in [:] }) throws -> FactCheckWorkflow {
        let flags = try XCTUnwrap(UserDefaults(suiteName: "RetractionSavedWorkTests.newClaim"))
        let settings = AppSettings(secretStore: NoSecrets(), credentialFlags: flags)
        try XCTSkipUnless(settings.selectedProvider.requiresAPIKey, "a keyless provider would run the claim for real")
        let workflow = FactCheckWorkflow(modelContext: context, modelContainer: container, settings: settings)
        workflow.useServices(
            llm: LLMService(baseURL: Self.unservedScheme, apiKey: "test-key", model: "test-model"),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        workflow.useRetractionCheck(check)
        return workflow
    }

    /// Starts a new claim on `workflow`, which stops at its services.
    private func startStoppedClaim(on workflow: FactCheckWorkflow) async {
        var errors: [Error] = []
        workflow.onError = { errors.append($0) }
        await workflow.startFactCheck(claim: "Statins prevent dementia")
        XCTAssertEqual(errors.count, 1, "control: the run stopped at its services, before any request")
    }

    /// A new claim answers for itself: the last run's notice does not survive
    /// into it, even when the new run stops at once.
    func testANewClaimClearsTheLastRunsNotice() async throws {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let retracted = Self.check("retracted")
        let workflow = try keylessWorkflow { papers in
            Dictionary(uniqueKeysWithValues: papers.map { ($0, retracted) })
        }
        workflow.restoreForViewing(session)
        await workflow.retryFailedDocuments(pmids: [documents[0].pmid])
        XCTAssertNotNil(workflow.retractionNotice, "control: the run left the paper out")

        await startStoppedClaim(on: workflow)

        XCTAssertNil(workflow.retractionNotice)
    }

    /// Nor do the last session's saved-work line and warning.
    func testANewClaimClearsTheSavedWorkLineAndWarning() async throws {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        storeElsewhere("10.1000/a", Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)))
        let workflow = try keylessWorkflow()
        workflow.restoreForViewing(session)
        XCTAssertNotNil(workflow.retractionSavedWorkLine, "control")
        XCTAssertNotNil(workflow.retractionSavedWorkWarning, "control")

        await startStoppedClaim(on: workflow)

        XCTAssertNil(workflow.retractionSavedWorkLine)
        XCTAssertNil(workflow.retractionSavedWorkWarning)
    }

    // MARK: - Check again

    func testCheckAgainStoresTheAnswerAndWarns() async {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"], cited: [0, 1], run: [
            0: Self.check("clear"), 1: Self.check("clear"),
        ])
        let later = Self.runDay.addingTimeInterval(Self.day)
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("retracted", at: later), "10.1000/b": Self.check("clear", at: later),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck?.isRetracted, true, "the answer is stored")
        XCTAssertEqual(session.retractionSnapshot()[documents[0].id]?.isClear, true, "the run's record is kept")
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-19")
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        XCTAssertFalse(workflow.retractionSavedWorkWarning?.contains("Study 1") == true, "control: still clear")
        XCTAssertFalse(workflow.isCheckingRetractionsAgain)
        let shown = session.shownRetractionChecks()[documents[0].id]
        XCTAssertEqual(shown?.isClear, true, "lists and counts keep the run's check")
        XCTAssertEqual(documents[0].badgedRetractionCheck(shown: shown)?.isRetracted, true, "the badge shows the new one")
        XCTAssertEqual(documents[0].badgedRetractionCheck(shown: documents[0].shownRetractionCheck)?.isRetracted, true,
                       "and so does the full text's banner")
    }

    /// #688 on *Check again*: one check per paper, from every document's evidence.
    func testCheckAgainChecksAPaperTwoDocumentsShareOnce() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/a"], cited: [0, 1], run: [
            0: Self.check("clear"), 1: Self.check("clear"),
        ])
        documents[0].publicationTypes = nil
        let found = PaperRetractionCheck(
            status: "retracted", deciding: Self.notice, unanswered: ["crossref"],
            checkedAt: Self.runDay.addingTimeInterval(Self.day), exportDataAsOf: nil, crossrefFailure: nil
        )
        let outage = PaperRetractionCheck(
            status: "unchecked", deciding: nil, unanswered: ["crossref"],
            checkedAt: Self.runDay.addingTimeInterval(Self.day), exportDataAsOf: nil, crossrefFailure: nil
        )
        let workflow = restore(session)
        let asked = AskedPapers()
        // Crossref is down; only a check that sees document 0's record finds the retraction
        workflow.useRetractionCheck { papers in
            asked.papers += papers
            var out: [RetractionPaper: PaperRetractionCheck] = [:]
            for paper in papers { out[paper] = paper.publicationTypes.isEmpty ? outage : found }
            return out
        }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(asked.papers.count, 1, "asked once")
        for document in documents { XCTAssertEqual(document.retractionCheck, found) }
        let key = try XCTUnwrap(documents[0].retractionPaper.paperKey)
        let records = try XCTUnwrap(RetractionCheckRecord.byKey([key], in: context)[key])
        XCTAssertEqual(records.map { RetractionCheckRecord.check($0.checkJSON) }, [found])
    }

    /// A row this build cannot read, and Crossref down while Retraction Watch
    /// says retracted: the retraction is stored and warned of (#669).
    func testCheckAgainStoresARetractionOverAnUnreadableRow() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("unchecked")])
        documents[0].retractionCheckJSON = "{\"status\": 7}"
        let found = PaperRetractionCheck(
            status: "retracted", deciding: Self.notice, unanswered: ["crossref"],
            checkedAt: Self.runDay.addingTimeInterval(Self.day), exportDataAsOf: nil, crossrefFailure: nil
        )
        let workflow = restore(session, answers: ["10.1000/a": found])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck, found, "the retraction is stored")
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-19")
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
    }

    /// Every lookup down after an earlier *Check again* found a retraction:
    /// the retraction stands and still warns.
    func testAnOutageDuringASecondCheckAgainKeepsTheWarning() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)),
        ])
        await workflow.checkRetractionsAgain()
        let outage = Self.check("unchecked", at: Self.runDay.addingTimeInterval(2 * Self.day))
        workflow.useRetractionCheck { papers in Dictionary(papers.map { ($0, outage) }) { first, _ in first } }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck?.isRetracted, true, "an outage is not knowledge")
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-19; 1 paper could not be checked again: \(Self.uncheckedCauses)")
    }

    /// One paper answered, two decided ones not, and one the run could not
    /// check either: only the decided ones are "not checked again", and the
    /// date is the oldest decided check's.
    func testAPartialOutageCountsTheDecidedPapersItMissed() async {
        let (session, _) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c", "10.1000/d"], cited: [0], run: [
            0: Self.check("clear"), 1: Self.check("clear"), 2: Self.check("clear"), 3: Self.check("unchecked"),
        ])
        let later = Self.runDay.addingTimeInterval(Self.day)
        // b's copy was consulted and Crossref failed: its causes follow the again count (#668)
        let unreadable = PaperRetractionCheck(
            status: "unchecked", deciding: nil, unanswered: ["retraction_watch_export", "crossref"],
            checkedAt: later, exportDataAsOf: "2026-10-19", crossrefFailure: "HTTP 503"
        )
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("clear", at: later), "10.1000/b": unreadable,
            "10.1000/c": Self.check("unchecked", at: later), "10.1000/d": Self.check("unchecked", at: later),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; 1 paper could not be checked: \(Self.uncheckedCauses);"
                + " 2 papers could not be checked again: the Retraction Watch data could not be used"
                + " (no up-to-date copy is on this device); a Retraction Watch notice could not be read;"
                + " Crossref could not be used (HTTP 503); Crossref had no usable answer for the DOI")
    }

    /// A run's paper whose document is gone is never asked: the causes of
    /// the others would claim it too, so the line gives the count alone.
    func testCheckAgainNamesNoCauseWhenAnUncheckedPaperWasNotReached() async {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"], cited: [0], run: [
            0: Self.check("unchecked"), 1: Self.check("unchecked"),
        ])
        context.delete(documents[1])
        try? context.save()
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status could not be checked")
    }

    /// Why ``check(_:at:)``'s unchecked answer leaves a paper with a DOI unchecked.
    private static let uncheckedCauses = "the Retraction Watch data could not be used (no up-to-date copy is on this device);"
        + " Crossref had no usable answer for the DOI"

    /// #660: a paper still unchecked after *Check again* is named with why,
    /// as the run's notice would; a plain reopen, whose snapshot records no
    /// cause, gives the count alone.
    func testCheckAgainNamesWhyPapersStayUnchecked() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("unchecked")])
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)),
        ])
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status could not be checked")

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine, "Retraction status could not be checked: \(Self.uncheckedCauses)")
    }

    func testCheckAgainFailureKeepsTheRunsRecord() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        workflow.useRetractionCheck { _ in throw CheckFailed() }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; it could not be checked again, so this is still the run's record")
        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
    }

    /// #673: a label that arrived after the run still warns when *Check
    /// again* fails, though nothing is stored.
    func testCheckAgainFailureStillWarnsByTheLabel() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        XCTAssertNil(workflow.retractionSavedWorkWarning)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        workflow.useRetractionCheck { _ in throw CheckFailed() }

        await workflow.checkRetractionsAgain()

        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
        XCTAssertTrue(workflow.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainFailed) == true)
        // control: without the label, nothing to warn of
        documents[0].publicationTypes = ["Journal Article"]
        await workflow.checkRetractionsAgain()
        XCTAssertNil(workflow.retractionSavedWorkWarning)
    }

    /// #673: a stored retraction keeps its own notice over the label, and
    /// a stored concern is never hidden by a failed check.
    func testCheckAgainFailureKeepsWhatIsStored() async {
        let later = Self.runDay.addingTimeInterval(Self.day)
        let (session, documents) = makeSession(
            ["10.1000/a", "10.1000/b"], cited: [0, 1], run: [0: Self.check("clear"), 1: Self.check("clear")])
        documents[0].retractionCheck = Self.check("retracted", at: later)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        documents[1].retractionCheck = Self.check("concern", at: later)
        let workflow = restore(session)
        workflow.useRetractionCheck { _ in throw CheckFailed() }

        await workflow.checkRetractionsAgain()

        let warning = workflow.retractionSavedWorkWarning ?? ""
        XCTAssertTrue(warning.contains("• Study 0: Retracted on 2026-10-19 (notice 10.1000/notice)"), warning)
        XCTAssertFalse(warning.contains("Study 0: Retracted (PubMed's label)"), warning)
        XCTAssertTrue(warning.contains("• Study 1: Expression of concern"), warning)
    }

    /// #654, #675: a stopped *Check again* stores nothing, says it was
    /// stopped, not that it failed, and still warns of a paper its label retracts.
    func testAStoppedCheckAgainStoresNothingAndWarnsByTheLabel() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        workflow.useRetractionCheck { _ in
            await MainActor.run { workflow.cancelCheckAgain() }
            try Task.checkCancellation()
            return [:]
        }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; checking again was stopped, so this is still the run's record")
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
        XCTAssertFalse(workflow.isCheckingRetractionsAgain)
    }

    /// #654: a stop the check does not throw for stores none of its answers.
    func testAStopTheCheckDidNotThrowForStoresNothing() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        let retracted = Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day))
        workflow.useRetractionCheck { papers in
            await MainActor.run { workflow.cancelCheckAgain() }
            return Dictionary(papers.map { ($0, retracted) }) { first, _ in first }
        }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
        XCTAssertTrue(workflow.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainStopped) == true)
        XCTAssertNil(workflow.retractionSavedWorkWarning, "an answer not stored warns of nothing")
        // control: the next Check again is not stopped by the last one's stop
        workflow.useRetractionCheck { papers in Dictionary(papers.map { ($0, retracted) }) { first, _ in first } }
        await workflow.checkRetractionsAgain()
        XCTAssertEqual(documents[0].retractionCheck, retracted)
    }

    /// #654: a stop asked while *Check again* waits behind earlier work stops
    /// it before it asks anything, and leaves that work running.
    func testAStopWhileWaitingStopsCheckAgainNotTheWorkAhead() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let asked = Asked()
        let workflow = restore(session, asked: asked)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        let (gate, open) = AsyncStream<Void>.makeStream()
        var aheadCancelled: Bool?
        let ahead = Task { @MainActor in
            await workflow.runAsWorkflowTask {
                for await _ in gate {}
                aheadCancelled = Task.isCancelled
            }
        }
        await Task.yield()
        let check = Task { @MainActor in await workflow.checkRetractionsAgain() }
        guard await Self.waitUntil({ workflow.isCheckingRetractionsAgain }) else {
            open.finish()
            return XCTFail("Check again never began waiting")
        }

        workflow.cancelCheckAgain()
        XCTAssertTrue(workflow.checkAgainStopRequested, "the badge's Cancel is disabled while it waits")
        open.finish()
        await ahead.value
        await check.value

        XCTAssertEqual(aheadCancelled, false, "the work ahead is not stopped")
        XCTAssertEqual(asked.calls, 0, "a stopped Check again asks nothing")
        XCTAssertTrue(workflow.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainStopped) == true)
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true, "#675")
    }

    /// #675: a stop the check did not throw for still warns by the label, never by the answers it threw away.
    func testAStopTheCheckDidNotThrowForStillWarnsByTheLabel() async {
        let (session, documents) = makeSession(
            ["10.1000/a", "10.1000/b"], cited: [0, 1], run: [0: Self.check("clear"), 1: Self.check("clear")])
        let workflow = restore(session)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        let retracted = Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day))
        workflow.useRetractionCheck { papers in
            await MainActor.run { workflow.cancelCheckAgain() }
            return Dictionary(papers.map { ($0, retracted) }) { first, _ in first }
        }

        await workflow.checkRetractionsAgain()

        let warning = workflow.retractionSavedWorkWarning ?? ""
        XCTAssertTrue(warning.contains("• Study 0: Retracted"), warning)
        XCTAssertFalse(warning.contains("Study 1"), "an answer not stored warns of nothing")
        XCTAssertEqual(documents[1].retractionCheck, Self.check("clear"), "nothing is stored")
    }

    /// #663, #675: a cancellation nobody asked for reads as a failure, still warning by the label.
    func testAnUnaskedCancellationIsAFailure() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        workflow.useRetractionCheck { _ in throw CancellationError() }

        await workflow.checkRetractionsAgain()

        XCTAssertTrue(workflow.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainFailed) == true)
        XCTAssertTrue(workflow.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
    }

    /// A second tap while *Check again* runs asks nothing and leaves the first
    /// to finish (the guard is set before any wait).
    func testASecondTapDuringCheckAgainAsksNothing() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let asked = Asked()
        let workflow = restore(session, asked: asked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        workflow.useRetractionCheck { _ in
            asked.calls += 1
            for await _ in gate {}
            return [:]
        }
        let running = Task { @MainActor in await workflow.checkRetractionsAgain() }
        guard await Self.waitUntil({ asked.calls > 0 }) else {
            open.finish()
            return XCTFail("the check never asked")
        }

        await workflow.checkRetractionsAgain()
        XCTAssertEqual(asked.calls, 1, "the second tap asks nothing")
        XCTAssertTrue(workflow.isCheckingRetractionsAgain, "the first is still running")
        XCTAssertEqual(workflow.retractionSavedWorkLine, RetractionText.checkingAgainLine,
                       "this window's own check is no other window's")

        open.finish()
        await running.value
        XCTAssertEqual(asked.calls, 1)
        XCTAssertFalse(workflow.isCheckingRetractionsAgain)
    }

    /// A second tap while *Check again* still waits behind earlier work asks
    /// nothing either, and leaves the line alone: this window's own check is
    /// not another window's, which the session hold alone would say.
    func testASecondTapWhileCheckAgainWaitsAsksNothing() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let asked = Asked()
        let workflow = restore(session, asked: asked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let ahead = Task { @MainActor in
            await workflow.runAsWorkflowTask { for await _ in gate {} }
        }
        await Task.yield()
        let restored = workflow.retractionSavedWorkLine
        XCTAssertNotNil(restored, "control: the saved-work line is shown")
        let check = Task { @MainActor in await workflow.checkRetractionsAgain() }
        guard await Self.waitUntil({ workflow.isCheckingRetractionsAgain }) else {
            open.finish()
            return XCTFail("Check again never began waiting")
        }
        let line = workflow.retractionSavedWorkLine
        XCTAssertEqual(line, restored, "control: the first check waits, its body (the checking line) not yet begun")

        await workflow.checkRetractionsAgain()
        XCTAssertEqual(workflow.retractionSavedWorkLine, line)
        XCTAssertEqual(asked.calls, 0, "the first still waits; the second asked nothing")
        XCTAssertTrue(workflow.isCheckingRetractionsAgain, "the first still waits")

        open.finish()
        await ahead.value
        await check.value
        XCTAssertEqual(asked.calls, 1, "only the first asks")
        XCTAssertFalse(workflow.isCheckingRetractionsAgain)
    }

    /// #711: two windows on one session check it again once at a time; the second is told why.
    func testASecondWindowCannotCheckTheSameSessionAgainMeanwhile() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let firstAsked = Asked()
        let first = restore(session, asked: firstAsked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        first.useRetractionCheck { _ in
            firstAsked.calls += 1
            for await _ in gate {}
            return [:]
        }
        let secondAsked = Asked()
        let second = restore(session, asked: secondAsked)
        let otherAsked = Asked()
        let other = restore(makeSession(["10.1000/b"], cited: [0], run: [0: Self.check("clear")]).0, asked: otherAsked)
        let running = Task { @MainActor in await first.checkRetractionsAgain() }
        guard await Self.waitUntil({ firstAsked.calls > 0 }) else {
            open.finish()
            return XCTFail("the first window never asked")
        }

        await second.checkRetractionsAgain()
        XCTAssertEqual(secondAsked.calls, 0, "the second window asks nothing")
        XCTAssertTrue(second.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainElsewhere) == true)
        XCTAssertFalse(second.isCheckingRetractionsAgain)
        await second.checkRetractionsAgain()
        XCTAssertEqual(secondAsked.calls, 0, "a refusal leaves the first window's hold in place")
        await other.checkRetractionsAgain()
        XCTAssertEqual(otherAsked.calls, 1, "control: another session is checked meanwhile")

        open.finish()
        await running.value
        await second.checkRetractionsAgain()
        XCTAssertEqual(secondAsked.calls, 1, "once the first is done, the second checks")
    }

    /// #711: a check stopped while it waits behind earlier work frees its session
    /// at once (a restore in the same window, or a closed window), not when that work ends.
    func testAStoppedCheckAgainFreesItsSessionWhileTheWorkAheadRuns() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let firstAsked = Asked()
        let first = restore(session, asked: firstAsked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let ahead = Task { @MainActor in
            await first.runAsWorkflowTask { for await _ in gate {} }
        }
        await Task.yield()
        let check = Task { @MainActor in await first.checkRetractionsAgain() }
        while !first.isCheckingRetractionsAgain { await Task.yield() }
        let secondAsked = Asked()
        let second = restore(session, asked: secondAsked)

        await second.checkRetractionsAgain()
        XCTAssertEqual(secondAsked.calls, 0, "control: the waiting check holds the session")
        XCTAssertTrue(second.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainElsewhere) == true)

        first.cancelCheckAgain()
        await second.checkRetractionsAgain()
        XCTAssertEqual(secondAsked.calls, 1, "a stopped check frees the session while the work ahead runs")
        XCTAssertFalse(second.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainElsewhere) == true)

        // the stopped check, ending later, must not free a hold it no longer owns
        let (secondGate, openSecond) = AsyncStream<Void>.makeStream()
        second.useRetractionCheck { _ in
            secondAsked.calls += 1
            for await _ in secondGate {}
            return [:]
        }
        let secondRunning = Task { @MainActor in await second.checkRetractionsAgain() }
        guard await Self.waitUntil({ secondAsked.calls > 1 }) else {
            open.finish(); openSecond.finish()
            return XCTFail("the second window never asked again")
        }
        open.finish()
        await ahead.value
        await check.value
        XCTAssertEqual(firstAsked.calls, 0, "a stopped check asks nothing")
        XCTAssertFalse(first.retractionSavedWorkLine?.contains(RetractionText.checkAgainStopped) == true,
                       "the second window stored the session's answers meanwhile (#714)")
        let thirdAsked = Asked()
        let third = restore(session, asked: thirdAsked)
        await third.checkRetractionsAgain()
        XCTAssertEqual(thirdAsked.calls, 0, "the second window's hold survives the stopped check's end")
        openSecond.finish()
        await secondRunning.value
    }

    /// #714: a refused *Check again* keeps what this window's own last one
    /// said, a stopped check's clause and its label's warning among it, until a restore.
    func testARefusalKeepsThisWindowsEarlierCaveat() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        let second = restore(session)
        second.useRetractionCheck { _ in
            await MainActor.run { second.cancelCheckAgain() }
            try Task.checkCancellation()
            return [:]
        }
        await second.checkRetractionsAgain()
        XCTAssertTrue(second.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true)
        let stopped = second.retractionSavedWorkLine ?? ""
        XCTAssertTrue(stopped.hasSuffix(RetractionText.checkAgainStopped), stopped)
        guard let release = await holdCheckAgain(session) else { return XCTFail("the first window never asked") }

        await second.checkRetractionsAgain()

        XCTAssertEqual(second.retractionSavedWorkLine, stopped + RetractionText.checkAgainElsewhere)
        XCTAssertTrue(second.retractionSavedWorkWarning?.contains("• Study 0: Retracted") == true, "the label still warns")
        await release()
        XCTAssertTrue(
            second.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainElsewhere) == true,
            "a check that stored nothing redraws nothing")

        // control: a restore is a fresh view, so a later refusal has no earlier caveat to keep
        second.restoreForViewing(session)
        guard let releaseAgain = await holdCheckAgain(session) else { return XCTFail("the third window never asked") }
        await second.checkRetractionsAgain()
        XCTAssertFalse(second.retractionSavedWorkLine?.contains(RetractionText.checkAgainStopped) == true)
        XCTAssertNil(second.retractionSavedWorkWarning)
        await releaseAgain()
    }

    /// #714: when another window's *Check again* saves its answers, a window
    /// showing the same session redraws its line, which they supersede, its
    /// refusal note and earlier caveat with it; another session's is untouched.
    func testAnotherWindowsStoredCheckRedrawsThisOne() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let retracted = Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day))
        let second = restore(session)
        second.useRetractionCheck { _ in throw CheckFailed() }
        await second.checkRetractionsAgain()
        let firstAsked = Asked()
        let first = restore(session, asked: firstAsked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        first.useRetractionCheck { papers in
            firstAsked.calls += 1
            for await _ in gate {}
            return Dictionary(papers.map { ($0, retracted) }) { first, _ in first }
        }
        // another session's window with a caveat of its own, which a redraw would drop
        let other = restore(makeSession(["10.1000/b"], cited: [0], run: [0: Self.check("clear")]).0)
        other.useRetractionCheck { _ in throw CheckFailed() }
        await other.checkRetractionsAgain()
        let otherLine = other.retractionSavedWorkLine
        XCTAssertTrue(otherLine?.hasSuffix(RetractionText.checkAgainFailed) == true, otherLine ?? "")
        let running = Task { @MainActor in await first.checkRetractionsAgain() }
        guard await Self.waitUntil({ firstAsked.calls > 0 }) else {
            open.finish()
            return XCTFail("the first window never asked")
        }
        await second.checkRetractionsAgain()
        XCTAssertTrue(second.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainElsewhere) == true)
        XCTAssertNil(second.retractionSavedWorkWarning, "control: nothing is stored yet")

        open.finish()
        await running.value

        XCTAssertEqual(documents[0].retractionCheck, retracted)
        XCTAssertEqual(second.retractionSavedWorkLine, first.retractionSavedWorkLine)
        XCTAssertFalse(second.retractionSavedWorkLine?.contains(RetractionText.checkAgainFailed) == true)
        XCTAssertTrue(second.retractionSavedWorkWarning?.contains("• Study 0: Retracted on") == true,
                      second.retractionSavedWorkWarning ?? "")
        XCTAssertEqual(other.retractionSavedWorkLine, otherLine, "another session is not redrawn")

        // the superseded caveat stays gone: a later refusal does not bring it back
        guard let release = await holdCheckAgain(session) else { return XCTFail("the third window never asked") }
        await second.checkRetractionsAgain()
        XCTAssertFalse(second.retractionSavedWorkLine?.contains(RetractionText.checkAgainFailed) == true,
                       second.retractionSavedWorkLine ?? "")
        await release()
    }

    /// #714: a refusal keeps what this window's own *Check again* that stored
    /// its answers said, the causes it named among it.
    func testARefusalKeepsAStoredCheckAgainsCauses() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("unchecked")])
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)),
        ])
        await workflow.checkRetractionsAgain()
        let line = workflow.retractionSavedWorkLine ?? ""
        XCTAssertEqual(line, "Retraction status could not be checked: \(Self.uncheckedCauses)")
        guard let release = await holdCheckAgain(session) else { return XCTFail("the other window never asked") }

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(workflow.retractionSavedWorkLine, line + RetractionText.checkAgainElsewhere)
        await release()
    }

    /// #714: a check stopped while it waits behind earlier work frees its
    /// session (#711); when another window then stores that session's answers,
    /// the stopped one ends showing them, never calling them the run's record.
    func testAStoppedCheckOvertakenElsewhereShowsTheStoredAnswers() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let retracted = Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day))
        let first = restore(session)
        let (gate, open) = AsyncStream<Void>.makeStream()
        let ahead = Task { @MainActor in
            await first.runAsWorkflowTask { for await _ in gate {} }
        }
        await Task.yield()
        let check = Task { @MainActor in await first.checkRetractionsAgain() }
        while !first.isCheckingRetractionsAgain { await Task.yield() }
        first.cancelCheckAgain()
        let second = restore(session, answers: ["10.1000/a": retracted])
        await second.checkRetractionsAgain()
        XCTAssertEqual(documents[0].retractionCheck, retracted, "control: the other window stored its answers")

        open.finish()
        await ahead.value
        await check.value

        XCTAssertEqual(first.retractionSavedWorkLine, second.retractionSavedWorkLine)
        XCTAssertFalse(first.retractionSavedWorkLine?.contains(RetractionText.checkAgainStopped) == true,
                       first.retractionSavedWorkLine ?? "")
        XCTAssertTrue(first.retractionSavedWorkWarning?.contains("• Study 0: Retracted on") == true,
                      first.retractionSavedWorkWarning ?? "")
    }

    /// #714: a window whose own work cleared its saved-work line is not given
    /// one back when another window's *Check again* stores the session's answers.
    func testAStoredCheckLeavesAWindowAtWorkAlone() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let working = restore(session)
        await working.retryFailedDocuments(pmids: [documents[0].pmid])
        XCTAssertNil(working.retractionSavedWorkLine, "control: the work cleared the line")
        let retracted = Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day))
        let other = restore(session, answers: ["10.1000/a": retracted])

        await other.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck, retracted, "control: the other window stored its answers")
        XCTAssertNil(working.retractionSavedWorkLine)
        XCTAssertNil(working.retractionSavedWorkWarning)
    }

    /// Starts another window's *Check again* on `session` and holds it at its
    /// lookup, so this session is refused elsewhere until the returned release
    /// is awaited; the held check then fails, storing nothing.
    ///
    /// - Returns: The release, or `nil` when the check never reached its lookup.
    private func holdCheckAgain(_ session: FactCheckSession) async -> (() async -> Void)? {
        let asked = Asked()
        let holder = restore(session, asked: asked)
        let (gate, open) = AsyncStream<Void>.makeStream()
        holder.useRetractionCheck { _ in
            asked.calls += 1
            for await _ in gate {}
            throw CheckFailed()
        }
        let running = Task { @MainActor in await holder.checkRetractionsAgain() }
        guard await Self.waitUntil({ asked.calls > 0 }) else {
            open.finish()
            return nil
        }
        return {
            open.finish()
            await running.value
        }
    }

    /// Yields until `condition` holds, or ``startDeadline`` passes, so a check
    /// that never starts fails its test instead of hanging the suite.
    private static func waitUntil(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + startDeadline
        while !condition() {
            guard ContinuousClock.now < deadline else { return false }
            await Task.yield()
        }
        return true
    }

    /// #654: background expiry reaches *Check again* too, and records no stop on the session.
    func testBackgroundExpiryStopsCheckAgain() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session)
        workflow.useRetractionCheck { _ in
            await MainActor.run { NotificationCenter.default.post(name: .backgroundTaskExpiring, object: nil) }
            try await Task.sleep(for: .seconds(30))
            return [:]
        }

        await workflow.checkRetractionsAgain()

        XCTAssertTrue(workflow.retractionSavedWorkLine?.hasSuffix(RetractionText.checkAgainStopped) == true)
        XCTAssertEqual(documents[0].retractionCheck, Self.check("clear"), "nothing is stored")
        XCTAssertEqual(session.stopReason, .completed, "no stop is recorded on the session")
        XCTAssertNil(workflow.stopNotice)
    }

    /// Every lookup down: a decided check stands, and the line says how many
    /// could not be checked again.
    func testCheckAgainOutageKeepsWhatTheRunKnew() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(documents[0].retractionCheck?.isClear, true, "an outage is not knowledge")
        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; 1 paper could not be checked again: \(Self.uncheckedCauses)")
    }

    func testCheckAgainNeverRewritesTheReport() async throws {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [0: Self.check("clear")])
        let before = try XCTUnwrap(session.report?.fullReport)
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("retracted", at: Self.runDay.addingTimeInterval(Self.day)),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(session.report?.fullReport, before)
        XCTAssertNotNil(workflow.retractionSavedWorkWarning, "control: the check did find a retraction")
    }

    /// A session from before the check records no run: *Check again* gives it
    /// a line from what it stored.
    func testCheckAgainDatesASessionThatPredatesTheCheck() async {
        let (session, _) = makeSession(["10.1000/a"], cited: [0], run: [:])
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("clear", at: Self.runDay.addingTimeInterval(Self.day)),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-19")
    }

    /// #684: a session older than the check, given a snapshot by Find More
    /// Evidence: Check again's answer for a scored paper without a run row counts.
    func testCheckAgainCountsAScoredPaperTheRunHasNoRowFor() async {
        let (session, documents) = makeSession(
            ["10.1000/a", "10.1000/b", "10.1000/c"], cited: [0], run: [1: Self.check("clear")])
        documents[2].relevanceScore = nil  // never scored: its outage is not the run's
        let later = Self.runDay.addingTimeInterval(Self.day)
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: later), "10.1000/b": Self.check("clear", at: later),
            "10.1000/c": Self.check("unchecked", at: later),
        ])
        // #685: before Check again, the scored paper with no check is already counted
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-18; 1 paper could not be checked")

        await workflow.checkRetractionsAgain()

        let line = workflow.retractionSavedWorkLine ?? "no line"
        XCTAssertTrue(line.hasPrefix("Retraction status checked 2026-10-19; 1 paper could not be checked"), line)
        XCTAssertFalse(line.contains("again"), line)
    }

    // MARK: - Left out

    func testALeftOutRowSaysWhyAndWhatCheckAgainFound() {
        let (session, documents) = makeSession(["10.1000/a"], cited: [], run: [0: Self.check("retracted")])
        documents[0].relevanceScore = nil
        documents[0].scoredAt = nil
        let shown = session.shownRetractionChecks()[documents[0].id]
        let run = "Excluded: retracted. Retracted on 2026-10-19 (notice 10.1000/notice)"
        XCTAssertEqual(documents[0].retractionExcludedLine(shown: shown), run)

        documents[0].retractionCheck = Self.check("clear", at: Self.runDay.addingTimeInterval(Self.day))
        XCTAssertEqual(
            documents[0].retractionExcludedLine(shown: shown), "\(run). Checked again: No retraction found")
        XCTAssertNil(documents[0].retractionExcludedLine(shown: Self.check("clear")), "control: not left out")
    }

    /// *Check again* in an outage leaves a left-out paper's line as the run's record.
    func testCheckAgainOutageKeepsALeftOutPapersLine() async {
        let (session, documents) = makeSession(["10.1000/a"], cited: [], run: [0: Self.check("retracted")])
        documents[0].relevanceScore = nil
        documents[0].scoredAt = nil
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("unchecked", at: Self.runDay.addingTimeInterval(Self.day)),
        ])

        await workflow.checkRetractionsAgain()

        let shown = session.shownRetractionChecks()[documents[0].id]
        XCTAssertEqual(
            documents[0].retractionExcludedLine(shown: shown),
            "Excluded: retracted. Retracted on 2026-10-19 (notice 10.1000/notice)")
        XCTAssertEqual(documents[0].badgedRetractionCheck(shown: shown)?.isRetracted, true)
    }

    // MARK: - An unreadable snapshot entry (#647)

    /// A snapshot this build cannot read at all, with no stored check to show,
    /// reads "could not be read", never "never checked" (#662); a document
    /// whose own entry or copy cannot be read says so too.
    func testAnUnreadableSnapshotReadsAsUnread() throws {
        let (session, documents) = makeSession(["10.1000/a"], cited: [0], run: [:])
        session.retractionSnapshotJSON = nil
        XCTAssertEqual(restore(session).retractionSavedWorkLine, "Retraction status never checked", "control")
        XCTAssertFalse(session.retractionSnapshotUnread())
        XCTAssertFalse(documents[0].retractionStatusUnread, "control")

        session.retractionSnapshotJSON = "[1, 2]"
        XCTAssertTrue(session.retractionSnapshotUnread())
        XCTAssertEqual(restore(session).retractionSavedWorkLine, RetractionText.statusUnread)
        XCTAssertTrue(documents[0].retractionStatusUnread)

        // one entry: unread for its own document only
        session.retractionSnapshotJSON = try XCTUnwrap(String(
            data: JSONSerialization.data(withJSONObject: [documents[0].id: ["status": 7]]), encoding: .utf8))
        XCTAssertTrue(session.retractionSnapshotUnread())
        XCTAssertTrue(session.retractionSnapshotUnread(for: documents[0].id))
        XCTAssertFalse(session.retractionSnapshotUnread(for: "another"))
        XCTAssertEqual(restore(session).retractionSavedWorkLine, RetractionText.statusUnread)

        // a stored check is shown instead: the line is the check's
        documents[0].retractionCheck = Self.check("clear")
        XCTAssertEqual(restore(session).retractionSavedWorkLine, "Retraction status checked 2026-10-18")
        XCTAssertFalse(documents[0].retractionStatusUnread)

        // the document's own copy unreadable, with no snapshot
        session.retractionSnapshotJSON = nil
        documents[0].retractionCheckJSON = "{\"status\": 7}"
        XCTAssertTrue(documents[0].retractionStatusUnread)
    }

    /// #733, the desktop's #727 rule: over a snapshot this build cannot read
    /// at all, the line is the scored and cited papers' stored checks, one
    /// with none counted unchecked; a failed or stopped *Check again* never
    /// says "still the run's record", which could not be read.
    func testAnUnreadableSnapshotsLineIsTheRunsPapersStoredChecks() async {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c"], cited: [0], run: [:])
        documents[0].retractionCheck = Self.check("clear")
        // not scored, not cited: its older check is not the run's
        documents[2].relevanceScore = nil
        documents[2].scoredAt = nil
        documents[2].retractionCheck = Self.check("clear", at: Self.runDay.addingTimeInterval(-Self.day))
        session.retractionSnapshotJSON = "[1, 2]"
        let workflow = restore(session)
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-18; 1 paper could not be checked")

        workflow.useRetractionCheck { _ in throw CheckFailed() }
        await workflow.checkRetractionsAgain()
        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; 1 paper could not be checked; it could not be checked again")

        // nothing of the run's stored: "could not be read", and still no record said to stand
        documents[0].retractionCheck = nil
        let unread = restore(session)
        XCTAssertEqual(unread.retractionSavedWorkLine, RetractionText.statusUnread)
        unread.useRetractionCheck { _ in throw CheckFailed() }
        await unread.checkRetractionsAgain()
        XCTAssertEqual(unread.retractionSavedWorkLine, RetractionText.statusUnread + "; it could not be checked again")
    }

    /// #733: a cited paper never scored is the run's, one neither scored nor
    /// cited is not; an answered *Check again* counts only the run's papers.
    func testAnAnsweredCheckAgainOverAnUnreadableSnapshotCountsOnlyTheRunsPapers() async {
        let (session, documents) = makeSession(
            ["10.1000/a", "10.1000/b", "10.1000/c", "10.1000/d"], cited: [0, 3], run: [:])
        documents[0].retractionCheck = Self.check("clear")
        for index in [2, 3] {
            documents[index].relevanceScore = nil
            documents[index].scoredAt = nil
        }
        documents[2].retractionCheck = Self.check("clear")
        session.retractionSnapshotJSON = "[1, 2]"
        let later = Self.runDay.addingTimeInterval(Self.day)
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("clear", at: later), "10.1000/b": Self.check("unchecked", at: later),
            // not the run's: its outage is never "could not be checked again"
            "10.1000/c": Self.check("unchecked", at: later), "10.1000/d": Self.check("clear", at: later),
        ])
        XCTAssertEqual(workflow.retractionSavedWorkLine, "Retraction status checked 2026-10-18; 2 papers could not be checked")

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-19; 1 paper could not be checked: \(Self.uncheckedCauses)")
    }

    /// One entry this build cannot read costs only itself, and a later run's
    /// record keeps it as written: a later build may read it.
    func testAnUnreadableSnapshotEntryIsLeftOutAndKept() throws {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        _ = session.recordRetractionSnapshot(["a": Self.check("retracted")])
        var written = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(session.retractionSnapshotJSON).utf8)) as? [String: Any]
        )
        written["b"] = ["status": 7]
        session.retractionSnapshotJSON = String(
            data: try JSONSerialization.data(withJSONObject: written), encoding: .utf8
        )

        XCTAssertEqual(session.retractionSnapshot(), ["a": Self.check("retracted")])

        _ = session.recordRetractionSnapshot(["c": Self.check("clear")])
        XCTAssertEqual(session.retractionSnapshot(), ["a": Self.check("retracted"), "c": Self.check("clear")])
        let kept = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(try XCTUnwrap(session.retractionSnapshotJSON).utf8)) as? [String: Any]
        )
        XCTAssertEqual(kept["b"] as? [String: Int], ["status": 7], "the unreadable entry is kept as written")
    }

    /// A snapshot the earlier build wrote (one `JSONEncoder` pass over the whole
    /// map) reads back unchanged, and a fractional `checkedAt` survives a later
    /// run's rewrite through `JSONSerialization`.
    func testAnEarlierBuildsSnapshotReadsAndRewritesUnchanged() throws {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        let old = ["a": Self.check("retracted", at: Date(timeIntervalSinceReferenceDate: 814_008_600.123_456_7))]
        session.retractionSnapshotJSON = String(data: try JSONEncoder().encode(old), encoding: .utf8)
        XCTAssertEqual(session.retractionSnapshot(), old)
        _ = session.recordRetractionSnapshot(["c": Self.check("clear")])
        XCTAssertEqual(session.retractionSnapshot()["a"], old["a"])
    }

    /// #726: a snapshot unreadable as a whole is never written over.
    func testASnapshotUnreadableAsAWholeIsNeverWrittenOver() {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        for text in ["not json", "[1]", "\"text\""] {
            session.retractionSnapshotJSON = text
            XCTAssertFalse(session.recordRetractionSnapshot(["c": Self.check("clear")]), text)
            XCTAssertEqual(session.retractionSnapshotJSON, text)
        }
        session.retractionSnapshotJSON = nil
        XCTAssertTrue(session.recordRetractionSnapshot(["c": Self.check("clear")]), "control: none yet")
        XCTAssertEqual(session.retractionSnapshot(), ["c": Self.check("clear")])
    }

    /// Control: a document checked again is replaced.
    func testASnapshotEntryCheckedAgainIsReplaced() {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        context.insert(session)
        _ = session.recordRetractionSnapshot(["a": Self.check("unchecked")])
        _ = session.recordRetractionSnapshot(["a": Self.check("retracted")])
        XCTAssertEqual(session.retractionSnapshot(), ["a": Self.check("retracted")])
    }
}
