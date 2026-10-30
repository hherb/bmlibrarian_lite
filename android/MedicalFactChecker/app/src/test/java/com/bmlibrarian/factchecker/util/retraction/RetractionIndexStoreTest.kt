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

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import java.io.File
import java.nio.file.Files
import kotlinx.coroutines.async
import kotlinx.coroutines.test.runTest
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The local Retraction Watch index (`RetractionIndexStoreTests.swift`): any refusal keeps the previous file. */
class RetractionIndexStoreTest {
    private lateinit var stub: StubServer
    private lateinit var directory: File
    private var unmetered = true

    private val file get() = File(directory, RetractionConstants.RETRACTION_INDEX_FILE_NAME)

    @Before
    fun setUp() {
        BmlibFfi.assumeAvailable()
        stub = StubServer()
        directory = Files.createTempDirectory("RetractionIndexStoreTest").toFile()
    }

    @After
    fun tearDown() {
        if (::stub.isInitialized) stub.close()
        if (::directory.isInitialized) directory.deleteRecursively()
    }

    private fun store() = RetractionIndexStore(directory, stub.client(), isUnmetered = { unmetered })

    /** Store an index file as an earlier refresh would have. */
    private fun storeIndex(rows: List<String> = RetractionFixture.rows, dataAsOf: String) {
        file.writeBytes(RetractionFixture.index(rows, dataAsOf).toBytes())
    }

    // ---- Reading

    @Test
    fun `a missing or unreadable file is no index`() {
        assertNull(store().currentIndex(RetractionFixture.nowMs))
        file.writeText("not an index")
        assertNull(store().currentIndex(RetractionFixture.nowMs))
    }

    @Test
    fun `a stale index is not used`() {
        storeIndex(dataAsOf = "2026-09-23") // 36 days before 2026-10-29
        assertNull(store().currentIndex(RetractionFixture.nowMs))
        storeIndex(dataAsOf = "2026-09-24") // control: 35 days is still current
        file.setLastModified(file.lastModified() + 2_000)
        assertEquals("2026-09-24", store().currentIndex(RetractionFixture.nowMs)?.dataAsOf())
    }

    // ---- Refreshing

    @Test
    fun `a current index is not downloaded again`() = runTest {
        storeIndex(dataAsOf = RetractionFixture.TODAY)
        assertEquals(RetractionIndexRefresh.Fresh, store().refreshIfStale(RetractionFixture.nowMs, "t@example.org"))
        assertTrue(stub.requestedUrls.isEmpty())
    }

