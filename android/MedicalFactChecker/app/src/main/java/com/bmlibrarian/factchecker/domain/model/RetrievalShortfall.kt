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
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.serialization.SerializationException
import java.io.IOException
import java.io.InterruptedIOException
import java.util.Locale

/**
 * Why a request to a literature source produced no usable answer (#252).
 *
 * A failed source is not a source with no evidence: each kind reads differently
 * to the user, and none of them as a search that matched nothing. The
 * [persistedValue]s are stored in a session's retrieval shortfalls and are the
 * contract's strings (`doc/cross_platform/search_failure_reporting.md`), which
 * Python writes too: never rename one.
 *
 * @property persistedValue The value stored for this kind
 */
enum class RequestFailureKind(val persistedValue: String) {
    /** The request timed out after its retries. */
    TIMEOUT("timeout"),

    /** No connection could be made, or it broke. */
    CONNECTION("connection"),

    /** The source answered with an HTTP error status. */
    HTTP_STATUS("http_status"),

    /** E-utilities answered with a redirect, which is never followed (#243). */
    REDIRECT_REFUSED("redirect_refused"),

    /** The source answered, but said the request failed: an `ERROR` inside an HTTP 200 (#255). */
    SERVICE_ERROR("service_error"),

    /** The answer could not be read. */
    MALFORMED_RESPONSE("malformed_response"),

    /** The answer was readable but held less than it counted. */
    INCOMPLETE_RESPONSE("incomplete_response"),

    /** Anything else. */
    REQUEST_FAILED("request_failed");

    /** Whether a failure of this kind is an HTTP answer, and so can name its status. */
    val carriesStatusCode: Boolean
        get() = this == HTTP_STATUS || this == REDIRECT_REFUSED

    companion object {
        /**
         * Read a stored kind.
         *
         * @param value The stored value, untrusted
         * @return The kind it names, or null for a value this build does not know
         */
        fun fromPersisted(value: String?): RequestFailureKind? =
            entries.firstOrNull { it.persistedValue == value }
    }
}

/** The lowest three-digit HTTP status code. */
private const val HTTP_STATUS_CODE_MIN = 100

/** The highest three-digit HTTP status code. */
private const val HTTP_STATUS_CODE_MAX = 999

/** The kinds another attempt may get past, whatever the answer's status: a timeout and a broken connection. */
private val TRANSIENT_KINDS = setOf(RequestFailureKind.TIMEOUT, RequestFailureKind.CONNECTION)

/** The reason clause of each kind that names no HTTP status. */
private val REQUEST_FAILURE_REASONS = mapOf(
    RequestFailureKind.TIMEOUT to "the request timed out",
    RequestFailureKind.CONNECTION to "the connection failed",
    RequestFailureKind.SERVICE_ERROR to "the service reported an error",
    RequestFailureKind.MALFORMED_RESPONSE to "the response could not be read",
    RequestFailureKind.INCOMPLETE_RESPONSE to "the response was incomplete",
    RequestFailureKind.REQUEST_FAILED to "the request failed",
)

/**
 * The reason phrases a clause names, fixed by the contract in RFC 9110 wording
 * rather than taken from a library, whose phrases differ between platforms and
 * releases. Any other status reads as its number alone.
 */
private val HTTP_REASON_PHRASES = mapOf(
    400 to "Bad Request",
    401 to "Unauthorized",
    403 to "Forbidden",
    404 to "Not Found",
    408 to "Request Timeout",
    413 to "Content Too Large",
    414 to "URI Too Long",
    429 to "Too Many Requests",
    500 to "Internal Server Error",
    502 to "Bad Gateway",
    503 to "Service Unavailable",
    504 to "Gateway Timeout",
)

/**
 * A request that failed after its retries, reduced to what is safe to show.
 *
 * Only the kind and the HTTP status are kept. An answer's body is not: NCBI's
 * 400 for a bad key repeats the key, and a converter's error quotes the body it
 * could not read. Nothing built from this type can therefore print either.
 *
 * @property kind What went wrong
 * @property statusCode The HTTP status, for [RequestFailureKind.HTTP_STATUS] and
 *   [RequestFailureKind.REDIRECT_REFUSED]; null otherwise or when unknown
 * @throws IllegalArgumentException if a status is given for another kind, or is
 *   not a three-digit HTTP status
 */
