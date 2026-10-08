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

import android.content.Context
import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import okio.BufferedSource
import java.io.File
import java.io.IOException
import java.util.Locale
import java.util.concurrent.TimeUnit
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Elsevier's Article Retrieval API, asked for an Elsevier article's PDF by DOI with
 * the user's own key and, when set, an institutional token (#480, stage C2).
 *
 * The pure rules, pinned with Python's `elsevier_api.py` and BioMedLit's
 * `Elsevier.swift` by `doc/cross_platform/fulltext_parity/elsevier_article.json`:
 * which DOIs are asked, the request's address, how one answer is classified, and
 * what it leaves in the session. The key travels only in `X-ELS-APIKey` and the
 * token only in `X-ELS-Insttoken`: neither is ever part of the URL built here.
 */
object Elsevier {
    /** What a path keeps bare besides ASCII letters and digits, as Python's `quote(s, safe="/")`. */
    private const val PATH_SAFE_PUNCTUATION = "-._~/"

    /** The radix of a percent escape's hex digits. */
    private const val HEX_RADIX = 16

    /** A byte's value as an unsigned number. */
    private const val BYTE_MASK = 0xFF

    /** The cache file's name before the digest, and its extension. */
    private const val CACHE_FILE_PREFIX = "elsevier-"
    private const val CACHE_FILE_SUFFIX = ".pdf"

    /**
     * Whether a DOI is Elsevier's, and so may be asked about: CORE's normalised form
     * ([Core.normalisedDoi]) starts `10.1016/`. Every other DOI makes no request and
     * records nothing.
     *
     * @param doi The DOI as a source wrote it
     */
    fun isEligible(doi: String): Boolean = Core.normalisedDoi(doi).startsWith(Constants.ELSEVIER_DOI_PREFIX)

    /**
     * The article request for one DOI. It carries neither the key nor the token.
     *
     * @param doi The DOI; trimmed, one resolver or `doi:` prefix removed, its own case
     *   kept ([Core.doiWithoutPrefix])
     * @param baseUrl Elsevier's API root; trailing slashes are dropped
     * @return The URL, pinned by the contract's `article_url` rows
     */
    fun articleUrl(doi: String, baseUrl: String = Constants.ELSEVIER_BASE_URL): String =
        baseUrl.trimEnd('/') + Constants.ELSEVIER_ARTICLE_PATH + escapedPath(Core.doiWithoutPrefix(doi))

    /**
     * A text escaped as a URL path, Python's `quote(s, safe="/")`: ASCII letters and
     * digits, `-`, `.`, `_`, `~` and `/` bare, every other UTF-8 byte as `%XX` in
     * upper-case hex. A `;` is encoded: a servlet would read it as a path parameter.
     *
     * @param text The text
     * @return It escaped
     */
    fun escapedPath(text: String): String = buildString {
        for (byte in text.toByteArray(Charsets.UTF_8)) {
            val value = byte.toInt() and BYTE_MASK
            // A byte of a multi-byte character is above ASCII, so in none of these ranges
            val char = value.toChar()
            if (char in 'A'..'Z' || char in 'a'..'z' || char in '0'..'9' || char in PATH_SAFE_PUNCTUATION) {
                append(char)
            } else {
                append('%')
                append(value.toString(HEX_RADIX).uppercase(Locale.ROOT).padStart(2, '0'))
            }
        }
    }

    /**
     * The name of the file a DOI's PDF is cached under: the SHA-256 digest of the
     * normalised DOI, so the DOI's spellings share one file and none of them is a
     * path.
     *
     * @param doi The DOI
     * @return `elsevier-<64 hex digits>.pdf`
     */
    fun cacheFileName(doi: String): String =
        CACHE_FILE_PREFIX + KeyDigest.sha256Hex(Core.normalisedDoi(doi)) + CACHE_FILE_SUFFIX

    /** A fresh session with Elsevier's rules: unpaused, nothing refused. */
    fun newSession(): KeyedServiceSession = KeyedServiceSession(
        Constants.ELSEVIER_SERVICE_NAME,
        Constants.ELSEVIER_KEY_REFUSED_STATUS,
        Constants.ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429,
        ElsevierService.TAG
    )

