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
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import java.io.File
import java.io.IOException
import java.time.Instant
import java.time.LocalDate
import java.time.ZoneOffset
import java.time.format.DateTimeParseException
import java.time.temporal.ChronoUnit
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.HttpUrl.Companion.toHttpUrlOrNull
import okhttp3.OkHttpClient
import okhttp3.Request
import org.bmlib.ffi.RetractionIndex
import org.bmlib.ffi.RetractionIndexException
import org.bmlib.ffi.buildRetractionIndex
import org.bmlib.ffi.crossrefRetractionRequests

/** What a [RetractionIndexStore.refreshIfStale] did. */
sealed class RetractionIndexRefresh {
    /** The stored index is current; nothing was downloaded. */
    data object Fresh : RetractionIndexRefresh()

    /** The network is metered, so the ~68 MB export was not downloaded. */
    data object Metered : RetractionIndexRefresh()

    /** A new index was built and stored. */
    data class Refreshed(val noticeCount: Long) : RetractionIndexRefresh()

    /**
     * The download arrived but was not stored, or a recent one was refused;
     * the previous file is kept. The text is for the log: this app's, never
     * the provider's.
     */
    data class Refused(val reason: String) : RetractionIndexRefresh()

    /** The download failed; the previous file is kept. */
    data class Failed(val failure: RequestFailure) : RetractionIndexRefresh()
}

/**
 * The local Retraction Watch index: one file, built by bmlib from Crossref's
 * export and replaced whole (Swift's `RetractionIndexStore`).
 *
 * @param directory Where the index file lives
 * @param httpClient The client the export is downloaded with
 * @param isUnmetered Whether the active network is unmetered; the export is
 *   downloaded only then
 * @param exportUrl The export's address
 */
