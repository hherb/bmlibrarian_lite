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

import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import okhttp3.mockwebserver.MockWebServer
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue

/** Far longer than any test, so only a cancel can end a call early. */
const val SLOW_SECONDS = 60L

/** How soon a cancelled call must end (#665). */
const val CANCEL_WITHIN_MS = 5_000L

/** Interval at which [awaitFileEndingWith] looks again. */
private const val FILE_POLL_MS = 10L

/**
 * Start [fetch], wait until [server] holds its request and [inFlight] returns,
 * cancel, and answer what [fetch] threw.
 *
 * Fails if the cancel takes longer than [CANCEL_WITHIN_MS] to end it (#665).
 *
 * @param inFlight Blocks until the fetch is where the cancel should land.
 */
fun cancelInFlight(
    server: MockWebServer,
    inFlight: () -> Unit = {},
    fetch: suspend () -> Unit
): Throwable? = runBlocking {
    var thrown: Throwable? = null
    val job = launch(Dispatchers.IO) {
        try {
            fetch()
        } catch (e: Throwable) {
            thrown = e
            throw e
        }
    }
    assertNotNull(server.takeRequest(SLOW_SECONDS, TimeUnit.SECONDS))
    inFlight()
    withTimeout(CANCEL_WITHIN_MS) { job.cancelAndJoin() }
    thrown
}

/** Wait, up to [SLOW_SECONDS], until a file under [dir] has a name ending with [suffix]. */
fun awaitFileEndingWith(dir: File, suffix: String) {
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(SLOW_SECONDS)
    while (dir.walkTopDown().none { it.isFile && it.name.endsWith(suffix) }) {
        assertTrue("no file ending with $suffix was written", System.nanoTime() < deadline)
        Thread.sleep(FILE_POLL_MS)
    }
}
