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
import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Dns
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File
import java.net.InetAddress
import java.util.concurrent.TimeUnit

/**
 * Elsevier's API through the real service and a local server (#480, stage C2):
 * every `answers` and `session` row of `elsevier_article.json`, where the key and
 * the token travel, the refused redirect, the pause, the refusals' scopes, the
 * cache, cancellation and pacing.
 */
class ElsevierServiceTest {
    @get:Rule
    val folder = TemporaryFolder()

    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val doi = "10.1016/j.cell.2020.02.052"
    private val path = "${Constants.ELSEVIER_ARTICLE_PATH}$doi"
    private var key: String? = KEY
    private var token: String? = null

    /** The cache directory the services built here save in; [fetch] sets it per call. */
    private var cacheRoot: File? = null

    @Before
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.requestUrl?.encodedPath ?: ""] ?: MockResponse().setResponseCode(404)
        }
        server.start(InetAddress.getLoopbackAddress(), 0)
        Log.clear()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun service(
        maxRetries: Int = 0,
        pacer: RequestPacer = RequestPacer(0L),
        session: KeyedServiceSession = Elsevier.newSession(),
        shared: OkHttpClient = OkHttpClient(),
        baseUrl: String = server.url("").toString().trimEnd('/')
    ) = ElsevierService(
        ElsevierService.client(shared), baseUrl, { cacheRoot!! }, { key }, { token }, pacer, maxRetries, 0L, session
    )

    /** Ask for [forDoi], the PDF cached in [dir]. */
    private suspend fun ElsevierService.fetch(dir: File = cacheDir(), forDoi: String = doi): ElsevierFetch? {
        cacheRoot = dir
        return fetchPdf(forDoi)
    }

    private fun cacheDir(): File = folder.newFolder()

    private fun cachedPath(dir: File): String = File(dir, Elsevier.cacheFileName(doi)).absolutePath

    private fun pdf(): MockResponse = MockResponse().setBody(Buffer().write(CONTRACT_PDF_BODY))

    /** The response a contract row describes. */
    private fun responseFor(row: JsonObject): MockResponse {
        val response = MockResponse().setResponseCode(row.getValue("status").jsonPrimitive.int)
        headersOf(row).forEach { (name, value) -> response.addHeader(name, value) }
        return response.setBody(Buffer().write(bodyOf(row)))
    }

    @Test
    fun `every answers row of the fixture gets its outcome`() = runBlocking {
        val rows = elsevierContract().getValue("answers").jsonArray.map { it.jsonObject }
        assertTrue("${rows.size} answers rows; an emptied table would pass vacuously", rows.size >= MIN_ANSWER_ROWS)
        for (row in rows) {
            val name = row.getValue("name").jsonPrimitive.content
            val status = row.getValue("status").jsonPrimitive.int
            routes[path] = responseFor(row)
            val dir = cacheDir()
            // A fresh service each row: two 429s would otherwise pause the next
            val fetch = service().fetch(dir)
            assertEquals(name, fetchFor(expectedAnswer(row, status), cachedPath(dir)), fetch)
            if (fetch is ElsevierFetch.Served) {
                assertArrayEquals(name, CONTRACT_PDF_BODY, File(fetch.localPath).readBytes())
            }
            // Nothing but a served PDF is ever left in the cache, and no partial file
            val left = dir.listFiles().orEmpty().map { it.name }
            assertEquals(name, if (fetch is ElsevierFetch.Served) listOf(Elsevier.cacheFileName(doi)) else emptyList(), left)
        }
    }

    @Test
    fun `every session row of the fixture gets its outcome`() = runBlocking {
        val rows = elsevierContract().getValue("session").jsonArray.map { it.jsonObject }
        assertTrue("${rows.size} session rows; an emptied table would pass vacuously", rows.size >= MIN_SESSION_ROWS)
        for (row in rows) {
            val name = row.getValue("name").jsonPrimitive.content
            val service = service()
            val dir = cacheDir()
            fun ask(step: JsonObject): Pair<Boolean, ElsevierFetch?> = runBlocking {
                val (stepKey, stepToken) = credentialsOf(step)
                key = stepKey
                token = stepToken
                val body = step["body_text"]?.jsonPrimitive?.contentOrNull.orEmpty()
                routes[path] = MockResponse().setResponseCode(step.getValue("status").jsonPrimitive.int).setBody(body)
                val before = server.requestCount
                val result = service.fetch(dir)
                (server.requestCount > before) to result
            }
            row.getValue("fetches").jsonArray.forEach { ask(it.jsonObject) }
            for (check in row.getValue("then").jsonArray.map { it.jsonObject }) {
                val (asked, result) = ask(check)
                assertEquals("$name: $check", check.getValue("asked").jsonPrimitive.content.toBoolean(), asked)
                assertEquals("$name: $check", fetchFor(expectedSessionAnswer(check), cachedPath(dir)), result)
            }
        }
    }

    @Test
    fun `the key and the token travel in their headers alone`() = runBlocking {
        token = TOKEN
        routes[path] = pdf()
        service().fetch()
        val request = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!
        assertEquals(KEY, request.getHeader(Constants.ELSEVIER_KEY_HEADER))
        assertEquals(TOKEN, request.getHeader(Constants.ELSEVIER_TOKEN_HEADER))
        assertEquals(Constants.ELSEVIER_ACCEPT, request.getHeader("Accept"))
        assertEquals(path, request.requestUrl!!.encodedPath)
        assertNull(request.requestUrl!!.query)
        assertFalse(KEY in request.requestUrl.toString() || TOKEN in request.requestUrl.toString())
        // Nothing else carries them
        assertNull(request.getHeader("Authorization"))
    }

    /** Trimmed, and a blank token is no token: never sent as an empty header. */
    @Test
    fun `the key is sent trimmed, and a blank token not at all`() = runBlocking {
        key = "  $KEY\n"
        token = "   "
        routes[path] = MockResponse().setResponseCode(404)
        assertEquals(ElsevierFetch.Absent, service().fetch())
        val request = server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS)!!
        assertEquals(KEY, request.getHeader(Constants.ELSEVIER_KEY_HEADER))
        assertNull(request.getHeader(Constants.ELSEVIER_TOKEN_HEADER))
    }

    /** Neither the key nor the token is ever logged, whatever the fetch comes to. */
    @Test
    fun `no log line holds the key or the token`() = runBlocking {
        token = TOKEN
        val answers = listOf(
            pdf(),
            MockResponse().setHeader(Constants.ELSEVIER_STATUS_HEADER, "WARNING - first page").setBody("%PDF-1.7"),
            MockResponse().setBody("<html/>"),
            MockResponse().setResponseCode(Constants.ELSEVIER_KEY_REFUSED_STATUS),
            MockResponse().setResponseCode(Constants.ELSEVIER_NETWORK_REFUSED_STATUS).setBody("AUTHENTICATION_ERROR"),
            MockResponse().setResponseCode(503),
            MockResponse().setResponseCode(429),
            MockResponse().setResponseCode(429)
        )
        val service = service()
        for (answer in answers) {
            routes[path] = answer
            service.fetch()
            // A refused key and refused credentials are told again, with no request
            service.fetch()
            key = "$KEY-${server.requestCount}"
        }
        // Not saved, and a transport failure
        routes[path] = pdf()
        service().fetch(folder.newFile())
        server.shutdown()
        service().fetch()
        assertTrue("the control: something was logged", Log.lines.isNotEmpty())
        assertFalse(Log.lines.toString(), Log.lines.any { KEY in it || TOKEN in it })
    }

    /** No key = nothing told: a debug line says so, and nothing is sent, the token included. */
    @Test
    fun `without a key nothing is asked`() = runBlocking {
        token = TOKEN
        for (absent in listOf<String?>(null, "", "  ")) {
            Log.clear()
            key = absent
            assertNull(service().fetch())
            assertEquals(Log.lines.toString(), 1, Log.lines.size)
            assertTrue(Log.lines.single(), Log.lines.single().startsWith("ElsevierService: No Elsevier API key"))
        }
        assertEquals(0, server.requestCount)
    }

    /** Another publisher's DOI is never asked, and records nothing. */
    @Test
    fun `a DOI that is not Elsevier's is never asked`() = runBlocking {
        for (other in listOf("10.1371/journal.pone.0000217", "10.10160/x", "", "  ")) {
            assertNull(other, service().fetch(forDoi = other))
        }
        assertEquals(0, server.requestCount)
        // The control: an Elsevier DOI is asked
        routes[path] = MockResponse().setResponseCode(404)
        assertEquals(ElsevierFetch.Absent, service().fetch())
        assertEquals(1, server.requestCount)
    }

    /** The key follows no redirect, to any host: a 3xx is the answer, never followed. */
    @Test
    fun `a redirect to another host is not followed`() = runBlocking {
        // Every name is the loopback server, so the other host name would reach it too
        val loopback = OkHttpClient.Builder().dns(object : Dns {
            override fun lookup(hostname: String) = listOf(InetAddress.getLoopbackAddress())
        }).build()
        routes[path] = MockResponse().setResponseCode(HTTP_FOUND)
            .setHeader("Location", "http://localhost:${server.port}$REDIRECTED_PATH")
        routes[REDIRECTED_PATH] = pdf()
        val fetch = service(shared = loopback, baseUrl = "http://127.0.0.1:${server.port}").fetch()
        assertEquals(ElsevierFetch.Unreachable(RequestFailure.forHttpStatus(HTTP_FOUND)), fetch)
        assertEquals("the redirect was not followed", 1, server.requestCount)
        // The control: the shared client itself follows redirects; the derived one does not
        assertTrue(loopback.followRedirects)
        assertFalse(ElsevierService.client(loopback).followRedirects)
        assertFalse(ElsevierService.client(loopback).followSslRedirects)
        assertFalse(ElsevierService.client(loopback).retryOnConnectionFailure)
    }

    @Test
    fun `two 429s in a row pause Elsevier for the session`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(429)
        val session = Elsevier.newSession()
        val service = service(session = session)
        val throttled = ElsevierFetch.Unreachable(RequestFailure.forHttpStatus(429))
        assertEquals(throttled, service.fetch())
        assertFalse(session.isPaused)
        assertEquals(throttled, service.fetch())
        assertTrue(session.isPaused)
        routes[path] = pdf()
        assertEquals(throttled, service.fetch())
        assertEquals(2, server.requestCount)
    }

    /** A 401 refuses the key only; a 403 AUTHENTICATION_ERROR those credentials only. */
    @Test
    fun `refusals are scoped to the key, and to the credentials`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(Constants.ELSEVIER_KEY_REFUSED_STATUS)
        assertEquals(ElsevierFetch.KeyRefused, service.fetch())
        token = TOKEN
        assertEquals("the key is refused whatever the token", ElsevierFetch.KeyRefused, service.fetch())
        assertEquals(1, server.requestCount)

        key = "$KEY-corrected"
        token = null
        routes[path] = MockResponse().setResponseCode(Constants.ELSEVIER_NETWORK_REFUSED_STATUS)
            .setBody("<service-error><status><statusCode>AUTHENTICATION_ERROR</statusCode></status></service-error>")
        assertEquals(ElsevierFetch.NetworkRefused, service.fetch())
        assertEquals(ElsevierFetch.NetworkRefused, service.fetch())
        assertEquals(2, server.requestCount)

        // A token added in the settings makes other credentials, which are asked
        token = TOKEN
        routes[path] = pdf()
        val dir = cacheDir()
        assertEquals(ElsevierFetch.Served(cachedPath(dir)), service.fetch(dir))
        assertEquals(3, server.requestCount)
    }

    /**
     * The checks before a request come in the contract's order: a key refused is told
     * as such even when those credentials were also refused from this network.
     */
    @Test
    fun `a refused key is told before a refused network`() = runBlocking {
        val service = service()
        routes[path] = MockResponse().setResponseCode(Constants.ELSEVIER_NETWORK_REFUSED_STATUS)
            .setBody(Constants.ELSEVIER_NETWORK_REFUSED_TOKEN)
        assertEquals(ElsevierFetch.NetworkRefused, service.fetch())
        // The same key with a token is other credentials: asked, and the key refused
        token = TOKEN
        routes[path] = MockResponse().setResponseCode(Constants.ELSEVIER_KEY_REFUSED_STATUS)
        assertEquals(ElsevierFetch.KeyRefused, service.fetch())
        // Both refusals now hold for the key without a token: the key's is told
        token = null
        assertEquals(ElsevierFetch.KeyRefused, service.fetch())
        assertEquals(2, server.requestCount)
    }

    /** A PDF saved earlier is served without a request, even while Elsevier refuses or is paused. */
    @Test
    fun `a cached PDF is served without asking`() = runBlocking {
        val dir = cacheDir()
        File(dir, Elsevier.cacheFileName(doi)).writeBytes(CONTRACT_PDF_BODY)
        val session = Elsevier.newSession()
        Elsevier.record(ElsevierAnswer.KeyRefused, Constants.ELSEVIER_KEY_REFUSED_STATUS, session, KeyDigest.key(KEY), "")
        routes[path] = MockResponse().setResponseCode(404)
        assertEquals(ElsevierFetch.Served(cachedPath(dir)), service(session = session).fetch(dir))
        assertEquals(0, server.requestCount)
        // The control: without the file, the refused key is told
        assertEquals(ElsevierFetch.KeyRefused, service(session = session).fetch())
    }

    /** A cached file that is not a PDF is set aside, and Elsevier asked. */
    @Test
    fun `a corrupt cached file is quarantined and Elsevier asked`() = runBlocking {
        val dir = cacheDir()
        val cached = File(dir, Elsevier.cacheFileName(doi))
        cached.writeText("<html>not a PDF</html>")
        routes[path] = pdf()
        assertEquals(ElsevierFetch.Served(cached.absolutePath), service().fetch(dir))
        assertEquals(1, server.requestCount)
        assertArrayEquals(CONTRACT_PDF_BODY, cached.readBytes())
        assertEquals("<html>not a PDF</html>", File(dir, "${cached.name}.corrupt").readText())
    }

    /** A PDF served that cannot be written is NotSaved, logged at ERROR, and never a link. */
    @Test
    fun `a PDF that cannot be saved is not saved`() = runBlocking {
        routes[path] = pdf()
        // A file where the cache directory should be: nothing can be written under it
        val notADirectory = folder.newFile()
        assertEquals(ElsevierFetch.NotSaved, service().fetch(notADirectory))
        assertEquals(1, server.requestCount)
        assertTrue(
            Log.levelledLines.toString(),
            Log.levelledLines.any { it.startsWith("E/ElsevierService: ") && "could not be saved" in it }
        )
    }

    /**
     * A zero-width space or a curly quote pasted with a key is never sent: OkHttp
     * would refuse the header quoting its value, so the fetch would throw, end the
     * whole chain and show the key. Unreachable instead, and logged without it.
     */
    @Test
    fun `credentials that cannot be sent are never sent, nor logged`() = runBlocking {
        routes[path] = pdf()
        val cases = listOf("zero\u200Bwidth-$KEY" to null, "curly\u2019$KEY" to null, KEY to "zero\u200Bwidth-$TOKEN")
        for ((badKey, badToken) in cases) {
            Log.clear()
            key = badKey
            token = badToken
            val session = Elsevier.newSession()
            val fetch = service(session = session).fetch()
            assertEquals(badKey, ElsevierFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED)), fetch)
            assertFalse("recorded nowhere", session.isPaused)
            assertTrue(Log.lines.toString(), Log.lines.any { "cannot be sent" in it })
            assertFalse(Log.lines.toString(), Log.lines.any { KEY in it || TOKEN in it })
        }
        assertEquals("never sent", 0, server.requestCount)
    }

    /** A PDF whose connection drops mid-body is the transport's failure: nothing kept, never "not saved". */
    @Test
    fun `a body cut off mid-stream is unreachable and leaves nothing`() = runBlocking {
        val body = Buffer().write(CONTRACT_PDF_BODY).write(ByteArray(LARGE_BODY_BYTES))
        routes[path] = MockResponse().setBody(body).setSocketPolicy(SocketPolicy.DISCONNECT_DURING_RESPONSE_BODY)
        val dir = cacheDir()
        val fetch = service().fetch(dir)
        assertTrue(fetch.toString(), fetch is ElsevierFetch.Unreachable)
        assertEquals("neither the PDF nor its .part file", emptyList<String>(), dir.listFiles().orEmpty().map { it.name })
    }

    /** A key the settings could not read is unreachable, never "no key", and nothing is sent. */
    @Test
    fun `a key or token that cannot be read is unreachable`() = runBlocking {
        val failing: () -> String? = { throw IllegalStateException("keystore unavailable") }
        val dir = cacheDir()
        fun service(apiKey: () -> String?, instToken: () -> String?) = ElsevierService(
            ElsevierService.client(OkHttpClient()), server.url("").toString().trimEnd('/'), { dir },
            apiKey, instToken, RequestPacer(0L), 0, 0L, Elsevier.newSession()
        )
        val unreachable = ElsevierFetch.Unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        assertEquals(unreachable, service(failing) { null }.fetchPdf(doi))
        assertEquals(unreachable, service({ KEY }, failing).fetchPdf(doi))
        assertEquals(0, server.requestCount)
        // The control: readable settings ask
        routes[path] = MockResponse().setResponseCode(404)
        assertEquals(ElsevierFetch.Absent, service({ KEY }) { null }.fetchPdf(doi))
    }

    /** One fetch whose 429s outlast its retries counts once toward the pause, however many attempts it made. */
    @Test
    fun `a 429 outlasting its retries counts once`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(429)
        val session = Elsevier.newSession()
        val service = service(maxRetries = 1, session = session)
        assertEquals(ElsevierFetch.Unreachable(RequestFailure.forHttpStatus(429)), service.fetch())
        assertEquals("retried once", 2, server.requestCount)
        assertFalse("two attempts are one fetch", session.isPaused)
        // The control: a second fetch ending in 429 pauses
        service.fetch()
        assertTrue(session.isPaused)
    }

    @Test
    fun `no server is unreachable`() = runBlocking {
        server.shutdown()
        val fetch = service().fetch()
        assertTrue(fetch.toString(), fetch is ElsevierFetch.Unreachable)
        assertEquals(RequestFailureKind.CONNECTION, (fetch as ElsevierFetch.Unreachable).failure.kind)
    }

    @Test
    fun `cancellation still propagates`() {
        val cancelling = OkHttpClient.Builder()
            .addInterceptor(Interceptor { throw CancellationException("cancelled") })
            .build()
        assertThrows(CancellationException::class.java) {
            runBlocking { service(shared = cancelling).fetch() }
        }
    }

    @Test
    fun `every attempt takes a pacer slot`() = runBlocking {
        routes[path] = MockResponse().setResponseCode(503)
        val retries = Constants.ELSEVIER_MAX_RETRIES
        val service = service(maxRetries = retries, pacer = RequestPacer(PACER_INTERVAL_MS))
        val started = System.nanoTime()
        val fetch = service.fetch()
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)
        assertEquals(ElsevierFetch.Unreachable(RequestFailure.forHttpStatus(503)), fetch)
        assertEquals("four attempts in all", retries + 1, server.requestCount)
        assertTrue("$elapsedMs ms", elapsedMs >= retries * PACER_INTERVAL_MS)
    }

    /**
     * The session the injected services use is the process's: a key refused by one
     * is refused by another, with no request. The key is this test's own, so the
     * refusal it leaves in the process refuses no other test's key.
     */
    @Test
    fun `injected services share one session`() = runBlocking {
        val processKey = "process-wide-test-key"
        val context: Context = mockk { every { cacheDir } returns folder.newFolder() }
        val settings: SettingsRepository = mockk {
            every { getElsevierApiKey() } returns processKey
            every { getElsevierInstToken() } returns ""
        }
        // Every request goes to the local server, wherever it was addressed
        val toServer = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val local = chain.request().url.newBuilder().scheme("http").host(server.hostName).port(server.port).build()
            chain.proceed(chain.request().newBuilder().url(local).build())
        }).build()
        routes[path] = MockResponse().setResponseCode(Constants.ELSEVIER_KEY_REFUSED_STATUS)
        assertEquals(ElsevierFetch.KeyRefused, ElsevierService(toServer, settings, context).fetchPdf(doi))
        assertEquals(ElsevierFetch.KeyRefused, ElsevierService(toServer, settings, context).fetchPdf(doi))
        assertEquals("the second service sent nothing", 1, server.requestCount)
        // The control: a test's own session is not the process's
        routes[path] = MockResponse().setResponseCode(404)
        key = processKey
        assertEquals(ElsevierFetch.Absent, service().fetch())
    }

    /** A CORE paused by its 429s leaves Elsevier's process session untouched: the two share nothing. */
    @Test
    fun `a CORE pause never pauses Elsevier`() = runBlocking {
        routes[Constants.CORE_SEARCH_PATH] = MockResponse().setResponseCode(429)
        val core = CoreService(
            PmcOpenDataService.bucketClient(OkHttpClient(), Constants.CORE_REQUEST_TIMEOUT_SECONDS),
            server.url("").toString().trimEnd('/'), { "core-key" }, RequestPacer(0L), 0, 0L
        )
        repeat(Constants.CORE_PAUSE_AFTER_CONSECUTIVE_429) { core.fetchText(doi) }
        assertTrue("the control: CORE is paused", core.isPaused)

        // The injected Elsevier service, on the process's session, still asks
        val context: Context = mockk { every { cacheDir } returns folder.newFolder() }
        val settings: SettingsRepository = mockk {
            every { getElsevierApiKey() } returns "core-pause-test-key"
            every { getElsevierInstToken() } returns ""
        }
        val toServer = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
            val local = chain.request().url.newBuilder().scheme("http").host(server.hostName).port(server.port).build()
            chain.proceed(chain.request().newBuilder().url(local).build())
        }).build()
        routes[path] = MockResponse().setResponseCode(Constants.HTTP_NOT_FOUND)
        val before = server.requestCount
        assertEquals(ElsevierFetch.Absent, ElsevierService(toServer, settings, context).fetchPdf(doi))
        assertEquals("Elsevier was asked", before + 1, server.requestCount)
    }

    private companion object {
        const val KEY = "test-elsevier-key"
        const val TOKEN = "test-elsevier-token"
        const val PACER_INTERVAL_MS = 150L
        const val REQUEST_WAIT_SECONDS = 5L
        const val MIN_ANSWER_ROWS = 24
        const val MIN_SESSION_ROWS = 11
        const val HTTP_FOUND = 302
        const val LARGE_BODY_BYTES = 256 * 1024
        const val REDIRECTED_PATH = "/redirected"
    }
}
