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
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.every
import io.mockk.mockk
import java.io.File
import java.util.concurrent.TimeUnit
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import kotlinx.coroutines.test.runTest
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/**
 * Downloading a PDF says why it got none (#478), and keeps only a PDF: a page
 * served in its place was saved as the PDF and returned as cached ever after.
 */
class FullTextServicePdfDownloadTest {

    @get:Rule
    val cache = TemporaryFolder()

    private lateinit var server: MockWebServer
    private lateinit var service: FullTextService

    private val pdfBytes = "%PDF-1.7\n%âãÏÓ\n1 0 obj\n".toByteArray(Charsets.ISO_8859_1)

    @Before
    fun setUp() {
        server = MockWebServer()
        server.start()
        val context = mockk<Context> { every { cacheDir } returns cache.root }
        service = FullTextService(
            context = context,
            europePmcService = mockk<EuropePMCService>(relaxed = true),
            unpaywallApi = mockk(relaxed = true),
            httpClient = OkHttpClient(),
            pmcOpenData = absentBucket(),
            openAlex = absentOpenAlex(),
            core = absentCore(),
            elsevier = absentElsevier()
        )
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    /** Download `/a.pdf` for document `d`, checked against [title] when one is given. */
    private suspend fun download(title: String? = null): PdfDownload =
        service.downloadPdf(server.url("/a.pdf").toString(), "d", title)

    private fun cachedFiles(): List<String> =
        cache.root.walkTopDown().filter { it.isFile }.map { it.name }.toList()

    @Test
    fun `a PDF is saved and its path answered`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "application/pdf").setBody(Buffer().write(pdfBytes)))

        val saved = download() as PdfDownload.Saved

        assertArrayEquals(pdfBytes, File(saved.path).readBytes())
        assertEquals(listOf("d.pdf"), cachedFiles())
    }

    /** A login page served with 200 is not the PDF, and nothing is cached (#478). */
    @Test
    fun `a page served in place of the PDF is not saved`() = runTest {
        server.enqueue(MockResponse().setHeader("Content-Type", "text/html").setBody("<html>Sign in to read</html>"))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)), download())
        assertEquals(emptyList<String>(), cachedFiles())
        assertNull(service.getCachedPdfPath("d"))
    }

    @Test
    fun `a challenge served as a PDF is challenged and not saved`() = runTest {
        server.enqueue(
            MockResponse().setHeader("Content-Type", "application/pdf").setBody("<title>Preparing to download")
        )

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 200)), download())
        assertEquals(emptyList<String>(), cachedFiles())
        assertNull(service.getCachedPdfPath("d"))
    }

    @Test
    fun `a cloudflare 403 is challenged`() = runTest {
        server.enqueue(MockResponse().setResponseCode(403).setHeader("Server", "cloudflare").setBody("<html>"))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 403)), download())
    }

    /** The page's markers, not the Server header, are what name the wall here (#480). */
    @Test
    fun `a 403 whose page names the wall is challenged`() = runTest {
        server.enqueue(
            MockResponse().setResponseCode(403).setHeader("Server", "nginx").setBody("<html><title>Just a moment...")
        )

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 403)), download())
    }

    /**
     * A refusal whose page cannot be read keeps its answer: the unread page is
     * no reason to call a 403 a connection failure. The enqueued response
     * promises more body than it sends, then drops the connection, which fails
     * the read of the page.
     */
    @Test
    fun `a cloudflare 403 whose page breaks off is still challenged`() = runTest {
        server.enqueue(brokenBody(403).setHeader("Server", "cloudflare"))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 403)), download())
    }

    /**
     * What arrived of a page that breaks off is still read: a marker in its
     * first half names the wall, as Python's `read_more_of_prefix` keeps it.
     */
    @Test
    fun `a refusal whose page names the wall and then breaks off is challenged`() = runTest {
        server.enqueue(brokenBody(403, "<div id=\"px-captcha\"></div>").setHeader("Server", "nginx"))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 403)), download())
    }

    @Test
    fun `a challenge served as a 200 that breaks off is challenged`() = runTest {
        server.enqueue(brokenBody(200, "<title>Preparing to download"))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 200)), download())
        assertEquals(emptyList<String>(), cachedFiles())
    }

    /** A 404's page is never read, so its markup cannot make it a challenge. */
    @Test
    fun `a 404 with challenge markup is gone`() = runTest {
        server.enqueue(
            MockResponse().setResponseCode(404).setHeader("Server", "cloudflare").setBody("<title>Just a moment...")
        )

        assertEquals(PdfDownload.Failed(RequestFailure.forHttpStatus(404)), download())
    }

    /**
     * A page is told apart before the cache is written, so a cache that cannot
     * be written does not turn a challenge into a served copy.
     */
    @Test
    fun `a challenge is recognised when the cache cannot be written`() = runTest {
        File(cache.root, "fulltext_pdfs").writeText("a file where the cache directory should be")
        server.enqueue(MockResponse().setHeader("Content-Type", "application/pdf").setBody("<title>Just a moment..."))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CHALLENGED, 200)), download())
    }

    @Test
    fun `an ordinary 403 whose page breaks off keeps its status`() = runTest {
        server.enqueue(brokenBody(403).setHeader("Server", "nginx"))

        assertEquals(PdfDownload.Failed(RequestFailure.forHttpStatus(403)), download())
    }

    @Test
    fun `a 404 whose page breaks off is still gone`() = runTest {
        server.enqueue(brokenBody(404))

        assertEquals(PdfDownload.Failed(RequestFailure.forHttpStatus(404)), download())
    }

    /** A page that begins with [start] and breaks off: MockWebServer sends half its body, then drops it. */
    private fun brokenBody(status: Int, start: String = ""): MockResponse =
        MockResponse()
            .setResponseCode(status)
            .setBody(Buffer().writeUtf8(start).write(ByteArray(BROKEN_PAGE_BYTES)))
            .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)

    @Test
    fun `an ordinary 403 keeps its status`() = runTest {
        server.enqueue(MockResponse().setResponseCode(403).setHeader("Server", "nginx").setBody("<html>"))

        assertEquals(PdfDownload.Failed(RequestFailure.forHttpStatus(403)), download())
    }

    @Test
    fun `a refusal keeps its status`() = runTest {
        for (status in listOf(403, 404, 503)) {
            server.enqueue(MockResponse().setResponseCode(status))

            assertEquals("$status", PdfDownload.Failed(RequestFailure(RequestFailureKind.HTTP_STATUS, status)), download())
        }
    }

    /** No answer at all is a connection failure, which the reader is told "could not be asked". */
    @Test
    fun `a dropped connection is a connection failure`() = runTest {
        server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST))

        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.CONNECTION)), download())
    }

    @Test
    fun `an address that cannot be requested is never asked for`() = runTest {
        for (address in listOf("ftp://repo.example.org/a.pdf", "/a.pdf", "file:///tmp/a.pdf")) {
            assertEquals(
                address,
                PdfDownload.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED)),
                service.downloadPdf(address, "d", null)
            )
        }
        assertEquals(0, server.requestCount)
    }

    /** A body that breaks off is a failure, and no part of it is left to be served as cached. */
    @Test
    fun `a download that breaks off leaves nothing cached`() = runTest {
        server.enqueue(
            MockResponse()
                .setBody(Buffer().write(pdfBytes + ByteArray(TRUNCATED_BODY_PADDING)))
                .setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
        )

        assertTrue(download() is PdfDownload.Failed)
        assertEquals(emptyList<String>(), cachedFiles())
        assertNull(service.getCachedPdfPath("d"))
    }

    /**
     * A cache that cannot be written is our fault, never blamed on the source
     * as a connection failure: the PDF was served (#478).
     */
    @Test
    fun `a PDF that could not be saved is not the source's failure`() = runTest {
        File(cache.root, "fulltext_pdfs").writeText("a file where the cache directory should be")
        server.enqueue(MockResponse().setBody(Buffer().write(pdfBytes)))

        assertSame(PdfDownload.NotSaved, download())
        assertEquals(1, server.requestCount)
        assertEquals(listOf("fulltext_pdfs"), cachedFiles())
    }

    /** A page an earlier build saved as the PDF is quarantined and fetched again. */
    @Test
    fun `a cached file that is not a PDF is fetched again`() = runTest {
        val stale = File(cache.root, "fulltext_pdfs/d.pdf").apply {
            parentFile?.mkdirs()
            writeText("<html>login</html>")
        }
        assertNull(service.getCachedPdfPath("d"))
        server.enqueue(MockResponse().setBody(Buffer().write(pdfBytes)))

        val saved = download() as PdfDownload.Saved

        assertEquals(stale.absolutePath, saved.path)
        assertArrayEquals(pdfBytes, stale.readBytes())
        assertEquals(1, server.requestCount)
        assertEquals("<html>login</html>", File(cache.root, "fulltext_pdfs/d.pdf.corrupt").readText())
    }

    /**
     * A cached PDF is never handed over for an address (#561): every PDF of a document
     * is cached under one name, so the file says nothing about the address asked, and
     * the address is asked.
     */
    @Test
    fun `a cached PDF is never answered for an address, which is asked`() = runTest {
        val cached = File(cache.root, "fulltext_pdfs/d.pdf").apply {
            parentFile?.mkdirs()
            writeText("%PDF-1.4 an earlier download")
        }
        server.enqueue(MockResponse().setBody(Buffer().write(pdfBytes)))

        val saved = download() as PdfDownload.Saved

        assertEquals(1, server.requestCount)
        assertEquals(cached.absolutePath, saved.path)
        assertArrayEquals(pdfBytes, cached.readBytes())
    }

    // ==================== The title check (#546, #561) ====================

    private val title = "Caffeine and blood pressure: a critical review"

    /** A PDF's bytes whose first page carries [firstPage]. */
    private fun titledPdfBytes(firstPage: String): ByteArray =
        writeTitledPdf(File(cache.newFolder(), "titled.pdf"), firstPage).readBytes()

    private val anotherArticle: ByteArray
        get() = titledPdfBytes("Using Effect Size - or Why the P Value Is Not Enough\nGail M. Sullivan")
    private val thisArticle: ByteArray
        get() = titledPdfBytes("$title\nAbstract")

    private val cachedPdf: File get() = File(cache.root, "fulltext_pdfs/d.pdf")
    private val setAside: File get() = File(cache.root, "fulltext_pdfs/d.pdf" + Constants.PDF_MISMATCH_SUFFIX)

    /** Every file in the PDF cache directory, by name. */
    private fun pdfCache(): List<String> =
        File(cache.root, "fulltext_pdfs").listFiles().orEmpty().map { it.name }.sorted()

    /**
     * Another article's PDF is judged where it waits, set aside beside the cache name,
     * and never takes it: this article's PDF cached there stays.
     */
    @Test
    fun `another article's PDF is set aside and leaves the cached PDF alone`() = runTest {
        val kept = thisArticle
        cachedPdf.apply { parentFile?.mkdirs() }.writeBytes(kept)
        val served = anotherArticle
        server.enqueue(MockResponse().setBody(Buffer().write(served)))

        assertSame(PdfDownload.WrongArticle, download(title))

        assertArrayEquals(kept, cachedPdf.readBytes())
        assertArrayEquals(served, setAside.readBytes())
        assertEquals("no partial file left", listOf("d.pdf", "d.pdf.mismatch"), pdfCache())
    }

    /** The control: this article's PDF is saved under the cache name. */
    @Test
    fun `this article's PDF is saved`() = runTest {
        val served = thisArticle
        server.enqueue(MockResponse().setBody(Buffer().write(served)))

        val saved = download(title) as PdfDownload.Saved

        assertEquals(cachedPdf.absolutePath, saved.path)
        assertArrayEquals(served, cachedPdf.readBytes())
        assertEquals(listOf("d.pdf"), pdfCache())
    }

    /** With no title nothing is checked: another article's PDF is saved. */
    @Test
    fun `with no title nothing is checked`() = runTest {
        server.enqueue(MockResponse().setBody(Buffer().write(anotherArticle)))
        assertTrue(download(title = null) is PdfDownload.Saved)
        assertFalse(setAside.exists())
    }

    /**
     * A PDF the check could not judge is kept, never refused: a scan has no text to
     * compare, and a truncated PDF cannot be read. Only a mismatch refuses.
     */
    @Test
    fun `a PDF the check cannot judge is kept`() = runTest {
        val unjudged = mapOf(
            "a scan" to titledPdfBytes(""),
            "a truncated PDF" to "%PDF-1.7\n1 0 obj\n<<".toByteArray()
        )
        for ((name, body) in unjudged) {
            server.enqueue(MockResponse().setBody(Buffer().write(body)))
            assertTrue(name, download(title) is PdfDownload.Saved)
            assertArrayEquals(name, body, cachedPdf.readBytes())
            assertFalse(name, setAside.exists())
        }
    }

    /**
     * #561: a stale cached PDF of another article is never blamed on the address
     * asked. Asked, the address answers for itself: here a 404.
     */
    @Test
    fun `a stale cached PDF of another article is never told as the address's`() = runTest {
        val stale = anotherArticle
        cachedPdf.apply { parentFile?.mkdirs() }.writeBytes(stale)
        server.enqueue(MockResponse().setResponseCode(404))

        assertEquals(PdfDownload.Failed(RequestFailure.forHttpStatus(404)), download(title))

        assertEquals(1, server.requestCount)
        assertFalse("nothing set aside: the cached file was not asked about", setAside.exists())
        assertArrayEquals(stale, cachedPdf.readBytes())
    }

    /**
     * The race the PR #562 review found: a cached PDF the viewer judged another
     * article's, replaced during that check by a download a concurrent fetch checked
     * and moved in, is not set aside; the fresh PDF stays under the cache name.
     */
    @Test
    fun `a cached PDF replaced during its check is not set aside`() = runTest {
        val fresh = thisArticle
        cachedPdf.apply { parentFile?.mkdirs() }.writeBytes(anotherArticle)
        val refused = refusedAsAnotherArticle(cachedPdf.path, title, cacheName = cachedPdf) { file, t ->
            PdfTitleChecker.check(file, t).also {
                // The concurrent fetch's checked download, renamed into place
                val moved = File(cachedPdf.parentFile, "d.pdf.1.part").apply { writeBytes(fresh) }
                assertTrue(moved.renameTo(cachedPdf))
            }
        }
        assertFalse(refused)
        assertArrayEquals(fresh, cachedPdf.readBytes())
        assertFalse(setAside.exists())
    }

    /** The control: a cached PDF of another article left as it was is set aside. */
    @Test
    fun `a cached PDF of another article left as it was is set aside`() = runTest {
        val stale = anotherArticle
        cachedPdf.apply { parentFile?.mkdirs() }.writeBytes(stale)
        assertTrue(refusedAsAnotherArticle(cachedPdf.path, title, cacheName = cachedPdf))
        assertFalse(cachedPdf.exists())
        assertArrayEquals(stale, setAside.readBytes())
    }

    /** A partial file of its own, holding [bytes], beside the cache name. */
    private fun partialHolding(bytes: ByteArray): File =
        File(cachedPdf.parentFile, "d.pdf.1.part").apply { parentFile?.mkdirs(); writeBytes(bytes) }

    /**
     * A download removed before it was cached (the system clears its cache directory
     * under storage pressure) was never judged: a request failed, never a PDF not
     * saved, whose link would offer it.
     */
    @Test
    fun `a download removed before its check is a request failed`() = runTest {
        val gone = File(cachedPdf.parentFile.apply { mkdirs() }, "d.pdf.1.part")
        assertEquals(
            PdfDownload.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED)),
            admitDownload(gone, cachedPdf, title, "https://example.org/a.pdf")
        )
        assertFalse(cachedPdf.exists())
    }

    /** Removed during its check, so the check judged no file: as removed before it. */
    @Test
    fun `a download removed during its check is a request failed`() = runTest {
        val partial = partialHolding(thisArticle)
        val result = admitDownload(partial, cachedPdf, title, "https://example.org/a.pdf") { file, _ ->
            file.delete()
            PdfTitleCheck.Unreadable
        }
        assertEquals(PdfDownload.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED)), result)
        assertFalse(cachedPdf.exists())
    }

    /** The control: one that is there and cannot take its cache name is not saved. */
    @Test
    fun `a download that cannot take its cache name is not saved`() = runTest {
        val partial = partialHolding(thisArticle)
        cachedPdf.mkdirs()
        File(cachedPdf, "x").createNewFile()
        assertSame(PdfDownload.NotSaved, admitDownload(partial, cachedPdf, title, "https://example.org/a.pdf"))
    }

    /**
     * Cancel does not wait for a slow download to end (#665): the call is cancelled,
     * and the partial file goes with it.
     */
    @Test
    fun `a cancelled download ends at once and saves nothing`() = runBlocking {
        server.enqueue(
            MockResponse().setHeader("Content-Type", "application/pdf")
                .setBody(Buffer().write(pdfBytes).write(ByteArray(pdfBytes.size * SLOW_BODY_SECONDS)))
                .throttleBody(pdfBytes.size.toLong(), 1, TimeUnit.SECONDS)
        )
        val job = launch(Dispatchers.IO) { download() }
        assertNotNull(server.takeRequest(SLOW_SECONDS, TimeUnit.SECONDS))

        withTimeout(CANCEL_WITHIN_MS) { job.cancelAndJoin() }

        assertEquals(emptyList<String>(), cachedFiles())
    }

    @Test
    fun `only bytes that begin with the PDF signature look like a PDF`() {
        assertTrue(looksLikePdf(pdfBytes))
        assertFalse(looksLikePdf("%PD".toByteArray()))
        assertFalse(looksLikePdf("<html>".toByteArray()))
        assertFalse(looksLikePdf(ByteArray(0)))
    }

    private companion object {
        /** A download, and a wait for it, far longer than any test. */
        const val SLOW_BODY_SECONDS = 20
        const val SLOW_SECONDS = 60L
        const val CANCEL_WITHIN_MS = 5_000L

        /** Enough body that the server breaks off well before its end. */
        const val TRUNCATED_BODY_PADDING = 256 * 1024

        /** Well under the 64 KiB read of a refusal's page, of which MockWebServer sends half. */
        const val BROKEN_PAGE_BYTES = 8 * 1024
    }
}
