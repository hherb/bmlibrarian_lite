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
package com.bmlibrarian.factchecker.ui.fulltext

import org.junit.Assert.assertEquals
import org.junit.Test

/** CORE's plain text, cut into paragraphs for the lazy viewer: nothing shown is lost. */
class PlainTextParagraphsTest {

    @Test
    fun `blank lines part paragraphs, single line breaks do not`() {
        assertEquals(
            listOf("One\nline two", "Two", "  Three, indented"),
            plainTextParagraphs("One\nline two\n\nTwo\r\n \t\r\n\n  Three, indented")
        )
    }

    @Test
    fun `whitespace before, after and between is no paragraph`() {
        assertEquals(listOf("a", "b"), plainTextParagraphs("\n\n  \na\n\n\n\nb\n\n"))
        assertEquals(emptyList<String>(), plainTextParagraphs(" \n\n "))
    }

    /** Every character but the parting blank lines is shown, in order: no truncation. */
    @Test
    fun `every visible character of a long text is kept`() {
        val text = (1..PARAGRAPHS).joinToString("\n\n") { "Paragraph $it: " + "word ".repeat(WORDS) }
        val paragraphs = plainTextParagraphs(text)
        assertEquals(PARAGRAPHS, paragraphs.size)
        assertEquals(text, paragraphs.joinToString("\n\n"))
    }

    private companion object {
        const val PARAGRAPHS = 2_000
        const val WORDS = 500
    }
}
