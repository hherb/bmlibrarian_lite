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
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.LinearProgressIndicator
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.CostCalculator

/**
 * Progress indicator for the fact-check workflow.
 *
 * Displays the current workflow step, progress bar, document counts,
 * and cost information. Provides a cancel button to abort the workflow.
 *
 * @param progress Current workflow progress information
 * @param onCancel Callback when cancel is pressed
 * @param modifier Modifier for the component
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            // Status row with spinner and message
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                CircularProgressIndicator(
                    modifier = Modifier.size(24.dp),
                    strokeWidth = 2.dp
                )
                Spacer(modifier = Modifier.width(Constants.UI_ICON_TEXT_SPACING.dp))
                Text(
                    text = progress.message,
                    style = MaterialTheme.typography.bodyLarge,
                    modifier = Modifier.weight(1f)
                )
            }

            Spacer(modifier = Modifier.height(Constants.UI_ICON_TEXT_SPACING.dp))

            // Linear progress bar
            LinearProgressIndicator(
                progress = { progress.percentage },
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(Constants.UI_ICON_TEXT_SPACING.dp))

            // Statistics row
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
                    if (progress.relevantDocuments > 0) {
                        Text(
                            text = "Relevant: ${progress.relevantDocuments}",
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
                        text = "${progress.percentageInt}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            // Cancel button
            TextButton(
                onClick = onCancel,
                modifier = Modifier.align(Alignment.End)
            ) {
                Text("Cancel")
            }
        }
    }
}