data class RequestFailure(
    val kind: RequestFailureKind,
    val statusCode: Int? = null
) {
    init {
        if (statusCode != null) {
            require(kind.carriesStatusCode) { "A ${kind.persistedValue} failure carries no HTTP status" }
            require(isHttpStatusCode(statusCode)) { "An HTTP status code is an integer from 100 to 999" }
        }
    }

    /**
     * Whether another attempt may succeed: a timeout, a broken connection, or a
     * status [NetworkRetry] counts as transient, such as 429 or 503.
     */
    val isRetryable: Boolean
        get() = kind in TRANSIENT_KINDS ||
            (kind == RequestFailureKind.HTTP_STATUS && statusCode != null && NetworkRetry.isRetryableStatusCode(statusCode))

    /**
     * Describe the failure as a clause for a sentence shown to the user.
     *
     * @return For example "HTTP 429 Too Many Requests" or "the request timed out"
     */
    fun describe(): String = when (kind) {
        RequestFailureKind.HTTP_STATUS -> statusCode?.let(::httpStatusLabel) ?: "an HTTP error"
        RequestFailureKind.REDIRECT_REFUSED -> {
            val status = statusCode?.let { " (HTTP $it)" }.orEmpty()
            "a redirect$status was refused"
        }
        else -> REQUEST_FAILURE_REASONS.getValue(kind)
    }

    companion object {
        /**
         * The failure for an answer with an unsuccessful status.
         *
         * @param statusCode The status the source answered with
         * @return A refused redirect for a 3xx, which the PubMed client never
         *   follows; an HTTP error otherwise
         */
        fun forHttpStatus(statusCode: Int): RequestFailure {
            val kind = if (statusCode in Constants.HTTP_REDIRECT_STATUS_CODES) {
                RequestFailureKind.REDIRECT_REFUSED
            } else {
                RequestFailureKind.HTTP_STATUS
            }
            return RequestFailure(kind, statusCode)
        }

        /**
         * Classify an error a request raised, keeping nothing of the error itself.
         *
         * OkHttp raises a spent call timeout as a bare `InterruptedIOException`
         * and a socket timeout as its subclass, so both are timeouts; every other
         * `IOException` is a connection that could not be made or broke. A
         * converter's `SerializationException` is an answer that could not be
         * read, and its message, which quotes the body, is dropped here.
         *
         * @param error What the request raised
         * @return The failure, by kind only
         */
        fun fromException(error: Throwable): RequestFailure = RequestFailure(
            when (error) {
                is InterruptedIOException -> RequestFailureKind.TIMEOUT
                is IOException -> RequestFailureKind.CONNECTION
                is SerializationException -> RequestFailureKind.MALFORMED_RESPONSE
                else -> RequestFailureKind.REQUEST_FAILED
            }
        )

        /**
         * Whether a value is a three-digit HTTP status code.
         *
         * @param value The value
         * @return True for 100 to 999
         */
        fun isHttpStatusCode(value: Long): Boolean = value in HTTP_STATUS_CODE_MIN..HTTP_STATUS_CODE_MAX

        /**
         * Whether a value is a three-digit HTTP status code.
         *
         * @param value The value
         * @return True for 100 to 999
         */
        private fun isHttpStatusCode(value: Int): Boolean = isHttpStatusCode(value.toLong())

        /**
         * Label an HTTP status with its reason phrase when the contract names one.
         *
         * @param statusCode The status code
         * @return For example "HTTP 503 Service Unavailable", or "HTTP 599"
         */
        private fun httpStatusLabel(statusCode: Int): String =
            HTTP_REASON_PHRASES[statusCode]?.let { "HTTP $statusCode $it" } ?: "HTTP $statusCode"
    }
}

/**
 * Which query of a fact-check a shortfall belongs to.
 *
 * Smart search runs alternative queries when the claim's own query finds too
 * little. An alternative search that fails must not read as the source never
 * having been searched, since the original query's results from that source
 * are in the report (user's decision, 2026-09-15).
 *
 * @property persistedValue The stored marker, or null for the original query,
 *   which stores none
 */
enum class ShortfallQuery(val persistedValue: String?) {
    /** The query the claim was converted to. */
    ORIGINAL(null),

    /** An alternative query smart search generated. */
    ALTERNATIVE("alternative")
}

