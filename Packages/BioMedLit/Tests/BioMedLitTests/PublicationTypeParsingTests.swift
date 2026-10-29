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

    /// The label stays with its own article: the next one, with no list, is unrecorded.
    func testPubMedTypesDoNotCarryToTheNextArticle() {
        let xml = """
        <PubmedArticleSet>\
        <PubmedArticle><MedlineCitation><PMID>1</PMID><Article><Journal><Title>J</Title></Journal>\
        <ArticleTitle>A</ArticleTitle><PublicationTypeList>\
        <PublicationType UI="D016441">Retracted Publication</PublicationType></PublicationTypeList>\
        </Article></MedlineCitation></PubmedArticle>\
        <PubmedArticle><MedlineCitation><PMID>2</PMID><Article><Journal><Title>J</Title></Journal>\
        <ArticleTitle>B</ArticleTitle></Article></MedlineCitation></PubmedArticle>\
        </PubmedArticleSet>
        """
        let articles = PubMedXMLParser(data: Data(xml.utf8)).parseArticleSet().articles
        XCTAssertEqual(articles.count, 2)
        XCTAssertEqual(articles.first?.publicationTypes, ["Retracted Publication"])
        XCTAssertNil(articles.last?.publicationTypes)
    }

    private func europePMCTypes(_ pubTypeList: String) throws -> [String]? {
        let result = try JSONDecoder().decode(EuropePMCResult.self, from: Data("""
        {"id": "1", "source": "MED", "pmid": "1", "title": "T", "pubTypeList": \(pubTypeList)}
        """.utf8))
        return EuropePMCService.searchArticle(from: result).publicationTypes
    }

    /// Read as the desktop reads it: an odd shape costs the field, never the record.
    func testEuropePMCOddTypeShapesKeepTheRecord() throws {
        XCTAssertEqual(try europePMCTypes(#"{"pubType": "Retracted Publication"}"#), ["Retracted Publication"])
        XCTAssertEqual(try europePMCTypes(#"{"pubType": ["Retracted Publication", null, 3]}"#),
                       ["Retracted Publication"])
        XCTAssertNil(try europePMCTypes(#"{"pubType": {"x": 1}}"#))
        XCTAssertNil(try europePMCTypes(#"{}"#))
    }

    /// A dropped duplicate's label reaches the kept record; `nil` adds nothing.
    func testMergerFoldsADuplicatesTypesIntoTheKeptRecord() {
        func article(_ pmid: String, _ title: String, _ types: [String]?) -> SearchArticle {
            SearchArticle(pmid: pmid, title: title, abstract: "", authors: "", journal: "", year: "",
                          source: .pubmed, publicationTypes: types)
        }
        let merged = SearchResultMerger.mergeArticles(
            primary: [article("1", "Study Alpha", ["Journal Article"]), article("2", "Study Beta", nil)],
            secondary: [article("1", "Study Alpha", ["Retracted Publication", "Journal Article"]),
                        article("2", "Study Beta", nil)]
        )
        XCTAssertEqual(merged.count, 2)
        XCTAssertEqual(merged[0].publicationTypes, ["Journal Article", "Retracted Publication"])
        XCTAssertNil(merged[1].publicationTypes)
    }

    func testDefaultQueryNoLongerExcludesRetracted() {
        let query = StructuredQuery(concepts: [SearchConcept(name: "x", keywords: ["asthma"])])
        let built = PubMedQueryBuilder.build(from: query)
        XCTAssertFalse(built.contains("Retracted Publication"))
        XCTAssertTrue(built.contains("Editorial"), "the other default exclusions stay")
    }
}
