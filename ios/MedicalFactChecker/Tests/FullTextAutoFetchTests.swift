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
import BioMedLit
@testable import MedicalFactChecker

/// Which papers the automatic full-text setting fetches, and what citation
/// extraction is given once it has.
final class FullTextAutoFetchTests: XCTestCase {
    override func setUp() {
        super.setUp()
        StringArrayTransformer.register()
    }

    private func makeDocument(
        pmid: String = "12662058",
        score: Int? = 5,
        doi: String? = nil
    ) -> Document {
        let document = Document(pmid: pmid, title: "Title \(pmid)", abstract: "An abstract.")
        document.relevanceScore = score
        document.doi = doi
        return document
    }

    // MARK: - Threshold

    func testTheFloorIsFourWhateverTheUsersThresholdIsBelowIt() {
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 1), 4)
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 3), 4)
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 4), 4)
    }

    /// A paper under the user's own threshold is not in the report.
    func testAHigherUserThresholdRaisesTheFloor() {
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 5), 5)
    }

    // MARK: - Selection

    func testOnlyScoresFourAndFiveAreFetched() {
        let docs = (1...5).map { (n: Int) in makeDocument(pmid: String(n), score: n) }

        let picked = FullTextAutoFetch.documentsToFetch(from: docs, minScoreThreshold: 3)

        XCTAssertEqual(picked.map { $0.pmid }, ["4", "5"])
    }

    func testAnUnscoredDocumentIsNotFetched() {
        let picked = FullTextAutoFetch.documentsToFetch(
            from: [makeDocument(score: nil)], minScoreThreshold: 3
        )
        XCTAssertTrue(picked.isEmpty)
    }

    func testAScoreFourPaperIsSkippedWhenTheThresholdIsFive() {
        let docs = [makeDocument(pmid: "4", score: 4), makeDocument(pmid: "5", score: 5)]

        let picked = FullTextAutoFetch.documentsToFetch(from: docs, minScoreThreshold: 5)

        XCTAssertEqual(picked.map { $0.pmid }, ["5"])
    }

    func testAPaperAlreadyHoldingFullTextIsNotFetchedAgain() {
        let document = makeDocument()
        document.fullTextContent = "Body text."

        XCTAssertTrue(FullTextAutoFetch.documentsToFetch(from: [document], minScoreThreshold: 3).isEmpty)
    }

    /// A recorded "no source had it" is not retried on every run.
    func testAPaperKnownToHaveNoFullTextIsNotAskedAgain() {
        let document = makeDocument()
        document.markFullTextUnavailable()

        XCTAssertTrue(FullTextAutoFetch.documentsToFetch(from: [document], minScoreThreshold: 3).isEmpty)
    }

    /// A PDF link stored without a file or text is fetched again (#464): how
    /// earlier builds stored an Unpaywall landing page as the article's PDF.
    func testAPaperHoldingOnlyAnUndownloadedPDFLinkIsFetchedAgain() {
        let document = makeDocument(doi: "10.1126/science.adk9967")
        document.fullTextFetchedAt = Date()
        document.fullTextSource = "unpaywall"
        document.fullTextPDFPath = "https://hdl.handle.net/2115/95934"
        document.fullTextPDFPathIsLocalFile = false

        XCTAssertTrue(document.holdsOnlyUndownloadedPDFLink)
        XCTAssertEqual(
            FullTextAutoFetch.documentsToFetch(from: [document], minScoreThreshold: 3).count, 1
        )
    }

    /// Controls for the one above: a downloaded file with no text (a scan) and
    /// a PDF whose text was read are not fetched again.
    func testADownloadedPDFIsNotFetchedAgainWithOrWithoutText() {
        let scan = makeDocument(pmid: "1")
        scan.fullTextFetchedAt = Date()
        scan.fullTextPDFPath = "/tmp/scan.pdf"
        scan.fullTextPDFPathIsLocalFile = true
        let read = makeDocument(pmid: "2")
        read.fullTextFetchedAt = Date()
        read.fullTextPDFPath = "https://example.org/a.pdf"
        read.fullTextPDFPathIsLocalFile = false
        read.fullTextContent = "The article."

        XCTAssertFalse(scan.holdsOnlyUndownloadedPDFLink)
        XCTAssertFalse(read.holdsOnlyUndownloadedPDFLink)
        XCTAssertTrue(
            FullTextAutoFetch.documentsToFetch(from: [scan, read], minScoreThreshold: 3).isEmpty
        )
    }

    /// Records stored before the local-file flag existed have it `nil`, and
    /// count as remote: they are most of the pre-#464 landing-page records.
    func testAnUndownloadedLinkWrittenBeforeTheLocalFileFlagIsFetchedAgain() {
        let document = makeDocument(doi: "10.1126/science.adk9967")
        document.fullTextFetchedAt = Date()
        document.fullTextPDFPath = "https://hdl.handle.net/2115/95934"
        document.fullTextPDFPathIsLocalFile = nil

        XCTAssertTrue(document.holdsOnlyUndownloadedPDFLink)
        XCTAssertEqual(
            FullTextAutoFetch.documentsToFetch(from: [document], minScoreThreshold: 3).count, 1
        )
    }

    // MARK: - Keeping a stored link

    private func documentHoldingALink() -> Document {
        let document = makeDocument(doi: "10.1126/science.adk9967")
        document.fullTextFetchedAt = Date()
        document.fullTextPDFPath = "https://repo.example.org/files/a.pdf"
        document.fullTextPDFPathIsLocalFile = false
        return document
    }

    private let doiLink = URL(string: "https://doi.org/10.1126/science.adk9967")!

    /// A fallback the chain settled on because the open-access copy could not
    /// be reached does not replace the stored link (#464).
    func testAFallbackFromAnUnreachableCopyKeepsTheStoredLink() {
        let result = FullTextResult(content: .doi(webURL: doiLink), openAccessShortfall: .timeout)

        let kept = FullTextAutoFetch.storedLinkKept(documentHoldingALink(), refetched: result)

        XCTAssertEqual(kept, FullTextAutoFetch.StoredLinkKept(failure: .timeout))
        XCTAssertNotNil(kept?.errorDescription)
    }

    /// Controls: a fallback with nothing unsettled is the chain's answer, and
    /// a document holding no link has nothing to keep.
    func testAnAnsweredFallbackOrADocumentWithNoLinkIsApplied() {
        let answered = FullTextResult(content: .doi(webURL: doiLink))
        let unsettled = FullTextResult(content: .doi(webURL: doiLink), openAccessShortfall: .timeout)

        XCTAssertNil(FullTextAutoFetch.storedLinkKept(documentHoldingALink(), refetched: answered))
        XCTAssertNil(FullTextAutoFetch.storedLinkKept(makeDocument(), refetched: unsettled))
    }

    /// The refusal fails the document in the run, which leaves it as it was.
    func testARefusedRefetchLeavesTheDocumentToBeFetchedNextRun() async throws {
        let document = documentHoldingALink()
        let result = FullTextResult(content: .doi(webURL: doiLink), openAccessShortfall: .connection)

        let failures = try await FullTextAutoFetch.retrieve(
            [document],
            fetch: { document in
                if let kept = FullTextAutoFetch.storedLinkKept(document, refetched: result) {
                    throw kept
                }
                XCTFail("the fallback was applied")
            },
            persist: {}
        )

        XCTAssertEqual(failures.count, 1)
        XCTAssertEqual(document.fullTextPDFPath, "https://repo.example.org/files/a.pdf")
        XCTAssertTrue(document.holdsOnlyUndownloadedPDFLink)
    }

    /// Control for the not-again tests above: a fresh paper of the same score is fetched,
    /// so those tests are not passing because nothing ever is.
    func testAFreshHighScoringPaperIsFetched() {
        XCTAssertEqual(
            FullTextAutoFetch.documentsToFetch(from: [makeDocument()], minScoreThreshold: 3).count, 1
        )
    }

    func testADocumentWithNothingToLookItUpByIsNotFetched() {
        let nothing = makeDocument(pmid: "  ", doi: "  ")

        XCTAssertTrue(FullTextAutoFetch.documentsToFetch(from: [nothing], minScoreThreshold: 3).isEmpty)
    }

    func testADOIAloneIsEnoughToLookAPaperUp() {
        let preprint = makeDocument(pmid: "", doi: "10.1101/2024.01.01.573000")

        XCTAssertEqual(FullTextAutoFetch.documentsToFetch(from: [preprint], minScoreThreshold: 3).count, 1)
    }

    // MARK: - Citation text

    func testThereIsNoCitationTextWithoutFullText() {
        XCTAssertNil(FullTextAutoFetch.citationText(for: makeDocument()))
    }

    func testAShortTextIsReturnedWhole() {
        let document = makeDocument()
        document.fullTextContent = "  Methods. Results.  "

        let result = FullTextAutoFetch.citationText(for: document, maxCharacters: 100)

        XCTAssertEqual(result?.text, "Methods. Results.")
        XCTAssertEqual(result?.truncated, false)
    }

    func testALongTextIsCutAndSaysSo() {
        let document = makeDocument()
        document.fullTextContent = String(repeating: "a", count: 50)

        let result = FullTextAutoFetch.citationText(for: document, maxCharacters: 10)

        XCTAssertEqual(result?.text.count, 10)
        XCTAssertEqual(result?.truncated, true)
    }

    /// An abstract-only deposit's text is the abstract, already in the prompt;
    /// handing it over as a body would pay for it twice.
    func testAnAbstractOnlyDepositIsNotCitationText() {
        let document = makeDocument()
        document.fullTextContent = "Only the abstract."
        document.fullTextContentKindRaw = "abstract"

        XCTAssertNil(FullTextAutoFetch.citationText(for: document))
    }

    // MARK: - Prompt source

    func testWithoutFullTextThePromptReadsTheAbstractAsBefore() {
        let input = CitationInput(pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020)

        let source = ParallelCitationService.sourceSection(for: input)

        XCTAssertEqual(source.noun, "abstract")
        XCTAssertEqual(source.body, "Abstract:\nAbs.")
    }

    func testWithFullTextThePromptCarriesBothAndNoCutNotice() {
        let input = CitationInput(
            pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020,
            fullText: "Body.", fullTextTruncated: false
        )

        let source = ParallelCitationService.sourceSection(for: input)

        XCTAssertEqual(source.noun, "article")
        XCTAssertTrue(source.body.contains("Abstract:\nAbs."))
        XCTAssertTrue(source.body.contains("Full text:\nBody."))
        XCTAssertFalse(source.body.contains("cut here"))
    }

    func testACutFullTextIsAnnouncedToTheModel() {
        let input = CitationInput(
            pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020,
            fullText: "Body", fullTextTruncated: true
        )

        XCTAssertTrue(ParallelCitationService.sourceSection(for: input).body.contains("cut here"))
    }

    // MARK: - Notice

    @MainActor
    func testAShortFailureListIsNamed() {
        let notice = FactCheckWorkflow.fullTextFailureNotice(for: ["Alpha", "Beta"])

        XCTAssertTrue(notice.contains("Alpha; Beta"))
    }

    @MainActor
    func testALongFailureListIsCounted() {
        let notice = FactCheckWorkflow.fullTextFailureNotice(for: ["a", "b", "c", "d"])

        XCTAssertTrue(notice.contains("4 documents"))
        XCTAssertFalse(notice.contains("a; b"))
    }

    // MARK: - Selection by identifier

    func testAPMCIDAloneIsEnoughToLookAPaperUp() {
        let document = makeDocument(pmid: "")
        document.pmcId = "PMC1234567"

        XCTAssertEqual(FullTextAutoFetch.documentsToFetch(from: [document], minScoreThreshold: 3).count, 1)
    }

    /// A preprint's accession lives in the `pmid` slot, with no PMC ID or DOI.
    func testAPreprintAccessionInThePMIDSlotIsFetched() {
        let preprint = makeDocument(pmid: "PPR123456")

        XCTAssertEqual(FullTextAutoFetch.documentsToFetch(from: [preprint], minScoreThreshold: 3).count, 1)
    }

    // MARK: - Citation text edges

    func testATextOfExactlyTheLimitIsNotCut() {
        let document = makeDocument()
        document.fullTextContent = String(repeating: "a", count: 10)

        let result = FullTextAutoFetch.citationText(for: document, maxCharacters: 10)

        XCTAssertEqual(result?.text.count, 10)
        XCTAssertEqual(result?.truncated, false)
    }

    func testAWhitespaceOnlyTextIsNoCitationText() {
        let document = makeDocument()
        document.fullTextContent = "  \n  "

        XCTAssertNil(FullTextAutoFetch.citationText(for: document))
    }

    // MARK: - Settings gates

    func testCitationFullTextIsGivenOnlyWhenTheSettingIsOn() {
        let document = makeDocument()
        document.fullTextContent = "Body."

        XCTAssertNotNil(FullTextAutoFetch.citationFullText(
            for: document, autoFetchEnabled: true, minScoreThreshold: 3))
        XCTAssertNil(FullTextAutoFetch.citationFullText(
            for: document, autoFetchEnabled: false, minScoreThreshold: 3))
    }

    /// A text fetched by hand for a lower-scored paper must not change its cost.
    func testCitationFullTextIsNotGivenForALowerScoredPaper() {
        let document = makeDocument(score: 3)
        document.fullTextContent = "Body."

        XCTAssertNil(FullTextAutoFetch.citationFullText(
            for: document, autoFetchEnabled: true, minScoreThreshold: 3))
    }

    func testAnUnanalysedDocumentNeedsAPassWhateverTheSetting() {
        let document = makeDocument()

        XCTAssertTrue(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: false))
        XCTAssertTrue(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: true))
    }

    /// An analysis made on the abstract alone is redone once full text is
    /// there, but only when the setting is on.
    func testAnAbstractOnlyAnalysisIsRedoneOnlyWithTheSettingOn() {
        let document = Document(pmid: "12345678", title: "A Study", abstract: "")
        document.doi = "10.1000/example"
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        builder.fullTextSearched = false
        document.storeTransparencyResult(builder.build())
        document.fullTextContent = "Body text."

        XCTAssertFalse(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: false))
        XCTAssertTrue(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: true))
    }

    // MARK: - Retrieval

    private struct Boom: Error {}

    func testRetrievalAppliesEachFetchAndPersists() async throws {
        let docs = [makeDocument(pmid: "1"), makeDocument(pmid: "2")]
        var fetched: [String] = []
        var saves = 0

        let failures = try await FullTextAutoFetch.retrieve(
            docs,
            fetch: { fetched.append($0.pmid) },
            persist: { saves += 1 }
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertEqual(fetched, ["1", "2"])
        XCTAssertEqual(saves, 2)
    }

    /// The expected outcome for a closed-access paper: recorded, not a failure.
    func testNoFullTextIsRecordedAndIsNotAFailure() async throws {
        let document = makeDocument()

        let failures = try await FullTextAutoFetch.retrieve(
            [document],
            fetch: { _ in throw FullTextError.noFullTextAvailable },
            persist: {}
        )

        XCTAssertTrue(failures.isEmpty)
        XCTAssertTrue(document.fullTextAttempted)
    }

    /// Any other error leaves the document untouched, so the next run retries
    /// it, and the loop goes on to the next one.
    func testAnotherErrorIsReportedAndLeavesTheDocumentForARetry() async throws {
        let bad = makeDocument(pmid: "1")
        let good = makeDocument(pmid: "2")

        let failures = try await FullTextAutoFetch.retrieve(
            [bad, good],
            fetch: { if $0.pmid == "1" { throw Boom() } },
            persist: {}
        )

        XCTAssertEqual(failures.map { $0.document.pmid }, ["1"])
        XCTAssertFalse(bad.fullTextAttempted)
        XCTAssertEqual(
            FullTextAutoFetch.documentsToFetch(from: [bad], minScoreThreshold: 3).count, 1
        )
    }

    func testAFailedSaveIsReported() async throws {
        let failures = try await FullTextAutoFetch.retrieve(
            [makeDocument()],
            fetch: { _ in },
            persist: { throw Boom() }
        )

        XCTAssertEqual(failures.count, 1)
    }

    func testCancellationStopsTheLoopRatherThanCountingAsAFailure() async {
        var fetched = 0
        do {
            _ = try await FullTextAutoFetch.retrieve(
                [makeDocument(pmid: "1"), makeDocument(pmid: "2")],
                fetch: { _ in fetched += 1; throw CancellationError() },
                persist: {}
            )
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertEqual(fetched, 1)
    }

    /// A cancelled request surfaces as `URLError.cancelled`, not `CancellationError`.
    func testAURLCancellationAlsoStopsTheLoop() async {
        do {
            _ = try await FullTextAutoFetch.retrieve(
                [makeDocument()],
                fetch: { _ in throw URLError(.cancelled) },
                persist: {}
            )
            XCTFail("cancellation must propagate")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
    }

    // MARK: - Budget

    private func input(_ pmid: String, fullTextCharacters: Int?) -> CitationInput {
        CitationInput(
            pmid: pmid, title: "T", abstract: "Abs.", authors: "A", year: 2020,
            fullText: fullTextCharacters.map { String(repeating: "a", count: $0) },
            fullTextTruncated: false
        )
    }

    func testTextsWithinTheBudgetAreKept() {
        // 400 characters = 100 tokens at $1 each = $100.
        let result = FullTextAutoFetch.fittingBudget(
            [input("1", fullTextCharacters: 400)], remainingUSD: 100, usdPerInputToken: 1
        )

        XCTAssertEqual(result.droppedCount, 0)
        XCTAssertNotNil(result.inputs[0].fullText)
    }

    func testTextsPastTheBudgetFallBackToTheAbstractInOrder() {
        let result = FullTextAutoFetch.fittingBudget(
            [input("1", fullTextCharacters: 400),
             input("2", fullTextCharacters: 400),
             input("3", fullTextCharacters: nil)],
            remainingUSD: 150, usdPerInputToken: 1
        )

        XCTAssertEqual(result.droppedCount, 1)
        XCTAssertNotNil(result.inputs[0].fullText)
        XCTAssertNil(result.inputs[1].fullText)
        XCTAssertFalse(result.inputs[1].fullTextTruncated)
        XCTAssertEqual(result.inputs[1].abstract, "Abs.")
        XCTAssertEqual(result.inputs[2].pmid, "3")
    }

    func testTheBudgetNoticeCountsThePapers() {
        XCTAssertTrue(FullTextAutoFetch.budgetNotice(droppedCount: 1).contains("1 paper "))
        XCTAssertTrue(FullTextAutoFetch.budgetNotice(droppedCount: 3).contains("3 papers"))
    }

    // MARK: - Setting

    @MainActor
    func testTheSettingDefaultsOffPersistsAndResets() {
        let settings = AppSettings.shared
        let key = "auto_fetch_full_text_enabled"
        let original = settings.autoFetchFullTextEnabled
        defer { settings.autoFetchFullTextEnabled = original }

        settings.autoFetchFullTextEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: key))

        settings.resetToDefaults()
        XCTAssertFalse(settings.autoFetchFullTextEnabled)
        XCTAssertFalse(UserDefaults.standard.bool(forKey: key))
    }
}
