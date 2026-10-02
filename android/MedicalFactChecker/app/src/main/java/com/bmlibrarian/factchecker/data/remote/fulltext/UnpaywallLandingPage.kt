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

package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.util.Constants
import java.net.URI
import java.net.URISyntaxException
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull

/**
 * What an Unpaywall answer offers the PDF tier.
 *
 * At most one is set: a PDF URL is tried as it is, and a landing page is read
 * for the PDF it declares only when no location offers a PDF URL.
 *
 * @property pdfUrl The first location's `url_for_pdf`, best location first
 * @property landingPage The page to read when no location has a `url_for_pdf`.
 *   Never a PDF itself: only a page that may declare one
 */
data class UnpaywallChoice(
    val pdfUrl: String? = null,
    val landingPage: String? = null
)

/**
 * Which URL an Unpaywall answer offers, and the PDF a landing page declares (#464).
 *
 * Unpaywall sets a location's `url` to `url_for_pdf` when it has one and to the
 * landing page when it does not, so `url` is never a PDF that `url_for_pdf` did
 * not already name. Treating it as one downloaded an HTML page as the article.
 * A landing page usually declares its PDF in a Highwire Press tag,
 * `<meta name="citation_pdf_url" content="...">`, which [citationPdfUrl] reads.
 *
 * Pure functions, a port of Python's `oa_landing_page` module, pinned with the
 * Python and Swift versions by
 * `doc/cross_platform/fulltext_parity/unpaywall_landing_page.json`.
 */
object UnpaywallLandingPage {

    /**
     * One `<meta ...>` tag. A `>` inside a quoted value ends it early, which no
     * URL needs: it would be percent-encoded.
     */
    private val META_TAG = Regex("""<meta\b[^>]*>""", RegexOption.IGNORE_CASE)

    /**
     * One attribute: its name (group 1), then a double-quoted (2), single-quoted
     * (3) or unquoted (4) value.
     */
    private val ATTRIBUTE = Regex("""([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))""")

    /** A URL's scheme (group 1), per RFC 3986 section 3.1. */
    private val SCHEME = Regex("""^([A-Za-z][A-Za-z0-9+.-]*):""")

    /**
     * The `..` segments at the start of an absolute path, each of which climbs
     * above the root: `/../../a.pdf` matches `/../..`.
     */
    private val LEADING_PARENT_SEGMENTS = Regex("""^(?:/\.\.)+(?=/|$)""")

    /** The path of a URL whose path is the root. */
    private const val ROOT_PATH = "/"

    /** One character reference: `&#38;`, `&#x26;` or a named one such as `&amp;`. */
    private val CHARACTER_REFERENCE = Regex("""&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);""")

    /** The marker that opens a numeric character reference (`&#...;`). */
    private const val NUMERIC_REFERENCE_PREFIX = "#"

    /** The marker that makes a numeric character reference hexadecimal (`&#x...;`). */
    private const val HEX_REFERENCE_MARKER = 'x'

    /** Radix of a hexadecimal character reference. */
    private const val HEX_RADIX = 16

    /** Radix of a decimal character reference. */
    private const val DECIMAL_RADIX = 10

    /**
     * What a numeric reference to no character decodes to, as browsers and
     * Python's `html.unescape` do: U+FFFD REPLACEMENT CHARACTER.
     */
    private const val REPLACEMENT_CHARACTER = "\uFFFD"

    /**
     * The named references an attribute value is decoded for. A URL needs only
     * these; any other name is left as written.
     */
    private val NAMED_REFERENCES = mapOf(
        "amp" to "&",
        "lt" to "<",
        "gt" to ">",
        "quot" to "\"",
        "apos" to "'",
        "nbsp" to "\u00A0"
    )

