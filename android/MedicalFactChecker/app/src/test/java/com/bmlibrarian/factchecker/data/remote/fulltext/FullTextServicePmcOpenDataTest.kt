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
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextUrlEntry
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextUrlList
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResult
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextXmlFetch
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * PMC's open-data bucket in the full-text chain (#480): asked by PMC ID after
 * Europe PMC's XML gave no text and before its PDF render, and named in the
 * not-established sentence only when Europe PMC left nothing unsettled. Mirrors
 * Python's step 2a and BioMedLit's tier after the Europe PMC XML block.
 */
class FullTextServicePmcOpenDataTest {

    private val europePmc: EuropePMCService = mockk()
    private val bucket: PmcOpenDataService = mockk()

    private val jats = """
        <?xml version="1.0" encoding="UTF-8"?>
        <article>
          <front><article-meta>
            <title-group><article-title>A trial</article-title></title-group>
          </article-meta></front>
          <body><sec><title>Methods</title><p>We randomised 40 patients.</p></sec></body>
        </article>
    """.trimIndent()

    /** XML the JATS parser refuses: a mismatched end tag (an unclosed one is read to the end and parses). */
    private val unparseable = "<article><body></article>"

    private fun service() = FullTextService(
        context = mockk(relaxed = true),
        europePmcService = europePmc,
        unpaywallApi = mockk<UnpaywallApi>(),
        httpClient = mockk(relaxed = true),
        pmcOpenData = bucket,
        openAlex = absentOpenAlex()
    )

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

    // ==================== When the bucket is asked ====================

