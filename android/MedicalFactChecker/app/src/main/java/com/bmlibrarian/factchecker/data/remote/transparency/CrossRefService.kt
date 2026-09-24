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

package com.bmlibrarian.factchecker.data.remote.transparency

import android.util.Log
import com.bmlibrarian.factchecker.domain.transparency.FunderInfo
import com.bmlibrarian.factchecker.domain.transparency.FundingAnalyzer
import com.bmlibrarian.factchecker.domain.transparency.JsonCasts
import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneId
import java.util.concurrent.TimeUnit
import kotlinx.serialization.SerializationException
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request

/**
 * Why a CrossRef request failed. Messages are those of the Swift `CrossRefError`.
 *
 * @property isRetryable Whether another attempt could succeed (network and server failures).
 */
sealed class CrossRefException(message: String) : Exception(message) {
    abstract val isRetryable: Boolean

    /** The DOI cannot be turned into a request URL. */
    class InvalidDoi(val doi: String) : CrossRefException("Invalid DOI: $doi") {
        override val isRetryable: Boolean = false
    }

    /** The exchange failed in transport (no connection, timeout, ...). */
    class NetworkError(val detail: String) : CrossRefException("Network error: $detail") {
        override val isRetryable: Boolean = true
    }

    /** A non-retryable HTTP status other than 404. */
    class HttpError(val statusCode: Int) : CrossRefException("HTTP error: $statusCode") {
        override val isRetryable: Boolean = false
    }

    /** A retryable status (429 or 5xx). */
    class ServerError(val statusCode: Int) :
        CrossRefException("CrossRef server error (HTTP $statusCode). Try again later.") {
        override val isRetryable: Boolean = true
    }

    /** The answer was not the JSON shape CrossRef returns. */
    class ParseError(val detail: String) : CrossRefException("Failed to parse response: $detail") {
        override val isRetryable: Boolean = false
    }
}

/**
 * Client for the CrossRef REST API, the source of Funder Registry DOIs that make
 * industry classification reliable.
 *
 * Ported from the Swift `CrossRefService` (BioMedLit): the same URL, polite
 * User-Agent, pacing, retry rule and field parsing. A 404 answers null — the
 * work is absent; every other failure throws a [CrossRefException], so a caller
 * can tell an unreachable CrossRef from a work it does not have.
 *
 * @param email Contact email for the CrossRef polite pool, sent in the User-Agent.
 * @param httpClient HTTP client; defaults to one with Swift's 45 s timeout.
 * @param baseUrl API base URL (overridable for tests).
 * @param retryPolicy How transient failures are retried.
 * @param minimumRequestIntervalMs Minimum gap between two requests.
 */
