/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.put
import kotlinx.serialization.json.putJsonObject

/**
 * A failed source is not an empty one (#252, the Android half of #247).
 *
 * Pure functions that carry a search failure to the reader: they build the
 * [RetrievalShortfall]s a search records, turn them into the notice, the
 * Methodology line and the failure message the user sees, and keep them in a
 * session. The sentences are the contract's
 * (`doc/cross_platform/search_failure_reporting.md`), shared verbatim with
 * Python's `search_failures.py`; Python runs no alternative queries, so it
 * writes none of their clauses.
 */
object SearchFailureReporting {

    /** Opens the notice that precedes whatever an incomplete search produced. */
    private const val NOTICE_OPENING = "> **Incomplete search:** "

    /** The notice's opening as plain text, its block-quote and bold markup left out. */
    private const val NOTICE_PLAIN_OPENING = "Incomplete search: "

    /**
     * The mark Android's history list shows beside a verdict whose search was
     * incomplete, where the report's notice is not shown and nothing names what failed.
     */
    const val INCOMPLETE_REPORT_MARK = "${NOTICE_PLAIN_OPENING}the report rests only on the records that were retrieved."

    /** Separates the notice from the text it precedes. */
    private const val NOTICE_SEPARATOR = "\n\n"

    /** Separates the clauses of several shortfalls. */
    private const val CLAUSE_SEPARATOR = "; "

    // Persisted keys and provider values. The stored strings are the contract's:
    // never rename one, and never derive a provider from SearchProvider's own names.
    private const val KEY_PROVIDER = "provider"
    private const val KEY_FAILURE = "failure"
    private const val KEY_KIND = "kind"
    private const val KEY_STATUS_CODE = "status_code"
    private const val KEY_RECORDS_MISSING = "records_missing"
    private const val KEY_QUERY = "query"
    private const val STORED_PUBMED = "pubmed"
    private const val STORED_EUROPE_PMC = "europepmc"

    /** Matches a JSON number that is a whole number, sign included. */
    private val WHOLE_NUMBER = Regex("-?[0-9]+")

    private const val RATE_LIMIT_ADVICE =
        "The service is limiting how often it can be searched: wait a minute and try again."
    private const val PUBMED_KEY_ADVICE = "An NCBI API key, set in Settings, raises PubMed's limit."
    private const val PUBMED_REFUSED_KEY_ADVICE =
        "If an NCBI API key is set in Settings, check that it is correct: " +
            "PubMed refuses a request whose key it does not accept."
    private const val SERVICE_ERROR_ADVICE =
        "If it happens again, rephrase the question: the service may be unable to process the query."
    private const val CONNECTIVITY_ADVICE = "Check the internet connection and try again."
    private const val FALLBACK_ADVICE = "Try again later."

    /**
     * What NCBI answers a request whose API key it does not accept (400, checked
     * live for #243); 401 and 403 are refusals of the same kind.
     */
    private val REFUSED_KEY_STATUSES = setOf(Constants.HTTP_BAD_REQUEST, Constants.HTTP_UNAUTHORIZED, Constants.HTTP_FORBIDDEN)

    // ==================== Building shortfalls ====================

    /**
     * Record records a failure left out, if it left any out.
     *
     * A shortfall with nothing missing is not recorded: it would tell the user a
     * complete search was incomplete. Records missing without a reason are
     * recorded as a failed request: the count degrades, it is never dropped.
     *
     * @param provider The source, PubMed or Europe PMC
     * @param failure Why records are missing, or null when no reason was kept
     * @param recordsMissing How many records are missing
     * @return One shortfall, or none when nothing is missing
     */
    fun shortfallsForMissingRecords(
        provider: SearchProvider,
        failure: RequestFailure?,
        recordsMissing: Int
    ): List<RetrievalShortfall> {
        if (recordsMissing < 1) return emptyList()
        val reason = failure ?: RequestFailure(RequestFailureKind.REQUEST_FAILED)
        return listOf(RetrievalShortfall(provider, reason, recordsMissing))
    }

