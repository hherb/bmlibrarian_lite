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

package com.bmlibrarian.factchecker.data.remote

import android.util.Log
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import retrofit2.Response
import kotlin.coroutines.cancellation.CancellationException

// How the PubMed and Europe PMC clients send a search request (#252). A failure
// is reduced to its RequestFailure where it is met: the transport's error is not
// kept and an answer's body is never read, so nothing built here can carry a
// request or an answer's text.

/**
 * Run a request to a literature source, retrying it while its failure is transient.
 *
 * @param block The request, failing with a [SourceRequestException]
 * @return What the request returned
 * @throws SourceRequestException when it failed and retrying would not help, or the retries ran out
 */
internal suspend fun <T> withSourceRetries(block: suspend () -> T): T =
    NetworkRetry.withExponentialBackoff(
        maxRetries = Constants.NETWORK_MAX_RETRIES,
        shouldRetry = { e -> e is SourceRequestException && e.failure.isRetryable }
    ) { block() }

/**
 * Send one request to a literature source and refuse an unsuccessful answer.
 *
 * An error the transport raised is reduced to its [RequestFailure] and logged by
 * class only, since a converter's message quotes the body it could not read.
 * Cancellation is rethrown, so a cancelled search stays cancelled.
 *
 * @param provider The source
 * @param logTag The tag a failed request is logged under
 * @param statusFailure The failure an unsuccessful status stands for, read from the status line alone
 * @param request The Retrofit call
 * @return The successful response
 * @throws SourceRequestException if the request failed or the status is not 2xx
 */
internal suspend fun <T> sendSourceRequest(
    provider: SearchProvider,
    logTag: String,
    statusFailure: (Int) -> RequestFailure,
    request: suspend () -> Response<T>
): Response<T> {
    val response = try {
        request()
    } catch (e: CancellationException) {
        throw e
    } catch (e: Exception) {
        val failure = RequestFailure.fromException(e)
        Log.w(logTag, "${provider.displayName} request failed: ${failure.describe()} (${e.javaClass.simpleName})")
        throw SourceRequestException(provider, failure)
    }
    if (!response.isSuccessful) {
        throw SourceRequestException(provider, statusFailure(response.code()))
    }
    return response
}

/**
 * Build the error for a literature source's answer that cannot be read, and log why.
 *
 * @param provider The source
 * @param logTag The tag the reason is logged under
 * @param reason What was wrong, naming fields only, never their values
 * @return The error to throw
 */
internal fun unreadableSourceAnswer(provider: SearchProvider, logTag: String, reason: String): SourceRequestException {
    Log.e(logTag, "Unreadable ${provider.displayName} answer: $reason")
    return SourceRequestException(provider, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
}
