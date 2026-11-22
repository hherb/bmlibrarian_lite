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

/// A merged duplicate must not lose PubMed's indexing (MeSH, status, method).
final class MeshIndexingMergeTests: XCTestCase {

    private func article(
        pmid: String, title: String, source: SearchProvider,
        mesh: [String]? = nil, status: String? = nil, method: String? = nil
    ) -> SearchArticle {
        SearchArticle(
            pmid: pmid, title: title, abstract: "", authors: "", journal: "J", year: "2020",
            source: source, meshTerms: mesh, medlineStatus: status, indexingMethod: method)
    }

    func testKeptEuropePMCRecordTakesPubMedIndexingByIdentifier() {
        let kept = article(pmid: "1", title: "Aspirin and stroke", source: .europePMC)
        let dup = article(pmid: "1", title: "Aspirin and stroke", source: .pubmed,
                          mesh: ["Humans", "Stroke"], status: "MEDLINE", method: "Automated")
        let merged = SearchResultMerger.mergeArticles(primary: [kept], secondary: [dup])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].meshTerms, ["Humans", "Stroke"])
        XCTAssertEqual(merged[0].medlineStatus, "MEDLINE")
        XCTAssertEqual(merged[0].indexingMethod, "Automated")
    }

    func testKeptEuropePMCRecordTakesPubMedIndexingByTitle() {
        let kept = article(pmid: "", title: "Aspirin for secondary prevention of stroke", source: .europePMC)
        let dup = article(pmid: "2", title: "Aspirin for secondary prevention of stroke", source: .pubmed,
                          mesh: ["Aspirin"], status: "In-Process", method: "Curated")
        let merged = SearchResultMerger.mergeArticles(primary: [kept], secondary: [dup])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].meshTerms, ["Aspirin"])
        XCTAssertEqual(merged[0].medlineStatus, "In-Process")
        XCTAssertEqual(merged[0].indexingMethod, "Curated")
    }

    func testKeptRecordsOwnIndexingWins() {
        let kept = article(pmid: "3", title: "T", source: .pubmed,
                           mesh: ["Humans"], status: "MEDLINE", method: "Manual")
        let dup = article(pmid: "3", title: "T", source: .europePMC,
                          mesh: ["Other"], status: "Publisher", method: "Automated")
        let merged = SearchResultMerger.mergeArticles(primary: [kept], secondary: [dup])
        XCTAssertEqual(merged[0].meshTerms, ["Humans"])
        XCTAssertEqual(merged[0].medlineStatus, "MEDLINE")
        XCTAssertEqual(merged[0].indexingMethod, "Manual")
    }
}
