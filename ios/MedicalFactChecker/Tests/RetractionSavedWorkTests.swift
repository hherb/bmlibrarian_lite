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
        session.recordRetractionSnapshot(Dictionary(uniqueKeysWithValues: run.map { (documents[$0.key].id, $0.value) }))
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

    /// A document in another session holding `check` for `doi`.
    @discardableResult
    private func storeElsewhere(_ doi: String, _ check: PaperRetractionCheck) -> Document {
        let other = FactCheckSession(claim: "Another claim")
        context.insert(other)
        let document = Document(pmid: "3000000", title: "Same paper", abstract: "An abstract.")
        document.doi = doi
        context.insert(document)
        document.session = other
        document.retractionCheck = check
        try? context.save()
        return document
    }

    /// Counts the papers asked about, answering each from `answers` by DOI.
    private final class Asked: @unchecked Sendable {
        var calls = 0
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
        storeElsewhere("10.1000/a", Self.check("clear")).retractionCheckJSON = "{\"status\": 7}"
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
            "Retraction status checked 2026-10-19; 1 paper could not be checked again")
    }

    /// One paper answered, two decided ones not, and one the run could not
    /// check either: only the decided ones are "not checked again", and the
    /// date is the oldest decided check's.
    func testAPartialOutageCountsTheDecidedPapersItMissed() async {
        let (session, _) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c", "10.1000/d"], cited: [0], run: [
            0: Self.check("clear"), 1: Self.check("clear"), 2: Self.check("clear"), 3: Self.check("unchecked"),
        ])
        let later = Self.runDay.addingTimeInterval(Self.day)
        let workflow = restore(session, answers: [
            "10.1000/a": Self.check("clear", at: later), "10.1000/b": Self.check("unchecked", at: later),
            "10.1000/c": Self.check("unchecked", at: later), "10.1000/d": Self.check("unchecked", at: later),
        ])

        await workflow.checkRetractionsAgain()

        XCTAssertEqual(
            workflow.retractionSavedWorkLine,
            "Retraction status checked 2026-10-18; 1 paper could not be checked: \(Self.uncheckedCauses);"
                + " 2 papers could not be checked again")
    }

    /// Why ``check(_:at:)``'s unchecked answer leaves a paper with a DOI unchecked.
    private static let uncheckedCauses = "the Retraction Watch data could not be used (it downloads over Wi-Fi);"
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
            "Retraction status checked 2026-10-18; 1 paper could not be checked again")
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
}
