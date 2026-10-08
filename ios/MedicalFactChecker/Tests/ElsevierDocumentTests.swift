// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// Licensed under the GNU Affero General Public License, version 3 or later.

import XCTest
@testable import MedicalFactChecker
import BioMedLit

/// The PDF Elsevier's API served as a full-text source (#480, stage C2).
///
/// Elsevier's article URL needs the key, so it is never a reader link: the
/// served PDF is held only as the local file it was saved to.
final class ElsevierDocumentTests: XCTestCase {
    private let localPath = "/tmp/fulltext-cache/elsevier-10.1016-j.cell.2020.01.001.pdf"
    private let articleURL = URL(
        string: "https://api.elsevier.com/content/article/doi/10.1016/j.cell.2020.01.001")!
    private let text = String(repeating: "prose ", count: 500)

    private var elsevierResult: BioMedLit.FullTextResult {
        BioMedLit.FullTextResult(
            content: .elsevier(localPath: localPath), warnings: JATSParseWarnings(), degradation: nil,
            contentKind: .extracted, extractedText: text, localPDFPath: localPath,
            extractionCoverage: PDFExtractionCoverage(convertedPages: 4, pageCount: 4),
            openAccessShortfall: nil, pdfNotSavedFrom: nil
        )
    }

    private func makeDocument() -> Document {
        Document(pmid: "1", title: "T", abstract: "")
    }

    /// The shared Elsevier contract, `doc/cross_platform/fulltext_parity/elsevier_article.json`,
    /// found by walking up from this file to the repository's root.
    private func loadContract() throws -> [String: Any] {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/elsevier_article.json")
            if FileManager.default.fileExists(atPath: candidate.path) {
                return try XCTUnwrap(
                    JSONSerialization.jsonObject(with: Data(contentsOf: candidate)) as? [String: Any])
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory
                || FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                // A failure, not a skip: a test that cannot read the contract pins nothing
                return try XCTUnwrap(nil as [String: Any]?, "elsevier_article.json not found")
            }
            directory = parent
        }
    }

    func testTheSourceIsTheContracts() throws {
        let contract = try loadContract()
        let source = try XCTUnwrap(contract["source"] as? String)
        XCTAssertEqual(AppFullTextSource.elsevier.rawValue, source)
        XCTAssertEqual(AppFullTextSource.elsevier.displayName, contract["source_label"] as? String)
        XCTAssertEqual(AppFullTextSource.elsevier.displayName, "Elsevier's API (PDF)")
        XCTAssertEqual(AppFullTextSource(rawValue: source), .elsevier)
    }

    func testTheSourceHasAnIconAndIsShownInTheApp() {
        XCTAssertEqual(AppFullTextSource.elsevier.iconName, "key")
        XCTAssertTrue(AppFullTextSource.elsevier.canDisplayInApp)
    }

    func testAStoredElsevierSourceIsLabelled() {
        let document = makeDocument()
        document.fullTextSource = "elsevier"
        XCTAssertEqual(document.fullTextSourceDisplay, "Elsevier's API (PDF)")
    }

    func testElsevierPDFReachesTheAppAsTheLocalFile() {
        let app = BioMedLitAdapters.toAppFullTextResult(elsevierResult)
        XCTAssertEqual(app.source, .elsevier)
        XCTAssertEqual(app.content, .pdfURL(URL(fileURLWithPath: localPath)))
        XCTAssertEqual(app.pdfURL?.isFileURL, true)
        XCTAssertEqual(app.localPDFPath, localPath)
        XCTAssertEqual(app.extractedText, text)
        XCTAssertNil(app.pdfNotSavedFrom)
        XCTAssertNil(app.webURL)
    }

    func testAStoredElsevierPDFIsTheLocalFileAndNoRemoteURL() {
        let document = makeDocument()
        document.applyFullTextResult(BioMedLitAdapters.toAppFullTextResult(elsevierResult))

        XCTAssertEqual(document.fullTextSource, "elsevier")
        XCTAssertEqual(document.fullTextPDFPath, localPath)
        XCTAssertEqual(document.fullTextPDFPathIsLocalFile, true)
        XCTAssertEqual(document.localPDFFilePath, localPath)
        XCTAssertEqual(document.displayedFullText, .localPDF(path: localPath))
        XCTAssertNil(document.fullTextPDFNotSavedFrom)
        XCTAssertNil(document.fullTextOpenAccessShortfallJSON)
        XCTAssertEqual(document.analyzableFullText, text)
        XCTAssertEqual(document.cachedFullTextResult?.localPDFPath, localPath)
    }

    /// An Elsevier result that names its article URL and no local file is
    /// never stored as a link: the URL needs the key, so a reader opening it
    /// would be refused, and a loader re-fetching it would ask without headers.
    func testAnElsevierResultWithoutALocalFileStoresNoLink() {
        let document = makeDocument()
        document.applyFullTextResult(
            AppFullTextResult(content: .pdfURL(articleURL), source: .elsevier, extractedText: text)
        )

        XCTAssertNil(document.fullTextPDFPath)
        XCTAssertNil(document.fullTextPDFPathIsLocalFile)
        XCTAssertNotEqual(
            document.displayedFullText, .remotePDFLink(urlString: articleURL.absoluteString))
    }

    /// The control: another source's PDF with no local file still keeps its link.
    func testAnUnpaywallResultWithoutALocalFileKeepsItsLink() {
        let document = makeDocument()
        let link = URL(string: "https://repository.example.org/paper.pdf")!
        document.applyFullTextResult(AppFullTextResult(content: .pdfURL(link), source: .unpaywall))

        XCTAssertEqual(document.fullTextPDFPath, link.absoluteString)
        XCTAssertEqual(document.fullTextPDFPathIsLocalFile, false)
    }

    func testTheSettingsExplanationsAreVerbatim() {
        XCTAssertEqual(
            AppSettings.elsevierAPIKeyExplanation,
            "Optional. A free Elsevier API key (dev.elsevier.com) lets the app download the PDFs of "
                + "Elsevier articles you are entitled to: open-access articles anywhere, subscribed "
                + "ones from your institution's network.")
        XCTAssertEqual(
            AppSettings.elsevierInstTokenExplanation,
            "Optional. An institutional token from Elsevier lets the key use your institution's "
                + "subscriptions away from its network.")
    }

    func testTheKeyAndTokenReachTheService() {
        XCTAssertTrue(
            BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "", elsevierAPIKey: "k").asksElsevier)
        XCTAssertTrue(
            BMLFullTextService.create(
                ncbiEmail: "", coreAPIKey: "", elsevierAPIKey: "k", elsevierInstToken: "t"
            ).asksElsevier)
        XCTAssertFalse(
            BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "", elsevierAPIKey: "  ").asksElsevier)
        XCTAssertFalse(
            BMLFullTextService.create(
                ncbiEmail: "", coreAPIKey: "", elsevierAPIKey: "", elsevierInstToken: "t"
            ).asksElsevier,
            "a token without a key asks nothing")
        XCTAssertFalse(BMLFullTextService.create(ncbiEmail: "", coreAPIKey: "k").asksElsevier)
    }
}
