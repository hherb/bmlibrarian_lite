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

package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Add
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp

/**
 * Banner displayed when continuing a search from history.
 *
 * Shows information about the resumed session including:
 * - Document count and scored count
 * - "Add More Results" button if more evidence is available
 * - "New Question" button to start fresh
 *
 * Styled with a light blue background to distinguish from other UI elements.
 * Mirrors the iOS ResumedSessionBanner component for cross-platform consistency.
 *
 * @param documentCount Total number of documents found in the session
 * @param scoredCount Number of documents that have been scored
 * @param canAddMore Whether more documents can be fetched from the search
 * @param isLoading Whether a fetch operation is currently in progress
 * @param onAddMore Callback when user taps "Add More Results"
 * @param onNewQuestion Callback when user taps "New Question"
 * @param modifier Modifier for the component
 */
@Composable
fun ResumedSessionBanner(
    documentCount: Int,
    scoredCount: Int,
    canAddMore: Boolean,
    isLoading: Boolean,
    onAddMore: () -> Unit,
    onNewQuestion: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.primaryContainer.copy(alpha = 0.3f)
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            // Header row with icon, text, and indicator
            Row(
                modifier = Modifier.fillMaxWidth(),
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(12.dp)
            ) {
                Icon(
                    imageVector = Icons.Default.Refresh,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.primary,
                    modifier = Modifier.size(28.dp)
                )

                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = "Continuing previous search",
                        style = MaterialTheme.typography.titleSmall,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                    Text(
                        text = "$documentCount documents found, $scoredCount scored",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // Green indicator if more documents available
                if (canAddMore) {
                    Icon(
                        imageVector = Icons.Default.Add,
                        contentDescription = "More documents available",
                        tint = Color(0xFF4CAF50), // Green
                        modifier = Modifier.size(24.dp)
                    )
                }
            }

            // Action buttons row
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .padding(top = 12.dp),
                horizontalArrangement = Arrangement.spacedBy(8.dp)
            ) {
                // Add More Results button (only shown if more documents available)
                if (canAddMore) {
                    Button(
                        onClick = onAddMore,
                        enabled = !isLoading
                    ) {
                        if (isLoading) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                color = MaterialTheme.colorScheme.onPrimary,
                                strokeWidth = 2.dp
                            )
                        } else {
                            Text("Add More Results")
                        }
                    }
                }

                // New Question button (always shown)
                OutlinedButton(
                    onClick = onNewQuestion,
                    enabled = !isLoading
                ) {
                    Text("New Question")
                }
            }
        }
    }
}
