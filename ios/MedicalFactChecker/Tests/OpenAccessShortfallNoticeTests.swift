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

    /// The four "open the publisher link straight away" gates hold back while
    /// there is a shortfall or a degradation to explain, and only then.
    func testAWebLinkOpensStraightAwayOnlyWithNothingToExplain() {
        func link(
            _ degradation: FullTextDegradation?, _ shortfall: OpenAccessShortfall?
        ) -> AppFullTextResult {
            AppFullTextResult(
                content: .webURL(Self.doiLink), source: .doi,
                degradation: degradation, openAccessShortfall: shortfall
            )
        }

        XCTAssertTrue(link(nil, nil).hasNothingToExplain)
        XCTAssertFalse(link(nil, Self.throttled).hasNothingToExplain)
        XCTAssertFalse(link(nil, .unpaywallNotConfigured).hasNothingToExplain)
        XCTAssertFalse(link(.europePMCUnreachable, nil).hasNothingToExplain)
        XCTAssertFalse(link(.europePMCUnreachable, Self.throttled).hasNothingToExplain)
    }

    /// A caching note holds the gate back too (#480): opening the browser
    /// first would take the reader past it.
    func testACachingNoteAloneHoldsTheWebLinkBack() {
        let noted = AppFullTextResult(
            content: .webURL(Self.doiLink), source: .doi, pdfNotSavedFrom: Self.unsavedPDF.absoluteString
        )

        XCTAssertFalse(noted.hasNothingToExplain)
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
                openAccessShortfall: nil,
                pdfNotSavedNote: nil
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
                openAccessShortfall: Self.throttled,
                pdfNotSavedNote: nil
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
                openAccessShortfall: Self.throttled,
                pdfNotSavedNote: nil
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
                openAccessShortfall: Self.throttled,
                pdfNotSavedNote: nil
            )
        )

        XCTAssertTrue(content.isWarning)
        XCTAssertNotNil(content.openAccessNotice)
    }

    // MARK: - The caching note (#480)

    private static let unsavedPDF = URL(string: "https://repo.example.org/a.pdf")!

    /// A PDF served and not saved, whose link is the result.
    private func unsavedLink() -> AppFullTextResult {
        AppFullTextResult(
            content: .pdfURL(Self.unsavedPDF),
            source: .unpaywall,
            pdfNotSavedFrom: Self.unsavedPDF.absoluteString
        )
    }

    func testTheAdapterCarriesTheUnsavedPDFOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .unpaywall(pdfURL: Self.unsavedPDF),
                pdfNotSavedFrom: Self.unsavedPDF.absoluteString
            )
        )

        XCTAssertEqual(result.pdfNotSavedFrom, Self.unsavedPDF.absoluteString)
        XCTAssertEqual(
            result.pdfNotSavedNote,
            OpenAccessShortfall.notSavedNote(address: Self.unsavedPDF.absoluteString, linkKept: true)
        )
    }

    /// OpenAlex's PDF, served and cached, maps as Unpaywall's does: the local
    /// file wins over the remote URL, and the source and its badge are
    /// OpenAlex's.
    func testTheAdapterMapsACachedOpenAlexPDFToTheLocalFile() {
        let localPath = "/tmp/bmlibrarian-test/openalex.pdf"
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .openAlex(pdfURL: Self.unsavedPDF),
                contentKind: .extracted,
                extractedText: "The article.",
                localPDFPath: localPath,
                extractionCoverage: PDFExtractionCoverage(convertedPages: 1, pageCount: 1)
            )
        )

        XCTAssertEqual(result.content, .pdfURL(URL(fileURLWithPath: localPath)))
        XCTAssertEqual(result.source, .openAlex)
        XCTAssertEqual(result.source.displayName, "OpenAlex")
        XCTAssertEqual(result.source.iconName, "lock.open")
        XCTAssertNil(result.pdfNotSavedNote)
    }

    /// OpenAlex's PDF served and not saved: its remote link is the result,
    /// and the caching note says only that link is kept.
    func testTheAdapterCarriesAnUnsavedOpenAlexPDFOntoTheAppResult() {
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(
                content: .openAlex(pdfURL: Self.unsavedPDF),
                pdfNotSavedFrom: Self.unsavedPDF.absoluteString
            )
        )

        XCTAssertEqual(result.content, .pdfURL(Self.unsavedPDF))
        XCTAssertEqual(result.source, .openAlex)
        XCTAssertEqual(result.pdfNotSavedFrom, Self.unsavedPDF.absoluteString)
        XCTAssertEqual(
            result.pdfNotSavedNote,
            OpenAccessShortfall.notSavedNote(address: Self.unsavedPDF.absoluteString, linkKept: true)
        )
    }

    /// An address `URL(string:)` re-encodes (a space, a non-ASCII letter)
    /// still reads "only its link is kept": the service hands over the
    /// fetched URL's `absoluteString` as the note's address (pinned in
    /// BioMedLit's `testTheNoteAddressIsTheKeptLinkEvenWhenReEncoded`), and
    /// the document stores that URL's `absoluteString` as its link.
    func testAReEncodedAddressStillKeepsItsLink() throws {
        let raw = "https://repo.example.org/my paper \u{00FC}.pdf"
        let pdfURL = try XCTUnwrap(URL(string: raw))
        XCTAssertNotEqual(pdfURL.absoluteString, raw, "the address must be one URL(string:) re-encodes")
        let result = BioMedLitAdapters.toAppFullTextResult(
            BMLFullTextResult(content: .unpaywall(pdfURL: pdfURL), pdfNotSavedFrom: pdfURL.absoluteString)
        )
        let document = makeDocument()

        document.applyFullTextResult(result)

        XCTAssertTrue(document.holdsOnlyUndownloadedPDFLink)
        XCTAssertEqual(document.fullTextPDFPath, document.fullTextPDFNotSavedFrom)
        XCTAssertTrue(try XCTUnwrap(result.pdfNotSavedNote).contains("so only its link is kept."))
        XCTAssertTrue(try XCTUnwrap(document.storedPDFNotSavedNote).contains("so only its link is kept."))
    }

    /// The document holds the PDF's link as its own, so the note says only
    /// the link is kept, and it survives a reopen.
    func testAStoredUnsavedPDFWhoseLinkIsKeptSaysSo() throws {
        let document = makeDocument()

        document.applyFullTextResult(unsavedLink())

        XCTAssertEqual(document.fullTextPDFNotSavedFrom, document.fullTextPDFPath)
        let note = try XCTUnwrap(document.storedPDFNotSavedNote)
        XCTAssertEqual(
            note,
            "A PDF of this article was found at repo.example.org but could not be saved on this "
                + "device, so only its link is kept. Check the free storage space and try again."
        )
        XCTAssertEqual(document.cachedFullTextResult?.pdfNotSavedNote, note)
    }

    /// The control: an abstract returned instead holds no link, so the PDF
    /// could not be read.
    func testAStoredUnsavedPDFBesideAnAbstractCouldNotBeRead() throws {
        let document = makeDocument()

        document.applyFullTextResult(
            AppFullTextResult(
                content: .html(content: "<p>Abstract.</p>", markdown: "Abstract."),
                source: .europePMC,
                pdfNotSavedFrom: Self.unsavedPDF.absoluteString,
                contentKind: .abstract
            )
        )

        XCTAssertNil(document.fullTextPDFPath)
        XCTAssertTrue(try XCTUnwrap(document.storedPDFNotSavedNote).contains("so it could not be read."))
    }

    /// Every fetch that leaves no note clears the last one, as the shortfall is.
    func testTheUnsavedPDFIsClearedWhereTheShortfallIs() {
        let document = makeDocument()
        document.applyFullTextResult(unsavedLink())
        document.applyFullTextResult(AppFullTextResult(content: .webURL(Self.doiLink), source: .doi))
        XCTAssertNil(document.fullTextPDFNotSavedFrom)

        document.applyFullTextResult(unsavedLink())
        document.clearFullTextCache()
        XCTAssertNil(document.fullTextPDFNotSavedFrom)

        document.applyFullTextResult(unsavedLink())
        document.markFullTextUnavailable()
        XCTAssertNil(document.fullTextPDFNotSavedFrom)
    }

    /// Alone, the caching note is a note of its own, not a warning and not
    /// the open-access notice.
    func testACachingNoteAloneIsANote() throws {
        let note = OpenAccessShortfall.notSavedNote(address: Self.unsavedPDF.absoluteString, linkKept: true)
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: nil,
                openAccessShortfall: nil,
                pdfNotSavedNote: note
            )
        )

        XCTAssertNil(content.message)
        XCTAssertNil(content.openAccessNotice)
        XCTAssertEqual(content.pdfNotSavedNote, note)
        XCTAssertFalse(content.isWarning)
    }

    /// The sentence is the shared contract's (checked in BioMedLit): spot-check
    /// that the app shows that one and not a paraphrase.
    func testTheNoticeIsTheContractSentence() throws {
        let content = try XCTUnwrap(
            ParseWarningBannerContent(
                warnings: JATSParseWarnings(),
                degradation: nil,
                extractionCoverage: nil,
                openAccessShortfall: Self.throttled,
                pdfNotSavedNote: nil
            )
        )

        XCTAssertEqual(
            content.openAccessNotice,
            "Unpaywall (HTTP 429 Too Many Requests) could not be asked, so a freely available copy "
                + "may exist. Whether this document is open access was not established."
        )
    }
}