    @Test
    fun `Europe PMC absent, then the bucket serves`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Served(jats)

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextResult.PmcOpenDataXml)
        result as FullTextResult.PmcOpenDataXml
        assertEquals(jats, result.xml)
        assertTrue(result.markdown, result.markdown.contains("We randomised 40 patients."))
        assertTrue(result.html, result.html.contains("We randomised 40 patients."))
        assertTrue(result.hasContent)
    }

    @Test
    fun `Europe PMC served, so the bucket is not asked`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(jats)

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextResult.EuropePmcXml)
        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }

    @Test
    fun `an unreachable Europe PMC still asks the bucket`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns
            FullTextXmlFetch.Unreachable(RequestFailure.forHttpStatus(503))
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Served(jats)

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextResult.PmcOpenDataXml)
    }

    @Test
    fun `the bucket is asked by the normalised PMC ID`() = runTest {
        coEvery { europePmc.fetchFullTextXml(any()) } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Served(jats)

        val result = service().fetchFullText(pmcId = " pmc1 ", doi = null, pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextResult.PmcOpenDataXml)
    }

    @Test
    fun `a PMC ID the identifier search resolved is asked too`() = runTest {
        searchAnswers(EuropePMCArticle(id = "123", source = "MED", pmcid = "PMC7", title = "t"))
        coEvery { europePmc.fetchFullTextXml("PMC7") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC7") } returns PmcOpenDataFetch.Served(jats)

        val result = service().fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

        assertTrue("$result", result is FullTextResult.PmcOpenDataXml)
    }

    /** Python and Swift ask the bucket before Europe PMC's PDF render, which answers 403 to every client (#453). */
    @Test
    fun `the bucket comes before Europe PMC's PDF render`() = runTest {
        searchAnswers(
            EuropePMCArticle(
                id = "123", source = "MED", pmcid = "PMC7", title = "t",
                fullTextUrlList = FullTextUrlList(
                    listOf(FullTextUrlEntry(availability = "Free", documentStyle = "pdf", url = "https://europepmc.org/a.pdf"))
                )
            )
        )
        coEvery { europePmc.fetchFullTextXml("PMC7") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC7") } returns PmcOpenDataFetch.Served(jats)

        val result = service().fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

        assertTrue("$result", result is FullTextResult.PmcOpenDataXml)
    }

    @Test
    fun `a bucket that serves nothing leaves Europe PMC's PDF render its turn`() = runTest {
        searchAnswers(
            EuropePMCArticle(
                id = "123", source = "MED", pmcid = "PMC7", title = "t",
                fullTextUrlList = FullTextUrlList(
                    listOf(FullTextUrlEntry(availability = "Free", documentStyle = "pdf", url = "https://europepmc.org/a.pdf"))
                )
            )
        )
        coEvery { europePmc.fetchFullTextXml("PMC7") } returns FullTextXmlFetch.Absent
        for (fetch in listOf(
            PmcOpenDataFetch.Absent,
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503)),
            PmcOpenDataFetch.Served(unparseable)
        )) {
            coEvery { bucket.fetchXml("PMC7") } returns fetch

            val result = service().fetchFullText(pmcId = null, doi = null, pmid = "123").getOrThrow()

            assertEquals("$fetch", FullTextResult.EuropePmcPdf("https://europepmc.org/a.pdf"), result)
        }
    }

    @Test
    fun `a preprint passed as the PMC ID never asks the bucket`() = runTest {
        coEvery { europePmc.fetchFullTextXml(any()) } returns FullTextXmlFetch.Absent

        service().fetchFullText(pmcId = "PPR1316954", doi = null, pmid = null)

        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }

    @Test
    fun `a preprint found by its DOI never asks the bucket`() = runTest {
        searchAnswers(EuropePMCArticle(id = "PPR1316954", source = "PPR", doi = "10.1101/example", title = "p"))
        coEvery { europePmc.fetchFullTextXml("PPR1316954") } returns FullTextXmlFetch.Absent

        service().fetchFullText(pmcId = null, doi = "10.1101/example", pmid = null)

        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }

    @Test
    fun `no PMC ID never asks the bucket`() = runTest {
        searchAnswers()

        service().fetchFullText(pmcId = null, doi = null, pmid = "123")

        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }

    // ==================== What a chain that found nothing says ====================

    @Test
    fun `Europe PMC's shortfall comes first`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503))

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertEquals(
            FullTextResult.NotEstablished(
                RequestFailure.forHttpStatus(Constants.HTTP_NOT_FOUND), NotEstablishedSource.EUROPE_PMC
            ),
            result
        )
    }

    @Test
    fun `the bucket's shortfall when Europe PMC had none`() = runTest {
        // Europe PMC served XML that would not parse: no shortfall of its own.
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(unparseable)
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503))

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        val expected = FullTextResult.NotEstablished(
            RequestFailure.forHttpStatus(503), NotEstablishedSource.PMC_OPEN_DATA
        )
        assertEquals(expected, result)
        assertEquals(notEstablishedMessage(Constants.PMC_OPEN_DATA_SERVICE_NAME, expected.failure), expected.reason)
    }

    /** Python and Swift record a served bucket XML that will not convert as a malformed answer. */
    @Test
    fun `a bucket XML that will not parse is a malformed answer, not an absence`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(unparseable)
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Served(unparseable)

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertEquals(
            FullTextResult.NotEstablished(
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE), NotEstablishedSource.PMC_OPEN_DATA
            ),
            result
        )
    }

    @Test
    fun `control - a bucket absence leaves the chain unavailable`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(unparseable)
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Absent

        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()

        assertTrue("$result", result is FullTextResult.Unavailable)
    }

    @Test
    fun `a DOI still ends on its link when the bucket could not be read`() = runTest {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(unparseable)
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503))

        val result = service().fetchFullText(pmcId = "PMC1", doi = "10.1234/x", pmid = null).getOrThrow()

        assertEquals(
            FullTextResult.DoiUrl("https://doi.org/10.1234/x", OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED),
            result
        )
    }

    // ==================== The result ====================

    @Test
    fun `the bucket's text is stored under its own source`() {
        val result = FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>")

        assertEquals(Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA, service().getSourceConstant(result))
    }

    @Test
    fun `each not-established source names itself in the reader's sentence`() {
        val failure = RequestFailure(RequestFailureKind.TIMEOUT)

        assertEquals(Constants.EUROPE_PMC_SERVICE_NAME, NotEstablishedSource.EUROPE_PMC.serviceName)
        assertEquals(Constants.PMC_OPEN_DATA_SERVICE_NAME, NotEstablishedSource.PMC_OPEN_DATA.serviceName)
        assertEquals(
            absenceNotEstablishedMessage(failure),
            FullTextResult.NotEstablished(failure, NotEstablishedSource.EUROPE_PMC).reason
        )
        assertEquals(
            notEstablishedMessage(Constants.PMC_OPEN_DATA_SERVICE_NAME, failure),
            FullTextResult.NotEstablished(failure, NotEstablishedSource.PMC_OPEN_DATA).reason
        )
        assertEquals(notEstablishedMessage("Europe PMC", failure), absenceNotEstablishedMessage(failure))
    }
}
