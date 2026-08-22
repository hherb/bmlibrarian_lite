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

    /// `<table-wrap-foot>` may hold `<p>` directly — a general note about the
    /// table, with no marker to hang an `<fn>` off. It is `</table-wrap-foot>`'s
    /// own depth that keeps such a paragraph out of the cell furniture, and until
    /// this test nothing covered it: every case went through an `<fn>`, which
    /// raises the depth by itself, so dropping the `<table-wrap-foot>` increment
    /// entirely left the suite green.
    func testTableFootProseOutsideAFootnoteIsStillCaptured() throws {
        let article = try article(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <table><tbody><tr><td>Age</td><td>54</td></tr></tbody></table>
            <table-wrap-foot><p>Values are mean (SD).</p></table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.tables.first?.footnotes, ["Values are mean (SD)."])
    }

    /// The same paragraph after an `<fn>`, which is where publishers usually put
    /// it. `</fn>` must decrement the depth rather than clear it, or the note
    /// falls out of the footnotes and is dropped as cell furniture.
    func testTableFootProseAfterAFootnoteIsStillCaptured() throws {
        let article = try article(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <table><tbody><tr><td>Age</td><td>54<sup>a</sup></td></tr></tbody></table>
            <table-wrap-foot>
              <fn id="t1fn1"><label>a</label><p>Adjusted for sex.</p></fn>
              <p>Values are mean (SD).</p>
            </table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(
            article.tables.first?.footnotes,
            ["a — Adjusted for sex.", "Values are mean (SD)."]
        )
    }

    /// `</table-wrap-foot>` must give its increment back, or the counter never
    /// falls and every later `<p>` in the document routes to the footnote branch —
    /// where, with no exhibit open, it is discarded. Only the real-corpus digest
    /// caught this before, and it reports a byte-length change rather than a lost
    /// section.
    func testSectionProseAfterAFootnotedTableIsStillSectionProse() throws {
        let article = try article(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <table><tbody><tr><td>Age</td><td>54<sup>a</sup></td></tr></tbody></table>
            <table-wrap-foot>
              <fn id="t1fn1"><label>a</label><p>Adjusted for sex.</p></fn>
            </table-wrap-foot>
          </table-wrap>
          <p>The table shows the adjusted estimates.</p>
        </sec>
        <sec><title>Discussion</title><p>These findings suggest a link.</p></sec>
        """)

        XCTAssertEqual(
            article.bodySections.map(\.paragraphs),
            [["The table shows the adjusted estimates."], ["These findings suggest a link."]],
            "prose after a footnoted table was swallowed by the footnote branch"
        )
    }

    /// A `<table-wrap>` nested inside another one used to strand the footnote
    /// counter above zero: the inner `</table-wrap>` cleared `inTableWrap`, so the
    /// enclosing `</fn>` skipped its decrement and every remaining paragraph in the
    /// article drained into the footnote branch and was dropped. Asking the element
    /// stack instead — which still knows the outer `<table-wrap>` is open — unwinds
    /// it correctly.
    ///
    /// The outer *table* is still lost here (a single `currentTable` slot, #173);
    /// what this pins is that the loss stays inside the table and does not take the
    /// article's prose with it.
    func testANestedTableWrapDoesNotSwallowTheRestOfTheArticle() throws {
        let article = try article(body: """
        <sec>
          <title>Methods</title>
          <table-wrap id="tblOuter">
            <label>Table 1.</label>
            <table><tbody><tr><td>outer</td></tr></tbody></table>
            <table-wrap-foot>
              <fn id="fn1"><label>a</label>
                <table-wrap id="tblInner">
                  <label>Table 1a.</label>
                  <table><tbody><tr><td>inner</td></tr></tbody></table>
                </table-wrap>
                <p>Outer footnote prose.</p>
              </fn>
            </table-wrap-foot>
          </table-wrap>
        </sec>
        <sec><title>Results</title><p>Real article prose.</p></sec>
        <sec><title>Discussion</title><p>Discussion prose.</p></sec>
        """)

        XCTAssertEqual(
            article.bodySections.map(\.paragraphs),
            [[], ["Real article prose."], ["Discussion prose."]],
            "a nested table stranded the footnote counter and ate the rest of the body"
        )
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
