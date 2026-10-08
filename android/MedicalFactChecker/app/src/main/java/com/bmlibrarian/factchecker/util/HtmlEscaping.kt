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

/**
 * The attributes whose value a browser follows or loads as a URL, by lower-case
 * name: the links and images our renderers write, and the few others that can
 * act on a URL.
 */
private val URL_ATTRIBUTES = setOf("href", "src", "xlink:href", "action", "formaction")

/**
 * A start tag: its name, then its attribute section, quoted values taken whole
 * so a `>` inside one does not end the tag. Possessive, so a long tag is
 * consumed in runs, without backtracking.
 */
private val START_TAG = Regex("""<([A-Za-z][^\s/>]*+)((?:"[^"]*+"|'[^']*+'|[^'">]++)*+)>""")

/**
 * One attribute in a tag's attribute section: the space before it, its name,
 * then, if it has one, `=` and the value, double-quoted, single-quoted or unquoted.
 */
private val ATTRIBUTE = Regex("""(\s*+)([^\s"'>/=]++)(?:\s*+=\s*+("[^"]*+"|'[^']*+'|[^\s>]++))?""")

/**
 * A character reference: decimal, hexadecimal or named; the semicolon optional,
 * as a browser reads a numeric one without it.
 */
private val CHARACTER_REFERENCE = Regex("&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);?")

/**
 * The named references that can change how a URL's scheme reads: the five
 * [escapeHtml] writes, their legacy upper-case forms, the colon, the tab and
 * line break a URL parser removes, and the characters that end a scheme.
 */
private val NAMED_REFERENCES = mapOf(
    "amp" to "&", "AMP" to "&",
    "lt" to "<", "LT" to "<",
    "gt" to ">", "GT" to ">",
    "quot" to "\"", "QUOT" to "\"",
    "apos" to "'",
    "colon" to ":",
    "Tab" to "\t",
    "NewLine" to "\n",
    "sol" to "/",
    "quest" to "?",
    "num" to "#"
)

/** The radix of a decimal character reference. */
private const val DECIMAL_RADIX = 10

/** The radix of a hexadecimal character reference. */
private const val HEX_RADIX = 16

/** What a browser reads a numeric reference to no valid character as. */
private const val REPLACEMENT_CHARACTER = '�'

/**
 * An attribute value as a browser reads it: every numeric character reference
 * decoded, and the named ones in [NAMED_REFERENCES]; any other left as it is.
 *
 * A reference this leaves undecoded can only make a URL look less safe to
 * [isSafeUrl] (its `&` and `;` inside a scheme), never safer.
 *
 * @param value The raw attribute value, without its quotes
 * @return The value as the browser hands it to the URL parser
 */
internal fun decodeCharacterReferences(value: String): String =
    CHARACTER_REFERENCE.replace(value) { match ->
        val name = match.groupValues[1]
        when {
            name.startsWith("#x") || name.startsWith("#X") -> codePointText(name.substring(2).toIntOrNull(HEX_RADIX))
            name.startsWith("#") -> codePointText(name.substring(1).toIntOrNull(DECIMAL_RADIX))
            else -> NAMED_REFERENCES[name] ?: match.value
        }
    }

/** The text of a numeric reference's code point; [REPLACEMENT_CHARACTER] for none, a surrogate or NUL. */
private fun codePointText(codePoint: Int?): String =
    if (codePoint == null || codePoint == 0 || codePoint > Character.MAX_CODE_POINT ||
        codePoint in Character.MIN_SURROGATE.code..Character.MAX_SURROGATE.code
    ) {
        REPLACEMENT_CHARACTER.toString()
    } else {
        String(Character.toChars(codePoint))
    }

/**
 * HTML with every URL attribute [isSafeUrl] refuses dropped, at the boundary
 * of the JavaScript-enabled WebView (#495).
 *
 * Each `href`, `src` (and the other [URL_ATTRIBUTES]) in a start tag is judged
 * by its value as the browser reads it ([decodeCharacterReferences]); one that
 * fails is removed with the space before it, so a `javascript:` link becomes
 * plain text inside its `<a>`
 * and an unsafe image loads nothing. The element and its text stay: no content
 * is removed. Attribute names in any case, and values double-quoted,
 * single-quoted or unquoted, are all read. Text outside tags is untouched.
 *
 * Every route into the viewer passes here: HTML stored by builds before #495,
 * whose links were written for any scheme, a fresh JATS render, and a figure
 * whose deposit path was written as-is.
 *
 * @param html The page body
 * @return The same HTML, less each unsafe URL attribute
 */
internal fun neutraliseUnsafeUrls(html: String): String =
    START_TAG.replace(html) { tag ->
        val attributes = tag.groupValues[2]
        val kept = ATTRIBUTE.replace(attributes) { attribute ->
            val quoted = attribute.groupValues[3]
            val unsafe = attribute.groupValues[2].lowercase() in URL_ATTRIBUTES && quoted.isNotEmpty() &&
                !isSafeUrl(decodeCharacterReferences(unquoted(quoted)))
            if (unsafe) "" else attribute.value
        }
        if (kept == attributes) tag.value else "<${tag.groupValues[1]}$kept>"
    }

/** An attribute value without the quotes around it, if it has them. */
private fun unquoted(value: String): String =
    if (value.length >= 2 && (value.first() == '"' || value.first() == '\'') && value.last() == value.first()) {
        value.substring(1, value.length - 1)
    } else {
        value
    }
