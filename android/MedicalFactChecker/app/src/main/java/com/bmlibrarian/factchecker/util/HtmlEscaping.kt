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

/**
 * Escape text for HTML, as element content or as a double- or single-quoted
 * attribute value.
 *
 * The five characters HTML gives meaning to are replaced by their character
 * references, `&` first so that no reference is escaped twice. The JATS→HTML
 * renderer and the stored-markdown renderer share this one escaper (#495).
 *
 * @param text The text to escape
 * @return The text with `&`, `<`, `>`, `"` and `'` escaped
 */
internal fun escapeHtml(text: String): String {
    return text
        .replace("&", "&amp;")
        .replace("<", "&lt;")
        .replace(">", "&gt;")
        .replace("\"", "&quot;")
        .replace("'", "&#39;")
}

/** The references [escapeHtml] writes, each with the character it stands for. */
private val ESCAPED_CHARACTERS = mapOf(
    "&amp;" to "&",
    "&lt;" to "<",
    "&gt;" to ">",
    "&quot;" to "\"",
    "&#39;" to "'"
)

/** Any one of the references in [ESCAPED_CHARACTERS]. */
private val ESCAPED_CHARACTER = Regex("&(?:amp|lt|gt|quot|#39);")

/**
 * Undo [escapeHtml]: the text it was given.
 *
 * Decodes the five references [escapeHtml] writes, in a single pass, so
 * `&amp;lt;` becomes `&lt;` and not `<`. Any other reference is left as it is.
 *
 * @param text Text [escapeHtml] produced
 * @return The text before escaping
 */
internal fun unescapeHtml(text: String): String =
    ESCAPED_CHARACTER.replace(text) { match -> ESCAPED_CHARACTERS.getValue(match.value) }

/** The only schemes a link or image may name; an anchor or a relative URL names none. */
private val SAFE_URL_SCHEMES = setOf("http", "https")

/**
 * Whether a URL may be written into an `href` or `src` of a page shown in the
 * JavaScript-enabled WebView: http, https, an anchor, or a relative URL (#495).
 *
 * Judged as a browser reads a URL: leading and trailing control characters and
 * spaces dropped, tabs and line breaks removed anywhere. A colon before any
 * `/`, `?` or `#` makes what precedes it a scheme, which must be http or https;
 * so `javascript:`, `data:`, `vbscript:` and the like, in any case, are refused.
 * The stored-markdown renderer and the JATS renderer's inline links both ask
 * this.
 *
 * @param url The URL as the browser will read it: unescaped text, not an
 *   attribute value with character references
 * @return True when the URL names no scheme, or http or https
 */
internal fun isSafeUrl(url: String): Boolean {
    val cleaned = url
        .filterNot { it == '\t' || it == '\n' || it == '\r' }
        .trim { it <= ' ' }
    val colon = cleaned.indexOf(':')
    if (colon < 0) return true
    val beforeColon = cleaned.substring(0, colon)
    if (beforeColon.any { it == '/' || it == '?' || it == '#' }) return true
    return beforeColon.lowercase() in SAFE_URL_SCHEMES
}
