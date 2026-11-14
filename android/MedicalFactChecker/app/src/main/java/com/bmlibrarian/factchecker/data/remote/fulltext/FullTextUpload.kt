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

import android.content.Context
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException
import java.io.InputStream
import java.util.Date
import java.util.Locale
import java.util.regex.Matcher
import java.util.regex.Pattern
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Why a file the reader chose could not be used as a paper's full text.
 *
 * @param message What to tell the reader
 */
class FullTextUploadException(message: String) : Exception(message)

/** What a chosen file holds, once read. */
sealed interface FullTextUploadContent {
    /**
     * A PDF, stored on the device, with the text read from it.
     *
     * @property path Where it is stored
     * @property text Its text; null when it has none (a scan)
     */
    data class Pdf(val path: String, val text: String?) : FullTextUploadContent

    /**
     * Text: Markdown, plain text, or HTML reduced to its text.
     *
     * @property text The text
     */
    data class Text(val text: String) : FullTextUploadContent
}

/**
 * A full text the reader supplies by hand, for a paper without text the analysis
 * can read: none found, a scanned PDF, or an abstract-only deposit.
 *
 * An uploaded PDF is kept in its own folder in the app's files
 * ([Constants.UPLOADED_FULLTEXT_DIR]), apart from the PDFs the retrieval chain
 * downloads: not in the cache the system may empty, nor where clearing the PDF
 * cache would delete it. Its text is extracted, so citation extraction reads it
 * rather than the abstract. HTML is kept as its text only, never as markup a
 * viewer would render. Mirrors iOS/macOS's `FullTextUpload`.
 */
