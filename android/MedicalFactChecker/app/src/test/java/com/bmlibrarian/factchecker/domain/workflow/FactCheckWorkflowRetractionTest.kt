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
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.AppSettings
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.util.retraction.BmlibFfi
import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import com.bmlibrarian.factchecker.util.retraction.RetractionPaper
import com.bmlibrarian.factchecker.util.retraction.RetractionService
import com.bmlibrarian.factchecker.util.retraction.RetractionSnapshot
import com.bmlibrarian.factchecker.util.retraction.StoredRetractionEvidence
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/**
 * The retraction screen before scoring: a retracted paper is never scored or
 * cited and leaves its trace; an unchecked one is scored and counted; a
 * failing check never stops the run. Papers carry PMIDs only, so their keys
 * need no native library.
 */
class FactCheckWorkflowRetractionTest {

    private lateinit var documentRepository: DocumentRepository
    private lateinit var reportRepository: ReportRepository
    private lateinit var sessionRepository: SessionRepository
    private lateinit var retractionService: RetractionService
    private lateinit var scoring: ParallelScoringService
    private lateinit var errors: ErrorPersistenceManager
    private lateinit var workflow: FactCheckWorkflow

    private val documents = linkedMapOf<String, DocumentEntity>()
    private val citations = mutableListOf<CitationEntity>()

    /** Each paper's stored row, by key, as the retraction_checks table holds it. */
    private val rows = mutableMapOf<String, String>()

    /** What each check was asked about. */
    private val asked = mutableListOf<List<RetractionPaper>>()

    /** The check each paper's fresh check answers with, by PMID. */
    private val answers = mutableMapOf<String, PaperRetractionCheck>()

    /** Which documents scoring was asked to score. */
    private val scored = mutableListOf<String>()

    private var snapshotJson: String? = null

    /** Every report written, its markdown. */
    private val reports = mutableListOf<String>()

    private var session = SessionEntity(
        id = SESSION_ID,
        claimText = "Aspirin prevents strokes",
        pubmedQuery = "aspirin",
        workflowStep = WorkflowStep.SCORING_DOCUMENTS,
        searchProvider = SearchProvider.PUBMED
    )

