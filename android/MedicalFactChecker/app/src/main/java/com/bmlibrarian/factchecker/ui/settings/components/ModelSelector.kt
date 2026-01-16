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

package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Modifier
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.util.Constants
import java.util.Locale

/**
 * Dropdown selector for LLM models.
 *
 * Displays an exposed dropdown menu with available models for the
 * currently selected provider. Shows model name and pricing info.
 *
 * @param selectedModelId The currently selected model's ID
 * @param models List of available models to display
 * @param onModelSelected Callback invoked when a model is selected
 * @param modifier Modifier to be applied to the dropdown container
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
            colors = ExposedDropdownMenuDefaults.outlinedTextFieldColors(),
            modifier = Modifier
                .fillMaxWidth()
                .menuAnchor(MenuAnchorType.PrimaryNotEditable)
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
                            Text(
                                text = formatModelPrice(model),
                                style = MaterialTheme.typography.bodySmall,
                                color = if (model.isFree) {
                                    MaterialTheme.colorScheme.primary
                                } else {
                                    MaterialTheme.colorScheme.onSurfaceVariant
                                }
                            )
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

/**
 * Format the model price for display in the dropdown.
 *
 * Shows "Free" for models with zero pricing, otherwise shows
 * the input price per million tokens.
 *
 * @param model The model info to format
 * @return Formatted price string
 */
private fun formatModelPrice(model: ModelInfo): String {
    return if (model.isFree) {
        "Free"
    } else {
        String.format(
            Locale.US,
            "$%.${Constants.SETTINGS_BUDGET_DECIMAL_PLACES}f/1M",
            model.inputPricePer1M
        )
    }
}
