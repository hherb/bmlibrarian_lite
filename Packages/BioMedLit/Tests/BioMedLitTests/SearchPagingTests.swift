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


import Foundation
import XCTest
@testable import BioMedLit

/// How far a source can be paged, and what a page should hold (#256, #253).
final class SearchPagingTests: XCTestCase {
    /// An esearch page lists at most what PubMed holds past its offset, and the first 9,999.
    func testAnEsearchPageListsWhatPubMedHoldsPastItsOffset() {
        XCTAssertEqual(SearchPaging.expectedEsearchListing(totalCount: 25_000, offset: 0, pageSize: 100), 100)
        XCTAssertEqual(SearchPaging.expectedEsearchListing(totalCount: 120, offset: 100, pageSize: 100), 20)
        XCTAssertEqual(SearchPaging.expectedEsearchListing(totalCount: 25_000, offset: 9_900, pageSize: 100), 99)
        XCTAssertEqual(SearchPaging.expectedEsearchListing(totalCount: 25_000, offset: 9_999, pageSize: 100), 0)
        XCTAssertEqual(SearchPaging.expectedEsearchListing(totalCount: 5, offset: 10, pageSize: 100), 0)
    }

    /// PubMed has a next page until its offset reaches the total or the records it lists.
    func testPubMedHasANextPageUntilTheTotalOrTheCap() {
        XCTAssertTrue(SearchPaging.pubMedHasNextPage(offset: 0, totalCount: 25_000))
        XCTAssertTrue(SearchPaging.pubMedHasNextPage(offset: 9_998, totalCount: 25_000))
        XCTAssertFalse(SearchPaging.pubMedHasNextPage(offset: 9_999, totalCount: 25_000))
        XCTAssertFalse(SearchPaging.pubMedHasNextPage(offset: 10_500, totalCount: 25_000))
        XCTAssertFalse(SearchPaging.pubMedHasNextPage(offset: 20, totalCount: 20))
        XCTAssertFalse(SearchPaging.pubMedHasNextPage(offset: 0, totalCount: 0))
    }

    /// The cap is the number of records PubMed lists, which is also the offset bound.
    func testTheCapIsTheNumberOfRecordsPubMedLists() {
        XCTAssertEqual(SearchPaging.pubMedListableRecords, 9_999)
        XCTAssertEqual(SearchPaging.pubMedListableRecords, BioMedLitConstants.pubmedMaxOffset)
    }

    /// A Europe PMC page should hold the batch, or the hits not yet received.
    func testAEuropePMCPageHoldsTheBatchOrTheHitsNotYetReceived() {
        XCTAssertEqual(
            SearchPaging.expectedEuropePMCPage(hitCount: 500, recordsReceived: 0, pageSize: 25), 25
        )
        XCTAssertEqual(
            SearchPaging.expectedEuropePMCPage(hitCount: 30, recordsReceived: 25, pageSize: 25), 5
        )
        XCTAssertEqual(
            SearchPaging.expectedEuropePMCPage(hitCount: 25, recordsReceived: 25, pageSize: 25), 0
        )
        XCTAssertEqual(
            SearchPaging.expectedEuropePMCPage(hitCount: 10, recordsReceived: 25, pageSize: 25), 0
        )
    }
}
