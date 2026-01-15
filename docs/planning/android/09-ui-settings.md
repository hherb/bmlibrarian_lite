# Phase 9: UI - Settings View

## Overview

This phase implements the Settings screen where users configure LLM providers, API keys, search options, and budget limits.

**Estimated Duration**: 1 week
**Prerequisites**: Phases 1-8 completed
**Deliverable**: Full settings configuration UI

## Settings Screen Structure

```
┌─────────────────────────────────────────────────────┐
│                 Settings Screen                      │
│  ┌───────────────────────────────────────────────┐  │
│  │           LLM Provider Section                 │  │
│  │  - Provider selector                           │  │
│  │  - Model selector                              │  │
│  │  - API key input                               │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │           Search Settings Section              │  │
│  │  - Search provider (PubMed/Europe PMC/Both)    │  │
│  │  - Include preprints toggle                    │  │
│  │  - Batch size slider                           │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │           Budget Settings Section              │  │
│  │  - Per-run budget slider                       │  │
│  │  - Monthly budget slider                       │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │           Advanced Section                     │  │
│  │  - NCBI email/API key                          │  │
│  │  - Reset to defaults                           │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Tasks

### 9.1 Create Settings Screen

```kotlin
// ui/settings/SettingsScreen.kt
package com.bmlibrarian.factchecker.ui.settings

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Visibility
import androidx.compose.material.icons.filled.VisibilityOff
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.input.PasswordVisualTransformation
import androidx.compose.ui.text.input.VisualTransformation
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.ui.settings.components.*

