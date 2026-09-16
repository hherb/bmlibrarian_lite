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

import BioMedLit
import XCTest
@testable import MedicalFactChecker

/// A PubMed batch advances the app's offset by the PMIDs it consumed, not by
/// the articles it produced, and stops where BioMedLit says there is no next page.
///
/// Since #251 BioMedLit reports PubMed's real total, so later batches are
/// requested. A `PubmedBookArticle` yields no article, so advancing by the
/// article count re-requested PMIDs already fetched, and a batch that parsed to
/// nothing was requested again on every "fetch more".
final class PubMedPaginationAdapterTests: XCTestCase {
    /// One parsed article, standing in for a batch where others did not parse.
    private let article = BMLSearchArticle(
        pmid: "12345",
        title: "A title",
        abstract: "",
        authors: "",
        journal: "",
        year: "2026",
        source: .pubmed,
        identifierKind: .pubmed
    )

    /// Where PubMed's paging goes after a page requested at `basePosition`.
    private func unified(_ result: BMLSearchResult, basePosition: Int) -> OffsetPaginationState {
        BioMedLitAdapters.pubMedPagination(
            for: result, basePosition: basePosition, articleCount: result.articles.count
        )
    }

    /// A PubMed result with `count` copies of the one article.
    private func result(articles count: Int, totalCount: Int, nextOffset: Int?) -> BMLSearchResult {
        BMLSearchResult(
            articles: Array(repeating: article, count: count),
            totalCount: totalCount,
            nextOffset: nextOffset,
            query: "aspirin",
            provider: .pubmed
        )
    }

    /// Ten PMIDs consumed but one article parsed: the next batch starts ten on.
    func testTheNextOffsetFollowsThePMIDsConsumed() {
        let converted = unified(result(articles: 1, totalCount: 25000, nextOffset: 30), basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 30)
        XCTAssertTrue(converted.hasMore)
        XCTAssertEqual(converted.totalCount, 25000)
    }

    /// A batch with a next page that parsed to nothing still moves on.
    func testABatchWithNoParsedArticlesStillAdvances() {
        let converted = unified(result(articles: 0, totalCount: 25000, nextOffset: 30), basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 30)
        XCTAssertTrue(converted.hasMore)
    }

    /// A last batch whose every PMID parsed ends pagination.
    func testALastBatchThatFullyParsedEndsPagination() {
        let converted = unified(result(articles: 1, totalCount: 21, nextOffset: nil), basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 21)
        XCTAssertFalse(converted.hasMore)
    }

    /// A last batch that parsed to nothing ends pagination instead of being
    /// requested again on every "fetch more".
    func testALastBatchWithNoParsedArticlesEndsPagination() {
        let converted = unified(result(articles: 0, totalCount: 21, nextOffset: nil), basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 21)
        XCTAssertFalse(converted.hasMore)
    }

    /// A last batch where some PMIDs did not parse still reaches the end, so the
    /// next request does not re-fetch the unparsed ones.
    func testALastBatchWithSomeUnparsedArticlesEndsPagination() {
        let converted = unified(result(articles: 8, totalCount: 30, nextOffset: nil), basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 30)
        XCTAssertFalse(converted.hasMore)
    }

    /// At PubMed's offset cap BioMedLit states no next page even though more
    /// articles match, and a PubMed search offers no batch past the cap. A search
    /// of both providers is judged against the combined total instead (#253).
    func testTheOffsetCapEndsPagination() {
        let converted = unified(result(articles: 20, totalCount: 25000, nextOffset: nil), basePosition: 9980)

        XCTAssertFalse(converted.hasMore)
        XCTAssertTrue(converted.isExhausted, "BioMedLit said there is no page past the cap")
    }

    /// An empty batch past the end offers nothing further.
    func testAnEmptyBatchPastTheEndEndsPagination() {
        let converted = unified(result(articles: 0, totalCount: 3, nextOffset: nil), basePosition: 10)

        XCTAssertFalse(converted.hasMore)
    }
}
