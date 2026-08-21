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

/// Tests for `<caption>` hosts other than `<fig>` and `<table-wrap>`.
///
/// The first caption fix routed on `inFigure || inTableWrap` and consulted the
/// caption only inside that branch, so every other element JATS allows a
/// `<caption>` on still renamed the enclosing `<sec>` and spilled its prose into
/// the article text. Measured over 386 recent open-access PMC articles that was
/// 86 of them (22.3%): 258 `<supplementary-material>` captions, 144 `<media>`,
/// 15 `<boxed-text>` and 2 `<fig-group>`. `<supplementary-material><caption>` is
/// on essentially every PLOS article.
final class JATSCaptionHostTests: XCTestCase {

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

    // MARK: - Supplementary material (the PLOS shape)

    func testSupplementaryMaterialCaptionDoesNotRenameEnclosingSection() throws {
        let article = try parse(body: """
        <sec>
          <title>Supporting information</title>
          <p>Real section prose.</p>
          <supplementary-material id="pone.s001">
            <caption><title>S1 File.</title><p>Inclusion and exclusion criteria.</p></caption>
          </supplementary-material>
        </sec>
        """)

        XCTAssertEqual(article.bodySections.count, 1)
        XCTAssertEqual(article.bodySections[0].title, "Supporting information")
    }

    func testSupplementaryMaterialCaptionProseStaysOutOfSectionParagraphs() throws {
        let article = try parse(body: """
        <sec>
          <title>Supporting information</title>
          <p>Real section prose.</p>
          <supplementary-material id="pone.s001">
            <caption><title>S1 File.</title><p>Supplementary methods and tables.</p></caption>
          </supplementary-material>
        </sec>
        """)

        XCTAssertEqual(article.bodySections[0].paragraphs, ["Real section prose."])
    }

    // MARK: - Boxed text and media

    func testBoxedTextCaptionDoesNotRenameEnclosingSection() throws {
        let article = try parse(body: """
        <sec>
          <title>Discussion</title>
          <p>Real section prose.</p>
          <boxed-text>
            <caption><title>Box 1.</title><p>Boxed caption prose.</p></caption>
          </boxed-text>
        </sec>
        """)

        XCTAssertEqual(article.bodySections[0].title, "Discussion")
        XCTAssertEqual(article.bodySections[0].paragraphs, ["Real section prose."])
    }

    /// A `<media>` inside a `<fig>` carries its own caption. `inFigure` is still
    /// set for the enclosing figure, so reading the ambient flags concatenated the
    /// video legend onto the figure's caption.
    func testMediaCaptionInsideAFigureDoesNotJoinTheFigureCaption() throws {
        let article = try parse(body: """
        <sec>
          <title>Results</title>
          <fig id="f1"><label>Figure 1</label>
            <caption><title>Study flow diagram.</title></caption>
            <media id="m1">
              <caption><p>Video S1 legend.</p></caption>
            </media>
          </fig>
        </sec>
        """)

        XCTAssertEqual(article.figures.count, 1)
        XCTAssertEqual(article.figures[0].caption, "Study flow diagram.")
        XCTAssertFalse(article.figures[0].caption.contains("Video S1"))
    }

    /// A caption host directly under `<body>` must not open an implicit section
    /// either: the unsectioned-prose recovery would otherwise turn the caption
    /// into article text rather than merely misfiling it.
    func testUnmodelledCaptionUnderBodyDoesNotOpenAnImplicitSection() throws {
        let article = try parse(body: """
        <supplementary-material id="pone.s001">
          <caption><title>S1 File.</title><p>(PDF)</p></caption>
        </supplementary-material>
        """)

        XCTAssertTrue(article.bodySections.isEmpty)
    }

    // MARK: - The modelled hosts still work

    func testFigureAndTableCaptionsAreStillCaptured() throws {
        let article = try parse(body: """
        <sec>
          <title>Results</title>
          <fig id="f1"><caption><title>Figure caption.</title></caption></fig>
          <table-wrap id="t1"><caption><title>Table caption.</title></caption></table-wrap>
        </sec>
        """)

        XCTAssertEqual(article.figures.first?.caption, "Figure caption.")
        XCTAssertEqual(article.tables.first?.caption, "Table caption.")
        XCTAssertEqual(article.bodySections[0].title, "Results")
    }
}
