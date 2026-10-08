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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    /** A link stored by a build before #495, written for any scheme, can no longer act; its text stays. */
    @Test
    fun `a stored javascript link loses its href and keeps its text`() {
        assertEquals(
            "<p>see <a>the trial</a></p>",
            neutraliseUnsafeUrls("<p>see <a href=\"javascript:alert(1)\">the trial</a></p>")
        )
    }

    /** Every way a browser still reads a scheme as one: each is dropped. */
    @Test
    fun `every disguise of an unsafe scheme is dropped`() {
        val disguised = listOf(
            "JaVaScRiPt:alert(1)",
            "&#106;avascript:alert(1)",
            "&#x6A;avascript:alert(1)",
            "&#0000106avascript:alert(1)",
            "javascript&colon;alert(1)",
            "javascript&#58;alert(1)",
            "java\tscript:alert(1)",
            "java\nscript:alert(1)",
            "java&Tab;script:alert(1)",
            "java&#10;script:alert(1)",
            " \u0001javascript:alert(1)",
            "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox(1)"
        )
        for (url in disguised) {
            assertEquals(url, "<a>x</a>", neutraliseUnsafeUrls("<a href=\"$url\">x</a>"))
        }
    }

    /** Names in any case, values in any quoting, spaces around the `=`. */
    @Test
    fun `unsafe values are dropped however the attribute is written`() {
        val written = listOf(
            "<a HREF=\"javascript:alert(1)\">x</a>",
            "<a Href='javascript:alert(1)'>x</a>",
            "<a href=javascript:alert(1)>x</a>",
            "<a href = \"javascript:alert(1)\">x</a>",
            "<A href=\"javascript:alert(1)\">x</A>"
        )
        for (html in written) {
            val neutralised = neutraliseUnsafeUrls(html)
            assertFalse(neutralised, "javascript" in neutralised.lowercase())
            assertTrue(neutralised, neutralised.endsWith(">x</a>", ignoreCase = true))
        }
    }

    /** A figure whose deposit path names a scheme loads nothing; its other attributes stay. */
    @Test
    fun `an image source with an unsafe scheme is dropped`() {
        assertEquals(
            "<img alt=\"Figure 1\" loading=\"lazy\">",
            neutraliseUnsafeUrls("<img src=\"javascript:alert(1)\" alt=\"Figure 1\" loading=\"lazy\">")
        )
        assertEquals("<img alt=\"f\" />", neutraliseUnsafeUrls("<img SRC='data:image/svg+xml,x' alt=\"f\" />"))
    }

    /** The control: http, https, a relative path and an anchor are untouched, as is all text. */
    @Test
    fun `safe links and text are untouched`() {
        val html = "<p>Text with href=\"javascript:x\" written as prose &amp; a &lt;tag&gt;.</p>" +
            "<a href=\"https://doi.org/10.1/x?a=1&amp;b=2\">doi</a>" +
            "<a href=\"http://example.org/\">http</a>" +
            "<a href=\"#fig1\">Figure 1</a>" +
            "<a href=\"figures/f1.jpg\">relative</a>" +
            "<img src=\"https://europepmc.org/articles/PMC1/bin/f1.jpg\" alt=\"a &gt; b\" " +
            "onerror=\"tryAlternativeExtensions(this)\">" +
            "<a title=\"javascript:not a URL\" href=\"/path:with-colon\">t</a>"
        assertEquals(html, neutraliseUnsafeUrls(html))
    }

    /** A `>` inside a quoted value does not end the tag, so the attribute after it is still judged. */
    @Test
    fun `a quoted greater-than does not hide a later attribute`() {
        assertEquals(
            "<a title=\"a > b\">x</a>",
            neutraliseUnsafeUrls("<a title=\"a > b\" href=\"javascript:alert(1)\">x</a>")
        )
    }

    /** An attribute named in another's value is that value's text, not an attribute. */
    @Test
    fun `an attribute inside another's value is left alone`() {
        val html = "<a title=' href=javascript:alert(1)' href=\"https://example.org/\">x</a>"
        assertEquals(html, neutraliseUnsafeUrls(html))
    }

    /** A long page is read in runs, never one recursion per character. */
    @Test
    fun `a long tag and a long page are read`() {
        val long = "x".repeat(LONG_RUN)
        val html = "<img alt=$long src=\"javascript:alert(1)\">" + "<p>$long</p>".repeat(LONG_REPEATS)
        val neutralised = neutraliseUnsafeUrls(html)
        assertEquals("<img alt=$long>" + "<p>$long</p>".repeat(LONG_REPEATS), neutralised)
    }

    @Test
    fun `character references are decoded as a browser reads them`() {
        assertEquals("j:\t\n/?#&<", decodeCharacterReferences("&#106;&colon;&Tab;&NewLine;&sol;&quest;&num;&amp;&lt;"))
        assertEquals("\uFFFD\uFFFD\uFFFD", decodeCharacterReferences("&#0;&#xD800;&#99999999999;"))
        assertEquals("&unknown; stays", decodeCharacterReferences("&unknown; stays"))
    }

    private companion object {
        const val LONG_RUN = 200_000
        const val LONG_REPEATS = 20
    }
}
