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

/// Publication types reach the search article, and the query no longer drops
/// retracted papers silently: the `Retracted Publication` label alone retracts
/// a paper, so it must be seen rather than filtered out of sight.
final class PublicationTypeParsingTests: XCTestCase {

    private func pubMedArticles(_ body: String) -> [SearchArticle] {
        let xml = """
        <PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>1</PMID><Article>
        <Journal><Title>J</Title></Journal><ArticleTitle>T</ArticleTitle>\(body)
        </Article></MedlineCitation></PubmedArticle></PubmedArticleSet>
        """
        return PubMedXMLParser(data: Data(xml.utf8)).parseArticleSet().articles
    }

    func testPubMedKeepsPublicationTypes() {
        let articles = pubMedArticles("""
        <PublicationTypeList><PublicationType UI="D016441">Retracted Publication</PublicationType>\
        <PublicationType UI="D016428">Journal Article</PublicationType></PublicationTypeList>
        """)
        XCTAssertEqual(articles.first?.publicationTypes, ["Retracted Publication", "Journal Article"])
    }

    func testEuropePMCKeepsPublicationTypes() throws {
        let result = try JSONDecoder().decode(EuropePMCResult.self, from: Data("""
        {"id": "1", "source": "MED", "pmid": "1", "title": "T",
         "pubTypeList": {"pubType": ["Retracted Publication", "research-article"]}}
        """.utf8))
        XCTAssertEqual(
            EuropePMCService.searchArticle(from: result).publicationTypes,
            ["Retracted Publication", "research-article"]
        )
    }

    /// No list is not an empty list: absent stays unrecorded.
    func testNoTypeListIsNil() throws {
        XCTAssertNil(pubMedArticles("").first?.publicationTypes)
        XCTAssertEqual(pubMedArticles("<PublicationTypeList/>").first?.publicationTypes, [])
        let result = try JSONDecoder().decode(
            EuropePMCResult.self, from: Data(#"{"id": "1", "title": "T"}"#.utf8))
        XCTAssertNil(EuropePMCService.searchArticle(from: result).publicationTypes)
    }

    func testDefaultQueryNoLongerExcludesRetracted() {
        let query = StructuredQuery(concepts: [SearchConcept(name: "x", keywords: ["asthma"])])
        let built = PubMedQueryBuilder.build(from: query)
        XCTAssertFalse(built.contains("Retracted Publication"))
        XCTAssertTrue(built.contains("Editorial"), "the other default exclusions stay")
    }
}
