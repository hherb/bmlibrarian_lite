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

/// An open-access copy that went unassessed reaches the reader, and stays with
/// the document until a later fetch settles it (#466).
///
/// When Unpaywall, or the landing page it named, could not answer, the chain
/// ends on a fallback, usually a publisher link. Before this the reader saw that
/// link exactly as they saw one for an article with no free copy at all.
final class OpenAccessShortfallNoticeTests: XCTestCase {
    private static let throttled = OpenAccessShortfall(source: .unpaywall, failure: .httpStatus(429))
    private static let doiLink = URL(string: "https://doi.org/10.1234/example")!

    private func makeDocument() -> Document {
        Document(pmid: "12345678", title: "A Study", abstract: "")
    }

    /// A publisher-link fallback the chain settled on because Unpaywall was throttled.
    private func unsettledLink() -> AppFullTextResult {
        AppFullTextResult(
            content: .webURL(Self.doiLink), source: .doi, openAccessShortfall: Self.throttled
        )
    }

    // MARK: - The adapter

    func testTheAdapterCarriesTheShortfallOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(content: .doi(webURL: Self.doiLink), openAccessShortfall: Self.throttled)
        )

        XCTAssertEqual(result.openAccessShortfall, Self.throttled)
    }

    /// The control: an Unpaywall that answered leaves nothing to say.
    func testASettledFallbackCarriesNoShortfall() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(content: .doi(webURL: Self.doiLink))
        )

        XCTAssertNil(result.openAccessShortfall)
    }

    // MARK: - The document

    /// A link-only record caches nothing displayable, and the notice survives
    /// that: it is what the record exists to explain.
    func testALinkOnlyFallbackKeepsItsShortfall() {
        let document = makeDocument()

        document.applyFullTextResult(unsettledLink())

        XCTAssertTrue(document.isLinkOnly)
        XCTAssertNil(document.cachedFullTextResult)
        XCTAssertEqual(document.cachedRetrievalNotice.openAccessShortfall, Self.throttled)
    }

    /// A PDF link the chain could not download carries it on the rebuilt result too.
    func testARebuiltResultCarriesTheShortfall() {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .pdfURL(URL(string: "https://example.org/a.pdf")!),
                source: .europePMC,
                openAccessShortfall: Self.throttled
            )
        )

        XCTAssertEqual(document.cachedFullTextResult?.openAccessShortfall, Self.throttled)
    }

    /// A later fetch that settled the question clears the notice: one left behind
    /// would tell the reader a free copy may exist after Unpaywall said none does.
    func testALaterSettledFetchClearsTheShortfall() {
        let document = makeDocument()
        document.applyFullTextResult(unsettledLink())

        document.applyFullTextResult(AppFullTextResult(content: .webURL(Self.doiLink), source: .doi))

        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
        XCTAssertNil(document.cachedRetrievalNotice.openAccessShortfall)
    }

    func testClearingTheCacheClearsTheShortfall() {
        let document = makeDocument()
        document.applyFullTextResult(unsettledLink())

        document.clearFullTextCache()

        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
    }

    func testMarkingUnavailableClearsTheShortfall() {
        let document = makeDocument()
        document.applyFullTextResult(unsettledLink())

        document.markFullTextUnavailable()

        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
    }

    /// The field is written only when a lookup went unsettled, so a value this
    /// build cannot read still says one did, and is not read as silence.
    func testAnUnreadableStoredShortfallStillSpeaks() {
        let document = makeDocument()
        document.applyFullTextResult(AppFullTextResult(content: .webURL(Self.doiLink), source: .doi))
        document.fullTextOpenAccessShortfallJSON = "{\"schema_version\":99}"

        XCTAssertEqual(
            document.cachedRetrievalNotice.openAccessShortfall,
            OpenAccessShortfall(source: .unpaywall, failure: .requestFailed)
        )
    }

    /// A record written before the field existed keeps its earlier silence.
    func testARecordFromBeforeTheFieldSaysNothing() {
        let document = makeDocument()
        document.applyFullTextResult(AppFullTextResult(content: .webURL(Self.doiLink), source: .doi))

        XCTAssertNil(document.cachedRetrievalNotice.openAccessShortfall)
    }

    // MARK: - The banner

    func testTheBannerSaysNothingWhenNothingWentUnsettled() {
        XCTAssertNil(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: nil,
                openAccessShortfall: nil
            )
        )
    }

    /// Alone, the shortfall raises a note, not a warning: the link shown is
    /// complete in itself.
    func testAShortfallAloneIsANote() throws {
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: nil,
                openAccessShortfall: Self.throttled
            )
        )

        XCTAssertNil(content.message)
        XCTAssertEqual(content.openAccessNotice, Self.throttled.notice)
        XCTAssertFalse(content.isWarning)
    }

    /// Beside a degradation, both facts are said: neither hides the other.
    func testAShortfallBesideADegradationKeepsBoth() throws {
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: .europePMCUnreachable,
                extractionCoverage: nil,
                openAccessShortfall: Self.throttled
            )
        )

        XCTAssertEqual(content.message, .degraded(.europePMCUnreachable))
        XCTAssertEqual(content.openAccessNotice, Self.throttled.notice)
    }

    /// A warning about the text shown stays a warning with the note beside it.
    func testAWarningStaysAWarningBesideTheNote() throws {
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: PDFExtractionCoverage(convertedPages: 3, pageCount: 9),
                openAccessShortfall: Self.throttled
            )
        )

        XCTAssertTrue(content.isWarning)
        XCTAssertNotNil(content.openAccessNotice)
    }

    /// The sentence is the shared contract's (checked in BioMedLit): spot-check
    /// that the app shows that one and not a paraphrase.
    func testTheNoticeIsTheContractSentence() throws {
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: nil,
                openAccessShortfall: Self.throttled
            )
        )

        XCTAssertEqual(
            content.openAccessNotice,
            "Unpaywall (HTTP 429 Too Many Requests) could not be asked, so a freely available copy "
                + "may exist. Whether this document is open access was not established."
        )
    }
}
