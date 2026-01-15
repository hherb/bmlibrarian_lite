# Phase 6: UI - Navigation & FactCheck Screen

## Overview

This phase implements the main navigation structure and the primary FactCheck screen. The FactCheck screen is the core interface where users enter claims and see the fact-checking process unfold.

**Estimated Duration**: 1-2 weeks
**Prerequisites**: Phases 1-5 completed
**Deliverable**: Working navigation and end-to-end fact-check screen

## UI Architecture

```
┌─────────────────────────────────────────────────────┐
│                    MainActivity                      │
│  ┌───────────────────────────────────────────────┐  │
│  │               AppNavigation                    │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │          NavHost (Screens)              │  │  │
│  │  │  ┌─────┐ ┌──────┐ ┌───────┐ ┌────────┐  │  │  │
│  │  │  │Check│ │Report│ │History│ │Settings│  │  │  │
│  │  │  └─────┘ └──────┘ └───────┘ └────────┘  │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  │  ┌─────────────────────────────────────────┐  │  │
│  │  │         BottomNavigationBar             │  │  │
│  │  └─────────────────────────────────────────┘  │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Tasks

### 6.1 Create Navigation Routes

```kotlin
// ui/navigation/NavRoutes.kt
package com.bmlibrarian.factchecker.ui.navigation

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.History
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material.icons.outlined.CheckCircle
import androidx.compose.material.icons.outlined.Description
import androidx.compose.material.icons.outlined.History
import androidx.compose.material.icons.outlined.Settings
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Navigation routes for the app.
 */
sealed class NavRoute(
    val route: String,
    val title: String,
    val selectedIcon: ImageVector,
    val unselectedIcon: ImageVector
) {
    data object FactCheck : NavRoute(
        route = "factcheck",
        title = "Check",
        selectedIcon = Icons.Filled.CheckCircle,
        unselectedIcon = Icons.Outlined.CheckCircle
    )

    data object Report : NavRoute(
        route = "report",
        title = "Report",
        selectedIcon = Icons.Filled.Description,
        unselectedIcon = Icons.Outlined.Description
    )

    data object History : NavRoute(
        route = "history",
        title = "History",
        selectedIcon = Icons.Filled.History,
        unselectedIcon = Icons.Outlined.History
    )

    data object Settings : NavRoute(
        route = "settings",
        title = "Settings",
        selectedIcon = Icons.Filled.Settings,
        unselectedIcon = Icons.Outlined.Settings
    )

    // Non-bottom-nav routes
    data object Disclaimer : NavRoute(
        route = "disclaimer",
        title = "Disclaimer",
        selectedIcon = Icons.Filled.CheckCircle,
        unselectedIcon = Icons.Outlined.CheckCircle
    )

    data object Onboarding : NavRoute(
        route = "onboarding",
        title = "Welcome",
        selectedIcon = Icons.Filled.CheckCircle,
        unselectedIcon = Icons.Outlined.CheckCircle
    )

    companion object {
        val bottomNavItems = listOf(FactCheck, Report, History, Settings)
    }
}
```

### 6.2 Create App Navigation

```kotlin
// ui/navigation/AppNavigation.kt
package com.bmlibrarian.factchecker.ui.navigation

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.hilt.navigation.compose.hiltViewModel
import androidx.navigation.NavDestination.Companion.hierarchy
import androidx.navigation.NavGraph.Companion.findStartDestination
import androidx.navigation.compose.NavHost
import androidx.navigation.compose.composable
import androidx.navigation.compose.currentBackStackEntryAsState
import androidx.navigation.compose.rememberNavController
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.ui.factcheck.FactCheckScreen
import com.bmlibrarian.factchecker.ui.history.HistoryScreen
import com.bmlibrarian.factchecker.ui.onboarding.DisclaimerScreen
import com.bmlibrarian.factchecker.ui.onboarding.OnboardingScreen
import com.bmlibrarian.factchecker.ui.report.ReportScreen
import com.bmlibrarian.factchecker.ui.settings.SettingsScreen

