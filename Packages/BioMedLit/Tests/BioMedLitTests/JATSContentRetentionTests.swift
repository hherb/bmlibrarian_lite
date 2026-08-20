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

/// Tests that content the parser sees is not silently discarded.
///
/// Each case here covers text that reached `fullTextContent` before some
/// narrowing change and stopped afterwards. That string is what the transparency
/// COI and data-availability regexes read, so a quiet drop shows up as a paper
/// scoring as undisclosed rather than as a parse failure.
final class JATSContentRetentionTests: XCTestCase {

    // MARK: - Helpers

    private func article(body: String, back: String = "") throws -> JATSArticle {
        try JATSXMLParser(data: Data(xml(body: body, back: back).utf8)).parseToArticle()
    }

    private func markdown(body: String, back: String = "") throws -> String {
        try JATSXMLParser(data: Data(xml(body: body, back: back).utf8)).parseToMarkdown()
    }

    private func xml(body: String, back: String) -> String {
        """
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
        \(back)
        </article>
        """
    }

    // MARK: - Table and figure footnotes

    /// Routing every non-caption `<p>` inside a `<table-wrap>` to the cell branch
    /// dropped `<table-wrap-foot>` outright. The rendered table does not carry it,
    /// so nothing else was keeping it — and footnotes hold the abbreviation
    /// expansions and per-table funding notes the transparency analysis reads.
    func testTableFootnotesAreCaptured() throws {
        let article = try article(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <caption><title>Baseline characteristics.</title></caption>
            <table><tbody><tr><td>Age</td><td>54</td></tr></tbody></table>
            <table-wrap-foot>
              <fn><p>Funded by Acme Pharmaceuticals Inc.</p></fn>
              <fn><p>SD = standard deviation.</p></fn>
            </table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.tables.first?.footnotes, [
            "Funded by Acme Pharmaceuticals Inc.",
            "SD = standard deviation.",
        ])
    }

    func testTableFootnotesReachTheMarkdown() throws {
        let text = try markdown(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <table><tbody><tr><td>Age</td><td>54</td></tr></tbody></table>
            <table-wrap-foot><fn><p>Funded by Acme Pharmaceuticals Inc.</p></fn></table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertTrue(text.contains("Funded by Acme Pharmaceuticals Inc."))
    }

    /// Footnotes are not the caption, and must not be folded into it.
    func testFootnotesAreKeptSeparateFromTheCaption() throws {
        let article = try article(body: """
        <sec>
          <table-wrap id="t1">
            <caption><title>Baseline characteristics.</title></caption>
            <table><tbody><tr><td>Age</td><td>54</td></tr></tbody></table>
            <table-wrap-foot><fn><p>SD = standard deviation.</p></fn></table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.tables.first?.caption, "Baseline characteristics.")
    }

    /// Cell prose is still furniture: the rendered table already carries it, and
    /// letting it through duplicated it into the article text.
    func testCellParagraphsAreStillNotTreatedAsProse() throws {
        let article = try article(body: """
        <sec>
          <title>Results</title>
          <p>Real section prose.</p>
          <table-wrap id="t1">
            <table><tbody><tr><td><p>Cell prose.</p></td></tr></tbody></table>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.bodySections[0].paragraphs, ["Real section prose."])
        XCTAssertEqual(article.tables.first?.footnotes, [])
    }

    // MARK: - Unsectioned back matter

    /// `<sec>` is optional in `<back>` just as it is in `<body>`, and `<ack>`
    /// routinely holds `<p>` directly — which is where funding acknowledgements
    /// and competing-interest statements live.
    func testUnsectionedAcknowledgementProseIsKept() throws {
        let article = try article(
            body: "<sec><title>Methods</title><p>We enrolled 120 patients.</p></sec>",
            back: """
            <back>
              <ack><p>This work was funded by Acme Pharmaceuticals Inc.</p></ack>
            </back>
            """
        )

        let allProse = article.bodySections.flatMap(\.paragraphs)
        XCTAssertTrue(allProse.contains("This work was funded by Acme Pharmaceuticals Inc."))
    }

    func testUnsectionedFootnoteGroupProseIsKept() throws {
        let article = try article(
            body: "<sec><title>Methods</title><p>Enrolment.</p></sec>",
            back: """
            <back>
              <fn-group><fn><p>The authors declare no competing interests.</p></fn></fn-group>
            </back>
            """
        )

        let allProse = article.bodySections.flatMap(\.paragraphs)
        XCTAssertTrue(allProse.contains("The authors declare no competing interests."))
    }

    /// Sectioned back matter already worked and must keep working.
    func testSectionedBackMatterIsUnaffected() throws {
        let article = try article(
            body: "<sec><title>Methods</title><p>Enrolment.</p></sec>",
            back: "<back><sec><title>Funding</title><p>Funded by NIH.</p></sec></back>"
        )

        XCTAssertTrue(article.bodySections.contains { $0.title == "Funding" })
    }

    func testWhitespaceOnlyBackProseProducesNoSection() throws {
        let article = try article(
            body: "<sec><title>Methods</title><p>Enrolment.</p></sec>",
            back: "<back><ack><p>   </p></ack></back>"
        )

        XCTAssertEqual(article.bodySections.count, 1)
    }
}
