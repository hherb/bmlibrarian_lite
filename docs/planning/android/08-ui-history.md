# Phase 8: UI - History View

## Overview

This phase implements the History screen where users can browse their past fact-check sessions, view summaries, and access previous reports.

**Estimated Duration**: 3-5 days
**Prerequisites**: Phases 1-7 completed
**Deliverable**: Browsable session history with delete functionality

## Tasks

### 8.1 Create History ViewModel

```kotlin
// ui/history/HistoryViewModel.kt
package com.bmlibrarian.factchecker.ui.history

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * UI state for a session with its report.
 */
data class SessionWithReport(
    val session: SessionEntity,
    val report: ReportEntity?
)

/**
 * UI state for the History screen.
 */
data class HistoryUiState(
    val sessions: List<SessionWithReport> = emptyList(),
    val isLoading: Boolean = true,
    val selectedSessionId: String? = null,
    val showDeleteConfirmation: Boolean = false
)

/**
 * ViewModel for the History screen.
 */
@HiltViewModel
class HistoryViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val reportDao: ReportDao
) : ViewModel() {

    private val _uiState = MutableStateFlow(HistoryUiState())
    val uiState: StateFlow<HistoryUiState> = _uiState.asStateFlow()

    init {
        loadSessions()
    }

    /**
     * Load all sessions with their reports.
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
     * Cancel deletion.
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
     * Confirm and delete the selected session.
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
     * Delete all sessions.
     */
    fun deleteAllSessions() {
        viewModelScope.launch {
            sessionRepository.deleteAllSessions()
        }
    }
}
```

### 8.2 Create History Screen

```kotlin
// ui/history/HistoryScreen.kt
package com.bmlibrarian.factchecker.ui.history

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.history.components.SessionCard

/**
 * Screen showing the history of fact-check sessions.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun HistoryScreen(
    onSessionClick: (String) -> Unit,
    viewModel: HistoryViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()

    // Delete confirmation dialog
    if (uiState.showDeleteConfirmation) {
        AlertDialog(
            onDismissRequest = viewModel::cancelDeletion,
            title = { Text("Delete Session?") },
            text = { Text("This will permanently delete the session and its report. This action cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = viewModel::confirmDeletion,
                    colors = ButtonDefaults.textButtonColors(
                        contentColor = MaterialTheme.colorScheme.error
                    )
                ) {
                    Text("Delete")
                }
            },
            dismissButton = {
                TextButton(onClick = viewModel::cancelDeletion) {
                    Text("Cancel")
                }
            }
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        // Header with clear all option
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "History",
                style = MaterialTheme.typography.headlineMedium,
                modifier = Modifier.weight(1f)
            )

            if (uiState.sessions.isNotEmpty()) {
                var showClearAllDialog by remember { mutableStateOf(false) }

                IconButton(onClick = { showClearAllDialog = true }) {
                    Icon(
                        imageVector = Icons.Default.DeleteSweep,
                        contentDescription = "Clear all",
                        tint = MaterialTheme.colorScheme.error
                    )
                }

                if (showClearAllDialog) {
                    AlertDialog(
                        onDismissRequest = { showClearAllDialog = false },
                        title = { Text("Clear All History?") },
                        text = { Text("This will permanently delete all sessions and reports. This action cannot be undone.") },
                        confirmButton = {
                            TextButton(
                                onClick = {
                                    viewModel.deleteAllSessions()
                                    showClearAllDialog = false
                                },
                                colors = ButtonDefaults.textButtonColors(
                                    contentColor = MaterialTheme.colorScheme.error
                                )
                            ) {
                                Text("Clear All")
                            }
                        },
                        dismissButton = {
                            TextButton(onClick = { showClearAllDialog = false }) {
                                Text("Cancel")
                            }
                        }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        when {
            uiState.isLoading -> {
                Box(
                    contentAlignment = Alignment.Center,
                    modifier = Modifier.fillMaxSize()
                ) {
                    CircularProgressIndicator()
                }
            }

            uiState.sessions.isEmpty() -> {
                EmptyHistoryPlaceholder()
            }

            else -> {
                LazyColumn(
                    verticalArrangement = Arrangement.spacedBy(12.dp)
                ) {
                    items(
                        items = uiState.sessions,
                        key = { it.session.id }
                    ) { sessionWithReport ->
                        SessionCard(
                            sessionWithReport = sessionWithReport,
                            onClick = { onSessionClick(sessionWithReport.session.id) },
                            onDelete = { viewModel.selectForDeletion(sessionWithReport.session.id) }
                        )
                    }
                }
            }
        }
    }
}

@Composable
private fun EmptyHistoryPlaceholder() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "No History Yet",
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Completed fact-checks will appear here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}
```

### 8.3 Create Session Card Component

```kotlin
// ui/history/components/SessionCard.kt
package com.bmlibrarian.factchecker.ui.history.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.ui.history.SessionWithReport
import com.bmlibrarian.factchecker.ui.report.components.VerdictBadge
import java.text.SimpleDateFormat
import java.util.*

/**
 * Card displaying a session summary in the history list.
 */
@Composable
fun SessionCard(
    sessionWithReport: SessionWithReport,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier
) {
    val session = sessionWithReport.session
    val report = sessionWithReport.report
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy", Locale.getDefault()) }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth()
            ) {
                // Verdict badge if report exists
                report?.let {
                    VerdictBadge(
                        verdict = it.verdict,
                        modifier = Modifier.padding(end = 12.dp)
                    )
                }

                // Claim text and metadata
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = session.claimText,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = 2,
                        overflow = TextOverflow.Ellipsis
                    )

                    Spacer(modifier = Modifier.height(4.dp))

                    Text(
                        text = dateFormat.format(session.createdAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // Delete button
                IconButton(onClick = onDelete) {
                    Icon(
                        imageVector = Icons.Default.Delete,
                        contentDescription = "Delete",
                        tint = MaterialTheme.colorScheme.error
                    )
                }

                // Navigation indicator
                Icon(
                    imageVector = Icons.Default.ChevronRight,
                    contentDescription = "View",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Report summary if available
            report?.let {
                Spacer(modifier = Modifier.height(8.dp))
                HorizontalDivider()
                Spacer(modifier = Modifier.height(8.dp))

                Text(
                    text = it.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = 2,
                    overflow = TextOverflow.Ellipsis
                )

                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    horizontalArrangement = Arrangement.spacedBy(16.dp)
                ) {
                    Text(
                        text = "${it.totalDocumentsReviewed} docs",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "${it.citationsCount} citations",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "$${String.format("%.4f", session.estimatedCostUsd)}",
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}
```

## Verification Checklist

- [ ] Sessions load and display correctly
- [ ] Sessions sorted by date (newest first)
- [ ] Verdict badge shows correct color
- [ ] Claim text truncates properly
- [ ] Date displays in readable format
- [ ] Session click navigates to report
- [ ] Delete confirmation dialog works
- [ ] Delete removes session from list
- [ ] Clear all confirmation works
- [ ] Empty state shows placeholder

## Testing

### UI Tests

```kotlin
// androidTest/ui/history/HistoryScreenTest.kt
@HiltAndroidTest
class HistoryScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun emptyHistory_showsPlaceholder() {
        // Navigate to history tab
        composeRule.onNodeWithText("History").performClick()

        // Verify placeholder
        composeRule.onNodeWithText("No History Yet").assertExists()
    }

    @Test
    fun sessionCard_displaysCorrectly() {
        // Insert test session
        // Navigate to history
        // Verify card elements
    }
}
```

## Next Phase

Continue to [Phase 9: UI - Settings View](./09-ui-settings.md)
