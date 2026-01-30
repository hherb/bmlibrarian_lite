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
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.ReportRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.data.repository.UsageRepository
import com.bmlibrarian.factchecker.domain.embedding.EmbeddingService
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.ml.HydeGenerator
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.isActive
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.coroutines.coroutineContext

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
    private val pubMedService: PubMedService,
    private val europePMCService: EuropePMCService,
    private val sessionRepository: SessionRepository,
    private val documentRepository: DocumentRepository,
    private val reportRepository: ReportRepository,
    private val usageRepository: UsageRepository,
    private val settingsRepository: SettingsRepository,
    private val parallelScoringService: ParallelScoringService,
    private val checkpointManager: CheckpointManager,
    private val errorPersistenceManager: ErrorPersistenceManager,
    private val embeddingService: EmbeddingService,
    private val hydeGenerator: HydeGenerator
) {

    companion object {
        private const val TAG = "FactCheckWorkflow"
    }

    // ==================== Observable State ====================

    /** Current workflow state. */
    private val _state = MutableStateFlow<WorkflowState>(WorkflowState.Idle)
    val state: StateFlow<WorkflowState> = _state.asStateFlow()

    /** Progress tracking for UI display. */
    private val _progress = MutableStateFlow(WorkflowProgress.idle())
    val progress: StateFlow<WorkflowProgress> = _progress.asStateFlow()

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

        // Update state
        _state.value = WorkflowState.ConvertingQuery(claim)
        updateProgress("Analyzing claim...", WorkflowProgress.basePercentageFor(WorkflowStep.CONVERTING_QUERY))

        try {
            // Run the workflow
            runWorkflow(session, config)
        } catch (e: BudgetError) {
            handleBudgetError(e, session)
        } catch (e: Exception) {
            handleWorkflowError(e, session)
        }

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

        currentSession = session
        currentConfig = config
        monthlyUsageUsd = usageRepository.getCurrentMonthSpend()
        isResumedSession = true  // Enable checkpoint loading

        try {
            runWorkflow(session, config)
        } catch (e: BudgetError) {
            handleBudgetError(e, session)
        } catch (e: Exception) {
            handleWorkflowError(e, session)
        } finally {
            isResumedSession = false
        }
    }

    /**
     * Continue workflow after user approves fetching more documents.
     */
    suspend fun continueWithMoreDocuments() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()

        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.SEARCHING_PUBMED)

        // Refresh session to get updated workflow step
        val updatedSession = sessionRepository.getSession(session.id) ?: session
        currentSession = updatedSession

        _state.value = WorkflowState.Searching(
            query = updatedSession.pubmedQuery ?: "",
            provider = config.searchProvider.name,
            batchNumber = updatedSession.currentBatch + 1
        )

        try {
            runWorkflow(updatedSession, config)
        } catch (e: BudgetError) {
            handleBudgetError(e, updatedSession)
        } catch (e: Exception) {
            handleWorkflowError(e, updatedSession)
        }
    }

    /**
     * Continue workflow after user declines to fetch more documents.
     */
    suspend fun proceedWithCurrentDocuments() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()

        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.EXTRACTING_CITATIONS)

        // Refresh session to get updated workflow step
        val updatedSession = sessionRepository.getSession(session.id) ?: session
        currentSession = updatedSession

        try {
            runWorkflow(updatedSession, config)
        } catch (e: BudgetError) {
            handleBudgetError(e, updatedSession)
        } catch (e: Exception) {
            handleWorkflowError(e, updatedSession)
        }
    }

    /**
     * Fetch additional evidence after initial report generation.
     *
     * Allows users to gather more evidence when initial report is incomplete.
     */
    suspend fun fetchMoreEvidence() {
        val session = currentSession
            ?: throw IllegalStateException("No active session")
        val config = currentConfig ?: WorkflowConfig.default()

        _state.value = WorkflowState.FetchingMoreEvidence()
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FETCHING_MORE_EVIDENCE)

        try {
            // Fetch more documents
            if (session.hasMoreDocuments) {
                updateProgress("Fetching more documents...", WorkflowProgress.PROGRESS_EXTRACTION_START)
                val newDocs = searchForDocuments(session, config, isNextBatch = true)

                if (newDocs.isNotEmpty()) {
                    // Score new documents
                    updateProgress("Scoring new documents...", WorkflowProgress.PROGRESS_SCORING_MORE_EVIDENCE)
                    scoreDocuments(newDocs, session.claimText, config)

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

                    extractCitations(docsNeedingCitations, session.claimText, session.id, config)
                }
            }

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
        } catch (e: Exception) {
            handleWorkflowError(e, session)
        }
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

        try {
            when (step) {
                ProcessingCheckpointEntity.STEP_SCORING -> {
                    _state.value = WorkflowState.Scoring(0, documents.size)
                    updateProgress("Retrying ${documents.size} failed documents...",
                        WorkflowProgress.PROGRESS_SCORING_START)

                    scoreDocuments(documents, session.claimText, config)

                    // Count successes by checking which documents now have scores
                    val successfulIds = mutableSetOf<String>()
                    for (doc in documents) {
                        val updatedDoc = documentRepository.getDocument(doc.id)
                        if (updatedDoc?.relevanceScore != null) {
                            successfulIds.add(doc.id)
                        }
                    }
                    successCount = successfulIds.size

                    // Remove errors for successfully retried documents
                    errorPersistenceManager.removeErrorsForDocuments(session.id, successfulIds)
                }

                ProcessingCheckpointEntity.STEP_CITATION -> {
                    _state.value = WorkflowState.ExtractingCitations(0, documents.size)
                    updateProgress("Retrying ${documents.size} failed extractions...",
                        WorkflowProgress.PROGRESS_EXTRACTION_START)

                    extractCitations(documents, session.claimText, session.id, config)

                    // Count successes by checking citation count
                    val successfulIds = mutableSetOf<String>()
                    for (doc in documents) {
                        if (documentRepository.getCitationCountForDocument(doc.id) > 0) {
                            successfulIds.add(doc.id)
                        }
                    }
                    successCount = successfulIds.size

                    // Remove errors for successfully retried documents
                    errorPersistenceManager.removeErrorsForDocuments(session.id, successfulIds)
                }
            }

            // Update retry counts for remaining errors
            retryableErrors.forEach { error ->
                if (error.documentId !in documentIds) {
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

            val documents = searchForDocuments(updatedSession, config)

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

            if (relevantCount < config.targetRelevantDocuments && hasMore) {
                // Try smart search first if enabled
                if (config.smartSearchEnabled && relevantCount < config.smartSearchThreshold) {
                    // Could implement smart search here in future
                }

                // Calculate available documents
                val availableCount = calculateAvailableDocuments(updatedSession)

                if (availableCount > 0) {
                    currentStep = WorkflowStep.AWAITING_USER_DECISION
                    sessionRepository.updateWorkflowStep(session.id, currentStep)
                    _state.value = WorkflowState.AwaitingUserDecision(
                        relevantCount = relevantCount,
                        targetCount = config.targetRelevantDocuments,
                        availableCount = availableCount
                    )
                    updateProgress(
                        "Found $relevantCount relevant documents. Fetch more?",
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
     */
    private suspend fun convertClaimToQuery(claim: String, config: WorkflowConfig): String {
        val provider = getLLMProvider()
        val apiKey = settingsRepository.getLlmApiKey()
        val model = settingsRepository.getLlmModel()

        val result = llmService.convertToPubMedQuery(
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

        return result.getOrThrow()
    }

    /**
     * Search for documents from the configured provider(s).
     */
    private suspend fun searchForDocuments(
        session: SessionEntity,
        config: WorkflowConfig,
        isNextBatch: Boolean = false
    ): List<DocumentEntity> {
        val query = session.pubmedQuery ?: return emptyList()
        val allDocuments = mutableListOf<DocumentEntity>()
        val batchNumber = if (isNextBatch) session.currentBatch + 1 else session.currentBatch

        when (config.searchProvider) {
            SearchProvider.PUBMED -> {
                val offset = if (isNextBatch) session.pubmedOffset else 0
                val result = pubMedService.search(
                    query = query,
                    offset = offset,
                    batchSize = config.batchSize,
                    email = settingsRepository.getNcbiEmail().ifEmpty { null }
                )

                if (result.isSuccess) {
                    val searchResult = result.getOrThrow()
                    val entities = pubMedService.toDocumentEntities(
                        articles = searchResult.articles,
                        sessionId = session.id,
                        batchNumber = batchNumber,
                        startPosition = offset
                    )
                    allDocuments.addAll(entities)

                    // Update session pagination state
                    sessionRepository.updatePubMedPagination(
                        sessionId = session.id,
                        offset = searchResult.nextOffset,
                        totalResults = searchResult.totalResults
                    )
                }
            }

            SearchProvider.EUROPE_PMC -> {
                val cursor = if (isNextBatch) session.epmcCursor else null
                val result = europePMCService.search(
                    query = query,
                    cursor = cursor,
                    batchSize = config.batchSize,
                    includePreprints = config.includePreprints
                )

                if (result.isSuccess) {
                    val searchResult = result.getOrThrow()
                    val entities = europePMCService.toDocumentEntities(
                        articles = searchResult.articles,
                        sessionId = session.id,
                        batchNumber = batchNumber,
                        startPosition = documentRepository.getDocumentCount(session.id)
                    )
                    allDocuments.addAll(entities)

                    // Update session pagination state
                    sessionRepository.updateEpmcPagination(
                        sessionId = session.id,
                        cursor = searchResult.nextCursor,
                        totalResults = searchResult.totalResults
                    )
                }
            }

            SearchProvider.BOTH -> {
                // Search both providers with half batch size each
                val halfBatch = config.batchSize / 2

                // PubMed
                val pubmedOffset = if (isNextBatch) session.pubmedOffset else 0
                val pubmedResult = pubMedService.search(
                    query = query,
                    offset = pubmedOffset,
                    batchSize = halfBatch,
                    email = settingsRepository.getNcbiEmail().ifEmpty { null }
                )

                if (pubmedResult.isSuccess) {
                    val sr = pubmedResult.getOrThrow()
                    allDocuments.addAll(
                        pubMedService.toDocumentEntities(
                            articles = sr.articles,
                            sessionId = session.id,
                            batchNumber = batchNumber,
                            startPosition = pubmedOffset
                        )
                    )
                    sessionRepository.updatePubMedPagination(session.id, sr.nextOffset, sr.totalResults)
                }

                // Europe PMC
                val epmcCursor = if (isNextBatch) session.epmcCursor else null
                val epmcResult = europePMCService.search(
                    query = query,
                    cursor = epmcCursor,
                    batchSize = halfBatch,
                    includePreprints = config.includePreprints
                )

                if (epmcResult.isSuccess) {
                    val sr = epmcResult.getOrThrow()
                    // Deduplicate by PMID
                    val existingPmids = allDocuments.mapNotNull { it.pmid }.toSet()
                    val newEntities = europePMCService.toDocumentEntities(
                        articles = sr.articles,
                        sessionId = session.id,
                        batchNumber = batchNumber,
                        startPosition = documentRepository.getDocumentCount(session.id)
                    ).filter { it.pmid !in existingPmids }
                    allDocuments.addAll(newEntities)
                    sessionRepository.updateEpmcPagination(session.id, sr.nextCursor, sr.totalResults)
                }
            }
        }

        // Save documents to database
        if (allDocuments.isNotEmpty()) {
            documentRepository.saveDocuments(allDocuments)

            // Compute embedding scores if enabled
            if (settingsRepository.isEmbeddingEnabled() && embeddingService.isAvailable) {
                computeEmbeddingScores(allDocuments, session.claimText)
            }
        }

        return allDocuments
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
     * Extract citation passages from relevant documents.
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

        documents.forEachIndexed { index, doc ->
            checkBudget(session, config)

            _state.value = WorkflowState.ExtractingCitations(index + 1, documents.size)
            updateProgress(
                "Extracting citations from document ${index + 1}",
                WorkflowProgress.PROGRESS_EXTRACTION_START + (WorkflowProgress.PROGRESS_EXTRACTION_RANGE * (index + 1) / documents.size)
            )

            val result = llmService.extractCitations(
                provider = provider,
                apiKey = apiKey,
                model = model,
                claim = claim,
                title = doc.title,
                content = doc.abstractText ?: doc.fullTextMarkdown
            )

            if (result.isSuccess) {
                val extractions = result.getOrThrow()
                val citations = extractions.map { extraction ->
                    CitationEntity(
                        documentId = doc.id,
                        passage = extraction.passage,
                        relevanceExplanation = extraction.relevance
                    )
                }
                documentRepository.saveCitations(citations)

                // Record usage
                recordUsage(
                    operation = "citation",
                    inputTokens = estimateTokens(claim + doc.title + (doc.abstractText ?: "")),
                    outputTokens = Constants.LLM_CITATION_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
                )
            }
        }
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
            return createNoEvidenceReport(sessionId, claim, relevantCount, model, config)
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
        val fullReport = generation.report + "\n\n## References\n\n$references"

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
        val modelInfo = provider?.getModel(model)
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
     */
    private suspend fun createNoEvidenceReport(
        sessionId: String,
        claim: String,
        relevantDocCount: Int,
        model: String,
        config: WorkflowConfig
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
            fullReportMarkdown = fullReport,
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
        _state.value = WorkflowState.Failed(
            error = error.message ?: "Unknown error",
            cause = error
        )
        sessionRepository.setError(session.id, error.message ?: "Unknown error")
        sessionRepository.updateWorkflowStep(session.id, WorkflowStep.FAILED)
    }
}
