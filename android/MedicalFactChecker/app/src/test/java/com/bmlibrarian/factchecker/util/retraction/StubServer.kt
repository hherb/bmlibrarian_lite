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

import java.net.URLDecoder
import java.util.concurrent.CopyOnWriteArrayList
import okhttp3.Interceptor
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest

/**
 * A MockWebServer every request is sent to, whatever host bmlib's URL names
 * (Swift's `StubURLProtocol`): answers by route, then by sequence, then the default.
 */
class StubServer : AutoCloseable {
    private val server = MockWebServer()

    /** Each request's original URL, decoded, in order. */
    val requestedUrls = CopyOnWriteArrayList<String>()

    /** Each request as the server saw it, in order. */
    val requests = CopyOnWriteArrayList<RecordedRequest>()

    /** Answers for a URL containing the key, before anything else. */
    var routes: Map<String, MockResponse> = emptyMap()

    /** Answers used once each, in order, before [stubbed]. */
    val sequence = ArrayDeque<MockResponse>()

    /** The answer when no route or sequence entry applies. */
    var stubbed: MockResponse = MockResponse().setResponseCode(200)

    init {
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse {
                requests += request
                val original = URLDecoder.decode(request.getHeader(ORIGINAL_URL) ?: "", "UTF-8")
                requestedUrls += original
                routes.entries.firstOrNull { original.contains(it.key) }?.let { return it.value }
                return synchronized(sequence) { sequence.removeFirstOrNull() } ?: stubbed
            }
        }
        server.start()
    }

    /** A client whose every request goes to this server, the original URL in a header. */
    fun client(): OkHttpClient = OkHttpClient.Builder().addInterceptor(Interceptor { chain ->
        val original = chain.request()
        val target = server.url(original.url.encodedPath).newBuilder().encodedQuery(original.url.encodedQuery).build()
        chain.proceed(original.newBuilder().url(target).header(ORIGINAL_URL, original.url.toString()).build())
    }).build()

    override fun close() = server.shutdown()

    companion object {
        private const val ORIGINAL_URL = "X-Original-Url"

        fun answer(status: Int, body: String = ""): MockResponse = MockResponse().setResponseCode(status).setBody(body)

        fun answer(status: Int, body: ByteArray): MockResponse =
            MockResponse().setResponseCode(status).setBody(okio.Buffer().write(body))

        /** Crossref's works list holding [items]. */
        fun crossrefBody(items: String): String =
            """{"status":"ok","message-type":"work-list","message":{"items":[$items]}}"""
    }
}
