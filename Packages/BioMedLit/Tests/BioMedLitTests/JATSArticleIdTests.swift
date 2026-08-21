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

/// Tests for `<article-id>` classification.
///
/// A `<front>` carries several ids of different kinds, and the ones with no
/// recognised `pub-id-type` fell through to pattern matching that could
/// overwrite an id already read from a typed element. Real PMC articles hit
/// this: SAGE's `publisher-id` is the DOI with the slash replaced by an
/// underscore, and PMC emits `pmcid-ver` — the canonical id with a version
/// suffix — immediately after `pmcid`.
final class JATSArticleIdTests: XCTestCase {

    private func parse(articleMeta: String, knownPMCId: String? = nil) throws -> JATSArticle {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front>
            <article-meta>
        \(articleMeta)
              <title-group><article-title>T</article-title></title-group>
            </article-meta>
          </front>
          <body><p>Prose.</p></body>
        </article>
        """
        return try JATSXMLParser(data: Data(xml.utf8), knownPMCId: knownPMCId).parseToArticle()
    }

    // MARK: - A publisher-id must not become the DOI

    /// The exact id layout PMC serves for PMC12759138: the real DOI first, then
    /// SAGE's internal `publisher-id`, which is the same string with the slash
    /// replaced by an underscore.
    func testPublisherIdDoesNotOverwriteTheTypedDOI() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="doi">10.1177/20552076251406653</article-id>
              <article-id pub-id-type="publisher-id">10.1177_20552076251406653</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1177/20552076251406653")
    }

    /// Order must not decide: the same two ids the other way round.
    func testTypedDOIWinsEvenWhenThePublisherIdComesFirst() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="publisher-id">10.1177_20552076251406653</article-id>
              <article-id pub-id-type="doi">10.1177/20552076251406653</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1177/20552076251406653")
    }

    /// A DOI has a `10.` prefix *and* a slash. Without the shape check, any
    /// untyped id starting "10." is taken as one — which is how the underscore
    /// form got in.
    func testAnIdWithoutASlashIsNotADOI() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="publisher-id">10.1177_20552076251406653</article-id>
        """)

        XCTAssertTrue(article.doi.isEmpty, "took the publisher id as a DOI: \(article.doi)")
    }

    /// The fallback still earns its keep for a genuinely untyped DOI.
    func testAnUntypedIdWithDOIShapeIsStillTakenAsTheDOI() throws {
        let article = try parse(articleMeta: """
              <article-id>10.1234/untyped</article-id>
        """)

        XCTAssertEqual(article.doi, "10.1234/untyped")
    }

    // MARK: - The versioned PMC id must not become the canonical one

    /// PMC emits `pmcid` then `pmcid-ver` then `pmcaid`/`pmcaiid`. Only the
    /// first is the canonical id; the versioned form breaks any lookup or
    /// figure URL keyed on it.
    func testVersionedPMCIdDoesNotOverwriteTheCanonicalOne() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="pmcid">PMC12759138</article-id>
              <article-id pub-id-type="pmcid-ver">PMC12759138.1</article-id>
              <article-id pub-id-type="pmcaid">12759138</article-id>
              <article-id pub-id-type="pmcaiid">12759138</article-id>
              <article-id pub-id-type="pmid">41488273</article-id>
        """)

        XCTAssertEqual(article.pmcId, "PMC12759138")
        XCTAssertEqual(article.pmid, "41488273")
    }

    /// A caller that already knows the PMC ID must not have it replaced by a
    /// versioned id from the document.
    func testKnownPMCIdSurvivesAVersionedIdInTheDocument() throws {
        let article = try parse(
            articleMeta: """
                  <article-id pub-id-type="pmcid-ver">PMC12759138.1</article-id>
            """,
            knownPMCId: "PMC12759138"
        )

        XCTAssertEqual(article.pmcId, "PMC12759138")
    }

    /// `pmcaid` is PMC's internal numeric article id, not a PMID.
    func testPMCInternalNumericIdIsNotTakenAsThePMID() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="pmcaid">12759138</article-id>
        """)

        XCTAssertTrue(article.pmid.isEmpty, "took PMC's internal id as a PMID: \(article.pmid)")
    }

    // MARK: - The ordinary case still works

    func testTypedIdsAreRead() throws {
        let article = try parse(articleMeta: """
              <article-id pub-id-type="pmid">12345678</article-id>
              <article-id pub-id-type="pmc">PMC1234567</article-id>
              <article-id pub-id-type="doi">10.1234/test</article-id>
        """)

        XCTAssertEqual(article.pmid, "12345678")
        XCTAssertEqual(article.pmcId, "PMC1234567")
        XCTAssertEqual(article.doi, "10.1234/test")
    }
}
