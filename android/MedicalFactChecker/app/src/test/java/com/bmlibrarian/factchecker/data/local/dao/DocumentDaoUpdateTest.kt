/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.data.local.dao

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import io.mockk.Runs
import io.mockk.coEvery
import io.mockk.just
import io.mockk.mockk
import io.mockk.slot
import java.util.Date
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * A whole-row document update keeps the stored transparency result.
 *
 * Screens read a row, `copy()` it and write it back to change its full text;
 * the workflow may store a transparency result in between.
 */
class DocumentDaoUpdateTest {

    private val delegate = mockk<DocumentDao>()

    /** Every DAO call goes to the mock except [DocumentDao.update], which runs as written. */
    private val dao = object : DocumentDao by delegate {
        override suspend fun update(document: DocumentEntity) = super.update(document)
    }

    @Test
    fun `a stale copy written back keeps the result stored after it was read`() = runTest {
        val read = DocumentEntity(id = "d", sessionId = "s", title = "t")
        val analysedAt = Date(1_000L)
        coEvery { delegate.getById("d") } returns read.copy(
            transparencyResultJson = "{stored}",
            transparencyAnalyzedAt = analysedAt,
        )
        val written = slot<DocumentEntity>()
        coEvery { delegate.updateAllColumns(capture(written)) } just Runs

        dao.update(read.copy(fullTextMarkdown = "body"))

        assertEquals("body", written.captured.fullTextMarkdown)
        assertEquals("{stored}", written.captured.transparencyResultJson)
        assertEquals(analysedAt, written.captured.transparencyAnalyzedAt)
    }
}
