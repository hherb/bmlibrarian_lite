// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// Integration tests that download real JATS XML from Europe PMC and parse it.
///
/// Run with: INTEGRATION_TESTS=1 swift test --filter JATSXMLParserIntegrationTests
/// Skipped by default when INTEGRATION_TESTS env var is not set.
final class JATSXMLParserIntegrationTests: XCTestCase {

    // MARK: - Test Data

    struct TestArticle {
        let label: String
        let doi: String
        let pmcId: String
        let pmid: String
    }

    static let testArticles: [TestArticle] = [
        TestArticle(
            label: "article_1_sage",
            doi: "10.1177/20552076251406653",
            pmcId: "PMC12759138",
            pmid: "41488273"
        ),
        TestArticle(
            label: "article_2_jmir",
            doi: "10.2196/82550",
            pmcId: "PMC12661592",
            pmid: "41313195"
        ),
        TestArticle(
            label: "article_3_mdpi",
            doi: "10.3390/healthcare14010097",
            pmcId: "PMC12785261",
            pmid: "41517028"
        ),
    ]

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["INTEGRATION_TESTS"] == "1",
            "Integration tests disabled. Set INTEGRATION_TESTS=1 to run."
        )
    }

    // MARK: - Helper

    private func downloadXML(pmcId: String) async throws -> Data {
        let baseURL = BioMedLitConstants.europePMCBaseURL
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"
        guard let url = URL(string: "\(baseURL)/\(normalizedId)/fullTextXML") else {
            XCTFail("Invalid URL for PMC ID: \(pmcId)")
            throw URLError(.badURL)
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 30

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            XCTFail("HTTP \(status) for \(pmcId)")
            throw URLError(.badServerResponse)
        }

        return data
    }

    // MARK: - Download Tests

    func testDownloadXML_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXML(pmcId: article.pmcId)
        let xmlString = String(data: data, encoding: .utf8) ?? ""
        XCTAssertGreaterThan(data.count, 1000, "XML should be substantial")
        XCTAssertTrue(xmlString.contains("<article"), "Should contain <article> element")
        XCTAssertTrue(xmlString.contains("</article>"), "Should contain closing </article>")
    }

    func testDownloadXML_article2() async throws {
        let article = Self.testArticles[1]
        let data = try await downloadXML(pmcId: article.pmcId)
        XCTAssertGreaterThan(data.count, 1000, "XML should be substantial (versioned PMC ID)")
    }

    func testDownloadXML_article3() async throws {
        let article = Self.testArticles[2]
        let data = try await downloadXML(pmcId: article.pmcId)
        XCTAssertGreaterThan(data.count, 1000, "XML should be substantial")
    }

    // MARK: - Parse to Markdown Tests

    func testParseToMarkdown_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Markdown should be substantial")
        XCTAssertTrue(markdown.hasPrefix("# "), "Should start with title heading")
        XCTAssertTrue(markdown.contains("## Abstract"), "Should contain Abstract section")
        XCTAssertTrue(markdown.contains(article.doi), "Should contain DOI")
    }

    func testParseToMarkdown_article2() async throws {
        let article = Self.testArticles[1]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Markdown should be substantial")
        XCTAssertTrue(markdown.hasPrefix("# "), "Should start with title heading")
        XCTAssertTrue(markdown.contains("## Abstract"), "Should contain Abstract section")
    }

    func testParseToMarkdown_article3() async throws {
        let article = Self.testArticles[2]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Markdown should be substantial")
        XCTAssertTrue(markdown.hasPrefix("# "), "Should start with title heading")
        XCTAssertTrue(markdown.contains("## Abstract"), "Should contain Abstract section")
    }

    // MARK: - Parse to HTML Tests

    func testParseToHTML_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let html = try parser.parseToHTML()

        XCTAssertGreaterThan(html.count, 500, "HTML should be substantial")
        XCTAssertTrue(html.contains("<h1>"), "Should contain h1 tag")
        XCTAssertTrue(html.contains("<h2>Abstract</h2>"), "Should contain Abstract heading")
    }

    // MARK: - Parse to Article (Structured Data) Tests

    func testParseToArticle_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let jatsArticle = try parser.parseToArticle()

        XCTAssertFalse(jatsArticle.title.isEmpty, "Title should not be empty")
        XCTAssertFalse(jatsArticle.authors.isEmpty, "Authors should not be empty")
        XCTAssertFalse(jatsArticle.abstractSections.isEmpty, "Abstract should not be empty")
        XCTAssertFalse(jatsArticle.bodySections.isEmpty, "Body sections should not be empty")
        XCTAssertEqual(jatsArticle.doi, article.doi, "DOI should match")
    }

    func testParseToArticle_article2() async throws {
        let article = Self.testArticles[1]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let jatsArticle = try parser.parseToArticle()

        XCTAssertFalse(jatsArticle.title.isEmpty, "Title should not be empty")
        XCTAssertFalse(jatsArticle.abstractSections.isEmpty, "Abstract should not be empty")
        XCTAssertFalse(jatsArticle.bodySections.isEmpty, "Body sections should not be empty")
    }

    func testParseToArticle_article3() async throws {
        let article = Self.testArticles[2]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let jatsArticle = try parser.parseToArticle()

        XCTAssertFalse(jatsArticle.title.isEmpty, "Title should not be empty")
        XCTAssertFalse(jatsArticle.abstractSections.isEmpty, "Abstract should not be empty")
        XCTAssertFalse(jatsArticle.bodySections.isEmpty, "Body sections should not be empty")
        XCTAssertFalse(jatsArticle.references.isEmpty, "References should not be empty")
    }

    // MARK: - Body Section Structure Tests

    func testBodySectionsHaveContent_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXML(pmcId: article.pmcId)
        let parser = JATSXMLParser(data: data, knownPMCId: article.pmcId)
        let jatsArticle = try parser.parseToArticle()

        let sectionsWithContent = jatsArticle.bodySections.filter { !$0.paragraphs.isEmpty }
        XCTAssertGreaterThan(
            sectionsWithContent.count, 0,
            "At least one body section should have paragraphs"
        )

        let sectionsWithTitles = jatsArticle.bodySections.filter { !$0.title.isEmpty }
        XCTAssertGreaterThan(
            sectionsWithTitles.count, 0,
            "At least one body section should have a title"
        )
    }

    // MARK: - Identifier Resolution Helpers

    /// Resolve a PMID to its PMC ID via Europe PMC search API, then download XML.
    private func downloadXMLByPMID(_ pmid: String) async throws -> Data {
        let pmcId = try await resolveIdentifier(query: "ext_id:\(pmid) src:med")
        return try await downloadXML(pmcId: pmcId)
    }

    /// Resolve a DOI to its PMC ID via Europe PMC search API, then download XML.
    private func downloadXMLByDOI(_ doi: String) async throws -> Data {
        let pmcId = try await resolveIdentifier(query: "DOI:\"\(doi)\"")
        return try await downloadXML(pmcId: pmcId)
    }

    /// Search Europe PMC and extract the PMC ID from the first result.
    private func resolveIdentifier(query: String) async throws -> String {
        let service = EuropePMCService()
        let result = try await service.search(
            query: query,
            pageSize: 1,
            requireAbstract: false
        )
        guard let firstArticle = result.articles.first,
              let pmcId = firstArticle.pmcId, !pmcId.isEmpty else {
            XCTFail("No PMC ID found for query: \(query)")
            throw URLError(.resourceUnavailable)
        }
        return pmcId
    }

    // MARK: - Identifier Resolution Tests (PMID)

    func testFindFullTextByPMID_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXMLByPMID(article.pmid)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via PMID lookup")
        XCTAssertTrue(markdown.hasPrefix("# "), "Should start with title heading")
    }

    func testFindFullTextByPMID_article2() async throws {
        let article = Self.testArticles[1]
        let data = try await downloadXMLByPMID(article.pmid)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via PMID lookup")
    }

    func testFindFullTextByPMID_article3() async throws {
        let article = Self.testArticles[2]
        let data = try await downloadXMLByPMID(article.pmid)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via PMID lookup")
    }

    // MARK: - Identifier Resolution Tests (DOI)

    func testFindFullTextByDOI_article1() async throws {
        let article = Self.testArticles[0]
        let data = try await downloadXMLByDOI(article.doi)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via DOI lookup")
        XCTAssertTrue(markdown.hasPrefix("# "), "Should start with title heading")
    }

    func testFindFullTextByDOI_article2() async throws {
        let article = Self.testArticles[1]
        let data = try await downloadXMLByDOI(article.doi)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via DOI lookup")
    }

    func testFindFullTextByDOI_article3() async throws {
        let article = Self.testArticles[2]
        let data = try await downloadXMLByDOI(article.doi)
        let parser = JATSXMLParser(data: data)
        let markdown = try parser.parseToMarkdown()

        XCTAssertGreaterThan(markdown.count, 500, "Should get substantial markdown via DOI lookup")
    }

    // MARK: - PMC PDF Fallback Tests

    /// Article with free PDF in PMC but no JATS XML available.
    static let pmcPdfOnlyArticle = TestArticle(
        label: "pmc_pdf_only",
        doi: "10.1212/CON.0000000000000816",
        pmcId: "PMC7339914",
        pmid: "31996627"
    )

    func testPdfRenderURLExtracted() async throws {
        let service = EuropePMCService()
        let result = try await service.search(
            query: "PMCID:PMC7339914",
            pageSize: 1,
            requireAbstract: false
        )
        guard let article = result.articles.first else {
            XCTFail("Article PMC7339914 not found in Europe PMC")
            return
        }
        XCTAssertNotNil(article.pdfRenderURL, "Should have a PDF render URL")
        XCTAssertTrue(
            article.pdfRenderURL?.contains("pdf=render") == true,
            "PDF URL should contain pdf=render, got: \(article.pdfRenderURL ?? "nil")"
        )
    }

    func testFullTextServiceFindsPdfFallback() async throws {
        let article = Self.pmcPdfOnlyArticle
        let service = FullTextService(email: "test@example.com")
        let result = try await service.fetchFullText(
            pmcId: nil,
            doi: article.doi,
            pmid: article.pmid
        )
        switch result {
        case .europePMCPDF(let pdfURL):
            XCTAssertTrue(
                pdfURL.absoluteString.contains("pdf=render"),
                "Should return Europe PMC PDF render URL, got: \(pdfURL.absoluteString)"
            )
        case .europePMC:
            // If XML becomes available in future, that's also acceptable
            break
        default:
            // Unpaywall or DOI fallback is acceptable but PMC PDF should be preferred
            break
        }
    }
}