    /**
     * Report the same failure of the same source once, its counts added.
     *
     * A session that meets one failure page after page, or alternative query
     * after alternative query, would otherwise repeat one clause each time.
     *
     * @param shortfalls What a search is missing, in the order it was recorded
     * @return The shortfalls in first-seen order. Those naming the same source,
     *   failure and query have their counts added, unless the sum is more than a
     *   count holds: then they stay apart, so no count is cut short. A source that
     *   could not be searched at all (no count) is never merged into a count, and
     *   is reported once for each failure and query however often it failed.
     */
    fun combinedShortfalls(shortfalls: List<RetrievalShortfall>): List<RetrievalShortfall> {
        val combined = mutableListOf<RetrievalShortfall>()
        for (shortfall in shortfalls) {
            val index = combined.indexOfFirst { earlier ->
                earlier.provider == shortfall.provider &&
                    earlier.failure == shortfall.failure &&
                    earlier.query == shortfall.query &&
                    countsCombine(earlier.recordsMissing, shortfall.recordsMissing)
            }
            if (index < 0) {
                combined.add(shortfall)
                continue
            }
            // A source that could not be searched is already reported
            val earlierMissing = combined[index].recordsMissing ?: continue
            combined[index] = combined[index].copy(recordsMissing = earlierMissing + checkNotNull(shortfall.recordsMissing))
        }
        return combined
    }

    /**
     * Whether two shortfalls of the same source, failure and query read as one clause.
     *
     * @param earlier The count already reported, or null for a source not searched
     * @param later The count to report, or null for a source not searched
     * @return True for two sources not searched, or two counts whose sum a count
     *   can hold; false when one has a count and the other has none
     */
    private fun countsCombine(earlier: Int?, later: Int?): Boolean =
        if (earlier == null || later == null) {
            earlier == later
        } else {
            earlier.toLong() + later <= Int.MAX_VALUE
        }

    // ==================== Telling the reader ====================

    /**
     * Join every shortfall's clause, in order.
     *
     * @param shortfalls What the search is missing
     * @return The clauses separated by semicolons, or "" when there are none
     */
    fun describeSearchShortfalls(shortfalls: List<RetrievalShortfall>): String =
        shortfalls.joinToString(CLAUSE_SEPARATOR) { it.describe() }

    /**
     * Build the notice that precedes whatever an incomplete search produced.
     *
     * @param shortfalls What the search is missing
     * @return A Markdown block quote, or "" when the search was complete, so a
     *   complete search never reads as a qualified one
     */
    fun formatSearchShortfallNotice(shortfalls: List<RetrievalShortfall>): String {
        if (shortfalls.isEmpty()) return ""
        return "$NOTICE_OPENING${describeSearchShortfalls(shortfalls)}. " +
            "Everything below rests only on the records that were retrieved."
    }

    /**
     * Put the incomplete-search notice in front of text a reader will see.
     *
     * @param text A report, or a message standing in for one
     * @param shortfalls What the search behind it is missing
     * @return The notice, a blank line and the text; or the text unchanged when
     *   the search was complete
     */
    fun withSearchShortfallNotice(text: String, shortfalls: List<RetrievalShortfall>): String {
        val notice = formatSearchShortfallNotice(shortfalls)
        return if (notice.isEmpty()) text else "$notice$NOTICE_SEPARATOR$text"
    }

    /**
     * Separate the incomplete-search notice from the text behind it.
     *
     * For a renderer that draws the notice ahead of what it shows before the
     * report's own text, such as the verdict: the notice is moved, never
     * dropped.
     *
     * @param text A report, with or without the notice
     * @return The notice as [withSearchShortfallNotice] wrote it and the text
     *   after it; or null and the text unchanged when it does not open with one
     */
    fun splitSearchShortfallNotice(text: String): Pair<String?, String> {
        if (!text.startsWith(NOTICE_OPENING)) return null to text
        val separator = text.indexOf(NOTICE_SEPARATOR)
        if (separator < 0) return null to text
        return text.substring(0, separator) to text.substring(separator + NOTICE_SEPARATOR.length)
    }

    /**
     * Render a notice as plain text, for a surface that draws no Markdown.
     *
     * @param notice A notice from [formatSearchShortfallNotice]
     * @return The same sentence without its block-quote and bold markup
     */
    fun plainNotice(notice: String): String =
        if (notice.startsWith(NOTICE_OPENING)) NOTICE_PLAIN_OPENING + notice.removePrefix(NOTICE_OPENING) else notice

    /**
     * Separate the incomplete-search notice from the text behind it, the notice as plain text.
     *
     * For a surface that draws the notice ahead of the verdict and draws no
     * Markdown for it: the report screen, the PDF and the shared text.
     *
     * @param text A report, with or without the notice
     * @return The notice as [plainNotice] renders it and the text after it; or
     *   null and the text unchanged when it does not open with one
     */
    fun splitPlainSearchShortfallNotice(text: String): Pair<String?, String> {
        val (notice, body) = splitSearchShortfallNotice(text)
        return notice?.let(::plainNotice) to body
    }

