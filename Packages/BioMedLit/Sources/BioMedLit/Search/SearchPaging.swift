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

/// How far each literature source's search can be paged, and what a page should hold (#256, #253).
///
/// The clients, the search and the session each ask these questions; one answer
/// for each keeps them from disagreeing about whether a next page exists or
/// whether a page came back short.
public enum SearchPaging {
    /// The largest number of records PubMed lists for one search.
    ///
    /// Checked live on 2026-09-15: `retstart` may be at most 9998, so the last
    /// listable record is the 9,999th. It is the same number as
    /// ``BioMedLitConstants/pubmedMaxOffset``, which bounds the offset
    /// exclusively, and is named here for the question this file answers.
    public static let pubMedListableRecords = BioMedLitConstants.pubmedMaxOffset

    /// How many PMIDs an esearch page should list.
    ///
    /// - Parameters:
    ///   - totalCount: The search's `count`.
    ///   - offset: The page's `retstart`.
    ///   - pageSize: The page size asked for, `retmax`.
    /// - Returns: The PMIDs PubMed holds from `offset` on, up to `pageSize` and
    ///   to the first ``pubMedListableRecords``; 0 past the end of what can be listed.
    public static func expectedEsearchListing(totalCount: Int, offset: Int, pageSize: Int) -> Int {
        max(0, min(pageSize, totalCount - offset, pubMedListableRecords - offset))
    }

    /// Whether PubMed has a page at an offset.
    ///
    /// - Parameters:
    ///   - offset: The page's offset.
    ///   - totalCount: The search's `count`.
    /// - Returns: `true` while the offset is short of both the total and the
    ///   records PubMed lists.
    public static func pubMedHasNextPage(offset: Int, totalCount: Int) -> Bool {
        offset < min(totalCount, pubMedListableRecords)
    }

    /// How many records a Europe PMC page should hold.
    ///
    /// - Parameters:
    ///   - hitCount: The search's `hitCount`.
    ///   - recordsReceived: How many records the search's earlier pages held,
    ///     readable or not.
    ///   - pageSize: The page size asked for.
    /// - Returns: The page size, or the hits not yet received if fewer; 0 once
    ///   every hit arrived.
    public static func expectedEuropePMCPage(hitCount: Int, recordsReceived: Int, pageSize: Int) -> Int {
        max(0, min(pageSize, hitCount - recordsReceived))
    }
}
