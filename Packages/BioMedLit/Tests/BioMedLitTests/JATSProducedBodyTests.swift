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

/// A body-less deposit parses *successfully* — `parseToHTML` throws
/// `.noContent` only when the whole rendering is empty, and an abstract is not
/// empty. So Europe PMC's abstract-only records were returned, cached and
/// analysed as article bodies, and nothing in the parse said otherwise.
final class JATSProducedBodyTests: XCTestCase {
    private func xml(_ body: String) -> Data {
        Data("""
        <article xmlns:xlink="http://www.w3.org/1999/xlink">
          <front><article-meta>
            <title-group><article-title>A title</article-title></title-group>
            <abstract><p>Background and findings.</p></abstract>
          </article-meta></front>
          \(body)
        </article>
        """.utf8)
    }

    func testAnArticleWithABodyReportsOne() throws {
        let parser = JATSXMLParser(data: xml("<body><sec><title>Methods</title><p>We enrolled 120 patients.</p></sec></body>"))
        _ = try parser.parseToHTML()
        XCTAssertTrue(parser.producedBody)
    }

    /// The case that matters: it parses, it renders, and it is not an article.
    func testABodylessDepositReportsNoBody() throws {
        let parser = JATSXMLParser(data: xml(""))
        let html = try parser.parseToHTML()
        XCTAssertFalse(html.isEmpty, "the abstract still renders; that is the trap")
        XCTAssertFalse(parser.producedBody)
    }

    /// A `<body>` element holding only loose prose still counts. Anything less
    /// would undo the implicit-section fix (#1.3 in the alignment doc), which
    /// exists precisely because `<sec>` is optional.
    func testLooseProseInABodyCountsAsABody() throws {
        let parser = JATSXMLParser(data: xml("<body><p>Loose prose with no section.</p></body>"))
        _ = try parser.parseToHTML()
        XCTAssertTrue(parser.producedBody)
    }

    /// An empty `<body>` element is not a body. The tag being present says
    /// nothing about there being prose in it.
    func testAnEmptyBodyElementIsNotABody() throws {
        let parser = JATSXMLParser(data: xml("<body></body>"))
        _ = try parser.parseToHTML()
        XCTAssertFalse(parser.producedBody)
    }

    /// Regression test: a deposit with `<front>` and `<back>` but no `<body>` is
    /// exactly the abstract-only Europe PMC shape this property exists to detect.
    /// Back-matter sections (acknowledgements, funding, etc.) must not be counted
    /// as a body. This was the critical bug: `bodySections` receives both body and
    /// back-matter sections, so this shape wrongly reported `producedBody == true`.
    func testAFrontAndBackWithoutBodyReportsNoBody() throws {
        let parser = JATSXMLParser(data: xml("""
            <back>
              <sec><title>Acknowledgements</title><p>We thank the funding agency.</p></sec>
              <p>This is loose prose in the back matter.</p>
            </back>
            """))
        let html = try parser.parseToHTML()
        XCTAssertFalse(html.isEmpty, "abstract and back matter still render")
        XCTAssertFalse(parser.producedBody, "back matter is not a body")
    }

    /// An empty `<sec>` in the body — just the tag with no title or content —
    /// does not count as a body. A section is not made by its wrapper but by its
    /// prose. This was Consequence B in the reviewer's finding.
    func testABodyWithOnlyAnEmptySectionReportsNoBody() throws {
        let parser = JATSXMLParser(data: xml("<body><sec></sec></body>"))
        _ = try parser.parseToHTML()
        XCTAssertFalse(parser.producedBody)
    }

    /// A document with both a populated `<body>` and a populated `<back>` is an
    /// article with both body and acknowledgements. It must report as having a body.
    /// This guards against over-applying the fix.
    func testABodyAndPopulatedBackReportsBody() throws {
        let parser = JATSXMLParser(data: xml("""
            <body><sec><title>Methods</title><p>We studied 100 subjects.</p></sec></body>
            <back><sec><title>Acknowledgements</title><p>Funded by NIH.</p></sec></back>
            """))
        _ = try parser.parseToHTML()
        XCTAssertTrue(parser.producedBody)
    }
}
