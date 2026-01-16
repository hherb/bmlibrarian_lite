package com.bmlibrarian.factchecker.ui.history

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.DeleteSweep
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.history.components.SessionCard
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants

/**
 * Session history screen.
 *
 * Shows past fact-checking sessions with their claims and verdicts.
 * Users can browse completed sessions, tap to view reports, and delete
 * sessions individually or clear all history.
 *
 * @param onSessionClick Callback when a session is selected, passes session ID
 * @param viewModel The ViewModel for managing history state
 */
@Composable
fun HistoryScreen(
    onSessionClick: (String) -> Unit = {},
    viewModel: HistoryViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()

    // Delete single session confirmation dialog
    if (uiState.showDeleteConfirmation) {
        DeleteSessionDialog(
            onConfirm = viewModel::confirmDeletion,
            onDismiss = viewModel::cancelDeletion
        )
    }

    // Clear all confirmation dialog
    if (uiState.showClearAllConfirmation) {
        ClearAllDialog(
            onConfirm = viewModel::confirmClearAll,
            onDismiss = viewModel::cancelClearAll
        )
    }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(Constants.UI_SCREEN_PADDING.dp)
    ) {
        // Header with title and clear all button
        HistoryHeader(
            showClearAll = uiState.sessions.isNotEmpty(),
            onClearAllClick = viewModel::showClearAllConfirmation
        )

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Content area
        when {
            uiState.isLoading -> {
                LoadingIndicator()
            }

            uiState.sessions.isEmpty() -> {
                EmptyHistoryPlaceholder()
            }

            else -> {
                SessionList(
                    sessions = uiState.sessions,
                    onSessionClick = onSessionClick,
                    onDeleteClick = viewModel::selectForDeletion
                )
            }
        }
    }
}

/**
 * Header row with title and optional clear all button.
 *
 * @param showClearAll Whether to show the clear all button
 * @param onClearAllClick Callback when clear all is tapped
 */
@Composable
private fun HistoryHeader(
    showClearAll: Boolean,
    onClearAllClick: () -> Unit
) {
    Row(
        verticalAlignment = Alignment.CenterVertically,
        modifier = Modifier.fillMaxWidth()
    ) {
        Text(
            text = "History",
            style = MaterialTheme.typography.headlineMedium,
            modifier = Modifier.weight(1f)
        )

        if (showClearAll) {
            IconButton(onClick = onClearAllClick) {
                Icon(
                    imageVector = Icons.Default.DeleteSweep,
                    contentDescription = "Clear all history",
                    tint = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}

/**
 * Centered loading indicator.
 */
@Composable
private fun LoadingIndicator() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.fillMaxSize()
    ) {
        CircularProgressIndicator()
    }
}

/**
 * Placeholder shown when there are no sessions in history.
 */
@Composable
private fun EmptyHistoryPlaceholder() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier.fillMaxSize()
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.History,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.height(Constants.UI_ICON_SIZE_LARGE.dp)
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "No History Yet",
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = "Completed fact-checks will appear here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}

/**
 * Scrollable list of session cards.
 *
 * @param sessions List of sessions with reports to display
 * @param onSessionClick Callback when a session card is tapped
 * @param onDeleteClick Callback when a session's delete button is tapped
 */
@Composable
private fun SessionList(
    sessions: List<SessionWithReport>,
    onSessionClick: (String) -> Unit,
    onDeleteClick: (String) -> Unit
) {
    LazyColumn(
        verticalArrangement = Arrangement.spacedBy(Constants.HISTORY_CARD_SPACING.dp)
    ) {
        items(
            items = sessions,
            key = { it.session.id }
        ) { sessionWithReport ->
            SessionCard(
                sessionWithReport = sessionWithReport,
                onClick = { onSessionClick(sessionWithReport.session.id) },
                onDelete = { onDeleteClick(sessionWithReport.session.id) }
            )
        }
    }
}

/**
 * Confirmation dialog for deleting a single session.
 *
 * @param onConfirm Callback when delete is confirmed
 * @param onDismiss Callback when deletion is cancelled
 */
@Composable
private fun DeleteSessionDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Delete Session?") },
        text = {
            Text(
                "This will permanently delete the session and its report. " +
                    "This action cannot be undone."
            )
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                )
            ) {
                Text("Delete")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

/**
 * Confirmation dialog for clearing all history.
 *
 * @param onConfirm Callback when clear all is confirmed
 * @param onDismiss Callback when clearing is cancelled
 */
@Composable
private fun ClearAllDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Clear All History?") },
        text = {
            Text(
                "This will permanently delete all sessions and reports. " +
                    "This action cannot be undone."
            )
        },
        confirmButton = {
            TextButton(
                onClick = onConfirm,
                colors = ButtonDefaults.textButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                )
            ) {
                Text("Clear All")
            }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) {
                Text("Cancel")
            }
        }
    )
}

// ==================== Previews ====================

@Preview(showBackground = true)
@Composable
private fun EmptyHistoryPlaceholderPreview() {
    MedicalFactCheckerTheme {
        EmptyHistoryPlaceholder()
    }
}

@Preview(showBackground = true)
@Composable
private fun HistoryHeaderPreview() {
    MedicalFactCheckerTheme {
        HistoryHeader(
            showClearAll = true,
            onClearAllClick = {}
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun DeleteSessionDialogPreview() {
    MedicalFactCheckerTheme {
        DeleteSessionDialog(
            onConfirm = {},
            onDismiss = {}
        )
    }
}
