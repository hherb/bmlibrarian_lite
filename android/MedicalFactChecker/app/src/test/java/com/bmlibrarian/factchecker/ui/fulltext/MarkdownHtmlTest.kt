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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The stored-markdown renderer, whose page is shown in a JavaScript-enabled
 * WebView (#495).
 *
 * Ordinary markdown, as the JATS→markdown converter writes it, renders as it
 * always did; those expectations were recorded from the renderer before it
 * escaped anything. Article text is untrusted, so hostile markdown must render
 * inert: no tag, attribute or URL scheme the renderer did not write itself.
 */
class MarkdownHtmlTest {

    @Test
    fun `headers, bold and italic render as before`() {
        assertEquals(
            "<p><h1>Title</h1></p><p><h2>Methods</h2></p><p>Some <strong>bold</strong> and <em>it</em> text.\n</p>",
            markdownBodyHtml("# Title\n\n## Methods\n\nSome **bold** and *it* text.")
        )
    }

    @Test
    fun `links to https and to an anchor render as before`() {
        assertEquals(
            "<p>See <a href=\"#fig1\">Figure 1</a> and <a href=\"https://example.org/a\">the site</a>.\n</p>",
            markdownBodyHtml("See [Figure 1](#fig1) and [the site](https://example.org/a).")
        )
    }

    /** A figure as the JATS converter writes it: an anchor comment, its heading, its image and caption. */
    @Test
    fun `an anchored figure renders as before`() {
        val markdown = "<!-- anchor:fig1 -->\n\n### Figure 1\n\n" +
            "![Figure](https://europepmc.org/articles/PMC1/bin/f1.jpg)\n\nCaption"

        assertEquals(
            "<p><h3 id=\"fig1\">Figure 1</h3></p><p><figure><img src=\"https://europepmc.org/articles/PMC1/bin/f1.jpg\" " +
                "alt=\"Figure\" onerror=\"this.onerror=null; tryAlternativeExtensions(this);\" loading=\"lazy\"></figure>" +
                "</p><p>Caption\n</p>",
            markdownBodyHtml(markdown)
        )
    }

    @Test
    fun `a standalone anchor renders as before`() {
        assertEquals(
            "<p><span id=\"tab1\"></span></p><p>Text\n</p>",
            markdownBodyHtml("<!-- anchor:tab1 -->\n\nText")
        )
    }

    @Test
    fun `a table renders as before`() {
        assertEquals(
            "<p><table><thead><tr><th>A</th><th>B</th></tr></thead>" +
                "<tbody><tr><td>1</td><td>2</td></tr></tbody></table></p>",
            markdownBodyHtml("| A | B |\n| --- | --- |\n| 1 | 2 |")
        )
    }

    @Test
    fun `the page wraps the body`() {
        val page = markdownToBasicHtml("Text")

        assertTrue(page, page.contains("<body>\n            <p>Text\n</p>\n        </body>"))
    }

    // Hostile input (#495)

    @Test
    fun `a script element renders as text`() {
        val html = markdownBodyHtml("<script>alert(1)</script>")

        assertFalse(html, html.contains("<script"))
        assertEquals("<p>&lt;script&gt;alert(1)&lt;/script&gt;\n</p>", html)
    }

    @Test
    fun `an image with an event handler renders as text`() {
        val html = markdownBodyHtml("<img src=x onerror=alert(1)>")

        assertFalse(html, html.contains("<img"))
        assertEquals("<p>&lt;img src=x onerror=alert(1)&gt;\n</p>", html)
    }

    /** Medical prose compares: `p<a` must not open a tag and swallow the text after it. */
    @Test
    fun `comparisons in prose render as text`() {
        assertEquals(
            "<p>p&lt;0.05 and n&gt;10, a&lt;b &amp; c\n</p>",
            markdownBodyHtml("p<0.05 and n>10, a<b & c")
        )
    }

    @Test
    fun `a javascript link renders as its text only`() {
        // The URL ends at the first `)`, so the second is text, as it always was
        assertEquals("<p>x)\n</p>", markdownBodyHtml("[x](javascript:alert(1))"))
    }

    @Test
    fun `a javascript image renders as its alt text only`() {
        assertEquals("<p>a)\n</p>", markdownBodyHtml("![a](javascript:alert(1))"))
    }

    @Test
    fun `no link or image carries a scheme other than http or https`() {
        val urls = listOf(
            "javascript:alert(1)", "JavaScript:alert(1)", " javascript:alert(1)", "java\tscript:alert(1)",
            "\u0001javascript:alert(1)", "data:text/html,x", "vbscript:msgbox(1)", "file:///etc/hosts"
        )
        for (url in urls) {
            for (markdown in listOf("[x]($url)", "![x]($url)")) {
                val html = markdownBodyHtml(markdown)
                assertFalse("$markdown -> $html", html.contains("href=") || html.contains("<img"))
            }
        }
    }

    @Test
    fun `http, https, anchor and relative links are kept`() {
        // Judged as the browser reads the URL: leading spaces dropped, tabs removed
        val kept = listOf("http://a.org/x", "HTTPS://a.org/x", "#fig1", "fig1.jpg", "/a/b:c", "?q=a:b",
            " https://a.org/x", "ht\ttps://a.org/x")
        for (url in kept) {
            val html = markdownBodyHtml("[x]($url)")
            assertTrue("$url -> $html", html.contains("<a href=\"$url\">x</a>"))
        }
    }

    /** A character reference in the markdown is text, so it cannot spell a scheme. */
    @Test
    fun `a character reference cannot spell a scheme`() {
        val html = markdownBodyHtml("[x](&#106;avascript:alert(1))")

        // The browser reads the href as `&#106;avascript:alert(1`: a relative URL
        assertEquals("<p><a href=\"&amp;#106;avascript:alert&#40;1\">x</a>)\n</p>", html)
    }

    /** A colon before any `/`, `?` or `#` of the URL the browser reads names a scheme. */
    @Test
    fun `a scheme is found in the URL as the browser reads it`() {
        // Escaped, the quote is `&#39;`, whose `#` would hide the colon
        assertEquals("<p>x\n</p>", markdownBodyHtml("[x]('a:b)"))
    }

    @Test
    fun `an ampersand in a URL is escaped in the attribute`() {
        assertEquals(
            "<p><a href=\"https://e.org/a?b=1&amp;c=2\">s</a>\n</p>",
            markdownBodyHtml("[s](https://e.org/a?b=1&c=2)")
        )
    }

    @Test
    fun `a quote in a URL or anchor cannot end the attribute`() {
        val hostile = listOf(
            "[x](https://a.org/\" onclick=\"alert(1))",
            "![x](https://a.org/\" onload=\"alert(1))",
            "<!-- anchor:x\" onmouseover=\"alert(1) -->",
            "<!-- anchor:x\" onmouseover=\"alert(1) -->\n\n### Heading",
            "[x](https://a.org/' onclick='alert(1))",
        )
        for (markdown in hostile) {
            assertOnlyOwnMarkup(markdown)
        }
    }

    /**
     * The renderer's passes run one after another over the same text: a later
     * pass must never reach into the markup an earlier one wrote. Each of these
     * broke out of an attribute while the passes saw each other's tags.
     */
    @Test
    fun `no pass reaches into the markup another wrote`() {
        val hostile = listOf(
            // A link spanning into the image the image pass wrote
            "![x[y](http://a.com/)](http://b.com/ onerror=alert(1)//)",
            "[t](/![a](http://u onerror=alert(1)//)",
            // A link spanning into the anchor the anchor pass wrote
            "[t](/\n<!-- anchor:a onfocus=alert(1) autofocus x -->\n### x)",
            "<!-- anchor:[x -->\n\n](http://ok onmouseover=alert(1) x)",
            // Emphasis, tables and paragraphs inside attribute values
            "<!-- anchor:*a -->\n\n*b onmouseover=alert(1)*",
            "| [t](http://a|b onmouseover=alert(1)) | c |\n| --- | --- |",
            "![a\n\nb](http://u)",
            "![x |\n| --- |\n| y\" onerror=\"alert(1) |](http://u)",
        )
        for (markdown in hostile) {
            assertOnlyOwnMarkup(markdown)
        }
    }

    /**
     * An image's alt text can hold markup an earlier pass wrote: an anchor's
     * element, with its quotes, which must not end the alt attribute.
     */
    @Test
    fun `an anchor inside alt text cannot end the attribute`() {
        assertOnlyOwnMarkup("![x\n<!-- anchor:a onerror=alert(1) b -->\n](http://u)")
    }

    /**
     * Every attribute value encodes what a later pass matches on, and what would
     * end it, so the value reaches the page as it was written.
     */
    @Test
    fun `an attribute value hides every character a later pass matches on`() {
        assertEquals(
            "<p><span id=\"a&#91;b&#93;c&#40;d&#41;e&#42;f&#124;g\"></span>\n</p>",
            markdownBodyHtml("<!-- anchor:a[b]c(d)e*f|g -->")
        )
        assertEquals(
            "<p><figure><img src=\"http://u\" alt=\"&lt;strong&gt;a&lt;/strong&gt;&#10;&#10;b\" " +
                "onerror=\"this.onerror=null; tryAlternativeExtensions(this);\" loading=\"lazy\"></figure>\n</p>",
            markdownBodyHtml("![**a**\n\nb](http://u)")
        )
    }

    /** A URL stops at markup an earlier pass wrote, rather than swallowing it into an attribute. */
    @Test
    fun `a URL cannot swallow an element another pass wrote`() {
        val image = markdownBodyHtml("[t](/![a](http://u)")
        assertTrue(image, image.contains("<img src=\"http://u\" alt=\"a\""))

        val heading = markdownBodyHtml("![a](/\n<!-- anchor:b -->\n### H)")
        assertTrue(heading, heading.contains("<h3 id=\"b\">H)</h3>"))
    }

    /** The hostile corpus, rendered as a whole page too. */
    @Test
    fun `the page carries no markup but its own`() {
        val page = markdownToBasicHtml("<script>alert(1)</script>\n\n[x](javascript:alert(1))")
        val body = page.substringAfter("<body>")

        assertFalse(body, body.contains("<script"))
        assertFalse(body, body.contains("javascript:"))
    }

    // The oracle: the start tags of the output, read as an HTML tokenizer reads them

    /** A start tag: its name and its attributes, values decoded. */
    private data class StartTag(val name: String, val attributes: List<Pair<String, String>>)

    /**
     * Assert that [markdown] renders to no tag, attribute or link scheme but
     * those the renderer writes itself.
     */
    private fun assertOnlyOwnMarkup(markdown: String) {
        val html = markdownBodyHtml(markdown)
        for (tag in startTags(html)) {
            assertTrue("<${tag.name}> in $html", tag.name in OWN_TAGS)
            for ((name, value) in tag.attributes) {
                assertTrue("$name on <${tag.name}> in $html", name in OWN_ATTRIBUTES)
                if (name == "onerror") assertEquals(html, OWN_ONERROR, value)
                if (name == "href" || name == "src") {
                    val url = value.filterNot { it == '\t' || it == '\n' || it == '\r' }
                        .trim { it <= ' ' }.lowercase()
                    val scheme = Regex("^([a-z][a-z0-9+.-]*):").find(url)?.groupValues?.get(1)
                    assertTrue("$name=$value in $html", scheme == null || scheme == "http" || scheme == "https")
                }
            }
        }
    }

    /** The start tags in [html], with their attributes; end tags and comments are skipped. */
    private fun startTags(html: String): List<StartTag> {
        val tags = mutableListOf<StartTag>()
        var i = 0
        while (i < html.length) {
            if (html.startsWith("<!--", i)) {
                val end = html.indexOf("-->", i + 4)
                i = if (end < 0) html.length else end + 3
                continue
            }
            val isTag = html[i] == '<' && i + 1 < html.length &&
                (html[i + 1].isLetter() || (html[i + 1] == '/' && i + 2 < html.length && html[i + 2].isLetter()))
            if (!isTag) {
                i++
                continue
            }
            val isEnd = html[i + 1] == '/'
            i += if (isEnd) 2 else 1
            val nameStart = i
            while (i < html.length && !html[i].isWhitespace() && html[i] != '/' && html[i] != '>') i++
            val name = html.substring(nameStart, i).lowercase()
            val attributes = mutableListOf<Pair<String, String>>()
            while (i < html.length && html[i] != '>') {
                if (html[i].isWhitespace() || html[i] == '/') {
                    i++
                    continue
                }
                val attrStart = i
                i++
                while (i < html.length && !html[i].isWhitespace() && html[i] != '/' && html[i] != '>' && html[i] != '=') i++
                val attrName = html.substring(attrStart, i).lowercase()
                while (i < html.length && html[i].isWhitespace()) i++
                var value = ""
                if (i < html.length && html[i] == '=') {
                    i++
                    while (i < html.length && html[i].isWhitespace()) i++
                    if (i < html.length && (html[i] == '"' || html[i] == '\'')) {
                        val quote = html[i]
                        val end = html.indexOf(quote, i + 1).let { if (it < 0) html.length else it }
                        value = html.substring(i + 1, end)
                        i = minOf(end + 1, html.length)
                    } else {
                        val valueStart = i
                        while (i < html.length && !html[i].isWhitespace() && html[i] != '>') i++
                        value = html.substring(valueStart, i)
                    }
                }
                attributes += attrName to decodeReferences(value)
            }
            i++
            if (!isEnd) tags += StartTag(name, attributes)
        }
        return tags
    }

    /** [value] with its character references decoded, as a browser decodes an attribute. */
    private fun decodeReferences(value: String): String =
        Regex("&(#[0-9]+|#[xX][0-9a-fA-F]+|amp|lt|gt|quot|apos);").replace(value) { match ->
            val ref = match.groupValues[1]
            when {
                ref.startsWith("#x") || ref.startsWith("#X") -> ref.drop(2).toInt(HEX_RADIX).toChar().toString()
                ref.startsWith("#") -> ref.drop(1).toInt().toChar().toString()
                else -> NAMED_REFERENCES.getValue(ref)
            }
        }

    private companion object {
        /** The radix of a hexadecimal character reference. */
        const val HEX_RADIX = 16

        val NAMED_REFERENCES = mapOf("amp" to "&", "lt" to "<", "gt" to ">", "quot" to "\"", "apos" to "'")

        /** The tags the renderer writes. */
        val OWN_TAGS = setOf(
            "p", "h1", "h2", "h3", "h4", "h5", "h6", "strong", "em", "figure", "img", "a", "span",
            "table", "thead", "tbody", "tr", "th", "td"
        )

        /** The attributes the renderer writes. */
        val OWN_ATTRIBUTES = setOf("id", "href", "src", "alt", "onerror", "loading")

        /** The one event handler the renderer writes: the figure's image-extension fallback. */
        const val OWN_ONERROR = "this.onerror=null; tryAlternativeExtensions(this);"
    }
}
