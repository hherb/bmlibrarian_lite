package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import okio.Buffer
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

class PmcOpenDataServiceTest {
    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val listingHits = java.util.concurrent.atomic.AtomicInteger()
    private var flakyListing = false
    private val listing = """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents></ListBucketResult>"""
    private val article = "<article><body><p>The study.</p></body></article>"
    private val articlePath = "/PMC10358571.1/PMC10358571.1.xml"

    @Before
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                val path = request.requestUrl?.encodedPath ?: ""
                if (path == "/" && flakyListing && listingHits.getAndIncrement() == 0) {
                    return MockResponse().setResponseCode(503)
                }
                return routes[path] ?: MockResponse().setResponseCode(404)
            }
        }
        server.start()
    }

    @After
    fun tearDown() {
        server.shutdown()
    }

    private fun service(maxRetries: Int = 0) = PmcOpenDataService(
        OkHttpClient(),
        baseUrl = server.url("/").toString().trimEnd('/'),
        pacer = RequestPacer(0L),
        maxRetries = maxRetries
    )

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

    @Test
    fun `a listing 404 is absent`() = runBlocking {
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PMC10358571"))
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
        flakyListing = true
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
    fun `a 404 listing is asked once and is absent`() = runBlocking {
        assertEquals(PmcOpenDataFetch.Absent, service(maxRetries = 1).fetchXml("PMC10358571"))
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

    @Test
    fun `a 408 is not retried`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(408)
        // OkHttp itself replays a 408 unless told not to; this isolates the service's own policy.
        val client = OkHttpClient.Builder().retryOnConnectionFailure(false).build()
        val service = PmcOpenDataService(
            client, server.url("/").toString().trimEnd('/'), RequestPacer(0L), 1
        )
        assertEquals(
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(408)),
            service.fetchXml("PMC10358571")
        )
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
}
