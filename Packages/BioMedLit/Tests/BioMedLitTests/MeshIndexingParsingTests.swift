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

/// PubMed's indexing (MeSH descriptors, MEDLINE status, indexing method)
/// reaches the search article; it is the study-design reference MANTA is
/// compared against.
final class MeshIndexingParsingTests: XCTestCase {

    private func articles(citationAttributes: String = "", _ body: String) -> [SearchArticle] {
        let xml = """
        <PubmedArticleSet><PubmedArticle><MedlineCitation \(citationAttributes)><PMID>1</PMID><Article>
        <Journal><Title>J</Title></Journal><ArticleTitle>T</ArticleTitle></Article>\(body)
        </MedlineCitation></PubmedArticle></PubmedArticleSet>
        """
        return PubMedXMLParser(data: Data(xml.utf8)).parseArticleSet().articles
    }

    func testKeepsMeshDescriptorsNotQualifiers() {
        let found = articles("""
        <MeshHeadingList>\
        <MeshHeading><DescriptorName UI="D1" MajorTopicYN="N">Humans</DescriptorName></MeshHeading>\
        <MeshHeading><DescriptorName UI="D2" MajorTopicYN="Y">Stroke</DescriptorName>\
        <QualifierName UI="Q1" MajorTopicYN="N">therapy</QualifierName></MeshHeading>\
        </MeshHeadingList>
        """)
        XCTAssertEqual(found.first?.meshTerms, ["Humans", "Stroke"])
    }

    func testKeepsStatusAndIndexingMethod() {
        let found = articles(
            citationAttributes: "Status=\"MEDLINE\" Owner=\"NLM\" IndexingMethod=\"Automated\"", "")
        XCTAssertEqual(found.first?.medlineStatus, "MEDLINE")
        XCTAssertEqual(found.first?.indexingMethod, "Automated")
    }

    func testNoMeshListIsNil() {
        let found = articles(citationAttributes: "Status=\"In-Process\"", "")
        XCTAssertNil(found.first?.meshTerms)
        XCTAssertEqual(found.first?.medlineStatus, "In-Process")
        XCTAssertNil(found.first?.indexingMethod)
    }
}
