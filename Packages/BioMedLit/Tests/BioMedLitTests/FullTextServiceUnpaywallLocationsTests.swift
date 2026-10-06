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
@testable import BioMedLit

private struct ExtractingStub: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(
            text: "The article.", success: true, pageCount: 1, convertedPages: 1, warnings: []
        )
    }
}

/// Holds no text: a scan, say.
private struct TextlessStub: PDFTextExtracting {
    func extract(from fileURL: URL) -> PDFExtractionResult {
        PDFExtractionResult(text: "", success: true, pageCount: 1, convertedPages: 0, warnings: [])
    }
}

/// A cache write that always fails, as on a full disk.
private let failingWrite: @Sendable (Data, URL) throws -> Void = { _, _ in
    throw CocoaError(.fileWriteOutOfSpace)
}

/// Every PDF Unpaywall names is tried, in Unpaywall's order; every failure is
/// told; a copy served but not saved ends the walk with a caching note
/// (#480, stage B; the maintainer's decisions of 2026-10-05).
final class FullTextServiceUnpaywallLocationsTests: XCTestCase {
    private let doi = "10.1/locations"
    private let first = "https://walled.example.org/a.pdf"
    private let second = "https://repo.example.org/b.pdf"
    private let pdfBody = Data("%PDF-1.7\n".utf8) + Data(repeating: 0x30, count: 64)

    /// The article's cache key: no PMID, so the DOI names it.
    private var cacheKey: ArticleCacheKey {
        ArticleCacheKey(pmid: "", pmcId: nil, doi: doi)!
    }

    /// A PMC accession no article has yet, for the test that needs Europe
    /// PMC's abstract held: the PDF cache is the real user directory, so a
    /// real accession's entries would be deleted by this suite.
    private let unassignedPMCID = "PMC99999992"

    /// The cache key of a fetch that passes ``unassignedPMCID``.
    private var pmcCacheKey: ArticleCacheKey {
        ArticleCacheKey(pmid: "", pmcId: unassignedPMCID, doi: doi)!
    }

    /// Europe PMC's render of the article, resolved by the search below.
    private let render = "https://europepmc.org/articles/PMC1/pdf"

    /// An S3 listing naming nothing: PMC's open-data bucket holds no copy.
    private let emptyListing = Data("""
        <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>0</KeyCount>\
        </ListBucketResult>
        """.utf8)
    private let listingRoute = "pmc-oa-opendata.s3.amazonaws.com/?list-type"

    /// Europe PMC's XML with an abstract and no body: the abstract is held.
    private let bodyless = Data("""
        <article><front><article-meta>
          <title-group><article-title>A trial</article-title></title-group>
          <abstract><p>Background and findings only.</p></abstract>
        </article-meta></front></article>
        """.utf8)

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        FullTextService.deleteCachedPDF(for: pmcCacheKey)
        // Europe PMC knows no record, so the Unpaywall tier decides the outcome
        StubURLProtocol.routes["search"] = (200, Data(#"{"resultList": {"result": []}}"#.utf8))
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: cacheKey)
        FullTextService.deleteCachedPDF(for: pmcCacheKey)
        super.tearDown()
    }

