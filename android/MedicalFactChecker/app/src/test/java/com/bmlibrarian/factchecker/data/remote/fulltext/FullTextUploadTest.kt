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

import android.content.ContentResolver
import android.content.Context
import android.net.Uri
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUpload.Kind
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import com.itextpdf.kernel.pdf.canvas.parser.PdfTextExtractor
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Deferred
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.ByteArrayInputStream
import java.io.File
import java.io.InputStream

/** A full text the reader supplies by hand (iOS's `FullTextUploadTests`). */
class FullTextUploadTest {

    @get:Rule
    val folder = TemporaryFolder()

    // ==================== What a file is ====================

    @Test
    fun `a file is read by its type, else by its name`() {
        assertEquals(Kind.PDF, FullTextUpload.kindOf("application/pdf", null))
        assertEquals(Kind.HTML, FullTextUpload.kindOf("text/html", "page.txt"))
        assertEquals(Kind.TEXT, FullTextUpload.kindOf("application/octet-stream", "notes.md"))
        assertEquals(Kind.PDF, FullTextUpload.kindOf(null, "Paper.PDF"))
        assertEquals(Kind.TEXT, FullTextUpload.kindOf("text/csv", null))
        assertNull(FullTextUpload.kindOf("application/msword", "paper.docx"))
    }

    @Test
    fun `an HTML page is kept as its text, never its markup`() {
        val text = FullTextUpload.htmlToText(
            "<html><head><title>T</title><script>alert(1)</script></head><body>" +
                "<h1>Methods</h1><p>We randomised 40&nbsp;patients &amp; 2 sites.</p><p>Caf&#233;</p></body></html>"
        )

        assertEquals("Methods\nWe randomised 40 patients & 2 sites.\nCafé", text)
    }

    @Test
    fun `an unclosed script is kept as text, and the elements after it are still dropped`() {
        assertEquals(
            "B C E",
            FullTextUpload.htmlToText("<script>a</script>B<script>C<STYLE>d</style >E<head>")
        )
    }

    // Each was quadratic as a regex: 400 KB of `<script ` took 35 s (#763)
    @Test(timeout = 10_000)
    fun `unclosed openers and tags are read in linear time`() {
        for (name in listOf("script", "style", "head")) {
            val unclosed = "<$name ".repeat(100_000)
            assertEquals(unclosed.trim(), FullTextUpload.htmlToText(unclosed))
        }
        assertEquals("<".repeat(1_000_000), FullTextUpload.htmlToText("<".repeat(1_000_000)))
        val closed = "<script>a</script>b".repeat(100_000)
        assertEquals("b".repeat(100_000).toList().joinToString(" "), FullTextUpload.htmlToText(closed))
    }

    @Test
    fun `scripts, styles and the head are dropped across lines and cases, and lookalike names are kept`() {
        assertEquals(
            "Title kept\nlast",
            FullTextUpload.htmlToText(
                "<HEAD><style>p {\n}</style><script>x\ny</script></head ><header>Title</header>" +
                    "<p>kept</p><scripts>last</scripts><SCRIPT type=x>z</Script\n>"
            )
        )
    }

    @Test
    fun `the linear reading drops what the regex reading dropped`() {
        val atoms = listOf(
            "<script>", "<SCRIPT ", "</script>", "</Script >", "<style>", "</style\n>", "<head>", "<header>",
            "</head>", "<head", "</head", "<", ">", "a", " ", "\n", "</", "<scriptx>", "<p>", "</p>", "<br/>", "&lt;"
        )
        val random = java.util.Random(763)
        repeat(20_000) {
            val page = buildString { repeat(random.nextInt(14)) { append(atoms[random.nextInt(atoms.size)]) } }
            assertEquals(page, regexHtmlToText(page), FullTextUpload.htmlToText(page))
        }
    }

    /** `htmlToText` before #763: quadratic on an unclosed opener, the reference for what is dropped. */
    private fun regexHtmlToText(html: String): String = html
        .replace(Regex("(?is)<(script|style|head)\\b.*?</\\1\\s*>"), " ")
        .replace(Regex("(?i)<br\\s*/?>|</(p|div|h[1-6]|li|tr|section|article|blockquote)\\s*>"), "\n")
        .replace(Regex("(?s)<[^>]*>"), " ")
        .replace(Regex("&#(\\d+);")) { match ->
            match.groupValues[1].toIntOrNull()?.takeIf(Character::isValidCodePoint)
                ?.let { String(Character.toChars(it)) } ?: match.value
        }
        .replace("&nbsp;", " ").replace("&lt;", "<").replace("&gt;", ">")
        .replace("&quot;", "\"").replace("&#39;", "'").replace("&amp;", "&")
        .lines().joinToString("\n") { it.replace(Regex("[ \\t]+"), " ").trim() }
        .replace(Regex("\n{3,}"), "\n\n")
        .trim()

