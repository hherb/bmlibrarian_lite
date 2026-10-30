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

package com.bmlibrarian.factchecker.util

import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import okhttp3.OkHttpClient
import okhttp3.Request
import okhttp3.Response
import java.io.IOException

/**
 * Execute [request] and hand its response to [block], which reads it, as
 * `newCall(request).execute().use(block)` does, but cancellable (#665).
 *
 * OkHttp's blocking `execute()` and body reads ignore coroutine cancellation, so
 * Cancel would wait for a slow fetch to end. Here a cancelled caller cancels the
 * call, which ends both at once, and the transport failure that follows is
 * thrown as the [kotlinx.coroutines.CancellationException] it is, never as an
 * unreachable source.
 *
 * Call it on a pooled dispatcher (`Dispatchers.IO`): the cancel runs on another
 * of its threads while this one is blocked.
 *
 * @param request The request.
 * @param block Reads the response; it is closed afterwards.
 * @return What [block] returned.
 * @throws IOException if the exchange failed in transport.
 * @throws kotlinx.coroutines.CancellationException if the caller cancelled.
 */
suspend inline fun <T> OkHttpClient.executeCancellably(request: Request, block: (Response) -> T): T {
    val call = newCall(request)
    // UNDISPATCHED: waiting before execute() starts, so no cancel can come too early to be seen
    val canceller = CoroutineScope(currentCoroutineContext()).launch(start = CoroutineStart.UNDISPATCHED) {
        try {
            awaitCancellation()
        } finally {
            call.cancel()
        }
    }
    try {
        return call.execute().use(block)
    } catch (e: IOException) {
        currentCoroutineContext().ensureActive()
        throw e
    } finally {
        canceller.cancel() // also cancels the call, which has ended by now
    }
}