@Singleton
class FullTextUpload @Inject constructor(
    @ApplicationContext private val context: Context
) {
    /**
     * Read a chosen file into a full text for a document.
     *
     * @param uri The file the reader chose
     * @param documentId The document, which names a stored PDF
     * @param maxBytes The largest PDF read; a larger one is refused, never cut
     * @param maxHtmlBytes The largest HTML file read; a larger one is refused,
     *   never cut
     * @param maxTextBytes The longest text kept whole on the document's row: a
     *   text file's size, or an HTML page's text once its markup is dropped (a
     *   page saved with its images inline is mostly markup, #763); a longer one
     *   is refused, never cut
     * @return What the file holds
     * @throws FullTextUploadException for a file of a kind not supported, one
     *   too large (or too large for this device's memory), one holding no text or text that is not UTF-8, or one that
     *   could not be read or stored; a PDF uploaded before for the paper is kept
     *   unless the new one is stored whole
     */
    suspend fun read(
        uri: Uri,
        documentId: String,
        maxBytes: Long = Constants.MAX_UPLOAD_BYTES,
        maxHtmlBytes: Long = Constants.MAX_UPLOAD_HTML_BYTES,
        maxTextBytes: Long = Constants.MAX_STORED_TEXT_BYTES
    ): FullTextUploadContent = withContext(Dispatchers.IO) {
        val resolver = context.contentResolver
        val kind = kindOf(resolver.getType(uri), displayName(uri))
            ?: throw FullTextUploadException(UNSUPPORTED_MESSAGE)
        try {
            val stream = resolver.openInputStream(uri) ?: throw IOException("the file could not be opened")
            stream.use { input ->
                when (kind) {
                    Kind.PDF -> store(input, documentId, maxBytes)
                    Kind.HTML -> textContent(heldToRow(htmlToText(readText(input, maxHtmlBytes)), maxTextBytes))
                    Kind.TEXT -> textContent(readText(input, maxTextBytes))
                }
            }
        } catch (e: IOException) {
            Log.e(TAG, "The file chosen for $documentId could not be read or stored", e)
            throw FullTextUploadException("The file could not be read: ${e.message}")
        } catch (e: SecurityException) {
            Log.e(TAG, "The file chosen for $documentId could not be opened", e)
            throw FullTextUploadException("The file could not be opened.")
        } catch (e: OutOfMemoryError) {
            // A small heap, several copies of a page while it is reduced: told, never a crash
            Log.e(TAG, "The file chosen for $documentId is too large to read on this device", e)
            throw FullTextUploadException(TOO_LARGE_FOR_DEVICE_MESSAGE)
        }
    }

    /** An HTML page's text, refused rather than cut when longer than a row can hold. */
    private fun heldToRow(text: String, maxTextBytes: Long): String {
        if (text.toByteArray(Charsets.UTF_8).size > maxTextBytes) {
            throw FullTextUploadException(textTooLongMessage(maxTextBytes))
        }
        return text
    }

    /** A text file's content; one with no text is refused rather than stored as a full text. */
    private fun textContent(text: String): FullTextUploadContent.Text =
        FullTextUploadContent.Text(text.trim().ifEmpty { throw FullTextUploadException(NO_TEXT_MESSAGE) })

    /** The chosen file's name, when the provider gives one. */
    private fun displayName(uri: Uri): String? = try {
        context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (e: SecurityException) {
        null
    }

    /**
     * Copy a chosen PDF to its stored name, with its text, replacing an earlier
     * upload only once the copy is whole and read: a cancel during the copy or
     * the read leaves the earlier PDF beside the text the row holds of it. A
     * cancel after the rename, before the caller writes the row, can still
     * leave the new PDF beside the old text (Deferred: #776).
     */
    private suspend fun store(input: InputStream, documentId: String, maxBytes: Long): FullTextUploadContent.Pdf {
        val folder = File(context.filesDir, Constants.UPLOADED_FULLTEXT_DIR).apply { mkdirs() }
        // An identifier may hold characters a file name cannot
        val name = documentId.map { if (it.isLetterOrDigit()) it else '_' }.joinToString("")
        val destination = File(folder, "uploaded-$name.pdf")
        // A staged copy an upload killed with the app left behind, never cleared by the system
        folder.listFiles { file -> file.name.startsWith("uploaded-$name.") && file.name.endsWith(".part") }
            ?.forEach(File::delete)
        val staged = File.createTempFile("uploaded-$name.", ".part", folder)
        try {
            staged.outputStream().use { output -> copyBounded(input, output, maxBytes) }
            val text = extractedPdfText(staged.path)
            if (!staged.renameTo(destination)) throw IOException("the PDF could not be stored")
            return FullTextUploadContent.Pdf(destination.path, text)
        } finally {
            staged.delete()
        }
    }

    /** Read a text file, refusing one too large to read whole or not UTF-8. */
    private suspend fun readText(input: InputStream, maxBytes: Long): String {
        val bytes = java.io.ByteArrayOutputStream().also { copyBounded(input, it, maxBytes) }.toByteArray()
        return decodedUtf8(bytes)
    }

    /** Copy a stream, refusing past [maxBytes] rather than keeping part of it; a cancel stops it (#764). */
    private suspend fun copyBounded(input: InputStream, output: java.io.OutputStream, maxBytes: Long) {
        val buffer = ByteArray(COPY_BUFFER_BYTES)
        var total = 0L
        while (true) {
            currentCoroutineContext().ensureActive()
            val read = input.read(buffer)
            if (read < 0) return
            total += read
            if (total > maxBytes) throw FullTextUploadException(tooLargeMessage(maxBytes))
            output.write(buffer, 0, read)
        }
    }

    /** The kinds of file an upload reads. */
    internal enum class Kind { PDF, HTML, TEXT }

    companion object {
        private const val TAG = "FullTextUpload"
        private const val COPY_BUFFER_BYTES = 64 * 1024

        /** The file types the picker offers. */
        val PICKER_TYPES = arrayOf("application/pdf", "text/html", "text/markdown", "text/plain", "text/x-markdown")

        /** Told when the chosen file is of a kind not supported. */
        const val UNSUPPORTED_MESSAGE = "Unsupported file format. Please use PDF, HTML, Markdown, or plain text"

        /** Told when a PDF was stored but none of its text could be kept (a scan, a damaged file, a book). */
        const val PDF_WITHOUT_TEXT_MESSAGE = "The PDF was stored, but its text could not be read or is too long " +
            "to keep, so the analysis still reads the paper's abstract."

        /** Told when a file passed its size bound but this device's memory could not hold it while read. */
        const val TOO_LARGE_FOR_DEVICE_MESSAGE = "The file is too large to read on this device, so it was not used."

        /** Told when the chosen text file holds no text. */
        const val NO_TEXT_MESSAGE = "The file holds no text, so it was not used."

        /** Told when the chosen file is not UTF-8 text (UTF-16, a legacy code page). */
        const val NOT_UTF8_MESSAGE = "The file is not UTF-8 text, so it was not used. Save it as UTF-8 and try again."

        /**
         * Told when the chosen file is larger than an upload of its kind may be.
         *
         * @param maxBytes The limit applied
         * @return The sentence
         */
        fun tooLargeMessage(maxBytes: Long): String = "The file is larger than ${shownSize(maxBytes)}, so it was not used."

        /**
         * Told when an HTML page's text is longer than a document's row can hold.
         *
         * @param maxBytes The limit applied
         * @return The sentence
         */
        fun textTooLongMessage(maxBytes: Long): String =
            "The page's text is longer than ${shownSize(maxBytes)}, so it was not used."

        private fun shownSize(maxBytes: Long): String {
            val megabytes = maxBytes.toDouble() / BYTES_PER_MEGABYTE
            return if (megabytes >= 1) "%.0f MB".format(Locale.ROOT, megabytes) else "$maxBytes bytes"
        }

        private const val BYTES_PER_MEGABYTE = 1024 * 1024

        /**
         * A text file's bytes as UTF-8, a byte-order mark dropped; refused when
         * they are not UTF-8, rather than stored with replacement characters.
         *
         * @param bytes The file
         * @return Its text
         * @throws FullTextUploadException when the bytes are not UTF-8
         */
        internal fun decodedUtf8(bytes: ByteArray): String {
            val decoder = Charsets.UTF_8.newDecoder()
                .onMalformedInput(java.nio.charset.CodingErrorAction.REPORT)
                .onUnmappableCharacter(java.nio.charset.CodingErrorAction.REPORT)
            val text = try {
                decoder.decode(java.nio.ByteBuffer.wrap(bytes)).toString()
            } catch (e: java.nio.charset.CharacterCodingException) {
                throw FullTextUploadException(NOT_UTF8_MESSAGE)
            }
            // A NUL is never in prose: UTF-16 that happened to decode as UTF-8
            if ('\u0000' in text) throw FullTextUploadException(NOT_UTF8_MESSAGE)
            return text.removePrefix("\uFEFF")
        }

        /**
         * What kind of file this is. A PDF or HTML type decides it; otherwise the
         * name's extension does, so a `text/plain` file named `.html` is read as
         * HTML; any other `text/` type is read as text.
         *
         * @param mimeType The type the provider gives, if any
         * @param name The file's name, if any
         * @return Its kind, or null for a kind not supported
         */
        internal fun kindOf(mimeType: String?, name: String?): Kind? {
            when (mimeType?.lowercase(Locale.ROOT)) {
                "application/pdf" -> return Kind.PDF
                "text/html", "application/xhtml+xml" -> return Kind.HTML
            }
            when (name?.substringAfterLast('.', "")?.lowercase(Locale.ROOT)) {
                "pdf" -> return Kind.PDF
                "html", "htm" -> return Kind.HTML
                "md", "markdown", "txt" -> return Kind.TEXT
            }
            return if (mimeType?.startsWith("text/") == true) Kind.TEXT else null
        }

        /**
         * The text of an HTML page: scripts and styles dropped, block ends kept as
         * line breaks, tags removed, the common entities decoded.
         *
         * shortcut: a regex reading of HTML, enough for the prose citation
         * extraction needs; use a real parser if uploaded pages lose their text.
         *
         * Linear in the page (#763): a lazy regex from each unclosed opener
         * scanned to the page's end, 400 KB of `<script ` taking 35 s.
         *
         * @param html The page
         * @return Its text
         */
        internal fun htmlToText(html: String): String = withoutTags(
            withoutSkipped(html)
                .replace(Regex("(?i)<br\\s*/?>|</(p|div|h[1-6]|li|tr|section|article|blockquote)\\s*>"), "\n")
        )
            .replace(Regex("&#(\\d+);")) { match ->
                match.groupValues[1].toIntOrNull()?.takeIf(Character::isValidCodePoint)
                    ?.let { String(Character.toChars(it)) } ?: match.value
            }
            .replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">")
            .replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")
            .lines().joinToString("\n") { it.replace(Regex("[ \\t]+"), " ").trim() }
            .replace(Regex("\n{3,}"), "\n\n")
            .trim()

        // One group per name: Android's case-insensitive matching is Unicode-aware,
        // so the opener's text (`<ſcript`) need not lowercase to a name
        private val SKIPPED_OPENER = Pattern.compile("(?i)<(?:(script)|(style)|(head))\\b")
        private val SKIPPED_CLOSERS = listOf("script", "style", "head").map { Pattern.compile("(?i)</$it\\s*>") }

        /**
         * The page with each script, style and head dropped, its tags with it.
         * An opener never closed is left for [withoutTags]. Each pattern keeps
         * one matcher that only moves forward, so no stretch of the page is
         * scanned twice: a match of either kind holds a single `<`, its first
         * character, so matches never overlap and a matcher passes none. Never
         * `find(start)`, which resets the matcher and on Android hands native
         * code the whole page again.
         */
        private fun withoutSkipped(html: String): String {
            val kept = StringBuilder(html.length)
            val opener = SKIPPED_OPENER.matcher(html)
            val closers = SKIPPED_CLOSERS.map { it.matcher(html) }
            // Per name: its matcher holds a match; it has none left
            val matched = BooleanArray(closers.size)
            val exhausted = BooleanArray(closers.size)
            var at = 0
            while (opener.find()) {
                if (opener.start() < at) continue
                val named = (1..closers.size).first { opener.group(it) != null } - 1
                val closer = closers[named]
                if (!exhausted[named] && !(matched[named] && closer.start() >= opener.end())) {
                    matched[named] = advancePast(closer, opener.end())
                    exhausted[named] = !matched[named]
                }
                if (exhausted[named]) {
                    kept.append(html, at, opener.end())
                    at = opener.end()
                } else {
                    kept.append(html, at, opener.start()).append(' ')
                    at = closer.end()
                }
            }
            return kept.append(html, at, html.length).toString()
        }

        /** Move [matcher] to its first match starting at or past [from]; false when none is left. */
        private fun advancePast(matcher: Matcher, from: Int): Boolean {
            while (matcher.find()) {
                if (matcher.start() >= from) return true
            }
            return false
        }

        /**
         * Every tag replaced by a space. Past the page's last `>` nothing can
         * be a tag, and a `<` there would scan to the end for one: only the
         * part before it is searched.
         */
        private fun withoutTags(html: String): String {
            val end = html.lastIndexOf('>') + 1
            return html.substring(0, end).replace(Regex("<[^>]*>"), " ") + html.substring(end)
        }
    }
}

/**
 * The document as an upload leaves it: the reader's text, recorded as uploaded.
 *
 * Replaces whatever full text the document held; a PDF's text is stored beside
 * it for the analysis. Clears what earlier fetches recorded about sources: an
 * upload settles the paper's full text.
 *
 * @param content What the chosen file holds
 * @return The document to store
 */
fun DocumentEntity.recordingUpload(content: FullTextUploadContent): DocumentEntity {
    val uploaded = copy(
        fullTextSource = Constants.FULLTEXT_SOURCE_UPLOADED,
        fullTextFetchedAt = Date(),
        fullTextUnavailable = false,
        fullTextAbstractOnly = false,
        fullTextHTML = null,
        fullTextOpenAccessShortfallJson = null,
        fullTextPdfNotSavedFrom = null
    )
    return when (content) {
        is FullTextUploadContent.Pdf -> uploaded.copy(pdfPath = content.path, pdfExtractedText = content.text, fullTextMarkdown = null)
        is FullTextUploadContent.Text -> uploaded.copy(fullTextMarkdown = content.text, pdfPath = null, pdfExtractedText = null)
    }
}