    @Test
    fun `a refresh builds and stores the download`() = runTest {
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv())
        val store = store()
        assertEquals(RetractionIndexRefresh.Refreshed(3), store.refreshIfStale(RetractionFixture.nowMs, "t@example.org"))
        val index = store.currentIndex(RetractionFixture.nowMs)
        assertEquals(RetractionFixture.TODAY, index?.dataAsOf())
        assertEquals(3uL, index?.noticeCount())
        val url = stub.requestedUrls.first()
        assertTrue(url, url.startsWith(RetractionConstants.RETRACTION_WATCH_EXPORT_URL))
        assertTrue(url, url.contains("mailto=t@example.org"))
        assertTrue(stub.requests.first().getHeader("User-Agent")!!.contains("mailto:t@example.org"))
        assertFalse("no temporary file is left", File(directory, "${RetractionConstants.RETRACTION_INDEX_FILE_NAME}.part").exists())
        assertFalse("no download is left", File(directory, "${RetractionConstants.RETRACTION_INDEX_FILE_NAME}.download").exists())
    }

    /** Android kills the process often: the day's wait must outlive it, or every launch downloads again (#647). */
    @Test
    fun `a refusal holds across launches`() = runTest {
        stub.stubbed = StubServer.answer(200, "<html><body>Please sign in</body></html>")
        assertTrue(store().refreshIfStale(RetractionFixture.nowMs, "t@example.org") is RetractionIndexRefresh.Refused)
        assertTrue("a new launch's store", store().refreshIfStale(RetractionFixture.nowMs + 60_000, "t@example.org") is RetractionIndexRefresh.Refused)
        assertEquals(1, stub.requestedUrls.size)
        // control: a day later a new launch tries again, and a success clears the wait
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv())
        val later = RetractionFixture.nowMs + RetractionConstants.RETRACTION_WATCH_REFUSED_BACKOFF_MS
        assertEquals(RetractionIndexRefresh.Refreshed(3), store().refreshIfStale(later, "t@example.org"))
        assertFalse(File(directory, "${RetractionConstants.RETRACTION_INDEX_FILE_NAME}.refused").exists())
    }

    @Test
    fun `a metered network downloads nothing`() = runTest {
        unmetered = false
        assertEquals(RetractionIndexRefresh.Metered, store().refreshIfStale(RetractionFixture.nowMs, "t@example.org"))
        assertTrue(stub.requestedUrls.isEmpty())
    }

    @Test
    fun `a refused download keeps the previous file, and is not downloaded again for a day`() = runTest {
        storeIndex(dataAsOf = "2026-01-01")
        val before = file.readBytes()
        stub.stubbed = StubServer.answer(200, "<html><body>Please sign in</body></html>")
        val store = store()
        assertTrue(store.refreshIfStale(RetractionFixture.nowMs, "t@example.org") is RetractionIndexRefresh.Refused)
        assertArrayEquals(before, file.readBytes())
        assertTrue(store.refreshIfStale(RetractionFixture.nowMs + 60_000, "t@example.org") is RetractionIndexRefresh.Refused)
        assertEquals("a refused export is not downloaded again at once (#647)", 1, stub.requestedUrls.size)
        // control: a day later it is tried again
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv())
        val later = RetractionFixture.nowMs + RetractionConstants.RETRACTION_WATCH_REFUSED_BACKOFF_MS
        assertEquals(RetractionIndexRefresh.Refreshed(3), store.refreshIfStale(later, "t@example.org"))
    }

    @Test
    fun `a shrunk export is refused, an unshrunk one replaces a stale copy`() = runTest {
        storeIndex(RetractionFixture.retractions(10), dataAsOf = "2026-01-01")
        val before = file.readBytes()
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv(RetractionFixture.retractions(9)))
        assertTrue(store().refreshIfStale(RetractionFixture.nowMs, "t@example.org") is RetractionIndexRefresh.Refused)
        assertArrayEquals(before, file.readBytes())
        // control, once the refusal's day has passed
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv(RetractionFixture.retractions(10)))
        val later = RetractionFixture.nowMs + RetractionConstants.RETRACTION_WATCH_REFUSED_BACKOFF_MS
        val store = store()
        assertEquals(RetractionIndexRefresh.Refreshed(10), store.refreshIfStale(later, "t@example.org"))
        assertEquals(RetractionIndexStore.today(later).toString(), store.currentIndex(later)?.dataAsOf())
    }

    @Test
    fun `a failed download keeps the previous file and is tried again next time`() = runTest {
        storeIndex(dataAsOf = "2026-01-01")
        val before = file.readBytes()
        stub.stubbed = StubServer.answer(404)
        val store = store()
        assertEquals(
            RetractionIndexRefresh.Failed(RequestFailure(RequestFailureKind.HTTP_STATUS, 404)),
            store.refreshIfStale(RetractionFixture.nowMs, "t@example.org")
        )
        assertArrayEquals(before, file.readBytes())
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv())
        assertEquals(RetractionIndexRefresh.Refreshed(3), store.refreshIfStale(RetractionFixture.nowMs, "t@example.org"))
        assertEquals(2, stub.requestedUrls.size)
    }

    @Test
    fun `a download cut short is refused`() = runTest {
        val body = RetractionFixture.csv()
        stub.stubbed = StubServer.answer(200, body)
            .setHeader("Content-Length", body.size + 100)
            .setSocketPolicy(SocketPolicy.DISCONNECT_AT_END)
        assertEquals(
            RetractionIndexRefresh.Failed(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)),
            store().refreshIfStale(RetractionFixture.nowMs, "t@example.org")
        )
        assertFalse(file.exists())
    }

    /** Launch and a run may both ask while the copy is stale: one download serves both. */
    @Test
    fun `concurrent refreshes download once`() = runTest {
        stub.stubbed = StubServer.answer(200, RetractionFixture.csv())
        val store = store()
        val first = async { store.refreshIfStale(RetractionFixture.nowMs, "t@example.org") }
        val second = async { store.refreshIfStale(RetractionFixture.nowMs, "t@example.org") }
        first.await()
        second.await()
        assertEquals(1, stub.requestedUrls.size)
    }
}