    /**
     * Classify one answer, after its retries (the contract's `answers` table).
     *
     * @param status The HTTP status. A 3xx is never followed: it is unreachable
     * @param headers The answer's headers as name and value; `X-ELS-Status` is
     *   matched by name in any case
     * @param body The body, or at least its start: `%PDF` for a 200, and up to
     *   [Constants.ELSEVIER_ERROR_BODY_MAX_BYTES] for a 403 (more is not read)
     * @return What the answer means
     */
    fun classify(status: Int, headers: Iterable<Pair<String, String>>, body: ByteArray): ElsevierAnswer =
        when (status) {
            // The warning is read before the body: the first page is a valid PDF,
            // and never the article's text
            Constants.HTTP_OK -> when {
                isFirstPageOnly(headers) -> ElsevierAnswer.FirstPageOnly
                looksLikePdf(body) -> ElsevierAnswer.Served
                else -> ElsevierAnswer.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
            }
            Constants.HTTP_NOT_FOUND -> ElsevierAnswer.Absent
            Constants.ELSEVIER_KEY_REFUSED_STATUS -> ElsevierAnswer.KeyRefused
            Constants.ELSEVIER_NETWORK_REFUSED_STATUS ->
                if (isNetworkRefusal(body)) {
                    ElsevierAnswer.NetworkRefused
                } else {
                    ElsevierAnswer.Unreachable(RequestFailure.forHttpStatus(status))
                }
            else -> ElsevierAnswer.Unreachable(RequestFailure.forHttpStatus(status))
        }

    /** Whether a 200 carries the first page only: an `X-ELS-Status` whose value, trimmed, starts `WARNING` in any case. */
    private fun isFirstPageOnly(headers: Iterable<Pair<String, String>>): Boolean = headers.any { (name, value) ->
        name.equals(Constants.ELSEVIER_STATUS_HEADER, ignoreCase = true) &&
            value.trim().startsWith(Constants.ELSEVIER_WARNING_PREFIX, ignoreCase = true)
    }

    /** Whether a 403's body, read up to the bound, holds the token's ASCII bytes. */
    private fun isNetworkRefusal(body: ByteArray): Boolean {
        val token = Constants.ELSEVIER_NETWORK_REFUSED_TOKEN.toByteArray(Charsets.US_ASCII)
        val end = minOf(body.size, Constants.ELSEVIER_ERROR_BODY_MAX_BYTES) - token.size
        return (0..end).any { start -> token.indices.all { body[start + it] == token[it] } }
    }

    /**
     * The answer a fetch has without asking, in the contract's order: this key
     * refused, these credentials refused from this network, then the pause. Such a
     * fetch makes no request and is recorded nowhere.
     *
     * @param session Elsevier's session state
     * @param keyDigest The key's [KeyDigest.key]
     * @param credentialsDigest The key's and token's [KeyDigest.credentials]
     * @return The answer, or null when Elsevier is to be asked
     */
    fun answerWithoutAsking(
        session: KeyedServiceSession,
        keyDigest: String,
        credentialsDigest: String
    ): ElsevierAnswer? = when {
        session.refuses(keyDigest) -> ElsevierAnswer.KeyRefused
        session.refusesNetwork(credentialsDigest) -> ElsevierAnswer.NetworkRefused
        session.isPaused -> ElsevierAnswer.Unreachable(RequestFailure.forHttpStatus(Constants.HTTP_TOO_MANY_REQUESTS))
        else -> null
    }

    /**
     * Record how a fetch that made a request ended: a refusal from this network
     * refuses those credentials; any other answer is noted by its status (a 401
     * refuses the key, a 429 counts toward the pause, anything else resets the count).
     *
     * @param answer The answer classified
     * @param status The HTTP status it ended on, or null when it got none
     * @param session Elsevier's session state
     * @param keyDigest The key's [KeyDigest.key]
     * @param credentialsDigest The key's and token's [KeyDigest.credentials]
     */
    fun record(
        answer: ElsevierAnswer,
        status: Int?,
        session: KeyedServiceSession,
        keyDigest: String,
        credentialsDigest: String
    ) {
        if (answer == ElsevierAnswer.NetworkRefused) {
            session.recordNetworkRefused(credentialsDigest)
        } else {
            session.record(status, keyDigest)
        }
    }
}

