package com.bmlibrarian.factchecker.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * Combined session and report data for display in history list.
 *
 * Associates a session with its report (if completed) for rendering
 * session cards with verdict badges and summaries.
 *
 * @property session The fact-check session entity
 * @property report The evidence report for this session, or null if not completed
 */
data class SessionWithReport(
    val session: SessionEntity,
    val report: ReportEntity?
)

/**
 * UI state for the History screen.
 *
 * Contains all state needed to render the history list including sessions,
 * loading state, and delete confirmation dialog state.
 *
 * @property sessions List of sessions with their reports, sorted by date (newest first)
 * @property isLoading Whether sessions are currently being loaded
 * @property selectedSessionId Session ID selected for deletion, or null
 * @property showDeleteConfirmation Whether to show the delete confirmation dialog
 * @property showClearAllConfirmation Whether to show the clear all confirmation dialog
 */
data class HistoryUiState(
    val sessions: List<SessionWithReport> = emptyList(),
    val isLoading: Boolean = true,
    val selectedSessionId: String? = null,
    val showDeleteConfirmation: Boolean = false,
    val showClearAllConfirmation: Boolean = false
)

/**
 * ViewModel for the History screen.
 *
 * Manages the state for displaying and deleting past fact-check sessions.
 * Sessions are loaded reactively and automatically update when the database
 * changes (e.g., new sessions added or deleted).
 *
 * @property sessionRepository Repository for session operations
 * @property reportDao DAO for fetching session reports
 */
@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val reportDao: ReportDao
) : ViewModel() {

    private val _uiState = MutableStateFlow(HistoryUiState())

    /** Observable UI state for the history screen. */
    val uiState: StateFlow<HistoryUiState> = _uiState.asStateFlow()

    init {
        loadSessions()
    }

    /**
     * Load all completed sessions with their reports.
     *
     * Uses Flow collection to reactively update when sessions change.
     * Sessions are sorted by creation date (newest first).
     */
    private fun loadSessions() {
        viewModelScope.launch {
            sessionRepository.getCompletedSessions()
                .collect { sessions ->
                    val sessionsWithReports = sessions.map { session ->
                        val report = reportDao.getBySessionId(session.id)
                        SessionWithReport(session, report)
                    }
                    _uiState.update {
                        it.copy(
                            sessions = sessionsWithReports,
                            isLoading = false
                        )
                    }
                }
        }
    }

    /**
     * Select a session for deletion.
     *
     * Shows the delete confirmation dialog for the specified session.
     *
     * @param sessionId The ID of the session to delete
     */
    fun selectForDeletion(sessionId: String) {
        _uiState.update {
            it.copy(
                selectedSessionId = sessionId,
                showDeleteConfirmation = true
            )
        }
    }

    /**
     * Cancel the deletion operation.
     *
     * Dismisses the delete confirmation dialog without deleting.
     */
    fun cancelDeletion() {
        _uiState.update {
            it.copy(
                selectedSessionId = null,
                showDeleteConfirmation = false
            )
        }
    }

    /**
     * Confirm and execute deletion of the selected session.
     *
     * Deletes the session from the database. Due to CASCADE foreign key
     * constraints, this also deletes all associated documents, citations,
     * and reports.
     */
    fun confirmDeletion() {
        val sessionId = _uiState.value.selectedSessionId ?: return

        viewModelScope.launch {
            sessionRepository.deleteSession(sessionId)
            _uiState.update {
                it.copy(
                    selectedSessionId = null,
                    showDeleteConfirmation = false
                )
            }
        }
    }

    /**
     * Show the clear all confirmation dialog.
     */
    fun showClearAllConfirmation() {
        _uiState.update {
            it.copy(showClearAllConfirmation = true)
        }
    }

    /**
     * Cancel the clear all operation.
     *
     * Dismisses the clear all confirmation dialog without deleting.
     */
    fun cancelClearAll() {
        _uiState.update {
            it.copy(showClearAllConfirmation = false)
        }
    }

    /**
     * Confirm and execute deletion of all sessions.
     *
     * Warning: This permanently deletes all data in the database.
     */
    fun confirmClearAll() {
        viewModelScope.launch {
            sessionRepository.deleteAllSessions()
            _uiState.update {
                it.copy(showClearAllConfirmation = false)
            }
        }
    }
}
