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

    /// Control for the two above: a fresh paper of the same score is fetched,
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
}
