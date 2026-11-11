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
import com.bmlibrarian.factchecker.domain.model.SearchConcept
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.util.retraction.BmlibFfi
import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import com.bmlibrarian.factchecker.util.retraction.RetractionChecker
import com.bmlibrarian.factchecker.util.retraction.RetractionPaper
import com.bmlibrarian.factchecker.util.retraction.RetractionService
import com.bmlibrarian.factchecker.util.retraction.RetractionSnapshot
import com.bmlibrarian.factchecker.util.retraction.RetractionText
import com.bmlibrarian.factchecker.util.retraction.retractionPaper
import com.bmlibrarian.factchecker.util.retraction.StoredRetractionEvidence
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.every
import io.mockk.mockk
import io.mockk.mockkObject
import io.mockk.unmockkObject
import java.io.IOException
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.test.runCurrent
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.After
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
    private lateinit var llmService: LLMService
    private lateinit var literatureSearch: LiteratureSearch

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
        llmService = mockk(relaxed = true)
        literatureSearch = mockk(relaxed = true)
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
        coEvery { retractionService.store(any(), any()) } answers {
            val keepExisting = secondArg<Boolean>()
            firstArg<Map<String, PaperRetractionCheck>>().forEach { (key, check) ->
                if (!keepExisting || key !in rows) rows[key] = PaperRetractionCheck.encode(check)
            }
        }
        coEvery { retractionService.check(any()) } coAnswers {
            val papers = firstArg<List<RetractionPaper>>()
            asked += papers
            papers.associateWith { answers[it.pmid] ?: CLEAR }
        }

        workflow = FactCheckWorkflow(
            llmService = llmService,
            literatureSearch = literatureSearch,
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

    @After
    fun tearDown() = unmockkObject(RetractionChecker.Companion)

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
    fun `a paper scored before any screen is counted unchecked in the report (#657)`() = runTest {
        hold("d1")
        documents["d1"] = documents.getValue("d1").copy(relevanceScore = 5)
        hold("d2")

        run()

        assertEquals("only the new paper is screened", listOf("d2"), scored)
        assertFalse("d1" in snapshot())
        val report = reports.single()
        assertTrue(report, report.startsWith("> **Retraction check:** 1 paper's retraction status could not be checked.\n\n"))
    }

    /** The unscreened paper has no cause, so the screened one's is not named over both. */
    @Test
    fun `a report counting a paper no run screened gives the count alone`() = runTest {
        hold("d1")
        documents["d1"] = documents.getValue("d1").copy(relevanceScore = 5)
        hold("d2")
        answers["2"] = OUTAGE

        run()

        assertEquals("only the new paper is screened", listOf("d2"), scored)
        val report = reports.single()
        assertTrue(report, report.startsWith("> **Retraction check:** 2 papers' retraction status could not be checked.\n\n"))
    }

    @Test
    fun `a run's report names the causes of the papers it screened`() = runTest {
        hold("d1")
        answers["1"] = OUTAGE

        run()

        val report = reports.single()
        assertTrue(
            report,
            report.startsWith("> **Retraction check:** 1 paper's retraction status could not be checked: Crossref could not be used (HTTP 503).\n\n")
        )
    }

    /**
     * The control: a run that screened only some of the papers its report
     * counts (the rest recorded by an earlier run) gives the count alone, as a
     * restored snapshot does, so no paper is counted under another's cause.
     */
    @Test
    fun `a report counting papers an earlier run screened gives the count alone`() = runTest {
        hold("d1")
        documents["d1"] = documents.getValue("d1").copy(relevanceScore = 5)
        snapshotJson = RetractionSnapshot.merged(null, mapOf("d1" to NO_EXPORT))
        hold("d2")
        answers["2"] = OUTAGE

        run()

        assertEquals("only the new paper is screened", listOf("d2"), scored)
        val report = reports.single()
        assertTrue(report, report.startsWith("> **Retraction check:** 2 papers' retraction status could not be checked.\n\n"))
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
        // a stored clear the label has since overtaken
        val clear = CLEAR.copy(checkedAtMs = System.currentTimeMillis() - 10 * DAY_MS)
        rows["pmid:3"] = PaperRetractionCheck.encode(clear)
        hold("d3", types = listOf("Retracted Publication"))
        coEvery { retractionService.check(any()) } throws IOException("down")

        run()

        assertEquals(listOf("d2"), scored)
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue(snapshot().getValue("d2").isUnchecked)
        assertTrue(snapshot().getValue("d3").isRetracted)
        assertTrue("the label overtakes the stored clear", PaperRetractionCheck.decode(rows.getValue("pmid:3"))!!.isRetracted)
    }

    @Test
    fun `a failed check fills only a missing row, never one another writer stored meanwhile`() = runTest {
        hold("d1")
        answers["1"] = OUTAGE
        // no row when read; another writer stores a retraction before this run writes
        coEvery { retractionService.storedChecks(any()) } answers {
            rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED)
            emptyMap()
        }

        run()

        assertTrue("the other writer's row stands", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
    }

    @Test
    fun `an answered check replaces a row another writer stored meanwhile`() = runTest {
        hold("d1")
        coEvery { retractionService.storedChecks(any()) } answers {
            rows["pmid:1"] = PaperRetractionCheck.encode(OUTAGE)
            emptyMap()
        }

        run()

        assertTrue("control: every lookup answered", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isClear)
    }

    @Test
    fun `a document a second screen of the run meets again is checked once`() = runTest {
        hold("d1")
        hold("d2")
        answers["2"] = RETRACTED
        coEvery { llmService.generateAlternativeQueries(any(), any(), any(), any(), any(), any(), any(), any()) } returns
            Result.success(listOf(StructuredQuery(concepts = listOf(SearchConcept(name = "salicylate", keywords = listOf("salicylate"))))))
        // smart search finds d2 again beside a new d3
        coEvery { literatureSearch.searchPage(any()) } answers {
            hold("d3")
            SearchPageOutcome(listOf(documents.getValue("d2"), documents.getValue("d3")), emptyList(), null, null)
        }

        workflow.resumeSession(SESSION_ID, CONFIG.copy(smartSearchEnabled = true))

        assertEquals("control: the run screened twice", 2, asked.size)
        assertEquals(listOf("1", "2", "3"), asked.flatten().mapNotNull { it.pmid }.sorted())
        assertFalse("still left out", "d2" in scored)
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
        coEvery { retractionService.store(any(), any()) } throws IOException("disk full")

        run()

        assertEquals(listOf("d1"), scored)
        assertTrue(snapshot().getValue("d2").isRetracted)
        assertEquals("Retraction check: 1 retracted paper left out.", workflow.retractionNotice.value)
    }

    /** #720, the desktop's `test_a_failed_stored_read_still_asks_afresh_and_stores_nothing`. */
    @Test
    fun `stored checks that cannot be read leave every paper to the fresh check, and nothing is stored`() = runTest {
        hold("d1")
        hold("d2")
        answers["2"] = RETRACTED
        coEvery { retractionService.storedChecks(any()) } throws IOException("database locked")

        run()

        assertEquals(listOf("d1"), scored)
        assertEquals(listOf("1", "2"), asked.single().map { it.pmid })
        assertTrue(snapshot().getValue("d1").isClear)
        assertTrue(snapshot().getValue("d2").isRetracted)
        assertEquals("Retraction check: 1 retracted paper left out.", workflow.retractionNotice.value)
        coVerify(exactly = 0) { retractionService.store(any(), any()) }
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

    /** #671: decided once per paper, as the desktop does, so the document that knows less never writes over it. */
    @Test
    fun `a paper two documents share is checked once, from both documents' evidence`() = runTest {
        // the document that knows less comes first, so its own paper alone would not do
        hold("d1", pmid = "1")
        hold("d2", pmid = "1", types = listOf("Journal Article"))
        // Crossref is down; only a check that sees d2's record finds the retraction
        coEvery { retractionService.check(any()) } coAnswers {
            val papers = firstArg<List<RetractionPaper>>()
            asked += papers
            papers.associateWith { if (it.publicationTypes.isEmpty()) OUTAGE else RETRACTED.copy(unanswered = listOf("crossref")) }
        }

        run()

        assertEquals(listOf(listOf(RetractionPaper(null, "1", listOf("Journal Article")))), asked)
        assertTrue(scored.isEmpty())
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
    }

    /** The desktop's `_label_only_unreadable`: a label is recorded when any document of the paper recorded one. */
    @Test
    fun `a paper's label counts as recorded when a later document recorded it`() = runTest {
        val label = PaperRetractionCheck(
            "retracted", StoredRetractionEvidence("pubmed_label", "retraction"), checkedAtMs = System.currentTimeMillis() - 10 * DAY_MS
        )
        rows["pmid:1"] = PaperRetractionCheck.encode(label)
        hold("d1", pmid = "1")
        hold("d2", pmid = "1", types = listOf("Journal Article"))

        run()

        assertEquals(listOf("d1", "d2"), scored)
        assertTrue(snapshot().getValue("d1").isClear)
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isClear)
    }

    /** The desktop's `_label_retracts` over every document of a key: one document's label overtakes a stored clear for all. */
    @Test
    fun `a label on one document of a paper overtakes a stored clear for every document`() = runTest {
        BmlibFfi.assumeAvailable()
        rows["pmid:1"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = System.currentTimeMillis()))
        hold("d1", pmid = "1")
        hold("d2", pmid = "1", types = listOf("Retracted Publication"))
        coEvery { retractionService.check(any()) } throws IOException("down")

        run()

        assertTrue(scored.isEmpty())
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue(snapshot().getValue("d2").isRetracted)
    }

    /** A merge that throws leaves the run's papers unchecked, each by its own label, and the run goes on. */
    @Test
    fun `a merge that throws leaves every paper unchecked but its own label, and the run goes on`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1", doi = "10.1/x", types = listOf("Retracted Publication"))
        hold("d2")
        mockkObject(RetractionChecker.Companion)
        every { RetractionChecker.doiKey(any()) } throws IllegalStateException("bmlib")

        run()

        assertTrue(asked.isEmpty())
        assertEquals(listOf("d2"), scored)
        assertTrue(snapshot().getValue("d1").isRetracted)
        assertTrue(snapshot().getValue("d2").isUnchecked)
        assertTrue(workflow.retractionNotice.value!!.endsWith("could not be checked: the check failed."))
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

    /** #726: a snapshot unreadable as a whole is never written over; the run still screens and says so. */
    @Test
    fun `an unreadable snapshot is never written over and the notice says the status was not saved`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1")
        hold("d2")
        answers["1"] = RETRACTED
        snapshotJson = "[\"a newer build's\"]"

        run()

        assertEquals(listOf("d2"), scored)
        assertEquals("[\"a newer build's\"]", snapshotJson)
        coVerify(exactly = 0) { sessionRepository.updateRetractionSnapshot(any(), any()) }
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        val notice = workflow.retractionNotice.value!!
        assertTrue(notice, notice.endsWith(RetractionText.SCREEN_NOT_SAVED))
        // control: a readable snapshot is merged
        assertTrue(RetractionSnapshot.merged("{}", mapOf("d1" to RETRACTED)) != null)
    }

    /** #738: a paper screened again over its unreadable entry keeps the entry, and the run says its status was not saved. */
    @Test
    fun `a new check refused over an unreadable entry is said not saved`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1")
        hold("d2")
        answers["1"] = RETRACTED
        val newer = "{\"d1\": {\"status\": \"withdrawn\", \"checkedAtMs\": $RUN_MS}}"
        snapshotJson = newer

        run()

        assertEquals(listOf("d2"), scored)
        // #737: the newer build's entry is kept as it was; d2's check is added
        assertEquals(setOf("d1"), RetractionSnapshot.unreadIds(snapshotJson))
        assertEquals(setOf("d2"), snapshot().keys)
        val notice = workflow.retractionNotice.value!!
        assertTrue(notice, notice.startsWith("Retraction check: 1 retracted paper left out"))
        assertTrue(notice, notice.endsWith(RetractionText.SCREEN_NOT_SAVED))
    }

    /** #738's control: an unreadable entry for a paper outside the run leaves the run saved. */
    @Test
    fun `an unreadable entry for a paper the run does not screen leaves the run saved`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1")
        hold("d2")
        answers["1"] = RETRACTED
        snapshotJson = "{\"dX\": {\"status\": \"withdrawn\", \"checkedAtMs\": $RUN_MS}}"

        run()

        assertEquals(listOf("d2"), scored)
        assertEquals(setOf("dX"), RetractionSnapshot.unreadIds(snapshotJson))
        assertEquals(setOf("d1", "d2"), snapshot().keys)
        val notice = workflow.retractionNotice.value!!
        assertTrue(notice, notice.startsWith("Retraction check: 1 retracted paper left out"))
        assertFalse(notice, notice.contains(RetractionText.SCREEN_NOT_SAVED))
    }

    /** #726: with nothing left out and every paper checked, the notice is the sentence alone. */
    @Test
    fun `an unreadable snapshot under an all-clear run gives the not-saved sentence alone`() = runTest {
        BmlibFfi.assumeAvailable()
        hold("d1")
        hold("d2")
        answers["1"] = CLEAR
        answers["2"] = CLEAR
        snapshotJson = "\"a newer build's\""

        run()

        assertEquals(listOf("d1", "d2"), scored)
        assertEquals(RetractionText.SCREEN_NOT_SAVED, workflow.retractionNotice.value)
    }

    // ==================== Saved work: a restored session, Check again ====================

    /** A completed session whose run checked d1 (cited) and d2 a day ago and found both clear. */
    private suspend fun restoreCheckedSession() {
        hold("d1")
        hold("d2")
        documents.replaceAll { _, document -> document.copy(relevanceScore = 5) }
        citations += CitationEntity(documentId = "d1", passage = "A passage.")
        snapshotJson = RetractionSnapshot.merged(null, mapOf("d1" to CLEAR.copy(checkedAtMs = RUN_MS), "d2" to CLEAR.copy(checkedAtMs = RUN_MS)))
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
    }

    /** #662: a snapshot recorded but unreadable is said as such, never "never checked". */
    @Test
    fun `a restored session whose snapshot cannot be read says so`() = runTest {
        hold("d1")
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        snapshotJson = null
        workflow.restoreForViewing(session)
        assertEquals("control", "Retraction status never checked", workflow.retractionSavedWork.value?.line)

        snapshotJson = "[1, 2]"
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))

        assertEquals(RetractionText.STATUS_UNREAD, workflow.retractionSavedWork.value?.line)
        assertTrue(asked.isEmpty())

        // one entry this build cannot read, and nothing else to show: unread too
        snapshotJson = """{"d1": {"status": 7}}"""
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        assertEquals(RetractionText.STATUS_UNREAD, workflow.retractionSavedWork.value?.line)
    }

    /** #662's control: a stored check is shown over an unreadable snapshot, as on iOS. */
    @Test
    fun `a restored session with an unreadable snapshot shows a stored check instead`() = runTest {
        hold("d1")
        documents.replaceAll { _, document -> document.copy(relevanceScore = 5) }
        citations += CitationEntity(documentId = "d1", passage = "A passage.")
        rows["pmid:1"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS))
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        snapshotJson = "[1, 2]"
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))

        assertEquals("Retraction status checked 2026-10-18", workflow.retractionSavedWork.value?.line)
    }

    /**
     * #733, the desktop's #727 rule: over a snapshot this build cannot read at
     * all, the line is the scored and cited papers' stored rows, one with none
     * counted unchecked; a failed *Check again* never says the unread record stands.
     */
    @Test
    fun `an unreadable snapshot's line is the run's papers' stored rows`() = runTest {
        hold("d1")
        hold("d2")
        hold("d3")
        documents.replaceAll { id, document -> if (id == "d3") document else document.copy(relevanceScore = 5) }
        citations += CitationEntity(documentId = "d1", passage = "A passage.")
        rows["pmid:1"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS))
        // not scored, not cited: its older row is not the run's
        rows["pmid:3"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS - 86_400_000L))
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        snapshotJson = "[1, 2]"
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))

        assertEquals("Retraction status checked 2026-10-18; 1 paper could not be checked", workflow.retractionSavedWork.value?.line)
        // the badges keep every document's row
        assertEquals("clear", workflow.retractionSavedWork.value?.checks?.get("d3")?.status)

        coEvery { retractionService.check(any()) } throws IOException("down")
        workflow.checkRetractionsAgain()
        assertEquals(
            "Retraction status checked 2026-10-18; 1 paper could not be checked; it could not be checked again",
            workflow.retractionSavedWork.value?.line
        )

        // nothing of the run's stored: "could not be read", and still no record said to stand
        rows.remove("pmid:1")
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        assertEquals(RetractionText.STATUS_UNREAD, workflow.retractionSavedWork.value?.line)
        workflow.checkRetractionsAgain()
        assertEquals(RetractionText.STATUS_UNREAD + "; it could not be checked again", workflow.retractionSavedWork.value?.line)
    }

    /** An unreadable snapshot's session: d1 scored and cited, d2 scored, d4 cited only, d3 neither, with an older row. */
    private suspend fun restoreUnreadSession() {
        listOf("d1", "d2", "d3", "d4").forEach { hold(it) }
        documents.replaceAll { id, document -> if (id == "d1" || id == "d2") document.copy(relevanceScore = 5) else document }
        citations += CitationEntity(documentId = "d1", passage = "A passage.")
        citations += CitationEntity(documentId = "d4", passage = "Another passage.")
        rows["pmid:1"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS))
        rows["pmid:3"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS))
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        snapshotJson = "[1, 2]"
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
    }

    /** #733: a cited paper never scored is the run's; an answered Check again counts only the run's papers. */
    @Test
    fun `an answered Check again over an unreadable snapshot counts only the run's papers`() = runTest {
        restoreUnreadSession()
        assertEquals("Retraction status checked 2026-10-18; 2 papers could not be checked", workflow.retractionSavedWork.value?.line)

        answers["1"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = OUTAGE
        // not the run's: its outage is never "could not be checked again"
        answers["3"] = OUTAGE
        answers["4"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)
        workflow.checkRetractionsAgain()

        assertEquals(
            "Retraction status checked 2026-10-19; 1 paper could not be checked: " +
                RetractionText.uncheckedCauses(listOf(documents.getValue("d2").retractionPaper to OUTAGE), emptySet()).joinToString("; "),
            workflow.retractionSavedWork.value?.line
        )
    }

    /** #733: a Check again that cannot read the store, failed or stopped, never says the unread record stands. */
    @Test
    fun `a Check again that cannot read the store over an unreadable snapshot never says the record stands`() = runTest {
        restoreUnreadSession()
        val line = "Retraction status checked 2026-10-18; 2 papers could not be checked"
        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } throws IOException("disk")
        repeat(2) {
            assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { workflow.checkRetractionsAgain() } }
            assertEquals("$line; it could not be checked again", workflow.retractionSavedWork.value?.line)
        }

        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } answers { documents.values.toList() }
        coEvery { retractionService.check(any()) } coAnswers {
            coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } throws IOException("disk")
            awaitCancellation()
        }
        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.cancelCheckAgain()
        job.join()
        assertEquals("$line; checking again was stopped", workflow.retractionSavedWork.value?.line)
    }

    /** #733: answers stored but not shown keep the unread record's line, and its rule for a later failure. */
    @Test
    fun `answers stored but not shown over an unreadable snapshot keep its line`() = runTest {
        restoreUnreadSession()
        val line = "Retraction status checked 2026-10-18; 2 papers could not be checked"
        coEvery { retractionService.check(any()) } throws IOException("down")
        workflow.checkRetractionsAgain()
        assertEquals("$line; it could not be checked again", workflow.retractionSavedWork.value?.line)

        coEvery { retractionService.check(any()) } coAnswers {
            firstArg<List<RetractionPaper>>().associateWith { CLEAR }
        }
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } throws IOException("disk")
        workflow.checkRetractionsAgain()

        assertEquals(line + RetractionText.STORED_CHECKS_UNREAD, workflow.retractionSavedWork.value?.line)
        assertTrue(workflow.retractionSavedWork.value!!.unreadRecord)
    }

    /** #662: the report written over an unreadable snapshot says so in its methods. */
    @Test
    fun `a report over an unreadable snapshot says its retraction status could not be read`() = runTest {
        hold("d1")
        documents["d1"] = documents.getValue("d1").copy(relevanceScore = 5)
        snapshotJson = "[1, 2]"

        run()

        val report = reports.single()
        assertTrue(report, report.contains("- **Retraction Check:** ${RetractionText.STATUS_UNREAD}"))
        assertFalse(report, report.startsWith("> **Retraction check:**"))
    }

    @Test
    fun `a report from a session before the check has no retraction line`() = runTest {
        hold("d1")
        documents["d1"] = documents.getValue("d1").copy(relevanceScore = 5)

        run()

        assertFalse(reports.single(), reports.single().contains("Retraction Check:"))
    }

    @Test
    fun `a restored session says when its papers were checked, asking nothing`() = runTest {
        restoreCheckedSession()

        assertEquals("Retraction status checked 2026-10-18", workflow.retractionSavedWork.value?.line)
        assertNull(workflow.retractionSavedWork.value?.warning)
        assertTrue(asked.isEmpty())
    }

    /** #653's scenario: the warning and the badge read the one row another session wrote. */
    @Test
    fun `a restored session warns of a cited paper another session found retracted since, and badges it`() = runTest {
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS))
        rows["pmid:2"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS))

        restoreCheckedSession()

        val warning = workflow.retractionSavedWork.value?.warning!!
        assertTrue(warning, warning.startsWith("Since this report was written, 1 paper this report cites has a retraction warning:\n• Study d1: Retracted"))
        assertTrue("the badge reads the same row", workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertTrue("a paper not cited is badged, never warned of", workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d2").isRetracted)
        assertTrue(asked.isEmpty())
    }

    @Test
    fun `stored checks that cannot be read say so on a restored session, and the run's checks stand`() = runTest {
        coEvery { retractionService.storedChecks(any()) } throws IOException("disk")

        restoreCheckedSession()

        assertEquals("Retraction status checked 2026-10-18; later checks could not be read", workflow.retractionSavedWork.value?.line)
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isClear)
    }

    @Test
    fun `Check again stores each paper's answer and warns, never rewriting the run's snapshot`() = runTest {
        restoreCheckedSession()
        val runSnapshot = snapshotJson
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        assertEquals(runSnapshot, snapshotJson)
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertEquals("both rechecked a day later", "Retraction status checked 2026-10-19", workflow.retractionSavedWork.value?.line)
        assertFalse(workflow.isCheckingRetractionsAgain.value)
        coVerify(exactly = 0) { sessionRepository.updateRetractionSnapshot(any(), any()) }
    }

    /** #671 on Check again: one check per paper, from every document's evidence. */
    @Test
    fun `Check again checks a paper two documents share once, from both documents' evidence`() = runTest {
        restoreCheckedSession()
        // d1, first, knows less, so its own paper alone would not do
        hold("d3", pmid = "1", types = listOf("Journal Article"))
        documents["d3"] = documents.getValue("d3").copy(relevanceScore = 5)
        // Crossref is down; only a check that sees d3's record finds the retraction
        coEvery { retractionService.check(any()) } coAnswers {
            val papers = firstArg<List<RetractionPaper>>()
            asked += papers
            val retracted = RETRACTED.copy(unanswered = listOf("crossref"), checkedAtMs = RUN_MS + DAY_MS)
            papers.associateWith { if (it.publicationTypes.isEmpty()) OUTAGE else retracted }
        }

        workflow.checkRetractionsAgain()

        assertEquals(RetractionPaper(null, "1", listOf("Journal Article")), asked.single().single { it.pmid == "1" })
        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d3").isRetracted)
    }

    /** A merge that throws an Exception still warns by each document's own label (the catch's `papers`). */
    @Test
    fun `a Check again whose merge throws still warns by the label`() = runTest {
        BmlibFfi.assumeAvailable()
        restoreCheckedSession()
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Retracted Publication\"]")
        documents["d2"] = documents.getValue("d2").copy(doi = "10.1/x")
        mockkObject(RetractionChecker.Companion)
        every { RetractionChecker.doiKey(any()) } throws IllegalStateException("bmlib")

        workflow.checkRetractionsAgain()

        assertTrue(asked.isEmpty())
        val warning = workflow.retractionSavedWork.value?.warning
        assertTrue("$warning", warning!!.contains("• Study d1: Retracted"))
        // the saved rows' keys call bmlib as well, so they are said to be unread
        val line = workflow.retractionSavedWork.value?.line
        assertTrue("$line", line!!.contains(RetractionText.CHECK_AGAIN_FAILED))
        assertTrue("nothing is stored: $rows", rows.isEmpty())
    }

    @Test
    fun `a failing Check again stores nothing and says the run's record stands`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.check(any()) } throws IOException("offline")

        workflow.checkRetractionsAgain()

        assertEquals(
            "Retraction status checked 2026-10-18; it could not be checked again, so this is still the run's record",
            workflow.retractionSavedWork.value?.line
        )
        assertTrue(rows.isEmpty())
    }

    /** #673: a label that arrived after the run still warns when Check again fails, though nothing is stored. */
    @Test
    fun `a failing Check again still warns by the label`() = runTest {
        BmlibFfi.assumeAvailable()
        restoreCheckedSession()
        assertNull(workflow.retractionSavedWork.value?.warning)
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Retracted Publication\"]")
        coEvery { retractionService.check(any()) } throws IOException("offline")

        workflow.checkRetractionsAgain()

        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(workflow.retractionSavedWork.value?.line!!.endsWith(RetractionText.CHECK_AGAIN_FAILED))
        assertTrue("nothing is stored", rows.isEmpty())
        // control: without the label, nothing to warn of
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Journal Article\"]")
        workflow.checkRetractionsAgain()
        assertNull(workflow.retractionSavedWork.value?.warning)
    }

    /** #673: a stored retraction keeps its own notice over the label, and a stored concern is never hidden by a failed check. */
    @Test
    fun `a failing Check again keeps what is stored`() = runTest {
        BmlibFfi.assumeAvailable()
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS))
        rows["pmid:2"] = PaperRetractionCheck.encode(CONCERN.copy(checkedAtMs = RUN_MS + DAY_MS))
        restoreCheckedSession()
        citations += CitationEntity(documentId = "d2", passage = "A passage.")
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Retracted Publication\"]")
        coEvery { retractionService.check(any()) } throws IOException("offline")

        workflow.checkRetractionsAgain()

        val warning = workflow.retractionSavedWork.value?.warning!!
        assertTrue(warning, warning.contains("• Study d1: Retracted on 2026-03-09 (notice 10.9/n)"))
        assertFalse(warning, warning.contains("PubMed's label"))
        assertTrue(warning, warning.contains("• Study d2: Expression of concern"))
    }

    /** #673, #720: an answered check whose rows cannot be read still warns of and badges what it found, storing nothing. */
    @Test
    fun `a Check again whose rows cannot be read still warns of what it found`() = runTest {
        BmlibFfi.assumeAvailable()
        restoreCheckedSession()
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        coEvery { retractionService.storedChecks(any()) } throws IOException("database locked")

        workflow.checkRetractionsAgain()

        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.line!!.endsWith(RetractionText.CHECK_AGAIN_NOT_SAVED + RetractionText.STORED_CHECKS_UNREAD))
        coVerify(exactly = 0) { retractionService.store(any(), any()) }
    }

    @Test
    fun `a Check again that cannot read the store throws and never leaves the checking line up`() = runTest {
        restoreCheckedSession()
        coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } throws IOException("disk")

        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { workflow.checkRetractionsAgain() } }

        assertEquals(
            "Retraction status checked 2026-10-18; it could not be checked again, so this is still the run's record",
            workflow.retractionSavedWork.value?.line
        )
        assertFalse(workflow.isCheckingRetractionsAgain.value)
    }

    /** #654 item 1: no Retraction Watch copy (mobile data, a fresh install) is named, not left a bare count. */
    @Test
    fun `Check again names why papers stay unchecked`() = runTest {
        hold("d1")
        snapshotJson = RetractionSnapshot.merged(null, mapOf("d1" to NO_EXPORT.copy(checkedAtMs = RUN_MS)))
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        answers["1"] = NO_EXPORT.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        assertEquals(
            "Retraction status could not be checked: the Retraction Watch data could not be used (no up-to-date copy is on this device)",
            workflow.retractionSavedWork.value?.line
        )
    }

    /** A run's snapshot: d1 clear, d2's entry one this build cannot read. */
    private fun snapshotWithAnUnreadableEntry(): String =
        RetractionSnapshot.merged(null, mapOf("d1" to CLEAR.copy(checkedAtMs = RUN_MS)))!!
            .removeSuffix("}").plus(", \"d2\": {\"status\": 7}}").also {
                assertEquals(setOf("d2"), RetractionSnapshot.unreadIds(it))
            }

    /** #727: a scored paper whose own entry cannot be read is "could not be read", never "could not be checked". */
    @Test
    fun `a scored paper's unreadable entry is counted unread on the line, never unchecked`() = runTest {
        hold("d1")
        hold("d2")
        documents.replaceAll { _, document -> document.copy(relevanceScore = 5) }
        // its stored row is not the run's record either
        rows["pmid:2"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS))
        snapshotJson = snapshotWithAnUnreadableEntry()
        session = session.copy(workflowStep = WorkflowStep.COMPLETED)
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))

        assertEquals(
            "Retraction status checked 2026-10-18; 1 paper's record could not be read",
            workflow.retractionSavedWork.value?.line
        )
        // its badge keeps its row
        assertNotNull(workflow.retractionSavedWork.value?.checks?.get("d2"))
    }

    /** #727: the report written again counts it the same way, in its notice and methods line. */
    @Test
    fun `a report counts a scored paper's unreadable entry as unread`() = runTest {
        hold("d1")
        hold("d2")
        documents.replaceAll { _, document -> document.copy(relevanceScore = 5) }
        snapshotJson = snapshotWithAnUnreadableEntry()

        run()

        val report = reports.single()
        assertTrue(report, report.startsWith("> **Retraction check:** 1 paper's retraction record could not be read."))
        assertTrue(report, report.contains("- **Retraction Check:** Retraction status checked 2026-10-18; 1 paper's record could not be read"))
        assertFalse(report, report.contains("could not be checked"))
    }

    /** #600: a later screen never writes over an entry this build cannot read. */
    @Test
    fun `an unreadable entry is never written over`() {
        val stored = snapshotWithAnUnreadableEntry()
        val merged = RetractionSnapshot.merged(stored, mapOf("d2" to CLEAR, "d3" to CLEAR))!!
        assertEquals(setOf("d2"), RetractionSnapshot.unreadIds(merged))
        assertEquals(setOf("d1", "d3"), RetractionSnapshot.read(merged).keys)
    }

    /** #684: a session older than the check, given a snapshot by Find More Evidence. */
    @Test
    fun `Check again counts a scored paper the run has no row for`() = runTest {
        hold("d1")
        hold("d2")
        documents.replaceAll { _, document -> document.copy(relevanceScore = 5) }
        hold("d3") // never scored: its outage is not the run's
        snapshotJson = RetractionSnapshot.merged(null, mapOf("d2" to CLEAR.copy(checkedAtMs = RUN_MS)))
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        // #685: before Check again, the scored paper with no row is already counted
        assertEquals("Retraction status checked 2026-10-18; 1 paper could not be checked", workflow.retractionSavedWork.value?.line)
        answers["1"] = NO_EXPORT.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["3"] = NO_EXPORT.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        val line = workflow.retractionSavedWork.value?.line!!
        assertTrue(line, line.startsWith("Retraction status checked 2026-10-19; 1 paper could not be checked"))
    }

    /** #660, #668: a decided row kept over an unchecked answer: its cause follows the again count. */
    @Test
    fun `Check again names only the causes of papers whose row stays unchecked`() = runTest {
        hold("d1")
        hold("d2")
        snapshotJson = RetractionSnapshot.merged(
            null, mapOf("d1" to NO_EXPORT.copy(checkedAtMs = RUN_MS), "d2" to CLEAR.copy(checkedAtMs = RUN_MS))
        )
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        answers["1"] = NO_EXPORT.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = OUTAGE.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        assertEquals(
            "Retraction status checked 2026-10-18; 1 paper could not be checked: the Retraction Watch data could not be used" +
                " (no up-to-date copy is on this device); 1 paper could not be checked again: Crossref could not be used (HTTP 503)",
            workflow.retractionSavedWork.value?.line
        )
    }

    /** #660: a run's paper no longer held is never asked; the others' causes would claim it too. */
    @Test
    fun `Check again names no cause when an unchecked paper was not reached`() = runTest {
        hold("d1")
        snapshotJson = RetractionSnapshot.merged(
            null, mapOf("d1" to NO_EXPORT.copy(checkedAtMs = RUN_MS), "d2" to NO_EXPORT.copy(checkedAtMs = RUN_MS))
        )
        workflow.restoreForViewing(session.copy(retractionSnapshotJson = snapshotJson))
        answers["1"] = NO_EXPORT.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        assertEquals("Retraction status could not be checked", workflow.retractionSavedWork.value?.line)
    }

    @Test
    fun `a decided paper Check again cannot reach keeps its record and is counted`() = runTest {
        restoreCheckedSession()
        rows["pmid:1"] = PaperRetractionCheck.encode(CLEAR.copy(checkedAtMs = RUN_MS))
        answers["1"] = OUTAGE.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)

        workflow.checkRetractionsAgain()

        assertEquals(
            "Retraction status checked 2026-10-18; 1 paper could not be checked again: Crossref could not be used (HTTP 503)",
            workflow.retractionSavedWork.value?.line
        )
        assertTrue("an outage is not knowledge", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isClear)
    }

    /** #654 item 2: Cancel reaches Check again, and leaves the completed session's step alone. */
    @Test
    fun `Cancel stops Check again, storing nothing`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.check(any()) } coAnswers { awaitCancellation() }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        assertTrue(workflow.isCheckingRetractionsAgain.value)
        workflow.cancelCheckAgain()
        job.join()

        assertTrue(job.isCancelled)
        assertTrue(rows.isEmpty())
        // the reader stopped it: worded as a stop, never a failure (#663 item 2)
        assertTrue(workflow.retractionSavedWork.value?.line!!.endsWith(RetractionText.CHECK_AGAIN_STOPPED))
        assertFalse(workflow.isCheckingRetractionsAgain.value)
        coVerify(exactly = 0) { sessionRepository.updateWorkflowStep(any(), any()) }
    }

    /** #675 item 1: a cancelled Check again still warns by the label, as a failed one does, and stores nothing. */
    @Test
    fun `a cancelled Check again still warns by the label`() = runTest {
        BmlibFfi.assumeAvailable()
        restoreCheckedSession()
        assertNull(workflow.retractionSavedWork.value?.warning)
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Retracted Publication\"]")
        coEvery { retractionService.check(any()) } coAnswers { awaitCancellation() }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.cancelCheckAgain()
        job.join()

        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(workflow.retractionSavedWork.value?.line!!.endsWith(RetractionText.CHECK_AGAIN_STOPPED))
        assertTrue("nothing is stored", rows.isEmpty())
    }

    /** #675: a merge that throws on the stop still leaves each document's own label to warn. */
    @Test
    fun `a cancelled Check again whose merge throws still warns by the label`() = runTest {
        BmlibFfi.assumeAvailable()
        restoreCheckedSession()
        documents["d1"] = documents.getValue("d1").copy(publicationTypesJson = "[\"Retracted Publication\"]")
        documents["d2"] = documents.getValue("d2").copy(doi = "10.1/x")
        var stopping = false
        mockkObject(RetractionChecker.Companion)
        every { RetractionChecker.doiKey(any()) } answers {
            if (stopping) throw IllegalStateException("bmlib") else callOriginal()
        }
        coEvery { retractionService.check(any()) } coAnswers { awaitCancellation() }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        stopping = true
        workflow.cancelCheckAgain()
        job.join()

        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(workflow.retractionSavedWork.value?.line!!.contains(RetractionText.CHECK_AGAIN_STOPPED))
        assertTrue("nothing is stored", rows.isEmpty())
    }

    /** #663: a Cancel once the answers are being stored is too late to stop them: never "still the run's record". */
    @Test
    fun `a Cancel while Check again stores its answers never calls them the run's record`() = runTest {
        restoreCheckedSession()
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        val storing = CompletableDeferred<Unit>()
        coEvery { retractionService.store(any(), any()) } coAnswers {
            storing.await()
            firstArg<Map<String, PaperRetractionCheck>>().forEach { (key, check) -> rows[key] = PaperRetractionCheck.encode(check) }
        }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.cancelCheckAgain()
        storing.complete(Unit)
        job.join()

        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        val line = workflow.retractionSavedWork.value?.line!!
        assertFalse(line, line.contains(RetractionText.CHECK_AGAIN_STOPPED))
        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
    }

    @Test
    fun `a run started after a restore drops the saved-work line`() = runTest {
        restoreCheckedSession()
        hold("d3")

        run()

        assertNull(workflow.retractionSavedWork.value)
    }

    /** A store that fails never hides what Check again found: the reader sees it, and that it was not saved. */
    @Test
    fun `a Check again whose answers cannot be stored still shows and warns of them`() = runTest {
        restoreCheckedSession()
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        answers["2"] = CLEAR.copy(checkedAtMs = RUN_MS + DAY_MS)
        coEvery { retractionService.store(any(), any()) } throws IOException("disk full")

        workflow.checkRetractionsAgain()

        assertTrue(rows.isEmpty())
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertEquals(
            "Retraction status checked 2026-10-19; the new status could not be saved with this run",
            workflow.retractionSavedWork.value?.line
        )
    }

    /** #663 item 1: stored answers are no longer the run's record, though they could not be shown. */
    @Test
    fun `a Check again that stores its answers but cannot show them says the new checks went unread`() = runTest {
        restoreCheckedSession()
        val shown = workflow.retractionSavedWork.value!!
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } throws IOException("disk")

        workflow.checkRetractionsAgain()

        assertTrue("stored", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        val savedWork = workflow.retractionSavedWork.value!!
        assertEquals("Retraction status checked 2026-10-18" + RetractionText.STORED_CHECKS_UNREAD, savedWork.line)
        // the earlier warning stays up: never a blank that could hide a retraction
        assertEquals(shown.warning, savedWork.warning)
        assertTrue("what it found is badged though it could not be read back", savedWork.checks.getValue("d1").isRetracted)
        assertFalse(workflow.isCheckingRetractionsAgain.value)
    }

    /** An earlier Check again's "not saved" is no longer so once this one stores its answers. */
    @Test
    fun `a Check again that stores its answers drops an earlier one's not saved, though it cannot show them`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.store(any(), any()) } throws IOException("disk full")
        workflow.checkRetractionsAgain()
        assertTrue(workflow.retractionSavedWork.value!!.line.endsWith(RetractionText.CHECK_AGAIN_NOT_SAVED))
        coEvery { retractionService.store(any(), any()) } answers {
            val keepExisting = secondArg<Boolean>()
            firstArg<Map<String, PaperRetractionCheck>>().forEach { (key, check) ->
                if (!keepExisting || key !in rows) rows[key] = PaperRetractionCheck.encode(check)
            }
        }
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } throws IOException("disk")

        workflow.checkRetractionsAgain()

        val line = workflow.retractionSavedWork.value!!.line
        assertFalse(line, line.contains(RetractionText.CHECK_AGAIN_NOT_SAVED))
        assertTrue(line, line.endsWith(RetractionText.STORED_CHECKS_UNREAD))
    }

    /** Control for the above: answers not stored leave the run's record, so the failure still says so and throws. */
    @Test
    fun `a Check again that neither stores nor shows its answers says the run's record stands`() = runTest {
        restoreCheckedSession()
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        coEvery { retractionService.store(any(), any()) } throws IOException("disk full")
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } throws IOException("disk")

        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { workflow.checkRetractionsAgain() } }

        assertTrue(rows.isEmpty())
        assertEquals(
            "Retraction status checked 2026-10-18" + RetractionText.CHECK_AGAIN_FAILED,
            workflow.retractionSavedWork.value?.line
        )
    }

    /** #651's shape: a retraction another session stored stands over Check again's outage, and is still warned of. */
    @Test
    fun `a stored retraction stands over Check again's outage and is still warned of`() = runTest {
        rows["pmid:1"] = PaperRetractionCheck.encode(RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS))
        restoreCheckedSession()
        answers["1"] = OUTAGE.copy(checkedAtMs = RUN_MS + 2 * DAY_MS)

        workflow.checkRetractionsAgain()

        assertTrue(PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isRetracted)
        assertTrue(workflow.retractionSavedWork.value?.warning!!.contains("• Study d1: Retracted"))
        assertTrue(
            workflow.retractionSavedWork.value?.line!!.endsWith("; 1 paper could not be checked again: Crossref could not be used (HTTP 503)")
        )
    }

    @Test
    fun `Check again runs one at a time`() = runTest {
        restoreCheckedSession()
        val gate = CompletableDeferred<Unit>()
        coEvery { retractionService.check(any()) } coAnswers {
            asked += firstArg<List<RetractionPaper>>()
            gate.await()
            firstArg<List<RetractionPaper>>().associateWith { CLEAR }
        }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.checkRetractionsAgain()
        gate.complete(Unit)
        job.join()

        assertEquals(1, asked.size)
    }

    /** Check again's own Cancel never takes over the workflow's: once it ends, Cancel reaches the session again. */
    @Test
    fun `Cancel after a Check again reaches the session`() = runTest {
        restoreCheckedSession()
        workflow.checkRetractionsAgain()

        workflow.cancel()

        coVerify { sessionRepository.updateWorkflowStep(SESSION_ID, WorkflowStep.AWAITING_USER_DECISION) }
    }

    /** A screen begun meanwhile (here a new question) is never written by the Check again it replaced. */
    @Test
    fun `a Check again whose screen was replaced stores its answers but never shows them`() = runTest {
        restoreCheckedSession()
        answers["1"] = RETRACTED.copy(checkedAtMs = RUN_MS + DAY_MS)
        val gate = CompletableDeferred<Unit>()
        coEvery { retractionService.store(any(), any()) } coAnswers {
            gate.await()
            firstArg<Map<String, PaperRetractionCheck>>().forEach { (key, check) -> rows[key] = PaperRetractionCheck.encode(check) }
        }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.reset()
        gate.complete(Unit)
        job.join()

        assertTrue("its answers were in: they are stored whole", PaperRetractionCheck.decode(rows.getValue("pmid:1"))!!.isRetracted)
        assertNull(workflow.retractionSavedWork.value)
        assertFalse(workflow.isCheckingRetractionsAgain.value)
    }

    @Test
    fun `a new screen cancels a Check again still asking`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.check(any()) } coAnswers { awaitCancellation() }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.reset()
        job.join()

        assertTrue(job.isCancelled)
        assertTrue(rows.isEmpty())
        assertNull("the cancelled check never writes the new screen", workflow.retractionSavedWork.value?.line)
    }

    @Test
    fun `a cancelled Check again that cannot read the store never leaves the checking line up`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.check(any()) } coAnswers {
            coEvery { documentRepository.getDocumentsBySessionSync(SESSION_ID) } throws IOException("disk")
            awaitCancellation()
        }

        val job = launch { workflow.checkRetractionsAgain() }
        runCurrent()
        workflow.cancelCheckAgain()
        job.join()

        assertEquals(
            "Retraction status checked 2026-10-18; checking again was stopped, so this is still the run's record",
            workflow.retractionSavedWork.value?.line
        )
    }

    @Test
    fun `a restore that cannot read its session's documents says the status could not be read`() = runTest {
        hold("d1")
        coEvery { documentRepository.getCitationsBySessionSync(SESSION_ID) } throws IOException("disk")

        workflow.restoreForViewing(session)

        assertEquals("Retraction status could not be read", workflow.retractionSavedWork.value?.line)
        // nothing of the run's record was read: a failed Check again never says it stands (#733)
        coEvery { retractionService.check(any()) } throws IOException("down")
        assertThrows(IOException::class.java) { kotlinx.coroutines.runBlocking { workflow.checkRetractionsAgain() } }
        assertEquals("Retraction status could not be read; it could not be checked again", workflow.retractionSavedWork.value?.line)
    }

    @Test
    fun `a stored row that does not decode is said unread on a restored session`() = runTest {
        rows["pmid:1"] = "{not json"

        restoreCheckedSession()

        assertEquals("Retraction status checked 2026-10-18; later checks could not be read", workflow.retractionSavedWork.value?.line)
        assertTrue("the run's check stands", workflow.retractionSavedWork.value?.checks.orEmpty().getValue("d1").isClear)
    }

    @Test
    fun `a Check again without bmlib's native library says the run's record stands`() = runTest {
        restoreCheckedSession()
        coEvery { retractionService.check(any()) } throws UnsatisfiedLinkError("no bmlib")

        workflow.checkRetractionsAgain()

        assertTrue(workflow.retractionSavedWork.value?.line!!.endsWith("so this is still the run's record"))
        assertTrue(rows.isEmpty())
        assertFalse(workflow.isCheckingRetractionsAgain.value)
    }

    private companion object {
        const val SESSION_ID = "session-retraction"
        const val DAY_MS = 86_400_000L
        const val RUN_MS = 1_792_315_800_000L // 2026-10-18 09:30 UTC
        val CONFIG = WorkflowConfig(smartSearchEnabled = false)
        val NOTICE = StoredRetractionEvidence("retraction_watch_export", "retraction", "2026-03-09", "10.9/n")
        val RETRACTED = PaperRetractionCheck("retracted", NOTICE, checkedAtMs = 1, exportDataAsOf = "2026-10-01")
        val CONCERN = PaperRetractionCheck(
            "concern", NOTICE.copy(kind = "expression_of_concern"), checkedAtMs = 1, exportDataAsOf = "2026-10-01"
        )
        val CLEAR = PaperRetractionCheck("clear", checkedAtMs = 1, exportDataAsOf = "2026-10-01")
        val NO_EXPORT = PaperRetractionCheck("unchecked", unanswered = listOf("retraction_watch_export"), checkedAtMs = 1)
        val OUTAGE = PaperRetractionCheck(
            "unchecked", unanswered = listOf("crossref"), checkedAtMs = 1, exportDataAsOf = "2026-10-01", crossrefFailure = "HTTP 503"
        )
    }
}
