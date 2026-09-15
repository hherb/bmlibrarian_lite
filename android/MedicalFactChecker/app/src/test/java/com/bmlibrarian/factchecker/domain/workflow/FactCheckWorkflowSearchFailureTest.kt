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
import com.bmlibrarian.factchecker.domain.model.NcbiCredentials
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchConcept
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.ShortfallQuery
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.slot
import kotlinx.coroutines.test.runTest
import okhttp3.ResponseBody.Companion.toResponseBody
import org.junit.Assert.assertEquals
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
        workflow = FactCheckWorkflow(
            llmService = llmService,
            literatureSearch = LiteratureSearch(
                PubMedService(pubMedApi) { NcbiCredentials.of(apiKey = null, email = null) },
                EuropePMCService(europePMCApi)
            ),
            sessionRepository = sessionRepository,
            documentRepository = documentRepository,
            reportRepository = reportRepository,
            usageRepository = mockk(relaxed = true),
            settingsRepository = mockk(relaxed = true),
            parallelScoringService = mockk(relaxed = true),
            parallelCitationService = mockk(relaxed = true),
            checkpointManager = mockk(relaxed = true),
            errorPersistenceManager = mockk(relaxed = true),
            embeddingService = mockk(relaxed = true),
            hydeGenerator = mockk(relaxed = true)
        )
    }

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
        coVerify { sessionRepository.updateRetrievalShortfalls(SESSION_ID, listOf(shortfall)) }
        coVerify { documentRepository.saveDocuments(match { docs -> docs.map { it.pmid } == listOf("1", "2") }) }
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
        assertTrue(
            "got ${workflow.searchFailureMessage.value}",
            workflow.searchFailureMessage.value.orEmpty().startsWith(
                "The search could not be completed: 20 PubMed records could not be retrieved (HTTP 429 Too Many Requests)."
            )
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
    fun `more evidence that every alternative search failed to find keeps the report and smart search`() = runTest {
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
        assertTrue(
            "got ${workflow.searchFailureMessage.value}",
            workflow.searchFailureMessage.value.orEmpty().startsWith(
                "The search could not be completed: an alternative search of PubMed could not be completed " +
                    "(HTTP 429 Too Many Requests)."
            )
        )
        coVerify { sessionRepository.updateSmartSearchState(SESSION_ID, false, null, null) }
        coVerify(exactly = 0) { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) }
        coVerify(exactly = 0) { sessionRepository.updateRetrievalShortfalls(any(), any()) }
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

    /** Answer esearch with an HTTP error. */
    private fun pubMedFailsWith(status: Int) {
        coEvery { pubMedApi.search(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Response.error(status, "".toResponseBody(null))
    }

    private companion object {
        const val SESSION_ID = "session-252"

        /** An alternative query, built into a different PubMed term than the claim's own "aspirin". */
        val ALTERNATIVE_QUERY = StructuredQuery(
            concepts = listOf(SearchConcept(name = "acetylsalicylic acid", keywords = listOf("acetylsalicylic acid")))
        )
    }
}
