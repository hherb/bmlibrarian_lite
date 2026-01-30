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
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
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

    /** List of scored documents to display. */
    val documents: List<DocumentEntity> = emptyList(),

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
    val sortOrder: DocumentSortOrder = DocumentSortOrder.DEFAULT
) {
    /**
     * Get documents sorted by the current sort order.
     *
     * @return Sorted list of documents
     */
    val sortedDocuments: List<DocumentEntity>
        get() = DocumentSortOrder.sortDocuments(documents, sortOrder)
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
    private val usageRepository: UsageRepository
) : ViewModel() {

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
     * @param sessionId The session ID to observe
     */
    private fun observeDocuments(sessionId: String) {
        viewModelScope.launch {
            documentRepository.getScoredDocumentsBySession(sessionId)
                .collect { docs ->
                    _uiState.update { it.copy(documents = docs) }
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
}
