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
/// the articles it produced.
///
/// Since #251 BioMedLit reports PubMed's real total, so a second batch is now
/// requested. A `PubmedBookArticle` yields no article, so advancing by the
/// article count re-requested PMIDs already fetched, and a batch that parsed to
/// nothing would have been requested again on every "fetch more".
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

    /// Convert a PubMed result requested at `basePosition`.
    private func unified(_ result: BMLSearchResult, basePosition: Int) -> UnifiedSearchResult {
        BioMedLitAdapters.toUnifiedSearchResult(
            result, appProvider: .pubmed, batchNumber: 2, basePosition: basePosition
        )
    }

    /// Ten PMIDs consumed but one article parsed: the next batch starts ten on.
    func testTheNextOffsetFollowsThePMIDsConsumed() {
        let result = BMLSearchResult(
            articles: [article], totalCount: 25000, nextOffset: 30, query: "aspirin", provider: .pubmed
        )

        let converted = unified(result, basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 30)
        XCTAssertTrue(converted.hasMore)
        XCTAssertEqual(converted.totalCount, 25000)
    }

    /// A batch that parsed to nothing still moves on, so "fetch more" cannot stall.
    func testABatchWithNoParsedArticlesStillAdvances() {
        let result = BMLSearchResult(
            articles: [], totalCount: 25000, nextOffset: 30, query: "aspirin", provider: .pubmed
        )

        XCTAssertEqual(unified(result, basePosition: 20).nextOffset, 30)
    }

    /// Without a next page from BioMedLit, the article count is all that is known.
    func testALastBatchAdvancesByItsArticles() {
        let result = BMLSearchResult(
            articles: [article], totalCount: 21, nextOffset: nil, query: "aspirin", provider: .pubmed
        )

        let converted = unified(result, basePosition: 20)

        XCTAssertEqual(converted.nextOffset, 21)
        XCTAssertFalse(converted.hasMore)
    }
}
