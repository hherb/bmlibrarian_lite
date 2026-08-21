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

/// `<sub-article>` content must not reach the enclosing article.
///
/// JATS lets a `<sub-article>` carry a complete `<front>`/`<article-meta>` and
/// `<body>` of its own. PLOS deposits its whole peer-review history that way —
/// one sub-article per review round, each with its own DOI, title, authors and
/// prose. Without a guard, the last of each wins over the real article's.
final class JATSSubArticleTests: XCTestCase {

    /// The shape PLOS deposits: the article, then review rounds as sub-articles.
    private static let xml = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front>
        <article-meta>
          <article-id pub-id-type="pmid">41474822</article-id>
          <article-id pub-id-type="doi">10.1371/journal.pgen.1012008</article-id>
          <title-group><article-title>Polycystins and ciliary derepression</article-title></title-group>
          <contrib-group>
            <contrib contrib-type="author"><name><surname>Real</surname><given-names>Ada</given-names></name></contrib>
          </contrib-group>
          <abstract><p>The real abstract.</p></abstract>
        </article-meta>
      </front>
      <body>
        <sec><title>Introduction</title><p>Real article prose.</p></sec>
      </body>
      <sub-article article-type="decision-letter">
        <front>
          <article-meta>
            <article-id pub-id-type="doi">10.1371/journal.pgen.1012008.r001</article-id>
            <title-group><article-title>Decision Letter</article-title></title-group>
            <contrib-group>
              <contrib contrib-type="author"><name><surname>Editor</surname><given-names>Ed</given-names></name></contrib>
            </contrib-group>
            <abstract><p>Reviewer abstract.</p></abstract>
          </article-meta>
        </front>
        <body>
          <p>13 Oct 2025</p>
          <p>Dear Dr Real, your manuscript requires revision.</p>
          <sec><title>Reviewer 1</title><p>The methods are unclear.</p></sec>
        </body>
      </sub-article>
      <sub-article article-type="reply">
        <front>
          <article-meta>
            <article-id pub-id-type="doi">10.1371/journal.pgen.1012008.r006</article-id>
            <title-group><article-title>Associated Data</article-title></title-group>
          </article-meta>
        </front>
        <body><p>PGENETICS-D-25-01008R2</p></body>
      </sub-article>
    </article>
    """

    private func parse() throws -> JATSArticle {
        try JATSXMLParser(data: Data(Self.xml.utf8)).parseToArticle()
    }

    func testSubArticleDOIDoesNotOverwriteTheArticleDOI() throws {
        XCTAssertEqual(try parse().doi, "10.1371/journal.pgen.1012008")
    }

    func testSubArticleTitleDoesNotOverwriteTheArticleTitle() throws {
        XCTAssertEqual(try parse().title, "Polycystins and ciliary derepression")
    }

    func testSubArticleAuthorsAreNotAddedToTheArticleAuthors() throws {
        let authors = try parse().authors

        XCTAssertEqual(authors.count, 1)
        XCTAssertEqual(authors.first?.surname, "Real")
    }

    func testSubArticleAbstractIsNotAddedToTheArticleAbstract() throws {
        let sections = try parse().abstractSections

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections.first?.content, "The real abstract.")
    }

    /// The one my unsectioned-`<body>` change makes load-bearing: a review
    /// round's loose prose is exactly the shape that fix now keeps.
    func testSubArticleProseDoesNotBecomeBodySections() throws {
        let sections = try parse().bodySections

        XCTAssertEqual(sections.count, 1)
        XCTAssertEqual(sections[0].title, "Introduction")
        XCTAssertEqual(sections[0].paragraphs, ["Real article prose."])
    }

    /// Nor does a sub-article's *sectioned* prose, which predates that change.
    func testSubArticleSectionsDoNotBecomeBodySections() throws {
        let titles = try parse().bodySections.map(\.title)

        XCTAssertFalse(titles.contains("Reviewer 1"), "got: \(titles)")
    }

    func testTotalBodyProseIsOnlyTheArticlesOwn() throws {
        let paragraphs = try parse().bodySections.reduce(0) { $0 + $1.paragraphs.count }

        XCTAssertEqual(paragraphs, 1)
    }

    // MARK: - Nesting

    /// A `<sub-article>` inside a `<sub-article>`, with the outer one's prose
    /// continuing after the inner one closes.
    ///
    /// JATS permits the nesting — an author reply carried inside the decision
    /// letter it answers — and `subArticleDepth` is a counter rather than a flag
    /// precisely so the inner `</sub-article>` does not read as "back in the real
    /// article". Nothing pinned that: reducing the counter to a 0/1 flag passed
    /// all 91 committed JATS tests, and it passes the real-article corpus too,
    /// because nested sub-articles do not occur in the Europe PMC feed at all
    /// (0 of 225 articles surveyed; eLife's decision-letter and reply are
    /// siblings). So a synthetic case is the only thing that can hold this line,
    /// and it has to be synthetic *because* the shape is absent from the wild.
    private static let nestedXML = """
    <?xml version="1.0" encoding="UTF-8"?>
    <article>
      <front>
        <article-meta>
          <article-id pub-id-type="doi">10.1371/journal.pgen.1012008</article-id>
          <title-group><article-title>Polycystins and ciliary derepression</article-title></title-group>
        </article-meta>
      </front>
      <body>
        <sec><title>Introduction</title><p>Real article prose.</p></sec>
      </body>
      <sub-article article-type="decision-letter">
        <body>
          <p>Dear Dr Real, your manuscript requires revision.</p>
          <sub-article article-type="reply">
            <body>
              <p>We thank the reviewers for their comments.</p>
            </body>
          </sub-article>
          <p>We look forward to receiving your revision.</p>
          <sec><title>Reviewer 2</title><p>The statistics need work.</p></sec>
        </body>
      </sub-article>
    </article>
    """

    /// Parse the nested fixture.
    ///
    /// - Returns: The parsed outer article.
    /// - Throws: Whatever the parser raised.
    private func parseNested() throws -> JATSArticle {
        try JATSXMLParser(data: Data(Self.nestedXML.utf8)).parseToArticle()
    }

    /// The assertion the counter actually holds up.
    ///
    /// Only the *sectioned* form leaks under a 0/1 flag. The loose `<p>` that
    /// follows it does not, but for an unrelated reason — the real article's
    /// `</body>` has already cleared `inBody`, and stray prose outside a body is
    /// dropped anyway. So this test is written against `<sec>`, and the prose is
    /// asserted alongside it only to record that the two travel differently.
    func testASectionAfterANestedSubArticleClosesStaysOutOfTheBody() throws {
        let article = try parseNested()

        XCTAssertEqual(
            article.bodySections.map(\.title), ["Introduction"],
            """
            the outer <sub-article> resumed after its nested one closed, so its \
            remaining sections leaked into the article body. This is what makes \
            subArticleDepth a counter rather than a flag.
            """
        )
        XCTAssertEqual(
            article.bodySections.flatMap(\.paragraphs), ["Real article prose."],
            "no sub-article prose may reach the body either"
        )
    }
}
