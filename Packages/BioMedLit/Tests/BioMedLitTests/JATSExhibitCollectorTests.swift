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

/// Tests for the type that owns exhibit ordering, and for the `<table-wrap>`
/// nesting that used to lose the outer table (#170, #173).
///
/// `<fig>` got a stack in #156; `<table-wrap>` kept a single slot, so the two
/// halves of the same question had two different answers. `ExhibitCollector`
/// holds the ordering rule once, for both.
final class JATSExhibitCollectorTests: XCTestCase {

    // MARK: - Ordering (#170)

    /// Identify the collected figures by the ids their builders carried.
    private func ids(_ collector: ExhibitCollector<FigureBuilder>) -> [String] {
        collector.completed.map(\.id)
    }

    private func opened(_ id: String) -> FigureBuilder {
        var builder = FigureBuilder()
        builder.id = id
        return builder
    }

    func testAnExhibitIsListedOnceItCloses() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("a"))

        XCTAssertEqual(ids(collector), [], "listed before its end tag arrived")

        collector.end()

        XCTAssertEqual(ids(collector), ["a"])
    }

    /// The reason the collector exists rather than a plain array: an exhibit is
    /// *built* at its end tag but has to be *listed* at its start, so appending
    /// on close puts every eLife figure supplement ahead of the figure it
    /// belongs to (#156).
    func testANestedExhibitIsListedAfterTheOneContainingIt() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("parent"))
        collector.begin(opened("supplement"))
        collector.end()
        collector.end()

        XCTAssertEqual(ids(collector), ["parent", "supplement"])
    }

    func testSiblingsKeepTheOrderTheyOpenedIn() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("parent"))
        collector.begin(opened("first"))
        collector.end()
        collector.begin(opened("second"))
        collector.end()
        collector.end()

        XCTAssertEqual(ids(collector), ["parent", "first", "second"])
    }

    func testThreeDeepNestingIsListedOutermostFirst() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("outer"))
        collector.begin(opened("middle"))
        collector.begin(opened("inner"))
        collector.end()
        collector.end()
        collector.end()

        XCTAssertEqual(ids(collector), ["outer", "middle", "inner"])
    }

    func testUnrelatedExhibitsKeepDocumentOrder() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("first"))
        collector.begin(opened("first-child"))
        collector.end()
        collector.end()
        collector.begin(opened("second"))
        collector.end()

        XCTAssertEqual(ids(collector), ["first", "first-child", "second"])
    }

    // MARK: - Addressing the open exhibit

    func testWithCurrentAddressesTheInnermostOpenExhibit() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("parent"))
        collector.begin(opened("child"))

        XCTAssertTrue(collector.withCurrent { $0.label = "Figure 1—figure supplement 1." })

        collector.end()
        collector.end()

        XCTAssertEqual(collector.completed.map(\.label), ["", "Figure 1—figure supplement 1."])
    }

    /// The parent becomes addressable again when its child closes — the half of
    /// #156 a single slot could not express.
    func testTheParentIsCurrentAgainOnceItsChildCloses() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("parent"))
        collector.begin(opened("child"))
        collector.end()

        XCTAssertTrue(collector.withCurrent { $0.label = "Figure 1." })

        collector.end()

        XCTAssertEqual(collector.completed.map(\.label), ["Figure 1.", ""])
    }

    /// Reported rather than absorbed: the callers route on the element stack and
    /// write here, so a disagreement between the two is a parser defect and the
    /// symptom is content quietly going missing.
    func testWithCurrentSaysSoWhenNothingIsOpen() {
        var collector = ExhibitCollector<FigureBuilder>()
        var ran = false

        XCTAssertFalse(collector.withCurrent { _ in ran = true })
        XCTAssertFalse(ran)
    }

    /// `end()`'s twin of the above. Answering one impossible condition with a
    /// diagnostic and the other with silence is how the quieter one ends up being
    /// the one that loses more — this end drops a whole exhibit, not one write.
    func testEndSaysSoWhenNothingIsOpen() {
        var collector = ExhibitCollector<FigureBuilder>()

        XCTAssertFalse(collector.end())
        XCTAssertEqual(ids(collector), [])
        XCTAssertEqual(collector.openCount, 0)
    }

    /// And says nothing when there was something to close, or the caller's log
    /// would fire on every well-formed exhibit in the document.
    func testEndSaysNothingWhenAnExhibitWasOpen() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("a"))

        XCTAssertTrue(collector.end())
    }

    // MARK: - What is still open

    func testOpenCountReportsTheExhibitsThatNeverClosed() {
        var collector = ExhibitCollector<FigureBuilder>()
        XCTAssertEqual(collector.openCount, 0)
        XCTAssertFalse(collector.isOpen)

        collector.begin(opened("outer"))
        collector.begin(opened("inner"))

        XCTAssertEqual(collector.openCount, 2)
        XCTAssertTrue(collector.isOpen)

        collector.end()

        XCTAssertEqual(collector.openCount, 1)
        XCTAssertTrue(collector.isOpen)
    }

    /// "Reserved but still open" and "opened and never closed" were the same
    /// `nil` in the array the collector replaces, and `compactMap` is the
    /// canonical silent-drop idiom. An unclosed exhibit now simply stays on the
    /// stack, where the unwind audit can see it (#175).
    func testAnUnclosedExhibitIsNotListedAndIsStillCounted() {
        var collector = ExhibitCollector<FigureBuilder>()
        collector.begin(opened("closed"))
        collector.end()
        collector.begin(opened("never closed"))

        XCTAssertEqual(ids(collector), ["closed"])
        XCTAssertEqual(collector.openCount, 1)
    }

    /// The same type serves tables, which is the point of it being generic:
    /// `<table-wrap>` nests too, and kept a single slot until #173 was fixed.
    func testTheCollectorServesTablesToo() {
        var collector = ExhibitCollector<TableBuilder>()
        var outer = TableBuilder()
        outer.id = "tblOuter"
        var inner = TableBuilder()
        inner.id = "tblInner"

        collector.begin(outer)
        collector.begin(inner)
        collector.end()
        collector.end()

        XCTAssertEqual(collector.completed.map(\.id), ["tblOuter", "tblInner"])
    }

    // MARK: - A nested <table-wrap> keeps the outer table (#173)

    /// The shape from #173, which two reviewers found independently: `%fn-model`
    /// admits `<table-wrap>`, so a table can open inside another table's
    /// footnote. Zero corpus articles nest one, so the digests cannot catch a
    /// regression here and this fixture is the only guard.
    ///
    /// The inner cell holds a `<p>` rather than bare text on purpose. Bare text
    /// never reaches the `<p>` routing branch, so it sidesteps the second half of
    /// #173 entirely — and `<td><p>` is what publishers actually deposit
    /// (PMC13294358 uses it for 41 of its 61 cells).
    private static let nestedTables = """
    <sec>
      <title>Methods</title>
      <table-wrap id="tblOuter">
        <label>Table 1.</label>
        <caption><title>Baseline characteristics.</title></caption>
        <table><tbody><tr><td>outer cell</td></tr></tbody></table>
        <table-wrap-foot>
          <fn id="fn1"><label>a</label>
            <table-wrap id="tblInner">
              <label>Table 1a.</label>
              <table><tbody><tr><td><p>inner cell</p></td></tr></tbody></table>
            </table-wrap>
            <p>Outer footnote prose.</p>
          </fn>
        </table-wrap-foot>
      </table-wrap>
    </sec>
    """

    private func parse(body: String) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <title-group><article-title>T</article-title></title-group>
              <contrib-group><contrib contrib-type="author">
                <name><surname>Doe</surname><given-names>J</given-names></name>
              </contrib></contrib-group>
            </article-meta>
          </front>
          <body>
        \(body)
          </body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
    }

    /// `case "table-wrap"` overwrote `currentTable`, so Table 1 — its label, its
    /// caption and every cell — was gone the instant the inner one opened, with
    /// no log.
    func testANestedTableWrapKeepsTheOuterTable() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(
            article.tables.map(\.id), ["tblOuter", "tblInner"],
            "the inner <table-wrap> displaced the table containing it"
        )
    }

    func testTheOuterTableKeepsItsLabel() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(article.tables.first?.label, "Table 1.")
    }

    func testTheOuterTableKeepsItsCaption() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(article.tables.first?.caption, "Baseline characteristics.")
    }

    func testTheOuterTableKeepsItsCells() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertTrue(
            article.tables.first?.markdownContent.contains("outer cell") ?? false,
            "outer table rendered as: \(article.tables.first?.markdownContent ?? "nothing")"
        )
    }

    /// Step 2 of #173: the inner `</table-wrap>` cleared the slot while the
    /// outer table was still open, so the outer table's own footnote prose —
    /// which arrives *after* the nested table — landed on an optional-chain
    /// no-op.
    func testTheOuterTablesFootnoteProseStillReachesIt() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(
            article.tables.first?.footnotes, ["a — Outer footnote prose."],
            "the footnote prose after the nested table was dropped"
        )
    }

    /// The inner table is a table in its own right, not a casualty of keeping
    /// the outer one.
    func testTheInnerTableIsKeptToo() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(article.tables.last?.label, "Table 1a.")
        XCTAssertTrue(
            article.tables.last?.markdownContent.contains("inner cell") ?? false,
            "inner table rendered as: \(article.tables.last?.markdownContent ?? "nothing")"
        )
    }

    /// The other half of #173, and the half a table stack alone does not fix.
    ///
    /// `exhibitFootnoteDepth` is one parser-wide counter, so while the inner
    /// table is being parsed it is still standing at the *outer* table's footnote
    /// depth. Every `<p>` in the inner table therefore took the footnote branch
    /// before reaching the exhibit-internals branch, and `appendFootnoteText`
    /// routes to the innermost exhibit — so the inner table's own cell prose was
    /// filed as the inner table's footnote, and rendered twice.
    ///
    /// `JATSContentRetentionTests.testCellParagraphsAreStillNotTreatedAsProse`
    /// already asserts exactly this for a flat table. Nesting must not suspend
    /// the rule.
    func testTheInnerTablesCellProseIsNotFiledAsItsFootnote() throws {
        let article = try parse(body: Self.nestedTables)

        XCTAssertEqual(
            article.tables.last?.footnotes, [],
            "the inner table's cells were filed under the outer table's footnote depth"
        )
    }

    /// Already true before #173 — the `</fn>` guard was fixed in #171 — and
    /// pinned here because the collector rewrites the state that guard reads.
    func testTheRestOfTheBodyIsStillThere() throws {
        let article = try parse(body: Self.nestedTables + """
        <sec><title>Results</title><p>Real article prose.</p></sec>
        """)

        XCTAssertEqual(
            article.bodySections.map(\.paragraphs),
            [[], ["Real article prose."]]
        )
    }
}
