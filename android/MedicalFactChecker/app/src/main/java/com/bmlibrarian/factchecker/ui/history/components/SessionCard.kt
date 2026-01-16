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

package com.bmlibrarian.factchecker.ui.history.components

import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.KeyboardArrowRight
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material3.Card
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.ui.history.SessionWithReport
import com.bmlibrarian.factchecker.ui.report.components.VerdictBadge
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants
import java.text.SimpleDateFormat
import java.util.Locale

/**
 * Formats cost as a USD string with proper decimal places.
 *
 * @param cost The cost in USD to format
 * @return Formatted cost string like "$0.0045"
 */
private fun formatCost(cost: Double): String {
    return "$${String.format(Locale.US, "%.${Constants.COST_DISPLAY_DECIMAL_PLACES}f", cost)}"
}

/**
 * Card displaying a session summary in the history list.
 *
 * Shows the claim text, verdict badge (if completed), date, and statistics.
 * Clicking the card navigates to view the full report. A delete button allows
 * removing the session from history.
 *
 * @param sessionWithReport The session and its associated report
 * @param onClick Callback when the card is tapped
 * @param onDelete Callback when the delete button is tapped
 * @param modifier Modifier for customizing the card appearance
 */
@Composable
fun SessionCard(
    sessionWithReport: SessionWithReport,
    onClick: () -> Unit,
    onDelete: () -> Unit,
    modifier: Modifier = Modifier
) {
    val session = sessionWithReport.session
    val report = sessionWithReport.report
    val dateFormat = remember {
        SimpleDateFormat(Constants.SESSION_DATE_DISPLAY_PATTERN, Locale.getDefault())
    }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .clickable(onClick = onClick)
    ) {
        Column(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth()
            ) {
                // Verdict badge if report exists
                report?.let {
                    VerdictBadge(
                        verdict = it.verdict,
                        modifier = Modifier.padding(end = Constants.UI_ICON_TEXT_SPACING.dp)
                    )
                }

                // Claim text and metadata
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = session.claimText,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = Constants.MAX_CLAIM_LINES,
                        overflow = TextOverflow.Ellipsis
                    )

                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))

                    Text(
                        text = dateFormat.format(session.createdAt),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                }

                // Delete button
                IconButton(onClick = onDelete) {
                    Icon(
                        imageVector = Icons.Default.Delete,
                        contentDescription = "Delete session",
                        tint = MaterialTheme.colorScheme.error
                    )
                }

                // Navigation indicator
                Icon(
                    imageVector = Icons.AutoMirrored.Filled.KeyboardArrowRight,
                    contentDescription = "View report",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            // Report summary and stats if available
            report?.let {
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
                HorizontalDivider()
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

                Text(
                    text = it.summary,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    maxLines = Constants.MAX_SUMMARY_PREVIEW_LINES,
                    overflow = TextOverflow.Ellipsis
                )

                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

                SessionStats(
                    documentsReviewed = it.totalDocumentsReviewed,
                    citationsCount = it.citationsCount,
                    cost = session.estimatedCostUsd
                )
            }
        }
    }
}

/**
 * Statistics row showing document count, citation count, and cost.
 *
 * @param documentsReviewed Number of documents reviewed
 * @param citationsCount Number of citations extracted
 * @param cost Estimated cost in USD
 */
@Composable
private fun SessionStats(
    documentsReviewed: Int,
    citationsCount: Int,
    cost: Double
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Constants.UI_SECTION_SPACING.dp)
    ) {
        Text(
            text = "$documentsReviewed docs",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = "$citationsCount citations",
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Text(
            text = formatCost(cost),
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

// ==================== Previews ====================

@Preview(showBackground = true)
@Composable
private fun SessionCardWithReportPreview() {
    MedicalFactCheckerTheme {
        SessionCard(
            sessionWithReport = SessionWithReport(
                session = SessionEntity(
                    claimText = "Vitamin D supplementation reduces the risk of respiratory infections",
                    estimatedCostUsd = 0.0045
                ),
                report = ReportEntity(
                    sessionId = "test-session",
                    verdict = Verdict.LIKELY_SUPPORTED,
                    summary = "Multiple studies suggest vitamin D may reduce respiratory infection risk, particularly in deficient individuals.",
                    fullReportMarkdown = "",
                    modelUsed = "gpt-4",
                    totalDocumentsReviewed = 25,
                    relevantDocumentsCount = 12,
                    citationsCount = 8
                )
            ),
            onClick = {},
            onDelete = {},
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun SessionCardWithoutReportPreview() {
    MedicalFactCheckerTheme {
        SessionCard(
            sessionWithReport = SessionWithReport(
                session = SessionEntity(
                    claimText = "Coffee consumption is linked to longevity",
                    estimatedCostUsd = 0.0
                ),
                report = null
            ),
            onClick = {},
            onDelete = {},
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun SessionCardRefutedPreview() {
    MedicalFactCheckerTheme {
        SessionCard(
            sessionWithReport = SessionWithReport(
                session = SessionEntity(
                    claimText = "Homeopathy is effective for treating cancer",
                    estimatedCostUsd = 0.0032
                ),
                report = ReportEntity(
                    sessionId = "test-session-2",
                    verdict = Verdict.REFUTED,
                    summary = "No credible scientific evidence supports homeopathy as an effective cancer treatment.",
                    fullReportMarkdown = "",
                    modelUsed = "claude-3-sonnet",
                    totalDocumentsReviewed = 18,
                    relevantDocumentsCount = 6,
                    citationsCount = 4
                )
            ),
            onClick = {},
            onDelete = {},
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        )
    }
}
