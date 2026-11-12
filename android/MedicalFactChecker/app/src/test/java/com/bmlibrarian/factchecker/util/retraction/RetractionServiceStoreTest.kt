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

import com.bmlibrarian.factchecker.data.local.dao.RetractionCheckDao
import com.bmlibrarian.factchecker.data.local.entity.RetractionCheckEntity
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/** Which checks replace a paper's row and which only fill a missing one (#658). */
class RetractionServiceStoreTest {
    /** REPLACE and IGNORE as Room runs them on the `paper_key` primary key. */
    private class MapDao(val rows: MutableMap<String, String>) : RetractionCheckDao {
        override suspend fun get(paperKeys: List<String>) =
            paperKeys.mapNotNull { key -> rows[key]?.let { RetractionCheckEntity(key, it) } }

        override suspend fun upsert(checks: List<RetractionCheckEntity>) = checks.forEach { rows[it.paperKey] = it.checkJson }

        override suspend fun insertIfAbsent(checks: List<RetractionCheckEntity>) =
            checks.forEach { rows.putIfAbsent(it.paperKey, it.checkJson) }
    }

    private val retracted = PaperRetractionCheck("retracted", checkedAtMs = 1)
    private val clear = PaperRetractionCheck("clear", checkedAtMs = 1)
    private val outage = PaperRetractionCheck("unchecked", unanswered = listOf("crossref"), checkedAtMs = 1)

    @Test
    fun `a check writes over its paper's row, a kept-existing one fills only a missing row`() = runTest {
        val rows = mutableMapOf("pmid:1" to PaperRetractionCheck.encode(clear), "pmid:2" to PaperRetractionCheck.encode(retracted))
        val service = RetractionService(mockk(relaxed = true), mockk(relaxed = true), MapDao(rows))

        service.store(mapOf("pmid:1" to retracted), keepingExisting = mapOf("pmid:2" to outage, "pmid:3" to outage))

        assertTrue("replaced", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        assertTrue("kept", PaperRetractionCheck.decode(rows.getValue("pmid:2"))!!.isRetracted)
        assertEquals("filled", "unchecked", PaperRetractionCheck.decode(rows.getValue("pmid:3"))!!.status)
    }
}
