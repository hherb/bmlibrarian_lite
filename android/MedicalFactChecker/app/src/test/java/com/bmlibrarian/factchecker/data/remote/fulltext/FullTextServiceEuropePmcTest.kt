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

import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResult
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextAccession
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextXmlFetch
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SourceRequestException
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The full-text chain around Europe PMC's XML fetch (#434): the preprint route,
 * and what a chain that found nothing may say about the article.
 */
class FullTextServiceEuropePmcTest {

    private lateinit var europePmc: EuropePMCService
    private lateinit var service: FullTextService

    @Before
    fun setup() {
        europePmc = mockk()
        service = FullTextService(
            context = mockk(relaxed = true),
            europePmcService = europePmc,
            unpaywallApi = mockk<UnpaywallApi>(),
            httpClient = mockk(relaxed = true)
        )
    }

    private val article = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <title-group><article-title>A preprint in full</article-title></title-group>
          </article-meta></front>
          <body><sec><title>Methods</title><p>Real prose.</p></sec></body>
        </article>
    """.trimIndent()

    /** Europe PMC's search answers with these records. */
    private fun searchAnswers(vararg records: EuropePMCArticle) {
        coEvery { europePmc.search(any(), any(), any(), any(), any()) } returns Result.success(
            EuropePMCSearchResult(
                articles = records.toList(),
                totalResults = records.size,
                nextCursor = null,
                resultsReceived = records.size,
                shortfalls = emptyList()
            )
        )
    }

    private val preprintRecord = EuropePMCArticle(
        id = "PPR1316954", source = "PPR", doi = "10.1101/example", title = "A preprint"
    )

    // ==================== The preprint route ====================

    @Test
    fun `a preprint found by its DOI is fetched by its record ID`() = runTest {
        searchAnswers(preprintRecord)
        coEvery { europePmc.fetchFullTextXml("PPR1316954") } returns FullTextXmlFetch.Served(article)

        val result = service.fetchFullText(pmcId = null, doi = "10.1101/example", pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextService.FullTextResult.EuropePmcXml)
        // The default search filters preprints out, so the DOI would match nothing
        coVerify { europePmc.search(any(), any(), any(), includePreprints = true, any()) }
    }

    @Test
    fun `a preprint record whose ID is not a PPR accession is not fetched`() = runTest {
        searchAnswers(preprintRecord.copy(id = "12345"))

        service.fetchFullText(pmcId = null, doi = "10.1101/example", pmid = null)

        coVerify(exactly = 0) { europePmc.fetchFullTextXml(any()) }
    }

    // ==================== What a chain that found nothing may say ====================

    @Test
    fun `a 404 does not establish that the article has no full text`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Absent

        val result = service.fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertEquals(
            FullTextService.FullTextResult.NotEstablished(RequestFailure(RequestFailureKind.HTTP_STATUS, 404)),
            result
        )
    }

    @Test
    fun `an unreachable Europe PMC does not establish it`() = runTest {
        val throttled = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Unreachable(throttled)

        val result = service.fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertEquals(FullTextService.FullTextResult.NotEstablished(throttled), result)
    }

    @Test
    fun `a failed identifier search does not establish it`() = runTest {
        val outage = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
        coEvery { europePmc.search(any(), any(), any(), any(), any()) } returns
            Result.failure(SourceRequestException(SearchProvider.EUROPE_PMC, outage))

        val result = service.fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

        assertEquals(FullTextService.FullTextResult.NotEstablished(outage), result)
    }

    /** The control: without it the three above pass against a chain that never says Unavailable. */
    @Test
    fun `a search that answered with no record still says unavailable`() = runTest {
        searchAnswers()

        val result = service.fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

        assertTrue("$result", result is FullTextService.FullTextResult.Unavailable)
    }

    @Test
    fun `a record with no PMC ID that is not a preprint still says unavailable`() = runTest {
        searchAnswers(EuropePMCArticle(id = "123", source = "MED", pmid = "123", title = "An article"))

        val result = service.fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

        assertTrue("$result", result is FullTextService.FullTextResult.Unavailable)
        coVerify(exactly = 0) { europePmc.fetchFullTextXml(any()) }
    }

    // ==================== The resolution fold ====================

    @Test
    fun `a matched record settles the question however an earlier search went`() {
        val failed = FullTextService.PmcResolution(failure = RequestFailure(RequestFailureKind.TIMEOUT))
        val matched = FullTextService.PmcResolution(matchedARecord = true)

        assertTrue(failed.lostTheSource)
        assertFalse(failed.merging(matched).lostTheSource)
        assertFalse(matched.merging(failed).lostTheSource)
    }

    @Test
    fun `a failure survives a later search that matched nothing`() {
        val failed = FullTextService.PmcResolution(failure = RequestFailure(RequestFailureKind.TIMEOUT))

        assertTrue(failed.merging(FullTextService.PmcResolution()).lostTheSource)
        assertTrue(FullTextService.PmcResolution().merging(failed).lostTheSource)
    }

    @Test
    fun `a preprint record gives its PPR ID whatever the case of its source`() {
        val resolution = FullTextService.PmcResolution.fromArticle(preprintRecord.copy(source = "ppr"))

        assertEquals("PPR1316954", resolution.preprintAccession)
        assertNull(resolution.pmcId)
        assertTrue(resolution.matchedARecord)
        assertNull(FullTextService.PmcResolution.fromArticle(preprintRecord.copy(source = "MED")).preprintAccession)
    }

    // ==================== The reader's sentence ====================

    /** The verb follows #435's decision, worded as the iOS app words it. */
    @Test
    fun `the sentence names what Europe PMC did`() {
        val answered = absenceNotEstablishedMessage(RequestFailure(RequestFailureKind.HTTP_STATUS, 404))
        assertTrue(answered, answered.contains("Europe PMC (HTTP 404 Not Found) did not serve it"))
        assertFalse(answered, answered.contains("could not be asked"))

        val unasked = absenceNotEstablishedMessage(RequestFailure(RequestFailureKind.TIMEOUT))
        assertTrue(unasked, unasked.contains("Europe PMC could not be asked (the request timed out)"))
    }
}

/** The accession rules `fullTextXML` is asked by (#434), mirroring Python's `fulltext_accession`. */
class FullTextAccessionTest {
    @Test
    fun `a PMC ID is normalised whatever its prefix case`() {
        for (identifier in listOf("PMC123", "pmc123", "Pmc123", "123", "  PMC123\n")) {
            assertEquals(identifier, "PMC123", FullTextAccession.normalized(identifier))
        }
    }

    @Test
    fun `a preprint record ID is kept`() {
        for (identifier in listOf("PPR1316954", "ppr1316954", " PPR1316954 ")) {
            assertEquals(identifier, "PPR1316954", FullTextAccession.normalized(identifier))
        }
    }

    @Test
    fun `anything else is refused`() {
        for (identifier in listOf(
            "", "   ", "PMC", "PPR", "PMCabc", "12a", "PMC12 3", "../PMC1", "PMC-1",
            "PMC١٢٣", "١٢٣", "10.1234/example", "MED123", "PMCPPR1", "PPRPMC1"
        )) {
            assertNull(identifier, FullTextAccession.normalized(identifier))
        }
    }

    @Test
    fun `prefixed demands the prefix`() {
        assertNull(FullTextAccession.prefixed("123", "PPR"))
        assertNull(FullTextAccession.prefixed("123", "PMC"))
        assertNull(FullTextAccession.prefixed("PMC123", "PPR"))
        assertEquals("PPR7", FullTextAccession.prefixed(" ppr7 ", "PPR"))
        assertEquals("PMC7", FullTextAccession.prefixed("pmc7", "PMC"))
    }
}
