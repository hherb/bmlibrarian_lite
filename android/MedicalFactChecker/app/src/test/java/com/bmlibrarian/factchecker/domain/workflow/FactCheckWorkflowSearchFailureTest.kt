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

package com.bmlibrarian.factchecker.domain.workflow

import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCApi
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCResultList
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCSearchResponse
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.pubmed.ESearchResponse
import com.bmlibrarian.factchecker.data.remote.pubmed.ESearchResult
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedApi
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.ReportRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.UsageRepository
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialSource
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialsUnavailableException
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchConcept
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.ShortfallQuery
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.coVerifyOrder
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import retrofit2.Response

/**
 * What a fact-check does when its literature search fails (#252).
 *
 * Runs the workflow from its search step (a resumed session, so no LLM call
 * converts the claim) over the real search services with mocked APIs, and
 * relaxed mocks for everything the search does not touch.
 */
class FactCheckWorkflowSearchFailureTest {

    private lateinit var pubMedApi: PubMedApi
    private lateinit var europePMCApi: EuropePMCApi
    private lateinit var llmService: LLMService
    private lateinit var sessionRepository: SessionRepository
    private lateinit var documentRepository: DocumentRepository
    private lateinit var reportRepository: ReportRepository
    private lateinit var usageRepository: UsageRepository
    private lateinit var workflow: FactCheckWorkflow

    /** The session as the repository holds it; updated by the recorded shortfalls. */
    private lateinit var stored: SessionEntity

    @Before
    fun setUp() {
        pubMedApi = mockk()
        europePMCApi = mockk()
        llmService = mockk(relaxed = true)
        sessionRepository = mockk(relaxed = true)
        documentRepository = mockk(relaxed = true)
        reportRepository = mockk(relaxed = true)
        usageRepository = mockk(relaxed = true)
        workflow = workflowWith { NcbiCredentials.of(apiKey = null, email = null) }
        Log.clear()
    }

    /**
     * Build the workflow over the real search services.
     *
     * @param credentialSource Where PubMed's search reads the NCBI API key and email
     */
    private fun workflowWith(credentialSource: NcbiCredentialSource) = FactCheckWorkflow(
        llmService = llmService,
        literatureSearch = LiteratureSearch(PubMedService(pubMedApi, credentialSource), EuropePMCService(europePMCApi)),
        sessionRepository = sessionRepository,
        documentRepository = documentRepository,
        reportRepository = reportRepository,
        usageRepository = usageRepository,
        settingsRepository = mockk(relaxed = true),
        parallelScoringService = mockk(relaxed = true),
        parallelCitationService = mockk(relaxed = true),
        checkpointManager = mockk(relaxed = true),
        errorPersistenceManager = mockk(relaxed = true),
        embeddingService = mockk(relaxed = true),
        hydeGenerator = mockk(relaxed = true),
        transparencyRunner = mockk(relaxed = true)
    )