    /**
     * Decide which URL an Unpaywall answer offers.
     *
     * The locations are read best first: [UnpaywallResponse.best_oa_location],
     * then each of [UnpaywallResponse.oa_locations] in order. The first
     * non-blank `url_for_pdf` wins. Failing that, the first landing page
     * (`url_for_landing_page`, else `url`) is returned, never as a PDF URL, only
     * as a page that may declare one. Values are trimmed.
     *
     * @param response Unpaywall's decoded answer for one DOI
     * @return The PDF URL, the landing page, or neither
     */
    fun chooseUrl(response: UnpaywallResponse): UnpaywallChoice {
        val locations = listOfNotNull(response.best_oa_location) + response.oa_locations.orEmpty()
        locations.firstNotNullOfOrNull { present(it.url_for_pdf) }?.let { pdfUrl ->
            return UnpaywallChoice(pdfUrl = pdfUrl)
        }
        locations.firstNotNullOfOrNull { present(it.url_for_landing_page) ?: present(it.url) }?.let { page ->
            return UnpaywallChoice(landingPage = page)
        }
        return UnpaywallChoice()
    }

    /**
     * Return the PDF a landing page declares, or null when it declares none.
     *
     * Flow: every `<meta>` tag is read in document order; its attributes are
     * parsed ([attributes]); a tag whose `name` is not `citation_pdf_url`
     * (case-insensitively; `property=` is not `name=`) or whose `content` is
     * empty is passed over; the content is resolved against [pageUrl]
     * ([resolve]); the first result with an http(s) scheme is returned.
     *
     * @param html The landing page as served
     * @param pageUrl Where it was served from, after redirects: the base a
     *   relative URL resolves against
     * @return The absolute PDF URL, or null
     */
    fun citationPdfUrl(html: String, pageUrl: String): String? {
        for (tag in META_TAG.findAll(html)) {
            val attributes = attributes(tag.value)
            if (attributes["name"]?.lowercase() != Constants.CITATION_PDF_URL_META_NAME) continue
            val content = attributes["content"]
            if (content.isNullOrEmpty()) continue
            val resolved = resolve(pageUrl, content) ?: continue
            val scheme = schemeOf(resolved) ?: continue
            if (scheme.lowercase() in Constants.LANDING_PAGE_PDF_SCHEMES) return resolved
        }
        return null
    }

    /**
     * A string that names something, trimmed; null when it is null or blank.
     *
     * @param value A field from Unpaywall's answer
     * @return The trimmed value, or null
     */
    private fun present(value: String?): String? = value?.trim()?.takeIf { it.isNotEmpty() }

    /**
     * A tag's attributes: names lower-cased, values entity-decoded and trimmed.
     * The first of a repeated name wins, as in a browser.
     *
     * @param tag One `<meta ...>` tag
     * @return The attributes by lower-cased name
     */
    private fun attributes(tag: String): Map<String, String> {
        val attributes = mutableMapOf<String, String>()
        for (match in ATTRIBUTE.findAll(tag)) {
            val name = match.groupValues[1].lowercase()
            // Exactly one of the three value groups matched; an unmatched group is null
            val raw = (2..4).firstNotNullOf { match.groups[it]?.value }
            attributes.putIfAbsent(name, decodeEntities(raw).trim())
        }
        return attributes
    }

    /**
     * Decode the character references in an attribute value: numeric ones
     * (`&#38;`, `&#x26;`) and the named ones in [NAMED_REFERENCES]. An unknown
     * name is left as written; a number that names no character becomes
     * U+FFFD.
     *
     * @param value The value as written in the page
     * @return The value as a browser reads it
     */
    private fun decodeEntities(value: String): String =
        CHARACTER_REFERENCE.replace(value) { match ->
            val reference = match.groupValues[1]
            if (reference.startsWith(NUMERIC_REFERENCE_PREFIX)) {
                decodeNumericReference(reference.substring(NUMERIC_REFERENCE_PREFIX.length))
            } else {
                NAMED_REFERENCES[reference] ?: match.value
            }
        }

