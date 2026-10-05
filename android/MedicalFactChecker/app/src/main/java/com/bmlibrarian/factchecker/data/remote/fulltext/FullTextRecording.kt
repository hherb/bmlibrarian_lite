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
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.util.Constants
import java.util.Date

/**
 * What a full-text fetch comes to once its PDF was downloaded, or was not.
 *
 * @property document The document to store
 * @property result The chain's answer as the reader is to be shown it: the
 *   chain's own, except the open-access PDFs to try, which become the one
 *   obtained ([FullTextResult.OpenAccessPdf]) or, when none was, the DOI link
 *   carrying every shortfall met
 */
data class RecordedFetch(val document: DocumentEntity, val result: FullTextResult)

/**
 * The document as a full-text fetch leaves it: what the chain found, recorded on
 * the row.
 *
 * One writer for the fact-check, report and full-text screens, which each kept
 * their own copy of this mapping. Every branch writes the open-access shortfall
 * (#466) and the caching note (#480): the DOI fallback stores why the
 * open-access copy went unassessed, a PDF served but not saved stores where it
 * was found, and every other answer clears what an earlier fetch stored, so the
 * cards never say a free copy may exist after a fetch settled it.
 *
 * The PDFs are downloaded here. The open-access PDFs are walked in chain order
 * ([obtainingOpenAccessPdf]): a PDF a source named that it did not serve is
 * refused, not recorded as found (#478). A Europe PMC PDF that could not be
 * downloaded stays a link-only record of its own (#471); one served and not
 * saved also gets the caching note.
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
    is FullTextResult.OpenAccessPdfs -> obtainingOpenAccessPdf(result, downloadPdf)
    is FullTextResult.EuropePmcPdf -> when (val download = downloadPdf(result.pdfUrl)) {
        PdfDownload.NotSaved ->
            RecordedFetch(recording(result, pdfPath = null).copy(fullTextPdfNotSavedFrom = result.pdfUrl), result)
        else -> RecordedFetch(recording(result, download.savedPath), result)
    }
    else -> RecordedFetch(recording(result, pdfPath = null), result)
}

/**
 * Walk the open-access steps in chain order (#480, stage B).
 *
 * The first candidate served ends the walk: saved, it is the result; served but
 * not saved, its link is kept with a caching note, and nothing further is asked
 * (saving is our problem, not the source's), and a served copy settles the
 * open-access question, so no shortfall is recorded. Otherwise the DOI link
 * carries every shortfall met, in order: an unsettled lookup, or a candidate
 * refused under its namer's source with its address (#478's rule, the
 * maintainer's decision of 2026-10-05).
 *
 * @param result The steps the chain found
 * @param downloadPdf Downloads a PDF URL
 * @return The document to store, and the result to show
 */
private suspend fun DocumentEntity.obtainingOpenAccessPdf(
    result: FullTextResult.OpenAccessPdfs,
    downloadPdf: suspend (String) -> PdfDownload
): RecordedFetch {
    var shortfall: OpenAccessShortfall? = null
    for (step in result.steps) {
        when (step) {
            is OpenAccessStep.Unsettled -> shortfall = OpenAccessShortfall.adding(step.shortfall, shortfall)
            is OpenAccessStep.Candidate -> {
                val found = FullTextResult.OpenAccessPdf(step.pdfUrl, result.doi, step.namedBy)
                when (val download = downloadPdf(step.pdfUrl)) {
                    is PdfDownload.Saved -> return RecordedFetch(recording(found, download.path), found)
                    PdfDownload.NotSaved -> {
                        val linked = found.copy(notSaved = true)
                        return RecordedFetch(recording(linked, pdfPath = null), linked)
                    }
                    is PdfDownload.Failed -> shortfall = OpenAccessShortfall.adding(
                        OpenAccessShortfall(step.namedBy.refusedAs, download.failure, step.pdfUrl), shortfall
                    )
                }
            }
        }
    }
    val refused = FullTextResult.DoiUrl(doiLink(result.doi), shortfall)
    return RecordedFetch(recording(refused, pdfPath = null), refused)
}

/**
 * The document as an answer leaves it, its PDF already downloaded or not.
 *
 * Every answer clears the caching note an earlier fetch left, except an
 * open-access PDF served and not saved, which writes its own.
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
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.PmcOpenDataXml -> copy(
        fullTextMarkdown = result.markdown,
        fullTextHTML = result.html,
        fullTextSource = Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.EuropePmcPdf -> copy(
        pdfPath = pdfPath,
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.OpenAccessPdfs -> error("resolved by obtainingOpenAccessPdf before recording")
    is FullTextResult.OpenAccessPdf -> copy(
        pdfPath = pdfPath,
        fullTextSource = result.namedBy.fullTextSource,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = if (result.notSaved) result.pdfUrl else null
    )
    is FullTextResult.DoiUrl -> copy(
        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = result.openAccessShortfall?.toJson(),
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.Unavailable -> copy(
        fullTextUnavailable = true,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.NotEstablished -> this
}