/** What one answer of Elsevier's means (the contract's `answers` outcomes). */
sealed interface ElsevierAnswer {
    /** A 200 whose body is a PDF: the article. */
    data object Served : ElsevierAnswer

    /** No such article (404): nothing is recorded, and the chain goes on. */
    data object Absent : ElsevierAnswer

    /**
     * A 200 marked `WARNING`: the first page only, never the article's text. An
     * absence, told apart so it can be logged as such.
     */
    data object FirstPageOnly : ElsevierAnswer

    /**
     * Elsevier could not be asked, or its answer could not be read.
     *
     * @property failure Its real kind; a paused Elsevier is HTTP 429
     */
    data class Unreachable(val failure: RequestFailure) : ElsevierAnswer

    /** Elsevier refused the key (401), now or earlier this session. */
    data object KeyRefused : ElsevierAnswer

    /** Elsevier refused these credentials from this network (a 403 holding `AUTHENTICATION_ERROR`). */
    data object NetworkRefused : ElsevierAnswer
}

/** What asking Elsevier for one article's PDF learned. */
sealed interface ElsevierFetch {
    /**
     * The PDF, saved at this local path: never a link, as Elsevier's URL needs the key.
     *
     * @property localPath Where the PDF is cached
     */
    data class Served(val localPath: String) : ElsevierFetch

    /** No PDF of this article for this requestor (a 404, or a first page only): the chain goes on. */
    data object Absent : ElsevierFetch

    /**
     * Elsevier could not be asked, or its answer could not be read.
     *
     * @property failure Its real kind
     */
    data class Unreachable(val failure: RequestFailure) : ElsevierFetch

    /** Elsevier refused the key, so it was not asked about this article. */
    data object KeyRefused : ElsevierFetch

    /** Elsevier refused these credentials from this network. */
    data object NetworkRefused : ElsevierFetch

    /** Elsevier served the PDF and it could not be saved on this device (logged at ERROR, with its cause). */
    data object NotSaved : ElsevierFetch
}

/**
 * Asks Elsevier's Article API for an Elsevier article's PDF, the user's key in
 * `X-ELS-APIKey` alone and the institutional token, when set, in
 * `X-ELS-Insttoken` alone, paced to two requests a second.
 *
 * A singleton, and its injected instances share [PROCESS_SESSION]: the session
 * state is the process's (the contract's `session` table). Two consecutive
 * fetches ending in 429 stop Elsevier being asked until the app restarts; a 401
 * refuses the key it was sent with, and a 403 holding `AUTHENTICATION_ERROR`
 * those credentials, each for the rest of the process. It shares nothing with
 * CORE's state: a CORE 429 never pauses Elsevier.
 *
 * Redirects are never followed ([client]): the key travels in a custom header no
 * client strips on a redirect, so a 3xx is classified as the status it is.
 *
 * @param httpClient Derived by [client]: redirects off, no silent retry
 * @param baseUrl Elsevier's address; tests point it at a local server
 * @property cacheDir The directory the PDFs are cached in, as
 *   `elsevier-<digest>.pdf` ([Elsevier.cacheFileName]): the full-text PDF cache
 * @property apiKey The key, read per request; trimmed here, and blank is none
 * @property instToken The institutional token, read per request with a key only;
 *   trimmed here, and blank is none
 * @property pacer Every attempt, retries included, takes a slot
 * @property maxRetries Further attempts for a transport failure or a status in
 *   [Constants.ELSEVIER_RETRYABLE_STATUSES]; tests pass 0
 * @property initialBackoffMs The wait before the first retry, doubling after
 * @property session What one fetch leaves for the next
 */
