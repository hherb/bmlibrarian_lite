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

/// Tests for `<caption>` routing and unsectioned `<body>` prose.
///
/// Mirrors bmlib 0.6.0 and issue #30: `didEndElement` routed `<title>` and
/// `<p>` on whichever `in*` flag happened to be set, so a figure caption
/// nested in a section renamed the section and blanked the figure; and loose
/// `<body>` prose with no enclosing `<sec>` was dropped entirely.
final class JATSSectionRoutingTests: XCTestCase {

    // MARK: - Helpers

    private func parse(body: String) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <title-group>
                <article-title>T</article-title>
              </title-group>
            </article-meta>
          </front>
          <body>
        \(body)
          </body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
    }

    // MARK: - Caption inside a section (bmlib 0.6.0)

    /// The ordinary PMC layout: `<fig>` nested inside `<sec>`.
    func testFigureCaptionDoesNotRenameEnclosingSection() throws {
        let article = try parse(body: """
        <sec>
          <title>Methods</title>
          <p>We enrolled 120 patients.</p>
          <fig id="f1"><label>Figure 1</label>
            <caption><title>Study flow diagram</title><p>CONSORT diagram of enrolment.</p></caption>
          </fig>
          <p>Analysis was by intention to treat.</p>
        </sec>
        """)

        XCTAssertEqual(article.bodySections.count, 1)
        XCTAssertEqual(article.bodySections[0].title, "Methods")
    }

    func testCaptionProseDoesNotContaminateSectionParagraphs() throws {
        let article = try parse(body: """
        <sec>
          <title>Methods</title>
          <p>We enrolled 120 patients.</p>
          <fig id="f1"><label>Figure 1</label>
            <caption><title>Study flow diagram</title><p>CONSORT diagram of enrolment.</p></caption>
          </fig>
          <p>Analysis was by intention to treat.</p>
        </sec>
        """)

        XCTAssertEqual(
            article.bodySections[0].paragraphs,
            ["We enrolled 120 patients.", "Analysis was by intention to treat."]
        )
    }

    func testFigureKeepsItsCaptionWhenNestedInASection() throws {
        let article = try parse(body: """
        <sec>
          <title>Methods</title>
          <fig id="f1"><label>Figure 1</label>
            <caption><title>Study flow diagram</title><p>CONSORT diagram of enrolment.</p></caption>
          </fig>
        </sec>
        """)

        XCTAssertEqual(article.figures.count, 1)
        XCTAssertEqual(article.figures[0].caption, "Study flow diagram CONSORT diagram of enrolment.")
    }

    func testTableCaptionDoesNotRenameEnclosingSection() throws {
        let article = try parse(body: """
        <sec>
          <title>Results</title>
          <p>Baseline characteristics are shown below.</p>
          <table-wrap id="t1"><label>Table 1</label>
            <caption><title>Baseline characteristics</title><p>Values are n (%).</p></caption>
            <table><tbody><tr><td>Age</td></tr></tbody></table>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.bodySections[0].title, "Results")
        XCTAssertEqual(article.bodySections[0].paragraphs, ["Baseline characteristics are shown below."])
        XCTAssertEqual(article.tables.count, 1)
        XCTAssertEqual(article.tables[0].caption, "Baseline characteristics Values are n (%).")
    }

    /// A `<p>` inside a `<fig>` but outside its `<caption>` is furniture, not
    /// prose: it must not reach the section either.
    func testNonCaptionParagraphInsideFigureIsNotTreatedAsSectionProse() throws {
        let article = try parse(body: """
        <sec>
          <title>Methods</title>
          <fig id="f1">
            <caption><p>Real caption.</p></caption>
            <p>Attribution furniture.</p>
          </fig>
        </sec>
        """)

        XCTAssertEqual(article.bodySections[0].paragraphs, [])
        XCTAssertEqual(article.figures[0].caption, "Real caption.")
    }

    // MARK: - A structured abstract must not emit body sections

    /// `<abstract>` may be structured with `<sec>`. Those sections belong to the
    /// abstract, which has its own accumulator — pushing a `SectionBuilder` for
    /// them appended an empty section to `bodySections` at every `</sec>`.
    func testStructuredAbstractDoesNotEmitBodySections() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group><article-title>T</article-title></title-group>
              <abstract>
                <sec><title>Background</title><p>Background prose.</p></sec>
                <sec><title>Methods</title><p>Methods prose.</p></sec>
              </abstract>
            </article-meta>
          </front>
          <body><sec><title>Introduction</title><p>Body prose.</p></sec></body>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.bodySections.count, 1)
        XCTAssertEqual(article.bodySections[0].title, "Introduction")
    }

    /// The abstract's own sections must still be read.
    func testStructuredAbstractSectionsAreStillParsed() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group><article-title>T</article-title></title-group>
              <abstract>
                <sec><title>Background</title><p>Background prose.</p></sec>
                <sec><title>Methods</title><p>Methods prose.</p></sec>
              </abstract>
            </article-meta>
          </front>
          <body><p>Body prose.</p></body>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.abstractSections.map(\.title), ["Background", "Methods"])
        XCTAssertEqual(
            article.abstractSections.map(\.content),
            ["Background prose.", "Methods prose."]
        )
    }

    // MARK: - Unsectioned body (bmlib issue #30)

    func testLooseBodyProseIsKept() throws {
        let article = try parse(body: """
        <p>First loose paragraph.</p>
        <p>Second loose paragraph.</p>
        """)

        XCTAssertEqual(article.bodySections.count, 1)
        XCTAssertEqual(article.bodySections[0].title, "")
        XCTAssertEqual(
            article.bodySections[0].paragraphs,
            ["First loose paragraph.", "Second loose paragraph."]
        )
    }

    func testLooseBodyProseReachesTheMarkdown() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group><article-title>T</article-title></title-group>
            </article-meta>
          </front>
          <body><p>Every word of the article body.</p></body>
        </article>
        """
        let markdown = try JATSXMLParser(data: Data(xml.utf8)).parseToMarkdown()

        XCTAssertTrue(
            markdown.contains("Every word of the article body."),
            "markdown was: \(markdown)"
        )
    }

    /// Loose prose before a `<sec>` keeps its position in document order,
    /// rather than being folded in after the sectioned content.
    func testLooseProseBeforeASectionKeepsDocumentOrder() throws {
        let article = try parse(body: """
        <p>Lead-in prose.</p>
        <sec><title>Methods</title><p>Sectioned prose.</p></sec>
        <p>Trailing prose.</p>
        """)

        XCTAssertEqual(article.bodySections.count, 3)
        XCTAssertEqual(article.bodySections[0].title, "")
        XCTAssertEqual(article.bodySections[0].paragraphs, ["Lead-in prose."])
        XCTAssertEqual(article.bodySections[1].title, "Methods")
        XCTAssertEqual(article.bodySections[2].title, "")
        XCTAssertEqual(article.bodySections[2].paragraphs, ["Trailing prose."])
    }

    /// An empty paragraph must not open a titleless section, so a `<body>`
    /// holding nothing but whitespace stays body-less.
    func testWhitespaceOnlyBodyProducesNoSection() throws {
        let article = try parse(body: "<p>   </p>")

        XCTAssertEqual(article.bodySections.count, 0)
    }

    /// A loose figure caption must not become a titleless body section.
    func testLooseFigureCaptionDoesNotBecomeABodySection() throws {
        let article = try parse(body: """
        <fig id="f1"><caption><title>Flow</title><p>Caption prose.</p></caption></fig>
        """)

        XCTAssertEqual(article.bodySections.count, 0)
        XCTAssertEqual(article.figures[0].caption, "Flow Caption prose.")
    }
}