    /**
     * Build the persistent warning an incomplete search shows while its session goes on.
     *
     * @param shortfalls What the session's searches failed to retrieve
     * @return "Incomplete search: {clauses}.", or null when the searches were complete
     */
    fun incompleteSearchWarning(shortfalls: List<RetrievalShortfall>): String? =
        if (shortfalls.isEmpty()) null else "$NOTICE_PLAIN_OPENING${describeSearchShortfalls(shortfalls)}."

    /**
     * Build the report's Methodology section for an incomplete search.
     *
     * Android's report has no Methodology section of its own, so this holds only
     * the contract's Search Completeness line (user's decision, 2026-09-15).
     *
     * @param shortfalls What the search behind the report is missing
     * @return The section, or "" when the search was complete
     */
    fun searchCompletenessMethodology(shortfalls: List<RetrievalShortfall>): String {
        if (shortfalls.isEmpty()) return ""
        return "## Methodology\n\n- **Search Completeness:** Incomplete: ${describeSearchShortfalls(shortfalls)}"
    }

    /**
     * Say what the user can do about a failed search.
     *
     * @param shortfalls What failed
     * @return One or more sentences, each at most once, in this order: waiting
     *   out a rate limit (and, for PubMed, adding an NCBI API key); checking the
     *   NCBI API key PubMed refused; rephrasing a question the service could not
     *   process; checking the connection. Otherwise, trying again later.
     */
    fun searchFailureAdvice(shortfalls: List<RetrievalShortfall>): String {
        val advice = mutableListOf<String>()
        val rateLimited = shortfalls.filter { it.hasHttpStatus(setOf(Constants.HTTP_TOO_MANY_REQUESTS)) }
        if (rateLimited.isNotEmpty()) {
            advice.add(RATE_LIMIT_ADVICE)
            if (rateLimited.any { it.provider == SearchProvider.PUBMED }) advice.add(PUBMED_KEY_ADVICE)
        }
        if (shortfalls.any { it.provider == SearchProvider.PUBMED && it.hasHttpStatus(REFUSED_KEY_STATUSES) }) {
            advice.add(PUBMED_REFUSED_KEY_ADVICE)
        }
        if (shortfalls.any { it.failure.kind == RequestFailureKind.SERVICE_ERROR }) advice.add(SERVICE_ERROR_ADVICE)
        if (shortfalls.any { it.failure.kind == RequestFailureKind.TIMEOUT || it.failure.kind == RequestFailureKind.CONNECTION }) {
            advice.add(CONNECTIVITY_ADVICE)
        }
        return if (advice.isEmpty()) FALLBACK_ADVICE else advice.joinToString(" ")
    }

    /**
     * Say what a failed search could not do, and what to do next.
     *
     * @param error The failed search
     * @return The error's sentence, a blank line, and the advice
     */
    fun formatSearchFailureMessage(error: SearchFailedException): String =
        "${error.message}\n\n${searchFailureAdvice(error.shortfalls)}"

    /**
     * Whether a shortfall is an HTTP error answer with one of the statuses.
     *
     * @param statuses The status codes to look for
     * @return True for an [RequestFailureKind.HTTP_STATUS] failure whose status is among them
     */
    private fun RetrievalShortfall.hasHttpStatus(statuses: Set<Int>): Boolean =
        failure.kind == RequestFailureKind.HTTP_STATUS && failure.statusCode in statuses

    // ==================== The persisted form ====================

    /**
     * Build the value a session stores for what its search is missing.
     *
     * @param shortfalls What the search is missing
     * @return A JSON array in the contract's form, or null when there are none,
     *   so a complete search stores nothing
     */
    fun retrievalShortfallsToJson(shortfalls: List<RetrievalShortfall>): String? {
        if (shortfalls.isEmpty()) return null
        return buildJsonArray {
            for (shortfall in shortfalls) {
                addJsonObject {
                    put(KEY_PROVIDER, storedProvider(shortfall.provider))
                    putJsonObject(KEY_FAILURE) {
                        put(KEY_KIND, shortfall.failure.kind.persistedValue)
                        put(KEY_STATUS_CODE, shortfall.failure.statusCode)
                    }
                    put(KEY_RECORDS_MISSING, shortfall.recordsMissing)
                    shortfall.query.persistedValue?.let { put(KEY_QUERY, it) }
                }
            }
        }.toString()
    }