/**
 * Main navigation component for the app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun AppNavigation(
    settingsRepository: SettingsRepository = hiltViewModel<AppNavigationViewModel>().settingsRepository
) {
    val navController = rememberNavController()
    val settings by settingsRepository.settings.collectAsState()

    // Determine start destination based on onboarding state
    val startDestination = when {
        !settings.hasAcceptedDisclaimer -> NavRoute.Disclaimer.route
        !settings.hasCompletedOnboarding -> NavRoute.Onboarding.route
        else -> NavRoute.FactCheck.route
    }

    val navBackStackEntry by navController.currentBackStackEntryAsState()
    val currentDestination = navBackStackEntry?.destination

    // Show bottom nav only for main screens
    val showBottomNav = currentDestination?.route in NavRoute.bottomNavItems.map { it.route }

    Scaffold(
        bottomBar = {
            if (showBottomNav) {
                NavigationBar {
                    NavRoute.bottomNavItems.forEach { navItem ->
                        val selected = currentDestination?.hierarchy?.any {
                            it.route == navItem.route
                        } == true

                        NavigationBarItem(
                            selected = selected,
                            onClick = {
                                navController.navigate(navItem.route) {
                                    popUpTo(navController.graph.findStartDestination().id) {
                                        saveState = true
                                    }
                                    launchSingleTop = true
                                    restoreState = true
                                }
                            },
                            icon = {
                                Icon(
                                    imageVector = if (selected) navItem.selectedIcon else navItem.unselectedIcon,
                                    contentDescription = navItem.title
                                )
                            },
                            label = { Text(navItem.title) }
                        )
                    }
                }
            }
        }
    ) { paddingValues ->
        NavHost(
            navController = navController,
            startDestination = startDestination,
            modifier = Modifier.padding(paddingValues)
        ) {
            // Onboarding flow
            composable(NavRoute.Disclaimer.route) {
                DisclaimerScreen(
                    onAccept = {
                        settingsRepository.acceptDisclaimer()
                        navController.navigate(NavRoute.Onboarding.route) {
                            popUpTo(NavRoute.Disclaimer.route) { inclusive = true }
                        }
                    }
                )
            }

            composable(NavRoute.Onboarding.route) {
                OnboardingScreen(
                    onComplete = {
                        settingsRepository.completeOnboarding()
                        navController.navigate(NavRoute.FactCheck.route) {
                            popUpTo(NavRoute.Onboarding.route) { inclusive = true }
                        }
                    }
                )
            }

            // Main screens
            composable(NavRoute.FactCheck.route) {
                FactCheckScreen()
            }

            composable(NavRoute.Report.route) {
                ReportScreen()
            }

            composable(NavRoute.History.route) {
                HistoryScreen(
                    onSessionClick = { sessionId ->
                        // Navigate to report for this session
                        navController.navigate(NavRoute.Report.route)
                    }
                )
            }

            composable(NavRoute.Settings.route) {
                SettingsScreen()
            }
        }
    }
}

/**
 * ViewModel for AppNavigation to access settings.
 */
@dagger.hilt.android.lifecycle.HiltViewModel
class AppNavigationViewModel @javax.inject.Inject constructor(
    val settingsRepository: SettingsRepository
) : androidx.lifecycle.ViewModel()
```

### 6.3 Create FactCheck ViewModel

```kotlin
// ui/factcheck/FactCheckViewModel.kt
package com.bmlibrarian.factchecker.ui.factcheck

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowConfig
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * UI state for the FactCheck screen.
 */
data class FactCheckUiState(
    val claimText: String = "",
    val isRunning: Boolean = false,
    val workflowState: WorkflowState = WorkflowState.Idle,
    val progress: WorkflowProgress = WorkflowProgress(
        step = com.bmlibrarian.factchecker.domain.model.WorkflowStep.IDLE,
        message = "Ready to fact-check",
        percentage = 0f
    ),
    val documents: List<DocumentEntity> = emptyList(),
    val showConfigWarning: Boolean = false,
    val errorMessage: String? = null
)

/**
 * ViewModel for the FactCheck screen.
 */