    /**
     * The character a numeric reference names.
     *
     * @param digits What follows `&#`: decimal digits, or `x` and hex digits
     * @return The character, or U+FFFD for a number that names none (zero, a
     *   surrogate, or beyond Unicode)
     */
    private fun decodeNumericReference(digits: String): String {
        val isHex = digits.firstOrNull()?.lowercaseChar() == HEX_REFERENCE_MARKER
        val codePoint = if (isHex) {
            digits.substring(1).toIntOrNull(HEX_RADIX)
        } else {
            digits.toIntOrNull(DECIMAL_RADIX)
        }
        val namesACharacter = codePoint != null && codePoint != 0 &&
            Character.isValidCodePoint(codePoint) &&
            Character.getType(codePoint) != Character.SURROGATE.toInt()
        return if (namesACharacter) String(Character.toChars(codePoint!!)) else REPLACEMENT_CHARACTER
    }

    /**
     * Resolve a reference against the page it was found on (RFC 3986).
     *
     * [java.net.URI.resolve] does the work, with two repairs: a base with an
     * authority and an empty path (`https://host`) is given the path `/`, since
     * older `URI.resolve` implementations (JDK-4666701, fixed in recent JDKs but
     * not necessarily in the runtime an Android device ships) run the host into
     * the relative path, `https://hosta.pdf`; and a
     * reference `URI` refuses to parse (an unencoded space, say, which some
     * repositories emit) is resolved by OkHttp's lenient parser instead, which
     * percent-encodes it, rather than losing a PDF the page does declare. A
     * `..` that climbs above the root is then dropped
     * ([withoutDotSegmentsAboveRoot]).
     *
     * @param base The page's URL
     * @param reference The declared URL, absolute or relative
     * @return The absolute URL, or null when neither parser can resolve it
     */
    private fun resolve(base: String, reference: String): String? =
        try {
            var baseUri = URI(base)
            if (baseUri.rawAuthority != null && baseUri.rawPath.isNullOrEmpty()) {
                // Rebuilt as text: URI's multi-part constructors re-quote a '%'
                val query = baseUri.rawQuery?.let { "?$it" }.orEmpty()
                baseUri = URI("${baseUri.scheme}://${baseUri.rawAuthority}/$query")
            }
            withoutDotSegmentsAboveRoot(baseUri.resolve(URI(reference)))
        } catch (e: URISyntaxException) {
            base.toHttpUrlOrNull()?.resolve(reference)?.toString()
        }

    /**
     * A resolved URL with the `..` segments that climb above its root removed,
     * as RFC 3986 section 5.2.4 removes them: `https://host/../../a.pdf` becomes
     * `https://host/a.pdf`. `java.net.URI` keeps them (it follows RFC 2396 here),
     * which Python and Swift do not.
     *
     * Rebuilt as text from the raw parts, so nothing already percent-encoded is
     * encoded again. A URL without an authority (`javascript:...`) or with no such
     * segment is returned as it is.
     *
     * @param resolved The URL [URI.resolve] produced
     * @return The URL as an RFC 3986 resolver writes it
     */
    private fun withoutDotSegmentsAboveRoot(resolved: URI): String {
        val path = resolved.rawPath
        val authority = resolved.rawAuthority
        if (authority == null || path == null || !LEADING_PARENT_SEGMENTS.containsMatchIn(path)) {
            return resolved.toString()
        }
        val climbed = path.replaceFirst(LEADING_PARENT_SEGMENTS, "").ifEmpty { ROOT_PATH }
        val query = resolved.rawQuery?.let { "?$it" }.orEmpty()
        val fragment = resolved.rawFragment?.let { "#$it" }.orEmpty()
        return "${resolved.scheme}://$authority$climbed$query$fragment"
    }

    /**
     * The scheme of an absolute URL, as RFC 3986 spells one: a letter, then
     * letters, digits, `+`, `-` or `.`, ending at the first `:`.
     *
     * @param url A resolved URL
     * @return Its scheme as written, or null when it has none
     */
    private fun schemeOf(url: String): String? = SCHEME.find(url)?.groupValues?.get(1)
}
