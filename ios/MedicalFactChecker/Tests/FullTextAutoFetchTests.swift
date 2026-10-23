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

    /// The user's full-text score replaces the default, never below their threshold.
    func testTheUsersFullTextScoreSetsTheFloor() {
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 2, autoFetchMinScore: 3), 3)
        XCTAssertEqual(FullTextAutoFetch.minimumScore(minScoreThreshold: 4, autoFetchMinScore: 3), 4)

        let docs = (1...5).map { (n: Int) in makeDocument(pmid: String(n), score: n) }
        let picked = FullTextAutoFetch.documentsToFetch(from: docs, minScoreThreshold: 2, autoFetchMinScore: 3)
        XCTAssertEqual(picked.map { $0.pmid }, ["3", "4", "5"])
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

    /// A retry the reader asks for asks again: a source may have gained a copy.
    /// A paper that has its full text is still not fetched.
    func testARetryAsksAgainForAPaperKnownToHaveNoFullText() {
        let missing = makeDocument(pmid: "1")
        missing.markFullTextUnavailable()
        let held = makeDocument(pmid: "2")
        held.fullTextContent = "Body text."

        let picked = FullTextAutoFetch.documentsToFetch(from: [missing, held], minScoreThreshold: 3, retrying: true)

        XCTAssertEqual(picked.map { $0.pmid }, ["1"])
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
        let result = FullTextResult(
            content: .doi(webURL: doiLink),
            openAccessShortfall: OpenAccessShortfall(source: .unpaywall, failure: .timeout)
        )

        let kept = FullTextAutoFetch.storedLinkKept(documentHoldingALink(), refetched: result)

        XCTAssertEqual(
            kept,
            FullTextAutoFetch.StoredLinkKept(shortfall: OpenAccessShortfall(source: .unpaywall, failure: .timeout))
        )
        XCTAssertEqual(
            kept?.errorDescription,
            "Unpaywall (the request timed out) could not be asked, so a freely available copy may exist. "
                + "Whether this document is open access was not established. "
                + "The PDF link already stored was kept. Try again later."
        )
    }

    /// The refusal is worded by the shortfall's own verb (#435): a source that
    /// answered "did not serve it", and waiting will not change that, nor
    /// configuration that is missing (#466).
    func testTheRefusalSaysWhatTheShortfallSays() {
        let answered = OpenAccessShortfall(source: .landingPage, failure: .httpStatus(403))
        let refusal = FullTextAutoFetch.StoredLinkKept(shortfall: answered)

        XCTAssertEqual(
            refusal.errorDescription,
            "The open-access copy's landing page (HTTP 403 Forbidden) did not serve it, so whether "
                + "this document is open access was not established. The PDF link already stored was kept."
        )
        let unconfigured = FullTextAutoFetch.StoredLinkKept(shortfall: .unpaywallNotConfigured)
        XCTAssertEqual(
            unconfigured.errorDescription,
            OpenAccessShortfall.unpaywallNotConfigured.notice + " The PDF link already stored was kept."
        )
    }

    /// Waiting can help when any entry could not be asked, not only the first.
    func testTheRefusalSaysTryAgainWhenALaterEntryCouldNotBeAsked() {
        let shortfall = OpenAccessShortfall(
            source: .pdf, failure: .httpStatus(404), address: "https://repo.example.org/a.pdf"
        ).appending(OpenAccessShortfall(source: .openAlex, failure: .timeout))

        let refusal = FullTextAutoFetch.StoredLinkKept(shortfall: shortfall)

        XCTAssertTrue(refusal.errorDescription?.hasSuffix(" Try again later.") ?? false)
    }

    /// Controls: a fallback with nothing unsettled is the chain's answer, and
    /// a document holding no link has nothing to keep.
    func testAnAnsweredFallbackOrADocumentWithNoLinkIsApplied() {
        let answered = FullTextResult(content: .doi(webURL: doiLink))
        let unsettled = FullTextResult(
            content: .doi(webURL: doiLink),
            openAccessShortfall: OpenAccessShortfall(source: .unpaywall, failure: .timeout)
        )

        XCTAssertNil(FullTextAutoFetch.storedLinkKept(documentHoldingALink(), refetched: answered))
        XCTAssertNil(FullTextAutoFetch.storedLinkKept(makeDocument(), refetched: unsettled))
    }

    /// A downloaded copy without text carries CORE's entry when CORE, asked
    /// after it, could not be reached (#499). It is no fallback: the file
    /// beats the stored link, so it is applied.
    func testADownloadedScanCarryingCOREsEntryIsApplied() {
        let scan = FullTextResult(
            content: .unpaywall(pdfURL: URL(string: "https://repo.example.org/files/a.pdf")!),
            localPDFPath: "/tmp/full-text-auto-fetch-test-scan.pdf",
            openAccessShortfall: OpenAccessShortfall(source: .core, failure: .timeout)
        )

        XCTAssertNil(FullTextAutoFetch.storedLinkKept(documentHoldingALink(), refetched: scan))
    }

    /// The refusal fails the document in the run, which leaves it as it was.
    func testARefusedRefetchLeavesTheDocumentToBeFetchedNextRun() async throws {
        let document = documentHoldingALink()
        let result = FullTextResult(
            content: .doi(webURL: doiLink),
            openAccessShortfall: OpenAccessShortfall(source: .unpaywall, failure: .connection)
        )

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

    /// A publication is never cut: the windows read all of it.
    func testALongTextIsReturnedWhole() {
        let document = makeDocument()
        let text = String(repeating: "Methods and results. ", count: 5_000) + "The last sentence."
        document.fullTextContent = text

        XCTAssertEqual(FullTextAutoFetch.citationText(for: document), text)
    }

    /// A reference list is never analysed, so a text that is only one is no
    /// full text: the abstract is read.
    func testATextOfOnlyReferencesIsNoCitationText() {
        let document = makeDocument()
        document.fullTextContent = "References\n1. Smith J. A paper. 2020."

        XCTAssertNil(FullTextAutoFetch.citationText(for: document))
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

        let source = ParallelCitationService.sourceSections(for: input)

        XCTAssertEqual(source.noun, "abstract")
        XCTAssertEqual(source.bodies, ["Abstract:\nAbs."])
    }

    /// The full text alone: nothing is cut, so the abstract is not needed beside it.
    func testAShortFullTextIsOnePromptWithoutTheAbstract() {
        let input = CitationInput(
            pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020, fullText: "Body."
        )

        let source = ParallelCitationService.sourceSections(for: input)

        XCTAssertEqual(source.noun, "article")
        XCTAssertEqual(source.bodies, ["Full text:\nBody."])
    }

    /// A text over one window is read in several calls, every part labelled,
    /// and the end of the paper reaches the model.
    func testALongFullTextIsReadInPartsToItsEnd() {
        let text = String(repeating: "Methods and results. ", count: 2_000) + "The last sentence."
        let input = CitationInput(
            pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020, fullText: text
        )

        let prompts = ParallelCitationService.citationPrompts(input: input, claim: "C")

        XCTAssertGreaterThan(prompts.count, 1)
        XCTAssertTrue(prompts[0].contains("Full text (part 1 of \(prompts.count)):"))
        XCTAssertTrue(prompts.last?.contains("The last sentence.") ?? false)
        XCTAssertFalse(prompts.contains { $0.contains("Abstract:") })
    }

    func testAFullTextOfOnlyReferencesReadsTheAbstract() {
        let input = CitationInput(
            pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020,
            fullText: "References\n1. Smith J."
        )

        XCTAssertEqual(ParallelCitationService.sourceSections(for: input).bodies, ["Abstract:\nAbs."])
    }

    /// An empty abstract is still asked about, as before.
    func testAnEmptyAbstractIsStillOneCall() {
        let input = CitationInput(pmid: "1", title: "T", abstract: "", authors: "A", year: 2020)

        XCTAssertEqual(ParallelCitationService.citationPrompts(input: input, claim: "C").count, 1)
    }

    // MARK: - Reading the windows

    private static func usage(_ input: Int) -> LLMUsage {
        LLMUsage(model: "m", provider: nil, inputTokens: input, outputTokens: 1)
    }

    private static func reply(_ passages: String...) -> String {
        let items = passages.map { "{\"text\": \"\($0)\", \"relevance\": \"r\"}" }
        return "{\"passages\": [\(items.joined(separator: ", "))]}"
    }

    private static let longInput = CitationInput(
        pmid: "1", title: "T", abstract: "Abs.", authors: "A", year: 2020,
        fullText: String(repeating: "Methods and results. ", count: 2_000)
    )

    /// One call per window; the overlap's repeats are merged, the usage summed.
    func testEveryWindowIsAskedAndThePassagesMerged() async throws {
        let prompts = ParallelCitationService.citationPrompts(input: Self.longInput, claim: "C")
        var calls = 0

        let result = await ParallelCitationService.extractCitations(from: Self.longInput, claim: "C") { _ in
            calls += 1
            return calls == 1
                ? (Self.reply("Stroke fell by 20%.", "Bleeding rose."), Self.usage(10))
                : (Self.reply("stroke fell  by 20%."), Self.usage(10))
        }

        let success = try XCTUnwrap(result)
        XCTAssertTrue(success.isSuccess)
        XCTAssertEqual(calls, prompts.count)
        XCTAssertEqual(success.passages.map(\.text), ["Stroke fell by 20%.", "Bleeding rose."])
        XCTAssertEqual(success.usage?.inputTokens, 10 * prompts.count)
    }

    /// Passages from part of a paper would pass for the whole of it.
    func testAFailingWindowFailsThePaper() async throws {
        var calls = 0

        let result = await ParallelCitationService.extractCitations(from: Self.longInput, claim: "C") { _ in
            calls += 1
            if calls == 2 { throw URLError(.badServerResponse) }
            return (Self.reply("Stroke fell by 20%."), Self.usage(10))
        }

        let failure = try XCTUnwrap(result)
        XCTAssertTrue(failure.isError)
        XCTAssertTrue(failure.passages.isEmpty)
        XCTAssertEqual(failure.usage?.inputTokens, 10)
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

    /// A text the reader uploaded redoes an abstract-only analysis whatever
    /// the setting; a fetched one does not.
    func testAnUploadRedoesAnAbstractOnlyAnalysisWhateverTheSetting() {
        let document = Document(pmid: "12345678", title: "A Study", abstract: "")
        document.doi = "10.1000/example"
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Study"
        builder.fullTextSearched = false
        document.storeTransparencyResult(builder.build())
        document.fullTextContent = "Body text."

        document.fullTextSource = AppFullTextSource.uploaded.rawValue
        XCTAssertTrue(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: false))

        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        XCTAssertFalse(FullTextAutoFetch.needsTransparencyPass(document, autoFetchEnabled: false))
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

    /// The chain's answers that were not established are not absences, though
    /// none of them is retryable either: each is reported and leaves the
    /// document for the next run (#434, #475, #480). The rule must stay keyed
    /// on `noFullTextAvailable` itself: `isRetryable` is false for all of
    /// them, as it is for an absence, so it cannot tell them apart. The
    /// control is ``testNoFullTextIsRecordedAndIsNotAFailure``.
    func testAnAnswerThatWasNotEstablishedLeavesTheDocumentForARetry() async throws {
        let notEstablished: [FullTextError] = [
            .absenceNotEstablished(.timeout),
            .pmcOpenDataNotEstablished(.httpStatus(503)),
            .pmcOpenDataNotEstablished(.malformedResponse),
            .openAccessNotEstablished(.unpaywallNotConfigured),
            .identifierKindUnresolved("1287966"),
        ]
        for error in notEstablished {
            let document = makeDocument()

            let failures = try await FullTextAutoFetch.retrieve(
                [document],
                fetch: { _ in throw error },
                persist: {}
            )

            XCTAssertEqual(failures.count, 1, "\(error)")
            XCTAssertFalse(document.fullTextAttempted, "\(error)")
        }
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
            fullText: fullTextCharacters.map { String(repeating: "a", count: $0) }
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
        XCTAssertEqual(result.inputs[1].abstract, "Abs.")
        XCTAssertEqual(result.inputs[2].pmid, "3")
    }

    /// Every window is paid for, overlaps included: 40,000 characters are
    /// read as 16,000 + 16,000 + 8,500 = 40,500, or 10,125 tokens.
    func testTheEstimateCountsEveryWindow() {
        let fits = FullTextAutoFetch.fittingBudget(
            [input("1", fullTextCharacters: 40_000)], remainingUSD: 10_125, usdPerInputToken: 1
        )
        let over = FullTextAutoFetch.fittingBudget(
            [input("1", fullTextCharacters: 40_000)], remainingUSD: 10_124, usdPerInputToken: 1
        )

        XCTAssertEqual(fits.droppedCount, 0)
        XCTAssertEqual(over.droppedCount, 1)
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