@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val workflow: FactCheckWorkflow,
    private val settingsRepository: SettingsRepository,
    private val documentRepository: DocumentRepository
) : ViewModel() {

    private val _uiState = MutableStateFlow(FactCheckUiState())
    val uiState: StateFlow<FactCheckUiState> = _uiState.asStateFlow()

    // Current session ID
    private var currentSessionId: String? = null

    init {
        // Observe workflow state
        viewModelScope.launch {
            workflow.state.collect { state ->
                _uiState.update {
                    it.copy(
                        workflowState = state,
                        isRunning = state !is WorkflowState.Idle &&
                                   state !is WorkflowState.Completed &&
                                   state !is WorkflowState.Failed &&
                                   state !is WorkflowState.BudgetExceeded,
                        errorMessage = when (state) {
                            is WorkflowState.Failed -> state.error
                            is WorkflowState.BudgetExceeded -> state.message
                            else -> null
                        }
                    )
                }
            }
        }

        // Observe workflow progress
        viewModelScope.launch {
            workflow.progress.collect { progress ->
                _uiState.update { it.copy(progress = progress) }
            }
        }

        // Check configuration on init
        checkConfiguration()
    }

    /**
     * Update the claim text.
     */
    fun updateClaimText(text: String) {
        _uiState.update { it.copy(claimText = text) }
    }

    /**
     * Start the fact-check process.
     */
    fun startFactCheck() {
        val claim = _uiState.value.claimText.trim()
        if (claim.isEmpty()) return

        viewModelScope.launch {
            val settings = settingsRepository.getSettings()
            val config = WorkflowConfig(
                searchProvider = when (settings.searchProvider) {
                    com.bmlibrarian.factchecker.domain.model.SearchProvider.PUBMED ->
                        WorkflowConfig.SearchProvider.PUBMED
                    com.bmlibrarian.factchecker.domain.model.SearchProvider.EUROPE_PMC ->
                        WorkflowConfig.SearchProvider.EUROPE_PMC
                    com.bmlibrarian.factchecker.domain.model.SearchProvider.BOTH ->
                        WorkflowConfig.SearchProvider.BOTH
                },
                includePreprints = settings.includePreprints,
                batchSize = settings.batchSize,
                relevanceThreshold = settings.relevanceThreshold,
                targetRelevantDocuments = settings.targetRelevantDocuments,
                maxRunBudgetUsd = settings.maxRunBudgetUsd,
                monthlyBudgetUsd = settings.monthlyBudgetUsd
            )

            currentSessionId = workflow.startFactCheck(claim, config)

            // Observe documents for this session
            currentSessionId?.let { sessionId ->
                documentRepository.getScoredDocumentsBySession(sessionId)
                    .collect { docs ->
                        _uiState.update { it.copy(documents = docs) }
                    }
            }
        }
    }

    /**
     * User wants to fetch more documents.
     */
    fun fetchMoreDocuments() {
        viewModelScope.launch {
            val settings = settingsRepository.getSettings()
            workflow.fetchMoreDocuments(
                WorkflowConfig(
                    searchProvider = when (settings.searchProvider) {
                        com.bmlibrarian.factchecker.domain.model.SearchProvider.PUBMED ->
                            WorkflowConfig.SearchProvider.PUBMED
                        com.bmlibrarian.factchecker.domain.model.SearchProvider.EUROPE_PMC ->
                            WorkflowConfig.SearchProvider.EUROPE_PMC
                        com.bmlibrarian.factchecker.domain.model.SearchProvider.BOTH ->
                            WorkflowConfig.SearchProvider.BOTH
                    }
                )
            )
        }
    }

    /**
     * User declines to fetch more documents.
     */
    fun skipMoreDocuments() {
        viewModelScope.launch {
            workflow.skipMoreDocuments()
        }
    }

    /**
     * Cancel the current fact-check.
     */
    fun cancel() {
        workflow.reset()
        _uiState.update {
            it.copy(
                isRunning = false,
                errorMessage = null
            )
        }
    }

    /**
     * Clear any error message.
     */
    fun clearError() {
        _uiState.update { it.copy(errorMessage = null) }
    }

    /**
     * Check if settings are properly configured.
     */
    private fun checkConfiguration() {
        viewModelScope.launch {
            settingsRepository.settings.collect { settings ->
                val hasApiKey = settingsRepository.hasApiKey(settings.llmProviderId)
                _uiState.update {
                    it.copy(showConfigWarning = !settings.isConfigured || !hasApiKey)
                }
            }
        }
    }
}
```

### 6.4 Create FactCheck Screen

```kotlin
// ui/factcheck/FactCheckScreen.kt
package com.bmlibrarian.factchecker.ui.factcheck

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
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

