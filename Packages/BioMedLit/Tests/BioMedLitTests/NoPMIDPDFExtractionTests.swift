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

/// Returns a fixed extraction, so the end-to-end test below exercises the
/// retrieval chain rather than PDFKit.
private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// #202: an article with no PMID used to get no PDF extraction at all.
///
/// The refusal was correct as far as it went — every article with no PMID would
/// otherwise share one cache entry — but it threw away the article's other
/// identifiers, and a Europe PMC record can carry a PMC ID with no PMID. Those
/// are exactly the open-access articles most likely to have a usable free PDF.
/// The tier reported a download failure, the chain moved on, and nothing
/// distinguished this from a PDF that genuinely could not be fetched.
final class NoPMIDPDFExtractionTests: XCTestCase {
    private static let pmcOnly = ArticleCacheKey(pmid: "", pmcId: "PMC202test", doi: nil)!
    private static let otherPMCOnly = ArticleCacheKey(pmid: "", pmcId: "PMC202other", doi: nil)!
    private static let doiOnly = ArticleCacheKey(pmid: "", pmcId: nil, doi: "10.202/test")!

    private static let firstURL = URL(string: "https://example.org/pmc-article.pdf")!
    private static let secondURL = URL(string: "https://example.org/other-article.pdf")!

    private static let firstBytes =
        Data(BioMedLitConstants.pdfMagicBytes) + Data("the pmc article".utf8)
    private static let secondBytes =
        Data(BioMedLitConstants.pdfMagicBytes) + Data("a different article".utf8)

    private func clearCache() {
        for key in [Self.pmcOnly, Self.otherPMCOnly, Self.doiOnly] {
            FullTextService.deleteCachedPDF(for: key)
        }
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        clearCache()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        clearCache()
        super.tearDown()
    }

    private func makeService() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        return FullTextService(
            email: "test@example.org", session: URLSession(configuration: config)
        )
    }

    /// The defect, directly: this download used to be refused.
    func testAnArticleWithOnlyAPMCIdentifierGetsItsPDFCached() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]

        let path = try await makeService().downloadAndCachePDF(
            from: Self.firstURL, for: Self.pmcOnly
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Self.firstBytes)
    }

    /// An article whose only identifier is a DOI gets an entry too.
    func testAnArticleWithOnlyADOIGetsItsPDFCached() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]

        let path = try await makeService().downloadAndCachePDF(
            from: Self.firstURL, for: Self.doiOnly
        )

        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Self.firstBytes)
    }

    /// The property the old refusal was protecting, which must survive the fix:
    /// two articles that both lack a PMID must not read each other's bytes.
    func testTwoArticlesWithoutPMIDsDoNotShareCachedBytes() async throws {
        StubURLProtocol.routes = [
            "pmc-article.pdf": (200, Self.firstBytes),
            "other-article.pdf": (200, Self.secondBytes),
        ]
        let service = makeService()

        let firstPath = try await service.downloadAndCachePDF(
            from: Self.firstURL, for: Self.pmcOnly
        )
        let secondPath = try await service.downloadAndCachePDF(
            from: Self.secondURL, for: Self.otherPMCOnly
        )

        XCTAssertNotEqual(firstPath, secondPath)
        XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: secondPath)), Self.secondBytes)
    }

    /// A cached entry is served back to the article that owns it, and only to
    /// that article. The second lookup asks for the same URL under a different
    /// article and must miss.
    func testACachedEntryIsNotServedToADifferentArticle() async throws {
        StubURLProtocol.routes = ["pmc-article.pdf": (200, Self.firstBytes)]
        _ = try await makeService().downloadAndCachePDF(from: Self.firstURL, for: Self.pmcOnly)

        XCTAssertNotNil(FullTextService.cachedPDFPath(for: Self.pmcOnly, from: Self.firstURL))
        XCTAssertNil(FullTextService.cachedPDFPath(for: Self.otherPMCOnly, from: Self.firstURL))
    }

    // MARK: - End to end

    /// The whole point of #202, through the public entry point.
    ///
    /// A Europe PMC article with a PMC ID and neither a PMID nor a DOI used to
    /// get nothing: the cache refused to name an entry for it, *and* nothing
    /// asked Europe PMC for its PMC ID, so no render URL was ever resolved and
    /// no PDF tier fired. Both halves have to work for this to pass — keying
    /// the cache correctly is not enough on its own.
    ///
    /// The XML deposit here is body-less, so the XML tier holds it back and the
    /// PDF tier gets its turn, which is the only route to a render URL.
    func testAnArticleWithOnlyAPMCIdentifierReachesItsPDFThroughFetchFullText() async throws {
        let pmcId = "PMC202e2e"
        let key = ArticleCacheKey(pmid: "", pmcId: pmcId, doi: nil)!
        FullTextService.deleteCachedPDF(for: key)
        defer { FullTextService.deleteCachedPDF(for: key) }

        let searchResponse = #"""
        {"resultList": {"result": [{
          "id": "1", "pmcid": "PMC202e2e", "inPMC": "Y",
          "fullTextUrlList": {"fullTextUrl": [
            {"documentStyle": "pdf", "site": "Europe_PMC",
             "url": "https://europepmc.org/articles/PMC202e2e/pdf",
             "availability": "Open access", "availabilityCode": "OA"}
          ]}
        }]}}
        """#
        let bodyless = Data("""
        <article><front><article-meta>
          <title-group><article-title>A trial</article-title></title-group>
          <abstract><p>Abstract only.</p></abstract>
        </article-meta></front></article>
        """.utf8)

        StubURLProtocol.routes = [
            "search": (200, Data(searchResponse.utf8)),
            "fullTextXML": (200, bodyless),
            "articles/PMC202e2e/pdf": (200, Self.firstBytes),
        ]

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: StubExtractor(
                result: PDFExtractionResult(
                    text: "The recovered article body.",
                    success: true,
                    pageCount: 1,
                    convertedPages: 1,
                    warnings: [],
                    errorMessage: nil
                )
            ),
            extractPDFText: true
        )

        let result = try await service.fetchFullText(pmcId: pmcId, doi: nil, pmid: "")

        XCTAssertEqual(
            result.contentKind, .extracted,
            "the PDF's text must reach the caller, not the held-back abstract"
        )
        XCTAssertEqual(result.extractedText, "The recovered article body.")
    }
}
