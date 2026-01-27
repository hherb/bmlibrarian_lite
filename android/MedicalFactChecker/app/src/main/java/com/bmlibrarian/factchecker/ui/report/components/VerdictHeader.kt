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

package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants

/**
 * Header component showing the verdict badge and collapsible summary.
 *
 * Displays at the top of the report screen with a colored background
 * that corresponds to the verdict type. The summary is collapsible to
 * save screen real estate.
 *
 * @param verdict The verdict to display
 * @param summary Brief summary text of the evidence
 * @param modifier Modifier for customizing the header
 */
@Composable
fun VerdictHeader(
    verdict: Verdict,
    summary: String,
    modifier: Modifier = Modifier
) {
    var isExpanded by remember { mutableStateOf(false) }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = verdict.color.copy(alpha = Constants.VERDICT_BACKGROUND_ALPHA)
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            // Always visible: Verdict line with expand/collapse toggle
            Row(
                verticalAlignment = Alignment.CenterVertically,
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = "Verdict:",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))

                VerdictBadge(verdict = verdict)

                Spacer(modifier = Modifier.weight(1f))

                // Expand/collapse chevron
                IconButton(onClick = { isExpanded = !isExpanded }) {
                    Icon(
                        imageVector = if (isExpanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                        contentDescription = if (isExpanded) "Collapse summary" else "Expand summary",
                        tint = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }
            }

            // Collapsible summary
            AnimatedVisibility(visible = isExpanded) {
                Column {
                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
                    Text(
                        text = summary,
                        style = MaterialTheme.typography.bodyLarge,
                        color = MaterialTheme.colorScheme.onSurface
                    )
                }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderCollapsedPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.SUPPORTED,
            summary = "Strong evidence from multiple randomized controlled trials supports the claim that regular exercise reduces cardiovascular disease risk."
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderUnclearPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.UNCLEAR,
            summary = "Evidence is mixed regarding the effectiveness of vitamin D supplementation for preventing respiratory infections."
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderRefutedPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.REFUTED,
            summary = "No credible scientific evidence supports the claim. Multiple systematic reviews have found no benefit."
        )
    }
}
