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

import CryptoKit
import XCTest
@testable import BioMedLit

/// Serves a fixed extraction, so a PDF needs no real file.
private struct LibraryTestExtractor: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(text: "Recovered prose.", success: true, pageCount: 1, convertedPages: 1, warnings: [])
    }
}

/// A library that answers what a test sets and records what it is asked.
private final class FakeLibrary: FullTextLibrary, @unchecked Sendable {
    var jatsAnswer: LibraryJATSLookup = .none
    var pdfAnswer: Result<LibraryHeldPDF?, LibraryLookupFailure> = .success(nil)
    /// What `keep` answers; nil keeps nothing (no identifiers).
    var keepAnswer: Result<LibraryKept?, LibraryLookupFailure> = .success(nil)
    /// Called on each `keep`, before it answers.
    var onKeep: (() -> Void)?
    private(set) var papers: [LibraryPaper] = []
    private(set) var kept: [(kind: String, origin: String, bytes: Data)] = []
    private(set) var noted: [LibraryFileReference] = []
    private(set) var pdfAsked = 0

    func jats(for paper: LibraryPaper) -> LibraryJATSLookup {
        papers.append(paper)
        return jatsAnswer
    }

    func pdf(for paper: LibraryPaper) -> Result<LibraryHeldPDF?, LibraryLookupFailure> {
        pdfAsked += 1
        return pdfAnswer
    }

    func keep(_ bytes: Data, kind: String, paper: LibraryPaper, origin: String)
        -> Result<LibraryKept?, LibraryLookupFailure> {
        onKeep?()
        kept.append((kind, origin, bytes))
        return keepAnswer
    }

    func noteUse(_ file: LibraryFileReference, paper: LibraryPaper) -> LibraryLookupFailure? {
        noted.append(file)
        return nil
    }

    func path(of file: LibraryFileReference) -> String? { nil }
}

/// The fetch through the shared paper library (design §4.5): the library's
/// JATS first, then the chain's JATS kept, the library's PDF in place of a
/// download, and a download kept with its cache copy removed only once the
/// library holds it.
final class FullTextServiceLibraryTests: XCTestCase {
    /// Digits, so the library accepts it; PubMed has assigned no PMID this high.
    private static let pmid = "99999101"
    private static let doi = "10.99999/library-test"
    /// No article has this PMC ID yet.
    private static let pmcId = "PMC99999981"
    private static let title = "A trial of things"
    private static let pdfAddress = "https://example.org/library-test.pdf"
    private static let pdfBytes = Data("%PDF-1.4 library test".utf8)
    private static let cacheKey = ArticleCacheKey(pmid: pmid, pmcId: nil, doi: nil)!