/**
 * Settings screen for configuring the app.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SettingsScreen(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val settings by viewModel.settings.collectAsState()
    val apiKeyInput by viewModel.apiKeyInput.collectAsState()
    val hasApiKey by viewModel.hasApiKey.collectAsState()
    val currentModels by viewModel.currentModels.collectAsState()

    var showResetDialog by remember { mutableStateOf(false) }
    var showApiKey by remember { mutableStateOf(false) }

    Column(
        modifier = Modifier
            .fillMaxSize()
            .verticalScroll(rememberScrollState())
            .padding(16.dp)
    ) {
        Text(
            text = "Settings",
            style = MaterialTheme.typography.headlineMedium
        )

        Spacer(modifier = Modifier.height(24.dp))

        // LLM Provider Section
        SettingsSection(title = "LLM Provider") {
            // Provider selector
            ProviderSelector(
                selectedProviderId = settings.llmProviderId,
                providers = viewModel.providers,
                onProviderSelected = viewModel::setProvider
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Model selector
            ModelSelector(
                selectedModelId = settings.modelId,
                models = currentModels,
                onModelSelected = viewModel::setModel
            )

            Spacer(modifier = Modifier.height(16.dp))

            // API Key input
            OutlinedTextField(
                value = apiKeyInput,
                onValueChange = viewModel::updateApiKeyInput,
                label = { Text("API Key") },
                placeholder = { Text("Enter your API key") },
                visualTransformation = if (showApiKey) {
                    VisualTransformation.None
                } else {
                    PasswordVisualTransformation()
                },
                trailingIcon = {
                    Row {
                        IconButton(onClick = { showApiKey = !showApiKey }) {
                            Icon(
                                imageVector = if (showApiKey) {
                                    Icons.Default.VisibilityOff
                                } else {
                                    Icons.Default.Visibility
                                },
                                contentDescription = if (showApiKey) "Hide" else "Show"
                            )
                        }
                    }
                },
                supportingText = {
                    if (hasApiKey) {
                        Text("API key configured", color = MaterialTheme.colorScheme.primary)
                    }
                },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(8.dp))

            Button(
                onClick = viewModel::saveApiKey,
                enabled = apiKeyInput.isNotBlank(),
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Save API Key")
            }

            // Custom URL for custom provider
            if (settings.llmProviderId == "custom") {
                Spacer(modifier = Modifier.height(16.dp))
                OutlinedTextField(
                    value = settings.customBaseUrl,
                    onValueChange = viewModel::setCustomBaseUrl,
                    label = { Text("Custom Base URL") },
                    placeholder = { Text("https://api.example.com/v1") },
                    singleLine = true,
                    modifier = Modifier.fillMaxWidth()
                )
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Search Settings Section
        SettingsSection(title = "Search Settings") {
            // Search provider
            Text(
                text = "Search Provider",
                style = MaterialTheme.typography.labelLarge
            )
            Spacer(modifier = Modifier.height(8.dp))

            SearchProviderSelector(
                selectedProvider = settings.searchProvider,
                onProviderSelected = viewModel::setSearchProvider
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Include preprints
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
                    onCheckedChange = viewModel::setIncludePreprints
                )
            }

            Spacer(modifier = Modifier.height(16.dp))

            // Batch size slider
            SliderSetting(
                label = "Batch Size",
                value = settings.batchSize.toFloat(),
                onValueChange = { viewModel.setBatchSize(it.toInt()) },
                valueRange = 10f..50f,
                steps = 7,
                valueDisplay = "${settings.batchSize} documents"
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Relevance threshold slider
            SliderSetting(
                label = "Relevance Threshold",
                value = settings.relevanceThreshold.toFloat(),
                onValueChange = { viewModel.setRelevanceThreshold(it.toInt()) },
                valueRange = 1f..5f,
                steps = 3,
                valueDisplay = "${settings.relevanceThreshold}/5 minimum"
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Target relevant documents slider
            SliderSetting(
                label = "Target Relevant Documents",
                value = settings.targetRelevantDocuments.toFloat(),
                onValueChange = { viewModel.setTargetRelevantDocuments(it.toInt()) },
                valueRange = 5f..30f,
                steps = 4,
                valueDisplay = "${settings.targetRelevantDocuments} documents"
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Budget Settings Section
        SettingsSection(title = "Budget Limits") {
            // Per-run budget
            SliderSetting(
                label = "Per-Run Budget",
                value = settings.maxRunBudgetUsd.toFloat(),
                onValueChange = { viewModel.setMaxRunBudget(it.toDouble()) },
                valueRange = 0.10f..5.0f,
                steps = 48,
                valueDisplay = "$${String.format("%.2f", settings.maxRunBudgetUsd)}"
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Monthly budget
            SliderSetting(
                label = "Monthly Budget",
                value = settings.monthlyBudgetUsd.toFloat(),
                onValueChange = { viewModel.setMonthlyBudget(it.toDouble()) },
                valueRange = 1f..50f,
                steps = 48,
                valueDisplay = "$${String.format("%.2f", settings.monthlyBudgetUsd)}"
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Advanced Section
        SettingsSection(title = "Advanced") {
            // NCBI Email
            OutlinedTextField(
                value = settings.ncbiEmail,
                onValueChange = viewModel::setNcbiEmail,
                label = { Text("NCBI Email (optional)") },
                placeholder = { Text("your@email.com") },
                supportingText = { Text("Increases PubMed rate limit") },
                singleLine = true,
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(24.dp))

            // Reset button
            OutlinedButton(
                onClick = { showResetDialog = true },
                colors = ButtonDefaults.outlinedButtonColors(
                    contentColor = MaterialTheme.colorScheme.error
                ),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text("Reset to Defaults")
            }
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Model Pricing Info
        SettingsSection(title = "Model Pricing") {
            ModelPricingTable(models = currentModels)
        }

        Spacer(modifier = Modifier.height(32.dp))
    }

    // Reset confirmation dialog
    if (showResetDialog) {
        AlertDialog(
            onDismissRequest = { showResetDialog = false },
            title = { Text("Reset Settings?") },
            text = { Text("This will reset all settings to their defaults and remove all API keys. This action cannot be undone.") },
            confirmButton = {
                TextButton(
                    onClick = {
                        viewModel.resetToDefaults()
                        showResetDialog = false
                    },
                    colors = ButtonDefaults.textButtonColors(
                        contentColor = MaterialTheme.colorScheme.error
                    )
                ) {
                    Text("Reset")
                }
            },
            dismissButton = {
                TextButton(onClick = { showResetDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }
}
```

### 9.2 Create Settings Components

#### SettingsSection

```kotlin
// ui/settings/components/SettingsSection.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * A section in the settings screen with a title.
 */