/**
 * Main fact-checking screen.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FactCheckScreen(
    viewModel: FactCheckViewModel = hiltViewModel()
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

        // Claim input section
        ClaimInput(
            claimText = uiState.claimText,
            onClaimTextChange = viewModel::updateClaimText,
            onSubmit = viewModel::startFactCheck,
            isEnabled = !uiState.isRunning && !uiState.showConfigWarning,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Progress section
        when (val state = uiState.workflowState) {
            is WorkflowState.Idle -> {
                // Show placeholder or previous results
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
                CompletedMessage(reportId = state.reportId)
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
                    currentCost = state.currentCost,
                    budgetLimit = state.budgetLimit
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

@Composable
private fun CompletedMessage(reportId: String) {
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
        }
    }
}

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
                text = "Current: \$${String.format("%.4f", currentCost)} / Limit: \$${String.format("%.2f", budgetLimit)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onTertiaryContainer
            )
        }
    }
}
```

### 6.5 Create FactCheck Components

#### ClaimInput

```kotlin
// ui/factcheck/components/ClaimInput.kt
package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Input component for the medical claim.
 */
@Composable
fun ClaimInput(
    claimText: String,
    onClaimTextChange: (String) -> Unit,
    onSubmit: () -> Unit,
    isEnabled: Boolean,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier) {
        OutlinedTextField(
            value = claimText,
            onValueChange = onClaimTextChange,
            label = { Text("Medical Claim") },
            placeholder = { Text("Enter a medical claim to fact-check...") },
            enabled = isEnabled,
            minLines = 3,
            maxLines = 5,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height(12.dp))

        Button(
            onClick = onSubmit,
            enabled = isEnabled && claimText.isNotBlank(),
            modifier = Modifier.align(Alignment.End)
        ) {
            Icon(
                imageVector = Icons.Default.Search,
                contentDescription = null,
                modifier = Modifier.size(18.dp)
            )
            Spacer(modifier = Modifier.width(8.dp))
            Text("Check Claim")
        }
    }
}
```

#### SearchProgress

```kotlin
// ui/factcheck/components/SearchProgress.kt
package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.util.CostCalculator

/**
 * Progress indicator for the fact-check workflow.
 */
