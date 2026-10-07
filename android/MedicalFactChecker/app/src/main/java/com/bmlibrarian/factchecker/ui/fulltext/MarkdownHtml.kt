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

import com.bmlibrarian.factchecker.util.escapeHtml
import com.bmlibrarian.factchecker.util.isSafeUrl
import com.bmlibrarian.factchecker.util.unescapeHtml

/**
 * Convert basic markdown to an HTML page for display.
 *
 * This is a simple converter for basic markdown features.
 * For full markdown support, consider using a library like Markwon.
 *
 * @param markdown The stored markdown
 * @return A complete HTML page: [markdownBodyHtml] in the page's styles and scripts
 */
internal fun markdownToBasicHtml(markdown: String): String {
    val html = markdownBodyHtml(markdown)

    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0, maximum-scale=3.0, user-scalable=yes">
            <style>
                :root {
                    color-scheme: light dark;
                }

                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.6;
                    padding: 16px;
                    max-width: 100%;
                    margin: 0 auto;
                    color: var(--text-color);
                    background-color: var(--bg-color);
                }

                @media (prefers-color-scheme: dark) {
                    :root {
                        --text-color: #e0e0e0;
                        --bg-color: #1c1c1e;
                        --heading-color: #ffffff;
                        --link-color: #64B5F6;
                        --border-color: #444;
                        --table-header-bg: #2c2c2e;
                        --table-alt-bg: #252527;
                    }
                }

                @media (prefers-color-scheme: light) {
                    :root {
                        --text-color: #333;
                        --bg-color: #ffffff;
                        --heading-color: #1a1a1a;
                        --link-color: #1976D2;
                        --border-color: #ddd;
                        --table-header-bg: #f0f4f8;
                        --table-alt-bg: #fafafa;
                    }
                }

                h1 {
                    font-size: 1.6em;
                    color: var(--heading-color);
                    border-bottom: 2px solid var(--border-color);
                    padding-bottom: 8px;
                    margin-top: 0;
                }

                h2 {
                    font-size: 1.3em;
                    color: var(--heading-color);
                    margin-top: 1.5em;
                    border-bottom: 1px solid var(--border-color);
                    padding-bottom: 4px;
                }

                h3 { font-size: 1.15em; color: var(--heading-color); margin-top: 1.2em; }
                h4, h5, h6 { font-size: 1.05em; color: var(--heading-color); margin-top: 1em; }
                p { margin: 0.8em 0; }
                a { color: var(--link-color); text-decoration: none; }

                /* Table styling with horizontal scroll */
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin: 1em 0;
                    font-size: 0.9em;
                    display: block;
                    overflow-x: auto;
                    -webkit-overflow-scrolling: touch;
                }

                th, td {
                    border: 1px solid var(--border-color);
                    padding: 8px 12px;
                    text-align: left;
                    vertical-align: top;
                    min-width: 80px;
                }

                th { background-color: var(--table-header-bg); font-weight: 600; }
                tr:nth-child(even) { background-color: var(--table-alt-bg); }

                /* Figure styling */
                figure {
                    margin: 1.5em 0;
                    padding: 1em;
                    background-color: var(--table-alt-bg);
                    border-radius: 8px;
                    text-align: center;
                }

                figure img {
                    max-width: 100%;
                    height: auto;
                    display: block;
                    margin: 0 auto;
                }

                figcaption {
                    margin-top: 0.5em;
                    font-size: 0.9em;
                }
            </style>
            <script>
                // Try alternative image extensions when loading fails
                function tryAlternativeExtensions(img) {
                    var src = img.src;
                    var extensions = ['.jpg', '.jpeg', '.gif', '.png', '.svg'];
                    var currentExt = src.match(/\.[^.]+$/);
                    if (!currentExt) return;

                    var base = src.slice(0, -currentExt[0].length);
                    var tryIndex = parseInt(img.getAttribute('data-ext-try') || '0');
                    var origExt = (img.getAttribute('data-orig-ext') || currentExt[0]).toLowerCase();
                    if (tryIndex === 0) {
                        img.setAttribute('data-orig-ext', currentExt[0].toLowerCase());
                        origExt = currentExt[0].toLowerCase();
                    }

                    while (tryIndex < extensions.length) {
                        if (extensions[tryIndex].toLowerCase() !== origExt) {
                            img.setAttribute('data-ext-try', tryIndex + 1);
                            img.onerror = function() { tryAlternativeExtensions(this); };
                            img.src = base + extensions[tryIndex];
                            return;
                        }
                        tryIndex++;
                    }

                    img.onerror = null;
                    img.alt = 'Figure image unavailable';
                    img.style.display = 'none';
                }

                // Handle anchor link clicks for internal navigation
                document.addEventListener('click', function(e) {
                    var target = e.target;
                    while (target && target.tagName !== 'A') {
                        target = target.parentElement;
                    }
                    if (target && target.getAttribute('href') && target.getAttribute('href').startsWith('#')) {
                        e.preventDefault();
                        var anchorId = target.getAttribute('href').substring(1);
                        var element = document.getElementById(anchorId);
                        if (element) {
                            element.scrollIntoView({ behavior: 'smooth', block: 'start' });
                        }
                    }
                });
            </script>
        </head>
        <body>
            $html
        </body>
        </html>
    """.trimIndent()
}

/**
 * Convert basic markdown to the HTML of a page's body.
 *
 * The markdown is article text, and untrusted: XML character references in a
 * JATS deposit (`&lt;script&gt;`) are literal `<script>` once parsed, and the
 * page is shown in a WebView that runs JavaScript (#495). So the markdown is
 * HTML-escaped first, and every pass after that works on the escaped text: the
 * only markup in the result is the markup written here.
 *
 * Two rules keep the passes from reaching into each other's markup, since each
 * runs over what the earlier ones wrote:
 * - Every attribute value taken from the text is written by [attributeValue], which also encodes
 *   the characters a later pass matches on (`[`, `]`, `(`, `)`, `*`, `|`, line
 *   breaks), so no later pass finds anything to match inside one.
 * - A link's or image's URL cannot contain `<`, `>` or `"`. Escaped article
 *   text has none, so a URL never runs into a tag an earlier pass wrote.
 *
 * Links and images keep their URL only when [isSafeUrl] allows it, judged on
 * the URL the browser reads (the captured URL, unescaped): http, https, an
 * anchor, or a relative URL. Any other scheme (`javascript:`, `data:`, …)
 * leaves the link's text, or the image's alt text, alone.
 *
 * The one raw-HTML construct the JATS→markdown converter writes, the
 * `<!-- anchor:id -->` comment ahead of a figure or table, is recognised in its
 * escaped form and becomes an element with that `id`.
 *
 * @param markdown The stored markdown
 * @return The body's HTML
 */
internal fun markdownBodyHtml(markdown: String): String {
    var html = escapeHtml(markdown)

    // Anchor comments, followed by a heading or standalone
    html = ANCHORED_HEADING.replace(html) { match ->
        "<h3 id=\"${attributeValue(match.groupValues[1])}\">${match.groupValues[2]}</h3>"
    }
    html = ANCHOR.replace(html) { match -> "<span id=\"${attributeValue(match.groupValues[1])}\"></span>" }

    // Headers (process remaining ones not already converted from anchors)
    html = html.replace(Regex("^###### (.+)$", RegexOption.MULTILINE), "<h6>$1</h6>")
    html = html.replace(Regex("^##### (.+)$", RegexOption.MULTILINE), "<h5>$1</h5>")
    html = html.replace(Regex("^#### (.+)$", RegexOption.MULTILINE), "<h4>$1</h4>")
    html = html.replace(Regex("^### (.+)$", RegexOption.MULTILINE), "<h3>$1</h3>")
    html = html.replace(Regex("^## (.+)$", RegexOption.MULTILINE), "<h2>$1</h2>")
    html = html.replace(Regex("^# (.+)$", RegexOption.MULTILINE), "<h1>$1</h1>")

    // Bold and italic
    html = html.replace(Regex("\\*\\*(.+?)\\*\\*"), "<strong>$1</strong>")
    html = html.replace(Regex("\\*(.+?)\\*"), "<em>$1</em>")

    // Images with onerror handler for fallback (must be processed BEFORE links
    // to prevent the link regex from matching ![alt](url) as [alt](url))
    html = IMAGE.replace(html) { match ->
        val (alt, url) = match.destructured
        if (isSafeUrl(unescapeHtml(url))) {
            "<figure><img src=\"${attributeValue(url)}\" alt=\"${attributeValue(alt)}\" " +
                "onerror=\"$FIGURE_ONERROR\" loading=\"lazy\"></figure>"
        } else {
            alt
        }
    }

    // Links
    html = LINK.replace(html) { match ->
        val (text, url) = match.destructured
        if (isSafeUrl(unescapeHtml(url))) "<a href=\"${attributeValue(url)}\">$text</a>" else text
    }

    // Markdown tables
    html = convertMarkdownTables(html)

    // Paragraphs (double newlines)
    html = html.replace(Regex("\n\n+"), "</p><p>")
    html = "<p>$html</p>"

    // Clean up empty paragraphs
    html = html.replace("<p></p>", "")
    html = html.replace("<p>\n</p>", "")

    return html
}

/**
 * The longest anchor id recognised. The id's match is bounded so that a line
 * of anchor openings with no `-->` costs time in proportion to its length, not
 * its square: an unbounded lazy match runs to the end of the line from every
 * opening (#495). JATS ids are short; a longer "id" stays text.
 */
private const val ANCHOR_ID_MAX_LENGTH = 256

/**
 * The longest link or image URL recognised, bounded for the same reason as
 * [ANCHOR_ID_MAX_LENGTH]: many `[a](` with no `)` would otherwise each scan to
 * the end of the text.
 */
private const val LINK_URL_MAX_LENGTH = 2048

/** An escaped `<!-- anchor:id -->` comment and the `###` heading that follows it. */
private val ANCHORED_HEADING =
    Regex("&lt;!-- anchor:([^\\n]{1,$ANCHOR_ID_MAX_LENGTH}?) --&gt;\\s*\\n\\s*### (.+)")

/** An escaped `<!-- anchor:id -->` comment standing alone. */
private val ANCHOR = Regex("&lt;!-- anchor:([^\\n]{1,$ANCHOR_ID_MAX_LENGTH}?) --&gt;")

/**
 * `![alt](url)`, its URL free of markup another pass wrote. The alt text holds
 * no `[`, so a run of `![` with no `]` is scanned once, not once per opening.
 */
private val IMAGE = Regex("!\\[([^\\[\\]]*)]\\(([^)<>\"]{1,$LINK_URL_MAX_LENGTH})\\)")

/**
 * `[text](url)`, its URL free of markup another pass wrote. The text holds no
 * `[` (the innermost brackets are the link, as in CommonMark), so a run of `[`
 * with no `]` is scanned once, not once per opening.
 */
private val LINK = Regex("\\[([^\\[\\]]+)]\\(([^)<>\"]{1,$LINK_URL_MAX_LENGTH})\\)")

/** The figure image's fallback to other extensions, the one script an element carries. */
private const val FIGURE_ONERROR = "this.onerror=null; tryAlternativeExtensions(this);"

/**
 * The characters a later pass matches on, with the references that stand for
 * them in an attribute value, plus the three that would end the attribute or
 * the tag. `&` is already escaped in the text an attribute value is taken from.
 */
private val ATTRIBUTE_REFERENCES = mapOf(
    '"' to "&quot;",
    '<' to "&lt;",
    '>' to "&gt;",
    '[' to "&#91;",
    ']' to "&#93;",
    '(' to "&#40;",
    ')' to "&#41;",
    '*' to "&#42;",
    '|' to "&#124;",
    '\n' to "&#10;",
    '\r' to "&#13;"
)

/**
 * An attribute value from escaped text: inert inside its double quotes, and
 * invisible to every later pass.
 *
 * @param escaped Text already passed through [escapeHtml]
 * @return The value to write between double quotes
 */
private fun attributeValue(escaped: String): String = buildString {
    for (char in escaped) append(ATTRIBUTE_REFERENCES[char] ?: char)
}

/**
 * Convert markdown tables to HTML tables.
 */
private fun convertMarkdownTables(markdown: String): String {
    val lines = markdown.lines()
    val result = StringBuilder()
    var i = 0

    while (i < lines.size) {
        val line = lines[i]

        // Check if this is a table row (starts with |)
        if (line.trim().startsWith("|") && line.trim().endsWith("|")) {
            // Start of a potential table
            val tableLines = mutableListOf<String>()
            tableLines.add(line)
            i++

            // Collect all table lines
            while (i < lines.size) {
                val nextLine = lines[i].trim()
                if (nextLine.startsWith("|") && nextLine.endsWith("|")) {
                    tableLines.add(nextLine)
                    i++
                } else {
                    break
                }
            }

            // Convert table if we have at least a header and separator
            if (tableLines.size >= 2) {
                result.append(convertTableLinesToHtml(tableLines))
            } else {
                tableLines.forEach { result.appendLine(it) }
            }
        } else {
            result.appendLine(line)
            i++
        }
    }

    return result.toString()
}

/**
 * Convert markdown table lines to HTML table.
 */
private fun convertTableLinesToHtml(lines: List<String>): String {
    if (lines.size < 2) return lines.joinToString("\n")

    val html = StringBuilder()
    html.append("<table>")

    // Check if second line is separator
    val hasSeparator = lines.size > 1 && lines[1].contains("---")
    val headerRow = parseTableRow(lines[0])
    val dataRows = if (hasSeparator) lines.drop(2) else lines.drop(1)

    // Header
    if (headerRow.isNotEmpty()) {
        html.append("<thead><tr>")
        headerRow.forEach { cell ->
            html.append("<th>${cell.trim()}</th>")
        }
        html.append("</tr></thead>")
    }

    // Body
    if (dataRows.isNotEmpty()) {
        html.append("<tbody>")
        dataRows.forEach { line ->
            if (!line.contains("---")) { // Skip separator lines
                val cells = parseTableRow(line)
                html.append("<tr>")
                cells.forEach { cell ->
                    html.append("<td>${cell.trim()}</td>")
                }
                html.append("</tr>")
            }
        }
        html.append("</tbody>")
    }

    html.append("</table>")
    return html.toString()
}

/**
 * Parse a markdown table row into cells.
 */
private fun parseTableRow(line: String): List<String> {
    var content = line.trim()
    if (content.startsWith("|")) content = content.drop(1)
    if (content.endsWith("|")) content = content.dropLast(1)
    return content.split("|").map { it.trim().replace("\\|", "|") }
}
