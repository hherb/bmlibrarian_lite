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
    /// 27 of the 225 articles (12.0%) in the survey behind
    /// `doc/cross_platform/jats_corpus/` carry a labelled `<table-wrap-foot><fn>`.
    /// `figureFootnoteDepth` was already tracked and already consulted by the
    /// `"p"` case in `didEndElement`; the `"label"` case never got the guard.
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
    /// where abbreviation expansions and per-table funding notes live.
    func testTheFootnoteProseIsStillCaptured() throws {
        let article = try parse(body: tableWithFootnote(
            #"<fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(
            article.tables.first?.footnotes, ["a — AI: artificial intelligence."],
            "the footnote lost the marker its cell text still points at"
        )
    }

    /// Keeping the marker out of the table's `<label>` must not mean parking it on
    /// the table's caption instead.
    func testTheFootnoteMarkerDoesNotReachTheCaption() throws {
        let article = try parse(body: tableWithFootnote(
            #"<fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(article.tables.first?.caption, "Commonly asked questions.")
    }

    /// The marker is not decoration. `<sup>` is an inline element the parser
    /// flattens into the surrounding cell, so the rendered table body still reads
    /// `12.3a` — and with two footnotes and no markers, nothing says which of them
    /// `a` is. `PMC12661592` deposits exactly this shape.
    func testTheMarkerSurvivesSoCellTextStillResolves() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <table-wrap position="float" id="T1">
                <label>Table 1.</label>
                <table><tbody>
                  <tr><td>Drug</td><td>12.3<xref rid="T1_FN1" ref-type="table-fn"><sup>a</sup></xref></td></tr>
                  <tr><td>Placebo</td><td>4.5<xref rid="T1_FN2" ref-type="table-fn"><sup>b</sup></xref></td></tr>
                </tbody></table>
                <table-wrap-foot>
                  <fn id="T1_FN1"><label>a</label><p>Adjusted for age.</p></fn>
                  <fn id="T1_FN2"><label>b</label><p>Unadjusted.</p></fn>
                </table-wrap-foot>
              </table-wrap>
            </sec>
            """)

        XCTAssertEqual(
            article.tables.first?.footnotes,
            ["a — Adjusted for age.", "b — Unadjusted."],
            "the cells read 12.3a and 4.5b, so the footnotes must say which is which"
        )
    }

    /// A `<fn>` that deposits a marker and no prose has nothing to attach it to.
    /// The marker must not survive to prefix the *next* footnote.
    func testAMarkerWithoutProseDoesNotLeakOntoTheNextFootnote() throws {
        let article = try parse(body: tableWithFootnote("""
            <fn id="T1_FN1"><label>a</label></fn>
            <fn id="T1_FN2"><label>b</label><p>CI: confidence interval.</p></fn>
            """))

        XCTAssertEqual(article.tables.first?.footnotes, ["b — CI: confidence interval."])
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
            ["a — AI: artificial intelligence.", "b — CI: confidence interval."]
        )
    }

    /// With no `<label>` of its own the table has nothing for the marker to
    /// overwrite, which is the one shape that tells the depth guard apart from
    /// plain first-write-wins: that weaker rule reports "a" here, and reported it
    /// before #157 too.
    func testAnUnlabelledTableDoesNotBorrowItsFootnoteMarker() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <table-wrap position="float" id="T1">
                <caption><title>Commonly asked questions.</title></caption>
                <table><tbody><tr><td>Why?</td><td>Because.</td></tr></tbody></table>
                <table-wrap-foot>
                  <fn id="T1_FN1"><label>a</label><p>AI: artificial intelligence.</p></fn>
                </table-wrap-foot>
              </table-wrap>
            </sec>
            """)

        XCTAssertEqual(
            article.tables.first?.label, "",
            "an unlabelled table took its footnote's marker as its own label"
        )
        XCTAssertEqual(article.tables.first?.footnotes, ["a — AI: artificial intelligence."])
    }

    /// The figure twin of the case above.
    func testAnUnlabelledFigureDoesNotBorrowItsFootnoteMarker() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <fig id="F1">
                <caption><title>Survival by arm.</title></caption>
                <graphic xlink:href="fig1.jpg"/>
                <fn id="F1_FN1"><label>*</label><p>p &lt; 0.05.</p></fn>
              </fig>
            </sec>
            """)

        XCTAssertEqual(article.figures.first?.label, "")
        XCTAssertEqual(article.figures.first?.footnotes, ["* — p < 0.05."])
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
        XCTAssertEqual(article.figures.first?.footnotes, ["* — p < 0.05."])
    }

    /// JATS lets an exhibit open *inside* somebody's footnote, and a guard that
    /// compares the footnote depth against zero cannot tell that exhibit's own
    /// `<label>` from a marker — so it ate it. An empty label is not inert: the
    /// renderer substitutes `"Figure \(index + 1)"`, turning "Figure 9." into a
    /// plausible, invented "Figure 2".
    func testAFigureOpenedInsideATableFootnoteKeepsItsOwnLabel() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <table-wrap position="float" id="T1">
                <label>Table 1.</label>
                <table><tbody><tr><td>Why?</td><td>Because.</td></tr></tbody></table>
                <table-wrap-foot>
                  <fn id="T1_FN1"><label>a</label><p>See the figure.</p>
                    <fig id="F9"><label>Figure 9.</label><graphic xlink:href="f9.jpg"/></fig>
                  </fn>
                </table-wrap-foot>
              </table-wrap>
            </sec>
            """)

        XCTAssertEqual(
            article.figures.first?.label, "Figure 9.",
            "a figure inside a table footnote lost its own label to the depth guard"
        )
        XCTAssertEqual(article.tables.first?.label, "Table 1.")
    }

    /// The same hole one element over, and this one sits on the eLife supplement
    /// path the nesting fix exists to serve.
    func testAFigureOpenedInsideAFigureFootnoteKeepsItsOwnLabel() throws {
        let article = try parse(body: """
            <sec>
              <title>Results</title>
              <fig id="F1">
                <label>Figure 1.</label>
                <graphic xlink:href="f1.jpg"/>
                <fn id="F1_FN1"><label>*</label><p>p &lt; 0.05.</p>
                  <fig id="F1S1">
                    <label>Figure 1—figure supplement 1.</label>
                    <graphic xlink:href="s1.jpg"/>
                  </fig>
                </fn>
              </fig>
            </sec>
            """)

        XCTAssertEqual(
            article.figures.map(\.label),
            ["Figure 1.", "Figure 1—figure supplement 1."],
            "the nested figure lost its own label to the depth guard"
        )
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

    // MARK: - <label> belongs to the exhibit that encloses it most closely (#169)

    /// `<fig>` and `<table-wrap>` can be open at the same time, and the branch
    /// asked `inFigure` first, so the figure took every `<label>` in reach —
    /// including the table's own. `PMC13295835` nests a `<media>` in a `<fig>`,
    /// so an exhibit inside an exhibit is not a contrived shape.
    private func tableInsideFigure(footnote: String = "") -> String {
        """
        <sec>
          <title>Results</title>
          <fig id="f1">
            <label>Figure 1.</label>
            <graphic xlink:href="f1.jpg"/>
            <table-wrap id="t1">
              <label>Table 1.</label>
              <table><tbody><tr><td>12.3a</td></tr></tbody></table>
              \(footnote.isEmpty ? "" : "<table-wrap-foot>\(footnote)</table-wrap-foot>")
            </table-wrap>
          </fig>
        </sec>
        """
    }

    func testATableInsideAFigureKeepsItsOwnLabel() throws {
        let article = try parse(body: tableInsideFigure())

        XCTAssertEqual(
            article.tables.first?.label, "Table 1.",
            "the enclosing figure took the table's label"
        )
    }

    func testTheFigureAroundATableKeepsItsOwnLabelToo() throws {
        let article = try parse(body: tableInsideFigure())

        XCTAssertEqual(
            article.figures.first?.label, "Figure 1.",
            "the nested table's label was written over the figure's"
        )
    }

    /// The footnote marker routes through the same first-`inFigure`-wins chain,
    /// one layer down: `<table-wrap-foot>` belongs to the table it hangs off,
    /// whatever encloses that table.
    func testATableFootnoteMarkerStaysWithTheTableInsideAFigure() throws {
        let article = try parse(body: tableInsideFigure(
            footnote: #"<fn id="t1fn1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(
            article.tables.first?.footnotes, ["a — AI: artificial intelligence."],
            "the table's footnote was filed under the enclosing figure"
        )
    }

    func testAFigureAroundAFootnotedTableCollectsNoFootnotes() throws {
        let article = try parse(body: tableInsideFigure(
            footnote: #"<fn id="t1fn1"><label>a</label><p>AI: artificial intelligence.</p></fn>"#
        ))

        XCTAssertEqual(
            article.figures.first?.footnotes, [],
            "the figure collected the nested table's footnote"
        )
    }

    /// `<supplementary-material>` is the other thing eLife nests inside a `<fig>`,
    /// and it carries a label of its own: 14 occur in the committed corpus, none
    /// of them inside an exhibit, so this is the shape that was one deposit away
    /// from silently renaming a figure. The parser has no model for the
    /// supplement itself (#144); the point here is only that the figure keeps its
    /// own number.
    func testASupplementaryMaterialLabelInsideAFigureIsNotTheFiguresLabel() throws {
        let article = try parse(body: """
        <sec>
          <title>Results</title>
          <fig id="f1">
            <label>Figure 1.</label>
            <graphic xlink:href="f1.jpg"/>
            <supplementary-material id="f1sd1">
              <label>Figure 1—source data 1.</label>
              <media xlink:href="elife-f1-data1.xlsx"/>
            </supplementary-material>
          </fig>
        </sec>
        """)

        XCTAssertEqual(article.figures.first?.label, "Figure 1.")
    }

    /// The reverse nesting is the shape #156 exists to serve, so the label must
    /// keep travelling in the other direction too.
    func testAFigureInsideATableKeepsItsOwnLabel() throws {
        let article = try parse(body: """
        <sec>
          <title>Results</title>
          <table-wrap id="t1">
            <label>Table 1.</label>
            <table><tbody><tr><td>See below</td></tr></tbody></table>
            <table-wrap-foot>
              <fig id="f9"><label>Figure 9.</label><graphic xlink:href="f9.jpg"/></fig>
            </table-wrap-foot>
          </table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.figures.first?.label, "Figure 9.")
        XCTAssertEqual(article.tables.first?.label, "Table 1.")
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
    /// Of the 959 figures in the 225-article survey that carry a `<graphic>` at
    /// all, 507 (52.9%) end on a thumbnail. A `hasGraphic` boolean hid this
    /// completely — it was `true` either way.
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

    /// `specific-use="thumbnail"` is the other publisher convention for the same
    /// thing. Both attributes are open-valued in JATS, which defines no
    /// vocabulary for either, and no deposit in the corpus uses this one — it is
    /// covered here and nowhere else. Deposited last, as `content-type="thumb"`
    /// is, so the assertion fails under last-write-wins rather than passing on
    /// position.
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

    /// Most publishers type no graphic at all — all 12 eLife figures, and every
    /// SAGE, MDPI and BMJ figure in the corpus. With nothing to choose on, the
    /// first is the one the article leads with.
    func testUntypedGraphicsResolveTheFirst() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1-panel-a.jpg"/>
                <graphic xlink:href="fig1-panel-b.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1-panel-a.jpg")
    }

    /// Two thumbnails and nothing else: the first still wins. Ranking accepts a
    /// deposit only when it is *strictly* better, and a rule that accepted an
    /// equal one would swap in the last thumbnail here — the #161 shape again,
    /// one tier down.
    func testASecondThumbnailDoesNotDisplaceTheFirst() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="thumb" xlink:href="fig1-thumb-a.gif"/>
                <graphic content-type="thumb" xlink:href="fig1-thumb-b.gif"/>
            """))

        XCTAssertEqual(
            article.figures.first?.graphicURL, "fig1-thumb-a.gif",
            "an equally-ranked deposit displaced the one already held"
        )
    }

    /// Thumbnail, then image, then image. Once the thumbnail has been given up
    /// the figure is holding a full image, and the third deposit must not
    /// displace it — the case that catches a "have I seen a thumbnail?" flag
    /// that is set but never cleared.
    func testAThirdGraphicDoesNotDisplaceThePromotedImage() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="thumb" xlink:href="fig1-thumb.gif"/>
                <graphic xlink:href="fig1-a.jpg"/>
                <graphic xlink:href="fig1-b.jpg"/>
            """))

        XCTAssertEqual(
            article.figures.first?.graphicURL, "fig1-a.jpg",
            "the figure gave up a full image it had already accepted"
        )
    }

    /// Neither attribute is case-controlled, so both are lowercased before the
    /// substring test. Every corpus deposit is lowercase, which leaves the
    /// lowercasing unexercised unless a test spells it otherwise — and the
    /// thumbnail has to come first, or first-wins resolves the image regardless.
    func testAnUppercaseContentTypeIsStillAThumbnail() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic content-type="THUMB" xlink:href="fig1-thumb.gif"/>
                <graphic xlink:href="fig1.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.jpg")
    }

    /// The `specific-use` half of the same claim.
    func testAMixedCaseSpecificUseIsStillAThumbnail() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic specific-use="Thumbnail" xlink:href="fig1-thumb.gif"/>
                <graphic xlink:href="fig1.jpg"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.jpg")
    }

    /// A thumbnail is recognised by what the deposit says, never by the file
    /// extension. PLOS and Springer both happen to deposit `.gif` thumbnails, so
    /// every corpus thumbnail is a `.gif` and a parser that keyed on the suffix
    /// would pass the corpus — and then discard the only image a figure has
    /// wherever `.gif` is the image itself.
    func testAGifIsNotAThumbnailByVirtueOfBeingAGif() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1.gif"/>
                <graphic xlink:href="fig1-alt.jpg"/>
            """))

        XCTAssertEqual(
            article.figures.first?.graphicURL, "fig1.gif",
            "an untyped .gif was taken for a thumbnail on its extension alone"
        )
    }

    /// `<alternatives>` deposits the archival master *first* and the web
    /// derivative second — the opposite order to a thumbnail pair. Choosing the
    /// first non-thumbnail therefore picked a TIFF no WebKit view can render,
    /// where the older last-wins rule had happened to pick the JPEG. Rank rather
    /// than position settles both conventions at once.
    func testAnArchivalMasterLosesToTheWebDerivative() throws {
        let article = try parse(body: figureWithGraphics("""
                <alternatives>
                  <graphic xlink:href="fig1.tif" mimetype="image" mime-subtype="tiff"/>
                  <graphic xlink:href="fig1.jpg" mimetype="image" mime-subtype="jpeg"/>
                </alternatives>
            """))

        XCTAssertEqual(
            article.figures.first?.graphicURL, "fig1.jpg",
            "the figure resolved to an archival master the renderer cannot display"
        )
    }

    /// The same pair the other way round, so the rule is order-independent here
    /// too rather than merely preferring the last deposit again.
    func testTheWebDerivativeSurvivesAFollowingArchivalMaster() throws {
        let article = try parse(body: figureWithGraphics("""
                <alternatives>
                  <graphic xlink:href="fig1.jpg" mimetype="image" mime-subtype="jpeg"/>
                  <graphic xlink:href="fig1.tif" mimetype="image" mime-subtype="tiff"/>
                </alternatives>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.jpg")
    }

    /// An archival master is still better than nothing, the way a thumbnail is.
    func testAFigureWithOnlyAnArchivalMasterStillResolvesIt() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1.tif" mimetype="image" mime-subtype="tiff"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1.tif")
    }

    /// And a thumbnail that renders beats an archival master that does not,
    /// whichever order they arrive in.
    func testAThumbnailBeatsAnArchivalMaster() throws {
        let article = try parse(body: figureWithGraphics("""
                <graphic xlink:href="fig1.tif" mimetype="image" mime-subtype="tiff"/>
                <graphic content-type="thumb" xlink:href="fig1-thumb.gif"/>
            """))

        XCTAssertEqual(article.figures.first?.graphicURL, "fig1-thumb.gif")
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
