/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.ui.report

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for PaperSize enum.
 *
 * Tests the paper size options for PDF export.
 */
class PaperSizeTest {

    @Test
    fun `PaperSize has A4 option`() {
        val a4 = PaperSize.A4

        assertEquals("A4", a4.name)
    }

    @Test
    fun `PaperSize has LETTER option`() {
        val letter = PaperSize.LETTER

        assertEquals("LETTER", letter.name)
    }

    @Test
    fun `PaperSize has exactly two options`() {
        val sizes = PaperSize.entries

        assertEquals(2, sizes.size)
    }

    @Test
    fun `can iterate over all paper sizes`() {
        val sizes = PaperSize.entries.map { it.name }

        assertTrue(sizes.contains("A4"))
        assertTrue(sizes.contains("LETTER"))
    }

    @Test
    fun `paper sizes can be used in when expression`() {
        PaperSize.entries.forEach { size ->
            val description = when (size) {
                PaperSize.A4 -> "210 x 297 mm"
                PaperSize.LETTER -> "8.5 x 11 inches"
            }
            assertTrue(description.isNotEmpty())
        }
    }
}