@Singleton
class ElsevierService internal constructor(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val cacheDir: () -> File,
    private val apiKey: () -> String?,
    private val instToken: () -> String?,
    private val pacer: RequestPacer,
    private val maxRetries: Int,
    private val initialBackoffMs: Long,
    private val session: KeyedServiceSession
) {
    /** The key and the token are the user's, read from the settings at each request. */
    @Inject
    constructor(
        httpClient: OkHttpClient,
        settingsRepository: SettingsRepository,
        @ApplicationContext context: Context
    ) : this(
        client(httpClient),
        Constants.ELSEVIER_BASE_URL,
        { File(context.cacheDir, Constants.FULLTEXT_PDF_CACHE_DIR) },
        settingsRepository::getElsevierApiKey,
        settingsRepository::getElsevierInstToken,
        RequestPacer(Constants.ELSEVIER_MIN_INTERVAL_MS),
        Constants.ELSEVIER_MAX_RETRIES,
        Constants.ELSEVIER_INITIAL_BACKOFF_MS,
        PROCESS_SESSION
    )

    /**
     * One request's ending, after its retries.
     *
     * @property status The HTTP status it ended on, or null when it got none
     * @property answer The answer classified
     * @property fetch What it comes to, when that is settled by the attempt (a PDF
     *   saved or not saved); null for every other answer
     */
    private class Ending(val status: Int?, val answer: ElsevierAnswer, val fetch: ElsevierFetch? = null)

    /**
     * This article's PDF from Elsevier.
     *
     * The cache is consulted first, as every PDF tier consults it: a read is no
     * request, so a PDF saved earlier (on the institution's network, say) is served
     * even when Elsevier would now refuse or is paused, without spending the weekly
     * quota. A cached file that is not a PDF is quarantined and Elsevier asked.
     *
     * Never throws but for cancellation: an unexpected error is logged (never with
     * the key or the token) and answered as Elsevier unreachable.
     *
     * @param doi The DOI; only an Elsevier DOI ([Elsevier.isEligible]) is asked
     * @return Null when not asked: no key, or a DOI that is not Elsevier's (nothing
     *   sent, recorded or logged; the no-key debug line never carries the key); otherwise
     *   served (a local path), absent (a 404 or a first page only, logged at INFO),
     *   unreachable of its real kind (a paused Elsevier is HTTP 429, nothing sent),
     *   the key or the credentials refused, or not saved
     * @throws CancellationException if the caller cancelled
     */
    suspend fun fetchPdf(doi: String): ElsevierFetch? {
        // No per-article log for another publisher's DOI (as Python and Swift).
        if (!Elsevier.isEligible(doi)) return null
        val key = try {
            apiKey()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.e(TAG, "$SERVICE's key could not be read: ${e.javaClass.simpleName}")
            return ElsevierFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
        if (key == null) {
            Log.d(TAG, "No Elsevier API key is set; $SERVICE is not asked")
            return null
        }
        val token = try {
            instToken()?.trim()?.takeIf { it.isNotEmpty() }
        } catch (e: Exception) {
            if (e is CancellationException) throw e
            Log.e(TAG, "$SERVICE's institutional token could not be read: ${e.javaClass.simpleName}")
            return ElsevierFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        }
        val cached = File(cacheDir(), Elsevier.cacheFileName(doi))
        if (withContext(Dispatchers.IO) { cachedPdfOrQuarantine(cached) }) {
            Log.i(TAG, "Serving the cached PDF from $SERVICE for DOI $doi at ${cached.absolutePath}")
            return ElsevierFetch.Served(cached.absolutePath)
        }
        val keyDigest = KeyDigest.key(key)
        val credentialsDigest = KeyDigest.credentials(key, token)
        Elsevier.answerWithoutAsking(session, keyDigest, credentialsDigest)?.let { return fetchFor(it) }

        // A request we could not build was never sent: not an absence
        val url = Elsevier.articleUrl(doi, baseUrl).toHttpUrlOrNull()
            ?: return ElsevierFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        val request = Request.Builder().url(url)
            .header(Constants.ELSEVIER_KEY_HEADER, key)
            .apply { token?.let { header(Constants.ELSEVIER_TOKEN_HEADER, it) } }
            .header(Constants.HTTP_ACCEPT_HEADER, Constants.ELSEVIER_ACCEPT)
            .build()

        val ending = try {
            get(request, cached, doi)
        } catch (e: RetryableStatusException) {
            // A throttle or server error that outlasted its retries
            Ending(e.statusCode, ElsevierAnswer.Unreachable(RequestFailure.forHttpStatus(e.statusCode)))
        } catch (e: IOException) {
            Ending(null, ElsevierAnswer.Unreachable(RequestFailure.fromException(e)))
        } catch (e: CancellationException) {
            throw e
        } catch (e: Exception) {
            // Its class alone: a message could hold the request, and so the key
            Log.e(TAG, "$SERVICE lookup failed unexpectedly: ${e.javaClass.simpleName}")
            Ending(null, ElsevierAnswer.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED)))
        }
        Elsevier.record(ending.answer, ending.status, session, keyDigest, credentialsDigest)
        if (ending.answer == ElsevierAnswer.FirstPageOnly) {
            Log.i(TAG, "$SERVICE served only the first page for DOI $doi: this requestor is not entitled to the article; not used")
        }
        return ending.fetch ?: fetchFor(ending.answer)
    }

    /**
     * Whether a PDF is cached for this article; a cached file that is not one is
     * quarantined as `.corrupt`, and reads as a miss.
     */
    private fun cachedPdfOrQuarantine(cached: File): Boolean {
        if (isCachedPdf(cached)) return true
        if (cached.exists()) {
            Log.w(TAG, "Quarantining a cached file that is not a PDF: ${cached.absolutePath}")
            quarantineCachedFile(cached, File(cached.parentFile, cached.name + PDF_CORRUPT_SUFFIX))
        }
        return false
    }

    /**
     * Ask, retrying a throttle, a server error and a transport failure; every
     * attempt takes its own pacer slot.
     *
     * @param request The article request, its headers set
     * @param cached Where a PDF served is saved
     * @param doi The DOI, for the log
     * @return How the request ended
     * @throws RetryableStatusException for a retryable status that outlasted its retries
     * @throws IOException for a transport failure that did
     */
    private suspend fun get(request: Request, cached: File, doi: String): Ending = NetworkRetry.withExponentialBackoff(
        maxRetries = maxRetries,
        initialDelayMs = initialBackoffMs,
        shouldRetry = { NetworkRetry.isRetryableException(it) }
    ) {
        pacer.awaitTurn() // every attempt takes its own slot
        withContext(Dispatchers.IO) {
            httpClient.newCall(request).execute().use { response ->
                if (response.code in Constants.ELSEVIER_RETRYABLE_STATUSES) {
                    throw RetryableStatusException(response.code)
                }
                answered(response, cached, doi)
            }
        }
    }

    /**
     * Classify an answer, reading no more of its body than that needs, and save a
     * PDF served.
     *
     * A first page is told by its header alone. A 200 is read to its first bytes
     * (`%PDF`), then, a PDF, streamed to `<name>.part` and renamed into place; a 403
     * is read to [Constants.ELSEVIER_ERROR_BODY_MAX_BYTES] for the token, and nothing
     * of it is logged or kept. No other body is read.
     *
     * @throws IOException if the body could not be read (retried by the caller)
     */
    private fun answered(response: Response, cached: File, doi: String): Ending {
        val code = response.code
        val headers = response.headers.toList()
        val source = response.body?.source()
        val firstPage = code == Constants.HTTP_OK &&
            Elsevier.classify(code, headers, ByteArray(0)) == ElsevierAnswer.FirstPageOnly
        val prefix = when {
            source == null || firstPage -> ByteArray(0)
            code == Constants.HTTP_OK -> source.peekPrefix(Constants.PDF_MAGIC_BYTES.size)
            code == Constants.ELSEVIER_NETWORK_REFUSED_STATUS -> source.peekPrefix(Constants.ELSEVIER_ERROR_BODY_MAX_BYTES)
            else -> ByteArray(0)
        }
        val answer = Elsevier.classify(code, headers, prefix)
        if (answer != ElsevierAnswer.Served || source == null) return Ending(code, answer)
        return Ending(code, answer, save(source, cached, doi))
    }

    /**
     * Stream a PDF served to its cache file, through a `.part` file renamed into
     * place only once it arrived whole and begins with `%PDF`.
     *
     * @return Served, or NotSaved (logged at ERROR with its cause) when it could not be written
     * @throws IOException if the body could not be read
     */
    private fun save(source: BufferedSource, cached: File, doi: String): ElsevierFetch {
        val partial = File(cached.parentFile, cached.name + PDF_PARTIAL_SUFFIX)
        try {
            cached.parentFile?.mkdirs()
            source.inputStream().copyToCache(partial)
            if (!isCachedPdf(partial)) {
                // Its first bytes were %PDF; a file that is not one now was not written as served
                Log.e(TAG, "$SERVICE served the PDF for DOI $doi, and it could not be saved on this device (written incomplete)")
                return ElsevierFetch.NotSaved
            }
            if (!partial.renameTo(cached)) {
                Log.e(TAG, "$SERVICE served the PDF for DOI $doi, and it could not be saved on this device (rename failed)")
                return ElsevierFetch.NotSaved
            }
        } catch (e: CacheWriteException) {
            Log.e(
                TAG,
                "$SERVICE served the PDF for DOI $doi, and it could not be saved on this device " +
                    "(${e.cause?.javaClass?.simpleName})"
            )
            return ElsevierFetch.NotSaved
        } finally {
            // Gone once renamed; otherwise never to be read as the PDF
            partial.delete()
        }
        Log.d(TAG, "$SERVICE's PDF for DOI $doi saved at ${cached.absolutePath}")
        return ElsevierFetch.Served(cached.absolutePath)
    }

    /** At most [count] bytes from the start of the body, left unread for whoever reads it next. */
    private fun BufferedSource.peekPrefix(count: Int): ByteArray {
        request(count.toLong())
        return buffer.snapshot(minOf(buffer.size, count.toLong()).toInt()).toByteArray()
    }

    /** What a fetch learned from an answer that is not a PDF saved: a first page is no article, so an absence. */
    private fun fetchFor(answer: ElsevierAnswer): ElsevierFetch = when (answer) {
        ElsevierAnswer.Served, ElsevierAnswer.Absent, ElsevierAnswer.FirstPageOnly -> ElsevierFetch.Absent
        is ElsevierAnswer.Unreachable -> ElsevierFetch.Unreachable(answer.failure)
        ElsevierAnswer.KeyRefused -> ElsevierFetch.KeyRefused
        ElsevierAnswer.NetworkRefused -> ElsevierFetch.NetworkRefused
    }

    companion object {
        /** The tag Elsevier's log lines carry, its session's included. */
        internal const val TAG = "ElsevierService"

        /** The service as log lines name it. */
        private const val SERVICE = Constants.ELSEVIER_SERVICE_NAME

        /** Appended to a PDF's cache name while it is written. */
        private const val PDF_PARTIAL_SUFFIX = ".part"

        /** Appended to a cached file that is not a PDF, kept aside for whoever investigates. */
        private const val PDF_CORRUPT_SUFFIX = ".corrupt"

        /**
         * Elsevier's session state every injected service in this process shares:
         * the 429 pause, the refused key and the credentials refused from this network.
         */
        private val PROCESS_SESSION: KeyedServiceSession = Elsevier.newSession()

        /**
         * The client Elsevier is asked with, derived from the shared one (whose
         * interceptors it keeps): its own timeouts, no silent retry, and redirects
         * off, so a 3xx comes back as the answer and the key never follows it.
         *
         * @param shared The app's client
         * @return The derived client
         */
        fun client(shared: OkHttpClient): OkHttpClient = shared.newBuilder()
            .connectTimeout(Constants.ELSEVIER_REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(Constants.ELSEVIER_REQUEST_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .retryOnConnectionFailure(false)
            .followRedirects(false)
            .followSslRedirects(false)
            .build()
    }
}