    private func fetch(
        pmcId: String? = nil,
        extractor: PDFTextExtracting = ExtractingStub(),
        writeCachedPDF: @escaping @Sendable (Data, URL) throws -> Void = FullTextService.writeAtomically
    ) async throws -> FullTextResult {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return try await FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor,
            writeCachedPDF: writeCachedPDF
        ).fetchFullText(pmcId: pmcId, doi: doi, pmid: "")
    }

    private func unpaywall(_ pdfs: [String]) -> Data {
        let locations = pdfs.map { ["url_for_pdf": $0, "url": $0] }
        let body: [String: Any] = ["best_oa_location": locations.first as Any, "oa_locations": locations]
        return try! JSONSerialization.data(withJSONObject: body)
    }

    func testASecondLocationIsTriedWhenTheFirstIsRefused() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall, "a served copy settles it")
    }

    func testEveryLocationRefusedIsToldEachByItsHost() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (503, Data())

        let result = try await fetch()

        XCTAssertEqual(result.content, .doi(webURL: URL(string: "https://doi.org/\(doi)")!))
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
                .appending(OpenAccessShortfall(source: .pdf, failure: .httpStatus(503), address: second))
        )
        XCTAssertNil(result.pdfNotSavedFrom, "a refusal is the source's, not a caching problem")
    }

    func testTheRepeatedBestLocationIsRequestedOnce() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, first]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())

        _ = try await fetch()

        // A PDF download retries only transport errors (`.pdfDownload` with
        // `retryOnlyTransient`), so a 403 is one request: two would mean the
        // repeated location was tried twice
        XCTAssertEqual(StubURLProtocol.requestedURLs.filter { $0.contains("walled.example.org") }.count, 1)
    }

    func testAnUnfetchableAddressIsListedAndTheNextTried() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall(["ftp://repo.example.org/x.pdf", second]))
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall)
    }

    /// The control for the walk's refusal of an unfetchable address: alone, it
    /// is listed with its address, against the PDF, not Unpaywall.
    func testAnUnfetchableAddressAloneIsListedWithItsAddress() async throws {
        let unfetchable = "ftp://repo.example.org/x.pdf"
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([unfetchable]))

        let result = try await fetch()

        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .requestFailed, address: unfetchable)
        )
    }

    /// The rules the chain applies, pinned where it applies them; the tests
    /// below drive them through the chain with a failing cache write.
    func testAServedButUncachedCopySettlesTheQuestion() {
        let refused = OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: first)
        XCTAssertNil(FullTextService.settledOpenAccessShortfall(refused, copyServed: true))
        XCTAssertEqual(FullTextService.settledOpenAccessShortfall(refused, copyServed: false), refused)
        let link = FullTextResult(content: .unpaywall(pdfURL: URL(string: second)!), degradation: nil)
            .noting(openAccessShortfall: nil, pdfNotSavedFrom: second)
        XCTAssertNil(link.openAccessShortfall, "the init's assert holds")
        XCTAssertEqual(link.pdfNotSavedFrom, second)
    }
    /// The first copy served ends the walk even unsaved: saving is our
    /// problem, not the source's, so no later candidate and no OpenAlex.
    func testAServedCopyNotCachedEndsTheWalk() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (200, pdfBody)
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch(writeCachedPDF: failingWrite)

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: first)!), "its link is kept")
        XCTAssertNil(result.openAccessShortfall, "a served copy settles it")
        XCTAssertEqual(result.pdfNotSavedFrom, first)
        XCTAssertFalse(StubURLProtocol.requested("repo.example.org"), "\(StubURLProtocol.requestedURLs)")
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }

    /// A refusal before the copy not cached is not told: the copy settles it.
    func testARefusalBeforeACopyNotCachedIsNotTold() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch(writeCachedPDF: failingWrite)

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertNil(result.openAccessShortfall)
        XCTAssertEqual(result.pdfNotSavedFrom, second)
        XCTAssertFalse(StubURLProtocol.requested("api.openalex.org"))
    }

    /// The control: the same chain with the write succeeding reads the copy.
    func testControlTheSameCopyCachedIsRead() async throws {
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch()

        XCTAssertEqual(result.content, .unpaywall(pdfURL: URL(string: second)!))
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertNil(result.pdfNotSavedFrom)
    }

    /// Europe PMC's render is no open-access copy: unsaved, it is the note's
    /// address, but Unpaywall's walk still runs and its refusal is told.
    func testARenderNotCachedLetsTheUnpaywallWalkRun() async throws {
        StubURLProtocol.routes["search"] = (200, Data(#"""
            {"resultList": {"result": [{
              "id": "1", "pmcid": "PMC1", "inPMC": "Y", "doi": "10.1/locations",
              "fullTextUrlList": {"fullTextUrl": [
                {"documentStyle": "pdf", "site": "Europe_PMC",
                 "url": "https://europepmc.org/articles/PMC1/pdf",
                 "availability": "Open access", "availabilityCode": "OA"}
              ]}
            }]}}
            """#.utf8))
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes[listingRoute] = (200, emptyListing)
        StubURLProtocol.routes["articles/PMC1/pdf"] = (200, pdfBody)
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([second]))
        StubURLProtocol.routes["repo.example.org"] = (403, Data())

        let result = try await fetch(writeCachedPDF: failingWrite)

        XCTAssertTrue(StubURLProtocol.requested("articles/PMC1/pdf"), "the render tier was reached")
        XCTAssertTrue(StubURLProtocol.requested("repo.example.org"), "the walk ran")
        XCTAssertEqual(result.pdfNotSavedFrom, render)
        XCTAssertEqual(
            result.openAccessShortfall,
            OpenAccessShortfall(source: .pdf, failure: .httpStatus(403), address: second),
            "a render not saved settles nothing"
        )
    }

    /// A copy obtained without text, the abstract held, settles the question
    /// though the walk goes on for text: no "Failed to obtain" beside it.
    func testATextlessCopyWithTheAbstractHeldSettlesTheQuestion() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, bodyless)
        StubURLProtocol.routes[listingRoute] = (200, emptyListing)
        StubURLProtocol.routes["unpaywall"] = (200, unpaywall([first, second]))
        StubURLProtocol.routes["walled.example.org"] = (403, Data())
        StubURLProtocol.routes["repo.example.org"] = (200, pdfBody)

        let result = try await fetch(pmcId: unassignedPMCID, extractor: TextlessStub())

        XCTAssertEqual(result.contentKind, .abstract, "a textless copy does not beat the abstract")
        XCTAssertNil(result.openAccessShortfall, "a copy was obtained")
        XCTAssertNil(result.pdfNotSavedFrom, "it was saved")
        XCTAssertTrue(StubURLProtocol.requested("api.openalex.org"), "OpenAlex may still have text")
    }
}
