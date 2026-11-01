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

/// The retraction screen before scoring: a retracted paper is never scored,
/// stays in its session, and the run's notice counts it; a check that fails
/// or a lookup that is down never reads as clear.
///
/// Scoring goes to a scheme nothing serves, so a document that reaches it is
/// marked failed at once (`scoredAt` set) and nothing reaches the network.
/// The retraction check is an injected closure answering by DOI.
@MainActor
final class RetractionScreenWorkflowTests: XCTestCase {
    private var container: ModelContainer!
    private var context: ModelContext!

    /// No transport serves this scheme, and LLMService does not retry it.
    private static let unservedScheme = URL(string: "nosuch-scheme://x")!

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

    /// A session holding one unscored document per DOI (`nil`: no DOI, and a
    /// bare number states no PubMed ID).
    private func makeSession(_ dois: [String?]) -> (FactCheckSession, [Document]) {
        let session = FactCheckSession(claim: "Aspirin prevents stroke")
        session.pubmedQuery = "aspirin AND stroke"
        context.insert(session)
        let documents = dois.enumerated().map { index, doi in
            let document = Document(pmid: "1000000\(index)", title: "Study \(index)", abstract: "An abstract.")
            document.doi = doi
            document.publicationTypes = ["Journal Article"]
            document.markFullTextUnavailable()
            context.insert(document)
            document.session = session
            return document
        }
        session.documentsFound = documents.count
        try? context.save()
        return (session, documents)
    }

    /// A workflow showing `session`, scoring nowhere, checking with `check`.
    private func restore(_ session: FactCheckSession, check: @escaping RetractionCheck) -> FactCheckWorkflow {
        let workflow = FactCheckWorkflow(modelContext: context, modelContainer: container, settings: .shared)
        workflow.restoreForViewing(session)
        workflow.useServices(
            llm: LLMService(baseURL: Self.unservedScheme, apiKey: "test-key", model: "test-model"),
            pubMed: BMLPubMedService.create(from: .shared)
        )
        workflow.useRetractionCheck(check)
        return workflow
    }

    /// A check closure answering each paper by its DOI from `answers`.
    private static func answering(_ answers: [String?: PaperRetractionCheck]) -> RetractionCheck {
        { papers in
            var out: [RetractionPaper: PaperRetractionCheck] = [:]
            for paper in papers { out[paper] = answers[paper.doi] ?? answers[nil] }
            return out
        }
    }

    private static let notice = StoredRetractionEvidence(
        source: "retraction_watch_export", kind: "retraction", date: "2024-01-02",
        noticeDOI: "10.1000/notice", recordID: "42", rawKind: "Retraction"
    )

