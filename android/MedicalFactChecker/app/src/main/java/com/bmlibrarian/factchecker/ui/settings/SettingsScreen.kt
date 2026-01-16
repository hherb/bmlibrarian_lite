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

package com.bmlibrarian.factchecker.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.ui.settings.components.ModelPricingTable
import com.bmlibrarian.factchecker.ui.settings.components.ModelSelector
import com.bmlibrarian.factchecker.ui.settings.components.ProviderSelector
import com.bmlibrarian.factchecker.ui.settings.components.SearchProviderSelector
import com.bmlibrarian.factchecker.ui.settings.components.SettingsSection
import com.bmlibrarian.factchecker.ui.settings.components.SliderSetting
import com.bmlibrarian.factchecker.util.Constants
import java.util.Locale

/**
 * Settings and configuration screen.
 *
 * Allows users to configure LLM provider, API keys, budget limits,
 * search settings, and other app preferences. Uses Material 3
 * components organized into logical sections.
 *
 * @param viewModel The SettingsViewModel instance (injected via Hilt)
 */
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val settings by viewModel.settings.collectAsState()
    val apiKeyInput by viewModel.apiKeyInput.collectAsState()
    val hasApiKey by viewModel.hasApiKey.collectAsState()
    val requiresApiKey by viewModel.requiresApiKey.collectAsState()
    val currentModels by viewModel.currentModels.collectAsState()
    val statusMessage by viewModel.statusMessage.collectAsState()
    val estimatedCostPerRun by viewModel.estimatedCostPerRun.collectAsState()

    var showResetDialog by remember { mutableStateOf(false) }
    var showApiKey by remember { mutableStateOf(false) }
    val snackbarHostState = remember { SnackbarHostState() }

    // Show status message in snackbar
    LaunchedEffect(statusMessage) {
        statusMessage?.let {
            snackbarHostState.showSnackbar(it)
            viewModel.clearStatusMessage()
        }
    }

    Scaffold(
        snackbarHost = {
            SnackbarHost(hostState = snackbarHostState)
        }
    ) { paddingValues ->
        Column(
            modifier = Modifier
                .fillMaxSize()
                .verticalScroll(rememberScrollState())
                .padding(paddingValues)
                .padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            Text(
                text = "Settings",
                style = MaterialTheme.typography.headlineMedium
            )

            Spacer(modifier = Modifier.height((Constants.UI_SECTION_SPACING + Constants.UI_ELEMENT_SPACING).dp))

            // LLM Provider Section
            LLMProviderSection(
                settings = settings,
                apiKeyInput = apiKeyInput,
                hasApiKey = hasApiKey,
                requiresApiKey = requiresApiKey,
                showApiKey = showApiKey,
                currentModels = currentModels,
                providers = viewModel.providers,
                onProviderSelected = viewModel::setProvider,
                onModelSelected = viewModel::setModel,
                onApiKeyInputChange = viewModel::updateApiKeyInput,
                onToggleApiKeyVisibility = { showApiKey = !showApiKey },
                onSaveApiKey = viewModel::saveApiKey,
                onClearApiKey = viewModel::clearApiKey,
                onCustomBaseUrlChange = viewModel::setCustomBaseUrl
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            // Search Settings Section
            SearchSettingsSection(
                settings = settings,
                onSearchProviderSelected = viewModel::setSearchProvider,
                onIncludePreprintsChange = viewModel::setIncludePreprints,
                onBatchSizeChange = viewModel::setBatchSize,
                onRelevanceThresholdChange = viewModel::setRelevanceThreshold,
                onTargetRelevantDocsChange = viewModel::setTargetRelevantDocuments
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            // Budget Settings Section
            BudgetSettingsSection(
                settings = settings,
                estimatedCostPerRun = estimatedCostPerRun,
                onMaxRunBudgetChange = viewModel::setMaxRunBudget,
                onMonthlyBudgetChange = viewModel::setMonthlyBudget
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            // Advanced Section
            AdvancedSection(
                ncbiEmail = settings.ncbiEmail,
                onNcbiEmailChange = viewModel::setNcbiEmail,
                onResetClick = { showResetDialog = true }
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            // Model Pricing Info
            if (currentModels.isNotEmpty()) {
                SettingsSection(title = "Model Pricing") {
                    ModelPricingTable(models = currentModels)
                }
            }

            Spacer(modifier = Modifier.height(Constants.UI_PLACEHOLDER_PADDING.dp))
        }
    }

    // Reset confirmation dialog
    if (showResetDialog) {
        ResetConfirmationDialog(
            onConfirm = {
                viewModel.resetToDefaults()
                showResetDialog = false
            },
            onDismiss = { showResetDialog = false }
        )
    }
}

/**
 * LLM Provider configuration section.
 *
 * Contains provider selection, model selection, and API key management.
 */
@Composable
private fun LLMProviderSection(
    settings: com.bmlibrarian.factchecker.domain.model.AppSettings,
    apiKeyInput: String,
    hasApiKey: Boolean,
    requiresApiKey: Boolean,
    showApiKey: Boolean,
    currentModels: List<com.bmlibrarian.factchecker.domain.model.ModelInfo>,
    providers: List<LLMProvider>,
    onProviderSelected: (String) -> Unit,
    onModelSelected: (String) -> Unit,
    onApiKeyInputChange: (String) -> Unit,
    onToggleApiKeyVisibility: () -> Unit,
    onSaveApiKey: () -> Unit,
    onClearApiKey: () -> Unit,
    onCustomBaseUrlChange: (String) -> Unit
) {
    SettingsSection(title = "LLM Provider") {
        // Provider selector
        ProviderSelector(
            selectedProviderId = settings.llmProviderId,
            providers = providers,
            onProviderSelected = onProviderSelected
        )

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Model selector
        if (currentModels.isNotEmpty()) {
            ModelSelector(
                selectedModelId = settings.modelId,
                models = currentModels,
                onModelSelected = onModelSelected
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
        }

        // API Key input (only show if required)
        if (requiresApiKey) {
            OutlinedTextField(
                value = apiKeyInput,
                onValueChange = onApiKeyInputChange,
                label = { Text("API Key") },
                placeholder = { Text("Enter your API key") },
                visualTransformation = if (showApiKey) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                trailingIcon = {
                    IconButton(onClick = onToggleApiKeyVisibility) {
                        Icon(
                            imageVector = if (showApiKey) {
                                Icons.Default.VisibilityOff
                            } else {
                                Icons.Default.Visibility
                            },
                            contentDescription = if (showApiKey) "Hide API key" else "Show API key"
                        )
                    }
                },
                supportingText = {
                    if (hasApiKey) {
                        Text(
                            "API key configured",
                            color = MaterialTheme.colorScheme.primary
                        )
                    }
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
                modifier = Modifier.align(Alignment.End)
            ) {
                if (hasApiKey) {
                    OutlinedButton(
                        onClick = onClearApiKey,
                        colors = ButtonDefaults.outlinedButtonColors(
                            contentColor = MaterialTheme.colorScheme.error
                        )
                    ) {
                        Text("Clear")
                    }
                }
                Button(
                    onClick = onSaveApiKey,
                    enabled = apiKeyInput.isNotBlank()
                ) {
                    Text("Save API Key")
                }
            }
        }

        // Custom URL for custom provider
        if (settings.llmProviderId == LLMProvider.CUSTOM.id) {
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            OutlinedTextField(
                value = settings.customBaseUrl,
                onValueChange = onCustomBaseUrlChange,
                label = { Text("Custom Base URL") },
                placeholder = { Text("https://api.example.com/v1") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )
        }
    }
}

/**
 * Search settings section.
 *
 * Contains search provider selection, preprint toggle, and batch settings.
 */
@Composable
private fun SearchSettingsSection(
    settings: com.bmlibrarian.factchecker.domain.model.AppSettings,
    onSearchProviderSelected: (com.bmlibrarian.factchecker.domain.model.SearchProvider) -> Unit,
    onIncludePreprintsChange: (Boolean) -> Unit,
    onBatchSizeChange: (Int) -> Unit,
    onRelevanceThresholdChange: (Int) -> Unit,
    onTargetRelevantDocsChange: (Int) -> Unit
) {
    SettingsSection(title = "Search Settings") {
        // Search provider
        Text(
            text = "Search Provider",
            style = MaterialTheme.typography.labelLarge
        )
        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        SearchProviderSelector(
            selectedProvider = settings.searchProvider,
            onProviderSelected = onSearchProviderSelected
        )

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Include preprints toggle
        Row(
            verticalAlignment = Alignment.CenterVertically,
            modifier = Modifier.fillMaxWidth()
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = "Include Preprints",
                    style = MaterialTheme.typography.bodyLarge
                )
                Text(
                    text = "Show preprints in search results",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            Switch(
                checked = settings.includePreprints,
                onCheckedChange = onIncludePreprintsChange
            )
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Batch size slider
        SliderSetting(
            label = "Batch Size",
            value = settings.batchSize.toFloat(),
            onValueChange = { onBatchSizeChange(it.toInt()) },
            valueRange = Constants.SETTINGS_MIN_BATCH_SIZE..Constants.SETTINGS_MAX_BATCH_SIZE,
            steps = Constants.SETTINGS_BATCH_SIZE_STEPS,
            valueDisplay = "${settings.batchSize} documents"
        )

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Relevance threshold slider
        SliderSetting(
            label = "Relevance Threshold",
            value = settings.relevanceThreshold.toFloat(),
            onValueChange = { onRelevanceThresholdChange(it.toInt()) },
            valueRange = Constants.SCORING_MIN_SCORE.toFloat()..Constants.SCORING_MAX_SCORE.toFloat(),
            steps = Constants.SCORING_MAX_SCORE - Constants.SCORING_MIN_SCORE - 1,
            valueDisplay = "${settings.relevanceThreshold}/${Constants.SCORING_MAX_SCORE} minimum"
        )

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Target relevant documents slider
        SliderSetting(
            label = "Target Relevant Documents",
            value = settings.targetRelevantDocuments.toFloat(),
            onValueChange = { onTargetRelevantDocsChange(it.toInt()) },
            valueRange = Constants.SETTINGS_MIN_TARGET_DOCS..Constants.SETTINGS_MAX_TARGET_DOCS,
            steps = Constants.SETTINGS_TARGET_DOCS_STEPS,
            valueDisplay = "${settings.targetRelevantDocuments} documents"
        )
    }
}

/**
 * Budget settings section.
 *
 * Contains per-run and monthly budget sliders with cost estimate display.
 */
@Composable
private fun BudgetSettingsSection(
    settings: com.bmlibrarian.factchecker.domain.model.AppSettings,
    estimatedCostPerRun: String,
    onMaxRunBudgetChange: (Double) -> Unit,
    onMonthlyBudgetChange: (Double) -> Unit
) {
    SettingsSection(title = "Budget Limits") {
        // Estimated cost display
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "Estimated cost per run",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = estimatedCostPerRun,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary
            )
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Per-run budget slider
        SliderSetting(
            label = "Per-Run Budget",
            value = settings.maxRunBudgetUsd.toFloat(),
            onValueChange = { onMaxRunBudgetChange(it.toDouble()) },
            valueRange = Constants.SETTINGS_MIN_RUN_BUDGET_USD..Constants.SETTINGS_MAX_RUN_BUDGET_USD,
            steps = Constants.SETTINGS_RUN_BUDGET_STEPS,
            valueDisplay = formatBudget(settings.maxRunBudgetUsd)
        )

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Monthly budget slider
        SliderSetting(
            label = "Monthly Budget",
            value = settings.monthlyBudgetUsd.toFloat(),
            onValueChange = { onMonthlyBudgetChange(it.toDouble()) },
            valueRange = Constants.SETTINGS_MIN_MONTHLY_BUDGET_USD..Constants.SETTINGS_MAX_MONTHLY_BUDGET_USD,
            steps = Constants.SETTINGS_MONTHLY_BUDGET_STEPS,
            valueDisplay = formatBudget(settings.monthlyBudgetUsd)
        )
    }
}

/**
 * Advanced settings section.
 *
 * Contains NCBI configuration and reset options.
 */
@Composable
private fun AdvancedSection(
    ncbiEmail: String,
    onNcbiEmailChange: (String) -> Unit,
    onResetClick: () -> Unit
) {
    SettingsSection(title = "Advanced") {
        // NCBI Email
        OutlinedTextField(
            value = ncbiEmail,
            onValueChange = onNcbiEmailChange,
            label = { Text("NCBI Email (optional)") },
            placeholder = { Text("your@email.com") },
            supportingText = { Text("Increases PubMed rate limit") },
            singleLine = true,
            modifier = Modifier.fillMaxWidth()
        )

        Spacer(modifier = Modifier.height((Constants.UI_SECTION_SPACING + Constants.UI_ELEMENT_SPACING).dp))

        // Reset button
        OutlinedButton(
            onClick = onResetClick,
            colors = ButtonDefaults.outlinedButtonColors(
                contentColor = MaterialTheme.colorScheme.error
            ),
            modifier = Modifier.fillMaxWidth()
        ) {
            Text("Reset to Defaults")
        }
    }
}

/**
 * Reset confirmation dialog.
 *
 * Warns user that reset will clear all settings and API keys.
 */
@Composable
private fun ResetConfirmationDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Reset Settings?") },
        text = {
            Text(
                "This will reset all settings to their defaults and remove all API keys. " +
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
                Text("Reset")
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
 * Format a budget value for display.
 *
 * @param value The budget value in USD
 * @return Formatted budget string (e.g., "$0.50")
 */
private fun formatBudget(value: Double): String {
    return String.format(
        Locale.US,
        "$%.${Constants.SETTINGS_BUDGET_DECIMAL_PLACES}f",
        value
    )
}
