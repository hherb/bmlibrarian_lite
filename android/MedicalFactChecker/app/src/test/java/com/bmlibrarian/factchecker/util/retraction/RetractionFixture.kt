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
package com.bmlibrarian.factchecker.util.retraction

import java.time.Instant
import org.bmlib.ffi.RetractionIndex
import org.bmlib.ffi.buildRetractionIndex

/**
 * A small Retraction Watch export in the real export's columns (header from
 * bmlib's `the_retraction_index_round_trips_through_the_ffi`), as Swift's
 * `RetractionFixture`.
 */
object RetractionFixture {
    const val HEADER = "Record ID,RetractionDate,RetractionDOI,OriginalPaperDOI,OriginalPaperPubMedID,RetractionNature"

    /** A retraction, a concern and a correction, each by DOI and PMID. */
    val rows = listOf(
        "1,2/6/2010 0:00,10.1000/notice1,10.1000/retracted,111,Retraction",
        "2,3/7/2011 0:00,10.1000/notice2,10.1000/concerned,222,Expression of concern",
        "3,4/8/2012 0:00,10.1000/notice3,10.1000/corrected,333,Correction",
    )

    /** The day the tests run on, and its index's `dataAsOf`. */
    const val TODAY = "2026-10-29"

    /** Midday UTC on [TODAY]. */
    val nowMs: Long = Instant.parse("2026-10-29T12:00:00Z").toEpochMilli()

    /** [count] distinct retraction rows. */
    fun retractions(count: Int): List<String> = (1..count).map { "$it,2/6/2010 0:00,10.2000/n$it,10.2000/p$it,${1000 + it},Retraction" }

    fun csv(rows: List<String> = this.rows): ByteArray = ((listOf(HEADER) + rows).joinToString("\n") + "\n").toByteArray()

    fun index(rows: List<String> = this.rows, dataAsOf: String = TODAY): RetractionIndex = buildRetractionIndex(csv(rows), dataAsOf).index
}
