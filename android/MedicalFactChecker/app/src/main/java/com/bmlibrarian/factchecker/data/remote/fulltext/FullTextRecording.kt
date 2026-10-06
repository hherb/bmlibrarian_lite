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
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.OpenAccessUnsettledReason
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
 * refused, not recorded as found (#478), and once every Unpaywall PDF was
 * refused OpenAlex is asked for the ones it names ([askOpenAlex]); once every
 * candidate, OpenAlex's included, was refused, CORE is asked for its extracted
 * text ([askCore]), last before the DOI link. A Europe PMC
 * PDF that could not be downloaded stays a link-only record of its own (#471);
 * one served and not saved also gets the caching note.
 *
 * @param result What the chain returned
 * @param downloadPdf Downloads a PDF URL
 * @param askOpenAlex Asks OpenAlex for its steps, given the DOI and the
 *   addresses tried or refused; called at most once, and only when no
 *   Unpaywall copy was served (#480). Required: a caller that left it out
 *   would never ask OpenAlex
 * @param askCore Asks CORE for its extracted text, given the DOI; called at most
 *   once, only when every open-access candidate failed and none was served
 *   (#480, stage C). Null is no key: nothing asked, nothing recorded. Required,
 *   with no default, for the same reason as [askOpenAlex]
 * @return The document to store, and the result to show; the document is
 *   unchanged for [FullTextResult.NotEstablished], which is not a fact about
 *   the article and leaves the fetch on offer (#434)
 */
suspend fun DocumentEntity.recordingFullTextFetch(
    result: FullTextResult,
    downloadPdf: suspend (String) -> PdfDownload,
    askOpenAlex: suspend (doi: String, tried: List<String>) -> List<OpenAccessStep>,
    askCore: suspend (doi: String) -> CoreFetch?
): RecordedFetch = when (result) {
    is FullTextResult.OpenAccessPdfs -> obtainingOpenAccessPdf(result, downloadPdf, askOpenAlex, askCore)
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
 * open-access question, so no shortfall is recorded. When no step was served
 * and the chain had not yet asked OpenAlex, it is asked, once, with every
 * address tried, and its steps are walked the same way (the maintainer's
 * decision of 2026-10-05: no OpenAlex request that cannot raise the odds).
 * When still nothing was served, CORE is asked, once, for its extracted text
 * (#480, stage C): served, it is the result, recorded as plain text; unreachable,
 * it is the last shortfall; absent, or without a key, it adds nothing.
 * Otherwise the DOI link carries every shortfall met, in chain order: an
 * unsettled lookup, or a candidate refused under its namer's source with its
 * address (#478's rule).
 *
 * @param result The steps the chain found
 * @param downloadPdf Downloads a PDF URL
 * @param askOpenAlex Asks OpenAlex for its steps, given the DOI and the
 *   addresses tried or refused, in chain order
 * @param askCore Asks CORE for its extracted text, given the DOI
 * @return The document to store, and the result to show
 */
private suspend fun DocumentEntity.obtainingOpenAccessPdf(
    result: FullTextResult.OpenAccessPdfs,
    downloadPdf: suspend (String) -> PdfDownload,
    askOpenAlex: suspend (String, List<String>) -> List<OpenAccessStep>,
    askCore: suspend (String) -> CoreFetch?
): RecordedFetch {
    var shortfall: OpenAccessShortfall? = null
    val tried = mutableListOf<String>()

    /** Walk [steps]; the recorded fetch when a copy was served, else null. */
    suspend fun walk(steps: List<OpenAccessStep>): RecordedFetch? {
        for (step in steps) {
            when (step) {
                is OpenAccessStep.Unsettled -> {
                    tried += step.addresses
                    shortfall = OpenAccessShortfall.adding(step.shortfall, shortfall)
                }
                is OpenAccessStep.Candidate -> {
                    tried += step.addresses
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
        return null
    }

    walk(result.steps)?.let { return it }
    if (!result.openAlexAsked) {
        walk(askOpenAlex(result.doi, tried.toList()))?.let { return it }
    }
    // CORE's extracted text (#480, stage C): every candidate failed, so it can
    // raise the odds. Reached only when no copy was served: a Saved or NotSaved
    // download has already returned above
    when (val fetched = askCore(result.doi)) {
        is CoreFetch.Served -> {
            val text = FullTextResult.CoreText(fetched.text)
            return RecordedFetch(recording(text, pdfPath = null), text)
        }
        is CoreFetch.Unreachable -> shortfall = OpenAccessShortfall.adding(
            OpenAccessShortfall(OpenAccessSource.CORE, OpenAccessUnsettledReason.Failed(fetched.failure)),
            shortfall
        )
        // A skip, not a failure: told as the key, and it keeps the absence unsettled (#498)
        CoreFetch.KeyRefused -> shortfall = OpenAccessShortfall.adding(OpenAccessShortfall.CORE_KEY_REFUSED, shortfall)
        CoreFetch.Absent, null -> Unit
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
 * An answer that brings no text (a PDF, the DOI link, unavailable) clears the
 * text an earlier fetch stored (#495), so no text is ever shown under another
 * answer's source: CORE's text, untrusted, is kept out of the JavaScript-enabled
 * WebView by its source label alone. No flow re-fetches over a stored text
 * today (the cards offer a fetch only without one, and the full-text screen's
 * refresh clears it first), so this guards the record, not a current path.
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
    // Plain text, untrusted: no HTML is stored, so nothing renders it as HTML
    is FullTextResult.CoreText -> copy(
        fullTextMarkdown = result.text,
        fullTextHTML = null,
        fullTextSource = Constants.FULLTEXT_SOURCE_CORE,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.EuropePmcPdf -> copy(
        pdfPath = pdfPath,
        fullTextMarkdown = null,
        fullTextHTML = null,
        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.OpenAccessPdfs -> error("resolved by obtainingOpenAccessPdf before recording")
    is FullTextResult.OpenAccessPdf -> copy(
        pdfPath = pdfPath,
        fullTextMarkdown = null,
        fullTextHTML = null,
        fullTextSource = result.namedBy.fullTextSource,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = if (result.notSaved) result.pdfUrl else null
    )
    is FullTextResult.DoiUrl -> copy(
        fullTextMarkdown = null,
        fullTextHTML = null,
        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = result.openAccessShortfall?.toJson(),
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.Unavailable -> copy(
        fullTextMarkdown = null,
        fullTextHTML = null,
        fullTextUnavailable = true,
        fullTextFetchedAt = Date(),
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    is FullTextResult.NotEstablished -> this
}
