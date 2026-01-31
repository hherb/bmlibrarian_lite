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

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.animation.fadeIn
import androidx.compose.animation.fadeOut
import androidx.compose.animation.slideInVertically
import androidx.compose.animation.slideOutVertically
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.derivedStateOf
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import android.content.Intent
import android.net.Uri
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import com.bmlibrarian.factchecker.ui.factcheck.components.ClaimInput
import com.bmlibrarian.factchecker.ui.factcheck.components.DocumentCard
import com.bmlibrarian.factchecker.ui.factcheck.components.FetchMorePrompt
import com.bmlibrarian.factchecker.ui.factcheck.components.ResumedSessionBanner
import com.bmlibrarian.factchecker.ui.factcheck.components.SearchProgress
import com.bmlibrarian.factchecker.ui.factcheck.components.SortingControls
import com.bmlibrarian.factchecker.util.CostCalculator

/**
 * Main fact-checking screen.
 *
 * Provides the primary interface for entering medical claims and
 * observing the fact-checking workflow progress.
 *
 * @param viewModel The ViewModel managing screen state
 * @param sessionIdToRestore Optional session ID to restore from history
 * @param onNavigateToReport Callback when workflow completes to navigate to report
 * @param onNavigateToFullText Callback to navigate to full-text viewer for a document
 */