    private static func retracted(
        checkedAt: Date = Date(), unanswered: [String] = [], deciding: StoredRetractionEvidence = notice
    ) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: "retracted", deciding: deciding, unanswered: unanswered,
            checkedAt: checkedAt, exportDataAsOf: "2026-10-28", crossrefFailure: nil
        )
    }

    private static func clear(checkedAt: Date = Date()) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: "clear", deciding: nil, unanswered: [],
            checkedAt: checkedAt, exportDataAsOf: "2026-10-28", crossrefFailure: nil
        )
    }

    private static func concern(unanswered: [String]) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: "concern", deciding: nil, unanswered: unanswered,
            checkedAt: Date(), exportDataAsOf: "2026-10-28", crossrefFailure: nil
        )
    }

    private static func unchecked(_ unanswered: [String], exportDataAsOf: String? = nil) -> PaperRetractionCheck {
        PaperRetractionCheck(
            status: "unchecked", deciding: nil, unanswered: unanswered,
            checkedAt: Date(), exportDataAsOf: exportDataAsOf, crossrefFailure: nil
        )
    }

    /// Asks and counts, answering each paper from `answers`.
    private final class Asked: @unchecked Sendable {
        var calls = 0
        var papers: [RetractionPaper] = []
    }

    private static func counting(_ asked: Asked, _ answers: [String?: PaperRetractionCheck]) -> RetractionCheck {
        let answer = answering(answers)
        return { papers in
            asked.calls += 1
            asked.papers += papers
            return try await answer(papers)
        }
    }

    private struct CheckFailed: Error {}

    // MARK: - Exclusion

    func testRetractedDocumentNeverReachesScoring() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.retracted(), "10.1000/b": Self.clear(),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        let (retracted, kept) = (documents[0], documents[1])
        XCTAssertTrue(retracted.isRetracted)
        XCTAssertNil(retracted.scoredAt, "a retracted paper is never scored")
        XCTAssertFalse(retracted.scoreParseFailed)
        XCTAssertTrue(retracted.session === session, "it stays in the session")
        XCTAssertTrue((session.documents ?? []).contains { $0 === retracted })
        XCTAssertFalse(session.unscoredDocuments.contains { $0 === retracted })
        XCTAssertNotNil(kept.scoredAt, "control: the clear paper reached scoring")
        XCTAssertEqual(workflow.retractionNotice, "Retraction check: 1 retracted paper left out.")
        let snapshot = session.retractionSnapshot()
        XCTAssertEqual(snapshot[retracted.id]?.isRetracted, true)
        XCTAssertEqual(snapshot[kept.id]?.isClear, true)
    }

    /// A paper with no DOI or PMID, and one the Retraction Watch data could
    /// not be consulted for: both unchecked, both scored, both counted.
    func testUncheckedDocumentIsScoredAndCounted() async throws {
        let (session, documents) = makeSession([nil, "10.1000/b"])
        let workflow = restore(session, check: Self.answering([
            nil: Self.unchecked(["retraction_watch_export", "crossref"]),
            "10.1000/b": Self.unchecked(["retraction_watch_export"]),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        for document in documents {
            XCTAssertNotNil(document.scoredAt, "an unchecked paper is scored")
            XCTAssertEqual(document.retractionCheck?.isUnchecked, true, "never clear")
            XCTAssertFalse(document.isRetracted)
        }
        XCTAssertEqual(
            workflow.retractionNotice,
            "Retraction check: 2 papers' retraction status could not be checked: "
                + "the Retraction Watch data could not be used (no up-to-date copy is on this device); no DOI or PMID."
        )
    }

    /// Smart search's documents reach scoring through `scoreNewDocuments`.
    func testSmartSearchDocumentsAreScreened() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.retracted(), "10.1000/b": Self.clear(),
        ]))

        try await workflow.scoreNewDocuments(documents.map(\.pmid))

        XCTAssertTrue(documents[0].isRetracted)
        XCTAssertNil(documents[0].scoredAt)
        XCTAssertNotNil(documents[1].scoredAt, "control: the clear paper reached scoring")
        XCTAssertEqual(workflow.retractionNotice, "Retraction check: 1 retracted paper left out.")
    }

    // MARK: - Once per run, and reuse

    /// A retracted paper stays unscored, so both scoring paths meet it; one
    /// whose Crossref lookup did not answer is not reusable, yet a run asks
    /// about it once. The next run asks again.
    func testEachDocumentIsCheckedOncePerRun() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let asked = Asked()
        let workflow = restore(session, check: Self.counting(asked, [
            "10.1000/a": Self.retracted(unanswered: ["crossref"]), "10.1000/b": Self.clear(),
        ]))

        await workflow.retryFailedDocuments(pmids: [])
        try await workflow.scoreNewDocuments([documents[0].pmid])

        XCTAssertEqual(asked.calls, 1)
        XCTAssertEqual(asked.papers.count, 2)
        XCTAssertEqual(workflow.retractionNotice, "Retraction check: 1 retracted paper left out.")

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(asked.calls, 2, "a new run asks again about a check that is not reusable")
        XCTAssertEqual(asked.papers.last?.doi, "10.1000/a")
    }

    /// Ruling 2: a stored check young enough, with every lookup answered, is
    /// used without asking.
    func testAFreshStoredCheckIsReusedWithoutAsking() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        documents[0].retractionCheck = Self.clear(checkedAt: Date().addingTimeInterval(-Self.day))
        let asked = Asked()
        let workflow = restore(session, check: Self.counting(asked, ["10.1000/b": Self.clear()]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(asked.papers.map(\.doi), ["10.1000/b"])
        XCTAssertEqual(session.retractionSnapshot().count, 2, "the reused check is what the run saw")
    }

    // MARK: - An outage never erases a stored verdict

    /// A stored retraction stands against a fresh check that could not
    /// consult a source it had: kept in storage with its time, still used.
    func testAStoredRetractionSurvivesAnOutage() async throws {
        let (session, documents) = makeSession(["10.1000/a"])
        let stored = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        documents[0].retractionCheck = stored
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.unchecked(["retraction_watch_export", "crossref"]),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(documents[0].retractionCheck, stored)
        XCTAssertNil(documents[0].scoredAt)
        XCTAssertEqual(workflow.retractionNotice, "Retraction check: 1 retracted paper left out.")
    }

    /// #651: what one session learned about a paper decides another's, after
    /// the first is deleted too. A finds X retracted (Crossref unanswered, so
    /// not reusable), B's check of X reaches no source, and X is left out.
    func testAnotherSessionsRetractionSurvivesAnOutageAndItsDeletion() async throws {
        let (first, firstDocuments) = makeSession(["10.1000/x"])
        let a = restore(first, check: Self.answering(["10.1000/x": Self.retracted(unanswered: ["crossref"])]))
        await a.retryFailedDocuments(pmids: [])
        XCTAssertTrue(firstDocuments[0].isRetracted)
        context.delete(first)
        try context.save()
        XCTAssertTrue(try context.fetch(FetchDescriptor<Document>()).isEmpty, "the session's documents went with it")

        let (second, secondDocuments) = makeSession(["10.1000/x"])
        let asked = Asked()
        let b = restore(second, check: Self.counting(asked, [
            "10.1000/x": Self.unchecked(["retraction_watch_export", "crossref"]),
        ]))
        await b.retryFailedDocuments(pmids: [])

        XCTAssertEqual(asked.calls, 1, "the record is not reusable, so B asks")
        XCTAssertTrue(secondDocuments[0].isRetracted)
        XCTAssertNil(secondDocuments[0].scoredAt, "left out by what the deleted session learned")
        XCTAssertEqual(b.retractionNotice, "Retraction check: 1 retracted paper left out.")
        XCTAssertEqual(try context.fetch(FetchDescriptor<RetractionCheckRecord>()).count, 1, "one row per paper")
    }

    /// #651: a record another session writes while this run's check is in
    /// flight is read before this run decides and writes back, never written
    /// over. The check of X reaches no source; meanwhile a retraction of X
    /// arrives, and X is left out.
    func testARecordWrittenDuringTheCheckIsNotWrittenOver() async throws {
        let (session, documents) = makeSession(["10.1000/x"])
        let key = try XCTUnwrap(documents[0].retractionPaper.paperKey)
        let answer = Self.answering(["10.1000/x": Self.unchecked(["retraction_watch_export", "crossref"])])
        let workflow = restore(session, check: { papers in
            try await self.recordElsewhere(key, Self.retracted(unanswered: ["crossref"]))
            return try await answer(papers)
        })
        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertTrue(documents[0].isRetracted)
        XCTAssertNil(documents[0].scoredAt, "left out by the record that arrived")
        let records = try context.fetch(FetchDescriptor<RetractionCheckRecord>())
        XCTAssertEqual(records.count, 1, "one row per paper")
        XCTAssertEqual(RetractionCheckRecord.check(records.first?.checkJSON)?.isRetracted, true)
    }

    /// Another session's `check`, written as the paper's record only.
    private func recordElsewhere(_ key: String, _ check: PaperRetractionCheck) throws {
        let json = try XCTUnwrap(String(data: JSONEncoder().encode(check), encoding: .utf8))
        context.insert(RetractionCheckRecord(paperKey: key, checkJSON: json))
        try context.save()
    }

    /// A stored clear stands in storage, but the run is shown the fresh
    /// unchecked: a clear resting on a lookup now down is not knowledge.
    func testAStoredClearIsNotUsedAgainstAnOutage() async throws {
        let (session, documents) = makeSession(["10.1000/a"])
        let stored = Self.clear(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        documents[0].retractionCheck = stored
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.unchecked(["crossref"], exportDataAsOf: "2026-10-28"),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(documents[0].retractionCheck, stored, "storage keeps the answered check")
        XCTAssertEqual(session.retractionSnapshot()[documents[0].id]?.isUnchecked, true)
        XCTAssertEqual(
            RetractionBadge.Content(check: session.shownRetractionChecks()[documents[0].id])?.text,
            "NOT CHECKED", "badged by the run's check, not the stored clear"
        )
        XCTAssertNotNil(documents[0].scoredAt)
        XCTAssertEqual(
            workflow.retractionNotice,
            "Retraction check: 1 paper's retraction status could not be checked: Crossref had no usable answer for the DOI."
        )
    }

    /// The desktop's `_label_only_unreadable`: a stored retraction resting on
    /// PubMed's label stands while the document has no label recorded (its
    /// silence is not a corrected label); a recorded label without it clears.
    func testALabelRetractionStandsWhileTheLabelIsNotRecorded() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let label = StoredRetractionEvidence(
            source: "pubmed_label", kind: "retraction", date: nil, noticeDOI: nil, recordID: nil, rawKind: nil
        )
        let stored = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day), deciding: label)
        documents[0].publicationTypes = nil
        for document in documents { document.retractionCheck = stored }
        let asked = Asked()
        let workflow = restore(session, check: Self.counting(asked, [
            "10.1000/a": Self.clear(), "10.1000/b": Self.clear(),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(asked.papers.first { $0.doi == "10.1000/a" }?.publicationTypes, [], "not recorded is asked as none")
        XCTAssertEqual(documents[0].retractionCheck, stored)
        XCTAssertTrue(documents[0].isRetracted)
        XCTAssertNil(documents[0].scoredAt)
        XCTAssertEqual(documents[1].retractionCheck?.isClear, true, "control: a recorded label without it clears")
        XCTAssertNotNil(documents[1].scoredAt)
    }

    /// #688, as the desktop's `check` and Android (#671): a paper two
    /// documents share is asked about once, from both documents' evidence,
    /// so the one that knows less is never scored unchecked.
    func testAPaperTwoDocumentsShareIsCheckedOnceFromBothDocumentsEvidence() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/a"])
        documents[1].publicationTypes = nil
        let asked = Asked()
        let (outage, found) = (Self.unchecked(["crossref"]), Self.retracted(unanswered: ["crossref"]))
        // Crossref is down; only a check that sees document 0's record finds the retraction
        let workflow = restore(session) { papers in
            asked.papers += papers
            var out: [RetractionPaper: PaperRetractionCheck] = [:]
            for paper in papers { out[paper] = paper.publicationTypes.isEmpty ? outage : found }
            return out
        }

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(asked.papers.count, 1, "asked once")
        XCTAssertEqual(asked.papers.first?.publicationTypes, ["Journal Article"])
        for document in documents {
            XCTAssertTrue(document.isRetracted)
            XCTAssertNil(document.scoredAt, "neither document of a retracted paper is scored")
            XCTAssertEqual(session.retractionSnapshot()[document.id]?.isRetracted, true)
        }
        let key = try XCTUnwrap(documents[0].retractionPaper.paperKey)
        let records = try XCTUnwrap(RetractionCheckRecord.byKey([key], in: context)[key])
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(RetractionCheckRecord.check(records[0].checkJSON)?.isRetracted, true)
    }

    /// #688: a retraction one document of a paper stored survives an outage
    /// for the other document too, which had no check of its own.
    func testAStoredRetractionOfAPaperTwoDocumentsShareSurvivesAnOutageForBoth() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/a"])
        documents[0].retractionCheck = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        let workflow = restore(session, check: Self.answering([nil: Self.unchecked(["retraction_watch_export", "crossref"])]))

        await workflow.retryFailedDocuments(pmids: [])

        for document in documents {
            XCTAssertTrue(document.isRetracted)
            XCTAssertNil(document.scoredAt)
        }
    }

    /// #688: a paper's label is recorded when any of its documents recorded
    /// it, so a stored label retraction is replaced for both of them, as the
    /// control in ``testALabelRetractionStandsWhileTheLabelIsNotRecorded()``
    /// replaces it for a document that recorded the label.
    func testAPaperTwoDocumentsShareHasItsLabelRecordedByEither() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/a"])
        let label = StoredRetractionEvidence(
            source: "pubmed_label", kind: "retraction", date: nil, noticeDOI: nil, recordID: nil, rawKind: nil
        )
        let stored = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day), deciding: label)
        documents[0].publicationTypes = nil
        for document in documents { document.retractionCheck = stored }
        let workflow = restore(session, check: Self.answering(["10.1000/a": Self.clear()]))

        await workflow.retryFailedDocuments(pmids: [])

        for document in documents {
            XCTAssertEqual(document.retractionCheck?.isClear, true)
            XCTAssertNotNil(document.scoredAt)
        }
    }

    /// The report names the papers its run left out, by the run's own check:
    /// a stored check changed afterwards does not rewrite it. Through the
    /// no-evidence report, which needs no model; the cited path passes the
    /// same section to `ReportFormatter.fullReport`.
    func testTheReportNamesWhatTheRunLeftOut() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.retracted(), "10.1000/b": Self.clear(),
        ]))
        await workflow.retryFailedDocuments(pmids: [])
        documents[0].retractionCheck = Self.clear()

        let made = try await workflow.regenerateReportWithNewEvidence(analyzeTransparencyUsing: { _, _, _ in
            XCTFail("nothing is relevant, so nothing is rated")
            throw CancellationError()
        })

        XCTAssertTrue(made)
        let report = try XCTUnwrap(session.report?.fullReport)
        XCTAssertTrue(report.hasPrefix("> **Retraction check:** 1 retracted paper left out.\n\n"), report)
        XCTAssertTrue(report.contains(RetractionText.leftOutHeading), report)
        XCTAssertTrue(report.contains("- Study 0. Retracted 2024-01-02; notice 10.1000/notice"), report)
        XCTAssertFalse(report.contains("- Study 1."), "control: the clear paper is not left out")
    }

    /// A report the screening run writes itself names why papers are
    /// unchecked, as the run's notice does.
    func testTheRunsOwnReportNamesTheCauses() async throws {
        let (session, _) = makeSession([nil])
        let workflow = restore(session, check: Self.answering([
            nil: Self.unchecked(["retraction_watch_export", "crossref"]),
        ]))

        await workflow.proceedWithCurrentDocuments()

        let report = try XCTUnwrap(session.report?.fullReport)
        XCTAssertTrue(report.hasPrefix(
            "> **Retraction check:** 1 paper's retraction status could not be checked: no DOI or PMID.\n\n"), report)
    }

    /// #657: a paper scored before the session was ever screened (Find More
    /// Evidence on a session older than the check) is counted unchecked, never
    /// left to read as clear, and no run's cause is put on it.
    func testAPaperScoredBeforeAnyScreenIsCountedUnchecked() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        documents[0].relevanceScore = 1
        documents[0].scoredAt = Date()
        let workflow = restore(session, check: Self.answering(["10.1000/b": Self.clear()]))
        await workflow.retryFailedDocuments(pmids: [])
        XCTAssertNil(session.retractionSnapshot()[documents[0].id], "the earlier paper was not screened")

        _ = try await workflow.regenerateReportWithNewEvidence(analyzeTransparencyUsing: { _, _, _ in
            XCTFail("nothing is relevant, so nothing is rated")
            throw CancellationError()
        })

        let report = try XCTUnwrap(session.report?.fullReport)
        XCTAssertTrue(report.hasPrefix(
            "> **Retraction check:** 1 paper's retraction status could not be checked.\n\n"), report)
    }

    /// Control for the rule above: it covers a label verdict only. A stored
    /// Retraction Watch retraction on a document with no label recorded is
    /// replaced by a fresh clear every lookup answered (a reinstatement).
    func testANoticeRetractionIsReplacedWhileTheLabelIsNotRecorded() async throws {
        let (session, documents) = makeSession(["10.1000/a"])
        documents[0].publicationTypes = nil
        documents[0].retractionCheck = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        let workflow = restore(session, check: Self.answering(["10.1000/a": Self.clear()]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(documents[0].retractionCheck?.isClear, true)
        XCTAssertNotNil(documents[0].scoredAt, "reinstated, so scored")
    }

    /// A stored row this build cannot read is kept against an outage, yet
    /// replaced by a retraction, which warns at least as much, whatever was
    /// down (#669), and the run leaves the paper out by the verdict it used:
    /// the notice and the exclusion never disagree. A fresh verdict every
    /// lookup answered replaces such a row.
    func testAnUnreadableRowIsKeptAndTheRunExcludesByItsOwnVerdict() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c"])
        for document in documents { document.retractionCheckJSON = "{\"status\": 7}" }
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.retracted(unanswered: ["crossref"]), "10.1000/b": Self.clear(),
            "10.1000/c": Self.unchecked(["crossref"]),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(documents[2].retractionCheckJSON, "{\"status\": 7}", "an outage never overwrites a row")
        XCTAssertEqual(documents[0].retractionCheck?.isRetracted, true, "a retraction does, a lookup down or not")
        XCTAssertNil(documents[0].scoredAt, "left out as the notice says")
        XCTAssertEqual(
            session.retractedUnscoredDocuments(by: session.shownRetractionChecks()).map(\.id), [documents[0].id],
            "listed as left out, as the notice and report name it"
        )
        XCTAssertEqual(session.documentsToScore, 2, "not counted as still to score")
        XCTAssertFalse(session.unscoredDocuments.contains { $0 === documents[0] })
        XCTAssertEqual(
            workflow.retractionNotice,
            "Retraction check: 1 retracted paper left out; 1 paper's retraction status could not be checked: "
                + "Crossref had no usable answer for the DOI.")
        XCTAssertEqual(documents[1].retractionCheck?.isClear, true)
        XCTAssertNotNil(documents[1].scoredAt)
    }

    /// A concern with a lookup down never overwrites a row this build cannot
    /// read, malformed or written by a newer build: it may hold a retraction
    /// (#669). An answer replaces a newer build's row (the control).
    func testAConcernOrAnOutageNeverOverwritesAnUnreadableRow() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c", "10.1000/d"])
        func newer(_ status: String, _ unanswered: [String]) throws -> String {
            let check = PaperRetractionCheck(
                status: status, deciding: nil, unanswered: unanswered,
                checkedAt: Date(), exportDataAsOf: nil, crossrefFailure: nil
            )
            return try XCTUnwrap(String(data: JSONEncoder().encode(check), encoding: .utf8))
        }
        // a newer build's row with Crossref unanswered: read as this build's, nothing would stand against the outage
        let rows = [
            "{\"status\": 7}", try newer("withdrawn", ["crossref"]),
            try newer("retracted", ["crossref", "pubpeer"]), try newer("withdrawn", ["crossref"]),
        ]
        for (document, row) in zip(documents, rows) { document.retractionCheckJSON = row }
        let workflow = restore(session, check: Self.answering([
            "10.1000/a": Self.concern(unanswered: ["crossref"]), "10.1000/b": Self.unchecked(["crossref"]),
            "10.1000/c": Self.unchecked(["crossref"]), "10.1000/d": Self.clear(),
        ]))

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertEqual(documents.prefix(3).map(\.retractionCheckJSON), Array(rows.prefix(3)))
        XCTAssertEqual(documents[3].retractionCheck?.isClear, true, "an answer replaces it")
    }

    /// The stop prompt's "remaining" and the progress bar do not count a
    /// retracted paper as still to score.
    func testARetractedPaperIsNotCountedAsRemaining() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        documents[0].retractionCheck = Self.retracted()
        session.documentsScored = 1
        session.currentStep = .scoringDocuments

        XCTAssertEqual(session.documentsToScore, 1)
        XCTAssertEqual(session.progressPercent, 60, accuracy: 0.001)
    }

    /// #648 item 4: what is still to score follows the check the run used,
    /// not a later stored one, wherever the two disagree.
    func testWhatIsToScoreFollowsTheRunsCheckNotTheStoredOne() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        session.recordRetractionSnapshot([documents[0].id: Self.retracted(), documents[1].id: Self.clear()])
        documents[0].retractionCheck = Self.clear()  // a later check: the run still left it out
        documents[1].retractionCheck = Self.retracted()  // a later check: the run kept it

        XCTAssertEqual(session.documentsToScore, 1)
        XCTAssertEqual(session.unscoredDocuments.map(\.id), [documents[1].id])
    }

    // MARK: - Failure and cancel

    /// Ruling 3: a check that throws leaves every paper it was given
    /// unchecked for this run, except where a stored verdict stands, and the
    /// run goes on to score.
    func testAFailingCheckLeavesEveryDocumentUncheckedAndTheRunGoesOn() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c"])
        let stored = Self.retracted(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        documents[2].retractionCheck = stored
        let workflow = restore(session, check: { _ in throw CheckFailed() })

        await workflow.retryFailedDocuments(pmids: [])

        for document in documents[0...1] {
            XCTAssertEqual(document.retractionCheck?.isUnchecked, true)
            XCTAssertEqual(document.retractionCheck?.unanswered, ["retraction_watch_export", "crossref"])
            XCTAssertNotNil(document.scoredAt, "the run goes on")
        }
        XCTAssertEqual(documents[2].retractionCheck, stored, "a failure never erases a stored retraction")
        XCTAssertNil(documents[2].scoredAt)
        XCTAssertEqual(
            workflow.retractionNotice,
            "Retraction check: 1 retracted paper left out; "
                + "2 papers' retraction status could not be checked: the check failed."
        )
    }

    /// The desktop's `_label_check` (#656): a check that throws still leaves
    /// out a paper whose record's own label says retracted, with no stored
    /// check or over a stored clear one the label has since overtaken.
    func testAFailedCheckStillLeavesOutAPaperItsLabelRetracts() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b", "10.1000/c"])
        documents[0].publicationTypes = ["Journal Article", "Retracted Publication"]
        documents[2].publicationTypes = ["Retracted Publication"]
        let storedClear = Self.clear(checkedAt: Date().addingTimeInterval(-10 * Self.day))
        documents[2].retractionCheck = storedClear
        let workflow = restore(session, check: { _ in throw CheckFailed() })

        await workflow.retryFailedDocuments(pmids: [])

        for document in [documents[0], documents[2]] {
            XCTAssertEqual(document.retractionCheck?.isDecidedByLabel, true)
            XCTAssertTrue(document.isRetracted)
            XCTAssertNil(document.scoredAt, "left out, never scored")
        }
        XCTAssertNotEqual(documents[2].retractionCheck, storedClear, "the label overtakes the stored clear")
        XCTAssertEqual(documents[1].retractionCheck?.isUnchecked, true, "control: no label, unchecked")
        XCTAssertNotNil(documents[1].scoredAt)
        XCTAssertEqual(
            workflow.retractionNotice,
            "Retraction check: 2 retracted papers left out; "
                + "1 paper's retraction status could not be checked: the check failed."
        )
    }

    /// A cancellation nobody asked for (a lookup's `URLError.cancelled`) is a
    /// failed check, not a stop: the label still decides and the run goes on.
    func testAnUnrequestedCancellationIsAFailedCheck() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        documents[0].publicationTypes = ["Retracted Publication"]
        let workflow = restore(session, check: { _ in throw CancellationError() })

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertTrue(documents[0].isRetracted)
        XCTAssertNil(documents[0].scoredAt)
        XCTAssertEqual(documents[1].retractionCheck?.isUnchecked, true)
        XCTAssertNotNil(documents[1].scoredAt, "the run goes on")
    }

    /// Cancel during the check: nothing claims the papers were checked, and
    /// none is scored.
    func testCancelDuringTheCheckRecordsNothing() async throws {
        let (session, documents) = makeSession(["10.1000/a", "10.1000/b"])
        let workflow = restore(session, check: { _ in
            try await Task.sleep(for: .seconds(60))
            return [:]
        })
        workflow.onProgress = { [weak workflow] _, message in
            if message == "Checking retraction status…" { workflow?.cancelFactCheck() }
        }

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertNil(session.retractionSnapshotJSON)
        for document in documents {
            XCTAssertNil(document.retractionCheckJSON)
            XCTAssertNil(document.scoredAt)
        }
        XCTAssertNil(workflow.retractionNotice)
    }

    /// A check that answers although the run was stopped during it records
    /// nothing either: its answer may be partial.
    func testAStopTheCheckDidNotThrowForRecordsNothing() async throws {
        let (session, documents) = makeSession(["10.1000/a"])
        final class Holder: @unchecked Sendable { weak var workflow: FactCheckWorkflow? }
        let holder = Holder()
        let answer = Self.answering(["10.1000/a": Self.clear()])
        let workflow = restore(session, check: { papers in
            await MainActor.run { holder.workflow?.cancelFactCheck() }
            return try await answer(papers)
        })
        holder.workflow = workflow

        await workflow.retryFailedDocuments(pmids: [])

        XCTAssertNil(session.retractionSnapshotJSON)
        XCTAssertNil(documents[0].retractionCheckJSON)
        XCTAssertNil(documents[0].scoredAt)
    }
}
