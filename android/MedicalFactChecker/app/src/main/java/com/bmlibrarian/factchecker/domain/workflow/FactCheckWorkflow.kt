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
import com.bmlibrarian.factchecker.domain.transparency.TransparencyJson
import com.bmlibrarian.factchecker.domain.transparency.TransparencyReportMarkdown
import com.bmlibrarian.factchecker.domain.transparency.canAnalyzeTransparency
import com.bmlibrarian.factchecker.domain.transparency.needsTransparencyAnalysis
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.ReportRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.data.repository.UsageRepository
import com.bmlibrarian.factchecker.domain.embedding.EmbeddingService
import com.bmlibrarian.factchecker.domain.model.EuropePMCQueryBuilder
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.NcbiCredentialsUnavailableException
import com.bmlibrarian.factchecker.domain.model.PubMedQueryBuilder
import com.bmlibrarian.factchecker.domain.model.QueryBuilderFactory
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailedException
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.ShortfallQuery
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.ml.HydeGenerator
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Job
import kotlinx.coroutines.currentCoroutineContext
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.coroutineContext

/** Why a session whose record of what its search missed is damaged cannot go on (#252). */
private const val DAMAGED_SESSION_MESSAGE =
    "This session cannot go on: its record of what its search could not retrieve is damaged, " +
        "so a report could not say whether its search was complete."

/**
 * A session's record of what its searches failed to retrieve cannot be read (#252).
 *
 * The session cannot go on: a report it wrote could not say whether its search
 * was complete. The message is for the user; the damaged record is not quoted.
 */
private class DamagedShortfallRecordException : Exception(DAMAGED_SESSION_MESSAGE)

/**
 * Main workflow engine for fact-checking.
 *
 * Orchestrates the entire fact-check process from claim input to evidence
 * report generation. Implements a state machine with progress tracking,
 * budget enforcement, and batch pagination.
 *
 * Features:
 * - State machine with observable state flow
 * - Progress tracking with detailed metrics
 * - Budget enforcement (per-run and monthly limits)
 * - Batch pagination with user decision prompts
 * - Smart search with alternative query generation
 * - Resumable workflow state
 *
 * Mirrors the iOS FactCheckWorkflow for cross-platform consistency.
 */
