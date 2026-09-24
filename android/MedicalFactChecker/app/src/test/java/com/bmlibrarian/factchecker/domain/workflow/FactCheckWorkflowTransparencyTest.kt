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

package com.bmlibrarian.factchecker.domain.workflow

import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.ReportRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.domain.transparency.COIAnalysisResult
import com.bmlibrarian.factchecker.domain.transparency.HighRiskTransparencySection
import com.bmlibrarian.factchecker.domain.transparency.TransparencyResultBuilder
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import io.mockk.slot
import java.io.IOException
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The workflow's transparency step: each relevant document is analysed before
 * the report is written, and the report discusses those rated high.
 */
class FactCheckWorkflowTransparencyTest {

    private lateinit var llmService: LLMService
    private lateinit var sessionRepository: SessionRepository
    private lateinit var documentRepository: DocumentRepository
    private lateinit var reportRepository: ReportRepository
    private lateinit var runner: TransparencyAnalysisRunner
    private lateinit var workflow: FactCheckWorkflow

    /** The session's documents as the repository holds them, updated by stored analyses. */
    private val documents = mutableMapOf<String, DocumentEntity>()

    @Before
    fun setUp() {
        llmService = mockk(relaxed = true)
        sessionRepository = mockk(relaxed = true)
        documentRepository = mockk(relaxed = true)
        reportRepository = mockk(relaxed = true)
        runner = mockk()
        workflow = FactCheckWorkflow(
            llmService = llmService,
            literatureSearch = mockk(relaxed = true),
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
            hydeGenerator = mockk(relaxed = true),
            transparencyRunner = runner
        )
        Log.clear()

        coEvery { sessionRepository.getSession(SESSION_ID) } returns SessionEntity(
            id = SESSION_ID,
            claimText = "Aspirin prevents strokes",
            pubmedQuery = "aspirin",
            workflowStep = WorkflowStep.ANALYZING_TRANSPARENCY,
            searchProvider = SearchProvider.PUBMED
        )
        listOf(
            document("relevant", relevance = 4),
            document("failing", relevance = 5),
            document("irrelevant", relevance = 1),
        ).forEach { documents[it.id] = it }
        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } answers { documents.values.toList() }
        coEvery { documentRepository.updateTransparency(any(), any()) } answers {
            val id = firstArg<String>()
            documents[id] = documents.getValue(id).copy(transparencyResultJson = secondArg())
        }
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } returns
            listOf(CitationEntity(documentId = "relevant", passage = "A passage."))
        coEvery { llmService.generateReport(any(), any(), any(), any(), any()) } returns
            Result.success(LLMService.ReportGeneration(verdict = "supported", summary = "S", report = "The analysis."))

        // No COI statement and no full text: rated high, with limited certainty.
        coEvery { runner.analyze(match { it.id == "relevant" }) } returns
            TransparencyResultBuilder(pmid = "1").apply {
                coiAnalysis = COIAnalysisResult.NOT_AVAILABLE
                fullTextSearched = false
            }.build()
        coEvery { runner.analyze(match { it.id == "failing" }) } throws IOException("CrossRef unreachable")
    }

    private fun document(id: String, relevance: Int) = DocumentEntity(
        id = id,
        sessionId = SESSION_ID,
        pmid = id.length.toString(),
        title = "Study $id",
        authors = listOf("Author${id.replaceFirstChar { it.uppercase() }} A", "Other B"),
        publicationYear = 2020,
        relevanceScore = relevance
    )

    @Test
    fun `relevant documents are analysed and the report discusses the high-risk one`() = runTest {
        val report = slot<String>()
        coEvery {
            reportRepository.createReport(any(), any(), any(), capture(report), any(), any(), any(), any(), any())
        } returns mockk(relaxed = true)

        workflow.resumeSession(SESSION_ID, WorkflowConfig(searchProvider = SearchProvider.PUBMED))

        coVerify(exactly = 1) { documentRepository.updateTransparency("relevant", any()) }
        coVerify(exactly = 0) { runner.analyze(match { it.id == "irrelevant" }) }
        assertTrue(report.captured, report.captured.contains("## ${HighRiskTransparencySection.HEADING}"))
        assertTrue(report.captured, report.captured.contains("### AuthorRelevant et al., 2020"))
        assertTrue(
            report.captured,
            report.captured.contains("Limited certainty because of lack of full text access")
        )
    }

    /** One document's failure is named, not fatal: the report is still written. */
    @Test
    fun `a failed analysis is reported and the run completes`() = runTest {
        workflow.resumeSession(SESSION_ID, WorkflowConfig(searchProvider = SearchProvider.PUBMED))

        assertTrue("got ${workflow.state.value}", workflow.state.value is WorkflowState.Completed)
        assertEquals("Transparency analysis failed for: Study failing", workflow.searchFailureMessage.value)
        coVerify(exactly = 0) { sessionRepository.setError(any(), any()) }
        coVerify(exactly = 0) { documentRepository.updateTransparency("failing", any()) }
    }

    @Test
    fun `a document analysed by the current analyzer is not analysed again`() = runTest {
        workflow.resumeSession(SESSION_ID, WorkflowConfig(searchProvider = SearchProvider.PUBMED))
        workflow.resumeSession(SESSION_ID, WorkflowConfig(searchProvider = SearchProvider.PUBMED))

        coVerify(exactly = 1) { runner.analyze(match { it.id == "relevant" }) }
    }

    private companion object {
        const val SESSION_ID = "session-transparency"
    }
}
