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

/** The stored-check read binds at most 999 keys a statement (SQLite before API 31, #658). */
class RetractionServiceStoredChecksTest {
    /** Refuses a read of more keys than old SQLite binds, as the platform would. */
    private class BoundedDao(val rows: Map<String, String>, val failingRead: Int? = null) : RetractionCheckDao {
        val reads = mutableListOf<Int>()

        override suspend fun get(paperKeys: List<String>): List<RetractionCheckEntity> {
            // SQLite's own limit, not the production constant, so the fake cannot follow it
            require(paperKeys.size <= 999) { "too many SQL variables" }
            if (reads.size == failingRead) throw IllegalStateException("disk I/O error")
            reads += paperKeys.size
            return paperKeys.mapNotNull { key -> rows[key]?.let { RetractionCheckEntity(key, it) } }
        }

        override suspend fun upsert(checks: List<RetractionCheckEntity>) = Unit

        override suspend fun insertIfAbsent(checks: List<RetractionCheckEntity>) = Unit
    }

    @Test
    fun `more keys than one statement binds are read in batches, every row returned`() = runTest {
        val keys = (0 until 2_500).map { "pmid:$it" }
        val dao = BoundedDao(keys.filterIndexed { i, _ -> i % 2 == 0 }.associateWith { "{}" })
        val service = RetractionService(mockk(relaxed = true), mockk(relaxed = true), dao)

        val stored = service.storedChecks(keys.toSet())

        assertEquals(listOf(999, 999, 502), dao.reads)
        assertEquals(1_250, stored.size)
        assertTrue(stored.keys.all { it.removePrefix("pmid:").toInt() % 2 == 0 })
    }

    /** A partial map would read the failed batch's papers as having no row, dropping "could not be read". */
    @Test
    fun `one batch failing fails the whole read`() = runTest {
        val keys = (0 until 2_500).map { "pmid:$it" }
        val dao = BoundedDao(keys.associateWith { "{}" }, failingRead = 1)
        val service = RetractionService(mockk(relaxed = true), mockk(relaxed = true), dao)

        val read = runCatching { service.storedChecks(keys.toSet()) }

        assertTrue("$read", read.exceptionOrNull() is IllegalStateException)
    }
}
