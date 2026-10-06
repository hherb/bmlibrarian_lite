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

package com.bmlibrarian.factchecker.util.jats

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The inline links of a deposit's paragraphs, in the JATS renderer's HTML, which
 * is shown in a JavaScript-enabled WebView (#495).
 *
 * A deposit's text is untrusted: a markdown link in it naming a `javascript:`
 * URL must not become a link (a backtick call needs no parentheses, so the
 * URL's cut-off at the first `)` does not help).
 */
class JATSInlineLinkTest {

    /** The HTML of an article whose one body paragraph is [paragraph], given as JATS XML. */
    private fun html(paragraph: String): String = JATSXMLParser(
        """
        <?xml version="1.0"?>
        <article><front><article-meta>
          <title-group><article-title>Host article</article-title></title-group>
        </article-meta></front>
        <body><sec><title>Intro</title><p>$paragraph</p></sec></body></article>
        """.trimIndent().toByteArray()
    ).parseToHTML()

    @Test
    fun `a link with an unsafe scheme renders as its text`() {
        val urls = listOf(
            "javascript:alert`1`", "JavaScript:alert`1`", "JAVASCRIPT:alert`1`", " javascript:alert`1`",
            "java&#9;script:alert`1`", "&#10;javascript:alert`1`", "data:text/html;base64,PHNjcmlwdD4=",
            "vbscript:msgbox", "file:///etc/hosts"
        )
        for (url in urls) {
            val html = html("See [x]($url) here.")
            assertFalse("$url -> $html", html.contains("<p>See <a"))
            assertTrue("$url -> $html", html.contains("<p>See x here.</p>"))
        }
    }

    @Test
    fun `an unsafe link's text is escaped`() {
        val html = html("See [&lt;b&gt;x](javascript:alert`1`) here.")

        assertTrue(html, html.contains("<p>See &lt;b&gt;x here.</p>"))
    }

    /** The control: http(s), anchors and relative URLs stay links. */
    @Test
    fun `a link with a safe URL stays a link`() {
        for (url in listOf("https://a.org/x", "HTTP://a.org/x", "#fig1", "fig1.jpg")) {
            val html = html("See [x]($url) here.")
            assertTrue("$url -> $html", html.contains("<p>See <a href=\"$url\">x</a> here.</p>"))
        }
    }

    /** Brackets pair as they always did: the `]` that brings the depth back to zero. */
    @Test
    fun `brackets pair as before`() {
        assertTrue(html("[a [b] c](https://u.org) x").contains("<p><a href=\"https://u.org\">a [b] c</a> x</p>"))
        assertTrue(html("[[a](https://u.org)").contains("<p>[<a href=\"https://u.org\">a</a></p>"))
        assertTrue(html("[x](no close").contains("<p>[x](no close</p>"))
        assertTrue(html("[x] y").contains("<p>[x] y</p>"))
    }

    /** Many unclosed `[`: each used to be scanned to the end of the text (10 s for 100k). */
    @Test
    fun `a paragraph of unclosed brackets renders quickly and as text`() {
        for (paragraph in listOf("[".repeat(PATHOLOGICAL_LENGTH), "[a](".repeat(PATHOLOGICAL_LENGTH / 4))) {
            val started = System.nanoTime()
            val html = html(paragraph)
            val elapsedMs = (System.nanoTime() - started) / NANOS_PER_MILLI

            assertTrue("${paragraph.take(8)}…: $elapsedMs ms", elapsedMs < PATHOLOGICAL_LIMIT_MS)
            assertTrue(paragraph.take(8), html.contains("<p>$paragraph</p>"))
        }
    }

    /** The control: a cross-reference to a figure is an anchor link, as before. */
    @Test
    fun `a figure cross-reference stays a link`() {
        val html = html("See <xref ref-type=\"fig\" rid=\"f1\">Figure 1</xref> here.")

        assertTrue(html, html.contains("<a href=\"#f1\">Figure 1</a>"))
    }

    private companion object {
        /** The length of a pathological paragraph: 100k characters. */
        const val PATHOLOGICAL_LENGTH = 100_000

        /** A generous limit on parsing one; linear, each takes well under half a second. */
        const val PATHOLOGICAL_LIMIT_MS = 2_000L

        const val NANOS_PER_MILLI = 1_000_000L
    }
}
