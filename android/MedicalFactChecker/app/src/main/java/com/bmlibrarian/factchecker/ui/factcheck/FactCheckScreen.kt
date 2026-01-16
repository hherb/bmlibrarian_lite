package com.bmlibrarian.factchecker.ui.factcheck

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import com.bmlibrarian.factchecker.ui.factcheck.components.ClaimInput
import com.bmlibrarian.factchecker.ui.factcheck.components.DocumentCard
import com.bmlibrarian.factchecker.ui.factcheck.components.FetchMorePrompt
import com.bmlibrarian.factchecker.ui.factcheck.components.SearchProgress
import com.bmlibrarian.factchecker.util.CostCalculator

/**
 * Main fact-checking screen.
 *
 * Provides the primary interface for entering medical claims and
 * observing the fact-checking workflow progress.
 *
 * @param viewModel The ViewModel managing screen state
 * @param onNavigateToReport Callback when workflow completes to navigate to report
 */
@Composable
fun FactCheckScreen(
    viewModel: FactCheckViewModel = hiltViewModel(),
    onNavigateToReport: () -> Unit = {}
) {
    val uiState by viewModel.uiState.collectAsState()

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        // Configuration warning banner
        if (uiState.showConfigWarning) {
            ConfigWarningBanner()
            Spacer(modifier = Modifier.height(16.dp))
        }

        // Budget display
        BudgetDisplay(
            monthlyUsed = uiState.monthlyUsedUsd,
            monthlyBudget = uiState.monthlyBudgetUsd,
            runBudget = uiState.runBudgetUsd
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Claim input section
        ClaimInput(
            claimText = uiState.claimText,
            onClaimTextChange = viewModel::updateClaimText,
            onSubmit = viewModel::startFactCheck,
            isEnabled = !uiState.isRunning && !uiState.showConfigWarning,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Progress/State section
        when (val state = uiState.workflowState) {
            is WorkflowState.Idle -> {
                if (uiState.documents.isEmpty()) {
                    IdlePlaceholder()
                }
            }

            is WorkflowState.AwaitingUserDecision -> {
                FetchMorePrompt(
                    relevantCount = state.relevantCount,
                    targetCount = state.targetCount,
                    availableCount = state.availableCount,
                    onFetchMore = viewModel::fetchMoreDocuments,
                    onSkip = viewModel::skipMoreDocuments
                )
            }

            is WorkflowState.Completed -> {
                CompletedMessage(
                    reportId = state.reportId,
                    onViewReport = onNavigateToReport
                )
            }

            is WorkflowState.Failed -> {
                ErrorMessage(
                    error = state.error,
                    onDismiss = viewModel::clearError
                )
            }

            is WorkflowState.BudgetExceeded -> {
                BudgetExceededMessage(
                    message = state.message,
                    currentCost = state.currentCostUsd,
                    budgetLimit = state.budgetLimitUsd
                )
            }

            else -> {
                // Show progress for all active states
                SearchProgress(
                    progress = uiState.progress,
                    onCancel = viewModel::cancel
                )
            }
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Scored documents list
        if (uiState.documents.isNotEmpty()) {
            Text(
                text = "Scored Documents (${uiState.documents.size})",
                style = MaterialTheme.typography.titleMedium,
                modifier = Modifier.padding(bottom = 8.dp)
            )

            LazyColumn(
                verticalArrangement = Arrangement.spacedBy(8.dp),
                modifier = Modifier.weight(1f)
            ) {
                items(
                    items = uiState.documents,
                    key = { it.id }
                ) { document ->
                    DocumentCard(document = document)
                }
            }
        }
    }
}

/**
 * Warning banner shown when LLM is not configured.
 */
@Composable
private fun ConfigWarningBanner() {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.padding(16.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Warning,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = "Please configure your LLM provider and API key in Settings before starting.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer
            )
        }
    }
}

/**
 * Display current budget usage.
 */
@Composable
private fun BudgetDisplay(
    monthlyUsed: Double,
    monthlyBudget: Double,
    runBudget: Double
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier
                .fillMaxWidth()
                .padding(16.dp)
        ) {
            Column {
                Text(
                    text = "Budget",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = "${CostCalculator.formatCost(monthlyUsed)} / ${CostCalculator.formatCost(monthlyBudget)} monthly",
                    style = MaterialTheme.typography.bodyMedium
                )
            }

            Column(horizontalAlignment = Alignment.End) {
                Text(
                    text = "Per run limit",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Text(
                    text = CostCalculator.formatCost(runBudget),
                    style = MaterialTheme.typography.bodyMedium
                )
            }
        }
    }
}

/**
 * Placeholder shown when no fact-check is in progress.
 */
@Composable
private fun IdlePlaceholder() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxWidth()
            .padding(32.dp)
    ) {
        Text(
            text = "Enter a medical claim above to start fact-checking.\n\nExample: \"Vitamin D supplementation prevents COVID-19 infection\"",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/**
 * Message shown when fact-check is complete.
 */
@Composable
private fun CompletedMessage(
    reportId: String,
    onViewReport: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Fact-check complete!",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "View the evidence report in the Report tab.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
            Spacer(modifier = Modifier.height(8.dp))
            TextButton(onClick = onViewReport) {
                Text("View Report")
            }
        }
    }
}

/**
 * Error message display.
 */
@Composable
private fun ErrorMessage(
    error: String,
    onDismiss: () -> Unit
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Error",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = error,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer
            )
            Spacer(modifier = Modifier.height(12.dp))
            TextButton(onClick = onDismiss) {
                Text("Dismiss")
            }
        }
    }
}

/**
 * Message shown when budget is exceeded.
 */
@Composable
private fun BudgetExceededMessage(
    message: String,
    currentCost: Double,
    budgetLimit: Double
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.tertiaryContainer
        ),
        modifier = Modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Budget Exceeded",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Text(
                text = "Current: ${CostCalculator.formatCost(currentCost)} / Limit: ${CostCalculator.formatCost(budgetLimit)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
        }
    }
}