class RetractionIndexStore(
    private val directory: File,
    private val httpClient: OkHttpClient = defaultExportClient(),
    private val isUnmetered: () -> Boolean,
    private val exportUrl: String = RetractionConstants.RETRACTION_WATCH_EXPORT_URL,
) {
    private val file = File(directory, RetractionConstants.RETRACTION_INDEX_FILE_NAME)

    /** One download at a time: a caller meanwhile waits, then finds the new copy. */
    private val downloading = Mutex()

    /** The last index read, with the file's modification time it was read at. */
    @Volatile private var cached: Pair<Long, RetractionIndex>? = null

    /** When a download was last refused, and why; the next waits a day (#647). */
    @Volatile private var lastRefusal: Pair<Long, String>? = null

    /** The stored index, whatever its age; null when missing or unreadable. */
    private fun storedIndex(): RetractionIndex? {
        val modified = file.lastModified()
        if (modified == 0L) return null
        cached?.let { (at, index) -> if (at == modified) return index }
        return try {
            RetractionIndex.fromBytes(file.readBytes()).also { cached = modified to it }
        } catch (e: IOException) {
            Log.w(TAG, "Retraction Watch index unreadable: ${e.javaClass.simpleName}")
            null
        } catch (e: RetractionIndexException) {
            Log.w(TAG, "Retraction Watch index unreadable: ${e.javaClass.simpleName}")
            null
        }
    }

    /**
     * The index to consult.
     *
     * @param nowMs The current time
     * @return Null when the file is missing, unreadable, or its `dataAsOf` is
     *   more than [RetractionConstants.RETRACTION_WATCH_MAX_AGE_DAYS] days
     *   before today (UTC): the export is then not consulted
     */
    fun currentIndex(nowMs: Long): RetractionIndex? {
        val index = storedIndex() ?: return null
        val asOf = try {
            LocalDate.parse(index.dataAsOf())
        } catch (e: DateTimeParseException) {
            return null
        }
        val age = ChronoUnit.DAYS.between(asOf, today(nowMs))
        return index.takeIf { age <= RetractionConstants.RETRACTION_WATCH_MAX_AGE_DAYS }
    }

    /**
     * Download and store a new index unless the stored one is current.
     *
     * bmlib builds the index, dated today; one under
     * [RetractionConstants.RETRACTION_WATCH_MIN_KEEP_RATIO] of the stored
     * index's notices is refused as truncated. On anything but [RetractionIndexRefresh.Refreshed]
     * the file is untouched. Never throws, but for cancellation.
     *
     * @param nowMs The current time
     * @param email Contact address, sent as `mailto=` and in the User-Agent
     */
    suspend fun refreshIfStale(nowMs: Long, email: String): RetractionIndexRefresh = downloading.withLock {
        if (currentIndex(nowMs) != null) return@withLock RetractionIndexRefresh.Fresh
        lastRefusal?.let { (at, reason) ->
            if (nowMs - at < RetractionConstants.RETRACTION_WATCH_REFUSED_BACKOFF_MS) return@withLock RetractionIndexRefresh.Refused(reason)
        }
        if (!isUnmetered()) return@withLock RetractionIndexRefresh.Metered
        if (!bmlibLoads()) return@withLock RetractionIndexRefresh.Refused("bmlib's native library is missing")
        withContext(Dispatchers.IO) { refresh(nowMs, email) }.also {
            if (it is RetractionIndexRefresh.Refused) lastRefusal = nowMs to it.reason
        }
    }

    /** [refreshIfStale]'s work, run once per download. */
    private fun refresh(nowMs: Long, email: String): RetractionIndexRefresh {
        val url = exportUrl.toHttpUrlOrNull()?.newBuilder()?.addQueryParameter("mailto", email)?.build()
            ?: return RetractionIndexRefresh.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        val request = Request.Builder()
            .url(url)
            .header("User-Agent", "${RetractionConstants.USER_AGENT_PRODUCT} (mailto:$email)")
            .build()

        val incomplete = RetractionIndexRefresh.Failed(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
        val body = try {
            httpClient.newCall(request).execute().use { response ->
                if (response.code != HTTP_OK) return RetractionIndexRefresh.Failed(RequestFailure.forHttpStatus(response.code))
                // OkHttp refuses a body shorter than its Content-Length: a download cut short ends here
                try {
                    response.body?.bytes()
                } catch (e: IOException) {
                    return incomplete
                } ?: return incomplete
            }
        } catch (e: IOException) {
            return RetractionIndexRefresh.Failed(RequestFailure.fromException(e))
        }

        val build = try {
            buildRetractionIndex(body, today(nowMs).toString())
        } catch (e: RetractionIndexException) {
            Log.w(TAG, "Retraction Watch export refused: ${e.javaClass.simpleName}")
            return RetractionIndexRefresh.Refused("the export could not be built")
        }
        if (build.skippedRows > 0u) Log.i(TAG, "Retraction Watch export: ${build.skippedRows} rows skipped")
        if (build.unknownNatures.isNotEmpty()) {
            // Their notices decide nothing: Retraction Watch's vocabulary moved
            Log.w(TAG, "Retraction Watch natures not recognised: ${build.unknownNatures.joinToString()}")
        }
        val count = build.index.noticeCount().toLong()
        val old = storedIndex()?.noticeCount()?.toLong()
        if (old != null && count < old * RetractionConstants.RETRACTION_WATCH_MIN_KEEP_RATIO) {
            Log.w(TAG, "Retraction Watch export shrank from $old to $count notices")
            return RetractionIndexRefresh.Refused("the export shrank from $old to $count notices")
        }
        val temporary = File(directory, "${RetractionConstants.RETRACTION_INDEX_FILE_NAME}.part")
        try {
            directory.mkdirs()
            temporary.writeBytes(build.index.toBytes())
            if (!temporary.renameTo(file)) throw IOException("rename failed")
        } catch (e: IOException) {
            temporary.delete()
            Log.w(TAG, "Retraction Watch index not stored: ${e.javaClass.simpleName}")
            return RetractionIndexRefresh.Refused("the index could not be stored")
        }
        cached = file.lastModified() to build.index
        return RetractionIndexRefresh.Refreshed(count)
    }

    companion object {
        private const val TAG = "RetractionIndexStore"
        private const val HTTP_OK = 200

        /**
         * Whether bmlib's native library loads: a debug build without it could
         * not build the index, so the ~68 MB export is never downloaded for nothing.
         */
        private fun bmlibLoads(): Boolean = try {
            crossrefRetractionRequests(emptyList(), null)
            true
        } catch (e: LinkageError) {
            false
        }

        /** Today's UTC day, the form bmlib's `dataAsOf` takes. */
        internal fun today(nowMs: Long): LocalDate = Instant.ofEpochMilli(nowMs).atOffset(ZoneOffset.UTC).toLocalDate()

        /** The export's client: an idle timeout long enough for a slow link, not one for the whole transfer. */
        fun defaultExportClient(): OkHttpClient = OkHttpClient.Builder()
            .readTimeout(RetractionConstants.RETRACTION_WATCH_DOWNLOAD_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .build()
    }
}
