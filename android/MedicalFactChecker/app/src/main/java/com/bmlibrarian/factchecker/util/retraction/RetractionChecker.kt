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

import org.bmlib.ffi.RetractionIndex
import org.bmlib.ffi.crossrefRetractionRequests
import org.bmlib.ffi.retractionStatus

/**
 * The workflow's injection point: a check of each paper, every paper
 * included. Throws only to say the check failed (or was cancelled).
 */
typealias RetractionCheck = suspend (List<RetractionPaper>) -> Map<RetractionPaper, PaperRetractionCheck>

/**
 * Checks papers against the Retraction Watch index, Crossref and their own
 * PubMed label; bmlib's rule decides (Swift's `RetractionChecker`).
 *
 * @param index The current index, or null when there is none (the export is
 *   then not consulted and nothing reads as clear)
 * @param crossref Crossref's answers by normalised DOI ([RetractionCrossrefLookup.results])
 */
class RetractionChecker(
    private val index: RetractionIndex?,
    private val crossref: suspend (List<String>) -> Map<String, CrossrefAnswer>
) {
    /**
     * Check [papers], asking Crossref once per normalised DOI.
     *
     * @param papers The papers; equal papers share one check
     * @param nowMs Stored as each check's time
     * @return A check per paper, every paper included
     */
    suspend fun check(papers: List<RetractionPaper>, nowMs: Long): Map<RetractionPaper, PaperRetractionCheck> {
        val keys = papers.distinct().associateWith { paper -> paper.doi?.let(::doiKey) }
        val answers = crossref(keys.values.filterNotNull().distinct())
        return keys.mapValues { (paper, doi) ->
            val export = index?.lookup(doi, paper.canonicalPmid)
            val answer = doi?.let { answers[it] }
            PaperRetractionCheck.fromVerdict(
                retractionStatus(doi, export, answer?.result, paper.publicationTypes),
                checkedAtMs = nowMs,
                exportDataAsOf = if (export == null) null else index?.dataAsOf(),
                crossrefFailure = answer?.failure?.describe()
            )
        }
    }

    companion object {
        /**
         * The key bmlib files [doi]'s Crossref answer under (the desktop's
         * `crossref_key`), from bmlib's own request builder.
         */
        fun doiKey(doi: String): String? {
            val requests = crossrefRetractionRequests(listOf(doi), null)
            return requests.batches.firstOrNull()?.dois?.firstOrNull() ?: requests.unsendable.firstOrNull()
        }
    }
}
