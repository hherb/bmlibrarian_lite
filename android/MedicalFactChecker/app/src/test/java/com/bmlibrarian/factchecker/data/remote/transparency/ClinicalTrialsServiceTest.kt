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
import java.time.Instant
import java.time.ZoneId
import kotlinx.coroutines.runBlocking
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonObject
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.QueueDispatcher
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/** Port of the Swift `ClinicalTrialsServiceTests`, plus the request itself over MockWebServer. */
class ClinicalTrialsServiceTest {

    private lateinit var server: MockWebServer
    private lateinit var service: ClinicalTrialsService

    @Before
    fun setUp() {
        server = MockWebServer().apply {
            (dispatcher as QueueDispatcher).setFailFast(true)
            start()
        }
        service = ClinicalTrialsService(
            httpClient = OkHttpClient(),
            baseUrl = server.url("/api/v2").toString(),
            retryPolicy = TransparencyRetryPolicy(initialDelayMs = 0, maxDelayMs = 0),
            minimumRequestIntervalMs = 0,
        )
        Log.clear()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun obj(json: String): JsonObject = Json.parseToJsonElement(json).jsonObject

    private fun localDate(instant: Instant) = instant.atZone(ZoneId.systemDefault()).toLocalDate()

    // ==================== getStudy over the wire ====================

    @Test
    fun `getStudy normalizes the id`() = runBlocking {
        server.enqueue(MockResponse().setBody(TransparencyTestFixtures.INDUSTRY_TRIAL_STUDY))
        val study = service.getStudy("  01234567 ")
        assertEquals("NCT01234567", service.extractTrialInfo(study)?.registrationId)
        assertEquals("/api/v2/studies/NCT01234567", server.takeRequest().path)
    }

    @Test
    fun `lowercase id is upper-cased`() = runBlocking {
        server.enqueue(MockResponse().setBody("{}"))
        service.getStudy("nct01234567")
        assertEquals("/api/v2/studies/NCT01234567", server.takeRequest().path)
    }

    @Test
    fun `an id that cannot form a URL is invalid`() = runBlocking {
        try {
            service.getStudy("NCT 0123")
            fail("expected an invalid NCT id")
        } catch (e: ClinicalTrialsException.InvalidNctId) {
            assertEquals("Invalid NCT ID: NCT 0123", e.message)
        }
        assertEquals(0, server.requestCount)
    }

    @Test
    fun `404 answers null`() = runBlocking {
        server.enqueue(MockResponse().setResponseCode(404))
        assertNull(service.getStudy("NCT00000000"))
    }

    @Test
    fun `a persistent server error throws after three attempts`() = runBlocking {
        repeat(3) { server.enqueue(MockResponse().setResponseCode(502)) }
        try {
            service.getStudy("NCT00000000")
            fail("expected a server error")
        } catch (e: ClinicalTrialsException.ServerError) {
            assertEquals("ClinicalTrials.gov server error (HTTP 502). Try again later.", e.message)
        }
        assertEquals(3, server.requestCount)
    }

    @Test
    fun `an answer that is not a JSON object is a parse error`() = runBlocking {
        server.enqueue(MockResponse().setBody("[1, 2]"))
        try {
            service.getStudy("NCT00000000")
            fail("expected a parse error")
        } catch (e: ClinicalTrialsException.ParseError) {
            assertEquals("Failed to parse response: Invalid JSON", e.message)
        }
    }

    /**
     * Swift's dictionary semantics, kept on purpose and pinned: a 404 is present
     * with a null value, a failed fetch is absent. A caller that reads a missing
     * key as "no such trial" turns an outage into an absence.
     */
    @Test
    fun `getStudies distinguishes absent from unreachable`() = runBlocking {
        server.enqueue(MockResponse().setBody(TransparencyTestFixtures.INDUSTRY_TRIAL_STUDY))
        server.enqueue(MockResponse().setResponseCode(404))
        server.enqueue(MockResponse().setResponseCode(400))
        val studies = service.getStudies(listOf("NCT01234567", "NCT11111111", "NCT22222222"))
        assertEquals(listOf("NCT01234567", "NCT11111111"), studies.keys.toList())
        assertTrue(studies.containsKey("NCT11111111"))
        assertNull(studies["NCT11111111"])
        assertFalse(studies.containsKey("NCT22222222"))
        assertTrue(Log.lines.any { it.contains("Failed to fetch study NCT22222222: HTTP error: 400") })
    }

    // ==================== trial info ====================

    @Test
    fun `industry trial`() {
        val registration = service.extractTrialInfo(TransparencyTestFixtures.industryTrialStudyJson)!!
        assertEquals("NCT01234567", registration.registrationId)
        assertEquals(TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME, registration.registry)
        assertEquals("A Phase III Study of Drug X vs Placebo", registration.title)
        assertEquals("INDUSTRY", registration.sponsorClass)
        assertEquals("Pfizer Inc.", registration.leadSponsor)
        assertTrue(registration.resultsPosted)
    }

    @Test
    fun `NIH trial`() {
        val registration = service.extractTrialInfo(TransparencyTestFixtures.nihTrialStudyJson)!!
        assertEquals("NCT87654321", registration.registrationId)
        assertEquals("NIH", registration.sponsorClass)
        assertEquals("National Heart, Lung, and Blood Institute", registration.leadSponsor)
        assertFalse(registration.resultsPosted)
    }

    @Test
    fun `trial without results`() {
        val registration = service.extractTrialInfo(TransparencyTestFixtures.trialWithoutResultsJson)!!
        assertEquals("NCT99999999", registration.registrationId)
        assertFalse(registration.resultsPosted)
    }

    @Test fun `invalid study`() = assertNull(service.extractTrialInfo(obj("""{"invalid": "data"}""")))

    @Test fun `null study`() = assertNull(service.extractTrialInfo(null))

    /** `hasResults` must be a JSON boolean, as Swift's `as? Bool` requires. */
    @Test
    fun `a string hasResults is not a boolean`() {
        val study = obj("""{"protocolSection": {"identificationModule": {"nctId": "NCT1"}}, "hasResults": "true"}""")
        assertFalse(service.extractTrialInfo(study)!!.resultsPosted)
    }

    @Test
    fun `primary outcomes`() {
        val outcomes = service.extractTrialInfo(TransparencyTestFixtures.industryTrialStudyJson)!!.primaryOutcomesRegistered
        assertEquals(listOf("Change in blood pressure from baseline", "Time to first cardiovascular event"), outcomes)
    }

    @Test
    fun `secondary outcomes`() {
        assertEquals(
            listOf("Quality of life score"),
            service.extractTrialInfo(TransparencyTestFixtures.industryTrialStudyJson)!!.secondaryOutcomesRegistered,
        )
    }

    @Test
    fun `no outcomes`() {
        val registration = service.extractTrialInfo(
            obj("""{"protocolSection": {"identificationModule": {"nctId": "NCT00000000"}}, "hasResults": false}"""),
        )!!
        assertTrue(registration.primaryOutcomesRegistered.isEmpty())
        assertTrue(registration.secondaryOutcomesRegistered.isEmpty())
    }

    // ==================== completion date ====================

    private fun studyWithDate(date: String) = obj(
        """{"protocolSection": {"identificationModule": {"nctId": "NCT1"},
            "statusModule": {"completionDateStruct": {"date": "$date"}}}, "hasResults": false}""",
    )

    @Test
    fun `full completion date`() {
        val date = localDate(service.extractTrialInfo(TransparencyTestFixtures.industryTrialStudyJson)!!.completionDate!!)
        assertEquals(2023, date.year)
        assertEquals(6, date.monthValue)
        assertEquals(30, date.dayOfMonth)
    }

    @Test
    fun `month-year completion date`() {
        val date = localDate(service.extractTrialInfo(studyWithDate("2024-03"))!!.completionDate!!)
        assertEquals(2024, date.year)
        assertEquals(3, date.monthValue)
    }

    @Test
    fun `year-only completion date`() =
        assertEquals(2024, localDate(service.extractTrialInfo(studyWithDate("2024"))!!.completionDate!!).year)

    @Test fun `unparseable completion date`() = assertNull(service.extractTrialInfo(studyWithDate("soon"))!!.completionDate)

    @Test
    fun `missing completion date`() = assertNull(
        service.extractTrialInfo(obj("""{"protocolSection": {"identificationModule": {"nctId": "NCT3"}}}"""))!!.completionDate,
    )

    // ==================== multiple ====================

    @Test
    fun `extract several`() {
        val registrations = service.extractTrialInfos(
            linkedMapOf(
                "NCT01234567" to TransparencyTestFixtures.industryTrialStudyJson,
                "NCT87654321" to TransparencyTestFixtures.nihTrialStudyJson,
                "NCT00000000" to null,
            ),
        )
        assertEquals(2, registrations.size)
    }

    @Test fun `extract none`() = assertTrue(service.extractTrialInfos(emptyMap()).isEmpty())

    // ==================== errors ====================

    @Test
    fun `error messages`() {
        assertEquals("Invalid NCT ID: test", ClinicalTrialsException.InvalidNctId("test").message)
        assertEquals("Network error: test", ClinicalTrialsException.NetworkError("test").message)
        assertEquals("HTTP error: 400", ClinicalTrialsException.HttpError(400).message)
        assertEquals(
            "ClinicalTrials.gov server error (HTTP 500). Try again later.",
            ClinicalTrialsException.ServerError(500).message,
        )
        assertEquals("Failed to parse response: test", ClinicalTrialsException.ParseError("test").message)
    }

    @Test
    fun `retryable errors`() {
        assertFalse(ClinicalTrialsException.InvalidNctId("test").isRetryable)
        assertTrue(ClinicalTrialsException.NetworkError("test").isRetryable)
        assertFalse(ClinicalTrialsException.HttpError(400).isRetryable)
        assertTrue(ClinicalTrialsException.ServerError(500).isRetryable)
        assertFalse(ClinicalTrialsException.ParseError("test").isRetryable)
    }

    // ==================== titles ====================

    @Test
    fun `brief title fallback`() {
        val study = obj(
            """{"protocolSection": {"identificationModule": {"nctId": "NCT4", "briefTitle": "Brief Title Only"}}}""",
        )
        assertEquals("Brief Title Only", service.extractTrialInfo(study)!!.title)
    }

    @Test
    fun `official title preferred`() {
        val title = service.extractTrialInfo(TransparencyTestFixtures.industryTrialStudyJson)!!.title
        assertEquals("A Phase III Study of Drug X vs Placebo", title)
        assertNotEquals("Drug X Study", title)
    }
}
