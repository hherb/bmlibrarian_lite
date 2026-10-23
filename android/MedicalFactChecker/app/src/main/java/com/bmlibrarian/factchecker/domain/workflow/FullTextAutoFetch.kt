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

import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.TextWindows

/**
 * The rules of the automatic full-text step: which papers are fetched in full,
 * and which text citation extraction reads.
 *
 * Pure functions, so the rules can be tested without a workflow, a network or a
 * database. Mirrors iOS/macOS's `FullTextAutoFetch`.
 */
object FullTextAutoFetch {

    /**
     * The lowest score fetched: the user's full-text score, but never below the
     * user's own relevance threshold.
     *
     * A paper under that threshold is not in the report, so fetching it would
     * spend retrieval time on text nothing reads.
     *
     * @param relevanceThreshold The user's relevance threshold (1-5)
     * @param autoFetchMinScore The user's full-text score (1-5)
     * @return The lowest score (1-5) whose papers are fetched
     */
    fun minimumScore(relevanceThreshold: Int, autoFetchMinScore: Int): Int = maxOf(autoFetchMinScore, relevanceThreshold)

    /**
     * The documents to fetch full text for.
     *
     * A document qualifies when it scores high enough, holds no full text, and
     * there is something to look it up by; on a run, only one never attempted,
     * since asking again for a paper no source had repeats the same failing round
     * trips. A retry the reader asks for asks again for those too: a source may
     * have gained a copy since. A link-only record (a PDF found and not
     * downloaded) is asked again only on a retry, as the full-text screen would
     * (differs from Swift, which re-fetches a link-only record on every run: #615).
     *
     * @param documents Candidate documents, in the order to fetch them
     * @param relevanceThreshold The user's relevance threshold (1-5)
     * @param autoFetchMinScore The user's full-text score (1-5)
     * @param retrying Whether the reader asked to retry, so attempted documents count
     * @return The qualifying documents, in the order given
     */
    fun documentsToFetch(
        documents: List<DocumentEntity>,
        relevanceThreshold: Int,
        autoFetchMinScore: Int,
        retrying: Boolean = false
    ): List<DocumentEntity> {
        val minimum = minimumScore(relevanceThreshold, autoFetchMinScore)
        return documents.filter { document ->
            meetsThreshold(document, minimum) &&
                !document.hasFullText &&
                (retrying || !(document.fullTextFetchedAt != null || document.fullTextUnavailable)) &&
                hasIdentifier(document)
        }
    }

    /**
     * The article text to give citation extraction, whole: it is read in windows
     * ([TextWindows.analysisWindows]), never cut.
     *
     * Null when the document has no full text the analysis may read
     * ([DocumentEntity.analysisFullText]), which includes an abstract-only
     * deposit (its text is the abstract), and when nothing comes before the
     * reference list, which is never read.
     *
     * @param document The document to read
     * @return The text, or null
     */
    fun citationText(document: DocumentEntity): String? =
        document.analysisFullText?.takeIf { TextWindows.analysisWindows(it).isNotEmpty() }

    /**
     * The article text citation extraction should read for one document.
     *
     * Only for the papers the setting is about, so a text fetched by hand for a
     * lower-scored paper does not change what that paper costs. A text the reader
     * uploaded is always read: they chose it for the analysis.
     *
     * @param document The document to read
     * @param config The run's configuration: the setting, the threshold and the full-text score
     * @return The text, or null to use the abstract
     */
    fun citationFullText(document: DocumentEntity, config: WorkflowConfig): String? {
        val covered = document.holdsUploadedFullText ||
            (config.autoFetchFullText &&
                meetsThreshold(document, minimumScore(config.relevanceThreshold, config.fullTextAutoFetchMinScore)))
        return if (covered) citationText(document) else null
    }

    /**
     * Whether a paper's citations have not read the full text it now holds.
     *
     * As recorded by [DocumentEntity.citationsReadFullText]. A record from before
     * that was kept judges by dates instead: a citation older than the full text
     * may have been taken from the abstract.
     *
     * @param document The document
     * @param citationTimes When each of its citations was extracted
     * @return Whether it holds a readable full text its citations have not read
     */
    fun fullTextUnreadByCitations(document: DocumentEntity, citationTimes: List<java.util.Date>): Boolean {
        if (document.analysisFullText == null) return false
        document.citationsReadFullText?.let { return !it }
        val fetched = document.fullTextFetchedAt ?: return false
        return citationTimes.any { it.before(fetched) }
    }

    /**
     * Whether a relevant paper has a full text its citations have not read, and
     * that citation extraction would read now.
     *
     * @param document The document
     * @param citationTimes When each of its citations was extracted
     * @param config The run's configuration
     * @return Whether a retry would extract its citations again from the text
     */
    fun hasUnreadFullText(document: DocumentEntity, citationTimes: List<java.util.Date>, config: WorkflowConfig): Boolean =
        meetsThreshold(document, config.relevanceThreshold) &&
            fullTextUnreadByCitations(document, citationTimes) &&
            citationFullText(document, config) != null