    @Before
    fun setUp() {
        documentRepository = mockk(relaxed = true)
        reportRepository = mockk(relaxed = true)
        sessionRepository = mockk(relaxed = true)
        retractionService = mockk()
        scoring = mockk(relaxed = true)
        errors = mockk(relaxed = true)
        val settingsRepository = mockk<SettingsRepository>(relaxed = true)
        every { settingsRepository.getLlmProvider() } returns LLMProvider.OPENAI.id
        every { settingsRepository.getLlmModel() } returns LLMProvider.OPENAI.defaultModel
        every { settingsRepository.settings } returns MutableStateFlow(AppSettings())
        val llmService = mockk<LLMService>(relaxed = true)
        coEvery { llmService.generateReport(any(), any(), any(), any(), any()) } returns
            Result.success(LLMService.ReportGeneration(verdict = "supported", summary = "S", report = "The analysis."))

        coEvery { sessionRepository.getSession(SESSION_ID) } answers { session.copy(retractionSnapshotJson = snapshotJson) }
        coEvery { sessionRepository.updateRetractionSnapshot(SESSION_ID, any()) } answers { snapshotJson = secondArg() }
        coEvery { documentRepository.getUnscoredDocuments(SESSION_ID) } answers { documents.values.filter { !it.isScored } }
        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } answers { documents.values.toList() }
        coEvery { documentRepository.getDocument(any()) } answers { documents[firstArg()] }
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } answers { citations.toList() }
        coEvery { documentRepository.saveCitations(any()) } answers { citations += firstArg<List<CitationEntity>>() }
        coEvery { scoring.scoreDocumentsWithCheckpoints(any(), any(), any(), any(), any(), any(), any(), any(), any()) } coAnswers {
            val inputs = firstArg<List<ScoringInput>>()
            scored += inputs.map { it.documentId }
            // every scored paper is relevant
            inputs.forEach { documents[it.documentId] = documents.getValue(it.documentId).copy(relevanceScore = 5) }
            emptyList()
        }
        val citationService = mockk<ParallelCitationService>(relaxed = true)
        coEvery { citationService.extractCitations(any(), any(), any(), any(), any(), any(), any(), any()) } coAnswers {
            val inputs = firstArg<List<CitationInput>>()
            val onResult = arg<suspend (CitationResult) -> Unit>(7)
            inputs.map { input ->
                CitationResult.Success(input.documentId, input.pmid, listOf(LLMService.CitationExtraction("A passage.", "Relevant.")))
                    .also { onResult(it) }
            }
        }
        coEvery { reportRepository.createReport(any(), any(), any(), any(), any(), any(), any(), any(), any()) } answers {
            reports += arg<String>(3)
            mockk(relaxed = true) { every { id } returns "report" }
        }
        coEvery { retractionService.storedChecks(any()) } answers {
            firstArg<Collection<String>>().mapNotNull { key -> rows[key]?.let { key to it } }.toMap()
        }
        coEvery { retractionService.store(any()) } answers {
            firstArg<Map<String, PaperRetractionCheck>>().forEach { (key, check) -> rows[key] = PaperRetractionCheck.encode(check) }
        }
        coEvery { retractionService.check(any()) } coAnswers {
            val papers = firstArg<List<RetractionPaper>>()
            asked += papers
            papers.associateWith { answers[it.pmid] ?: CLEAR }
        }

        workflow = FactCheckWorkflow(
            llmService = llmService,
            literatureSearch = mockk(relaxed = true),
            sessionRepository = sessionRepository,
            documentRepository = documentRepository,
            reportRepository = reportRepository,
            usageRepository = mockk(relaxed = true),
            settingsRepository = settingsRepository,
            parallelScoringService = scoring,
            parallelCitationService = citationService,
            checkpointManager = mockk(relaxed = true),
            errorPersistenceManager = errors,
            embeddingService = mockk(relaxed = true),
            hydeGenerator = mockk(relaxed = true),
            transparencyRunner = mockk(relaxed = true),
            fullTextService = mockk(relaxed = true),
            retractionService = retractionService
        )
        Log.clear()
    }

    private fun hold(id: String, pmid: String? = id.removePrefix("d"), doi: String? = null, types: List<String>? = null) {
        documents[id] = DocumentEntity(
            id = id, sessionId = SESSION_ID, pmid = pmid, doi = doi, title = "Study $id", abstractText = "A.",
            publicationTypesJson = types?.joinToString(",", "[", "]") { "\"$it\"" }
        )
    }

    private suspend fun run() = workflow.resumeSession(SESSION_ID, CONFIG)

    private fun snapshot() = RetractionSnapshot.read(snapshotJson)

    @Test
    fun `a retracted paper is never scored, stays in the session and is counted, stored and named`() = runTest {
        hold("d1")
        hold("d2")
        answers["2"] = RETRACTED

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue("it stays in the session", "d2" in documents)
        assertEquals("Retraction check: 1 retracted paper left out.", workflow.retractionNotice.value)
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:2"))!!.isRetracted)
        assertTrue(snapshot().getValue("d2").isRetracted)
        assertTrue(snapshot().getValue("d1").isClear)
        val report = reports.single()
        assertTrue(report, report.startsWith("> **Retraction check:** 1 retracted paper left out."))
        assertTrue(report, report.contains("## Left out as retracted\n\n- Study d2. Retracted 2026-03-09; notice 10.9/n"))
        assertTrue(report, report.contains("- **Retraction Check:** Retraction status checked "))
        assertFalse("never a reference", report.substringAfter("## References").contains("Study d2"))
    }

    @Test
    fun `an unchecked paper is scored and counted, with its cause`() = runTest {
        hold("d1")
        answers["1"] = OUTAGE

        run()

        assertEquals(listOf("d1"), scored)
        assertEquals(
            "Retraction check: 1 paper's retraction status could not be checked: Crossref could not be used (HTTP 503).",
            workflow.retractionNotice.value
        )
    }

    @Test
    fun `a paper under concern is scored and its reference carries the caveat`() = runTest {
        hold("d1")
        answers["1"] = CONCERN

        run()

        assertEquals(listOf("d1"), scored)
        val references = reports.single().substringAfter("## References")
        assertTrue(references, references.contains("Study d1. PMID: 1\n    ⚠️ Expression of concern (2026-03-09, notice 10.9/n)"))
    }

    @Test
    fun `retrying failed documents screens them too`() = runTest {
        hold("d1")
        answers["1"] = RETRACTED
        workflow.restoreForViewing(session)
        coEvery { errors.getRetryableErrorsByStep(SESSION_ID, any()) } returns listOf(mockk(relaxed = true) { every { documentId } returns "d1" })

        workflow.retryFailedDocuments()

        assertTrue(scored.isEmpty())
        assertTrue(snapshot().getValue("d1").isRetracted)
        // left out on purpose, so settled: it leaves the retry queue rather than failing again
        coVerify { errors.removeErrorsForDocuments(SESSION_ID, setOf("d1")) }
        coVerify(exactly = 0) { errors.markRetried(any()) }
    }

    @Test
    fun `a failing check leaves every paper unchecked, and the run goes on`() = runTest {
        hold("d1")
        coEvery { retractionService.check(any()) } throws IOException("down")

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(snapshot().getValue("d1").isUnchecked)
        // with no row yet a failure is written, as the desktop writes it: never reused, never standing against an answer
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isUnchecked)
        assertEquals("Retraction check: 1 paper's retraction status could not be checked: the check failed.", workflow.retractionNotice.value)
    }

    @Test
    fun `a build without bmlib's native library leaves every paper unchecked, and the run goes on`() = runTest {
        hold("d1")
        coEvery { retractionService.check(any()) } throws UnsatisfiedLinkError("no bmlib_ffi")

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(snapshot().getValue("d1").isUnchecked)
        assertTrue(workflow.retractionNotice.value!!.endsWith("could not be checked: the check failed."))
    }

    @Test
    fun `a cancel during the check records nothing`() = runTest {
        hold("d1")
        coEvery { retractionService.check(any()) } throws CancellationException("stopped")

        assertThrows(CancellationException::class.java) { kotlinx.coroutines.runBlocking { run() } }

        assertNull(snapshotJson)
        assertTrue(rows.isEmpty())
        assertTrue(scored.isEmpty())
    }

    /** #651's scenario: what session A learnt keeps the paper out of session B during an outage. */
    @Test
    fun `a retraction another session found stands against an outage`() = runTest {
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = System.currentTimeMillis() - 10 * DAY_MS))
        hold("d1")
        answers["1"] = OUTAGE.copy(unanswered = listOf("retraction_watch_export", "crossref"), exportDataAsOf = null)

        run()

        assertEquals("the stale row is asked again", 1, asked.size)
        assertTrue(scored.isEmpty())
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue("the row keeps what the answer established", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
    }

    @Test
    fun `a fresh stored retraction is used without asking`() = runTest {
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = System.currentTimeMillis()))
        hold("d1")

        run()

        assertTrue(asked.isEmpty())
        assertTrue(scored.isEmpty())
    }

    @Test
    fun `a paper with neither DOI nor PMID is checked, scored and stores nothing`() = runTest {
        hold("d1", pmid = null)
        // as bmlib answers a paper with no identifier: unchecked, both lookups unanswered
        coEvery { retractionService.check(any()) } coAnswers {
            firstArg<List<RetractionPaper>>().associateWith { PaperRetractionCheck.failed(1) }
        }

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(rows.isEmpty())
        assertTrue(snapshot().getValue("d1").isUnchecked)
        assertEquals("Retraction check: 1 paper's retraction status could not be checked: no DOI or PMID.", workflow.retractionNotice.value)
    }

    /** The desktop's `_label_check`: the label needs neither network nor database. */
    @Test
    fun `a failing check still leaves out a paper its own label retracts`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1", types = listOf("Retracted Publication"))
        hold("d2", types = listOf("Journal Article"))
        coEvery { retractionService.check(any()) } throws IOException("down")

        run()

        assertEquals(listOf("d2"), scored)
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue(snapshot().getValue("d2").isUnchecked)
    }

    @Test
    fun `a stored clear is kept through an outage but the paper is shown unchecked`() = runTest {
        val clear = CLEAR.copy(checkedAtMs = System.currentTimeMillis() - 10 * DAY_MS)
        rows["pmid:1"] = PaperRetractionCheck.encode(clear)
        hold("d1")
        answers["1"] = OUTAGE

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(snapshot().getValue("d1").isUnchecked)
        assertEquals("the row keeps its answer", clear, PaperRetractionCheck.decode(rows.getValue("pmid:1")))
        assertEquals(
            "Retraction check: 1 paper's retraction status could not be checked: Crossref could not be used (HTTP 503).",
            workflow.retractionNotice.value
        )
    }

    @Test
    fun `a check that cannot be stored still leaves the retracted paper out`() = runTest {
        hold("d1")
        hold("d2")
        answers["2"] = RETRACTED
        coEvery { retractionService.store(any()) } throws IOException("disk full")

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(snapshot().getValue("d2").isRetracted)
        assertEquals("Retraction check: 1 retracted paper left out.", workflow.retractionNotice.value)
    }

    @Test
    fun `stored checks that cannot be read leave every paper unchecked, and the run goes on`() = runTest {
        hold("d1")
        coEvery { retractionService.storedChecks(any()) } throws IOException("database locked")

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(asked.isEmpty())
        assertTrue(snapshot().getValue("d1").isUnchecked)
        assertEquals("Retraction check: 1 paper's retraction status could not be checked: the check failed.", workflow.retractionNotice.value)
    }

    /** The desktop's `test_one_typed_document_reads_the_label_for_the_paper`. */
    @Test
    fun `a paper two documents share is decided against the row this run writes`() = runTest {
        val label = PaperRetractionCheck(
            "retracted", StoredRetractionEvidence("pubmed_label", "retraction"), checkedAtMs = System.currentTimeMillis() - 10 * DAY_MS
        )
        rows["pmid:1"] = PaperRetractionCheck.encode(label)
        hold("d1", pmid = "1", types = listOf("Journal Article"))
        hold("d2", pmid = "1")

        run()

        assertEquals(listOf("d1", "d2"), scored)
        assertTrue(snapshot().getValue("d2").isClear)
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isClear)
    }

    @Test
    fun `a session whose papers were all left out writes the section into its stand-in report`() = runTest {
        hold("d1")
        answers["1"] = RETRACTED

        run()

        val report = reports.single()
        assertTrue(report, report.contains("## Methodology\n\n- **Retraction Check:** Retraction status checked "))
        assertTrue(report, report.contains("## Left out as retracted\n\n- Study d1. Retracted 2026-03-09; notice 10.9/n"))
        coVerify(exactly = 1) { sessionRepository.updateRetractionSnapshot(SESSION_ID, any()) }
    }

    private companion object {
        const val SESSION_ID = "session-retraction"
        const val DAY_MS = 86_400_000L
        val CONFIG = WorkflowConfig(smartSearchEnabled = false)
        val NOTICE = StoredRetractionEvidence("retraction_watch_export", "retraction", "2026-03-09", "10.9/n")
        val RETRACTED = PaperRetractionCheck("retracted", NOTICE, checkedAtMs = 1, exportDataAsOf = "2026-10-01")
        val CONCERN = PaperRetractionCheck(
            "concern", NOTICE.copy(kind = "expression_of_concern"), checkedAtMs = 1, exportDataAsOf = "2026-10-01"
        )
        val CLEAR = PaperRetractionCheck("clear", checkedAtMs = 1, exportDataAsOf = "2026-10-01")
        val OUTAGE = PaperRetractionCheck(
            "unchecked", unanswered = listOf("crossref"), checkedAtMs = 1, exportDataAsOf = "2026-10-01", crossrefFailure = "HTTP 503"
        )
    }
}
