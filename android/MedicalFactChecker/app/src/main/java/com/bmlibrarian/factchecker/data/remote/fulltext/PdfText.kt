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
import com.bmlibrarian.factchecker.util.Constants
import com.itextpdf.commons.exceptions.ITextException
import com.itextpdf.kernel.pdf.PdfDocument
import com.itextpdf.kernel.pdf.PdfPage
import com.itextpdf.kernel.pdf.PdfReader
import com.itextpdf.kernel.pdf.canvas.parser.PdfTextExtractor
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

private const val TAG = "PdfText"

/**
 * The text of a PDF on disk, every page in order, for the analysis to read.
 *
 * What citation extraction reads of a PDF full text, downloaded or uploaded: a
 * PDF is shown as itself, so its text is stored beside it
 * ([com.bmlibrarian.factchecker.data.local.entity.DocumentEntity.pdfExtractedText]).
 * Read off the main thread: iText parses every page.
 *
 * shortcut: a text longer than [Constants.MAX_STORED_TEXT_BYTES] is not kept,
 * since the row holding it could not be read back, and never cut; keep long
 * texts in a file beside the PDF if long PDFs (books, theses) turn up.
 *
 * A cancel is checked before each page (#764) and thrown, never answered with
 * the pages read so far.
 *
 * @param path The PDF on disk
 * @param maxBytes The longest text kept, in UTF-8 bytes
 * @param readPage Reads one page's text (a test's seam)
 * @return Its text, trimmed; null when it has none (a scan), cannot be read as
 *   a PDF (damaged, a password, no pages, gone), or is too long to keep, each
 *   logged
 * @throws CancellationException when the read is cancelled
 */
suspend fun extractedPdfText(
    path: String,
    maxBytes: Long = Constants.MAX_STORED_TEXT_BYTES,
    readPage: (PdfPage) -> String = { PdfTextExtractor.getTextFromPage(it) }
): String? = withContext(Dispatchers.IO) {
    val file = File(path)
    val text = try {
        // The reader closed too when the document cannot be built from it
        PdfReader(file).use { reader ->
            PdfDocument(reader).use { document ->
                (1..document.numberOfPages).joinToString("\n\n") { number ->
                    ensureActive()
                    readPage(document.getPage(number))
                }
            }
        }
    } catch (e: IOException) {
        Log.w(TAG, "${file.name} could not be read for its text", e)
        return@withContext null
    } catch (e: ITextException) {
        // iText's own: a damaged file, a password (BadPasswordException)
        Log.w(TAG, "${file.name} could not be read for its text", e)
        return@withContext null
    } catch (e: StackOverflowError) {
        // A page tree nested past the stack (a damaged or hostile file): the file's,
        // and the app must not die of it
        Log.w(TAG, "${file.name} is nested too deeply to read for its text", e)
        return@withContext null
    } catch (e: CancellationException) {
        // A RuntimeException too: the caller's, never the file's
        throw e
    } catch (e: RuntimeException) {
        // iText documents no closed set of errors: one that is not iText's is a
        // fault of the code or the install, and the file is still only unread
        Log.e(TAG, "Reading ${file.name} for its text failed in the code, not the file", e)
        return@withContext null
    }
    val trimmed = text.trim().ifEmpty {
        Log.w(TAG, "${file.name} has no text on its pages")
        return@withContext null
    }
    if (trimmed.toByteArray(Charsets.UTF_8).size > maxBytes) {
        Log.w(TAG, "${file.name}'s text is longer than $maxBytes bytes, so it is not kept for the analysis")
        return@withContext null
    }
    trimmed
}
