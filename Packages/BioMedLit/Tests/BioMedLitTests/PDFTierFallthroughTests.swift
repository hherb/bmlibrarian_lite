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

private struct StubExtractor: PDFTextExtracting {
    let result: PDFExtractionResult
    func extract(from fileURL: URL) -> PDFExtractionResult { result }
}

/// A PDF tier that could not fetch its bytes must not end the chain.
///
/// The tier used to decide whether to continue by asking whether an abstract
/// happened to be in hand, because "extraction is switched off" and "the
/// download failed" both arrived as `(nil, nil)`. A Europe PMC render URL that
/// 404s — those entries routinely point at publisher pages that no longer serve
/// the file — therefore returned as this article's full text, and the
/// open-access Unpaywall copy of the same paper was never requested.
final class PDFTierFallthroughTests: XCTestCase {
    private static let pdfBytes = Data([0x25, 0x50, 0x44, 0x46, 0x2D, 0x31, 0x2E, 0x34])
    private static let pmid = "fallthrough-test-99201"

    /// Names both a PMC ID and a free PDF render URL, so identifier resolution
    /// yields the `pdfRenderURL` the Europe PMC PDF tier needs.
    private static let searchResponseWithPDFRender = #"""
    {"resultList": {"result": [{
      "id": "1", "pmid": "1", "pmcid": "PMC1", "inPMC": "Y",
      "fullTextUrlList": {"fullTextUrl": [
        {"documentStyle": "pdf", "site": "Europe_PMC",
         "url": "https://europepmc.org/articles/PMC1/pdf",
         "availability": "Open access", "availabilityCode": "OA"}
      ]}
    }]}}
    """#

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.pmid)
    }

    override func tearDown() {
        StubURLProtocol.reset()
        FullTextService.deleteCachedPDF(for: Self.pmid)
        super.tearDown()
    }

    private func makeService(
        extractor: PDFTextExtracting = StubExtractor(result: PDFExtractionResult(
            text: "recovered", success: true, pageCount: 1, convertedPages: 1, warnings: []
        ))
    ) -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractor: extractor
        )
    }

    /// The headline case. The Europe PMC render URL 404s; Unpaywall has a copy
    /// that extracts cleanly; the reader must end up with the Unpaywall copy.
    func testADeadEuropePMCRenderURLFallsThroughToUnpaywall() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(Self.searchResponseWithPDFRender.utf8)),
            "fullTextXML": (404, Data()),
            "articles/PMC1/pdf": (404, Data()),
            "unpaywall": (
                200,
                Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/oa.pdf"}}"#.utf8)
            ),
            "oa.pdf": (200, Self.pdfBytes),
        ]

        let result = try await makeService()
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(
            result.source, .unpaywall,
            "a dead render URL must not stop the chain reaching an open-access copy"
        )
        XCTAssertEqual(result.contentKind, .extracted)
        XCTAssertEqual(result.extractedText, "recovered")
    }

    /// And when no later tier does better, the link we could not download is
    /// still offered — it names the article, which a publisher landing page only
    /// guesses at. Below an abstract, above the DOI page.
    func testAnUndownloadablePDFLinkIsStillOfferedWhenNothingBetterArrives() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(Self.searchResponseWithPDFRender.utf8)),
            "fullTextXML": (404, Data()),
            "articles/PMC1/pdf": (404, Data()),
            "unpaywall": (404, Data()),
        ]

        let result = try await makeService()
            .fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.source, .europePMCPDF)
        XCTAssertEqual(result.contentKind, FullTextContentKind.none)
        XCTAssertNil(result.localPDFPath, "nothing was downloaded, so there is no file")
        XCTAssertEqual(
            result.pdfURL?.absoluteString, "https://europepmc.org/articles/PMC1/pdf"
        )
    }

    /// Extraction switched off is not a failed download. The tier is meant to
    /// hand back the URL immediately in that case, without trying anything else.
    func testExtractionSwitchedOffStillReturnsTheFirstPDFURL() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(Self.searchResponseWithPDFRender.utf8)),
            "fullTextXML": (404, Data()),
            "unpaywall": (
                200,
                Data(#"{"best_oa_location":{"url_for_pdf":"https://example.org/oa.pdf"}}"#.utf8)
            ),
        ]
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        let service = FullTextService(
            email: "test@example.org",
            session: session,
            europePMCService: EuropePMCService(session: session),
            extractPDFText: false
        )

        let result = try await service.fetchFullText(pmcId: nil, doi: "10.1/x", pmid: Self.pmid)

        XCTAssertEqual(result.source, .europePMCPDF)
        XCTAssertNil(result.localPDFPath)
    }

    /// The tier the extraction slice was built for was unreachable on its most
    /// common input: the render URL arrives only with identifier resolution,
    /// which runs only when the caller has no PMC ID — and every app call site
    /// passes the one it already holds.
    func testTheEuropePMCPDFTierIsReachedEvenWhenTheCallerSuppliedAPMCId() async throws {
        StubURLProtocol.routes = [
            "search": (200, Data(Self.searchResponseWithPDFRender.utf8)),
            "fullTextXML": (404, Data()),
            "articles/PMC1/pdf": (200, Self.pdfBytes),
        ]

        let result = try await makeService()
            .fetchFullText(pmcId: "PMC1", doi: nil, pmid: Self.pmid)

        XCTAssertEqual(
            result.source, .europePMCPDF,
            "supplying the PMC ID must not skip the free PDF render tier"
        )
        XCTAssertEqual(result.extractedText, "recovered")
    }
}
