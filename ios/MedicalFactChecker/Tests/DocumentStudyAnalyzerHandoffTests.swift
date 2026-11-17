// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// What a document hands StudyAnalyzer (the library design §3): what
/// StudyAnalyzer cannot fetch itself, and when offline whatever the app has;
/// each source passed over is named.
final class DocumentStudyAnalyzerHandoffTests: XCTestCase {
    private let digest = String(repeating: "ab", count: 32)
    private let pdfPath = "/cache/paper.pdf"

    private struct Gone: Error {}

    private func makeDocument(pmid: String = "1") -> Document {
        Document(pmid: pmid, title: "A trial", abstract: "")
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
    ) -> StudyAnalyzerHandoffChoice? {
        document.studyAnalyzerHandoff(
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
        XCTAssertEqual(choice?.handoff.fullText?.format, .jats)
        XCTAssertEqual(choice?.handoff.fullText?.data, Data("<article/>".utf8))
        XCTAssertEqual(choice?.notes, [])
        XCTAssertEqual(reads.library, [LibraryFileReference(sha256: digest, kind: BioMedLitConstants.libraryKindJATS)])
        XCTAssertTrue(reads.files.isEmpty)
    }

    func testOnlineAJATSPaperWithoutItsFileSendsIdentifiersOnly() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.europePMC.rawValue
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: true)
        XCTAssertNil(choice?.handoff.fullText)
        XCTAssertEqual(choice?.handoff.pmid, "1")
        XCTAssertEqual(choice?.handoff.title, "A trial")
    }

    func testOfflineAJATSPaperSendsItsMarkdown() {
        let document = makeDocument()
        document.fullTextSource = AppFullTextSource.pmcOpenData.rawValue
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: false)
        XCTAssertEqual(choice?.handoff.fullText?.format, .markdown)
        XCTAssertEqual(choice?.handoff.fullText?.data, Data("# A trial".utf8))
        XCTAssertEqual(choice?.handoff.fullText?.source, AppFullTextSource.pmcOpenData.displayName)
    }

    func testAGoneLocalPDFFallsBackToTheLibrarysPDF() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindPDF
        let choice = choose(document, online: true, library: .success(Data("%PDF-1.4".utf8)))
        XCTAssertEqual(choice?.handoff.fullText?.format, .pdf)
        XCTAssertEqual(choice?.handoff.fullText?.data, Data("%PDF-1.4".utf8))
        XCTAssertEqual(choice?.notes.count, 1)
    }

    func testAnUnreadableLibraryJATSFallsBackWithANote() {
        let document = makeDocument()
        document.fullTextLibrarySHA256 = digest
        document.fullTextLibraryKind = BioMedLitConstants.libraryKindJATS
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: false,
                            library: .failure(.init(description: "the folder is not reachable", waits: true)))
        XCTAssertEqual(choice?.handoff.fullText?.format, .markdown)
        XCTAssertTrue(choice?.notes.first?.contains("the folder is not reachable") ?? false)
    }

    func testAPDFOverTheCapIsPassedOver() {
        let document = makeDocument()
        document.fullTextPDFPath = pdfPath
        document.fullTextPDFPathIsLocalFile = true
        document.fullTextContent = "# A trial"
        let choice = choose(document, online: true,
                            file: .success(Data(count: BioMedLitConstants.handoffMaxFileBytes + 1)))
        XCTAssertEqual(choice?.handoff.fullText?.format, .markdown)
        XCTAssertEqual(choice?.notes.count, 1)
    }

    func testNothingToSendIsNil() {
        XCTAssertNil(choose(makeDocument(pmid: ""), online: true))
    }

    func testAPreprintAccessionIsKept() {
        XCTAssertEqual(choose(makeDocument(pmid: "PPR456"), online: true)?.handoff.pmid, "PPR456")
    }
}
