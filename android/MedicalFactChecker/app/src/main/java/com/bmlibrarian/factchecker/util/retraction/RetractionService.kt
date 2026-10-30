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

import android.content.Context
import android.net.ConnectivityManager
import android.util.Log
import com.bmlibrarian.factchecker.data.local.dao.RetractionCheckDao
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.RetractionCheckEntity
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.transparency.usableDoi
import com.bmlibrarian.factchecker.domain.transparency.usablePmid
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import javax.inject.Inject
import javax.inject.Singleton
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

/** The paper a retraction check asks about; types not recorded are asked as none. */
val DocumentEntity.retractionPaper: RetractionPaper
    get() = RetractionPaper(usableDoi, usablePmid, publicationTypes.orEmpty())

/**
 * The app's retraction checking: the production check over the local
 * Retraction Watch index and one Crossref lookup per process (per contact
 * address), and each paper's stored row.
 */
@Singleton
class RetractionService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val settingsRepository: SettingsRepository,
    private val retractionCheckDao: RetractionCheckDao,
) {
    /** The export's downloads outlive any run: a stopped run never stops one. */
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val store by lazy {
        RetractionIndexStore(File(context.noBackupFilesDir, RetractionConstants.RETRACTION_FOLDER_NAME), isUnmetered = ::isUnmetered)
    }

    @Volatile private var crossref: Pair<String, RetractionCrossrefLookup>? = null

    /** The contact address sent to Crossref, as the transparency runner sends it. */
    private fun email(): String = settingsRepository.getNcbiEmail().trim().ifEmpty { Constants.UNPAYWALL_DEFAULT_EMAIL }

    /** The one lookup for this address, so pacing holds across every screen (#647). */
    private fun lookup(): RetractionCrossrefLookup {
        val email = email()
        crossref?.let { (builtFor, lookup) -> if (builtFor == email) return lookup }
        return RetractionCrossrefLookup(email).also { crossref = email to it }
    }

    private fun isUnmetered(): Boolean {
        val connectivity = context.getSystemService(ConnectivityManager::class.java) ?: return false
        return connectivity.activeNetwork != null && !connectivity.isActiveNetworkMetered
    }

    /**
     * Check [papers]: the current index (never waited for; refreshed at
     * launch, and in the background when there is none), Crossref and each
     * paper's label.
     *
     * @param papers The papers
     * @return A check per paper
     */
    suspend fun check(papers: List<RetractionPaper>): Map<RetractionPaper, PaperRetractionCheck> {
        val now = System.currentTimeMillis()
        val index = withContext(Dispatchers.IO) { store.currentIndex(now) }
        // a failed or aged-out refresh is tried again, for the next run
        if (index == null) refreshInBackground()
        return RetractionChecker(index, lookup()::results).check(papers, now)
    }

    /** Refresh the local Retraction Watch copy if it is stale, without waiting; the outcome is logged. */
    fun refreshInBackground() {
        scope.launch {
            try {
                Log.i(TAG, "Retraction Watch refresh: ${store.refreshIfStale(System.currentTimeMillis(), email())}")
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.w(TAG, "Retraction Watch refresh failed: ${e.javaClass.simpleName}")
            } catch (e: LinkageError) {
                // a build without bmlib's native library: nothing to refresh with
                Log.w(TAG, "Retraction Watch refresh unavailable: ${e.javaClass.simpleName}")
            } catch (e: OutOfMemoryError) {
                // a small heap cannot build the ~68 MB export: the app runs on without it, never crashed by it
                Log.w(TAG, "Retraction Watch refresh ran out of memory")
            }
        }
    }

    /**
     * The stored rows of these papers.
     *
     * @param paperKeys The papers' keys
     * @return Each stored row's JSON, by key
     */
    suspend fun storedChecks(paperKeys: Collection<String>): Map<String, String> =
        if (paperKeys.isEmpty()) emptyMap()
        else retractionCheckDao.get(paperKeys.toList()).associate { it.paperKey to it.checkJson }

    /**
     * Store these checks as their papers' rows.
     *
     * @param checks The checks, by paper key
     */
    suspend fun store(checks: Map<String, PaperRetractionCheck>) {
        if (checks.isEmpty()) return
        retractionCheckDao.upsert(checks.map { (key, check) -> RetractionCheckEntity(key, PaperRetractionCheck.encode(check)) })
    }

    private companion object {
        const val TAG = "RetractionService"
    }
}
