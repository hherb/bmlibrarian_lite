// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// What a document hands StudyAnalyzer (StudyAnalyzer's shared-library design §3): what
/// StudyAnalyzer cannot fetch itself, and when offline whatever the app has;
/// each source passed over is named.
final class DocumentStudyAnalyzerHandoffTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)
    private let pdfPath = "/cache/paper.pdf"

    private struct Gone: Error {}

    /// A PubMed search's record, so a bare decimal `pmid` is a PubMed ID.
    private func makeDocument(pmid: String = "1") -> Document {
        let document = Document(pmid: pmid, title: "A trial", abstract: "")
        document.searchSource = MedicalFactChecker.SearchProvider.pubmed.rawValue
        return document
    }

    /// Reads that record whether they were made.
    private final class Reads {
        var library: [LibraryFileReference] = []
        var files: [String] = []
    }

    private func choose(
        _ document: Document, online: Bool, reads: Reads = Reads(),
        library: Result<Data, LibraryLookupFailure> = .failure(.init(description: "no library", waits: false)),
        file: Result<Data, Error> = .failure(Gone())
    ) -> StudyAnalyzerHandoffChoice {
        document.studyAnalyzerPaper.handoff(
            online: online,
            readLibrary: { reads.library.append($0); return library },
            readFile: { reads.files.append($0); return try file.get() }
        )
    }

    func testTheLibrarysJATSIsSentFirst() {
        let document = makeDocument()
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        let reads = Reads()
        let choice = choose(document, online: true, reads: reads, library: .success(Data("<article/>".utf8)))
        XCTAssertEqual(choice.handoff?.fullText?.format, .jats)
        XCTAssertEqual(choice.handoff?.fullText?.data, Data("<article/>".utf8))
        XCTAssertEqual(choice.notes, [])
        XCTAssertEqual(reads.library, [LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindJATS)])
        XCTAssertTrue(reads.files.isEmpty)
    }

    func testOnlineAJATSPaperWithoutItsFileSendsIdentifiersOnly() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: true)
        XCTAssertNil(choice.handoff?.fullText)
        XCTAssertEqual(choice.handoff?.pmid, "1")
        XCTAssertEqual(choice.handoff?.title, "A trial")
    }

    func testOfflineAJATSPaperSendsItsMarkdown() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.pmcOpenData.rawValue
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: false)
        XCTAssertEqual(choice.handoff?.fullText?.format, .markdown)
        XCTAssertEqual(choice.handoff?.fullText?.data, Data("# A trial".utf8))
        XCTAssertEqual(choice.handoff?.fullText?.source, AppFullTextSource.pmcOpenData.displayName)
    }

    func testAGoneLocalPDFFallsBackToTheLibrarysPDF() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindPDF
        let choice = choose(document, online: true, library: .success(Data("%PDF-1.4".utf8)))
        XCTAssertEqual(choice.handoff?.fullText?.format, .pdf)
        XCTAssertEqual(choice.handoff?.fullText?.data, Data("%PDF-1.4".utf8))
        XCTAssertEqual(choice.notes.count, 2)
    }

    func testAnUnreadableLibraryJATSFallsBackWithANote() {
        let document = makeDocument()
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: false,
                            library: .failure(.init(description: "the folder is not reachable", waits: true)))
        XCTAssertEqual(choice.handoff?.fullText?.format, .markdown)
        XCTAssertTrue(choice.notes.first?.contains("the folder is not reachable") ?? false)
    }

    func testAPDFOverTheCapIsPassedOver() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: true,
                            file: .success(Data(count: BioMedLitConstants.handoffMaxPDFBytes + 1)))
        XCTAssertEqual(choice.handoff?.fullText?.format, .markdown)
        XCTAssertEqual(choice.notes.count, 2)
    }

    func testAFallbackSaysWhatWasSentInstead() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindPDF
        let choice = choose(document, online: true, library: .success(Data("%PDF-1.4".utf8)))
        XCTAssertEqual(choice.notes.last, "The library's PDF was sent instead.")
    }

    func testAnAbstractOnlyRecordIsNotSentAsItsText() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextContentKindRaw = FullTextContentKind.abstract.rawValue
        document.fullTextContent = "Only the abstract."
        document.fullTextHTML = "<p>Only the abstract.</p>"
        let choice = choose(document, online: false)
        XCTAssertNil(choice.handoff?.fullText)
        XCTAssertEqual(choice.handoff?.pmid, "1")
    }

    func testATextOverTheTextCapIsPassedOver() {
        let document = makeDocument()
        document.fullTextContent = String(repeating: "a", count: BioMedLitConstants.handoffMaxTextBytes + 1)
        document.fullTextHTML = "<p>A trial</p>"
        let choice = choose(document, online: false)
        XCTAssertEqual(choice.handoff?.fullText?.format, .html)
        XCTAssertTrue(choice.notes.first?.contains("20 MiB") ?? false)
    }

    func testNothingToSendIsNil() {
        let choice = choose(makeDocument(pmid: ""), online: true)
        XCTAssertNil(choice.handoff)
        XCTAssertEqual(choice.notes, [])
    }

    /// With no identifier, every text passed over still says why.
    func testNothingSentStillSaysWhatWasPassedOver() {
        let document = makeDocument(pmid: "")
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        let choice = choose(document, online: false,
                            library: .failure(.init(description: "the folder is not reachable", waits: true)))
        XCTAssertNil(choice.handoff)
        XCTAssertEqual(choice.notes, ["The library's JATS file could not be read: the folder is not reachable"])
    }

    func testALocalPDFIsSentByNameOnly() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.unpaywall.rawValue
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        let reads = Reads()
        let choice = choose(document, online: true, reads: reads, file: .success(Data("%PDF".utf8)))
        XCTAssertEqual(choice.handoff?.fullText?.format, .pdf)
        XCTAssertEqual(choice.handoff?.fullText?.data, Data("%PDF".utf8))
        XCTAssertEqual(choice.handoff?.fullText?.fileName, "paper.pdf")
        XCTAssertEqual(choice.handoff?.fullText?.source, AppFullTextSource.unpaywall.displayName)
        XCTAssertEqual(choice.notes, [])
        XCTAssertEqual(reads.files, [pdfPath])
    }

    /// Online, a JATS paper's PDF is not read: StudyAnalyzer fetches the JATS.
    func testOnlineAJATSPaperIsNotSentItsPDF() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.pmcOpenData.rawValue
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        let reads = Reads()
        let choice = choose(document, online: true, reads: reads, file: .success(Data("%PDF".utf8)))
        XCTAssertNil(choice.handoff?.fullText)
        XCTAssertEqual(choice.notes, [])
        XCTAssertTrue(reads.files.isEmpty)
    }

    func testOnlineAnUnreadableLibraryJATSSendsIdentifiersOnly() {
        let document = makeDocument()
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: true,
                            library: .failure(.init(description: "the folder is not reachable", waits: true)))
        XCTAssertNil(choice.handoff?.fullText)
        XCTAssertEqual(choice.notes.count, 2)
        XCTAssertEqual(choice.notes.last, StudyAnalyzerText.identifiersSent)
    }

    func testTheDOIAndPMCIDAreSent() {
        let document = makeDocument()
        document.doi = " 10.1/x "
        document.pmcId = "PMC9"
        let choice = choose(document, online: true)
        XCTAssertEqual(choice.handoff?.doi, "10.1/x")
        XCTAssertEqual(choice.handoff?.pmcid, "PMC9")
    }

    /// A bare-decimal accession not vouched for as PubMed's is no PMID
    /// (#212): StudyAnalyzer would file the paper under an unrelated article.
    func testAnAccessionThatIsNoPubMedIDIsNotSentAsOne() {
        let document = makeDocument(pmid: "123456")
        document.searchSource = MedicalFactChecker.SearchProvider.europePMC.rawValue
        document.identifierKind = .europePMCSource("ETH")
        document.doi = "10.1/x"
        XCTAssertNil(choose(document, online: true).handoff?.pmid)
    }

    func testAPMCAccessionIsSentAsThePMCID() {
        let document = makeDocument(pmid: "PMC77")
        document.identifierKind = .pmc
        let choice = choose(document, online: true)
        XCTAssertNil(choice.handoff?.pmid)
        XCTAssertEqual(choice.handoff?.pmcid, "PMC77")
    }

    func testAPDFOverTheCapNamesItsCap() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: false,
                            file: .success(Data(count: BioMedLitConstants.handoffMaxPDFBytes + 1)))
        XCTAssertEqual(choice.notes, ["The PDF is larger than StudyAnalyzer accepts (100 MiB).",
                                      "The text was sent instead."])
    }

    /// Prose extracted from a PDF is plain text, not Markdown.
    func testExtractedPDFProseIsSentAsText() {
        let document = makeDocument()
        document.fullTextContentKindRaw = FullTextContentKind.extracted.rawValue
        document.fullTextContent = "Plain prose."
        XCTAssertEqual(choose(document, online: false).handoff?.fullText?.format, .text)
    }

    /// Prose from only some of a PDF's pages is sent saying so.
    func testPartlyExtractedProseIsSentWithANote() {
        let document = makeDocument()
        document.fullTextContentKindRaw = FullTextContentKind.extracted.rawValue
        document.fullTextContent = "Plain prose."
        document.fullTextPDFPath = "https://example.org/paper.pdf"
        document.fullTextExtractedPages = 3
        document.fullTextTotalPages = 10
        XCTAssertEqual(choose(document, online: false).notes, [StudyAnalyzerText.incomplete])
    }

    /// A text the parse lost part of is sent saying so.
    func testATextWithParseLossesIsSentWithANote() throws {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextContent = "# A trial"
        let warnings = JATSParseWarnings(losses: [.openSections(1)])
        document.fullTextParseWarningsJSON = String(data: try JSONEncoder().encode(warnings), encoding: .utf8)
        let choice = choose(document, online: false)
        XCTAssertEqual(choice.handoff?.fullText?.format, .markdown)
        XCTAssertEqual(choice.notes, [StudyAnalyzerText.incomplete])
    }

    func testAPreprintAccessionIsKept() {
        XCTAssertEqual(choose(makeDocument(pmid: "PPR456"), online: true).handoff?.pmid, "PPR456")
    }
}