@Composable
fun SettingsSection(
    title: String,
    modifier: Modifier = Modifier,
    content: @Composable ColumnScope.() -> Unit
) {
    Card(
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = title,
                style = MaterialTheme.typography.titleMedium
            )
            Spacer(modifier = Modifier.height(16.dp))
            content()
        }
    }
}
```

#### ProviderSelector

```kotlin
// ui/settings/components/ProviderSelector.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.LLMProvider

/**
 * Dropdown selector for LLM providers.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ProviderSelector(
    selectedProviderId: String,
    providers: List<LLMProvider>,
    onProviderSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedProvider = providers.find { it.id == selectedProviderId }

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = modifier.fillMaxWidth()
    ) {
        OutlinedTextField(
            value = selectedProvider?.displayName ?: "Select Provider",
            onValueChange = {},
            readOnly = true,
            label = { Text("Provider") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor()
        )

        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false }
        ) {
            providers.forEach { provider ->
                DropdownMenuItem(
                    text = {
                        Column {
                            Text(provider.displayName)
                            if (provider.id == "ollama") {
                                Text(
                                    text = "Local - Free",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            }
                        }
                    },
                    onClick = {
                        onProviderSelected(provider.id)
                        expanded = false
                    }
                )
            }
        }
    }
}
```

#### ModelSelector

```kotlin
// ui/settings/components/ModelSelector.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import com.bmlibrarian.factchecker.domain.model.ModelInfo

/**
 * Dropdown selector for models.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ModelSelector(
    selectedModelId: String,
    models: List<ModelInfo>,
    onModelSelected: (String) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }
    val selectedModel = models.find { it.id == selectedModelId }

    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { expanded = it },
        modifier = modifier.fillMaxWidth()
    ) {
        OutlinedTextField(
            value = selectedModel?.displayName ?: "Select Model",
            onValueChange = {},
            readOnly = true,
            label = { Text("Model") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor()
        )

        ExposedDropdownMenu(
            expanded = expanded,
            onDismissRequest = { expanded = false }
        ) {
            models.forEach { model ->
                DropdownMenuItem(
                    text = {
                        Row(
                            horizontalArrangement = Arrangement.SpaceBetween,
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(model.displayName)
                            if (model.inputPricePer1M > 0) {
                                Text(
                                    text = "$${model.inputPricePer1M}/1M",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurfaceVariant
                                )
                            } else {
                                Text(
                                    text = "Free",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.primary
                                )
                            }
                        }
                    },
                    onClick = {
                        onModelSelected(model.id)
                        expanded = false
                    }
                )
            }
        }
    }
}
```

#### SearchProviderSelector

```kotlin
// ui/settings/components/SearchProviderSelector.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.SearchProvider

/**
 * Segmented button selector for search providers.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchProviderSelector(
    selectedProvider: SearchProvider,
    onProviderSelected: (SearchProvider) -> Unit,
    modifier: Modifier = Modifier
) {
    SingleChoiceSegmentedButtonRow(modifier = modifier.fillMaxWidth()) {
        SearchProvider.values().forEachIndexed { index, provider ->
            SegmentedButton(
                selected = selectedProvider == provider,
                onClick = { onProviderSelected(provider) },
                shape = SegmentedButtonDefaults.itemShape(
                    index = index,
                    count = SearchProvider.values().size
                )
            ) {
                Text(provider.displayName)
            }
        }
    }
}
```

#### SliderSetting

```kotlin
// ui/settings/components/SliderSetting.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * A slider setting with label and value display.
 */