    // ==================== What the document records ====================

    private val fetched = DocumentEntity(
        id = "d", sessionId = "s", title = "A trial",
        fullTextMarkdown = "Abstract only", fullTextAbstractOnly = true, fullTextUnavailable = true,
        fullTextOpenAccessShortfallJson =
            OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.TIMEOUT)).toJson()
    )

    @Test
    fun `an uploaded PDF is recorded with its text, as uploaded, and settles the paper`() {
        val recorded = fetched.recordingUpload(FullTextUploadContent.Pdf("/files/uploaded-d.pdf", "PDF prose"))

        assertEquals(Constants.FULLTEXT_SOURCE_UPLOADED, recorded.fullTextSource)
        assertTrue(recorded.holdsUploadedFullText)
        assertEquals("/files/uploaded-d.pdf", recorded.pdfPath)
        assertEquals("PDF prose", recorded.analysisFullText)
        assertFalse(recorded.fullTextUnavailable)
        assertFalse(recorded.fullTextAbstractOnly)
        assertNull(recorded.fullTextOpenAccessShortfallJson)
        assertNull(recorded.fullTextMarkdown)
    }

    @Test
    fun `an uploaded text replaces a held abstract`() {
        val recorded = fetched.recordingUpload(FullTextUploadContent.Text("The body."))

        assertEquals("The body.", recorded.analysisFullText)
        assertNull(recorded.pdfPath)
    }

    // ==================== Reading the file ====================

    private fun upload(type: String?, bytes: ByteArray): Pair<FullTextUpload, Uri> =
        upload(type) { ByteArrayInputStream(bytes) }

    private fun upload(type: String?, open: () -> InputStream): Pair<FullTextUpload, Uri> {
        val uri = mockk<Uri>()
        val resolver = mockk<ContentResolver> {
            every { getType(uri) } returns type
            every { query(uri, any(), any(), any(), any()) } returns null
            every { openInputStream(uri) } answers { open() }
        }
        val context = mockk<Context> {
            every { contentResolver } returns resolver
            every { filesDir } returns folder.root
        }
        return FullTextUpload(context) to uri
    }

    @Test
    fun `an uploaded PDF is kept in its own folder in the app's files`() = runTest {
        val (upload, uri) = upload("application/pdf", "%PDF-1.4 not really".toByteArray())

        val content = upload.read(uri, "doc/1") as FullTextUploadContent.Pdf

        assertEquals(File(File(folder.root, Constants.UPLOADED_FULLTEXT_DIR), "uploaded-doc_1.pdf").path, content.path)
        assertEquals("%PDF-1.4 not really", File(content.path).readText())
        assertNull("no text iText can read", content.text)
    }

    @Test
    fun `a file larger than an upload may be is refused, and an earlier upload is kept`() = runTest {
        val (first, uri) = upload("application/pdf", "%PDF earlier".toByteArray())
        val stored = (first.read(uri, "d") as FullTextUploadContent.Pdf).path
        val (second, uri2) = upload("application/pdf", ByteArray(2_048))

        val refused = runCatching { second.read(uri2, "d", maxBytes = 1_024) }.exceptionOrNull()

        assertEquals(FullTextUpload.tooLargeMessage(1_024), (refused as FullTextUploadException).message)
        assertEquals("%PDF earlier", File(stored).readText())
        assertEquals("no part file is left", listOf("uploaded-d.pdf"), File(folder.root, Constants.UPLOADED_FULLTEXT_DIR).list()?.toList())
    }

    @Test
    fun `a text file is read, and one with no text or of a kind not supported is refused`() = runTest {
        val (text, uri) = upload("text/markdown", "# Methods\n\nWe randomised.".toByteArray())
        assertEquals(FullTextUploadContent.Text("# Methods\n\nWe randomised."), text.read(uri, "d"))

        val (blank, blankUri) = upload("text/plain", "  \n ".toByteArray())
        assertEquals(FullTextUpload.NO_TEXT_MESSAGE, runCatching { blank.read(blankUri, "d") }.exceptionOrNull()?.message)

        val (image, imageUri) = upload("image/png", ByteArray(4))
        assertEquals(FullTextUpload.UNSUPPORTED_MESSAGE, runCatching { image.read(imageUri, "d") }.exceptionOrNull()?.message)
        assertThrows(FullTextUploadException::class.java) { kotlinx.coroutines.runBlocking { image.read(imageUri, "d") } }
    }

    @Test
    fun `a text file longer than a row can hold is refused, never cut`() = runTest {
        val (text, uri) = upload("text/plain", "a".repeat(2_048).toByteArray())

        val refused = runCatching { text.read(uri, "d", maxTextBytes = 1_024) }.exceptionOrNull()

        assertEquals(FullTextUpload.tooLargeMessage(1_024), refused?.message)
        assertEquals("The file is larger than 100 MB, so it was not used.", FullTextUpload.tooLargeMessage(Constants.MAX_UPLOAD_BYTES))
    }

    @Test
    fun `an HTML page is held to the row's limit by its text, not its markup`() = runTest {
        val image = "<img src=\"data:image/png;base64,${"A".repeat(4_096)}\">"
        val (page, uri) = upload("text/html", "<p>We randomised.</p>$image".toByteArray())
        assertEquals(FullTextUploadContent.Text("We randomised."), page.read(uri, "d", maxTextBytes = 1_024))

        val (long, longUri) = upload("text/html", "<p>${"a".repeat(2_048)}</p>".toByteArray())
        val refused = runCatching { long.read(longUri, "d", maxTextBytes = 1_024) }.exceptionOrNull()
        assertEquals(FullTextUpload.textTooLongMessage(1_024), refused?.message)

        val (large, largeUri) = upload("text/html", image.toByteArray())
        val tooLarge = runCatching { large.read(largeUri, "d", maxHtmlBytes = 1_024) }.exceptionOrNull()
        assertEquals(FullTextUpload.tooLargeMessage(1_024), tooLarge?.message)
        assertEquals("The page's text is longer than 1 MB, so it was not used.", FullTextUpload.textTooLongMessage(Constants.MAX_STORED_TEXT_BYTES))
    }

    @Test
    fun `an HTML page's text is held to the row's limit in UTF-8 bytes, not characters`() = runTest {
        val (page, uri) = upload("text/html", "<p>${"\u00e9".repeat(600)}</p>".toByteArray())

        val refused = runCatching { page.read(uri, "d", maxTextBytes = 1_024) }.exceptionOrNull()

        assertEquals(FullTextUpload.textTooLongMessage(1_024), refused?.message)
    }

    @Test
    fun `a file too large for this device's memory is refused, not a crash`() = runTest {
        val (page, uri) = upload("text/html") { object : InputStream() { override fun read(): Int = throw OutOfMemoryError() } }

        val refused = runCatching { page.read(uri, "d") }.exceptionOrNull()

        assertEquals(FullTextUpload.TOO_LARGE_FOR_DEVICE_MESSAGE, (refused as FullTextUploadException).message)
    }

    @Test
    fun `an uploaded PDF's text is read from it, and a second upload replaces the first`() = runTest {
        val (first, uri) = upload("application/pdf", writeTitledPdf(folder.newFile("a.pdf"), "Methods first").readBytes())
        val (second, uri2) = upload("application/pdf", writeTitledPdf(folder.newFile("b.pdf"), "Results second").readBytes())

        assertEquals("Methods first", (first.read(uri, "d") as FullTextUploadContent.Pdf).text)
        val replaced = second.read(uri2, "d") as FullTextUploadContent.Pdf

        assertEquals("Results second", replaced.text)
        assertEquals("Results second", extractedPdfText(replaced.path))
        assertEquals(listOf("uploaded-d.pdf"), File(folder.root, Constants.UPLOADED_FULLTEXT_DIR).list()?.toList())
    }

    @Test
    fun `a cancel once the copy is whole, before its text is read, keeps the earlier PDF`() = runTest {
        val (first, uri) = upload("application/pdf", "%PDF earlier".toByteArray())
        val stored = (first.read(uri, "d") as FullTextUploadContent.Pdf).path
        val bytes = writeTitledPdf(folder.newFile("new.pdf"), "New").readBytes()
        lateinit var job: Deferred<FullTextUploadContent>
        val (second, uri2) = upload("application/pdf") { cancellingAtEnd(ByteArrayInputStream(bytes)) { job.cancel() } }

        job = async { second.read(uri2, "d") }

        assertTrue(runCatching { job.await() }.exceptionOrNull() is CancellationException)
        assertEquals("%PDF earlier", File(stored).readText())
        assertEquals("no part file is left", listOf("uploaded-d.pdf"), File(folder.root, Constants.UPLOADED_FULLTEXT_DIR).list()?.toList())
    }

    @Test
    fun `a cancel stops the copy of a chosen file`() = runTest {
        var reads = 0
        lateinit var job: Deferred<FullTextUploadContent>
        val (upload, uri) = upload("application/pdf") {
            object : InputStream() {
                override fun read(): Int = 0
                override fun read(b: ByteArray, off: Int, len: Int): Int {
                    if (++reads == 1) job.cancel()
                    return len
                }
            }
        }

        job = async { upload.read(uri, "d") }

        assertTrue(runCatching { job.await() }.exceptionOrNull() is CancellationException)
        assertTrue("read $reads buffers", reads < 10)
    }

    @Test
    fun `a part file a killed upload left is deleted by the next one`() = runTest {
        val uploads = File(folder.root, Constants.UPLOADED_FULLTEXT_DIR).apply { mkdirs() }
        File(uploads, "uploaded-d.123.part").writeText("left")
        File(uploads, "uploaded-d2.123.part").writeText("another paper's")
        val (upload, uri) = upload("application/pdf", "%PDF-1.4 not really".toByteArray())

        upload.read(uri, "d")

        assertEquals(listOf("uploaded-d.pdf", "uploaded-d2.123.part"), uploads.list()?.sorted())
    }

    @Test
    fun `a text file that is not UTF-8 is refused, and a byte-order mark is dropped`() = runTest {
        val (utf16, uri) = upload("text/plain", "We randomised.".toByteArray(Charsets.UTF_16LE))
        assertEquals(FullTextUpload.NOT_UTF8_MESSAGE, runCatching { utf16.read(uri, "d") }.exceptionOrNull()?.message)

        val (latin1, latinUri) = upload("text/plain", "Caf\u00e9".toByteArray(Charsets.ISO_8859_1))
        assertEquals(FullTextUpload.NOT_UTF8_MESSAGE, runCatching { latin1.read(latinUri, "d") }.exceptionOrNull()?.message)

        val (marked, markedUri) = upload("text/plain", "\uFEFFCaf\u00e9".toByteArray(Charsets.UTF_8))
        assertEquals(FullTextUploadContent.Text("Caf\u00e9"), marked.read(markedUri, "d"))
    }

    // ==================== A PDF's text ====================

    @Test
    fun `a PDF's text is read page by page, in order`() = runTest {
        val pdf = writeTitledPdf(folder.newFile("two.pdf"), "Methods first", "Results second")

        assertEquals("Methods first\n\nResults second", extractedPdfText(pdf.path)?.replace(Regex("[ \t]+\n"), "\n"))
    }

    @Test
    fun `a PDF with blank pages, or text longer than a row can hold, gives no text`() = runTest {
        assertNull(extractedPdfText(writeTitledPdf(folder.newFile("scan.pdf"), "", "").path))

        val long = writeTitledPdf(folder.newFile("long.pdf"), "Methods first")
        assertNull(extractedPdfText(long.path, maxBytes = 4))
        assertEquals("Methods first", extractedPdfText(long.path, maxBytes = 1_024))
    }

    @Test
    fun `a cancelled read stops before the next page`() = runTest {
        val pdf = writeTitledPdf(folder.newFile("three.pdf"), "One", "Two", "Three")
        var pagesRead = 0
        lateinit var reading: Deferred<String?>
        reading = async {
            extractedPdfText(pdf.path, readPage = { page ->
                pagesRead++
                reading.cancel()
                PdfTextExtractor.getTextFromPage(page)
            })
        }

        assertTrue(runCatching { reading.await() }.exceptionOrNull() is CancellationException)
        assertEquals(1, pagesRead)
    }

    @Test
    fun `a cancellation iText throws while nothing was cancelled is an unread file, not a stop`() = runTest {
        val pdf = writeTitledPdf(folder.newFile("one.pdf"), "One")

        assertNull(extractedPdfText(pdf.path, readPage = { throw CancellationException("not the caller's") }))
    }

    /** A stream that calls [onEnd] when it reaches its end, as a cancel landing once the copy is whole. */
    private fun cancellingAtEnd(input: InputStream, onEnd: () -> Unit) = object : InputStream() {
        override fun read(): Int = input.read().also { if (it < 0) onEnd() }
        override fun read(b: ByteArray, off: Int, len: Int): Int = input.read(b, off, len).also { if (it < 0) onEnd() }
    }
}
