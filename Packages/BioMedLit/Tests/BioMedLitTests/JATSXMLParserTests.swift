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

final class JATSXMLParserTests: XCTestCase {

    // MARK: - Basic Parsing Tests

    func testParseSimpleArticle() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmid">12345678</article-id>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <article-id pub-id-type="doi">10.1234/test</article-id>
              <title-group>
                <article-title>Test Article Title</article-title>
              </title-group>
              <contrib-group>
                <contrib contrib-type="author">
                  <name>
                    <surname>Smith</surname>
                    <given-names>John</given-names>
                  </name>
                </contrib>
              </contrib-group>
              <abstract>
                <p>This is the abstract text.</p>
              </abstract>
            </article-meta>
          </front>
          <body>
            <sec>
              <title>Introduction</title>
              <p>This is the introduction.</p>
            </sec>
          </body>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        let markdown = try parser.parseToMarkdown()

        XCTAssertTrue(markdown.contains("Test Article Title"))
        XCTAssertTrue(markdown.contains("John Smith"))
        XCTAssertTrue(markdown.contains("This is the abstract text."))
        XCTAssertTrue(markdown.contains("Introduction"))
        XCTAssertTrue(markdown.contains("This is the introduction."))
    }

    func testParseToHTML() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmid">12345678</article-id>
              <title-group>
                <article-title>HTML Test</article-title>
              </title-group>
              <abstract>
                <p>Abstract content.</p>
              </abstract>
            </article-meta>
          </front>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        let html = try parser.parseToHTML()

        XCTAssertTrue(html.contains("<h1>HTML Test</h1>"))
        XCTAssertTrue(html.contains("<h2>Abstract</h2>"))
        XCTAssertTrue(html.contains("Abstract content."))
    }

    func testParseToArticle() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmid">12345678</article-id>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <article-id pub-id-type="doi">10.1234/test</article-id>
              <title-group>
                <article-title>Structured Article</article-title>
              </title-group>
              <pub-date>
                <year>2024</year>
              </pub-date>
            </article-meta>
          </front>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        let article = try parser.parseToArticle()

        XCTAssertEqual(article.title, "Structured Article")
        XCTAssertEqual(article.pmid, "12345678")
        XCTAssertEqual(article.pmcId, "PMC1234567")
        XCTAssertEqual(article.doi, "10.1234/test")
        XCTAssertEqual(article.year, "2024")
    }

    // MARK: - Figure Parsing Tests

    func testParseFigures() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <title-group>
                <article-title>Figure Test</article-title>
              </title-group>
            </article-meta>
          </front>
          <body>
            <fig id="Fig1">
              <label>Figure 1</label>
              <caption><p>This is figure 1 caption.</p></caption>
              <graphic xlink:href="test_Fig1_HTML"/>
            </fig>
          </body>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data, knownPMCId: "PMC1234567")

        let article = try parser.parseToArticle()

        XCTAssertEqual(article.figures.count, 1)
        XCTAssertEqual(article.figures[0].id, "Fig1")
        XCTAssertEqual(article.figures[0].label, "Figure 1")
        XCTAssertTrue(article.figures[0].caption.contains("figure 1 caption"))
        XCTAssertNotNil(article.figures[0].graphicURL)
    }

    // MARK: - Table Parsing Tests

    func testParseTables() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group>
                <article-title>Table Test</article-title>
              </title-group>
            </article-meta>
          </front>
          <body>
            <table-wrap id="Tab1">
              <label>Table 1</label>
              <caption><p>Sample table</p></caption>
              <table>
                <thead>
                  <tr>
                    <th>Column A</th>
                    <th>Column B</th>
                  </tr>
                </thead>
                <tbody>
                  <tr>
                    <td>Value 1</td>
                    <td>Value 2</td>
                  </tr>
                </tbody>
              </table>
            </table-wrap>
          </body>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        let article = try parser.parseToArticle()

        XCTAssertEqual(article.tables.count, 1)
        XCTAssertEqual(article.tables[0].id, "Tab1")
        XCTAssertEqual(article.tables[0].label, "Table 1")
        XCTAssertTrue(article.tables[0].markdownContent.contains("Column A"))
        XCTAssertTrue(article.tables[0].markdownContent.contains("Value 1"))
    }

    // MARK: - Reference Parsing Tests

    func testParseReferences() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group>
                <article-title>Reference Test</article-title>
              </title-group>
            </article-meta>
          </front>
          <back>
            <ref-list>
              <ref id="CR1">
                <label>1</label>
                <element-citation publication-type="journal">
                  <person-group person-group-type="author">
                    <name>
                      <surname>Doe</surname>
                      <given-names>Jane</given-names>
                    </name>
                  </person-group>
                  <article-title>Referenced Article</article-title>
                  <source>Test Journal</source>
                  <year>2023</year>
                  <volume>10</volume>
                  <fpage>100</fpage>
                  <lpage>110</lpage>
                </element-citation>
              </ref>
            </ref-list>
          </back>
        </article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        let article = try parser.parseToArticle()

        XCTAssertEqual(article.references.count, 1)
        XCTAssertEqual(article.references[0].id, "CR1")
        XCTAssertEqual(article.references[0].label, "1")
        XCTAssertEqual(article.references[0].authors.count, 1)
        XCTAssertTrue(article.references[0].authors[0].contains("Jane"))
        XCTAssertEqual(article.references[0].source, "Test Journal")
        XCTAssertEqual(article.references[0].year, "2023")
    }

    // MARK: - Error Handling Tests

    func testEmptyContentThrowsError() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article></article>
        """

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        XCTAssertThrowsError(try parser.parseToMarkdown()) { error in
            XCTAssertTrue(error is JATSParseError)
        }
    }

    func testInvalidXMLThrowsError() {
        let xml = "not valid xml at all <>"

        let data = xml.data(using: .utf8)!
        let parser = JATSXMLParser(data: data)

        XCTAssertThrowsError(try parser.parseToMarkdown()) { error in
            XCTAssertTrue(error is JATSParseError)
        }
    }
}
