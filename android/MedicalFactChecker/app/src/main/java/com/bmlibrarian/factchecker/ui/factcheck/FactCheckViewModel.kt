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

package com.bmlibrarian.factchecker.ui.factcheck

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import android.net.Uri
import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUpload
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUploadContent
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextUploadException
import com.bmlibrarian.factchecker.data.remote.fulltext.recordingUpload
import com.bmlibrarian.factchecker.data.remote.fulltext.recordingFullTextFetch
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.data.repository.UsageRepository
import com.bmlibrarian.factchecker.domain.model.DocumentSortOrder
import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchFailureReporting
import com.bmlibrarian.factchecker.domain.model.UnpaywallContact
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.FullTextAutoFetch
import com.bmlibrarian.factchecker.domain.workflow.WorkflowConfig
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import com.bmlibrarian.factchecker.util.retraction.RetractionSnapshot
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlin.coroutines.cancellation.CancellationException
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.distinctUntilChanged
import kotlinx.coroutines.flow.map
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * UI state for the FactCheck screen.
 *
 * Contains all the state needed to render the fact-checking interface,
 * including input text, workflow progress, documents, and error states.
 */
data class FactCheckUiState(
    /** The user's claim text input. */
    val claimText: String = "",

    /** Whether the workflow is currently running. */
    val isRunning: Boolean = false,

    /** Current workflow state for handling different UI modes. */
    val workflowState: WorkflowState = WorkflowState.Idle,

    /** Detailed progress information for progress indicators. */
    val progress: WorkflowProgress = WorkflowProgress.idle(),

    /** List of documents to display (includes in-progress scoring). */
    val documents: List<DocumentEntity> = emptyList(),

    /** Map of document ID to citations for that document. */
    val citationsByDocument: Map<String, List<CitationEntity>> = emptyMap(),

    /** Whether to show the configuration warning. */
    val showConfigWarning: Boolean = false,

    /** Error message to display, if any. */
    val errorMessage: String? = null,

    /** Budget information for display. */
    val monthlyUsedUsd: Double = 0.0,

    /** Monthly budget limit. */
    val monthlyBudgetUsd: Double = Constants.DEFAULT_MONTHLY_BUDGET_USD.toDouble(),

    /** Per-run budget limit. */
    val runBudgetUsd: Double = Constants.DEFAULT_MAX_RUN_BUDGET_USD.toDouble(),

    /** Generated PubMed query (displayed once generated). */
    val generatedQuery: String? = null,

    /** Current document sort order. */
    val sortOrder: DocumentSortOrder = DocumentSortOrder.DEFAULT,

    /** Whether this is a restored session from history. */
    val isResumedSession: Boolean = false,

    /** Whether more documents can be fetched for this session. */
    val canFetchMoreDocuments: Boolean = false,

    /** ID of document currently loading full text, or null if none. */
    val loadingFullTextDocumentId: String? = null,

    /** ID of the document whose full text is being uploaded, or null if none. */
    val uploadingFullTextDocumentId: String? = null,

    /** What the session's searches failed to retrieve (#252); empty when they were complete. */
    val searchShortfalls: List<RetrievalShortfall> = emptyList(),

    /** Why a search or smart search could not do what was asked while the session goes on, with advice; null when none. */
    val searchFailureMessage: String? = null,

    /** Whether the session's record of what its searches missed is damaged (#252). */
    val searchRecordDamaged: Boolean = false,

    /** The claim the current session searched; null before a search, and after New Question. */
    val searchedClaim: String? = null,

    /** Why a request for more evidence added nothing new, while the report stands; null when none. */
    val smartSearchNotice: String? = null,

    /** What the full-text step could not do; null when nothing went wrong. */
    val fullTextNotice: String? = null,

    /** What this run's retraction screen left out and could not check, or null. */
    val retractionNotice: String? = null,

    /**
     * The retraction check each document's run used (the session's
     * snapshot), by document id; decoded once per session update, not per row.
     */
    val retractionChecks: Map<String, PaperRetractionCheck> = emptyMap(),

    /** Whether the session has completed, so it holds a report. */
    val sessionComplete: Boolean = false,

    /** What a retry of full-text retrieval would do, offered beside its button; null when nothing. */
    val fullTextRetryNotice: String? = null,

    /**
     * What an action the reader took (an upload, a retry, a request for more
     * evidence) could not do, or what they should know of its outcome; kept,
     * unlike [errorMessage], until dismissed or the next such action.
     */
    val actionMessage: String? = null
) {
    /**
     * Whether the claim on screen is the one the current session searched, so
     * the submit button finds more evidence for it instead of starting over.
     *
     * An edited claim is a new question.
     */
    val isFollowUp: Boolean
        get() = searchedClaim != null && documents.isNotEmpty() && claimText.trim() == searchedClaim

    /**
     * Whether the submit button may be pressed, beyond a non-blank claim and an idle, configured app.
     *
     * A follow-up paused for the user's decision is answered by that decision's
     * buttons. Otherwise there is always more to try: smart search can run a
     * fresh round.
     */
    val canSubmit: Boolean
        get() = !(isFollowUp && workflowState is WorkflowState.AwaitingUserDecision)

    /** The submit button's text. */
    val submitLabel: String
        get() = if (isFollowUp) "Find More Evidence" else "Check Claim"

    /**
     * The persistent warning an incomplete search shows.
     *
     * @return That the session's record of what its searches missed is damaged,
     *   when it is; otherwise "Incomplete search: {clauses}.", or null when the
     *   searches were complete
     */
    val incompleteSearchWarning: String?
        get() = if (searchRecordDamaged) {
            DAMAGED_RECORD_WARNING
        } else {
            SearchFailureReporting.incompleteSearchWarning(searchShortfalls)
        }

    /**
     * Get only scored documents from the full list.
     *
     * @return List of documents that have been scored
     */
    val scoredDocuments: List<DocumentEntity>
        get() = documents.filter { it.relevanceScore != null }

    /** Papers the run left out as retracted: never scored, listed after the scored ones. */
    val retractedDocuments: List<DocumentEntity>
        get() = documents.filter { !it.isScored && retractionChecks[it.id]?.isRetracted == true }

    /**
     * Get scored documents sorted by the current sort order.
     *
     * @return Sorted list of scored documents
     */
    val sortedDocuments: List<DocumentEntity>
        get() = DocumentSortOrder.sortDocuments(scoredDocuments, sortOrder)

    /**
     * Get citations for a specific document.
     *
     * @param documentId The document ID
     * @return List of citations for the document
     */
    fun getCitationsForDocument(documentId: String): List<CitationEntity> =
        citationsByDocument[documentId] ?: emptyList()
}

