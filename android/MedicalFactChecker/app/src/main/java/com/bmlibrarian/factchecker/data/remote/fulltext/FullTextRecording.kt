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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.util.Constants
import java.util.Date

/**
 * The document as a full-text fetch leaves it: what the chain found, recorded on
 * the row.
 *
 * One writer for the fact-check and report screens, which each kept their own
 * copy of this mapping. Every branch writes the open-access shortfall (#466):
 * the DOI fallback stores why the open-access copy went unassessed, and every
 * other answer clears what an earlier fetch stored, so the cards never say a
 * free copy may exist after a fetch settled it.
 *
 * @param result What the chain returned
 * @param downloadPdf Downloads a PDF URL, answering its local path or null
 * @return The document to store; unchanged for [FullTextResult.NotEstablished],
 *   which is not a fact about the article and leaves the fetch on offer (#434)
 */
suspend fun DocumentEntity.recordingFullTextFetch(
    result: FullTextResult,
    downloadPdf: suspend (String) -> String?
): DocumentEntity = when (result) {
    is FullTextResult.EuropePmcXml -> copy(
        fullTextMarkdown = result.markdown,
        fullTextHTML = result.html,
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.EuropePmcPdf -> copy(
        pdfPath = downloadPdf(result.pdfUrl),
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.UnpaywallPdf -> copy(
        pdfPath = downloadPdf(result.pdfUrl),
        fullTextSource = Constants.FULLTEXT_SOURCE_UNPAYWALL,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.DoiUrl -> copy(
        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = result.openAccessShortfall?.toJson()
    )
    is FullTextResult.Unavailable -> copy(
        fullTextUnavailable = true,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.NotEstablished -> this
}