    @Test
    fun `a first search that failed ends the session with what failed, never as no documents found`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(429)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        val state = workflow.state.value
        assertTrue("got $state", state is WorkflowState.Failed)
        assertEquals(
            "The search could not be completed: PubMed could not be searched (HTTP 429 Too Many Requests).\n\n" +
                "The service is limiting how often it can be searched: wait a minute and try again. " +
                "An NCBI API key, set in Settings, raises PubMed's limit.",
            (state as WorkflowState.Failed).error
        )
        coVerify { sessionRepository.setError(SESSION_ID, state.error) }
        coVerify(exactly = 0) { documentRepository.saveDocuments(any()) }
        coVerify(exactly = 0) { sessionRepository.updatePubMedPagination(any(), any(), any()) }
    }

    @Test
    fun `when PubMed fails the report rests on Europe PMC and opens by saying so`() = runTest {
        holdSession(SearchProvider.BOTH)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(503)
        coEvery { europePMCApi.search(any(), any(), any(), any(), any()) } returns Response.success(
            EuropePMCSearchResponse(
                hitCount = 2,
                resultList = EuropePMCResultList(
                    result = listOf(EuropePMCArticle(pmid = "1", title = "One"), EuropePMCArticle(pmid = "2", title = "Two"))
                )
            )
        )
        val report = slot<String>()
        coEvery {
            reportRepository.createReport(any(), any(), any(), capture(report), any(), any(), any(), any(), any())
        } returns mockk(relaxed = true)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.BOTH))

        val shortfall = RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 503))
        // What is missing and the documents are kept before the paging moves past them
        coVerifyOrder {
            sessionRepository.updateRetrievalShortfalls(SESSION_ID, listOf(shortfall))
            documentRepository.saveDocuments(match { docs -> docs.map { it.pmid } == listOf("1", "2") })
            sessionRepository.updateEpmcPagination(SESSION_ID, any(), any(), any())
        }
        assertEquals(listOf(shortfall), workflow.searchShortfalls.value)
        assertTrue(
            "the report does not open with the notice: ${report.captured}",
            report.captured.startsWith(
                "> **Incomplete search:** PubMed could not be searched (HTTP 503 Service Unavailable). " +
                    "Everything below rests only on the records that were retrieved.\n\n"
            )
        )
        assertTrue("got ${workflow.state.value}", workflow.state.value is WorkflowState.Completed)
    }

    @Test
    fun `a search for more that failed keeps the session and returns to the decision`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20
        pubMedFailsWith(429)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        val state = workflow.state.value
        assertTrue("got $state", state is WorkflowState.AwaitingUserDecision)
        assertEquals(37, (state as WorkflowState.AwaitingUserDecision).availableCount)
        assertEquals(
            "The search could not be completed: 20 PubMed records could not be retrieved (HTTP 429 Too Many Requests).\n\n" +
                "The service is limiting how often it can be searched: wait a minute and try again. " +
                "An NCBI API key, set in Settings, raises PubMed's limit.",
            workflow.searchFailureMessage.value
        )
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
        coVerify(exactly = 0) { sessionRepository.updatePubMedPagination(any(), any(), any()) }
        coVerify(exactly = 0) { sessionRepository.updateRetrievalShortfalls(any(), any()) }
        coVerify { sessionRepository.updateWorkflowStep(SESSION_ID, WorkflowStep.AWAITING_USER_DECISION) }
    }

    @Test
    fun `a search for more continues the paging instead of asking for the first page again`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20
        pubMedFailsWith(400)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        coVerify { pubMedApi.search(any(), any(), any(), retMax = 20, retStart = 20, any(), any(), any()) }
        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), retStart = 0, any(), any(), any()) }
    }

    @Test
    fun `an alternative search that failed is recorded as its own, and the report says so`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(listOf(ALTERNATIVE_QUERY))
        // The claim's own query answers; the alternative query is rate limited
        pubMedFailsWith(429)
        coEvery { pubMedApi.search(any(), term = "aspirin", any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(ESearchResult(count = "1", idList = listOf("1"))))
        coEvery { pubMedApi.fetch(any(), any(), any(), any(), any(), any()) } returns Response.success(
            "<PubmedArticleSet><PubmedArticle><MedlineCitation><PMID>1</PMID><Article><ArticleTitle>One</ArticleTitle>" +
                "</Article></MedlineCitation></PubmedArticle></PubmedArticleSet>"
        )
        val report = slot<String>()
        coEvery {
            reportRepository.createReport(any(), any(), any(), capture(report), any(), any(), any(), any(), any())
        } returns mockk(relaxed = true)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED).copy(smartSearchEnabled = true))

        val shortfall = RetrievalShortfall(
            SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429), query = ShortfallQuery.ALTERNATIVE
        )
        coVerify { sessionRepository.updateRetrievalShortfalls(SESSION_ID, listOf(shortfall)) }
        assertTrue(
            "the report does not open with the notice: ${report.captured}",
            report.captured.startsWith(
                "> **Incomplete search:** an alternative search of PubMed could not be completed " +
                    "(HTTP 429 Too Many Requests)."
            )
        )
    }

    @Test
    fun `more evidence whose alternative queries failed and found nothing keeps the report and smart search`() = runTest {
        holdSession(SearchProvider.PUBMED)
        stored = stored.copy(workflowStep = WorkflowStep.COMPLETED)
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(listOf(ALTERNATIVE_QUERY))
        pubMedFailsWith(429)
        coEvery { reportRepository.getReportBySession(SESSION_ID) } returns mockk(relaxed = true) {
            coEvery { id } returns "report-252"
        }
        workflow.restoreForViewing(stored)

        workflow.fetchMoreEvidence()

        assertEquals(WorkflowState.Completed(reportId = "report-252"), workflow.state.value)
        assertEquals(
            "The search could not be completed: an alternative search of PubMed could not be completed " +
                "(HTTP 429 Too Many Requests).\n\n" +
                "The service is limiting how often it can be searched: wait a minute and try again. " +
                "An NCBI API key, set in Settings, raises PubMed's limit.",
            workflow.searchFailureMessage.value
        )
        coVerify { sessionRepository.updateSmartSearchState(SESSION_ID, false, null, null) }
        coVerify(exactly = 0) { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { sessionRepository.updateRetrievalShortfalls(any(), any()) }
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
    }

    @Test
    fun `more evidence whose alternative queries could not be generated keeps the report and says so`() = runTest {
        holdSession(SearchProvider.PUBMED)
        stored = stored.copy(workflowStep = WorkflowStep.COMPLETED)
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.failure(IllegalStateException("the model is unreachable"))
        coEvery { reportRepository.getReportBySession(SESSION_ID) } returns mockk(relaxed = true) {
            coEvery { id } returns "report-252"
        }
        workflow.restoreForViewing(stored)

        workflow.fetchMoreEvidence()

        assertEquals(WorkflowState.Completed(reportId = "report-252"), workflow.state.value)
        assertEquals(
            "Alternative searches could not be run: the language model could not propose alternative queries. " +
                "Check the model and its API key in Settings, then try again.",
            workflow.searchFailureMessage.value
        )
        // Smart search is not marked as tried, so the user can try again
        coVerify(exactly = 0) { sessionRepository.updateSmartSearchState(any(), true, any(), any()) }
        coVerify(exactly = 0) { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) }
        // A request that failed is not asked again here, and costs nothing
        coVerify(exactly = 1) { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) {
            usageRepository.recordUsage(any(), any(), any(), operation = "smart_search_query_generation", any(), any(), any())
        }
    }

    @Test
    fun `a model that cannot be asked during a search leaves smart search available and says so`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(429)
        pubMedFinds("1") { it == "aspirin" }
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.failure(IllegalStateException("the model is unreachable"))

        workflow.resumeSession(SESSION_ID, smartSearchConfig())

        assertEquals(
            "Alternative searches could not be run: the language model could not propose alternative queries. " +
                "Check the model and its API key in Settings, then try again.",
            workflow.searchFailureMessage.value
        )
        coVerify(exactly = 0) { sessionRepository.updateSmartSearchState(any(), true, any(), any()) }
        assertTrue("got ${workflow.state.value}", workflow.state.value is WorkflowState.Completed)
    }

    @Test
    fun `smart search asks again when the model's answer holds no usable query`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(429)
        pubMedFinds("1") { it == "aspirin" }
        pubMedFinds("2") { it.contains("acetylsalicylic") }
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returnsMany
            List(Constants.MAX_QUERY_RETRIES) { Result.success(emptyList<StructuredQuery>()) } +
            Result.success(listOf(ALTERNATIVE_QUERY))

        workflow.resumeSession(SESSION_ID, smartSearchConfig())

        coVerify(exactly = Constants.MAX_QUERY_RETRIES + 1) {
            llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any())
        }
        coVerify { documentRepository.saveDocuments(match { docs -> docs.map { it.pmid } == listOf("2") }) }
        assertEquals(null, workflow.searchFailureMessage.value)
    }

    @Test
    fun `answers that never hold a usable query mark smart search as tried, and the user is told`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(429)
        pubMedFinds("1") { it == "aspirin" }
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(emptyList())

        workflow.resumeSession(SESSION_ID, smartSearchConfig())

        coVerify(exactly = Constants.MAX_QUERY_RETRIES + 1) {
            llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any())
        }
        // Marked as tried, so no later batch asks and pays again
        coVerify { sessionRepository.updateSmartSearchState(SESSION_ID, true, null, null) }
        assertEquals(UNUSABLE_ANSWERS_MESSAGE, workflow.searchFailureMessage.value)
        assertTrue("got ${workflow.state.value}", workflow.state.value is WorkflowState.Completed)
    }

    @Test
    fun `more evidence whose alternative-query answers never hold a usable query keeps the report and says why`() = runTest {
        holdSession(SearchProvider.PUBMED)
        stored = stored.copy(workflowStep = WorkflowStep.COMPLETED)
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(emptyList())
        coEvery { reportRepository.getReportBySession(SESSION_ID) } returns mockk(relaxed = true) {
            coEvery { id } returns "report-252"
        }
        workflow.restoreForViewing(stored)

        workflow.fetchMoreEvidence()

        assertEquals(WorkflowState.Completed(reportId = "report-252"), workflow.state.value)
        assertEquals(UNUSABLE_ANSWERS_MESSAGE, workflow.searchFailureMessage.value)
        coVerify { sessionRepository.updateSmartSearchState(SESSION_ID, true, null, null) }
        coVerify(exactly = 0) { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `what a failed alternative query lost is recorded before a later query's documents are kept`() = runTest {
        holdSession(SearchProvider.PUBMED)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(429)
        pubMedFinds("1") { it == "aspirin" }
        pubMedFinds("2") { it.contains("salicylate") }
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(listOf(ALTERNATIVE_QUERY, SECOND_ALTERNATIVE_QUERY))

        workflow.resumeSession(SESSION_ID, smartSearchConfig())

        val lost = RetrievalShortfall(
            SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429), query = ShortfallQuery.ALTERNATIVE
        )
        coVerifyOrder {
            sessionRepository.updateRetrievalShortfalls(SESSION_ID, listOf(lost))
            documentRepository.saveDocuments(match { docs -> docs.map { it.pmid } == listOf("2") })
        }
    }

    @Test
    fun `a later page's loss joins what the session already recorded`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        val earlier = RetrievalShortfall(SearchProvider.EUROPE_PMC, RequestFailure(RequestFailureKind.TIMEOUT))
        stored = stored.copy(retrievalShortfallsJson = SearchFailureReporting.retrievalShortfallsToJson(listOf(earlier)))
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20
        // esearch lists 3 of the 20 PMIDs the page should hold
        coEvery { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(ESearchResult(count = "57", idList = listOf("21", "22", "23"))))
        coEvery { pubMedApi.fetch(any(), any(), any(), any(), any(), any()) } returns
            Response.success(articleSet("21", "22", "23"))

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        val recorded = listOf(
            earlier,
            RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE), 17)
        )
        coVerify { sessionRepository.updateRetrievalShortfalls(SESSION_ID, recorded) }
        assertEquals(recorded, workflow.searchShortfalls.value)
    }

    @Test
    fun `a report the model writes opens with the notice and states the gap in its Methodology`() = runTest {
        holdSession(SearchProvider.BOTH)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0
        pubMedFailsWith(503)
        coEvery { europePMCApi.search(any(), any(), any(), any(), any()) } returns Response.success(
            EuropePMCSearchResponse(hitCount = 1, resultList = EuropePMCResultList(result = listOf(EuropePMCArticle(pmid = "1", title = "One"))))
        )
        val cited = DocumentEntity(sessionId = SESSION_ID, pmid = "1", title = "One", relevanceScore = 5)
        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } returns listOf(cited)
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } returns
            listOf(CitationEntity(documentId = cited.id, passage = "Aspirin reduced strokes."))
        coEvery { llmService.generateReport(any(), any(), any(), any(), any()) } returns Result.success(
            LLMService.ReportGeneration(verdict = "supported", summary = "Supported.", report = "## Analysis\n\nAspirin helps.")
        )
        val report = slot<String>()
        coEvery {
            reportRepository.createReport(any(), any(), any(), capture(report), any(), any(), any(), any(), any())
        } returns mockk(relaxed = true)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.BOTH))

        val clause = "PubMed could not be searched (HTTP 503 Service Unavailable)"
        assertTrue(
            "got ${report.captured}",
            report.captured.startsWith(
                "> **Incomplete search:** $clause. Everything below rests only on the records that were retrieved.\n\n" +
                    "## Analysis\n\nAspirin helps.\n\n"
            )
        )
        // The transparency sections sit between the analysis and the Methodology
        assertTrue(
            "got ${report.captured}",
            report.captured.contains(
                "## Methodology\n\n- **Search Completeness:** Incomplete: $clause\n\n" +
                    "## References\n\n"
            )
        )
    }

    @Test
    fun `a session reopened from history shows what its search failed to retrieve`() {
        holdSession(SearchProvider.PUBMED)
        val recorded = listOf(RetrievalShortfall(SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429), 20))

        workflow.restoreForViewing(
            stored.copy(
                workflowStep = WorkflowStep.COMPLETED,
                retrievalShortfallsJson = SearchFailureReporting.retrievalShortfallsToJson(recorded)
            )
        )

        assertEquals(recorded, workflow.searchShortfalls.value)
        assertFalse(workflow.searchRecordDamaged.value)
    }

    @Test
    fun `resuming another session searches with its own query, never the last claim's`() = runTest {
        holdSession(SearchProvider.PUBMED)
        val other = stored.copy(id = OTHER_SESSION_ID, workflowStep = WorkflowStep.CONVERTING_QUERY, pubmedQuery = null)
        coEvery { sessionRepository.getSession(OTHER_SESSION_ID) } returns other
        coEvery { documentRepository.getDocumentCount(any()) } returns 0
        coEvery { llmService.convertToStructuredQuery(any(), any(), any(), any()) } returns Result.success(ALTERNATIVE_QUERY)
        pubMedFailsWith(429)
        workflow.resumeSession(OTHER_SESSION_ID, config(SearchProvider.PUBMED))
        coVerify { pubMedApi.search(any(), term = match { it.contains("acetylsalicylic") }, any(), any(), any(), any(), any(), any()) }

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        coVerify { pubMedApi.search(any(), term = "aspirin", any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a session whose record of shortfalls is damaged is not resumed, and the user is told why`() = runTest {
        holdSession(SearchProvider.PUBMED)
        stored = stored.copy(retrievalShortfallsJson = "null")
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 0

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        assertEquals(DAMAGED_SESSION_MESSAGE, (workflow.state.value as? WorkflowState.Failed)?.error)
        assertTrue(workflow.searchRecordDamaged.value)
        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `resuming a healthy session clears the damaged-record warning another session left`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20
        pubMedFailsWith(400)
        workflow.restoreForViewing(stored.copy(id = OTHER_SESSION_ID, retrievalShortfallsJson = "null"))
        assertTrue(workflow.searchRecordDamaged.value)

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        assertFalse(workflow.searchRecordDamaged.value)
    }

    @Test
    fun `fetching more for a session whose record of shortfalls is damaged is refused before searching`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        stored = stored.copy(workflowStep = WorkflowStep.AWAITING_USER_DECISION, retrievalShortfallsJson = "null")
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20
        workflow.restoreForViewing(stored)

        workflow.continueWithMoreDocuments()

        assertEquals(DAMAGED_SESSION_MESSAGE, (workflow.state.value as? WorkflowState.Failed)?.error)
        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `a report is not written for a session whose record of shortfalls is damaged`() = runTest {
        holdSession(SearchProvider.PUBMED)
        stored = stored.copy(workflowStep = WorkflowStep.AWAITING_USER_DECISION, retrievalShortfallsJson = "null")
        workflow.restoreForViewing(stored)

        workflow.proceedWithCurrentDocuments()

        assertEquals(DAMAGED_SESSION_MESSAGE, (workflow.state.value as? WorkflowState.Failed)?.error)
        coVerify(exactly = 0) { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) }
    }

    @Test
    fun `more evidence that cannot read the saved NCBI key keeps the report and says what to do`() = runTest {
        workflow = workflowWith { throw IllegalStateException("the keystore is broken") }
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        stored = stored.copy(workflowStep = WorkflowStep.COMPLETED)
        coEvery { reportRepository.getReportBySession(SESSION_ID) } returns mockk(relaxed = true) {
            coEvery { id } returns "report-252"
        }
        workflow.restoreForViewing(stored)

        workflow.fetchMoreEvidence()

        assertEquals(WorkflowState.Completed(reportId = "report-252"), workflow.state.value)
        assertEquals(NcbiCredentialsUnavailableException().message, workflow.searchFailureMessage.value)
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
    }

    @Test
    fun `fetching more that cannot read the saved NCBI key returns to the decision and says what to do`() = runTest {
        workflow = workflowWith { throw IllegalStateException("the keystore is broken") }
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        coEvery { documentRepository.getDocumentCount(SESSION_ID) } returns 20

        workflow.resumeSession(SESSION_ID, config(SearchProvider.PUBMED))

        assertTrue("got ${workflow.state.value}", workflow.state.value is WorkflowState.AwaitingUserDecision)
        assertEquals(NcbiCredentialsUnavailableException().message, workflow.searchFailureMessage.value)
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
    }

    @Test
    fun `a damaged record of shortfalls is a persistent warning, and more evidence is refused before searching`() = runTest {
        holdSession(SearchProvider.PUBMED, pubmedOffset = 20, pubmedTotalResults = 57)
        stored = stored.copy(workflowStep = WorkflowStep.COMPLETED, retrievalShortfallsJson = "null")
        coEvery { reportRepository.getReportBySession(SESSION_ID) } returns mockk(relaxed = true) {
            coEvery { id } returns "report-252"
        }

        workflow.restoreForViewing(stored)

        assertTrue(workflow.searchRecordDamaged.value)
        assertEquals(null, workflow.searchFailureMessage.value)

        workflow.fetchMoreEvidence()

        assertEquals(WorkflowState.Completed(reportId = "report-252"), workflow.state.value)
        assertEquals(
            "More evidence cannot be added to this session: its record of what its search could not " +
                "retrieve is damaged, so a new report could not say whether its search was complete.",
            workflow.searchFailureMessage.value
        )
        coVerify(exactly = 0) { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
    }

    // ==================== Helpers ====================

    /** Hold a session at its search step, whose recorded shortfalls follow what the workflow records. */
    private fun holdSession(provider: SearchProvider, pubmedOffset: Int = 0, pubmedTotalResults: Int = 0) {
        stored = SessionEntity(
            id = SESSION_ID,
            claimText = "Aspirin prevents strokes",
            pubmedQuery = "aspirin",
            workflowStep = WorkflowStep.SEARCHING_PUBMED,
            searchProvider = provider,
            pubmedOffset = pubmedOffset,
            pubmedTotalResults = pubmedTotalResults
        )
        val recorded = slot<List<RetrievalShortfall>>()
        coEvery { sessionRepository.getSession(SESSION_ID) } answers { stored }
        coEvery { sessionRepository.updateRetrievalShortfalls(SESSION_ID, capture(recorded)) } answers {
            stored = stored.copy(retrievalShortfallsJson = SearchFailureReporting.retrievalShortfallsToJson(recorded.captured))
        }
    }

    /** A configuration that searches this provider, without smart search. */
    private fun config(provider: SearchProvider) = WorkflowConfig(searchProvider = provider, smartSearchEnabled = false)

    /** A configuration that searches PubMed, with smart search. */
    private fun smartSearchConfig() = config(SearchProvider.PUBMED).copy(smartSearchEnabled = true)

    /** Answer esearch with an HTTP error. */
    private fun pubMedFailsWith(status: Int) {
        coEvery { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.error(status, "".toResponseBody(null))
    }

    /**
     * Answer the PubMed searches whose term matches with one record.
     *
     * @param pmid The record's PMID, fetched as an article titled after it
     * @param termMatches Which search terms find it
     */
    private fun pubMedFinds(pmid: String, termMatches: (String) -> Boolean) {
        coEvery { pubMedApi.search(any(), term = match { termMatches(it) }, any(), any(), any(), any(), any(), any()) } returns
            Response.success(ESearchResponse(ESearchResult(count = "1", idList = listOf(pmid))))
        coEvery { pubMedApi.fetch(any(), ids = pmid, any(), any(), any(), any()) } returns Response.success(articleSet(pmid))
    }

    /** An efetch article set holding one titled article for each PMID. */
    private fun articleSet(vararg pmids: String): String = pmids.joinToString(
        separator = "",
        prefix = "<PubmedArticleSet>",
        postfix = "</PubmedArticleSet>"
    ) { pmid ->
        "<PubmedArticle><MedlineCitation><PMID>$pmid</PMID><Article><ArticleTitle>Article $pmid</ArticleTitle>" +
            "</Article></MedlineCitation></PubmedArticle>"
    }

    private companion object {
        const val SESSION_ID = "session-252"

        /** A second session, which must never be searched with the first's query. */
        const val OTHER_SESSION_ID = "session-other"

        /** Shown when every answer the model gave, retries included, held no usable query. */
        const val UNUSABLE_ANSWERS_MESSAGE =
            "Alternative searches could not be run: the language model's answers held no search query " +
                "that could be used. Another model, chosen in Settings, may do better."

        /** Shown when a session whose record of shortfalls is damaged is asked to go on. */
        const val DAMAGED_SESSION_MESSAGE =
            "This session cannot go on: its record of what its search could not retrieve is damaged, " +
                "so a report could not say whether its search was complete."

        /** An alternative query, built into a different PubMed term than the claim's own "aspirin". */
        val ALTERNATIVE_QUERY = StructuredQuery(
            concepts = listOf(SearchConcept(name = "acetylsalicylic acid", keywords = listOf("acetylsalicylic acid")))
        )

        /** A second alternative query, whose term shares nothing with the first's. */
        val SECOND_ALTERNATIVE_QUERY = StructuredQuery(
            concepts = listOf(SearchConcept(name = "sodium salicylate", keywords = listOf("sodium salicylate")))
        )
    }
}