class CrossRefService(
    private val email: String,
    private val httpClient: OkHttpClient = defaultTransparencyHttpClient(),
    private val baseUrl: String = TransparencyConstants.CROSSREF_BASE_URL,
    private val retryPolicy: TransparencyRetryPolicy = TransparencyRetryPolicy(),
    minimumRequestIntervalMs: Long = TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS,
) {
    private val pacer = RequestPacer(minimumRequestIntervalMs)

    /**
     * Fetch a work's metadata by DOI.
     *
     * @param doi The DOI, bare ("10.1000/example") or as a doi.org URL.
     * @return The work (CrossRef's `message` object), or null if CrossRef answered 404.
     * @throws CrossRefException on any other failure, after retrying transient ones.
     */
    suspend fun getWork(doi: String): JsonObject? {
        val cleanDoi = cleanDoi(doi)
        val url = "$baseUrl/works/$cleanDoi".toHttpUrlOrNull() ?: throw CrossRefException.InvalidDoi(doi)
        val request = Request.Builder()
            .url(url)
            .header(USER_AGENT_HEADER, "$USER_AGENT_PRODUCT (mailto:$email)")
            .build()

        pacer.awaitTurn()
        Log.d(TAG, "Fetching CrossRef work for DOI: $cleanDoi")

        val body = withTransparencyRetries(retryPolicy, { it is CrossRefException && it.isRetryable }) {
            val response = try {
                executeTransparencyRequest(httpClient, request)
            } catch (e: IOException) {
                throw CrossRefException.NetworkError(e.javaClass.simpleName)
            }
            val status = response.statusCode
            when {
                status in TransparencyHttpConstants.RETRYABLE_STATUS_CODES -> throw CrossRefException.ServerError(status)
                status == TransparencyHttpConstants.HTTP_STATUS_OK -> response.body
                status == TransparencyHttpConstants.HTTP_STATUS_NOT_FOUND -> null
                else -> throw CrossRefException.HttpError(status)
            }
        }

        if (body == null) {
            Log.d(TAG, "CrossRef returned 404 for DOI: $cleanDoi")
            return null
        }

        val message = try {
            JsonCasts.obj(JsonCasts.obj(Json.parseToJsonElement(body))?.get(MESSAGE_KEY))
        } catch (e: SerializationException) {
            null
        } ?: throw CrossRefException.ParseError("Invalid JSON structure")

        Log.i(TAG, "CrossRef returned work for DOI: $cleanDoi")
        return message
    }

    /**
     * Classify the funders of a work's `funder` array.
     *
     * The array is read all-or-nothing, as Swift's `as? [[String: Any]]` is: an
     * entry that is not an object discards every funder.
     *
     * @param work The work, or null.
     * @return The classified funders; empty when there are none.
     */
    fun extractFunders(work: JsonObject?): List<FunderInfo> {
        val funders = JsonCasts.objectList(work?.get("funder")) ?: return emptyList()
        return FundingAnalyzer.parseCrossRefFunders(funders)
    }

    /**
     * The work's title: the first element of its `title` array.
     *
     * @param work The work, or null.
     * @return The title, or null.
     */
    fun extractTitle(work: JsonObject?): String? = JsonCasts.stringList(work?.get("title"))?.firstOrNull()

    /**
     * The journal: the first element of the work's `container-title` array.
     *
     * @param work The work, or null.
     * @return The journal name, or null.
     */
    fun extractJournal(work: JsonObject?): String? =
        JsonCasts.stringList(work?.get("container-title"))?.firstOrNull()

    /**
     * The work's authors as "Family, Given", or "Family" alone when there is no given name.
     *
     * Authors without a family name (e.g. consortia given as `name`) are skipped, as in Swift.
     *
     * @param work The work, or null.
     * @return The author names, in order.
     */
    fun extractAuthors(work: JsonObject?): List<String> {
        val authors = JsonCasts.objectList(work?.get("author")) ?: return emptyList()
        return authors.mapNotNull { author ->
            val family = JsonCasts.string(author["family"]) ?: return@mapNotNull null
            val given = JsonCasts.string(author["given"])
            if (given != null) "$family, $given" else family
        }
    }

    /**
     * The publication date, from the first of `published-print`, `published-online`
     * and `issued` that carries integer `date-parts`.
     *
     * A missing month or day defaults to 1; the date is midnight in the device's
     * time zone, as Swift's `Calendar.current` builds it.
     *
     * @param work The work, or null.
     * @return The date, or null.
     */
    fun extractPublicationDate(work: JsonObject?): Instant? {
        if (work == null) return null
        for (key in DATE_KEYS) {
            val dateStruct = JsonCasts.obj(work[key]) ?: continue
            val parts = JsonCasts.intListList(dateStruct["date-parts"])?.firstOrNull() ?: continue
            return dateFromParts(parts)
        }
        return null
    }

    /** Strip a doi.org URL prefix and percent-encode the DOI for a URL path. */
    private fun cleanDoi(doi: String): String =
        percentEncodePath(doi.replace(HTTPS_DOI_PREFIX, "").replace(HTTP_DOI_PREFIX, ""))

    /** A `[year, month?, day?]` date-parts array as an instant (month and day default to 1). */
    private fun dateFromParts(parts: List<Int>): Instant? {
        val year = parts.firstOrNull() ?: return null
        val month = parts.getOrNull(1) ?: TransparencyConstants.DEFAULT_MONTH
        val day = parts.getOrNull(2) ?: TransparencyConstants.DEFAULT_DAY
        // Lenient like Foundation's Calendar: out-of-range months and days roll over.
        return LocalDate.of(year, 1, 1)
            .plusMonths((month - 1).toLong())
            .plusDays((day - 1).toLong())
            .atStartOfDay(ZoneId.systemDefault())
            .toInstant()
    }

    private companion object {
        const val TAG = "CrossRefService"
        const val USER_AGENT_HEADER = "User-Agent"
        const val USER_AGENT_PRODUCT = "StudyTransparencyAnalyzer/1.0"
        const val MESSAGE_KEY = "message"
        const val HTTPS_DOI_PREFIX = "https://doi.org/"
        const val HTTP_DOI_PREFIX = "http://doi.org/"
        val DATE_KEYS = listOf("published-print", "published-online", "issued")
    }
}

/**
 * An HTTP client with Swift's transparency request timeout, for callers that do
 * not supply the app's own client.
 *
 * @return A new client.
 */
fun defaultTransparencyHttpClient(): OkHttpClient =
    OkHttpClient.Builder()
        .callTimeout(TransparencyHttpConstants.REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .readTimeout(TransparencyHttpConstants.REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
        .build()
