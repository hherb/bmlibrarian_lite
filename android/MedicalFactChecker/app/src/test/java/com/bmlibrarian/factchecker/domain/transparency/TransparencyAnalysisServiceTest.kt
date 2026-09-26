package com.bmlibrarian.factchecker.domain.transparency

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.transparency.ClinicalTrialsService
import com.bmlibrarian.factchecker.data.remote.transparency.CrossRefService
import com.bmlibrarian.factchecker.data.remote.transparency.TransparencyRetryPolicy
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Before
import org.junit.Test

/**
 * The analysis flow end to end, with CrossRef and ClinicalTrials.gov served by
 * MockWebServer and PubMed by a fake [ArticleMetadataLookup].
 *
 * The Swift `TransparencyAnalysisServiceTests` only reach the live network; these
 * pin the flow itself, including — deliberately — every place a network failure
 * degrades the result without a trace in it, so a fix to that has to change a test.
 */
class TransparencyAnalysisServiceTest {

    private lateinit var server: MockWebServer

    /** Path -> response; anything unrouted answers 404. */
    private val routes = mutableMapOf<String, MockResponse>()

    private val doiWithFunders = "10.1000/funded"

    @Before
    fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.path]?.clone() ?: MockResponse().setResponseCode(NOT_FOUND)
        }
        server.start()
        Log.clear()
    }

    @After
    fun tearDown() = server.shutdown()

    private fun service(lookup: ArticleMetadataLookup = ArticleMetadataLookup { null }) = TransparencyAnalysisService(
        metadataLookup = lookup,
        crossRefService = CrossRefService(
            email = "test@example.com",
            httpClient = OkHttpClient(),
            baseUrl = server.url("/crossref").toString(),
            retryPolicy = noDelay,
            minimumRequestIntervalMs = 0,
        ),
        clinicalTrialsService = ClinicalTrialsService(
            httpClient = OkHttpClient(),
            baseUrl = server.url("/ctgov").toString(),
            retryPolicy = noDelay,
            minimumRequestIntervalMs = 0,
        ),
    )

    private fun crossRefWork(doi: String, work: String) {
        routes["/crossref/works/$doi"] = MockResponse().setBody("""{"status": "ok", "message": $work}""")
    }

    private fun crossRefFails(doi: String, status: Int = SERVER_ERROR) {
        routes["/crossref/works/$doi"] = MockResponse().setResponseCode(status)
    }

    private val pfizerWork = """
        {"title": ["CrossRef title"], "container-title": ["CrossRef Journal"],
         "author": [{"family": "Smith", "given": "John"}],
         "funder": [{"name": "Pfizer Inc.", "DOI": "10.13039/100004319"}],
         "published-print": {"date-parts": [[2024, 3, 15]]}}
    """

    private fun requestedPaths(): List<String> = List(server.requestCount) { server.takeRequest().path!! }

    // ==================== input validation ====================

    @Test
    fun `neither identifier throws`() = runBlocking {
        try {
            service().analyze(doi = null, pmid = null)
            fail("expected NoIdentifiers")
        } catch (e: TransparencyAnalysisException.NoIdentifiers) {
            assertEquals("Must provide either DOI or PMID for analysis", e.message)
        }
    }

    @Test
    fun `analysis failure message`() {
        assertEquals("Analysis failed: Test failure reason", TransparencyAnalysisException.AnalysisFailure("Test failure reason").message)
    }

    // ==================== fullTextSearched ====================

    @Test
    fun `full text searched only when non-blank full text is given`() = runBlocking {
        val service = service()
        assertEquals(false, service.analyze(doi = "10.1000/a").fullTextSearched)
        assertEquals(false, service.analyze(doi = "10.1000/a", fullText = "").fullTextSearched)
        assertEquals(false, service.analyze(doi = "10.1000/a", fullText = " \n\t ").fullTextSearched)
        assertEquals(true, service.analyze(doi = "10.1000/a", fullText = "Some text").fullTextSearched)
    }

    // ==================== metadata ====================

    @Test
    fun `PubMed metadata is adopted and its DOI reaches CrossRef`() = runBlocking {
        crossRefWork(doiWithFunders, pfizerWork)
        val result = service { pmid ->
            assertEquals("12345678", pmid)
            ArticleMetadata(
                title = "PubMed title",
                journal = null,
                authors = listOf("Doe J"),
                doi = doiWithFunders,
                pmcid = "PMC1",
            )
        }.analyze(pmid = "12345678")

        assertEquals(doiWithFunders, result.doi)
        assertEquals("PMC1", result.pmcid)
        assertEquals("PubMed title", result.title)
        assertEquals("CrossRef Journal", result.journal)
        assertEquals(listOf("Doe J"), result.authors)
        assertEquals(listOf(TransparencyConstants.PUBMED_SOURCE_NAME, TransparencyConstants.CROSSREF_SOURCE_NAME), result.dataSourcesUsed)
        assertEquals(listOf("Pfizer Inc."), result.funders.map { it.name })
        assertTrue(result.industryFundingDetected)
        assertEquals(1.0, result.industryFundingConfidence, 0.0)
        assertEquals(SponsorType.INDUSTRY, result.sponsorType)
        assertTrue(result.publicationDate != null)
    }

    @Test
    fun `a supplied DOI is not replaced by PubMed's`() = runBlocking {
        crossRefWork("10.1000/mine", "{}")
        val result = service { ArticleMetadata("T", "J", emptyList(), doi = "10.1000/theirs", pmcid = null) }
            .analyze(doi = "10.1000/mine", pmid = "1")
        assertEquals("10.1000/mine", result.doi)
        assertEquals(listOf("/crossref/works/10.1000/mine"), requestedPaths())
    }

    @Test
    fun `CrossRef fills what PubMed did not supply`() = runBlocking {
        crossRefWork(doiWithFunders, pfizerWork)
        val result = service().analyze(doi = doiWithFunders)
        assertEquals("CrossRef title", result.title)
        assertEquals("CrossRef Journal", result.journal)
        assertEquals(listOf("Smith, John"), result.authors)
        assertEquals(listOf(TransparencyConstants.CROSSREF_SOURCE_NAME), result.dataSourcesUsed)
    }

    @Test
    fun `a work CrossRef does not have records no source and no funders`() = runBlocking {
        val result = service().analyze(doi = "10.1000/absent")
        assertTrue(result.dataSourcesUsed.isEmpty())
        assertTrue(result.funders.isEmpty())
        assertEquals(SponsorType.UNKNOWN, result.sponsorType)
    }

    // ==================== failed lookups ====================

    /**
     * An unreachable CrossRef is recorded, so "industry funding: not detected" does not
     * read as a checked funder list; a work CrossRef does not have (404) records nothing.
     */
    @Test
    fun `a CrossRef outage is recorded, unlike an absent work`() = runBlocking {
        crossRefFails(doiWithFunders)
        val failed = service().analyze(doi = doiWithFunders)
        val absent = service().analyze(doi = "10.1000/absent")

        assertFalse(failed.industryFundingDetected)
        assertEquals(absent.dataSourcesUsed, failed.dataSourcesUsed)
        assertEquals(listOf(TransparencyConstants.CROSSREF_UNREACHABLE_WARNING), failed.warnings)
        assertFalse(absent.warnings.contains(TransparencyConstants.CROSSREF_UNREACHABLE_WARNING))
        assertTrue(Log.lines.any { it.contains("CrossRef fetch failed for DOI $doiWithFunders") })
        // Kept as final, the outage stood as "no industry funding" forever (#385).
        assertEquals(true, failed.sourcesUnreachable)
        assertTrue(failed.needsReanalysis)
        assertEquals(false, absent.sourcesUnreachable)
        assertFalse(absent.needsReanalysis)
    }

    /** A PubMed failure with only a PMID also loses CrossRef, hence every funder. */
    @Test
    fun `a PubMed failure is logged and the analysis continues without it`() = runBlocking {
        crossRefWork(doiWithFunders, pfizerWork)
        val result = service { throw IOException("offline") }.analyze(pmid = "12345678")

        assertTrue(result.dataSourcesUsed.isEmpty())
        assertNull(result.title)
        assertFalse(result.industryFundingDetected)
        assertTrue(result.errors.isEmpty())
        assertEquals(0, server.requestCount)
        assertTrue(Log.lines.any { it.contains("PubMed fetch failed for PMID 12345678: IOException") })
        // Once logged only; now the reader is told, and the result is provisional (#385).
        assertEquals(listOf(TransparencyConstants.PUBMED_UNREACHABLE_WARNING), result.warnings)
        assertEquals(true, result.sourcesUnreachable)
        assertTrue(
            TransparencyRiskExplanation.of(result).caveats.any { it.startsWith("No CrossRef record was retrieved") },
        )
    }

    @Test
    fun `a PubMed failure still lets a supplied DOI reach CrossRef`() = runBlocking {
        crossRefWork(doiWithFunders, pfizerWork)
        val result = service { throw IOException("offline") }.analyze(doi = doiWithFunders, pmid = "1")
        assertEquals(listOf(TransparencyConstants.CROSSREF_SOURCE_NAME), result.dataSourcesUsed)
        assertTrue(result.industryFundingDetected)
    }

    @Test(expected = CancellationException::class)
    fun `cancellation is not swallowed`(): Unit = runBlocking {
        service { throw CancellationException("cancelled") }.analyze(pmid = "1")
        Unit
    }

    // ==================== trials ====================

    private fun trialTitledWork(nctId: String) =
        """{"title": ["A randomized trial (${nctId})"], "funder": [{"name": "University of Oxford"}]}"""

    @Test
    fun `an NCT id in the title is looked up and an industry sponsor recorded`() = runBlocking {
        crossRefWork("10.1000/trial", trialTitledWork("NCT99999999"))
        routes["/ctgov/studies/NCT99999999"] = MockResponse().setBody(TransparencyTestFixtures.TRIAL_WITHOUT_RESULTS_STUDY)

        val result = service().analyze(doi = "10.1000/trial")

        assertEquals(listOf("NCT99999999"), result.trialRegistrations.map { it.registrationId })
        assertEquals(
            listOf(TransparencyConstants.CROSSREF_SOURCE_NAME, TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME),
            result.dataSourcesUsed,
        )
        assertTrue(result.industryFundingDetected)
        assertEquals(SponsorType.MIXED, result.sponsorType)
        // Completed 2022-01-01, no results posted: past the FDAAA deadline.
        assertEquals(ResultsComplianceStatus.MISSING, result.resultsCompliance)
        assertFalse(result.warnings.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
        assertEquals(false, result.sourcesUnreachable)
    }

    /**
     * An unreachable registry leaves the registration unchecked, not missing: the outage
     * is recorded and the trial is not reported as unregistered.
     */
    @Test
    fun `a registry outage leaves the registration unchecked, not missing`() = runBlocking {
        crossRefWork("10.1000/trial", trialTitledWork("NCT01234567"))
        routes["/ctgov/studies/NCT01234567"] = MockResponse().setResponseCode(SERVER_ERROR)

        val result = service().analyze(doi = "10.1000/trial")

        assertTrue(result.trialRegistrations.isEmpty())
        assertTrue(result.warnings.contains(TrialComplianceAnalyzer.registryUnreachableWarning("NCT01234567")))
        assertFalse(result.warnings.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
        assertFalse(result.riskIndicators.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
        assertTrue(Log.lines.any { it.contains("ClinicalTrials.gov fetch failed for NCT01234567") })
        assertEquals(true, result.sourcesUnreachable)
    }

    /** Unparsed is not absent: an unreadable record is re-read, not kept (#385). */
    @Test
    fun `an unreadable registry record makes the result provisional`() = runBlocking {
        crossRefWork("10.1000/trial", trialTitledWork("NCT01234567"))
        routes["/ctgov/studies/NCT01234567"] = MockResponse().setBody("{}")

        val result = service().analyze(doi = "10.1000/trial")

        assertTrue(result.warnings.contains(TrialComplianceAnalyzer.unreadableRegistryRecordWarning("NCT01234567")))
        assertEquals(true, result.sourcesUnreachable)
    }

    /** A registry that answers it has no such trial is a finding about the study. */
    @Test
    fun `a trial the registry has no record of is reported missing`() = runBlocking {
        crossRefWork("10.1000/trial", trialTitledWork("NCT07654321"))

        val result = service().analyze(doi = "10.1000/trial")

        assertTrue(result.trialRegistrations.isEmpty())
        assertTrue(result.warnings.contains(TrialComplianceAnalyzer.registryHasNoRecordWarning("NCT07654321")))
        assertTrue(result.riskIndicators.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
        // The registry answered: a finding, not an outage.
        assertEquals(false, result.sourcesUnreachable)
    }

    /** With no trial ID to look up, nothing was asked, so nothing is reported missing. */
    @Test
    fun `a trial title without an NCT id is not reported unregistered`() = runBlocking {
        crossRefWork("10.1000/trial", """{"title": ["A randomized trial of X"]}""")

        val result = service().analyze(doi = "10.1000/trial")

        assertFalse(result.riskIndicators.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
        assertFalse(result.warnings.contains(RiskIndicatorStrings.MISSING_TRIAL_REGISTRATION))
    }

    // ==================== full text ====================

    @Test
    fun `COI and data availability come from the full text, lowercased`() = runBlocking {
        val result = service().analyze(doi = "10.1000/a", fullText = TransparencyTestFixtures.fullTextWithDataAvailability)

        assertEquals(
            "dr. smith reports grants from pfizer.\ndr. doe has no conflicts to declare.",
            result.coiAnalysis.statement,
        )
        assertEquals(DataDisclosureLevel.FULL_OPEN, result.dataAvailability.disclosureLevel)
        assertEquals("Zenodo", result.dataAvailability.repositoryName)
        assertEquals(true, result.fullTextSearched)
    }

    @Test
    fun `full text without the sections finds neither statement`() = runBlocking {
        val result = service().analyze(doi = "10.1000/a", fullText = TransparencyTestFixtures.fullTextWithoutDataAvailability)
        assertNull(result.coiAnalysis.statement)
        assertEquals(DataDisclosureLevel.NOT_STATED, result.dataAvailability.disclosureLevel)
        assertEquals(TransparencyRiskLevel.HIGH, result.riskLevel)
        assertEquals(TransparencyCertainty.FULL_TEXT, TransparencyCertainty.from(result.fullTextSearched))
    }

    @Test
    fun `industry funding without a COI statement is a discrepancy warning`() = runBlocking {
        crossRefWork(doiWithFunders, pfizerWork)
        val result = service().analyze(doi = doiWithFunders)
        assertTrue(result.warnings.contains("Industry funding detected but no COI statement found"))
    }

    @Test
    fun `author string splitting`() {
        assertEquals(
            listOf("Smith J", "Doe J"),
            TransparencyAnalysisService.formatAuthorsToList("Smith J, Doe J, "),
        )
    }

    private companion object {
        const val NOT_FOUND = 404
        const val SERVER_ERROR = 500
        val noDelay = TransparencyRetryPolicy(initialDelayMs = 0, maxDelayMs = 0)
    }
}