    private var made: [URL] = []
    #if os(macOS)
    private var accesses: [LibraryAccess] = []
    #endif

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.cacheKey)
        #if os(macOS)
        for access in accesses { access.stop() }
        accesses = []
        #endif
        for url in made { try? FileManager.default.removeItem(at: url) }
        made = []
        super.tearDown()
    }

    // MARK: Helpers

    private func makeService(
        library: (any FullTextLibrary)?,
        titleChecker: @escaping @Sendable (URL, String) -> PDFTitleCheck = { _, _ in .matches(share: 1) }
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: LibraryTestExtractor(),
            titleChecker: titleChecker,
            library: library
        )
    }

    /// A JATS article with the test's ids, with body prose.
    private static func jats() -> Data {
        Data("""
            <?xml version="1.0" encoding="UTF-8"?>
            <article><front><article-meta>
            <article-id pub-id-type="pmid">\(pmid)</article-id>
            <article-id pub-id-type="doi">\(doi)</article-id>
            <title-group><article-title>\(title)</article-title></title-group>
            <abstract><p>Things were tried.</p></abstract>
            </article-meta></front>
            <body><sec><title>Methods</title><p>We measured things.</p></sec></body></article>
            """.utf8)
    }

    /// Europe PMC serves the JATS by PMC ID.
    private func stubEuropePMCJATS() {
        StubURLProtocol.routes["fullTextXML"] = (200, Self.jats())
    }

    /// No PMC record; Unpaywall names one PDF, which serves.
    private func stubUnpaywallPDF() {
        StubURLProtocol.routes = [
            "search": (200, Data(#"{"resultList": {"result": []}}"#.utf8)),
            "unpaywall": (200, Data(#"{"best_oa_location":{"url_for_pdf":"\#(Self.pdfAddress)"}}"#.utf8)),
            "library-test.pdf": (200, Self.pdfBytes),
        ]
    }

    private func fetchWithPMCID(_ service: FullTextService) async throws -> FullTextResult {
        try await service.fetchFullText(pmcId: Self.pmcId, doi: Self.doi, pmid: Self.pmid, title: Self.title)
    }

    private func fetchPDF(_ service: FullTextService, title: String? = nil) async throws -> FullTextResult {
        try await service.fetchFullText(pmcId: nil, doi: Self.doi, pmid: Self.pmid, title: title)
    }

    /// Where the chain caches the Unpaywall PDF.
    private var cachedPDFPath: String {
        FullTextService.cachePath(for: Self.cacheKey, from: URL(string: Self.pdfAddress)!)
    }

    /// A PDF the fake library holds, in a temporary `papers/<folder>/<name>`.
    private func heldPDF() throws -> LibraryHeldPDF {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-lib-\(UUID().uuidString)", isDirectory: true)
        made.append(root)
        let folder = root.appendingPathComponent("papers/a-trial-99999101", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent("library.pdf")
        try Self.pdfBytes.write(to: file)
        return LibraryHeldPDF(path: file.path, file: LibraryFileReference(sha256: String(repeating: "b", count: 64),
                                                                           kind: "pdf"))
    }

    private static let unreachable = LibraryLookupFailure(
        description: "library, paper pmid=99999101: the library folder cannot be reached")

    // MARK: The library's JATS

    func testLibraryJATSEndsTheLookupWithNoRequest() async throws {
        let fake = FakeLibrary()
        let ref = LibraryFileReference(sha256: String(repeating: "a", count: 64), kind: "jats")
        fake.jatsAnswer = .usable(Self.jats(), ref)

        let result = try await fetchWithPMCID(makeService(library: fake))

        guard case .libraryJATS = result.content else { return XCTFail("served \(result.content)") }
        XCTAssertEqual(result.source, .library)
        XCTAssertEqual(result.contentKind, .fulltext)
        XCTAssertNotNil(result.markdown)
        XCTAssertEqual(result.libraryFile, ref)
        XCTAssertNil(result.libraryFailure)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [], "the library's JATS ends the lookup")
        XCTAssertEqual(fake.noted, [ref])
        XCTAssertEqual(fake.papers.first?.pmid, Self.pmid)
        XCTAssertEqual(fake.papers.first?.pmcId, Self.pmcId)
        XCTAssertEqual(fake.papers.first?.doi, Self.doi)
        XCTAssertEqual(fake.papers.first?.title, Self.title)
    }

    func testForeignLibraryJATSIsNotServed() async throws {
        let fake = FakeLibrary()
        let message = "the library's JATS f/n.xml is another paper's: its own doi 10.1/a is not the request's "
            + "\(Self.doi), so nothing is kept in the library in this lookup"
        fake.jatsAnswer = .wrongPaper(message)
        stubEuropePMCJATS()

        let result = try await fetchWithPMCID(makeService(library: fake))

        XCTAssertEqual(result.source, .europePMC, "the chain runs")
        XCTAssertEqual(result.libraryFailure, message)
        XCTAssertNil(result.libraryFile)
        XCTAssertTrue(fake.kept.isEmpty, "nothing is kept in that lookup")
        XCTAssertEqual(fake.pdfAsked, 0)
    }

    func testFailedLibraryTurnsTheLibraryOffForTheCall() async throws {
        let fake = FakeLibrary()
        fake.jatsAnswer = .failed(Self.unreachable.description)
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: fake))

        XCTAssertEqual(result.libraryFailure, Self.unreachable.description)
        XCTAssertEqual(fake.pdfAsked, 0)
        XCTAssertTrue(fake.kept.isEmpty)
    }

    // MARK: The chain's JATS

    func testUnkeptJATSWaitsInTheCache() async throws {
        let fake = FakeLibrary()
        fake.keepAnswer = .failure(Self.unreachable)
        stubEuropePMCJATS()

        let result = try await fetchWithPMCID(makeService(library: fake))

        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.libraryFailure, Self.unreachable.description)
        XCTAssertEqual(fake.kept.map(\.kind), ["jats"])
        XCTAssertEqual(fake.kept.first?.origin, FullTextSource.europePMC.displayName)
        let digest = SHA256.hash(data: Self.jats()).map { String(format: "%02x", $0) }.joined()
        let waiting = FullTextService.pdfCacheDirectory
            .appendingPathComponent("\(Self.cacheKey.filenameComponent)-\(digest.prefix(12)).xml")
        XCTAssertEqual(try Data(contentsOf: waiting), Self.jats(), "the JATS waits in the PDF cache")
    }

    // MARK: The library's PDF

    func testLibraryPDFReplacesTheDownload() async throws {
        let fake = FakeLibrary()
        let held = try heldPDF()
        fake.pdfAnswer = .success(held)
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: fake), title: Self.title)

        XCTAssertEqual(result.content, .libraryPDF(localPath: held.path))
        XCTAssertEqual(result.source, .library)
        XCTAssertEqual(result.localPDFPath, held.path)
        XCTAssertEqual(result.extractedText, "Recovered prose.")
        XCTAssertEqual(result.libraryFile, held.file)
        XCTAssertNil(result.libraryFailure)
        XCTAssertEqual(fake.noted, [held.file])
        XCTAssertFalse(StubURLProtocol.requested("library-test.pdf"), "no download")
        XCTAssertTrue(fake.kept.isEmpty, "the library's own PDF is not kept again")
    }

    func testLibraryPDFFailingTitleCheckIsNotServed() async throws {
        let fake = FakeLibrary()
        let held = try heldPDF()
        fake.pdfAnswer = .success(held)
        stubUnpaywallPDF()
        let service = makeService(library: fake, titleChecker: { url, _ in
            url.lastPathComponent == "library.pdf" ? .mismatch(share: 0.1) : .matches(share: 1)
        })

        let result = try await fetchPDF(service, title: Self.title)

        XCTAssertEqual(result.source, .unpaywall, "the chain downloads")
        let failure = try XCTUnwrap(result.libraryFailure)
        XCTAssertTrue(failure.contains("a-trial-99999101/library.pdf"), failure)
        XCTAssertTrue(failure.contains("another article's"), failure)
        XCTAssertTrue(FileManager.default.fileExists(atPath: held.path), "the library's file is left alone")
        XCTAssertTrue(fake.noted.isEmpty)
        XCTAssertTrue(fake.kept.isEmpty)
    }

    // MARK: A download kept

    func testUnreachableLibraryKeepsTheCacheCopy() async throws {
        let fake = FakeLibrary()
        fake.jatsAnswer = .failed(Self.unreachable.description)
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: fake))

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.localPDFPath, cachedPDFPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedPDFPath))
        XCTAssertEqual(result.libraryFailure, Self.unreachable.description)
        XCTAssertNil(result.libraryFile)
    }

    func testFailedPDFSaveKeepsTheCacheCopy() async throws {
        let fake = FakeLibrary()
        fake.keepAnswer = .failure(Self.unreachable)
        var cachedAtKeep = false
        let path = cachedPDFPath
        fake.onKeep = { cachedAtKeep = FileManager.default.fileExists(atPath: path) }
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: fake))

        XCTAssertTrue(cachedAtKeep)
        XCTAssertEqual(fake.kept.map(\.kind), ["pdf"])
        XCTAssertEqual(fake.kept.first?.origin, FullTextSource.unpaywall.displayName)
        XCTAssertEqual(fake.kept.first?.bytes, Self.pdfBytes)
        XCTAssertEqual(result.localPDFPath, cachedPDFPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedPDFPath), "the cache copy stays")
        XCTAssertEqual(result.libraryFailure, Self.unreachable.description)
        XCTAssertNil(result.libraryFile)
    }

    func testNoLibraryIsUnchanged() async throws {
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: nil))

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertEqual(result.localPDFPath, cachedPDFPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: cachedPDFPath))
        XCTAssertNil(result.libraryFile)
        XCTAssertNil(result.libraryFailure)
    }

    // MARK: The paper the library is told of

    func testLibraryPaperResolvesTheSlotByKind() {
        let pmc = FullTextService.libraryPaper(pmcId: nil, doi: nil, pmid: "PMC123", primaryKind: nil, title: nil)
        XCTAssertNil(pmc.pmid)
        XCTAssertEqual(pmc.pmcId, "PMC123")
        let preprint = FullTextService.libraryPaper(pmcId: nil, doi: nil, pmid: "PPR42", primaryKind: nil, title: nil)
        XCTAssertEqual(preprint.pmid, "PPR42")
        let pubmed = FullTextService.libraryPaper(pmcId: "PMC9", doi: " 10.1/a ", pmid: " 123 ",
                                                  primaryKind: .pubmed, title: "T")
        XCTAssertEqual(pubmed.pmid, "123")
        XCTAssertEqual(pubmed.pmcId, "PMC9")
        XCTAssertEqual(pubmed.doi, "10.1/a")
        XCTAssertEqual(pubmed.title, "T")
        XCTAssertNil(FullTextService.libraryPaper(pmcId: nil, doi: nil, pmid: "not-an-id", primaryKind: nil,
                                                  title: nil).pmid)
        XCTAssertNil(FullTextService.libraryPaper(pmcId: nil, doi: nil, pmid: "123",
                                                  primaryKind: .europePMCSource("agr"), title: nil).pmid)
    }

    // MARK: End to end, a real library

    #if os(macOS)
    /// A source over a fresh library in an empty temporary folder.
    private func realLibrary() throws -> (LibrarySource, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mfc-fts-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        made.append(url)
        let access = try LibrarySetup.choose(url).access
        accesses.append(access)
        return (try LibrarySource(access: access, installationID: "install-a", label: "MedicalFactChecker on test"),
                url)
    }

    func testServedJATSIsKept() async throws {
        let (library, _) = try realLibrary()
        stubEuropePMCJATS()

        let first = try await fetchWithPMCID(makeService(library: library))

        XCTAssertEqual(first.source, .europePMC)
        XCTAssertNil(first.libraryFailure)
        let file = try XCTUnwrap(first.libraryFile)
        XCTAssertEqual(file.kind, "jats")
        XCTAssertNotNil(library.path(of: file))

        StubURLProtocol.reset()
        let second = try await fetchWithPMCID(makeService(library: library))

        guard case .libraryJATS = second.content else { return XCTFail("served \(second.content)") }
        XCTAssertEqual(second.libraryFile, file)
        XCTAssertEqual(StubURLProtocol.requestedURLs, [])
    }

    func testTamperedLibraryJATSIsReported() async throws {
        let (library, _) = try realLibrary()
        let paper = LibraryPaper(pmid: Self.pmid, doi: Self.doi, pmcId: Self.pmcId, title: Self.title)
        guard case let .success(kept?) = library.keep(Self.jats(), kind: "jats", paper: paper, origin: "Test") else {
            return XCTFail("not kept")
        }
        try Data("<article>not what was saved</article>".utf8).write(to: URL(fileURLWithPath: kept.path))
        stubEuropePMCJATS()

        let result = try await fetchWithPMCID(makeService(library: library))

        XCTAssertEqual(result.source, .europePMC, "the chain runs")
        let failure = try XCTUnwrap(result.libraryFailure)
        XCTAssertTrue(failure.contains("digest"), failure)
    }

    func testSavedPDFLeavesNoCacheCopy() async throws {
        let (library, root) = try realLibrary()
        stubUnpaywallPDF()

        let result = try await fetchPDF(makeService(library: library))

        XCTAssertEqual(result.source, .unpaywall)
        XCTAssertNil(result.libraryFailure)
        let path = try XCTUnwrap(result.localPDFPath)
        XCTAssertTrue(path.hasPrefix(root.appendingPathComponent("papers").path + "/"), path)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Self.pdfBytes)
        XCTAssertEqual(result.libraryFile?.kind, "pdf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: cachedPDFPath), "the cache copy is removed")
    }
    #endif
}
