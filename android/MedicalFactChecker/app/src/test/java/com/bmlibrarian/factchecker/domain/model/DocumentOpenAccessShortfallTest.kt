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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The domain document carries the stored open-access shortfall, typed (#466). */
class DocumentOpenAccessShortfallTest {

    private val entity = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1/x")

    @Test
    fun `a stored shortfall reaches the domain document`() {
        for (shortfall in listOf(
            OpenAccessShortfall(OpenAccessSource.LANDING_PAGE, RequestFailure(RequestFailureKind.TIMEOUT)),
            OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED,
        )) {
            val stored = entity.copy(fullTextOpenAccessShortfallJson = shortfall.toJson())

            assertEquals(shortfall, Document.fromEntity(stored).openAccessShortfall)
        }
    }

    /** The control: a document with nothing stored has nothing to say. */
    @Test
    fun `nothing stored is no shortfall`() {
        assertNull(Document.fromEntity(entity).openAccessShortfall)
    }
}
