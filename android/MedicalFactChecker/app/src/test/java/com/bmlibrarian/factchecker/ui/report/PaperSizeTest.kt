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