/**
 * Part of a search that a failure left out (#252).
 *
 * A search proceeds on what was retrieved, and the user is told what is
 * missing: never silently, and never as a search that found nothing.
 *
 * @property provider The source that failed: [SearchProvider.PUBMED] or [SearchProvider.EUROPE_PMC]
 * @property failure Why
 * @property recordsMissing How many records could not be retrieved, at least
 *   one; or null when the source could not be searched at all, so how many it
 *   holds is unknown
 * @property query Whether the loss belongs to the claim's own query or to an
 *   alternative query smart search ran
 * @throws IllegalArgumentException if the provider is [SearchProvider.BOTH] or
 *   the count is below one: a shortfall with nothing missing would tell the user
 *   a complete search was incomplete
 */
data class RetrievalShortfall(
    val provider: SearchProvider,
    val failure: RequestFailure,
    val recordsMissing: Int? = null,
    val query: ShortfallQuery = ShortfallQuery.ORIGINAL
) {
    init {
        requireSingleSource(provider)
        require(recordsMissing == null || recordsMissing >= 1) {
            "A retrieval shortfall misses at least one record, or null"
        }
    }

    /**
     * Describe the shortfall as a clause for a sentence shown to the user.
     *
     * @return For example "PubMed could not be searched (HTTP 429 Too Many
     *   Requests)", "1,200 Europe PMC records could not be retrieved (the
     *   request timed out)", or for an alternative query "an alternative search
     *   of PubMed could not be completed (HTTP 429 Too Many Requests)"
     */
    fun describe(): String {
        val source = provider.displayName
        val reason = failure.describe()
        val alternative = query == ShortfallQuery.ALTERNATIVE
        val missing = recordsMissing ?: return if (alternative) {
            "an alternative search of $source could not be completed ($reason)"
        } else {
            "$source could not be searched ($reason)"
        }
        val noun = if (missing == 1) "record" else "records"
        val origin = if (alternative) " from an alternative search" else ""
        return "${String.format(Locale.US, "%,d", missing)} $source $noun$origin could not be retrieved ($reason)"
    }
}

/**
 * Refuse a provider that names a search rather than a source.
 *
 * @param provider The provider
 * @throws IllegalArgumentException for [SearchProvider.BOTH]
 */
private fun requireSingleSource(provider: SearchProvider) {
    require(provider != SearchProvider.BOTH) { "A retrieval shortfall must name PubMed or Europe PMC" }
}

/**
 * A literature source could not answer a request (#252).
 *
 * Returned by the PubMed and Europe PMC clients when a request fails after its
 * retries, the source answers with an error instead of a result, or its answer
 * cannot be read or lists none of what it counts. It is never an empty result;
 * an answer that holds part of what it counts is a page with shortfalls instead.
 *
 * Only the provider and a [RequestFailure] are kept, and never a cause, not even
 * one attached later: the message cannot carry a request or an answer body. The
 * message is for logs; text shown to the user comes from
 * [RetrievalShortfall.describe], which also covers a failed page rather than a
 * whole search.
 *
 * @property provider The source that failed, PubMed or Europe PMC
 * @property failure Why, reduced to its kind and HTTP status
 * @throws IllegalArgumentException if the provider is [SearchProvider.BOTH]
 */
class SourceRequestException(
    val provider: SearchProvider,
    val failure: RequestFailure
) : Exception("${provider.displayName} could not be searched (${failure.describe()})") {
    init {
        requireSingleSource(provider)
    }

    /** Always null: a cause would carry what the failure was reduced from. */
    override val cause: Throwable?
        get() = null
}

/**
 * A search that failures left with nothing to proceed on (#252).
 *
 * A search that loses part of its sources proceeds on the rest and says what is
 * missing. When the failures leave no documents at all, the honest answer is not
 * "No documents found" (nobody knows whether there are any), so the search
 * fails with this instead.
 *
 * @param shortfalls What failed, at least one; copied
 * @throws IllegalArgumentException if there are no shortfalls: a failure that
 *   names nothing tells the user nothing
 */
class SearchFailedException(shortfalls: List<RetrievalShortfall>) : Exception(messageFor(shortfalls)) {

    /** What failed, in the order it was recorded. */
    val shortfalls: List<RetrievalShortfall> = shortfalls.toList()

    /** Always null: what failed is in [shortfalls], reduced to what is safe to show. */
    override val cause: Throwable?
        get() = null

    private companion object {
        /**
         * Build the contract's sentence.
         *
         * @param shortfalls What failed
         * @return "The search could not be completed: {clauses}."
         */
        fun messageFor(shortfalls: List<RetrievalShortfall>): String {
            require(shortfalls.isNotEmpty()) { "A failed search names at least one shortfall" }
            return "The search could not be completed: ${SearchFailureReporting.describeSearchShortfalls(shortfalls)}."
        }
    }
}