/** The persistent warning for a session whose record of what its search missed is damaged (#252). */
private const val DAMAGED_RECORD_WARNING =
    "This session's record of what its search could not retrieve is damaged, so whether its search " +
        "was complete cannot be shown. The report keeps any notice it was written with."

/**
 * ViewModel for the FactCheck screen.
 *
 * Manages the fact-checking workflow, handling user input, workflow state,
 * and document display. Integrates with the FactCheckWorkflow engine and
 * settings repository.
 *
 * @param workflow The workflow engine for fact-checking
 * @param settingsRepository Repository for app settings
 * @param documentRepository Repository for document operations
 * @param usageRepository Repository for usage/budget tracking
 */
@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val workflow: FactCheckWorkflow,
    private val settingsRepository: SettingsRepository,
    private val documentRepository: DocumentRepository,
    private val usageRepository: UsageRepository,
    private val sessionRepository: SessionRepository,
    private val fullTextService: FullTextService,
    private val fullTextUpload: FullTextUpload
) : ViewModel() {

    companion object {
        private const val TAG = "FactCheckViewModel"
    }

    private val _uiState = MutableStateFlow(FactCheckUiState())
    val uiState: StateFlow<FactCheckUiState> = _uiState.asStateFlow()

    /** Current session ID for document observation. */
    private var currentSessionId: String? = null

    init {
        observeWorkflowState()
        observeWorkflowProgress()
        observeWorkflowSessionId()
        observeSearchShortfalls()
        observeConfiguration()
        loadBudgetInfo()
    }

    /**
     * Observe workflow state changes and update UI state accordingly.
     */
    private fun observeWorkflowState() {
        viewModelScope.launch {
            workflow.state.collect { state ->
                _uiState.update {
                    withRetryNotice(it.copy(
                        workflowState = state,
                        isRunning = state.isProcessing(),
                        // A restored session is idle; its completeness was read from it
                        sessionComplete = when (state) {
                            is WorkflowState.Completed -> true
                            is WorkflowState.Idle -> it.sessionComplete
                            else -> false
                        },
                        errorMessage = when (state) {
                            is WorkflowState.Failed -> state.error
                            is WorkflowState.BudgetExceeded -> state.message
                            else -> null
                        },
                        // Extract query from Searching state
                        generatedQuery = when (state) {
                            is WorkflowState.Searching -> state.query
                            else -> it.generatedQuery // Keep existing query
                        }
                    ))
                }
            }
        }
    }

    /**
     * Observe workflow progress and update UI state.
     */
    private fun observeWorkflowProgress() {
        viewModelScope.launch {
            workflow.progress.collect { progress ->
                _uiState.update { it.copy(progress = progress) }
            }
        }
    }

    /**
     * Observe what the session's searches failed to retrieve, and why a search for more failed (#252).
     */
    private fun observeSearchShortfalls() {
        viewModelScope.launch {
            workflow.searchShortfalls.collect { shortfalls ->
                _uiState.update { it.copy(searchShortfalls = shortfalls) }
            }
        }
        viewModelScope.launch {
            workflow.searchFailureMessage.collect { message ->
                _uiState.update { it.copy(searchFailureMessage = message) }
            }
        }
        viewModelScope.launch {
            workflow.searchRecordDamaged.collect { damaged ->
                _uiState.update { it.copy(searchRecordDamaged = damaged) }
            }
        }
        viewModelScope.launch {
            workflow.smartSearchNotice.collect { notice ->
                _uiState.update { it.copy(smartSearchNotice = notice) }
            }
        }
        viewModelScope.launch {
            workflow.retractionNotice.collect { notice ->
                _uiState.update { it.copy(retractionNotice = notice) }
            }
        }
        viewModelScope.launch {
            workflow.fullTextNotice.collect { notice ->
                _uiState.update { it.copy(fullTextNotice = notice) }
            }
        }
    }

    /**
     * Observe workflow session ID changes to start document observation immediately.
     *
     * This allows documents to appear in the UI as soon as they're saved to the database,
     * rather than waiting for the entire workflow to complete.
     */
    private fun observeWorkflowSessionId() {
        viewModelScope.launch {
            workflow.currentSessionId.collect { sessionId ->
                if (sessionId != null && sessionId != currentSessionId) {
                    currentSessionId = sessionId
                    observeDocuments(sessionId)
                } else if (sessionId == null) {
                    currentSessionId = null
                    // Clear documents when session is reset
                    _uiState.update { it.copy(documents = emptyList(), citationsByDocument = emptyMap()) }
                }
            }
        }
    }

    /**
     * Observe configuration changes and update UI state accordingly.
     *
     * This observes the configurationVersion StateFlow to reactively update the
     * configuration warning when any configuration changes (settings or API key).
     * This ensures the warning disappears immediately after saving an API key.
     */
    private fun observeConfiguration() {
        viewModelScope.launch {
            settingsRepository.configurationVersion.collect { _ ->
                // Re-check configuration whenever any configuration changes
                val isConfigured = settingsRepository.isConfigured()
                _uiState.update {
                    it.copy(showConfigWarning = !isConfigured)
                }
            }
        }
        // The retry's offer depends on the full-text setting and score
        viewModelScope.launch {
            settingsRepository.settings.collect { _ -> _uiState.update(::withRetryNotice) }
        }
    }

    /**
     * Load budget information from repositories.
     */
    private fun loadBudgetInfo() {
        viewModelScope.launch {
            val monthlyUsed = usageRepository.getCurrentMonthSpend()
            val monthlyBudget = settingsRepository.getMonthlyBudgetUsd()
            val runBudget = settingsRepository.getMaxRunBudgetUsd()

            _uiState.update {
                it.copy(
                    monthlyUsedUsd = monthlyUsed,
                    monthlyBudgetUsd = monthlyBudget.toDouble(),
                    runBudgetUsd = runBudget.toDouble()
                )
            }
        }
    }

    /**
     * Update the claim text.
     *
     * @param text The new claim text
     */
    fun updateClaimText(text: String) {
        _uiState.update { it.copy(claimText = text) }
    }

    /**
     * Find more evidence for the claim already searched, or start a new fact-check.
     */
    fun submit() {
        if (_uiState.value.isFollowUp) addMoreResults() else startFactCheck()
    }

    /**
     * Start the fact-check process.
     *
     * Creates a new session and runs the workflow with current settings.
     * Document observation starts automatically via observeWorkflowSessionId()
     * as soon as the workflow creates the session.
     */
    fun startFactCheck() {
        val claim = _uiState.value.claimText.trim()
        if (claim.isEmpty()) return

        // Clear previous query and documents when starting a new fact check
        _uiState.update {
            it.copy(generatedQuery = null, documents = emptyList(), citationsByDocument = emptyMap(), searchedClaim = claim)
        }

        viewModelScope.launch {
            try {
                val config = buildWorkflowConfig()
                // Document observation starts automatically via observeWorkflowSessionId()
                workflow.startFactCheck(claim, config)
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to start fact check")
                }
            }
        }
    }

    /**
     * User wants to fetch more documents.
     */
    fun fetchMoreDocuments() {
        viewModelScope.launch {
            try {
                workflow.continueWithMoreDocuments()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to fetch more documents")
                }
            }
        }
    }

    /**
     * User declines to fetch more documents.
     */
    fun skipMoreDocuments() {
        viewModelScope.launch {
            try {
                workflow.proceedWithCurrentDocuments()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to continue")
                }
            }
        }
    }

    /**
     * Cancel the current fact-check.
     */
    fun cancel() {
        viewModelScope.launch {
            workflow.cancel()
            _uiState.update {
                it.copy(
                    isRunning = false,
                    errorMessage = null
                )
            }
        }
    }

    /**
     * Clear any error message.
     */
    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    /**
     * Stop showing why a search for more documents failed.
     */
    fun dismissSearchFailure() {
        workflow.dismissSearchFailure()
    }

    /**
     * Update the document sort order.
     *
     * @param sortOrder The new sort order
     */
    fun setSortOrder(sortOrder: DocumentSortOrder) {
        _uiState.update { it.copy(sortOrder = sortOrder) }
    }

    /**
     * Observe documents for the current session.
     *
     * Observes all documents (not just scored) to enable incremental display
     * as documents are scored. Documents appear immediately and update when
     * their scores are populated.
     *
     * @param sessionId The session ID to observe
     */
    private fun observeDocuments(sessionId: String) {
        // Observe all documents (not just scored) for incremental updates
        viewModelScope.launch {
            documentRepository.getDocumentsBySession(sessionId)
                .collect { docs ->
                    _uiState.update { withRetryNotice(it.copy(documents = docs)) }
                }
        }

        // The checks the session's runs used, for the badges and the left-out list
        viewModelScope.launch {
            sessionRepository.getSessionFlow(sessionId)
                .map { it?.retractionSnapshotJson }
                .distinctUntilChanged()
                .collect { snapshot ->
                    _uiState.update { it.copy(retractionChecks = RetractionSnapshot.read(snapshot)) }
                }
        }

        // Observe citations for document display
        viewModelScope.launch {
            documentRepository.getCitationsBySession(sessionId)
                .collect { citations ->
                    // Group citations by document ID
                    val citationsMap = citations.groupBy { it.documentId }
                    _uiState.update { withRetryNotice(it.copy(citationsByDocument = citationsMap)) }
                }
        }
    }

    /**
     * Build the workflow configuration from current settings.
     *
     * Uses all available settings from SettingsRepository for search provider,
     * batch size, thresholds, and budget limits.
     *
     * @return WorkflowConfig with current settings
     */
    private fun buildWorkflowConfig(): WorkflowConfig {
        return WorkflowConfig(
            searchProvider = settingsRepository.getSearchProvider(),
            includePreprints = settingsRepository.getIncludePreprints(),
            batchSize = settingsRepository.getBatchSize(),
            relevanceThreshold = settingsRepository.getRelevanceThreshold(),
            targetRelevantDocuments = settingsRepository.getTargetRelevantDocuments(),
            maxRunBudgetUsd = settingsRepository.getMaxRunBudgetUsd().toDouble(),
            monthlyBudgetUsd = settingsRepository.getMonthlyBudgetUsd().toDouble(),
            autoFetchFullText = settingsRepository.settings.value.autoFetchFullTextEnabled,
            fullTextAutoFetchMinScore = settingsRepository.settings.value.fullTextAutoFetchMinScore
        )
    }

    /**
     * Extension function to check if workflow state is processing.
     *
     * @return true if workflow is in an active processing state
     */
    private fun WorkflowState.isProcessing(): Boolean {
        return this !is WorkflowState.Idle &&
                this !is WorkflowState.Completed &&
                this !is WorkflowState.Failed &&
                this !is WorkflowState.BudgetExceeded &&
                this !is WorkflowState.AwaitingUserDecision
    }

    // ==================== Session Restoration ====================

    /**
     * Restore a session from history for viewing.
     *
     * Loads the session data and documents without running the workflow.
     * This mirrors iOS's restoreForViewing() method, allowing users to
     * view past fact-check results and optionally fetch more evidence.
     * Document observation starts automatically via observeWorkflowSessionId().
     *
     * @param sessionId The ID of the session to restore
     */
    fun restoreSession(sessionId: String) {
        viewModelScope.launch {
            try {
                val session = sessionRepository.getSession(sessionId)
                    ?: throw IllegalArgumentException("Session not found: $sessionId")

                // Update UI state with restored session data
                _uiState.update {
                    it.copy(
                        claimText = session.claimText,
                        searchedClaim = session.claimText.trim(),
                        generatedQuery = session.pubmedQuery,
                        isResumedSession = true,
                        sessionComplete = session.workflowStep == WorkflowStep.COMPLETED,
                        canFetchMoreDocuments = session.hasMoreDocuments,
                        workflowState = WorkflowState.Idle,
                        isRunning = false,
                        errorMessage = null
                    )
                }

                // Initialize workflow with session for potential resume
                // This also emits the session ID for document observation
                workflow.restoreForViewing(session)

            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to restore session")
                }
            }
        }
    }

    /**
     * Add more results to the current or restored session.
     *
     * Fetches additional documents from the search (or, once it is exhausted,
     * a fresh round of alternative queries), scores them, and regenerates the
     * report with all evidence, under the current settings.
     */
    fun addMoreResults() {
        if (!startingAction()) return
        viewModelScope.launch {
            try {
                workflow.fetchMoreEvidence(buildWorkflowConfig())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Fetching more evidence failed", e)
                _uiState.update { it.copy(actionMessage = e.message ?: "Failed to fetch more documents") }
            } finally {
                endingAction()
            }
        }
    }

    /**
     * Fetch full text again for the papers that have none, and redo the analysis
     * with any that arrive, under the current settings.
     */
    fun retryFullText() {
        if (!startingAction()) return
        viewModelScope.launch {
            try {
                workflow.retryFullTextRetrieval(buildWorkflowConfig())
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Retrying full text failed", e)
                _uiState.update { it.copy(actionMessage = e.message ?: "Failed to retry full text") }
            } finally {
                endingAction()
            }
        }
    }

    /**
     * Mark a run started from the screen as running, at once: a second tap
     * before the workflow says it is busy would start a second run, paying twice
     * and saving its citations twice.
     *
     * @return False when something already runs, so nothing is started
     */
    private fun startingAction(): Boolean {
        var started = false
        _uiState.update {
            started = !it.isRunning
            if (started) it.copy(isRunning = true, fullTextRetryNotice = null, actionMessage = null) else it
        }
        return started
    }

    /**
     * End a run started from the screen: running only while the workflow is,
     * since a run that found nothing to do may never have changed its state.
     */
    private fun endingAction() {
        _uiState.update { withRetryNotice(it.copy(isRunning = workflow.state.value.isProcessing())) }
    }

    /** Stop showing [FactCheckUiState.actionMessage]. */
    fun dismissActionMessage() {
        _uiState.update { it.copy(actionMessage = null) }
    }

    /**
     * The state with what a retry of full-text retrieval would do, under the
     * current settings: offered only for a completed session, while nothing runs.
     */
    private fun withRetryNotice(state: FactCheckUiState): FactCheckUiState = state.copy(
        fullTextRetryNotice = if (state.isRunning || !state.sessionComplete) {
            null
        } else {
            FullTextAutoFetch.retryNotice(state.documents, state.citationsByDocument, buildWorkflowConfig())
        }
    )

    /**
     * Clear the session on screen, run or restored, and start a new question.
     *
     * Resets the workflow and UI to allow entering a fresh claim.
     */
    fun startNewQuestion() {
        workflow.reset()
        currentSessionId = null
        _uiState.update {
            FactCheckUiState(
                showConfigWarning = it.showConfigWarning,
                monthlyUsedUsd = it.monthlyUsedUsd,
                monthlyBudgetUsd = it.monthlyBudgetUsd,
                runBudgetUsd = it.runBudgetUsd
            )
        }
    }

    // ==================== Full Text ====================

    /**
     * Use a file the reader chose as a document's full text.
     *
     * Offered during a run too: the automatic fetch leaves a paper the reader
     * uploaded for alone, and the next extraction, or a retry, reads it whatever
     * the full-text setting or score.
     *
     * @param document The document
     * @param uri The file the reader chose
     */
    fun uploadFullText(document: DocumentEntity, uri: Uri) {
        viewModelScope.launch {
            _uiState.update { it.copy(uploadingFullTextDocumentId = document.id, actionMessage = null) }
            try {
                val content = fullTextUpload.read(uri, document.id)
                // Read again, so a score or fetch stored meanwhile is kept
                val current = documentRepository.getDocument(document.id) ?: document
                documentRepository.updateDocument(current.recordingUpload(content))
                if (content is FullTextUploadContent.Pdf && content.text == null) {
                    _uiState.update { it.copy(actionMessage = FullTextUpload.PDF_WITHOUT_TEXT_MESSAGE) }
                }
            } catch (e: FullTextUploadException) {
                Log.w(TAG, "Upload for ${document.id} refused: ${e.message}")
                _uiState.update { it.copy(actionMessage = e.message) }
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                // A provider's own failure (a revoked grant, a bad URI): told, never a crash
                Log.e(TAG, "Upload for ${document.id} failed", e)
                _uiState.update { it.copy(actionMessage = "The file could not be used as this paper's full text.") }
            } finally {
                _uiState.update { it.copy(uploadingFullTextDocumentId = null) }
            }
        }
    }

    /**
     * Fetch full text for a document.
     *
     * Attempts to retrieve full text from Europe PMC, Unpaywall, or DOI.
     * Updates the document in the database with the result.
     *
     * @param document The document to fetch full text for
     * @param onComplete Callback when full text is fetched (with success/failure)
     */
    fun fetchFullText(document: DocumentEntity, onComplete: (Boolean) -> Unit) {
        viewModelScope.launch {
            _uiState.update { it.copy(loadingFullTextDocumentId = document.id) }

            try {
                val settings = settingsRepository.settings.value
                val email = UnpaywallContact.emailFor(settings)

                val result = fullTextService.fetchFullText(
                    pmcId = document.pmcId,
                    doi = document.doi,
                    pmid = document.pmid,
                    email = email,
                    // Elsevier's PDF is checked against it (#546)
                    title = document.title
                )

                result.fold(
                    onSuccess = { chainResult ->
                        // The result as settled by the download: a PDF Unpaywall
                        // named that could not be downloaded is the DOI link (#478)
                        val (updatedDoc, fullTextResult) = document.recordingFullTextFetch(
                            chainResult,
                            downloadPdf = { url -> fullTextService.downloadPdf(url, document.id, document.title) },
                            askOpenAlex = { doi, tried -> fullTextService.openAlexSteps(doi, tried) },
                            askCore = { doi -> fullTextService.askCore(doi) },
                            readPdfText = { path -> fullTextService.readPdfText(path) }
                        )

                        documentRepository.updateDocument(updatedDoc)

                        val success = fullTextResult.hasContent
                        Log.d(TAG, "Full text fetch for ${document.id}: ${fullTextResult::class.simpleName}")
                        onComplete(success)
                    },
                    onFailure = { error ->
                        // A failed fetch is not an article without full text, so
                        // the document is not marked unavailable for good (#434)
                        Log.e(TAG, "Full text fetch failed: ${error.message}")
                        onComplete(false)
                    }
                )
            } catch (e: CancellationException) {
                // The caller went away: not a failed fetch to report
                throw e
            } catch (e: Exception) {
                Log.e(TAG, "Full text fetch error: ${e.message}")
                onComplete(false)
            } finally {
                _uiState.update { it.copy(loadingFullTextDocumentId = null) }
            }
        }
    }
}
