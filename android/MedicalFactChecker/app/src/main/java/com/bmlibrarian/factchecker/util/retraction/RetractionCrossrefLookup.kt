// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.data.remote.transparency.TransparencyHttpConstants
import com.bmlibrarian.factchecker.data.remote.transparency.TransparencyRetryPolicy
import com.bmlibrarian.factchecker.data.remote.transparency.defaultTransparencyHttpClient
import com.bmlibrarian.factchecker.data.remote.transparency.executeTransparencyRequest
import com.bmlibrarian.factchecker.data.remote.transparency.withTransparencyRetries
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import com.bmlibrarian.factchecker.util.NetworkRetry
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.bmlib.ffi.CrossrefBatch
import org.bmlib.ffi.CrossrefResult
import org.bmlib.ffi.crossrefRetractionRequests
import org.bmlib.ffi.parseCrossrefRetractionResponse

/**
 * Crossref's answer about one DOI.
 *
 * @property result bmlib's reading of the answer
 * @property failure Set exactly when [result] is unreachable: what to tell the reader
 */
data class CrossrefAnswer(val result: CrossrefResult, val failure: RequestFailure?)

/**
 * Asks Crossref which papers are retracted, in bmlib's batches (Swift's
 * `RetractionCrossrefLookup`). bmlib builds each request and reads each
 * answer; this sends them, paced and retried as `CrossRefService` is.
 *
 * One per process (per contact address), so its pacing holds across every
 * screen (#647).
 *
 * @param email Contact address for Crossref's polite pool
 * @param httpClient HTTP client
 * @param retryPolicy How transient failures are retried
 * @param minimumRequestIntervalMs Minimum gap between two requests
 */
class RetractionCrossrefLookup(
    private val email: String,
    private val httpClient: OkHttpClient = defaultTransparencyHttpClient(),
    private val retryPolicy: TransparencyRetryPolicy = TransparencyRetryPolicy(),
    minimumRequestIntervalMs: Long = TransparencyConstants.MINIMUM_REQUEST_INTERVAL_MS,
) {
    private val pacer = RequestPacer(minimumRequestIntervalMs)

    /**
     * Ask Crossref about [dois].
     *
     * @param dois DOIs in any form bmlib normalises
     * @return An answer per normalised DOI; a DOI bmlib cannot send is absent
     * @throws CancellationException only: any other failure leaves its batch
     *   unreachable, so the batches that answered, and the local index, still decide
     */
    suspend fun results(dois: List<String>): Map<String, CrossrefAnswer> {
        if (dois.isEmpty()) return emptyMap()
        val answers = mutableMapOf<String, CrossrefAnswer>()
        for (batch in crossrefRetractionRequests(dois, email).batches) {
            currentCoroutineContext().ensureActive()
            val answered = try {
                answer(batch)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Crossref batch failed: ${e.javaClass.simpleName}")
                unreachable(batch, RequestFailure(RequestFailureKind.REQUEST_FAILED))
            }
            answers.putAll(answered)
        }
        return answers
    }

    /** Send one batch and read what came back. */
    private suspend fun answer(batch: CrossrefBatch): Map<String, CrossrefAnswer> {
        val url = batch.url.toHttpUrlOrNull() ?: return unreachable(batch, RequestFailure(RequestFailureKind.REQUEST_FAILED))
        val request = Request.Builder()
            .url(url)
            .header(USER_AGENT_HEADER, "${RetractionConstants.USER_AGENT_PRODUCT} (mailto:$email)")
            .build()
        pacer.awaitTurn()

        val response = try {
            withTransparencyRetries(retryPolicy, { it is TransientStatus || (it is IOException && NetworkRetry.isRetryableException(it)) }) {
                val answered = executeTransparencyRequest(httpClient, request)
                if (answered.statusCode in TransparencyHttpConstants.RETRYABLE_STATUS_CODES) throw TransientStatus(answered.statusCode)
                answered
            }
        } catch (e: TransientStatus) {
            // Retries spent: the batch is unanswered, whatever the status said
            return unreachable(batch, RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            return unreachable(batch, RequestFailure.fromException(e))
        }

        val status = response.statusCode
        val body = response.body?.toByteArray(Charsets.UTF_8) ?: ByteArray(0)
        val statusFailure = if (status == TransparencyHttpConstants.HTTP_STATUS_OK) null else RequestFailure.forHttpStatus(status)
        return parseCrossrefRetractionResponse(status.toUShort(), body, batch.dois).mapValues { (_, result) ->
            if (result !is CrossrefResult.Unreachable) return@mapValues CrossrefAnswer(result, null)
            // bmlib's reason is for the log only (golden rule 13)
            Log.d(TAG, "Crossref answer unreadable: ${result.reason}")
            val failure = statusFailure ?: RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
            CrossrefAnswer(CrossrefResult.Unreachable(failure.describe()), failure)
        }
    }

    private fun unreachable(batch: CrossrefBatch, failure: RequestFailure): Map<String, CrossrefAnswer> {
        val answer = CrossrefAnswer(CrossrefResult.Unreachable(failure.describe()), failure)
        return batch.dois.associateWith { answer }
    }

    /** A status worth another attempt; kept only to be retried, never shown. */
    private class TransientStatus(val statusCode: Int) : Exception()

    private companion object {
        const val TAG = "RetractionCrossref"
        const val USER_AGENT_HEADER = "User-Agent"
    }
}