    /**
     * What a retry of full-text retrieval would do, for the screen to offer the
     * retry beside; null when it would do nothing.
     *
     * With the setting on, a paper scored high enough has no full text; or a
     * relevant paper has a full text (an upload, say) its citations have not read.
     *
     * @param documents The session's documents
     * @param citationsByDocument Their citations, by document ID
     * @param config The current configuration
     * @return The sentences to show, or null
     */
    fun retryNotice(
        documents: List<DocumentEntity>,
        citationsByDocument: Map<String, List<CitationEntity>>,
        config: WorkflowConfig
    ): String? {
        val missing = if (config.autoFetchFullText) {
            documentsToFetch(documents, config.relevanceThreshold, config.fullTextAutoFetchMinScore, retrying = true).size
        } else {
            0
        }
        val unread = documents.count { document ->
            hasUnreadFullText(document, citationsByDocument[document.id].orEmpty().map { it.createdAt }, config)
        }
        val minimum = minimumScore(config.relevanceThreshold, config.fullTextAutoFetchMinScore)
        val sentences = buildList {
            if (missing > 0) {
                add(
                    if (missing == 1) "1 paper scored $minimum or higher has no full text."
                    else "$missing papers scored $minimum or higher have no full text."
                )
            }
            if (unread > 0) {
                add(
                    if (unread == 1) "1 paper has a full text the analysis has not read yet."
                    else "$unread papers have a full text the analysis has not read yet."
                )
            }
        }
        return sentences.takeIf { it.isNotEmpty() }?.joinToString(" ")
    }

    /**
     * Keep full texts only while the estimated input cost fits the budget left.
     *
     * The run budget is checked once before the citation calls are made, and a
     * paper's calls read its whole full text, so the check alone no longer bounds
     * what the batch can spend. Each text is kept while the estimated cost of all
     * its windows (overlaps included) fits what is left; one that does not fit
     * falls back to its abstract, and a later, shorter text may still be kept.
     *
     * @param inputs The citation inputs, in the order they are paid for
     * @param remainingUsd What the run may still spend
     * @param usdPerInputToken The model's price for one input token
     * @return The inputs to send, and how many lost their full text
     */
    fun fittingBudget(
        inputs: List<CitationInput>,
        remainingUsd: Double,
        usdPerInputToken: Double
    ): Pair<List<CitationInput>, Int> {
        var remaining = remainingUsd
        var dropped = 0
        val fitted = inputs.map { input ->
            if (input.fullText == null) return@map input
            val characters = input.windows.sumOf { it.length }
            val cost = characters.toDouble() / Constants.TOKEN_ESTIMATE_CHARS_PER_TOKEN * usdPerInputToken
            if (cost <= remaining) {
                remaining -= cost
                input
            } else {
                dropped += 1
                input.withoutFullText()
            }
        }
        return fitted to dropped
    }

    /**
     * The notice for full texts left out to stay within the run budget.
     *
     * @param count How many papers were read from the abstract instead
     * @return A sentence saying so
     */
    fun budgetNotice(count: Int): String =
        "To stay within the run budget, $count paper${if (count == 1) "" else "s"} " +
            "scored for full text ${if (count == 1) "was" else "were"} read from the abstract instead."

    /**
     * A one-line summary of the documents whose full text could not be fetched.
     *
     * Names them while the list is short, counts past that; each failure is
     * logged individually either way.
     *
     * @param titles Titles of the documents that failed, in run order
     * @return A sentence naming or counting the failures
     */
    fun failureNotice(titles: List<String>): String =
        if (titles.size <= Constants.MAX_FAILED_TITLES_TO_NAME) {
            "Full text could not be retrieved or stored for: ${titles.joinToString("; ")}. " +
                "Where none was stored, the abstract was used."
        } else {
            "Full text could not be retrieved or stored for ${titles.size} documents. " +
                "Where none was stored, the abstract was used."
        }

    /**
     * The notice for full texts whose citation extraction failed.
     *
     * @param count How many papers' extraction failed
     * @return A sentence saying so; each failure is logged as it arrives
     */
    fun extractionFailureNotice(count: Int): String =
        "Citations could not be extracted from $count full text${if (count == 1) "" else "s"}; " +
            "${if (count == 1) "that paper keeps the citations it had" else "those papers keep the citations they had"}. " +
            "Try again later."

    /** Whether a document scores at least [minimum]. */
    private fun meetsThreshold(document: DocumentEntity, minimum: Int): Boolean = (document.relevanceScore ?: 0) >= minimum

    /**
     * Whether the retrieval chain has anything to look the document up by.
     *
     * The PMID slot counts as well as the PMC ID and DOI: it also holds a
     * preprint's accession, which the chain resolves.
     */
    private fun hasIdentifier(document: DocumentEntity): Boolean =
        listOf(document.pmcId, document.doi, document.pmid).any { !it.isNullOrBlank() }
}