@Composable
fun SearchProgress(
    progress: WorkflowProgress,
    onCancel: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    strokeWidth = 2.dp
                )
                Spacer(modifier = Modifier.width(12.dp))
                Text(
                    text = progress.message,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f)
                )
            }

            Spacer(modifier = Modifier.height(12.dp))

            LinearProgressIndicator(
                progress = { progress.percentage },
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                Column {
                    if (progress.documentsFound > 0) {
                        Text(
                            text = "Documents: ${progress.documentsFound}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                    if (progress.documentsScored > 0) {
                        Text(
                            text = "Scored: ${progress.documentsScored}",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                Column(horizontalAlignment = Alignment.End) {
                    Text(
                        text = "Cost: ${CostCalculator.formatCost(progress.currentCostUsd)}",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Text(
                        text = "${(progress.percentage * 100).toInt()}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            TextButton(
                onClick = onCancel,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Cancel")
            }
        }
    }
}
```

#### DocumentCard

```kotlin
// ui/factcheck/components/DocumentCard.kt
package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.*
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.ui.theme.*

/**
 * Card displaying a scored document.
 */
@Composable
fun DocumentCard(
    document: DocumentEntity,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .animateContentSize()
            .clickable { expanded = !expanded }
    ) {
        Column(
            modifier = Modifier.padding(12.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth()
            ) {
                // Score badge
                document.relevanceScore?.let { score ->
                    ScoreBadge(
                        score = score,
                        modifier = Modifier.padding(end = 12.dp)
                    )
                }

                // Title and metadata
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = document.title,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = if (expanded) Int.MAX_VALUE else 2,
                        overflow = TextOverflow.Ellipsis
                    )

                    Spacer(modifier = Modifier.height(4.dp))

                    Text(
                        text = document.formattedAuthors,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        document.journal?.let {
                            Text(
                                text = it,
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
                                modifier = Modifier.weight(1f, fill = false)
                            )
                        }
                        document.publicationYear?.let {
                            Text(
                                text = "($it)",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant
                            )
                        }
                    }
                }

                // Expand icon
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Expand",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Expanded content
            if (expanded) {
                Spacer(modifier = Modifier.height(12.dp))
                HorizontalDivider()
                Spacer(modifier = Modifier.height(12.dp))

                // Source badges
                Row(
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    SourceBadge(source = document.source)
                    if (document.isPreprint) {
                        PreprintBadge()
                    }
                    document.pmid?.let {
                        Text(
                            text = "PMID: $it",
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant
                        )
                    }
                }

                // Abstract
                document.abstractText?.let { abstract ->
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Abstract",
                        style = MaterialTheme.typography.labelMedium
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = abstract,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // Score rationale
                document.scoreRationale?.let { rationale ->
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Relevance Assessment",
                        style = MaterialTheme.typography.labelMedium
                    )
                    Spacer(modifier = Modifier.height(4.dp))
                    Text(
                        text = rationale,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }
        }
    }
}

@Composable
private fun ScoreBadge(
    score: Int,
    modifier: Modifier = Modifier
) {
    val backgroundColor = when (score) {
        1 -> Score1
        2 -> Score2
        3 -> Score3
        4 -> Score4
        5 -> Score5
        else -> MaterialTheme.colorScheme.surfaceVariant
    }

    Surface(
        color = backgroundColor,
        shape = MaterialTheme.shapes.small,
        modifier = modifier
    ) {
        Text(
            text = score.toString(),
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 4.dp)
        )
    }
}

@Composable
private fun SourceBadge(source: String) {
    val displayText = when (source.lowercase()) {
        "pubmed" -> "PubMed"
        "europepmc" -> "Europe PMC"
        "preprint" -> "Preprint"
        else -> source
    }

    Surface(
        color = MaterialTheme.colorScheme.secondaryContainer,
        shape = MaterialTheme.shapes.small
    ) {
        Text(
            text = displayText,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSecondaryContainer,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
        )
    }
}

@Composable
private fun PreprintBadge() {
    Surface(
        color = MaterialTheme.colorScheme.tertiaryContainer,
        shape = MaterialTheme.shapes.small
    ) {
        Text(
            text = "Preprint",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onTertiaryContainer,
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 2.dp)
        )
    }
}
```

#### FetchMorePrompt

```kotlin
// ui/factcheck/components/FetchMorePrompt.kt
package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Prompt asking user if they want to fetch more documents.
 */
@Composable
fun FetchMorePrompt(
    relevantCount: Int,
    targetCount: Int,
    availableCount: Int,
    onFetchMore: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Fetch More Documents?",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = "Found $relevantCount relevant documents (target: $targetCount).",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer
            )

            Text(
                text = "Approximately $availableCount more documents available.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSecondaryContainer
            )

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                OutlinedButton(
                    onClick = onSkip,
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Skip")
                }

                Button(
                    onClick = onFetchMore,
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Fetch More")
                }
            }
        }
    }
}
```

## Verification Checklist

- [ ] Navigation shows correct bottom bar items
- [ ] Onboarding flow works (disclaimer → onboarding → main)
- [ ] Tab navigation preserves state
- [ ] FactCheck screen displays claim input
- [ ] Progress shows during workflow
- [ ] Documents appear as they are scored
- [ ] User decision prompt works
- [ ] Error states display correctly
- [ ] Cancel button stops the workflow
- [ ] Configuration warning appears when needed

## Testing

### UI Tests

```kotlin
// androidTest/ui/factcheck/FactCheckScreenTest.kt
@HiltAndroidTest
class FactCheckScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun claimInput_displaysAndAcceptsText() {
        composeRule.onNodeWithText("Medical Claim").assertExists()
        composeRule.onNodeWithText("Enter a medical claim").performTextInput("Test claim")
        composeRule.onNodeWithText("Test claim").assertExists()
    }

    @Test
    fun checkButton_disabledWhenEmpty() {
        composeRule.onNodeWithText("Check Claim").assertIsNotEnabled()
    }

    @Test
    fun checkButton_enabledWithText() {
        composeRule.onNodeWithText("Enter a medical claim").performTextInput("Test")
        composeRule.onNodeWithText("Check Claim").assertIsEnabled()
    }
}
```

## Next Phase

Continue to [Phase 7: UI - Report View](./07-ui-report.md)
