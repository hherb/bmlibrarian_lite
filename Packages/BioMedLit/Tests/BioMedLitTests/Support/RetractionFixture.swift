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

import BmlibCore
import Foundation

/// A small Retraction Watch export in the real export's columns (header from
/// bmlib's `the_retraction_index_round_trips_through_the_ffi`).
enum RetractionFixture {
    static let header = "Record ID,RetractionDate,RetractionDOI,OriginalPaperDOI,OriginalPaperPubMedID,RetractionNature"

    /// A retraction, a concern and a correction, each by DOI and PMID.
    static let rows = [
        "1,2/6/2010 0:00,10.1000/notice1,10.1000/retracted,111,Retraction",
        "2,3/7/2011 0:00,10.1000/notice2,10.1000/concerned,222,Expression of concern",
        "3,4/8/2012 0:00,10.1000/notice3,10.1000/corrected,333,Correction",
    ]

    /// The day the tests run on, and its index's `dataAsOf`.
    static let today = "2026-10-29"

    /// Midday UTC on ``today``.
    static let now = ISO8601DateFormatter().date(from: "2026-10-29T12:00:00Z")!

    /// `count` distinct retraction rows.
    static func retractions(_ count: Int) -> [String] {
        (1...count).map { "\($0),2/6/2010 0:00,10.2000/n\($0),10.2000/p\($0),\(1000 + $0),Retraction" }
    }

    static func csv(_ rows: [String] = rows) -> Data {
        Data(([header] + rows).joined(separator: "\n").appending("\n").utf8)
    }

    static func index(_ rows: [String] = rows, dataAsOf: String = today) throws -> RetractionIndex {
        try buildRetractionIndex(csv: csv(rows), dataAsOf: dataAsOf).index
    }
}
