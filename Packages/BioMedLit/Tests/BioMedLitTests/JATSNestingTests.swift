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

/// Tests for parser state that must be saved and restored rather than cleared.
///
/// JATS nests. Every flag the parser clears on an end tag is a latent bug if the
/// element it belongs to can contain another of its own kind: the inner close
/// wipes the outer one's state and the remainder of the outer element is then
/// read under the wrong rules. `subArticleDepth` was written as a counter for
/// exactly this reason; these tests hold the rest of the state to the same
/// standard.
final class JATSNestingTests: XCTestCase {

    // MARK: - Helpers

    private func parse(_ inner: String) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <title-group><article-title>Real article</article-title></title-group>
        \(inner)
            </article-meta>
          </front>
          <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()
    }

    // MARK: - Nested <contrib-group>

    /// JATS permits a `<contrib-group>` inside `<collab>` for consortium
    /// authorship. Clearing the group type on the inner `</contrib-group>` left
    /// the outer group typeless, and a bare `<contrib>` with no type is read as an
    /// author — so the editors the group type excludes were admitted.
    func testNestedContribGroupDoesNotLeakEditorsAsAuthors() throws {
        let article = try parse("""
            <contrib-group content-type="editor">
              <contrib><name><surname>FirstEditor</surname><given-names>A</given-names></name></contrib>
              <contrib>
                <collab>The Study Group
                  <contrib-group content-type="author">
                    <contrib><name><surname>Inner</surname><given-names>B</given-names></name></contrib>
                  </contrib-group>
                </collab>
              </contrib>
              <contrib><name><surname>SecondEditor</surname><given-names>C</given-names></name></contrib>
            </contrib-group>
        """)

        let surnames = article.authors.map(\.surname)
        XCTAssertFalse(surnames.contains("FirstEditor"))
        XCTAssertFalse(surnames.contains("SecondEditor"),
                       "the trailing editor was admitted after the inner group cleared the type")
    }

    /// The ordinary PLOS shape must keep working: role declared once on the group.
    func testBareContribInheritsItsAuthorGroup() throws {
        let article = try parse("""
            <contrib-group content-type="author">
              <contrib><name><surname>Real</surname><given-names>A</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Real"])
    }

    /// An explicit `contrib-type` still decides on its own, so an editor sitting
    /// inside an author group stays out.
    func testExplicitContribTypeStillOverridesTheGroup() throws {
        let article = try parse("""
            <contrib-group content-type="author">
              <contrib contrib-type="author"><name><surname>Real</surname><given-names>A</given-names></name></contrib>
              <contrib contrib-type="editor"><name><surname>Editor</surname><given-names>B</given-names></name></contrib>
            </contrib-group>
        """)

        XCTAssertEqual(article.authors.map(\.surname), ["Real"])
    }

    // MARK: - Nested <sub-article>

    /// eLife and PLOS nest the author reply inside the decision-letter
    /// sub-article. A flag would be cleared by the inner `</sub-article>` and let
    /// the tail of the outer one back in; a depth counter does not.
    ///
    /// The tail must contain a `<sec>`, and that is the whole point of the
    /// fixture. Loose `<p>` after the inner close is dropped for an unrelated
    /// reason — the real article's `</body>` already cleared `inBody` — so a
    /// prose-only tail passes under a 0/1 flag and this test claimed a guard it
    /// did not provide. Verified: with `subArticleDepth` reduced to a flag, the
    /// `<sec>` leaks in and this is the test that says so.
    ///
    /// Synthetic on purpose: nested `<sub-article>` did not occur in any of the
    /// 225 real articles surveyed for the corpus in
    /// `doc/cross_platform/jats_corpus/`, so no real fixture can cover it.
    func testNestedSubArticleTailIsStillExcluded() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <article-id pub-id-type="pmc">PMC1234567</article-id>
            <title-group><article-title>Real article</article-title></title-group>
          </article-meta></front>
          <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
          <sub-article article-type="reviewer-report">
            <front-stub><title-group><article-title>Decision letter</article-title></title-group></front-stub>
            <body>
              <p>Outer reviewer prose before the reply.</p>
              <sub-article article-type="author-comment">
                <body><p>Inner author reply prose.</p></body>
              </sub-article>
              <p>Outer reviewer prose after the reply.</p>
              <sec><title>Reviewer 2</title><p>Outer reviewer section after the reply.</p></sec>
            </body>
          </sub-article>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.title, "Real article")
        XCTAssertEqual(
            article.bodySections.map(\.title), ["Methods"],
            """
            the outer <sub-article> resumed after its nested one closed, so its \
            remaining sections leaked into the article body. This is what makes \
            subArticleDepth a counter rather than a flag.
            """
        )
        let allProse = article.bodySections.flatMap(\.paragraphs)
        XCTAssertEqual(allProse, ["Real prose."])
        XCTAssertFalse(allProse.contains { $0.contains("reviewer prose") })
        XCTAssertFalse(allProse.contains { $0.contains("author reply") })
    }

    /// `<response>` is the other element that carries a whole article of its own.
    func testResponseContentIsExcluded() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <article-id pub-id-type="pmc">PMC1234567</article-id>
            <title-group><article-title>Real article</article-title></title-group>
          </article-meta></front>
          <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
          <response>
            <front-stub><title-group><article-title>Author response</article-title></title-group></front-stub>
            <body><p>Response prose.</p></body>
          </response>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.title, "Real article")
        XCTAssertEqual(article.bodySections.flatMap(\.paragraphs), ["Real prose."])
    }

    // MARK: - Nested <caption>

    /// A caption owner is a stack for the same reason: a captioned element may
    /// sit inside a caption, and popping to "no caption" on the inner close would
    /// send the rest of the outer caption to the enclosing section.
    func testCaptionInsideACaptionRestoresTheOuterOwner() throws {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <article-id pub-id-type="pmc">PMC1234567</article-id>
            <title-group><article-title>T</article-title></title-group>
          </article-meta></front>
          <body>
            <sec>
              <title>Results</title>
              <fig id="f1">
                <caption>
                  <title>Outer figure caption.</title>
                  <media id="m1"><caption><p>Inner media legend.</p></caption></media>
                  <p>Outer caption tail.</p>
                </caption>
              </fig>
            </sec>
          </body>
        </article>
        """
        let article = try JATSXMLParser(data: Data(xml.utf8)).parseToArticle()

        XCTAssertEqual(article.bodySections[0].title, "Results")
        XCTAssertEqual(article.bodySections[0].paragraphs, [])
        XCTAssertEqual(article.figures.first?.caption, "Outer figure caption. Outer caption tail.")
    }
}
