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
import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.data.repository.UsageRepository
import com.bmlibrarian.factchecker.domain.model.DocumentSortOrder
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowConfig
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
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
    val loadingFullTextDocumentId: String? = null
) {
    /**
     * Get only scored documents from the full list.
     *
     * @return List of documents that have been scored
     */
    val scoredDocuments: List<DocumentEntity>
        get() = documents.filter { it.relevanceScore != null }

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
    private val fullTextService: FullTextService
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
                    it.copy(
                        workflowState = state,
                        isRunning = state.isProcessing(),
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
                    )
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
     * Start the fact-check process.
     *
     * Creates a new session and runs the workflow with current settings.
     */
    fun startFactCheck() {
        val claim = _uiState.value.claimText.trim()
        if (claim.isEmpty()) return

        // Clear previous query and documents when starting a new fact check
        _uiState.update { it.copy(generatedQuery = null, documents = emptyList()) }

        viewModelScope.launch {
            try {
                val config = buildWorkflowConfig()
                currentSessionId = workflow.startFactCheck(claim, config)

                // Start observing documents for this session
                currentSessionId?.let { sessionId ->
                    observeDocuments(sessionId)
                }
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
                    _uiState.update { it.copy(documents = docs) }
                }
        }

        // Observe citations for document display
        viewModelScope.launch {
            documentRepository.getCitationsBySession(sessionId)
                .collect { citations ->
                    // Group citations by document ID
                    val citationsMap = citations.groupBy { it.documentId }
                    _uiState.update { it.copy(citationsByDocument = citationsMap) }
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
            monthlyBudgetUsd = settingsRepository.getMonthlyBudgetUsd().toDouble()
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
     *
     * @param sessionId The ID of the session to restore
     */
    fun restoreSession(sessionId: String) {
        viewModelScope.launch {
            try {
                val session = sessionRepository.getSession(sessionId)
                    ?: throw IllegalArgumentException("Session not found: $sessionId")

                currentSessionId = sessionId

                // Start observing documents for this session
                observeDocuments(sessionId)

                // Update UI state with restored session data
                _uiState.update {
                    it.copy(
                        claimText = session.claimText,
                        generatedQuery = session.pubmedQuery,
                        isResumedSession = true,
                        canFetchMoreDocuments = session.hasMoreDocuments,
                        workflowState = WorkflowState.Idle,
                        isRunning = false,
                        errorMessage = null
                    )
                }

                // Initialize workflow with session for potential resume
                workflow.restoreForViewing(session)

            } catch (e: Exception) {
                _uiState.update {
                    it.copy(errorMessage = e.message ?: "Failed to restore session")
                }
            }
        }
    }

    /**
     * Add more results to the restored session.
     *
     * Fetches additional documents from the search, scores them,
     * and regenerates the report with all evidence.
     */
    fun addMoreResults() {
        viewModelScope.launch {
            try {
                _uiState.update { it.copy(isRunning = true) }
                workflow.fetchMoreEvidence()
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(
                        errorMessage = e.message ?: "Failed to fetch more documents",
                        isRunning = false
                    )
                }
            }
        }
    }

    /**
     * Clear restored session state and start a new question.
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
                val email = settings.unpaywallEmail.ifEmpty { Constants.UNPAYWALL_DEFAULT_EMAIL }

                val result = fullTextService.fetchFullText(
                    pmcId = document.pmcId,
                    doi = document.doi,
                    pmid = document.pmid,
                    email = email
                )

                result.fold(
                    onSuccess = { fullTextResult ->
                        // Update document based on result type
                        val updatedDoc = when (fullTextResult) {
                            is FullTextService.FullTextResult.EuropePmcXml -> {
                                document.copy(
                                    fullTextMarkdown = fullTextResult.markdown,
                                    fullTextHTML = fullTextResult.html,
                                    fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
                                    fullTextFetchedAt = java.util.Date()
                                )
                            }
                            is FullTextService.FullTextResult.UnpaywallPdf -> {
                                // Download PDF
                                val localPath = fullTextService.downloadPdf(
                                    fullTextResult.pdfUrl,
                                    document.id
                                )
                                document.copy(
                                    pdfPath = localPath,
                                    fullTextSource = Constants.FULLTEXT_SOURCE_UNPAYWALL,
                                    fullTextFetchedAt = java.util.Date()
                                )
                            }
                            is FullTextService.FullTextResult.DoiUrl -> {
                                document.copy(
                                    fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
                                    fullTextFetchedAt = java.util.Date()
                                )
                            }
                            is FullTextService.FullTextResult.Unavailable -> {
                                document.copy(
                                    fullTextUnavailable = true,
                                    fullTextFetchedAt = java.util.Date()
                                )
                            }
                        }

                        documentRepository.updateDocument(updatedDoc)

                        val success = fullTextResult !is FullTextService.FullTextResult.Unavailable
                        Log.d(TAG, "Full text fetch ${if (success) "succeeded" else "unavailable"} for ${document.id}")
                        onComplete(success)
                    },
                    onFailure = { error ->
                        Log.e(TAG, "Full text fetch failed: ${error.message}")
                        // Mark as unavailable on failure
                        documentRepository.updateDocument(
                            document.copy(
                                fullTextUnavailable = true,
                                fullTextFetchedAt = java.util.Date()
                            )
                        )
                        onComplete(false)
                    }
                )
            } catch (e: Exception) {
                Log.e(TAG, "Full text fetch error: ${e.message}")
                onComplete(false)
            } finally {
                _uiState.update { it.copy(loadingFullTextDocumentId = null) }
            }
        }
    }
}