@Singleton
class FactCheckWorkflow @Inject constructor(
    private val llmService: LLMService,
    private val literatureSearch: LiteratureSearch,
    private val sessionRepository: SessionRepository,
    private val documentRepository: DocumentRepository,
    private val reportRepository: ReportRepository,
    private val usageRepository: UsageRepository,
    private val settingsRepository: SettingsRepository,
    private val parallelScoringService: ParallelScoringService,
    private val parallelCitationService: ParallelCitationService,
    private val checkpointManager: CheckpointManager,
    private val errorPersistenceManager: ErrorPersistenceManager,
    private val embeddingService: EmbeddingService,
    private val hydeGenerator: HydeGenerator,
    private val transparencyRunner: TransparencyAnalysisRunner
) {

    companion object {
        private const val TAG = "FactCheckWorkflow"

        /** Why more evidence is refused for a session whose record of what its search missed is damaged. */
        private const val DAMAGED_RECORD_REFUSAL_MESSAGE =
            "More evidence cannot be added to this session: its record of what its search could not " +
                "retrieve is damaged, so a new report could not say whether its search was complete."

        /** Shown when the model could not be asked for alternative queries; smart search stays available. */
        private const val SMART_SEARCH_UNAVAILABLE_MESSAGE =
            "Alternative searches could not be run: the language model could not propose alternative " +
                "queries. Check the model and its API key in Settings, then try again."

        /** Shown when every answer the model gave, retries included, held no usable query. */
        private const val SMART_SEARCH_UNUSABLE_MESSAGE =
            "Alternative searches could not be run: the language model's answers held no search query " +
                "that could be used. Another model, chosen in Settings, may do better."
    }

    // ==================== Observable State ====================

    /** Current workflow state. */
    private val _state = MutableStateFlow<WorkflowState>(WorkflowState.Idle)
    val state: StateFlow<WorkflowState> = _state.asStateFlow()

    /** Progress tracking for UI display. */
    private val _progress = MutableStateFlow(WorkflowProgress.idle())
    val progress: StateFlow<WorkflowProgress> = _progress.asStateFlow()

    /** Current session ID for document observation. Emits immediately when session is created. */
    private val _currentSessionId = MutableStateFlow<String?>(null)
    val currentSessionId: StateFlow<String?> = _currentSessionId.asStateFlow()

    /**
     * What the current session's searches failed to retrieve (#252); empty when
     * they were complete. Shown as a persistent warning while the session goes on.
     */
    private val _searchShortfalls = MutableStateFlow<List<RetrievalShortfall>>(emptyList())
    val searchShortfalls: StateFlow<List<RetrievalShortfall>> = _searchShortfalls.asStateFlow()

    /**
     * Why a search or smart search could not do what was asked while the session
     * carries on with what it has (#252), or why more evidence was refused, with
     * advice; null when there is nothing to tell.
     */
    private val _searchFailureMessage = MutableStateFlow<String?>(null)
    val searchFailureMessage: StateFlow<String?> = _searchFailureMessage.asStateFlow()

    /**
     * Whether the current session's record of what its searches failed to
     * retrieve is damaged, so whether they were complete cannot be shown (#252).
     */
    private val _searchRecordDamaged = MutableStateFlow(false)
    val searchRecordDamaged: StateFlow<Boolean> = _searchRecordDamaged.asStateFlow()

    // ==================== Current Session ====================

    /** Current active session. */
    private var currentSession: SessionEntity? = null

    /** Current workflow configuration. */
    private var currentConfig: WorkflowConfig? = null

    /** Monthly usage for budget checking. */
    private var monthlyUsageUsd: Double = 0.0

    /** Current workflow job for cancellation support. */
    private var workflowJob: Job? = null

    /** Whether this is a resumed session (for checkpoint handling). */
    private var isResumedSession: Boolean = false

    /**
     * Stored structured query for provider-specific translation.
     *
     * The LLM generates a provider-agnostic StructuredQuery which is then
     * translated to provider-specific syntax (PubMed, Europe PMC) as needed.
     * This mirrors the iOS approach for cross-platform consistency.
     */
    private var structuredQuery: StructuredQuery? = null

    // ==================== Main Entry Points ====================

    /**
     * Start a new fact-check workflow.
     *
     * Creates a new session and runs the complete workflow from claim
     * input through report generation.
     *
     * @param claim The medical claim to fact-check
     * @param config Workflow configuration (uses defaults if not provided)
     * @return The session ID for the created session
     */
    suspend fun startFactCheck(
        claim: String,
        config: WorkflowConfig = WorkflowConfig.default()
    ): String {
        // Validate configuration
        val errors = config.validate()
        if (errors.isNotEmpty()) {
            _state.value = WorkflowState.Failed("Invalid configuration: ${errors.first()}")
            throw IllegalArgumentException(errors.first())
        }

        currentConfig = config
        clearSearchFailureState()

        // Load monthly usage for budget checking
        monthlyUsageUsd = usageRepository.getCurrentMonthSpend()

        // Check monthly budget before starting
        if (monthlyUsageUsd >= config.monthlyBudgetUsd) {
            val error = BudgetError.MonthlyBudgetExceeded(monthlyUsageUsd, config.monthlyBudgetUsd)
            _state.value = WorkflowState.BudgetExceeded(
                message = error.message ?: "Monthly budget exceeded",
                currentCostUsd = monthlyUsageUsd,
                budgetLimitUsd = config.monthlyBudgetUsd,
                isMonthly = true
            )
            throw error
        }

        // Create new session
        val session = sessionRepository.createSession(
            claimText = claim,
            searchProvider = config.searchProvider,
            includePreprints = config.includePreprints
        )
        currentSession = session

        // Emit session ID immediately so UI can start observing documents
        _currentSessionId.value = session.id

        // Update state
        _state.value = WorkflowState.ConvertingQuery(claim)
        updateProgress("Analyzing claim...", WorkflowProgress.basePercentageFor(WorkflowStep.CONVERTING_QUERY))

        runHandlingFailures(session, config) { runWorkflow(session, config) }

        return session.id
    }

    /**
     * Resume an existing session.
     *
     * Continues a workflow from its current step, utilizing any
     * checkpointed progress to skip already-processed documents.
     *
     * @param sessionId Session ID to resume
     * @param config Optional configuration override
     */
    suspend fun resumeSession(
        sessionId: String,
        config: WorkflowConfig = WorkflowConfig.default()
    ) {
        val session = sessionRepository.getSession(sessionId)
            ?: throw IllegalArgumentException("Session not found: $sessionId")

        adoptSession(session)
        currentConfig = config
        monthlyUsageUsd = usageRepository.getCurrentMonthSpend()
        isResumedSession = true  // Enable checkpoint loading
        clearSearchFailureState()

        try {
            runHandlingFailures(session, config) {
                _searchShortfalls.value = requireReadableShortfalls(session)
                runWorkflow(session, config)
            }
        } finally {
            isResumedSession = false
        }
    }

    /**
     * Continue workflow after user approves fetching more documents.
     *
     * A search for more that failures leave with nothing returns to the decision,
     * with the failure shown, rather than ending the session (#252).
     */
    suspend fun continueWithMoreDocuments() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()
        _searchFailureMessage.value = null

        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.SEARCHING_PUBMED)

        // Refresh session to get updated workflow step
        val updatedSession = sessionRepository.getSession(session.id) ?: session
        currentSession = updatedSession

        _state.value = WorkflowState.Searching(
            query = updatedSession.pubmedQuery ?: "",
            provider = config.searchProvider.name,
            batchNumber = updatedSession.currentBatch + 1
        )

        runHandlingFailures(updatedSession, config) {
            // Refused before any search runs or budget is spent
            requireReadableShortfalls(updatedSession)
            runWorkflow(updatedSession, config)
        }
    }

    /**
     * Continue workflow after user declines to fetch more documents.
     */
    suspend fun proceedWithCurrentDocuments() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()
        _searchFailureMessage.value = null

        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.EXTRACTING_CITATIONS)

        // Refresh session to get updated workflow step
        val updatedSession = sessionRepository.getSession(session.id) ?: session
        currentSession = updatedSession

        runHandlingFailures(updatedSession, config) {
            // Refused before citation extraction spends budget on a report that cannot be written
            requireReadableShortfalls(updatedSession)
            runWorkflow(updatedSession, config)
        }
    }

    /**
     * Fetch additional evidence after initial report generation.
     *
     * Allows users to gather more evidence when initial report is incomplete.
     * A search for more that failures leave with nothing, or that cannot be sent
     * because the saved NCBI credentials cannot be read, keeps the session's
     * report as it was and shows why (#252). Smart search stays available to try
     * again when the model could not be asked or its queries failed; it is marked
     * as tried when every answer held no usable query.
     */
    suspend fun fetchMoreEvidence() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()
        _searchFailureMessage.value = null

        _state.value = WorkflowState.FetchingMoreEvidence()
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FETCHING_MORE_EVIDENCE)

        try {
            // Refresh session to get latest state
            val freshSession = sessionRepository.getSession(session.id) ?: session
            currentSession = freshSession

            // A new report could not say whether its search was complete: refuse
            // before any search runs or budget is spent
            if (readableShortfalls(freshSession) == null) {
                keepReportAfterFailedSearchForMore(session, DAMAGED_RECORD_REFUSAL_MESSAGE)
                return
            }

            // Fetch more documents
            if (freshSession.hasMoreDocuments) {
                updateProgress("Fetching more documents...", WorkflowProgress.PROGRESS_EXTRACTION_START)
                val newDocs = searchForDocuments(freshSession, config, isNextBatch = true)

                if (newDocs.isNotEmpty()) {
                    // Score new documents
                    updateProgress("Scoring new documents...", WorkflowProgress.PROGRESS_SCORING_MORE_EVIDENCE)
                    scoreDocuments(newDocs, freshSession.claimText, config)

                    // Extract citations from newly scored relevant documents
                    updateProgress("Extracting citations...", WorkflowProgress.basePercentageFor(WorkflowStep.EXTRACTING_CITATIONS))
                    // Re-fetch the documents to get updated scores, then filter for relevant ones
                    val scoredDocIds = newDocs.map { it.id }.toSet()
                    val relevantDocs = documentRepository.getDocumentsBySessionSync(session.id)
                        .filter { it.id in scoredDocIds }
                        .filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }

                    // Fetch citation counts before filtering (suspend function can't be called in filter lambda)
                    val citationCounts = relevantDocs.associateWith { doc ->
                        documentRepository.getCitationCountForDocument(doc.id)
                    }
                    val docsNeedingCitations = relevantDocs.filter { citationCounts[it] == 0 }

                    extractCitations(docsNeedingCitations, freshSession.claimText, session.id, config)
                }
            } else if (!freshSession.smartSearchEnabled && config.smartSearchEnabled) {
                // Pagination exhausted but smart search not tried — try alternative queries
                updateProgress("Trying alternative search strategies...", WorkflowProgress.PROGRESS_SEARCHING_START)
                val smartSearch = when (val outcome = executeSmartSearch(freshSession, config)) {
                    SmartSearchOutcome.Unavailable -> {
                        keepReportAfterFailedSearchForMore(session, SMART_SEARCH_UNAVAILABLE_MESSAGE)
                        return
                    }
                    SmartSearchOutcome.Unusable -> {
                        keepReportAfterFailedSearchForMore(session, SMART_SEARCH_UNUSABLE_MESSAGE)
                        return
                    }
                    is SmartSearchOutcome.Ran -> outcome
                }
                if (smartSearch.newDocuments == 0 && smartSearch.unrecordedShortfalls.isNotEmpty()) {
                    // Nothing new, and something failed: let the user try smart search again
                    sessionRepository.updateSmartSearchState(
                        sessionId = session.id,
                        enabled = false,
                        queriesJson = null,
                        fetchedPmids = null
                    )
                    throw SearchFailedException(smartSearch.unrecordedShortfalls)
                }
                recordShortfalls(session.id, smartSearch.unrecordedShortfalls)

                // Extract citations from any new relevant documents found by smart search
                val allRelevantDocs = documentRepository.getDocumentsBySessionSync(session.id)
                    .filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }
                val citationCounts = allRelevantDocs.associateWith { doc ->
                    documentRepository.getCitationCountForDocument(doc.id)
                }
                val docsNeedingCitations = allRelevantDocs.filter { citationCounts[it] == 0 }
                if (docsNeedingCitations.isNotEmpty()) {
                    updateProgress("Extracting citations...", WorkflowProgress.basePercentageFor(WorkflowStep.EXTRACTING_CITATIONS))
                    extractCitations(docsNeedingCitations, freshSession.claimText, session.id, config)
                }
            }

            // Analyse the transparency of documents this batch made relevant
            sessionRepository.updateWorkflowStep(session.id, WorkflowStep.ANALYZING_TRANSPARENCY)
            analyzeTransparency(session.id, config)

            // Regenerate report with all evidence
            sessionRepository.updateWorkflowStep(session.id, WorkflowStep.GENERATING_REPORT)
            _state.value = WorkflowState.GeneratingReport
            updateProgress("Regenerating report...", WorkflowProgress.PROGRESS_REPORT_GENERATION)
            val report = generateReport(session.id, session.claimText, config)

            // Complete
            sessionRepository.updateWorkflowStep(session.id, WorkflowStep.COMPLETED)
            _state.value = WorkflowState.Completed(reportId = report.id)
            updateProgress("Complete", WorkflowProgress.PROGRESS_COMPLETE)

        } catch (e: BudgetError) {
            handleBudgetError(e, session)
        } catch (e: SearchFailedException) {
            Log.w(TAG, "Search for more evidence failed: ${e.message}")
            keepReportAfterFailedSearchForMore(session, SearchFailureReporting.formatSearchFailureMessage(e))
        } catch (e: NcbiCredentialsUnavailableException) {
            keepReportAfterFailedSearchForMore(session, checkNotNull(e.message))
        } catch (e: CancellationException) {
            // A cancelled run is not a failed one: cancel() has already set the
            // state the user chose, which failing the session would overwrite.
            throw e
        } catch (e: Exception) {
            handleWorkflowError(e, session)
        }
    }

    /**
     * Run an entry point's work, turning a failure into the state the user sees.
     *
     * A search that failures leave with nothing, or that cannot be sent because
     * the saved NCBI credentials cannot be read, ends a first search and returns
     * a search for more to the decision ([handleSearchNotRun]); a budget error
     * stops the session; anything else fails it.
     *
     * @param session The session the work is for
     * @param config Workflow configuration
     * @param work The work
     */
    private suspend fun runHandlingFailures(session: SessionEntity, config: WorkflowConfig, work: suspend () -> Unit) {
        try {
            work()
        } catch (e: BudgetError) {
            handleBudgetError(e, session)
        } catch (e: SearchFailedException) {
            Log.w(TAG, "Search failed: ${e.message}")
            handleSearchNotRun(SearchFailureReporting.formatSearchFailureMessage(e), e, session, config)
        } catch (e: NcbiCredentialsUnavailableException) {
            handleSearchNotRun(checkNotNull(e.message), e, session, config)
        } catch (e: CancellationException) {
            // A cancelled run is not a failed one: cancel() has already set the
            // state the user chose, which failing the session would overwrite.
            throw e
        } catch (e: Exception) {
            handleWorkflowError(e, session)
        }
    }

    /**
     * End a request for more evidence that added nothing, keeping the report it had.
     *
     * The report stands on the evidence it was written from; the user is told why
     * nothing was added: a failed search, a search that could not be sent, smart
     * search that could not run, or a record that refuses more evidence.
     *
     * @param session The session
     * @param message What went wrong and what to do about it
     */
    private suspend fun keepReportAfterFailedSearchForMore(session: SessionEntity, message: String) {
        _searchFailureMessage.value = message
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.COMPLETED)
        val report = reportRepository.getReportBySession(session.id)
        _state.value = report?.let { WorkflowState.Completed(reportId = it.id) } ?: WorkflowState.Idle
        updateProgress("Complete", WorkflowProgress.PROGRESS_COMPLETE)
    }

    /**
     * Read a session's record of what its searches missed, if it can be read.
     *
     * @param session The session
     * @return The shortfalls; or null when the record is damaged, which is logged
     *   and shown as a persistent warning
     */
    private fun readableShortfalls(session: SessionEntity): List<RetrievalShortfall>? = try {
        session.retrievalShortfalls()
    } catch (e: IllegalArgumentException) {
        Log.e(TAG, "Session ${session.id} holds a damaged record of its search's shortfalls: ${e.message}")
        _searchRecordDamaged.value = true
        null
    }

    /**
     * Read a session's record of what its searches missed, for work that cannot go on without it.
     *
     * @param session The session
     * @return The shortfalls
     * @throws DamagedShortfallRecordException if the record is damaged, which is
     *   logged and shown as a persistent warning
     */
    private fun requireReadableShortfalls(session: SessionEntity): List<RetrievalShortfall> =
        readableShortfalls(session) ?: throw DamagedShortfallRecordException()

    /**
     * Forget what the last session's searches missed and why a search failed.
     */
    private fun clearSearchFailureState() {
        _searchShortfalls.value = emptyList()
        _searchFailureMessage.value = null
        _searchRecordDamaged.value = false
    }

    /**
     * Make a stored session the current one.
     *
     * The structured query lives in memory only, so another claim's is dropped:
     * it must not page this session.
     *
     * @param session The session
     */
    private fun adoptSession(session: SessionEntity) {
        if (currentSession?.id != session.id) {
            structuredQuery = null
        }
        currentSession = session
    }

    /**
     * Retry failed documents from the error queue.
     *
     * Attempts to re-process documents that previously failed during scoring
     * or citation extraction.
     *
     * @param step The processing step to retry ("scoring" or "citation")
     * @return Number of documents successfully retried
     */
    suspend fun retryFailedDocuments(step: String = ProcessingCheckpointEntity.STEP_SCORING): Int {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()

        val retryableErrors = errorPersistenceManager.getRetryableErrorsByStep(session.id, step)
        if (retryableErrors.isEmpty()) return 0

        val documentIds = retryableErrors.map { it.documentId }.toSet()
        val documents = documentRepository.getDocumentsBySessionSync(session.id)
            .filter { it.id in documentIds }

        if (documents.isEmpty()) return 0

        var successCount = 0
        var successfulIds = emptySet<String>()

        try {
            when (step) {
                ProcessingCheckpointEntity.STEP_SCORING -> {
                    _state.value = WorkflowState.Scoring(0, documents.size)
                    updateProgress("Retrying ${documents.size} failed documents...",
                        WorkflowProgress.PROGRESS_SCORING_START)

                    scoreDocuments(documents, session.claimText, config)

                    // Count successes by checking which documents now have scores
                    val scoringSuccessIds = mutableSetOf<String>()
                    for (doc in documents) {
                        val updatedDoc = documentRepository.getDocument(doc.id)
                        if (updatedDoc?.relevanceScore != null) {
                            scoringSuccessIds.add(doc.id)
                        }
                    }
                    successCount = scoringSuccessIds.size
                    successfulIds = scoringSuccessIds

                    // Remove errors for successfully retried documents
                    errorPersistenceManager.removeErrorsForDocuments(session.id, scoringSuccessIds)
                }

                ProcessingCheckpointEntity.STEP_CITATION -> {
                    _state.value = WorkflowState.ExtractingCitations(0, documents.size)
                    updateProgress("Retrying ${documents.size} failed extractions...",
                        WorkflowProgress.PROGRESS_EXTRACTION_START)

                    extractCitations(documents, session.claimText, session.id, config)

                    // Count successes by checking citation count
                    val citationSuccessIds = mutableSetOf<String>()
                    for (doc in documents) {
                        if (documentRepository.getCitationCountForDocument(doc.id) > 0) {
                            citationSuccessIds.add(doc.id)
                        }
                    }
                    successCount = citationSuccessIds.size
                    successfulIds = citationSuccessIds

                    // Remove errors for successfully retried documents
                    errorPersistenceManager.removeErrorsForDocuments(session.id, citationSuccessIds)
                }
            }

            // Update retry counts for errors that still failed
            retryableErrors.forEach { error ->
                if (error.documentId !in successfulIds) {
                    errorPersistenceManager.markRetried(error.id)
                }
            }

        } catch (e: BudgetError) {
            handleBudgetError(e, session)
        } catch (e: Exception) {
            // Don't fail completely, just return what we succeeded with
        }

        return successCount
    }

    /**
     * Get the count of retryable errors for the current session.
     *
     * @return Number of errors that can be retried
     */
    suspend fun getRetryableErrorCount(): Int {
        val session = currentSession ?: return 0
        return errorPersistenceManager.getRetryableCount(session.id)
    }

    /**
     * Cancel the current workflow.
     *
     * Gracefully cancels the workflow while preserving checkpointed work.
     * The workflow can be resumed later from the last checkpoint.
     *
     * @param preserveProgress If true, keeps the workflow in AWAITING_USER_DECISION
     *                         state so it can be resumed. If false, marks as failed.
     */
    suspend fun cancel(preserveProgress: Boolean = true) {
        // Cancel any running workflow job
        workflowJob?.cancel()
        workflowJob = null

        currentSession?.let { session ->
            if (preserveProgress) {
                // Keep checkpoints and set state to allow resumption
                sessionRepository.updateWorkflowStep(session.id, WorkflowStep.AWAITING_USER_DECISION)
                _state.value = WorkflowState.AwaitingUserDecision(
                    relevantCount = documentRepository.getRelevantCount(
                        session.id,
                        currentConfig?.relevanceThreshold ?: Constants.SCORING_MIN_RELEVANT_SCORE
                    ),
                    targetCount = currentConfig?.targetRelevantDocuments ?: Constants.TARGET_RELEVANT_DOCS,
                    availableCount = 0
                )
            } else {
                // Clear checkpoints and mark as failed
                checkpointManager.deleteCheckpoints(session.id)
                errorPersistenceManager.deleteErrors(session.id)
                sessionRepository.setError(session.id, "Cancelled by user")
                sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FAILED)
                _state.value = WorkflowState.Failed("Cancelled by user")
            }
        }

        if (!preserveProgress) {
            reset()
        }
    }

    /**
     * Reset the workflow to idle state.
     */
    fun reset() {
        workflowJob?.cancel()
        workflowJob = null
        currentSession = null
        currentConfig = null
        isResumedSession = false
        structuredQuery = null
        _currentSessionId.value = null
        clearSearchFailureState()
        _state.value = WorkflowState.Idle
        _progress.value = WorkflowProgress.idle()
    }

    /**
     * Stop showing why a search for more documents failed.
     */
    fun dismissSearchFailure() {
        _searchFailureMessage.value = null
    }

    /**
     * Restore a session for viewing without running the workflow.
     *
     * Loads an existing session so its data (claim, documents, report)
     * can be displayed in the UI, without triggering any new processing.
     * Use this when the user taps a history item to review past results.
     *
     * This mirrors iOS's restoreForViewing() method for cross-platform
     * consistency.
     *
     * @param session The fact-check session to restore for viewing.
     */
    fun restoreForViewing(session: SessionEntity) {
        adoptSession(session)
        currentConfig = WorkflowConfig(
            searchProvider = session.searchProvider,
            includePreprints = session.includePreprints
        )
        isResumedSession = true

        // Emit session ID so UI can observe documents
        _currentSessionId.value = session.id
        clearSearchFailureState()
        _searchShortfalls.value = readableShortfalls(session).orEmpty()

        _state.value = WorkflowState.Idle
        _progress.value = WorkflowProgress.idle()
    }

    // ==================== Workflow Execution ====================

    /**
     * Execute the workflow from the current step.
     */
    private suspend fun runWorkflow(session: SessionEntity, config: WorkflowConfig) {
        var currentStep = session.workflowStep

        // Step 1: Convert claim to query
        if (currentStep == WorkflowStep.IDLE || currentStep == WorkflowStep.CONVERTING_QUERY) {
            _state.value = WorkflowState.ConvertingQuery(session.claimText)
            updateProgress("Converting claim to search query...", WorkflowProgress.basePercentageFor(WorkflowStep.CONVERTING_QUERY))
            checkBudget(session, config)

            val query = convertClaimToQuery(session.claimText, config)
            sessionRepository.updateQuery(session.id, query)
            currentStep = WorkflowStep.SEARCHING_PUBMED
            sessionRepository.updateWorkflowStep(session.id, currentStep)
        }

        // Refresh session data
        var updatedSession = sessionRepository.getSession(session.id) ?: session

        // Step 2: Search for documents
        if (currentStep == WorkflowStep.SEARCHING_PUBMED) {
            val query = updatedSession.pubmedQuery ?: ""
            _state.value = WorkflowState.Searching(
                query = query,
                provider = config.searchProvider.name,
                batchNumber = updatedSession.currentBatch
            )
            updateProgress("Searching for documents...", WorkflowProgress.PROGRESS_SEARCHING_START)

            // A session that holds documents is fetching more: continue its paging
            // rather than asking for the first page again
            val isNextBatch = documentRepository.getDocumentCount(session.id) > 0
            val documents = searchForDocuments(updatedSession, config, isNextBatch)

            if (documents.isEmpty() && documentRepository.getDocumentCount(session.id) == 0) {
                _state.value = WorkflowState.Failed("No documents found for this claim")
                sessionRepository.setError(session.id, "No documents found")
                sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FAILED)
                return
            }

            currentStep = WorkflowStep.SCORING_DOCUMENTS
            sessionRepository.updateWorkflowStep(session.id, currentStep)
        }

        // Refresh session
        updatedSession = sessionRepository.getSession(session.id) ?: session

        // Step 3: Score documents
        if (currentStep == WorkflowStep.SCORING_DOCUMENTS) {
            val unscoredDocs = documentRepository.getUnscoredDocuments(session.id)

            if (unscoredDocs.isNotEmpty()) {
                _state.value = WorkflowState.Scoring(0, unscoredDocs.size)
                updateProgress("Scoring documents...", WorkflowProgress.PROGRESS_SCORING_START)
                scoreDocuments(unscoredDocs, session.claimText, config)
            }

            // Check if we need more documents
            val relevantCount = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)
            val hasMore = updatedSession.hasMoreDocuments &&
                    updatedSession.currentBatch < config.maxBatches

            // Try smart search if enabled and not enough relevant docs
            if (config.smartSearchEnabled && relevantCount < config.smartSearchThreshold &&
                !updatedSession.smartSearchEnabled) {
                when (val smartSearch = executeSmartSearch(updatedSession, config)) {
                    SmartSearchOutcome.Unavailable -> _searchFailureMessage.value = SMART_SEARCH_UNAVAILABLE_MESSAGE
                    SmartSearchOutcome.Unusable -> _searchFailureMessage.value = SMART_SEARCH_UNUSABLE_MESSAGE
                    is SmartSearchOutcome.Ran -> recordShortfalls(session.id, smartSearch.unrecordedShortfalls)
                }
                // Re-check after smart search
                val relevantAfterSmart = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)
                if (relevantAfterSmart >= config.targetRelevantDocuments) {
                    // Smart search found enough — proceed to citations
                    currentStep = WorkflowStep.EXTRACTING_CITATIONS
                    sessionRepository.updateWorkflowStep(session.id, currentStep)
                }
            }

            // Re-check relevant count (may have changed after smart search)
            val currentRelevant = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)

            if (currentRelevant < config.targetRelevantDocuments && hasMore) {
                // Calculate available documents
                val availableCount = calculateAvailableDocuments(updatedSession)

                if (availableCount > 0) {
                    currentStep = WorkflowStep.AWAITING_USER_DECISION
                    sessionRepository.updateWorkflowStep(session.id, currentStep)
                    _state.value = WorkflowState.AwaitingUserDecision(
                        relevantCount = currentRelevant,
                        targetCount = config.targetRelevantDocuments,
                        availableCount = availableCount
                    )
                    updateProgress(
                        "Found $currentRelevant relevant documents. Fetch more?",
                        WorkflowProgress.PROGRESS_AWAITING_USER
                    )
                    return // Wait for user decision
                }
            }

            currentStep = WorkflowStep.EXTRACTING_CITATIONS
            sessionRepository.updateWorkflowStep(session.id, currentStep)
        }

        // Step 4: Extract citations
        if (currentStep == WorkflowStep.EXTRACTING_CITATIONS ||
            currentStep == WorkflowStep.AWAITING_USER_DECISION) {
            sessionRepository.updateWorkflowStep(session.id, WorkflowStep.EXTRACTING_CITATIONS)

            // Get relevant documents without citations yet
            val allRelevantDocs = documentRepository.getDocumentsBySessionSync(session.id)
                .filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }

            // Fetch citation counts before filtering (suspend function can't be called in filter lambda)
            val citationCounts = allRelevantDocs.associateWith { doc ->
                documentRepository.getCitationCountForDocument(doc.id)
            }
            val relevantDocs = allRelevantDocs.filter { citationCounts[it] == 0 }

            if (relevantDocs.isNotEmpty()) {
                _state.value = WorkflowState.ExtractingCitations(0, relevantDocs.size)
                updateProgress("Extracting citations...", WorkflowProgress.PROGRESS_EXTRACTION_START)
                extractCitations(relevantDocs, session.claimText, session.id, config)
            }

            currentStep = WorkflowStep.ANALYZING_TRANSPARENCY
            sessionRepository.updateWorkflowStep(session.id, currentStep)
        }

        // Step 4b: Analyse transparency of relevant documents
        if (currentStep == WorkflowStep.ANALYZING_TRANSPARENCY) {
            analyzeTransparency(session.id, config)

            currentStep = WorkflowStep.GENERATING_REPORT
            sessionRepository.updateWorkflowStep(session.id, currentStep)
        }

        // Step 5: Generate report
        if (currentStep == WorkflowStep.GENERATING_REPORT) {
            _state.value = WorkflowState.GeneratingReport
            updateProgress("Generating evidence report...", WorkflowProgress.PROGRESS_REPORT_GENERATION)

            val report = generateReport(session.id, session.claimText, config)

            currentStep = WorkflowStep.COMPLETED
            sessionRepository.updateWorkflowStep(session.id, currentStep)
            _state.value = WorkflowState.Completed(reportId = report.id)
            updateProgress("Complete", WorkflowProgress.PROGRESS_COMPLETE)
        }
    }

    // ==================== Step Implementations ====================

    /**
     * Convert a medical claim to a PubMed query using the LLM.
     *
     * Stores the structured query for provider-specific translation, mirroring
     * the iOS approach for cross-platform consistency.
     */
    private suspend fun convertClaimToQuery(claim: String, config: WorkflowConfig): String {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()

        val result = llmService.convertToStructuredQuery(
            provider = provider,
            apiKey = apiKey,
            model = model,
            claim = claim
        )

        if (result.isFailure) {
            throw result.exceptionOrNull()
                ?: Exception("Failed to convert claim to query")
        }

        // Record usage (approximate since we don't have token counts from this call)
        recordUsage(
            operation = "query_conversion",
            inputTokens = estimateTokens(claim),
            outputTokens = Constants.LLM_QUERY_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
        )

        // Store structured query for provider-specific translation
        var parsed = result.getOrThrow()

        // Apply user's preprint preference before building query
        parsed = parsed.copy(excludePreprints = !config.includePreprints)
        structuredQuery = parsed

        // Build provider-specific query string
        return QueryBuilderFactory.build(parsed, config.searchProvider)
    }

    /**
     * Search one page of documents from the configured provider(s), and keep what it found.
     *
     * Uses the stored structured query to build provider-specific query strings,
     * ensuring optimal query syntax for each provider. This mirrors the iOS
     * approach for cross-platform consistency.
     *
     * A failed source is not an empty one (#252): what a provider failed to
     * retrieve is recorded on the session, beside the documents the page found.
     * A page that failures leave with nothing fails instead, and then nothing is
     * kept: no documents, no paging, no shortfalls, so asking again asks for the
     * same page.
     *
     * @param session The session to search for
     * @param config Workflow configuration
     * @param isNextBatch False for the search's first page; true to continue its paging
     * @return The documents the page found, saved
     * @throws SearchFailedException if failures left the page with no document
     */
    private suspend fun searchForDocuments(
        session: SessionEntity,
        config: WorkflowConfig,
        isNextBatch: Boolean = false
    ): List<DocumentEntity> {
        // Build provider-specific query from stored structured query, or fall back to session query
        fun getQueryForProvider(provider: SearchProvider): String {
            return structuredQuery?.let { sq ->
                // Apply preprint preference and build provider-specific query
                val withPreprints = sq.copy(excludePreprints = !config.includePreprints)
                QueryBuilderFactory.build(withPreprints, provider)
            } ?: session.pubmedQuery ?: ""
        }

        val outcome = literatureSearch.searchPage(
            SearchPageRequest(
                provider = config.searchProvider,
                pubMedQuery = getQueryForProvider(SearchProvider.PUBMED),
                europePMCQuery = getQueryForProvider(SearchProvider.EUROPE_PMC),
                batchSize = config.batchSize,
                includePreprints = config.includePreprints,
                continuation = if (isNextBatch) {
                    SessionPaging(
                        PubMedPaging(session.pubmedOffset, session.pubmedTotalResults),
                        EuropePMCPaging(session.epmcCursor, session.epmcTotalResults, session.epmcResultsReceived)
                    )
                } else {
                    null
                },
                query = ShortfallQuery.ORIGINAL,
                sessionId = session.id,
                batchNumber = if (isNextBatch) session.currentBatch + 1 else session.currentBatch,
                existingDocumentCount = documentRepository.getDocumentCount(session.id)
            )
        )

        // What is missing, then the documents, then the paging: a failure before the
        // paging moves leaves the page to be asked for again, never skipped unrecorded
        keepFound(session.id, outcome.shortfalls, outcome.documents)
        outcome.pubMedPaging?.let { sessionRepository.updatePubMedPagination(session.id, it.offset, it.totalResults) }
        outcome.europePMCPaging?.let {
            sessionRepository.updateEpmcPagination(session.id, it.cursor, it.totalResults, it.resultsReceived)
        }
        scoreByEmbedding(outcome.documents, session.claimText)
        return outcome.documents
    }

    /**
     * Add what a search failed to retrieve to what the session recorded, and show it.
     *
     * @param sessionId The session
     * @param shortfalls What the search failed to retrieve
     * @throws DamagedShortfallRecordException if the session's stored record is damaged
     * @throws IllegalStateException if the session no longer exists: the loss would go unrecorded
     */
    private suspend fun recordShortfalls(sessionId: String, shortfalls: List<RetrievalShortfall>) {
        if (shortfalls.isEmpty()) return
        Log.w(TAG, "Search incomplete: ${SearchFailureReporting.describeSearchShortfalls(shortfalls)}")
        val session = checkNotNull(sessionRepository.getSession(sessionId)) {
            "Session $sessionId is gone, so what its search could not retrieve cannot be recorded"
        }
        val recorded = SearchFailureReporting.combinedShortfalls(requireReadableShortfalls(session) + shortfalls)
        sessionRepository.updateRetrievalShortfalls(sessionId, recorded)
        _searchShortfalls.value = recorded
    }

    /**
     * Keep what a search found: what it lost first, then its documents.
     *
     * In that order, a failure between the two never leaves documents saved
     * whose search's losses went unrecorded.
     *
     * @param sessionId The session
     * @param shortfalls What the search failed to retrieve
     * @param documents The new documents the search found
     */
    private suspend fun keepFound(sessionId: String, shortfalls: List<RetrievalShortfall>, documents: List<DocumentEntity>) {
        recordShortfalls(sessionId, shortfalls)
        if (documents.isNotEmpty()) {
            documentRepository.saveDocuments(documents)
        }
    }

    /**
     * Score a search's saved documents by embedding, when enabled.
     *
     * @param documents The documents a search found
     * @param claim The claim being fact-checked
     */
    private suspend fun scoreByEmbedding(documents: List<DocumentEntity>, claim: String) {
        if (documents.isNotEmpty() && settingsRepository.isEmbeddingEnabled() && embeddingService.isAvailable) {
            computeEmbeddingScores(documents, claim)
        }
    }

    /**
     * Compute embedding-based similarity scores for documents.
     *
     * Uses on-device ML Kit embeddings to compute semantic similarity
     * between the claim and document abstracts. This provides a fast,
     * free alternative to LLM-based scoring.
     *
     * If HyDE is enabled, generates a hypothetical abstract first for
     * better embedding matching.
     *
     * @param documents List of documents to score
     * @param claim The medical claim being fact-checked
     */
    private suspend fun computeEmbeddingScores(
        documents: List<DocumentEntity>,
        claim: String
    ) {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()
        val session = currentSession ?: return

        // Generate HyDE abstract if enabled for better semantic matching
        val embeddingQuery = if (settingsRepository.isHydeEnabled()) {
            val hydeAbstract = hydeGenerator.generateHypotheticalAbstract(
                claim = claim,
                provider = provider,
                apiKey = apiKey,
                model = model
            )

            if (hydeAbstract != null) {
                // Save HyDE abstract to session
                sessionRepository.updateHydeAbstract(session.id, hydeAbstract)
                Log.i(TAG, "Generated HyDE abstract: ${hydeAbstract.take(100)}...")

                // Record HyDE generation usage
                recordUsage(
                    operation = "hyde_generation",
                    inputTokens = estimateTokens(claim),
                    outputTokens = Constants.LLM_SCORING_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
                )

                hydeAbstract
            } else {
                Log.w(TAG, "HyDE generation failed, using original claim")
                claim
            }
        } else {
            claim
        }

        // Prepare document data for batch processing
        val documentPairs = documents.map { doc ->
            doc.title to doc.abstractText
        }

        // Compute similarity scores in batch using the query (HyDE or original claim)
        val scores = embeddingService.scoreDocuments(embeddingQuery, documentPairs)

        // Update documents with embedding scores
        documents.zip(scores).forEach { (doc, score) ->
            score?.let { rawScore ->
                val normalizedScore = embeddingService.normalizeToRelevanceScale(rawScore)
                documentRepository.updateEmbeddingScore(
                    documentId = doc.id,
                    embeddingScore = rawScore,
                    embeddingScoreNormalized = normalizedScore
                )
            }
        }
    }

    /**
     * Score documents for relevance to the claim using parallel processing.
     *
     * Uses ParallelScoringService for concurrent scoring with configurable
     * concurrency limits. Supports checkpointing for workflow resumption.
     */
    private suspend fun scoreDocuments(
        documents: List<DocumentEntity>,
        claim: String,
        config: WorkflowConfig
    ) {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()
        val session = currentSession ?: return

        // Check budget before starting
        checkBudget(session, config)

        // Convert documents to scoring inputs
        val inputs = documents.map { ScoringInput.fromDocument(it) }

        // Get checkpointed document IDs if resuming
        val checkpointedIds = if (isResumedSession) {
            checkpointManager.getCheckpointedDocumentIds(
                sessionId = session.id,
                step = ProcessingCheckpointEntity.STEP_SCORING
            )
        } else {
            emptySet()
        }

        // Load and apply any checkpointed results
        if (checkpointedIds.isNotEmpty()) {
            val checkpointedResults = checkpointManager.loadScoringCheckpoints(session.id)
            for (result in checkpointedResults) {
                if (result.isSuccess) {
                    documentRepository.updateDocumentScore(
                        documentId = result.documentId,
                        score = result.scoreOrNull ?: 0,
                        rationale = result.rationaleOrNull ?: ""
                    )
                }
            }
        }

        // Score remaining documents with parallel processing
        val results = parallelScoringService.scoreDocumentsWithCheckpoints(
            documents = inputs,
            claim = claim,
            provider = provider,
            apiKey = apiKey,
            model = model,
            checkpointedIds = checkpointedIds,
            maxConcurrent = parallelScoringService.detectConcurrency(provider),
            onProgress = { documentId, completed, total ->
                // Check for cancellation
                if (!coroutineContext.isActive) return@scoreDocumentsWithCheckpoints

                _state.value = WorkflowState.Scoring(completed, total)
                updateProgress(
                    "Scoring document $completed of $total",
                    WorkflowProgress.PROGRESS_SCORING_START +
                            (WorkflowProgress.PROGRESS_SCORING_RANGE * completed / total)
                )
            },
            onResult = { result ->
                // Checkpoint the result
                checkpointManager.saveScoringCheckpoint(session.id, result)

                // Apply result to database
                if (result.isSuccess) {
                    documentRepository.updateDocumentScore(
                        documentId = result.documentId,
                        score = result.scoreOrNull ?: 0,
                        rationale = result.rationaleOrNull ?: ""
                    )
                } else {
                    // Record error for retry functionality
                    errorPersistenceManager.recordScoringError(session.id, result)
                }

                // Record usage
                recordUsage(
                    operation = "scoring",
                    inputTokens = result.inputTokens,
                    outputTokens = result.outputTokens
                )
            }
        )

        // Clean up checkpoints on successful completion
        val successCount = results.count { it.isSuccess }
        val errorCount = results.count { it.isError }

        if (errorCount == 0) {
            // All successful - clear checkpoints
            checkpointManager.deleteCheckpointsByStep(
                sessionId = session.id,
                step = ProcessingCheckpointEntity.STEP_SCORING
            )
        }
    }

    /**
     * Extract citation passages from relevant documents using parallel processing.
     *
     * Uses ParallelCitationService for concurrent extraction with configurable
     * concurrency (auto-detected based on provider: 3 for cloud, 1 for local).
     */
    private suspend fun extractCitations(
        documents: List<DocumentEntity>,
        claim: String,
        sessionId: String,
        config: WorkflowConfig
    ) {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()
        val session = currentSession ?: return

        // Check budget before starting parallel extraction
        checkBudget(session, config)

        // Build CitationInput structs for thread safety
        val inputs = documents.map { CitationInput.fromDocument(it) }

        // Build lookup map for applying results back to entities
        val documentsById = documents.associateBy { it.id }

        val total = documents.size
        _state.value = WorkflowState.ExtractingCitations(0, total)

        // Extract citations in parallel with incremental result handling
        val results = parallelCitationService.extractCitations(
            documents = inputs,
            claim = claim,
            provider = provider,
            apiKey = apiKey,
            model = model,
            onProgress = { _, completed, totalCount ->
                _state.value = WorkflowState.ExtractingCitations(completed, totalCount)
                updateProgress(
                    "Extracting citations $completed/$totalCount",
                    WorkflowProgress.PROGRESS_EXTRACTION_START + (WorkflowProgress.PROGRESS_EXTRACTION_RANGE * completed / totalCount)
                )
            },
            onResult = { result ->
                // Save citations immediately as each document completes
                if (result.isSuccess) {
                    val citations = result.extractionsOrEmpty.map { extraction ->
                        CitationEntity(
                            documentId = result.documentId,
                            passage = extraction.passage,
                            relevanceExplanation = extraction.relevance
                        )
                    }
                    documentRepository.saveCitations(citations)
                }

                // Record usage for all results (success and failure)
                recordUsage(
                    operation = "citation",
                    inputTokens = result.inputTokens,
                    outputTokens = result.outputTokens
                )
            }
        )
    }

    /**
     * Generate the evidence report.
     */
    private suspend fun generateReport(
        sessionId: String,
        claim: String,
        config: WorkflowConfig
    ): com.bmlibrarian.factchecker.data.local.entity.ReportEntity {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()
        val session = currentSession ?: throw IllegalStateException("No active session")

        checkBudget(session, config)

        // What the searches missed goes into the report by code, never left to the LLM (#252)
        val shortfalls = requireReadableShortfalls(sessionRepository.getSession(sessionId) ?: session)

        // Get all citations with their documents
        val citations = documentRepository.getCitationsBySessionSync(sessionId)
        val documents = documentRepository.getDocumentsBySessionSync(sessionId)
        val documentMap = documents.associateBy { it.id }

        // Build citation data for LLM
        val citationData = citations.mapNotNull { citation ->
            val doc = documentMap[citation.documentId] ?: return@mapNotNull null
            LLMService.DocumentCitation(
                title = doc.title,
                passage = citation.passage,
                pmid = doc.pmid,
                authors = doc.authors,
                year = doc.publicationYear,
                documentId = doc.id
            )
        }

        // Handle no citations case
        if (citationData.isEmpty()) {
            val relevantCount = documents.count { (it.relevanceScore ?: 0) >= config.relevanceThreshold }
            return createNoEvidenceReport(sessionId, claim, relevantCount, model, shortfalls)
        }

        val result = llmService.generateReport(
            provider = provider,
            apiKey = apiKey,
            model = model,
            claim = claim,
            citations = citationData
        )

        if (result.isFailure) {
            throw result.exceptionOrNull() ?: Exception("Failed to generate report")
        }

        val generation = result.getOrThrow()

        // Record usage
        recordUsage(
            operation = "report",
            inputTokens = estimateTokens(claim + citationData.joinToString { it.passage }),
            outputTokens = Constants.LLM_REPORT_MAX_TOKENS
        )

        // Build references section
        val relevantDocs = documents.filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }
        val references = buildReferencesSection(relevantDocs)
        val fullReport = ReportText.fullReport(
            generation.report,
            references,
            shortfalls,
            TransparencyReportMarkdown.sections(relevantDocs)
        )

        // Create and save report
        val report = reportRepository.createReport(
            sessionId = sessionId,
            verdict = Verdict.fromString(generation.verdict),
            summary = generation.summary,
            fullReportMarkdown = fullReport,
            footnotes = null,
            modelUsed = model,
            totalDocumentsReviewed = documents.size,
            relevantDocumentsCount = relevantDocs.size,
            citationsCount = citations.size
        )

        return report
    }

    // ==================== Transparency Analysis ====================

    /**
     * Analyse the transparency of every relevant document not yet analysed by
     * the current analyzer.
     *
     * A document's failure is not the run's: it is logged and the report goes
     * ahead. The report names every relevant document left without a readable
     * analysis (`TransparencyReportMarkdown`), which, unlike a transient notice,
     * stays with the report and cannot displace a search notice or be read
     * under the "Search failed" heading that notice card carries.
     *
     * @param sessionId The session
     * @param config Workflow configuration (for the relevance threshold)
     */
    private suspend fun analyzeTransparency(sessionId: String, config: WorkflowConfig) {
        val documents = documentRepository.getDocumentsBySessionSync(sessionId)
            .filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }
            .filter { it.needsTransparencyAnalysis && it.canAnalyzeTransparency }
        if (documents.isEmpty()) return

        documents.forEachIndexed { index, document ->
            currentCoroutineContext().ensureActive()
            _state.value = WorkflowState.AnalyzingTransparency(index, documents.size)
            updateProgress(
                "Analyzing transparency (${index + 1}/${documents.size})...",
                WorkflowProgress.PROGRESS_TRANSPARENCY_START +
                    WorkflowProgress.PROGRESS_TRANSPARENCY_RANGE * index / documents.size
            )
            try {
                val result = transparencyRunner.analyze(document)
                documentRepository.updateTransparency(document.id, TransparencyJson.encode(result))
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Transparency analysis failed for document ${document.id}", e)
            }
        }
    }

    // ==================== Smart Search ====================

    /** What smart search did (#252). */
    private sealed interface SmartSearchOutcome {
        /** The model could not be asked for alternative queries, so none ran; smart search stays available. */
        data object Unavailable : SmartSearchOutcome

        /** Every answer the model gave, retries included, held no usable query; smart search is marked as tried. */
        data object Unusable : SmartSearchOutcome

        /**
         * The alternative queries ran.
         *
         * @property newDocuments How many new documents they found
         * @property unrecordedShortfalls What failed queries lost while no query had
         *   found a new document, each marked as an alternative search's, for the
         *   caller to record or report. Empty once a query found one: every loss is
         *   then recorded with or after the documents.
         */
        data class Ran(val newDocuments: Int, val unrecordedShortfalls: List<RetrievalShortfall>) : SmartSearchOutcome
    }

    /**
     * Execute smart search by generating and trying alternative queries.
     *
     * When the initial search yields insufficient relevant documents, this method
     * asks the LLM to generate 2-3 alternative structured queries and searches
     * with each one, deduplicating by PMID. Mirrors the iOS `executeSmartSearch()`.
     *
     * The model is asked again, up to [Constants.MAX_QUERY_RETRIES] times, while
     * its answer holds no usable query. An alternative query that fails does not
     * end smart search: the next one is still tried (#252). What it lost is kept
     * back while no query has found a new document, so a search for more that
     * finds nothing keeps nothing; once one has, losses are recorded before any
     * later documents are saved.
     *
     * @param session The current session
     * @param config Workflow configuration
     * @return Whether the queries could be generated and, when they ran, what they found and lost
     */
    private suspend fun executeSmartSearch(session: SessionEntity, config: WorkflowConfig): SmartSearchOutcome {
        // Generate alternative queries
        updateProgress("Generating alternative search strategies...", WorkflowProgress.PROGRESS_SEARCHING_START)

        val relevantCount = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)
        val updatedSession = sessionRepository.getSession(session.id) ?: session

        val alternatives = requestAlternativeQueries(updatedSession, config, relevantCount).getOrElse { error ->
            // Not marked as tried, so smart search can be tried again
            Log.e(TAG, "Smart search could not ask for alternative queries (${error.javaClass.simpleName})")
            return SmartSearchOutcome.Unavailable
        }
        if (alternatives.isEmpty()) {
            // Marked as tried, so no later batch asks and pays again
            sessionRepository.updateSmartSearchState(
                sessionId = session.id,
                enabled = true,
                queriesJson = null,
                fetchedPmids = null
            )
            return SmartSearchOutcome.Unusable
        }

        // Track already-fetched PMIDs to avoid duplicates
        val existingDocs = documentRepository.getDocumentsBySessionSync(session.id)
        val fetchedPmids = existingDocs.mapNotNull { it.pmid }.toMutableSet()

        // Store alternatives and mark smart search as enabled
        val alternativesJson = try {
            kotlinx.serialization.json.Json.encodeToString(
                kotlinx.serialization.builtins.ListSerializer(StructuredQuery.serializer()),
                alternatives
            )
        } catch (e: Exception) { null }

        sessionRepository.updateSmartSearchState(
            sessionId = session.id,
            enabled = true,
            queriesJson = alternativesJson,
            fetchedPmids = fetchedPmids.joinToString(",")
        )

        var newDocumentCount = 0
        val unrecordedShortfalls = mutableListOf<RetrievalShortfall>()

        // Execute each alternative query
        for ((index, altQuery) in alternatives.withIndex()) {
            checkBudget(session, config)

            val queryDescription = altQuery.concepts.firstOrNull()?.name ?: "alternative ${index + 1}"
            val searchRange = WorkflowProgress.PROGRESS_SCORING_START - WorkflowProgress.PROGRESS_SEARCHING_START
            updateProgress(
                "Smart search ${index + 1}/${alternatives.size}: $queryDescription...",
                WorkflowProgress.PROGRESS_SEARCHING_START +
                    (searchRange * (index + 1) / (alternatives.size + 1))
            )

            // Build structured query with preprint preference applied
            val altWithPreprints = altQuery.copy(excludePreprints = !config.includePreprints)

            // Search using the appropriate provider
            val newDocs = try {
                executeAlternativeSearch(
                    altStructuredQuery = altWithPreprints,
                    session = updatedSession,
                    config = config,
                    fetchedPmids = fetchedPmids,
                    earlierLosses = unrecordedShortfalls.toList()
                )
            } catch (e: SearchFailedException) {
                Log.w(TAG, "Smart search ${index + 1}/${alternatives.size} failed: ${e.message}")
                if (newDocumentCount > 0) {
                    recordShortfalls(session.id, e.shortfalls)
                } else {
                    unrecordedShortfalls += e.shortfalls
                }
                continue
            }

            if (newDocs.isNotEmpty()) {
                // Recorded with these documents
                unrecordedShortfalls.clear()
                newDocumentCount += newDocs.size
                // Update fetched PMIDs
                newDocs.mapNotNull { it.pmid }.forEach { fetchedPmids.add(it) }
                sessionRepository.updateSmartSearchState(
                    sessionId = session.id,
                    enabled = true,
                    queriesJson = alternativesJson,
                    fetchedPmids = fetchedPmids.joinToString(",")
                )

                // Score new documents
                updateProgress(
                    "Scoring smart search results...",
                    WorkflowProgress.PROGRESS_SCORING_START
                )
                scoreDocuments(newDocs, session.claimText, config)
            }

            // Check if we now have enough relevant documents
            val newRelevantCount = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)
            if (newRelevantCount >= config.targetRelevantDocuments) {
                Log.i(TAG, "Smart search found enough relevant documents ($newRelevantCount)")
                break
            }
        }

        return SmartSearchOutcome.Ran(newDocumentCount, SearchFailureReporting.combinedShortfalls(unrecordedShortfalls))
    }

    /**
     * Ask the model for alternative queries, asking again while its answer holds none that can be used.
     *
     * Each answer is a paid call, so its usage is recorded and the budget checked
     * before asking again; a request that failed reached no model and costs nothing.
     *
     * @param session The current session
     * @param config Workflow configuration
     * @param relevantCount How many relevant documents the session holds
     * @return The queries; an empty list when every answer, retries included, held
     *   none; or a failure when the model could not be asked
     */
    private suspend fun requestAlternativeQueries(
        session: SessionEntity,
        config: WorkflowConfig,
        relevantCount: Int
    ): Result<List<StructuredQuery>> {
        val attempts = Constants.MAX_QUERY_RETRIES + 1
        repeat(attempts) { attempt ->
            checkBudget(session, config)
            val answer = llmService.generateAlternativeQueries(
                provider = getLLMProvider(),
                apiKey = settingsRepository.getLlmApiKey(),
                model = settingsRepository.getLlmModel(),
                claim = session.claimText,
                initialQuery = session.pubmedQuery,
                totalResults = session.pubmedTotalResults + session.epmcTotalResults,
                relevantCount = relevantCount
            )
            val queries = answer.getOrElse { return Result.failure(it) }
            recordUsage(
                operation = "smart_search_query_generation",
                inputTokens = estimateTokens(session.claimText),
                outputTokens = Constants.LLM_QUERY_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
            )
            if (queries.isNotEmpty()) return Result.success(queries)
            Log.w(TAG, "Smart search's answer ${attempt + 1} of $attempts held no usable query")
        }
        return Result.success(emptyList())
    }

    /**
     * Execute a single alternative search query, filtering out already-fetched PMIDs.
     *
     * @param altStructuredQuery The alternative structured query to execute
     * @param session Current session
     * @param config Workflow configuration
     * @param fetchedPmids Set of PMIDs already fetched (for deduplication)
     * @param earlierLosses What earlier alternative queries lost and nobody has
     *   recorded yet; recorded with this search's own losses if it finds documents
     * @return The new documents, saved; what the search and [earlierLosses] failed
     *   to retrieve is recorded on the session before them
     * @throws SearchFailedException if failures left the search with no new document
     */
    private suspend fun executeAlternativeSearch(
        altStructuredQuery: StructuredQuery,
        session: SessionEntity,
        config: WorkflowConfig,
        fetchedPmids: Set<String>,
        earlierLosses: List<RetrievalShortfall>
    ): List<DocumentEntity> {
        val outcome = literatureSearch.searchPage(
            SearchPageRequest(
                provider = config.searchProvider,
                pubMedQuery = QueryBuilderFactory.build(altStructuredQuery, SearchProvider.PUBMED),
                europePMCQuery = QueryBuilderFactory.build(altStructuredQuery, SearchProvider.EUROPE_PMC),
                batchSize = config.batchSize,
                includePreprints = config.includePreprints,
                continuation = null,
                query = ShortfallQuery.ALTERNATIVE,
                sessionId = session.id,
                batchNumber = session.currentBatch + 1,
                existingDocumentCount = documentRepository.getDocumentCount(session.id),
                excludedPmids = fetchedPmids
            )
        )
        // A search that failures left with nothing threw; one that found nothing keeps nothing back
        if (outcome.documents.isEmpty()) return emptyList()
        // Recorded with the documents they were lost beside, before anything later can fail
        keepFound(session.id, earlierLosses + outcome.shortfalls, outcome.documents)
        scoreByEmbedding(outcome.documents, session.claimText)
        return outcome.documents
    }

    // ==================== Helper Methods ====================

    /**
     * Get the configured LLM provider.
     */
    private fun getLLMProvider(): LLMProvider {
        val providerId = settingsRepository.getLlmProvider()
        return LLMProvider.fromId(providerId)
            ?: LLMProvider.OPENAI // Default fallback
    }

    /**
     * Check budget before making an LLM call.
     */
    private suspend fun checkBudget(session: SessionEntity, config: WorkflowConfig) {
        // Refresh session to get latest cost
        val currentSession = sessionRepository.getSession(session.id) ?: session
        val runCost = currentSession.estimatedCostUsd

        // Check per-run budget
        if (runCost >= config.maxRunBudgetUsd) {
            throw BudgetError.RunBudgetExceeded(runCost, config.maxRunBudgetUsd)
        }

        // Check monthly budget
        val totalMonthly = monthlyUsageUsd + runCost
        if (totalMonthly >= config.monthlyBudgetUsd) {
            throw BudgetError.MonthlyBudgetExceeded(totalMonthly, config.monthlyBudgetUsd)
        }
    }

    /**
     * Record API usage for budget tracking.
     */
    private suspend fun recordUsage(
        operation: String,
        inputTokens: Int,
        outputTokens: Int
    ) {
        val session = currentSession ?: return
        val model = settingsRepository.getLlmModel()
        val providerId = settingsRepository.getLlmProvider()
        val provider = LLMProvider.fromId(providerId)
        val modelInfo = provider?.pricedModel(model)
        val cost = modelInfo?.calculateCost(inputTokens, outputTokens) ?: 0.0

        // Record in usage table
        usageRepository.recordUsage(
            sessionId = session.id,
            provider = providerId,
            model = model,
            operation = operation,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = cost
        )

        // Update session totals
        sessionRepository.addTokenUsage(session.id, inputTokens, outputTokens, cost)

        // Update monthly tracking
        monthlyUsageUsd += cost

        // Update progress with current cost
        val updatedSession = sessionRepository.getSession(session.id)
        _progress.value = _progress.value.copy(
            currentCostUsd = updatedSession?.estimatedCostUsd ?: 0.0
        )
    }

    /**
     * Update progress state.
     */
    private fun updateProgress(message: String, percentage: Float) {
        val session = currentSession
        _progress.value = WorkflowProgress(
            step = _state.value.step,
            message = message,
            percentage = percentage,
            documentsFound = session?.documentsInBatch ?: 0,
            currentCostUsd = session?.estimatedCostUsd ?: 0.0,
            currentBatch = session?.currentBatch ?: 1
        )
    }

    /**
     * Calculate available documents that can still be fetched.
     *
     * @param session The current session with pagination state
     * @return Estimated number of documents available for fetching
     */
    private fun calculateAvailableDocuments(session: SessionEntity): Int {
        return when (currentConfig?.searchProvider) {
            SearchProvider.PUBMED -> maxOf(0, session.pubmedTotalResults - session.pubmedOffset)
            SearchProvider.EUROPE_PMC -> {
                if (session.epmcCursor != null) Constants.EUROPE_PMC_AVAILABLE_ESTIMATE else 0
            }
            SearchProvider.BOTH -> {
                maxOf(0, session.pubmedTotalResults - session.pubmedOffset) +
                        (if (session.epmcCursor != null) Constants.EUROPE_PMC_AVAILABLE_ESTIMATE else 0)
            }
            null -> 0
        }
    }

    /**
     * Estimate token count for text.
     *
     * Uses a rough approximation based on average characters per token.
     * This is sufficient for cost estimation purposes.
     *
     * @param text The text to estimate tokens for
     * @return Estimated token count (minimum 1)
     */
    private fun estimateTokens(text: String): Int {
        return (text.length / Constants.TOKEN_ESTIMATE_CHARS_PER_TOKEN).coerceAtLeast(1)
    }

    /**
     * Build the references section for the report.
     */
    private fun buildReferencesSection(documents: List<DocumentEntity>): String {
        return documents.mapIndexed { index, doc ->
            buildString {
                append("**${index + 1}.** ")
                append("**${formatAuthors(doc.authors)}")
                doc.publicationYear?.let { append(" ($it)") }
                append(".** ")
                append(doc.title)
                doc.journal?.let { append(". *$it*") }
                doc.pmid?.let { append(". PMID: $it") }
            }
        }.joinToString("\n\n")
    }

    /**
     * Format author list with "et al." truncation.
     */
    private fun formatAuthors(authors: List<String>?): String {
        if (authors.isNullOrEmpty()) return "Unknown Authors"
        return if (authors.size > Constants.MAX_AUTHORS_BEFORE_ET_AL) {
            "${authors.take(Constants.MAX_AUTHORS_BEFORE_ET_AL).joinToString(", ")} et al."
        } else {
            authors.joinToString(", ")
        }
    }

    /**
     * Create a report when no evidence/citations were found.
     *
     * @param sessionId The session
     * @param claim The claim being fact-checked
     * @param relevantDocCount How many documents met the relevance threshold
     * @param model The LLM model the session used
     * @param shortfalls What the session's searches failed to retrieve; the
     *   message opens with the incomplete-search notice when there are any
     * @return The saved report
     */
    private suspend fun createNoEvidenceReport(
        sessionId: String,
        claim: String,
        relevantDocCount: Int,
        model: String,
        shortfalls: List<RetrievalShortfall>
    ): com.bmlibrarian.factchecker.data.local.entity.ReportEntity {
        val (summary, fullReport) = if (relevantDocCount > 0) {
            // Documents found but citation extraction failed
            Pair(
                "Citation extraction failed for $relevantDocCount relevant document(s). Please review manually.",
                """
                |## Evidence Report
                |
                |**Claim:** $claim
                |
                |**Verdict:** Insufficient Evidence
                |
                |$relevantDocCount relevant document(s) were found, but citation extraction failed.
                |
                |### Recommendations
                |
                |- Review the scored documents directly
                |- Try running the search again
                |- Check for network connectivity issues
                |
                |---
                |*No citations extracted*
                """.trimMargin()
            )
        } else {
            // No relevant documents found
            Pair(
                "No relevant evidence found for this claim.",
                """
                |## Evidence Report
                |
                |**Claim:** $claim
                |
                |**Verdict:** Insufficient Evidence
                |
                |No relevant evidence was found in the searched literature.
                |
                |### Possible Reasons
                |
                |1. Limited published research on this topic
                |2. Search terms may need refinement
                |3. The claim may be too specific or novel
                |
                |### Recommendations
                |
                |- Try rephrasing the claim
                |- Consider broader search terms
                |- Consult specialized databases
                |
                |---
                |*No citations available*
                """.trimMargin()
            )
        }

        return reportRepository.createReport(
            sessionId = sessionId,
            verdict = Verdict.UNCLEAR,
            summary = summary,
            fullReportMarkdown = ReportText.standInReport(fullReport, shortfalls),
            footnotes = null,
            modelUsed = model,
            totalDocumentsReviewed = 0,
            relevantDocumentsCount = relevantDocCount,
            citationsCount = 0
        )
    }

    /**
     * Handle budget errors.
     */
    private suspend fun handleBudgetError(error: BudgetError, session: SessionEntity) {
        _state.value = WorkflowState.BudgetExceeded(
            message = error.message ?: "Budget exceeded",
            currentCostUsd = error.usedUsd,
            budgetLimitUsd = error.limitUsd,
            isMonthly = error.isMonthly
        )
        sessionRepository.setError(session.id, error.message ?: "Budget exceeded")
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.BUDGET_EXCEEDED)
    }

    /**
     * Handle general workflow errors.
     */
    private suspend fun handleWorkflowError(error: Exception, session: SessionEntity) {
        failSession(session, error.message ?: "Unknown error", error)
    }

    /**
     * End a session as failed, saying why.
     *
     * @param session The session
     * @param message Why, for the user
     * @param cause What failed
     */
    private suspend fun failSession(session: SessionEntity, message: String, cause: Exception) {
        _state.value = WorkflowState.Failed(error = message, cause = cause)
        sessionRepository.setError(session.id, message)
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FAILED)
    }

    /**
     * Handle a search that failures left with nothing, or that could not be sent (#252).
     *
     * A session that holds no document yet ends as failed, with what failed and
     * what to do about it: never as "No documents found", since nobody knows
     * whether there are any. It is kept, as a failed session, out of the history
     * list. A session that holds documents is left with them, back at the decision
     * to fetch more or go on, and shows the failure.
     *
     * @param message What failed and what to do about it
     * @param cause The failed search, or why it could not be sent
     * @param session The session it searched for
     * @param config Workflow configuration
     */
    private suspend fun handleSearchNotRun(message: String, cause: Exception, session: SessionEntity, config: WorkflowConfig) {
        if (documentRepository.getDocumentCount(session.id) == 0) {
            failSession(session, message, cause)
            return
        }

        _searchFailureMessage.value = message
        val freshSession = sessionRepository.getSession(session.id) ?: session
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.AWAITING_USER_DECISION)
        _state.value = WorkflowState.AwaitingUserDecision(
            relevantCount = documentRepository.getRelevantCount(session.id, config.relevanceThreshold),
            targetCount = config.targetRelevantDocuments,
            availableCount = calculateAvailableDocuments(freshSession)
        )
    }
}
