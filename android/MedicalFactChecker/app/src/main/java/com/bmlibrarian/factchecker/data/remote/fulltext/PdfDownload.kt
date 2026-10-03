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

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.util.Constants
import java.io.File

/**
 * What downloading a PDF came to.
 *
 * Typed rather than a nullable path, because a PDF Unpaywall named that could
 * not be obtained is refused with its cause (#478): a null said only that
 * something went wrong, and the copy was recorded as found.
 */
sealed class PdfDownload {
    /**
     * The PDF is in the cache.
     *
     * @property path Where it was saved.
     */
    data class Saved(val path: String) : PdfDownload()

    /**
     * No PDF was obtained.
     *
     * @property failure Why: the status, the transport failure,
     *   `MALFORMED_RESPONSE` for a body that is not a PDF, or `REQUEST_FAILED`
     *   for an address that cannot be requested or a file that could not be
     *   written.
     */
    data class Failed(val failure: RequestFailure) : PdfDownload()

    /** The saved file's path, or null when nothing was saved. */
    val savedPath: String?
        get() = (this as? Saved)?.path
}

/**
 * Whether bytes begin as a PDF file does.
 *
 * @param prefix The first bytes of a body or file
 * @return true when they begin with [Constants.PDF_MAGIC_BYTES]
 */
fun looksLikePdf(prefix: ByteArray): Boolean =
    prefix.size >= Constants.PDF_MAGIC_BYTES.size &&
        prefix.copyOfRange(0, Constants.PDF_MAGIC_BYTES.size).contentEquals(Constants.PDF_MAGIC_BYTES)

/**
 * Whether a cached file is a PDF: present, and beginning with `%PDF`.
 *
 * @param file The file to check
 * @return true when it can be shown as the PDF
 */
internal fun isCachedPdf(file: File): Boolean {
    if (!file.isFile || file.length() == 0L) return false
    val prefix = ByteArray(Constants.PDF_MAGIC_BYTES.size)
    val read = file.inputStream().use { it.read(prefix) }
    return read == prefix.size && looksLikePdf(prefix)
}

/**
 * The DOI link the full-text chain falls back to.
 *
 * @param doi The article's DOI
 * @return Its doi.org URL
 */
fun doiLink(doi: String): String = "${Constants.DOI_URL_PREFIX}$doi"
