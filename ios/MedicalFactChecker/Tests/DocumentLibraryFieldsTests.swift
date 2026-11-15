// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// The shared paper library's file of a fetched text, on `Document` (design
/// §4.4: by digest and kind, never by path), and the library's two sources
/// through the adapter (§4.5).
final class DocumentLibraryFieldsTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)
    private let libraryPath = "/Library/papers/smith-2020/smith-2020.pdf"
    private let why = "library, paper pmid=1: the folder is not reachable"

    private func makeDocument() -> Document {
        Document(pmid: "1", title: "T", abstract: "")
    }

    private func libraryPDF(waiting: Bool = false, failure: String? = nil) -> BioMedLit.FullTextResult {
        BioMedLit.FullTextResult(
            content: .libraryPDF(localPath: libraryPath), localPDFPath: libraryPath,
            libraryFile: LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindPDF),
            libraryFailure: failure, libraryWaiting: waiting
        )
    }

    func testTheLibrarySourceMirrorsTheServices() {
        XCTAssertEqual(AppFullTextSource.library.rawValue, BioMedLit.FullTextSource.library.rawValue)
        XCTAssertEqual(AppFullTextSource.library.displayName, BioMedLit.FullTextSource.library.displayName)
        XCTAssertTrue(AppFullTextSource.library.canDisplayInApp)
    }

    func testTheLibrarysJATSReachesTheAppAsHTML() {
        let app = BioMedLitAdapters.toAppFullTextResult(BioMedLit.FullTextResult(
            content: .libraryJATS(html: "<p>x</p>", markdown: "x"), contentKind: .fulltext,
            libraryFile: LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindJATS)
        ))
        XCTAssertEqual(app.source, .library)
        XCTAssertEqual(app.content, .html(content: "<p>x</p>", markdown: "x"))
        XCTAssertEqual(app.libraryFile, LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindJATS))
        XCTAssertNil(app.libraryWaiting)
    }

    func testTheLibrarysPDFReachesTheAppAsItsFile() {
        let app = BioMedLitAdapters.toAppFullTextResult(libraryPDF())
        XCTAssertEqual(app.source, .library)
        XCTAssertEqual(app.content, .pdfURL(URL(fileURLWithPath: libraryPath)))
        XCTAssertEqual(app.localPDFPath, libraryPath)
    }

    /// The why is kept only when a source waits for the library: a failure
    /// that left nothing waiting (another paper's file) is not a wait.
    func testTheWaitingWhyIsTheFailureOnlyWhenASourceWaits() {
        XCTAssertEqual(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)).libraryWaiting, why)
        XCTAssertNil(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: false, failure: why)).libraryWaiting)
    }

    /// Every library failure reaches the reader, whether or not anything waits.
    func testTheLibraryNoteIsTheFailureWhetherOrNotASourceWaits() {
        XCTAssertEqual(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)).libraryNote, why)
        XCTAssertEqual(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: false, failure: why)).libraryNote, why)
        XCTAssertNil(BioMedLitAdapters.toAppFullTextResult(libraryPDF()).libraryNote)
    }

    func testApplyingAResultStoresItsLibraryFileAndWait() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)))

        XCTAssertEqual(document.fullTextLibrarySHA256, digest)
        XCTAssertEqual(document.fullTextLibraryKind, BioMedLitConstants.libraryKindPDF)
        XCTAssertEqual(document.fullTextLibraryWaiting, why)
        XCTAssertEqual(document.fullTextLibraryNote, why)
        XCTAssertEqual(document.fullTextSource, "library")
        XCTAssertEqual(document.localPDFFilePath, libraryPath)
    }

    /// A later fetch with no library file must not inherit the earlier one.
    func testALaterResultWithoutALibraryFileClearsIt() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)))
        document.applyFullTextResult(.europePMC(html: "<p>x</p>", markdown: "x"))

        XCTAssertNil(document.fullTextLibrarySHA256)
        XCTAssertNil(document.fullTextLibraryKind)
        XCTAssertNil(document.fullTextLibraryWaiting)
        XCTAssertNil(document.fullTextLibraryNote)
    }

    func testClearingTheCacheClearsTheLibraryFields() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)))
        document.clearFullTextCache()

        XCTAssertNil(document.fullTextLibrarySHA256)
        XCTAssertNil(document.fullTextLibraryKind)
        XCTAssertNil(document.fullTextLibraryWaiting)
        XCTAssertNil(document.fullTextLibraryNote)
    }

    func testMarkingUnavailableClearsTheLibraryFields() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)))
        document.markFullTextUnavailable()

        XCTAssertNil(document.fullTextLibrarySHA256)
        XCTAssertNil(document.fullTextLibraryKind)
        XCTAssertNil(document.fullTextLibraryWaiting)
        XCTAssertNil(document.fullTextLibraryNote)
    }

    /// The PDF to find again by digest: only a stored local PDF whose library
    /// file is a PDF.
    func testTheLibraryPDFReferenceIsTheStoredPDFsLibraryFile() {
        let document = makeDocument()
        XCTAssertNil(document.libraryPDFReference, "nothing stored")

        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF()))
        XCTAssertEqual(document.libraryPDFReference,
                       LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindPDF))

        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        XCTAssertNil(document.libraryPDFReference, "a JATS is not the PDF")
    }

    // MARK: - What the reader is told (design §4.6)

    func testNothingIsSaidWithoutALibraryNoteOrFile() {
        let document = makeDocument()
        document.applyFullTextResult(.europePMC(html: "<p>x</p>", markdown: "x"))
        XCTAssertEqual(document.libraryNotices(libraryState: .unreachable(reason: "gone")), [])
        XCTAssertEqual(document.libraryNotices(libraryState: .notChosen), [])
    }

    func testAWaitingSourceSaysWhyItWaits() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: true, failure: why)))
        XCTAssertEqual(document.libraryNotices(libraryState: .notChosen),
                       ["Kept in this app until the paper library can be reached: \(why)."])
    }

    /// A failure that left nothing waiting is still told, in its own sentence.
    func testAFailureWithNothingWaitingIsTold() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(waiting: false, failure: why)))
        XCTAssertEqual(document.libraryNotices(libraryState: .reachable(folderName: "L", path: "/L")),
                       ["The paper library could not be used for this paper: \(why)."])
    }

    /// Several failures, one per line, are shown whole.
    func testAMultiSentenceNoteIsShownWhole() {
        let document = makeDocument()
        let both = [why, "library, file pdf \(digest): it is read-only"]
            .joined(separator: BioMedLitConstants.libraryFailureSeparator)
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(failure: both)))
        XCTAssertEqual(document.libraryNotices(libraryState: .notChosen),
                       ["The paper library could not be used for this paper: \(both)."])
    }

    /// A why that ends its own sentence gets no second full stop.
    func testANoteEndingInAFullStopGetsNoSecond() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF(failure: "it broke.")))
        XCTAssertEqual(document.libraryNotices(libraryState: .notChosen),
                       ["The paper library could not be used for this paper: it broke."])
    }

    /// An unreachable library is told only for a paper whose file is in it.
    func testAnUnreachableLibraryIsToldForAPaperWithALibraryFile() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(libraryPDF()))
        XCTAssertEqual(document.libraryNotices(libraryState: .unreachable(reason: "the drive is unplugged")),
                       ["The paper library cannot be reached: the drive is unplugged."])
        XCTAssertEqual(document.libraryNotices(libraryState: .reachable(folderName: "L", path: "/L")), [])
    }

    /// The banner speaks for the library alone, as a note, not a warning.
    func testTheBannerSpeaksForTheLibraryAloneAsANote() throws {
        let content = try XCTUnwrap(ParseWarningBannerContent(
            warnings: JATSParseWarnings(), degradation: nil, extractionCoverage: nil,
            openAccessShortfall: nil, pdfNotSavedNote: nil, libraryNotices: ["x"]
        ))
        XCTAssertEqual(content.libraryNotices, ["x"])
        XCTAssertNil(content.message)
        XCTAssertFalse(content.isWarning)
    }
}