    /**
     * Read what a session stored about its search's shortfalls.
     *
     * The failure, the count and the query degrade: an unknown kind, or a
     * failure that is missing or not an object, reads as a failed request; a
     * status code that is not a whole number from 100 to 999, or that belongs to
     * a kind carrying none, reads as null; a count that is not a whole number of
     * at least one reads as null, and a query marker this build does not know
     * reads as the original query, both of which claim more is missing, never
     * less.
     *
     * @param stored The stored value, untrusted; null when nothing was stored (a
     *   complete search, or a session saved before #252)
     * @return The shortfalls
     * @throws IllegalArgumentException if the value is not a JSON array (the JSON
     *   literal `null` included), or an entry is not an object naming PubMed or Europe PMC.
     *   Nothing is skipped: a dropped shortfall would let a report claim a
     *   complete search.
     */
    fun retrievalShortfallsFromJson(stored: String?): List<RetrievalShortfall> {
        if (stored == null) return emptyList()
        val entries = parsedOrNull(stored) as? JsonArray
            ?: throw IllegalArgumentException("Recorded retrieval shortfalls must be a JSON array")
        return entries.map(::shortfallFrom)
    }

    /**
     * Parse JSON without keeping the parser's exception, whose message quotes the input.
     *
     * @param text The text
     * @return The value, or null when the text is not JSON
     */
    private fun parsedOrNull(text: String): JsonElement? = try {
        Json.parseToJsonElement(text)
    } catch (_: SerializationException) {
        null
    }

    /**
     * Read one stored shortfall.
     *
     * @param entry The stored entry
     * @return The shortfall
     * @throws IllegalArgumentException if the entry is not an object naming PubMed or Europe PMC
     */
    private fun shortfallFrom(entry: JsonElement): RetrievalShortfall {
        val fields = entry as? JsonObject
            ?: throw IllegalArgumentException("A retrieval shortfall must be a JSON object")
        val provider = when ((fields[KEY_PROVIDER] as? JsonPrimitive)?.takeIf { it.isString }?.content) {
            STORED_PUBMED -> SearchProvider.PUBMED
            STORED_EUROPE_PMC -> SearchProvider.EUROPE_PMC
            else -> throw IllegalArgumentException("A retrieval shortfall must name PubMed or Europe PMC")
        }
        val missing = wholeNumber(fields[KEY_RECORDS_MISSING])?.takeIf { it in 1..Int.MAX_VALUE }?.toInt()
        // An unknown marker reads as the original query, whose clause claims more is missing
        val marker = (fields[KEY_QUERY] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val query = ShortfallQuery.entries.firstOrNull { it.persistedValue != null && it.persistedValue == marker }
            ?: ShortfallQuery.ORIGINAL
        return RetrievalShortfall(provider, failureFrom(fields[KEY_FAILURE]), missing, query)
    }

    /**
     * Read a stored failure, degrading rather than refusing.
     *
     * @param value The stored value, untrusted
     * @return The failure, as specific as the stored value allows
     */
    private fun failureFrom(value: JsonElement?): RequestFailure {
        val fields = value as? JsonObject ?: return RequestFailure(RequestFailureKind.REQUEST_FAILED)
        val kindValue = (fields[KEY_KIND] as? JsonPrimitive)?.takeIf { it.isString }?.content
        val kind = RequestFailureKind.fromPersisted(kindValue) ?: return RequestFailure(RequestFailureKind.REQUEST_FAILED)
        val status = wholeNumber(fields[KEY_STATUS_CODE])
            ?.takeIf { kind.carriesStatusCode && RequestFailure.isHttpStatusCode(it) }
            ?.toInt()
        return RequestFailure(kind, status)
    }

    /**
     * Read a stored whole number.
     *
     * @param value The stored value, untrusted
     * @return The number, or null for anything else: a string, a boolean, a
     *   fraction, `null`, or a number too large to hold
     */
    private fun wholeNumber(value: JsonElement?): Long? {
        val primitive = value as? JsonPrimitive ?: return null
        if (primitive.isString || !WHOLE_NUMBER.matches(primitive.content)) return null
        return primitive.content.toLongOrNull()
    }

    /**
     * The stored string for a source.
     *
     * @param provider PubMed or Europe PMC
     * @return "pubmed" or "europepmc"
     */
    private fun storedProvider(provider: SearchProvider): String = when (provider) {
        SearchProvider.PUBMED -> STORED_PUBMED
        SearchProvider.EUROPE_PMC -> STORED_EUROPE_PMC
        SearchProvider.BOTH -> throw IllegalArgumentException("A retrieval shortfall must name PubMed or Europe PMC")
    }
}
