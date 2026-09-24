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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.transparency.ClinicalTrialsService
import com.bmlibrarian.factchecker.data.remote.transparency.CrossRefService
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.transparency.TransparencyAnalysisService
import com.bmlibrarian.factchecker.domain.transparency.TransparencyResult
import com.bmlibrarian.factchecker.domain.transparency.analyzableFullText
import com.bmlibrarian.factchecker.domain.transparency.storedMetadataLookup
import com.bmlibrarian.factchecker.domain.transparency.usableDoi
import com.bmlibrarian.factchecker.domain.transparency.usablePmid
import com.bmlibrarian.factchecker.util.Constants
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Runs the transparency analysis for one document at a time.
 *
 * Holds one CrossRef and one ClinicalTrials.gov client for the app's lifetime,
 * so their request pacing spans every document rather than restarting per
 * document. The CrossRef client is rebuilt only when the contact email changes.
 */
@Singleton
class TransparencyAnalysisRunner @Inject constructor(
    private val settingsRepository: SettingsRepository
) {
    private val clinicalTrialsService = ClinicalTrialsService()

    /** The CrossRef client and the contact email it was built with. */
    @Volatile
    private var crossRef: Pair<String, CrossRefService>? = null

    /**
     * Analyse a document's transparency.
     *
     * Its metadata comes from what the search stored; the full text is whatever
     * [analyzableFullText] allows, which is currently none, so the result
     * records that the full text was not searched.
     *
     * @param document The document to analyse; it must have a PMID or DOI.
     * @return The analysis result.
     * @throws com.bmlibrarian.factchecker.domain.transparency.TransparencyAnalysisException.NoIdentifiers
     *   when the document has neither.
     */
    suspend fun analyze(document: DocumentEntity): TransparencyResult =
        TransparencyAnalysisService(
            metadataLookup = storedMetadataLookup(document),
            crossRefService = crossRefService(),
            clinicalTrialsService = clinicalTrialsService
        ).analyze(
            doi = document.usableDoi,
            pmid = document.usablePmid,
            fullText = document.analyzableFullText
        )

    /** The CrossRef client for the current contact email. */
    private fun crossRefService(): CrossRefService {
        val email = settingsRepository.getNcbiEmail().trim().ifEmpty { Constants.UNPAYWALL_DEFAULT_EMAIL }
        crossRef?.let { (builtFor, service) -> if (builtFor == email) return service }
        return CrossRefService(email).also { crossRef = email to it }
    }
}
