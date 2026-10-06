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

package com.bmlibrarian.factchecker.util

import org.junit.Assert.assertEquals
import org.junit.Test

/** The escaper the JATS and markdown renderers share (#495), and its inverse. */
class HtmlEscapingTest {

    @Test
    fun `the five characters HTML gives meaning to are escaped`() {
        assertEquals("&amp;&lt;&gt;&quot;&#39;", escapeHtml("&<>\"'"))
    }

    @Test
    fun `an existing reference is escaped as text`() {
        assertEquals("&amp;lt;", escapeHtml("&lt;"))
    }

    @Test
    fun `unescaping undoes escaping in one pass`() {
        val text = "a &lt; b & \"c\" <'d'> &amp;"

        assertEquals(text, unescapeHtml(escapeHtml(text)))
        assertEquals("&lt;", unescapeHtml("&amp;lt;"))
    }

    @Test
    fun `unescaping leaves other references alone`() {
        assertEquals("&#106;&nbsp;", unescapeHtml("&#106;&nbsp;"))
    }
}
