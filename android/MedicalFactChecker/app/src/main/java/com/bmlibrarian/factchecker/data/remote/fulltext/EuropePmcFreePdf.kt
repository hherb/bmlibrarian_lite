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

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextUrlEntry
import com.bmlibrarian.factchecker.util.Constants

/**
 * Which of Europe PMC's `fullTextUrl` entries is the free PDF (bmlib#79).
 *
 * `availability == "Free"` alone accepted about 4% of the free PDFs: the rest are
 * labelled "Open access" (`OA`), the same `?pdf=render` URL on the same host. The rule
 * is the shared contract `fulltext_parity/europepmc_free_pdf.json`, which Python and
 * Swift read too.
 */
internal object EuropePmcFreePdf {
    private const val TAG = "EuropePmcFreePdf"

    /**
     * Whether an entry is one the app may download.
     *
     * A code in [Constants.EUROPE_PMC_FREE_PDF_CODES] admits it. An entry with no code,
     * or an empty one, is judged by its label being in
     * [Constants.EUROPE_PMC_FREE_PDF_LABELS]. A code that is present but unrecognised is
     * refused WITHOUT reading the label: a future code this build has never evaluated
     * must not be admitted because its display string happens to read "Free".
     *
     * @param entry One `fullTextUrl` entry
     * @return Whether it is a free download
     */
    fun isFreeToDownload(entry: FullTextUrlEntry): Boolean {
        val code = entry.availabilityCode
        if (!code.isNullOrEmpty()) return code in Constants.EUROPE_PMC_FREE_PDF_CODES
        return entry.availability in Constants.EUROPE_PMC_FREE_PDF_LABELS
    }

    /**
     * The first free PDF URL among an article's entries.
     *
     * Only `documentStyle == "pdf"` entries count; an entry without a URL is skipped. A
     * PDF entry seen and not taken is logged, so it is visible in a trace.
     *
     * @param entries The article's `fullTextUrl` entries, or null if it has none
     * @return The first downloadable PDF URL, or null if there is none
     */
    fun extractUrl(entries: List<FullTextUrlEntry>?): String? {
        for (entry in entries.orEmpty()) {
            if (entry.documentStyle != Constants.EUROPE_PMC_PDF_DOCUMENT_STYLE) continue
            if (!isFreeToDownload(entry)) {
                reportRejected(entry)
                continue
            }
            entry.url?.let { return it }
        }
        return null
    }

    /**
     * Log a PDF entry that was seen and not taken: a known paywall code at debug, a code
     * in neither set (a value Europe PMC started publishing, refused fail-closed) at
     * warning, naming the code and its label.
     */
    private fun reportRejected(entry: FullTextUrlEntry) {
        val code = entry.availabilityCode
        val label = entry.availability
        if (!code.isNullOrEmpty() && code !in Constants.EUROPE_PMC_UNAVAILABLE_PDF_CODES) {
            Log.w(
                TAG,
                "Unrecognised Europe PMC availabilityCode '$code' (availability='$label'); the PDF " +
                    "was rejected fail-closed. If this is a free tier, add it to " +
                    "Constants.EUROPE_PMC_FREE_PDF_CODES."
            )
            return
        }
        Log.d(TAG, "Skipping Europe PMC PDF entry: availability=$label code=$code")
    }
}
