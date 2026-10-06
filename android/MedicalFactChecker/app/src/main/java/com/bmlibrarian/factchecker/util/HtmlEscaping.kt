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
