/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.data.remote.transparency

import android.util.Log
import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import com.bmlibrarian.factchecker.domain.transparency.TransparencyTestFixtures
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import okhttp3.mockwebserver.SocketPolicy
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** Port of the Swift `CrossRefServiceTests`, plus the request itself over MockWebServer. */
class CrossRefServiceTest {

    private lateinit var server: MockWebServer
    private lateinit var service: CrossRefService

    @Before
    fun setUp() {
        server = MockWebServer().apply {
            (dispatcher as QueueDispatcher).setFailFast(true)
            start()
        }
        service = CrossRefService(
            email = "test@example.com",
            httpClient = OkHttpClient(),
            baseUrl = server.url("/api").toString(),
            retryPolicy = TransparencyRetryPolicy(initialDelayMs = 0, maxDelayMs = 0),
            minimumRequestIntervalMs = 0,
        )
        Log.clear()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private fun localDate(instant: java.time.Instant) = instant.atZone(ZoneId.systemDefault()).toLocalDate()

    // ==================== getWork over the wire ====================

    @Test
    fun `getWork returns the message object and sends the polite User-Agent`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"status": "ok", "message": {"title": ["T"]}}"""))
        val work = service.getWork("10.1000/xyz123")
        assertEquals("T", service.extractTitle(work))
        val request = server.takeRequest()
        assertEquals("/api/works/10.1000/xyz123", request.path)
        assertEquals("StudyTransparencyAnalyzer/1.0 (mailto:test@example.com)", request.getHeader("User-Agent"))
    }

    @Test
    fun `a doi-org URL is stripped and unsafe characters are percent-encoded`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"message": {}}"""))
        service.getWork("https://doi.org/10.1002/(SICI)1097-0258<12:3>#x?y")
        assertEquals("/api/works/10.1002/(SICI)1097-0258%3C12:3%3E%23x%3Fy", server.takeRequest().path)
    }

    /** 404 means the work is absent — the one failure that answers null. */
    @Test
    fun `404 answers null`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(service.getWork("10.1000/missing"))
    }

    @Test
    fun `a server error is retried, then succeeds`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(503))
        server.enqueue(MockResponse().setResponseCode(429))
        server.enqueue(MockResponse().setBody("""{"message": {"title": ["Recovered"]}}"""))
        assertEquals("Recovered", service.extractTitle(service.getWork("10.1000/x")))
        assertEquals(3, server.requestCount)
    }

    @Test
    fun `a persistent server error throws after three attempts`() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(500)) }
        try {
            service.getWork("10.1000/x")
            fail("expected a server error")
        } catch (e: CrossRefException.ServerError) {
            assertEquals(500, e.statusCode)
            assertEquals("CrossRef server error (HTTP 500). Try again later.", e.message)
        }
        assertEquals(3, server.requestCount)
    }

    /** Unreachable is not absent: a non-retryable failure throws rather than reading as a 404. */
    @Test
    fun `a client error throws without retrying`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(400))
        try {
            service.getWork("10.1000/x")
            fail("expected an HTTP error")
        } catch (e: CrossRefException.HttpError) {
            assertEquals(400, e.statusCode)
        }
        assertEquals(1, server.requestCount)
    }

    @Test
    fun `a dropped connection is a retried network error`() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setSocketPolicy(SocketPolicy.DISCONNECT_AT_START)) }
        try {
            service.getWork("10.1000/x")
            fail("expected a network error")
        } catch (e: CrossRefException.NetworkError) {
            assertTrue(e.isRetryable)
        }
        assertEquals(3, server.requestCount)
    }

    @Test
    fun `an answer without a message object is a parse error`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"status": "ok"}"""))
        try {
            service.getWork("10.1000/x")
            fail("expected a parse error")
        } catch (e: CrossRefException.ParseError) {
            assertEquals("Failed to parse response: Invalid JSON structure", e.message)
        }
    }

    @Test
    fun `an answer that is not JSON is a parse error`() = runBlocking {
        server.enqueue(MockResponse().setBody("<html>busy</html>"))
        try {
            service.getWork("10.1000/x")
            fail("expected a parse error")
        } catch (e: CrossRefException.ParseError) {
            assertFalse(e.isRetryable)
        }
    }

    /** No answer body reaches the log. */
    @Test
    fun `the answer body is not logged`() = runBlocking {
        server.enqueue(MockResponse().setBody("""{"message": {"title": ["SECRET-BODY-TEXT"]}}"""))
        service.getWork("10.1000/x")
        assertFalse(Log.lines.toString(), Log.lines.any { it.contains("SECRET-BODY-TEXT") })
    }

    // ==================== funders ====================

    @Test
    fun `industry funder`() {
        val funder = service.extractFunders(TransparencyTestFixtures.industryFundedWorkJson).single()
        assertEquals("Pfizer Inc.", funder.name)
        assertEquals("10.13039/100004319", funder.funderDOI)
        assertTrue(funder.isIndustry)
        assertEquals(1.0, funder.confidence, 0.0)
        assertEquals(listOf("GRANT-2024-001"), funder.awardNumbers)
    }

    @Test
    fun `academic funder`() {
        val funder = service.extractFunders(TransparencyTestFixtures.academicFundedWorkJson).single()
        assertEquals("National Institutes of Health", funder.name)
        assertFalse(funder.isIndustry)
    }

    @Test
    fun `mixed funders`() {
        val funders = service.extractFunders(TransparencyTestFixtures.mixedFundedWorkJson)
        assertEquals(2, funders.size)
        assertEquals("Novartis AG", funders.single { it.isIndustry }.name)
        assertEquals("National Science Foundation", funders.single { !it.isIndustry }.name)
    }

    @Test fun `no funders`() = assertTrue(service.extractFunders(TransparencyTestFixtures.workNoFundersJson).isEmpty())

    @Test fun `null work has no funders`() = assertTrue(service.extractFunders(null).isEmpty())

    /** Swift's `as? [[String: Any]]` is all-or-nothing: one non-object entry discards the array. */
    @Test
    fun `a funder array with a non-object entry reads as none`() {
        assertTrue(service.extractFunders(obj("""{"funder": [{"name": "Pfizer Inc."}, "stray"]}""")).isEmpty())
    }

    // ==================== title, journal, authors ====================

    @Test fun `title`() = assertEquals(
        "A Randomized, Double-Blind, Placebo-Controlled Study",
        service.extractTitle(TransparencyTestFixtures.industryFundedWorkJson),
    )

    @Test fun `missing title`() = assertNull(service.extractTitle(obj("""{"author": []}""")))

    @Test fun `null title`() = assertNull(service.extractTitle(null))

    @Test fun `journal`() =
        assertEquals("New England Journal of Medicine", service.extractJournal(TransparencyTestFixtures.industryFundedWorkJson))

    @Test fun `missing journal`() = assertNull(service.extractJournal(obj("""{"title": ["Test"]}""")))

    @Test fun `null journal`() = assertNull(service.extractJournal(null))

    @Test fun `authors`() =
        assertEquals(listOf("Smith, John", "Doe, Jane"), service.extractAuthors(TransparencyTestFixtures.industryFundedWorkJson))

    @Test fun `family-only author`() = assertEquals(listOf("Smith"), service.extractAuthors(obj("""{"author": [{"family": "Smith"}]}""")))

    @Test fun `author without a family name is skipped`() =
        assertEquals(listOf("Doe"), service.extractAuthors(obj("""{"author": [{"name": "The Consortium"}, {"family": "Doe"}]}""")))

    @Test fun `no authors`() = assertTrue(service.extractAuthors(obj("""{"title": ["Test"]}""")).isEmpty())

    @Test fun `null authors`() = assertTrue(service.extractAuthors(null).isEmpty())

    // ==================== publication date ====================

    @Test
    fun `full publication date`() {
        val date = localDate(service.extractPublicationDate(TransparencyTestFixtures.industryFundedWorkJson)!!)
        assertEquals(2024, date.year)
        assertEquals(3, date.monthValue)
        assertEquals(15, date.dayOfMonth)
    }

    @Test
    fun `print is preferred over online`() {
        val work = obj("""{"published-print": {"date-parts": [[2024, 6, 1]]}, "published-online": {"date-parts": [[2024, 3, 1]]}}""")
        assertEquals(6, localDate(service.extractPublicationDate(work)!!).monthValue)
    }

    @Test
    fun `falls back to online`() {
        val date = localDate(service.extractPublicationDate(TransparencyTestFixtures.academicFundedWorkJson)!!)
        assertEquals(2024, date.year)
        assertEquals(1, date.monthValue)
    }

    @Test
    fun `falls back to issued`() {
        assertEquals(2019, localDate(service.extractPublicationDate(obj("""{"issued": {"date-parts": [[2019, 2]]}}"""))!!).year)
    }

    /** CrossRef writes `[[null]]` for an unknown date; Swift's `as? [[Int]]` skips to the next key. */
    @Test
    fun `null date parts are skipped`() {
        val work = obj("""{"published-print": {"date-parts": [[null]]}, "issued": {"date-parts": [[2020]]}}""")
        assertEquals(2020, localDate(service.extractPublicationDate(work)!!).year)
    }

    @Test fun `missing date`() = assertNull(service.extractPublicationDate(obj("""{"title": ["Test"]}""")))

    @Test fun `null date`() = assertNull(service.extractPublicationDate(null))

    @Test
    fun `year-only date defaults to the first of January`() {
        val date = localDate(service.extractPublicationDate(obj("""{"published-print": {"date-parts": [[2024]]}}"""))!!)
        assertEquals(2024, date.year)
        assertEquals(TransparencyConstants.DEFAULT_MONTH, date.monthValue)
        assertEquals(TransparencyConstants.DEFAULT_DAY, date.dayOfMonth)
    }

    // ==================== errors ====================

    @Test
    fun `error messages`() {
        assertEquals("Invalid DOI: test", CrossRefException.InvalidDoi("test").message)
        assertEquals("Network error: test", CrossRefException.NetworkError("test").message)
        assertEquals("HTTP error: 400", CrossRefException.HttpError(400).message)
        assertEquals("CrossRef server error (HTTP 500). Try again later.", CrossRefException.ServerError(500).message)
        assertEquals("Failed to parse response: test", CrossRefException.ParseError("test").message)
    }

    @Test
    fun `retryable errors`() {
        assertFalse(CrossRefException.InvalidDoi("test").isRetryable)
        assertTrue(CrossRefException.NetworkError("test").isRetryable)
        assertFalse(CrossRefException.HttpError(400).isRetryable)
        assertTrue(CrossRefException.ServerError(500).isRetryable)
        assertFalse(CrossRefException.ParseError("test").isRetryable)
    }
}
