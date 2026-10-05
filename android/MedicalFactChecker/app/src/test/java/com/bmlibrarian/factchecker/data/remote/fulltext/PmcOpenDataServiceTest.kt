package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.cancelAndJoin
import kotlinx.coroutines.launch
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import okhttp3.Dns
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okhttp3.mockwebserver.SocketPolicy
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.io.File
import java.net.InetAddress
import java.util.concurrent.TimeUnit

class PmcOpenDataServiceTest {
    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val listingHits = java.util.concurrent.atomic.AtomicInteger()
    /** When set, the listing's first answer has this status; later ones follow [routes]. */
    private var firstListingStatus: Int? = null
    private val listing = """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents></ListBucketResult>"""
    private val article = "<article><body><p>The study.</p></body></article>"
    private val articlePath = "/PMC10358571.1/PMC10358571.1.xml"

    @Before
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl?.encodedPath ?: ""
                val first = firstListingStatus
                if (path == "/" && first != null && listingHits.getAndIncrement() == 0) {
                    return MockResponse().setResponseCode(first)
                }
                return routes[path] ?: MockResponse().setResponseCode(404)
            }
        }
        // One address, so the dropped-connection test can pin its client to it
        server.start(InetAddress.getLoopbackAddress(), 0)
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private val baseUrl get() = server.url("/").toString().trimEnd('/')

    /**
     * The service as the app builds it, against the local server: the shared
     * client (OkHttp's defaults, which replay failed connections) goes through
     * [PmcOpenDataService.bucketClient], so no test passes on a replay the app
     * would not make.
     */
    private fun service(
        maxRetries: Int = 0,
        pacer: RequestPacer = RequestPacer(0L),
        initialBackoffMs: Long = 0L,
        client: OkHttpClient = PmcOpenDataService.bucketClient(
            OkHttpClient(), Constants.PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS
        )
    ) = PmcOpenDataService(client, baseUrl, pacer, maxRetries, initialBackoffMs)

    private val malformed = PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    private fun routeAll() {
        routes["/"] = MockResponse().setBody(listing)
        routes["/metadata/PMC10358571.1.json"] = MockResponse().setBody(
            """{"xml_url":"s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml?md5=a"}"""
        )
        routes[articlePath] = MockResponse().setBody(article)
    }

    @Test
    fun served() = runBlocking {
        routeAll()
        assertEquals(PmcOpenDataFetch.Served(article), service().fetchXml("PMC10358571"))
    }

    /** S3 answers NoSuchBucket with a 404; an article missing from the collection is an empty 200 listing. */
    @Test
    fun `a listing 404 is unreachable, not absent`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(404)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(404)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a metadata 404 after the listing named it is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setBody(listing)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(404)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a throttled listing is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(503)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a 503 then a 200 on the listing is served after a retry`() = runBlocking {
        routeAll()
        firstListingStatus = 503
        assertEquals(PmcOpenDataFetch.Served(article), service(maxRetries = 1).fetchXml("PMC10358571"))
        assertEquals(2, listingHits.get())
    }

    @Test
    fun `a JATS body where a listing should be is malformed`() = runBlocking {
        routes["/"] = MockResponse().setBody(article)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a blank article is incomplete`() = runBlocking {
        routeAll()
        routes[articlePath] = MockResponse().setBody("  ")
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a non-ASCII article served as an octet-stream round-trips exactly`() = runBlocking {
        routeAll()
        val text = "<article><body><p>Müller’s cohort — 95 % CI</p></body></article>"
        routes[articlePath] = MockResponse()
            .setHeader("Content-Type", "binary/octet-stream")
            .setBody(Buffer().writeUtf8(text))
        assertEquals(PmcOpenDataFetch.Served(text), service().fetchXml("PMC10358571"))
    }

    @Test
    fun `an article that is not valid UTF-8 is malformed`() = runBlocking {
        routeAll()
        routes[articlePath] = MockResponse()
            .setHeader("Content-Type", "binary/octet-stream")
            .setBody(Buffer().write(byteArrayOf(0xFF.toByte(), 0xFE.toByte())))
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a preprint is never asked`() = runBlocking {
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PPR1316954"))
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `the listing asks for this article's prefix`() = runBlocking {
        service().fetchXml("PMC10358571")
        val url = server.takeRequest().requestUrl!!
        assertEquals("2", url.queryParameter("list-type"))
        assertEquals("metadata/PMC10358571.", url.queryParameter("prefix"))
    }

    private val badRecordRoute = "/metadata/PMC10358571.1.json"

    @Test
    fun `a 404 listing is asked once and is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(404)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(404)),
            service(maxRetries = 1).fetchXml("PMC10358571")
        )
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `a 403 listing is asked once and is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(403)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(403)),
            service(maxRetries = 1).fetchXml("PMC10358571")
        )
        assertEquals(1, server.requestCount)
    }

    /**
     * OkHttp's default client replays a 408 on its own, outside the pacer; the
     * bucket's client ([PmcOpenDataService.bucketClient]) must not, and the
     * service's own policy does not retry a 408 either.
     */
    @Test
    fun `a 408 is not retried`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(408)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(408)),
            service(maxRetries = 1).fetchXml("PMC10358571")
        )
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `the bucket's client has its own timeout and replays nothing`() {
        val shared = OkHttpClient.Builder()
            .readTimeout(SHARED_READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
        val bucket = PmcOpenDataService.bucketClient(shared, Constants.PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS)
        val timeoutMs = TimeUnit.SECONDS.toMillis(Constants.PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS).toInt()
        assertEquals(timeoutMs, bucket.connectTimeoutMillis)
        assertEquals(timeoutMs, bucket.readTimeoutMillis)
        assertFalse(bucket.retryOnConnectionFailure)
        // The shared client is untouched
        assertTrue(shared.retryOnConnectionFailure)
    }

    @Test
    fun `a 429 then a 200 on the listing is served after a retry`() = runBlocking {
        routeAll()
        firstListingStatus = 429
        assertEquals(PmcOpenDataFetch.Served(article), service(maxRetries = 1).fetchXml("PMC10358571"))
        assertEquals(2, listingHits.get())
    }

    @Test
    fun `every retry takes its own pacer slot`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(429)
        val retries = 3
        // No backoff, so only the pacer spaces the attempts out
        val service = service(maxRetries = retries, pacer = RequestPacer(PACER_INTERVAL_MS), initialBackoffMs = 0L)
        val started = System.nanoTime()
        val fetch = service.fetchXml("PMC10358571")
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertEquals(PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(429)), fetch)
        assertEquals(retries + 1, server.requestCount)
        // The first attempt goes at once; each retry waits out the interval
        assertTrue("$elapsedMs ms", elapsedMs >= retries * PACER_INTERVAL_MS)
    }

    // ==================== Transport failures: unreachable, of their real kind ====================

    /**
     * A connection dropped after the request is a connection failure, retried
     * or not. Asserted exactly: an empty 200 listing would also be unreachable
     * (malformed). Under a custom Dispatcher MockWebServer ignores
     * DISCONNECT_AT_START and answers an empty 200, so the drop comes after the
     * request is read.
     *
     * The client resolves `localhost` to the server's one address: after a drop
     * OkHttp postpones that route, and without its own connection retries it
     * would send the next attempt to the other loopback address, which nothing
     * listens on.
     */
    @Test
    fun `a dropped connection is a connection failure`() = runBlocking {
        routes["/"] = MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AFTER_REQUEST)
        val dropped = PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.CONNECTION))
        val pinned = PmcOpenDataService.bucketClient(
            OkHttpClient.Builder().dns(object : Dns {
                override fun lookup(hostname: String) = listOf(InetAddress.getLoopbackAddress())
            }).build(),
            Constants.PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS
        )

        assertEquals(dropped, service(maxRetries = 0, client = pinned).fetchXml("PMC10358571"))
        assertEquals(1, server.requestCount)

        val retries = 2
        assertEquals(dropped, service(maxRetries = retries, client = pinned).fetchXml("PMC10358571"))
        // Each failed attempt was the service's own, paced retry: OkHttp replayed none
        assertEquals(1 + retries + 1, server.requestCount)
    }

    @Test
    fun `a read that outlasts the timeout is a timeout`() = runBlocking {
        routes["/"] = MockResponse().setBody(listing).setHeadersDelay(SLOW_ANSWER_MS, TimeUnit.MILLISECONDS)
        val impatient = OkHttpClient.Builder()
            .readTimeout(SHORT_TIMEOUT_MS, TimeUnit.MILLISECONDS)
            .retryOnConnectionFailure(false)
            .build()
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.TIMEOUT)),
            service(client = impatient).fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a cancelled caller is cancelled, not answered`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(503)
        // A long backoff: the cancellation lands while the service waits to retry
        val service = service(maxRetries = 3, initialBackoffMs = LONG_BACKOFF_MS)
        var answer: PmcOpenDataFetch? = null
        val job = launch(Dispatchers.Default) { answer = service.fetchXml("PMC10358571") }

        assertNotNull(server.takeRequest(REQUEST_WAIT_SECONDS, TimeUnit.SECONDS))
        val started = System.nanoTime()
        job.cancelAndJoin()

        assertNull("a cancelled fetch must not return an answer", answer)
        assertTrue(job.isCancelled)
        assertTrue(TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started) < LONG_BACKOFF_MS)
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `a constant 503 listing is asked twice with one retry`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(503)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503)),
            service(maxRetries = 1).fetchXml("PMC10358571")
        )
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `an article 404 and an article 503 are unreachable with that status`() = runBlocking {
        routeAll()
        routes.remove(articlePath)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(404)),
            service().fetchXml("PMC10358571")
        )
        routes[articlePath] = MockResponse().setResponseCode(503)
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a record without xml_url is absent`() = runBlocking {
        routeAll()
        routes[badRecordRoute] = MockResponse().setBody("""{"license_code":"TDM"}""")
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PMC10358571"))
    }

    @Test
    fun `a record whose xml_url is null is absent`() = runBlocking {
        routeAll()
        routes[badRecordRoute] = MockResponse().setBody("""{"xml_url":null}""")
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PMC10358571"))
    }

    @Test
    fun `a record naming XML in another bucket is malformed, not absent`() = runBlocking {
        routeAll()
        routes[badRecordRoute] = MockResponse().setBody(
            """{"xml_url":"s3://some-other-bucket/PMC10358571.1/PMC10358571.1.xml"}"""
        )
        assertEquals(malformed, service().fetchXml("PMC10358571"))
        // The other bucket's object was never asked for
        assertEquals(2, server.requestCount)
    }

    @Test
    fun `a record whose xml_url is not a string is malformed, not absent`() = runBlocking {
        routeAll()
        routes[badRecordRoute] = MockResponse().setBody("""{"xml_url":42}""")
        assertEquals(malformed, service().fetchXml("PMC10358571"))
    }

    @Test
    fun `a listing naming the article only under an unreadable version is malformed, not absent`() = runBlocking {
        routes["/"] = MockResponse().setBody(
            """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.x.json</Key></Contents></ListBucketResult>"""
        )
        assertEquals(malformed, service().fetchXml("PMC10358571"))
    }

    @Test
    fun `non-JSON metadata is malformed`() = runBlocking {
        routeAll()
        routes[badRecordRoute] = MockResponse().setBody("not json")
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `an empty listing is absent`() = runBlocking {
        routes["/"] = MockResponse().setBody(
            """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>0</KeyCount></ListBucketResult>"""
        )
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PMC10358571"))
    }

    @Test
    fun `a listing without the S3 namespace is malformed`() = runBlocking {
        routes["/"] = MockResponse().setBody(
            """<ListBucketResult><KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents></ListBucketResult>"""
        )
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    @Test
    fun `a listing that is not valid UTF-8 is malformed`() = runBlocking {
        routes["/"] = MockResponse().setBody(Buffer().write(byteArrayOf(0xFF.toByte(), 0xFE.toByte())))
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571")
        )
    }

    private fun statusRows() = run {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/pmc_open_data.json")
            if (file.isFile) {
                return@run Json.parseToJsonElement(file.readText())
                    .jsonObject.getValue("status").jsonArray.map { it.jsonObject }
            }
            candidate = candidate.parentFile
        }
        error("pmc_open_data.json not found above ${File("").absolutePath}")
    }

    @Test
    fun `every status row of the fixture gets its outcome`() = runBlocking {
        val rows = statusRows()
        assertTrue(rows.isNotEmpty())
        for (row in rows) {
            val step = row.getValue("step").jsonPrimitive.content
            val status = row.getValue("status").jsonPrimitive.int
            val outcome = row.getValue("outcome").jsonPrimitive.content
            routes.clear()
            routeAll()
            val answer = MockResponse().setResponseCode(status)
            if (status == 200) {
                // A read row answers normally: the step's own body stays.
            } else {
                when (step) {
                    "listing" -> routes["/"] = answer
                    "metadata" -> routes[badRecordRoute] = answer
                    "xml" -> routes[articlePath] = answer
                    else -> error("unknown step $step")
                }
            }
            val fetch = service(maxRetries = 0).fetchXml("PMC10358571")
            val label = "$step $status"
            when (outcome) {
                "absent" -> assertEquals(label, PmcOpenDataFetch.Absent, fetch)
                "unreachable" -> assertEquals(
                    label, PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(status)), fetch
                )
                "read" -> assertTrue("$label: $fetch", fetch is PmcOpenDataFetch.Served)
                else -> error("unknown outcome $outcome")
            }
        }
    }

    private companion object {
        /** A read timeout well beyond any test's wait, as the shared LLM client has. */
        const val SHARED_READ_TIMEOUT_SECONDS = 120L

        /** The pacer interval for the pacing test. */
        const val PACER_INTERVAL_MS = 150L

        /** A read timeout the slow answer outlasts. */
        const val SHORT_TIMEOUT_MS = 100L

        /** How long the slow answer holds its headers back. */
        const val SLOW_ANSWER_MS = 1_000L

        /** A backoff no test waits out. */
        const val LONG_BACKOFF_MS = 10_000L

        /** How long to wait for the first request to reach the server. */
        const val REQUEST_WAIT_SECONDS = 5L
    }
}