@Composable
fun FactCheckScreen(
    viewModel: FactCheckViewModel = hiltViewModel(),
    sessionIdToRestore: String? = null,
    onNavigateToReport: () -> Unit = {},
    onNavigateToFullText: (documentId: String) -> Unit = {}
) {
    val uiState by viewModel.uiState.collectAsState()
    val listState = rememberLazyListState()
    val context = LocalContext.current

    // Restore session if ID provided (from History navigation)
    LaunchedEffect(sessionIdToRestore) {
        if (sessionIdToRestore != null) {
            viewModel.restoreSession(sessionIdToRestore)
        }
    }

    // Show compact header when scrolled past the claim input section
    // The header becomes visible when user scrolls down past approximately the first 2 items
    val showCompactHeader by remember {
        derivedStateOf {
            val hasContent = uiState.claimText.isNotBlank() || uiState.generatedQuery != null
            val isScrolled = listState.firstVisibleItemIndex > 1 ||
                (listState.firstVisibleItemIndex == 1 && listState.firstVisibleItemScrollOffset > 100)
            hasContent && isScrolled
        }
    }

    Box(modifier = Modifier.fillMaxSize()) {
        // Main scrollable content
        LazyColumn(
            state = listState,
            contentPadding = PaddingValues(
                start = Constants.UI_SCREEN_PADDING.dp,
                end = Constants.UI_SCREEN_PADDING.dp,
                // Add top padding when compact header is shown to avoid overlap
                top = if (showCompactHeader) Constants.UI_COMPACT_HEADER_HEIGHT.dp else Constants.UI_SCREEN_PADDING.dp,
                bottom = Constants.UI_SCREEN_PADDING.dp
            ),
            verticalArrangement = Arrangement.spacedBy(Constants.UI_SECTION_SPACING.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            // Configuration warning banner
            if (uiState.showConfigWarning) {
                item(key = "config_warning") {
                    ConfigWarningBanner()
                }
            }

            // Budget display
            item(key = "budget") {
                BudgetDisplay(
                    monthlyUsed = uiState.monthlyUsedUsd,
                    monthlyBudget = uiState.monthlyBudgetUsd,
                    runBudget = uiState.runBudgetUsd
                )
            }

            // Claim input section
            item(key = "claim_input") {
                ClaimInput(
                    claimText = uiState.claimText,
                    onClaimTextChange = viewModel::updateClaimText,
                    onSubmit = if (uiState.isResumedSession) viewModel::addMoreResults else viewModel::startFactCheck,
                    isEnabled = !uiState.isRunning && !uiState.showConfigWarning,
                    modifier = Modifier.fillMaxWidth()
                )
            }

            // Resumed session banner (shown when restoring from history)
            if (uiState.isResumedSession) {
                item(key = "resumed_banner") {
                    ResumedSessionBanner(
                        documentCount = uiState.documents.size,
                        scoredCount = uiState.documents.count { it.relevanceScore != null },
                        canAddMore = uiState.canFetchMoreDocuments,
                        isLoading = uiState.isRunning,
                        onAddMore = viewModel::addMoreResults,
                        onNewQuestion = viewModel::startNewQuestion
                    )
                }
            }

            // Generated query display (show once generated)
            uiState.generatedQuery?.let { query ->
                if (query.isNotEmpty()) {
                    item(key = "query") {
                        GeneratedQueryDisplay(query = query)
                    }
                }
            }

            // Progress/State section
            item(key = "state") {
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
            }

            // Scored documents section
            if (uiState.documents.isNotEmpty()) {
                item(key = "documents_header") {
                    Column {
                        Text(
                            text = "Scored Documents (${uiState.documents.size})",
                            style = MaterialTheme.typography.titleMedium
                        )
                        SortingControls(
                            selectedSortOrder = uiState.sortOrder,
                            onSortOrderChange = viewModel::setSortOrder
                        )
                    }
                }

                items(
                    items = uiState.sortedDocuments,
                    key = { "doc_${it.id}" }
                ) { document ->
                    DocumentCard(
                        document = document,
                        isLoadingFullText = uiState.loadingFullTextDocumentId == document.id,
                        onGetFullText = { doc ->
                            viewModel.fetchFullText(doc) { success ->
                                if (success) {
                                    // Navigate to full-text viewer on success
                                    onNavigateToFullText(doc.id)
                                }
                            }
                        },
                        onViewFullText = { doc ->
                            onNavigateToFullText(doc.id)
                        },
                        onOpenPublisher = { doi ->
                            val url = "${Constants.DOI_URL_PREFIX}$doi"
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            context.startActivity(intent)
                        }
                    )
                }
            }
        }

        // Compact sticky header (visible when scrolled)
        AnimatedVisibility(
            visible = showCompactHeader,
            enter = slideInVertically(initialOffsetY = { -it }) + fadeIn(),
            exit = slideOutVertically(targetOffsetY = { -it }) + fadeOut(),
            modifier = Modifier.align(Alignment.TopCenter)
        ) {
            CompactContextHeader(
                claimText = uiState.claimText,
                generatedQuery = uiState.generatedQuery,
                documentCount = uiState.documents.size
            )
        }
    }
}

/**
 * Display for the generated PubMed query.
 *
 * Shows the query in a collapsible card (collapsed by default).
 * Tap to expand and see the full query without truncation.
 */
@Composable
private fun GeneratedQueryDisplay(query: String) {
    var expanded by remember { mutableStateOf(false) }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize()
            .clickable { expanded = !expanded }
    ) {
        Column(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = "PubMed Query:",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            AnimatedVisibility(visible = expanded) {
                Column {
                    Spacer(modifier = Modifier.height(8.dp))
                    Text(
                        text = query,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Warning,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.width(Constants.UI_ICON_TEXT_SPACING.dp))
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
                .padding(Constants.UI_CARD_PADDING.dp)
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
            .padding(Constants.UI_PLACEHOLDER_PADDING.dp)
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Text(
                text = "Fact-check complete!",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = "View the evidence report in the Report tab.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onPrimaryContainer
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Text(
                text = "Error",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = error,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onErrorContainer
            )
            Spacer(modifier = Modifier.height(Constants.UI_ICON_TEXT_SPACING.dp))
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Text(
                text = "Budget Exceeded",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
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

/**
 * Compact sticky header shown when scrolled past the main content.
 *
 * Displays a condensed 2-line summary of the current claim and query
 * to preserve context while maximizing screen space for documents.
 *
 * @param claimText The user's claim text
 * @param generatedQuery The generated PubMed query, if any
 * @param documentCount Number of scored documents
 */
@Composable
private fun CompactContextHeader(
    claimText: String,
    generatedQuery: String?,
    documentCount: Int
) {
    Column(
        modifier = Modifier
            .fillMaxWidth()
            .background(MaterialTheme.colorScheme.surface)
            .padding(
                horizontal = Constants.UI_SCREEN_PADDING.dp,
                vertical = Constants.UI_ELEMENT_SPACING.dp
            )
    ) {
        // First line: Claim text (truncated)
        Text(
            text = claimText.ifBlank { "Fact Check" },
            style = MaterialTheme.typography.titleSmall,
            maxLines = 1,
            overflow = TextOverflow.Ellipsis,
            color = MaterialTheme.colorScheme.onSurface
        )

        // Second line: Query preview and document count
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth()
        ) {
            generatedQuery?.let { query ->
                Text(
                    text = query,
                    style = MaterialTheme.typography.bodySmall,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
            }

            if (documentCount > 0) {
                Text(
                    text = "$documentCount docs",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.padding(start = Constants.UI_ELEMENT_SPACING.dp)
                )
            }
        }

        HorizontalDivider(
            modifier = Modifier.padding(top = Constants.UI_ELEMENT_SPACING.dp),
            color = MaterialTheme.colorScheme.outlineVariant
        )
    }
}