@Composable
fun SliderSetting(
    label: String,
    value: Float,
    onValueChange: (Float) -> Unit,
    valueRange: ClosedFloatingPointRange<Float>,
    steps: Int = 0,
    valueDisplay: String,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        Row(
            horizontalArrangement = Arrangement.SpaceBetween,
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = label,
                style = MaterialTheme.typography.bodyLarge
            )
            Text(
                text = valueDisplay,
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.primary
            )
        }

        Slider(
            value = value,
            onValueChange = onValueChange,
            valueRange = valueRange,
            steps = steps,
            modifier = Modifier.fillMaxWidth()
        )
    }
}
```

#### ModelPricingTable

```kotlin
// ui/settings/components/ModelPricingTable.kt
package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.ModelInfo

/**
 * Table showing model pricing information.
 */
@Composable
fun ModelPricingTable(
    models: List<ModelInfo>,
    modifier: Modifier = Modifier
) {
    Column(modifier = modifier.fillMaxWidth()) {
        // Header row
        Row(
            modifier = Modifier.fillMaxWidth()
        ) {
            Text(
                text = "Model",
                style = MaterialTheme.typography.labelMedium,
                modifier = Modifier.weight(2f)
            )
            Text(
                text = "Input",
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f)
            )
            Text(
                text = "Output",
                style = MaterialTheme.typography.labelMedium,
                textAlign = TextAlign.End,
                modifier = Modifier.weight(1f)
            )
        }

        HorizontalDivider(modifier = Modifier.padding(vertical = 8.dp))

        // Model rows
        models.forEach { model ->
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(vertical = 4.dp)
            ) {
                Text(
                    text = model.displayName,
                    style = MaterialTheme.typography.bodySmall,
                    modifier = Modifier.weight(2f)
                )
                Text(
                    text = if (model.inputPricePer1M > 0) {
                        "$${String.format("%.2f", model.inputPricePer1M)}"
                    } else {
                        "Free"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.End,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Text(
                    text = if (model.outputPricePer1M > 0) {
                        "$${String.format("%.2f", model.outputPricePer1M)}"
                    } else {
                        "Free"
                    },
                    style = MaterialTheme.typography.bodySmall,
                    textAlign = TextAlign.End,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
            }
        }

        Spacer(modifier = Modifier.height(8.dp))

        Text(
            text = "Prices per 1M tokens in USD",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
```

## Verification Checklist

- [ ] Provider dropdown shows all providers
- [ ] Model dropdown updates when provider changes
- [ ] API key saves and persists
- [ ] API key shows as configured after save
- [ ] Search provider selector works
- [ ] Preprints toggle saves state
- [ ] All sliders save their values
- [ ] Budget sliders show correct values
- [ ] Reset dialog appears and works
- [ ] Custom URL field shows for custom provider
- [ ] Model pricing table displays correctly

## Testing

### UI Tests

```kotlin
// androidTest/ui/settings/SettingsScreenTest.kt
@HiltAndroidTest
class SettingsScreenTest {

    @get:Rule
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Test
    fun providerSelector_changesModels() {
        composeRule.onNodeWithText("Settings").performClick()

        // Select a provider
        composeRule.onNodeWithText("Provider").performClick()
        composeRule.onNodeWithText("OpenAI").performClick()

        // Verify models updated
        composeRule.onNodeWithText("Model").performClick()
        composeRule.onNodeWithText("GPT-4o").assertExists()
    }

    @Test
    fun apiKey_savesAndShowsConfigured() {
        composeRule.onNodeWithText("Settings").performClick()

        // Enter API key
        composeRule.onNodeWithText("Enter your API key").performTextInput("test-key")
        composeRule.onNodeWithText("Save API Key").performClick()

        // Verify configured
        composeRule.onNodeWithText("API key configured").assertExists()
    }
}
```

## Next Phase

Continue to [Phase 10: Testing & Polish](./10-testing-polish.md)
