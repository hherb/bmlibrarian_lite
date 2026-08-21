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

/// Tests for markup that belongs to a *part* of a figure or table rather than to
/// the exhibit itself.
///
/// `<label>` and `<graphic>` are both routed on ambient state — "am I inside a
/// figure?", "which figure is current?" — and neither question distinguishes the
/// exhibit from its furniture. A footnote carries a `<label>` of its own, and a
/// figure routinely carries several `<graphic>`, so the last one seen won in both
/// cases and the exhibit lost its own value (#157, #161).
///
/// This is the same family as `JATSCaptionHostTests`, which covers the third
/// member: `<caption>`, routed on `inFigure`/`inTableWrap` until it learned to
/// read its own parent instead.
final class JATSExhibitRoutingTests: XCTestCase {

    // MARK: - Helpers

    private func parse(body: String) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <title-group><article-title>T</article-title></title-group>
            </article-meta>
          </front>
          <body>
        \(body)
          </body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
    }

    /// The JMIR shape from `doc/cross_platform/jats_corpus/PMC12661592.xml`,
    /// reduced to the parts that decide the label.
    private func tableWithFootnote(_ footnote: String) -> String {
        """
        <sec>
          <title>Results</title>
          <table-wrap position="float" id="T1">
            <label>Table 1.</label>
            <caption><title>Commonly asked questions.</title></caption>
            <table>
              <thead><tr><th>Question</th><th>Answer</th></tr></thead>
              <tbody><tr><td>Why?</td><td>Because.</td></tr></tbody>
            </table>
            <table-wrap-foot>\(footnote)</table-wrap-foot>
          </table-wrap>
        </sec>
        """
    }

    // MARK: - <label> belongs to its own element (#157)

    /// A `<table-wrap-foot><fn>` carries a marker — "a", "b", "*" — as its
    /// `<label>`, and the end-tag branch routed every `<label>` on `inTableWrap`
    /// alone. The table's own number was overwritten by the marker of its last
    /// footnote, so the table lost its identity wherever it is rendered or
    /// cross-referenced.
    ///
    /// 13.2% of the tables in the 225-article survey behind
    /// `doc/cross_platform/jats_corpus/` carry a labelled footnote.
    /// `figureFootnoteDepth` was already tracked and already consulted by the
    /// `<p>` branch four lines below; the `<label>` branch never got the guard.
    func testTableFootnoteLabelDoesNotOverwriteTheTableLabel() throws {
        let article = try parse(body: tableWithFootnote(
            #"<fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(
            article.tables.first?.label, "Table 1.",
            "the footnote marker was written over the table's own label"
        )
    }

    /// The guard must not be paid for by dropping the footnote prose, which is
    /// where abbreviation expansions and per-table funding notes live — the
    /// transparency analysis reads them.
    func testTheFootnoteProseIsStillCaptured() throws {
        let article = try parse(body: tableWithFootnote(
            #"<fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(article.tables.first?.footnotes, ["AI: artificial intelligence."])
    }

    /// Several labelled footnotes are the common case, and the *last* marker was
    /// the one that won. With one footnote a passing test cannot tell "the guard
    /// works" from "the first write happened to be the table's".
    func testSeveralLabelledFootnotesStillLeaveTheTableLabelAlone() throws {
        let article = try parse(body: tableWithFootnote("""
            <fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>
            <fn id="T1_FN2"><label>b</label><p>CI: confidence interval.</p></fn>
            """))

        XCTAssertEqual(article.tables.first?.label, "Table 1.")
        XCTAssertEqual(
            article.tables.first?.footnotes,
            ["AI: artificial intelligence.", "CI: confidence interval."]
        )
    }

    /// `inFigure` has the identical hole, and JATS allows `<fn>` inside `<fig>`.
    func testFigureFootnoteLabelDoesNotOverwriteTheFigureLabel() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <fig id="F1">
                <label>Figure 1.</label>
                <caption><title>Survival by arm.</title></caption>
                <graphic xlink:href="fig1.jpg"/>
                <fn id="F1_FN1"><label>*</label><p>p &lt; 0.05.</p></fn>
              </fig>
            </sec>
            """)

        XCTAssertEqual(article.figures.first?.label, "Figure 1.")
        XCTAssertEqual(article.figures.first?.footnotes, ["p < 0.05."])
    }

    /// A `<ref>` label is routed by the same `case "label"`, so the guard must not
    /// reach it. `<fn>` outside a figure or table never raises the depth.
    func testReferenceLabelsAreUnaffected() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <article-id pub-id-type="pmc">PMC1234567</article-id>
            <title-group><article-title>T</article-title></title-group>
          </article-meta></front>
          <body><sec><title>Results</title><p>Prose.</p></sec></body>
          <back>
            <ref-list>
              <ref id="R1"><label>1.</label><element-citation><article-title>A study</article-title></element-citation></ref>
            </ref-list>
          </back>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.references.first?.label, "1.")
    }

    // MARK: - <graphic> resolution (#161)

    private func figureWithGraphics(_ graphics: String) -> String {
        """
        <sec>
          <title>Results</title>
          <fig id="F1">
            <label>Figure 1.</label>
            <caption><title>Survival by arm.</title></caption>
        \(graphics)
          </fig>
        </sec>
        """
    }

    /// The PLOS shape from `doc/cross_platform/jats_corpus/PMC12755737.xml`: the
    /// full image first, a thumbnail second. The assignment was unconditional, so
    /// the thumbnail won and every figure resolved to a `.gif` thumb.
    ///
    /// 58.0% of the 959 figures in the 225-article survey carry more than one
    /// `<graphic>`. A `hasGraphic` boolean hid this completely — it was `true`
    /// either way.
    func testImageThenThumbnailResolvesTheImage() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="image" xlink:href="pone.0338891.g001.jpg"/>
                <graphic content-type="thumb" xlink:href="pone.0338891.g001.gif"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "pone.0338891.g001.jpg")
    }

    /// The same figure with the deposit order reversed. First-wins alone would
    /// pass the corpus and still hand back a thumbnail here, so `content-type` has
    /// to be read rather than position alone.
    func testThumbnailThenImageStillResolvesTheImage() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="thumb" xlink:href="pone.0338891.g001.gif"/>
                <graphic content-type="image" xlink:href="pone.0338891.g001.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "pone.0338891.g001.jpg")
    }

    /// `specific-use="thumbnail"` is the other spelling JATS sanctions for the
    /// same thing. Deposited last, as `content-type="thumb"` is, so the assertion
    /// fails under last-write-wins rather than passing on position.
    func testThumbnailBySpecificUseIsAlsoSkipped() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1.jpg"/>
                <graphic specific-use="thumbnail" xlink:href="fig1-thumb.gif"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.jpg")
    }

    /// The same pair deposited the other way round, and the only test that reads
    /// `specific-use` at all.
    ///
    /// Both orders are needed, for each attribute: with the thumbnail last,
    /// first-wins alone already resolves the image, so a thumbnail the parser
    /// fails to *recognise* costs nothing and the test above passes with
    /// `specific-use` dropped from the predicate entirely — verified by mutation.
    /// Only a thumbnail deposited first forces the attribute to be read.
    func testThumbnailBySpecificUseDepositedFirstIsAlsoSkipped() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic specific-use="thumbnail" xlink:href="fig1-thumb.gif"/>
                <graphic xlink:href="fig1.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.jpg")
    }

    /// Most publishers type no graphic at all — 11 of the 12 eLife figures and
    /// every SAGE and MDPI figure in the corpus. With nothing to choose on, the
    /// first is the one the article leads with.
    func testUntypedGraphicsResolveTheFirst() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1-panel-a.jpg"/>
                <graphic xlink:href="fig1-panel-b.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1-panel-a.jpg")
    }

    /// A thumbnail is better than nothing: skipping thumbs must not leave a
    /// figure that has only thumbs with no graphic at all.
    func testAFigureWithOnlyAThumbnailStillResolvesIt() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="thumb" xlink:href="fig1-thumb.gif"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1-thumb.gif")
    }

    /// A figure with no `<graphic>` reports none, rather than inheriting the
    /// previous figure's.
    func testAFigureWithNoGraphicReportsNone() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <fig id="F1"><label>Figure 1.</label><graphic xlink:href="fig1.jpg"/></fig>
              <fig id="F2"><label>Figure 2.</label><caption><title>Text only.</title></caption></fig>
            </sec>
            """)

        XCTAssertEqual(article.figures.map(\.graphicURL), ["fig1.jpg", nil])
    }
}
