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
 * What a full-text fetch comes to once its PDF was downloaded, or was not.
 *
 * @property document The document to store
 * @property result The chain's answer as the reader is to be shown it: the
 *   chain's own, except a PDF Unpaywall named that the source did not serve,
 *   which becomes the DOI link carrying why ([FullTextResult.UnpaywallPdf.refused])
 */
data class RecordedFetch(val document: DocumentEntity, val result: FullTextResult)

/**
 * The document as a full-text fetch leaves it: what the chain found, recorded on
 * the row.
 *
 * One writer for the fact-check, report and full-text screens, which each kept
 * their own copy of this mapping. Every branch writes the open-access shortfall
 * (#466): the DOI fallback stores why the open-access copy went unassessed, and
 * every other answer clears what an earlier fetch stored, so the cards never say
 * a free copy may exist after a fetch settled it.
 *
 * The PDF is downloaded here. A PDF Unpaywall named that the source did not
 * serve is refused, not recorded as found (#478): the document is recorded as
 * the DOI link, with the PDF's shortfall, as the chain would have ended had
 * Unpaywall named no PDF. One the source served that could not be saved is a
 * fault of ours, which says nothing about the copy: it stays a link-only
 * record with no shortfall, as BioMedLit keeps its link. A Europe PMC PDF that
 * could not be downloaded stays a link-only record of its own (#471).
 *
 * @param result What the chain returned
 * @param downloadPdf Downloads a PDF URL
 * @return The document to store, and the result to show; the document is
 *   unchanged for [FullTextResult.NotEstablished], which is not a fact about
 *   the article and leaves the fetch on offer (#434)
 */
suspend fun DocumentEntity.recordingFullTextFetch(
    result: FullTextResult,
    downloadPdf: suspend (String) -> PdfDownload
): RecordedFetch = when (result) {
    is FullTextResult.UnpaywallPdf -> when (val download = downloadPdf(result.pdfUrl)) {
        is PdfDownload.Saved -> RecordedFetch(recording(result, download.path), result)
        is PdfDownload.Failed -> result.refused(download.failure).let { refused ->
            RecordedFetch(recording(refused, pdfPath = null), refused)
        }
        // Served, but not saved: our fault, so the PDF's link is kept
        PdfDownload.NotSaved -> RecordedFetch(recording(result, pdfPath = null), result)
    }
    is FullTextResult.EuropePmcPdf ->
        RecordedFetch(recording(result, downloadPdf(result.pdfUrl).savedPath), result)
    else -> RecordedFetch(recording(result, pdfPath = null), result)
}

/**
 * The document as an answer leaves it, its PDF already downloaded or not.
 *
 * @param result What the chain came to
 * @param pdfPath Where its PDF was saved; null when nothing was
 * @return The document to store
 */
private fun DocumentEntity.recording(result: FullTextResult, pdfPath: String?): DocumentEntity = when (result) {
    is FullTextResult.EuropePmcXml -> copy(
        fullTextMarkdown = result.markdown,
        fullTextHTML = result.html,
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.EuropePmcPdf -> copy(
        pdfPath = pdfPath,
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null
    )
    is FullTextResult.UnpaywallPdf -> copy(
        pdfPath = pdfPath,
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
