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

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.OpenInNew
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.ui.common.MarkdownText
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.ui.theme.scoreColor
import com.bmlibrarian.factchecker.util.Constants

/**
 * Bottom sheet showing detailed document information.
 *
 * Displays full document metadata including title, authors, journal,
 * identifiers, relevance score, abstract, and full text actions.
 * Provides actions to view full text, open in PubMed, or dismiss.
 *
 * @param document The document to display details for
 * @param isLoadingFullText Whether full text is currently being fetched
 * @param onGetFullText Callback to fetch full text for this document
 * @param onViewFullText Callback to navigate to full text viewer
 * @param onOpenPublisher Callback to open publisher website (DOI link)
 * @param onOpenInPubMed Callback when "Open in PubMed" is clicked
 * @param onDismiss Callback when the sheet should be dismissed
 * @param modifier Modifier for customizing the component
 */
@Composable
fun DocumentDetailSheet(
    document: DocumentEntity,
    isLoadingFullText: Boolean = false,
    onGetFullText: (() -> Unit)? = null,
    onViewFullText: (() -> Unit)? = null,
    onOpenPublisher: ((String) -> Unit)? = null,
    onOpenInPubMed: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(Constants.UI_CARD_PADDING.dp)
            .verticalScroll(rememberScrollState())
    ) {
        // Title
        Text(
            text = document.title,
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.onSurface
        )

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Authors
        Text(
            text = document.formattedAuthors,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Journal and year
        Row {
            document.journal?.let { journal ->
                Text(
                    text = journal,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            document.publicationYear?.let { year ->
                Text(
                    text = " ($year)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

        // Identifiers row
        Row(
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_SECTION_SPACING.dp)
        ) {
            document.pmid?.let { pmid ->
                Text(
                    text = "PMID: $pmid",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            document.doi?.let { doi ->
                Text(
                    text = "DOI: $doi",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Relevance score
        document.relevanceScore?.let { score ->
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Row {
                Text(
                    text = "Relevance Score: ",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurface
                )
                Text(
                    text = "$score/5",
                    style = MaterialTheme.typography.labelLarge,
                    color = scoreColor(score)
                )
            }

            // Score rationale
            document.scoreRationale?.let { rationale ->
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                Text(
                    text = rationale,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Abstract (rendered as markdown for structured abstracts)
        document.abstractText?.let { abstract ->
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "Abstract",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            MarkdownText(
                text = abstract,
                textSizeSp = Constants.ABSTRACT_TEXT_SIZE_SP
            )
        }

        // Full Text Section
        if (onGetFullText != null || onViewFullText != null) {
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            HorizontalDivider()
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "Full Text",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurface
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            FullTextSection(
                document = document,
                isLoading = isLoadingFullText,
                onGetFullText = onGetFullText,
                onViewFullText = onViewFullText,
                onOpenPublisher = onOpenPublisher
            )
        }

        Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

        // Action buttons
        Row(
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            OutlinedButton(
                onClick = onDismiss,
                modifier = Modifier.weight(1f)
            ) {
                Text("Close")
            }

            document.pmid?.let { pmid ->
                Button(
                    onClick = { onOpenInPubMed(pmid) },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        imageVector = Icons.AutoMirrored.Filled.OpenInNew,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))
                    Text("PubMed")
                }
            }
        }

        // Bottom padding for navigation bar
        Spacer(modifier = Modifier.height(Constants.UI_NAVIGATION_BAR_PADDING.dp))
    }
}

/**
 * Section for full-text retrieval button and status.
 *
 * Displays different states:
 * - View Full Text button when full text is already available
 * - Get Full Text button when not yet attempted
 * - Unavailable message with fallback to publisher when retrieval failed
 *
 * @param document The document to display full-text actions for
 * @param isLoading Whether full text is currently being fetched
 * @param onGetFullText Callback to fetch full text
 * @param onViewFullText Callback to navigate to full text viewer
 * @param onOpenPublisher Callback to open publisher website
 */
@Composable
private fun FullTextSection(
    document: DocumentEntity,
    isLoading: Boolean,
    onGetFullText: (() -> Unit)?,
    onViewFullText: (() -> Unit)?,
    onOpenPublisher: ((String) -> Unit)?
) {
    when {
        // Already have full text - show view button
        document.hasFullText -> {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
            ) {
                Button(
                    onClick = { onViewFullText?.invoke() },
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding
                ) {
                    Icon(
                        imageVector = Icons.Default.Article,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    Text("View Full Text")
                }

                // Show source badge
                document.fullTextSourceDisplay?.let { source ->
                    Surface(
                        color = MaterialTheme.colorScheme.secondaryContainer,
                        shape = MaterialTheme.shapes.small
                    ) {
                        Text(
                            text = source,
                            style = MaterialTheme.typography.labelSmall,
                            color = MaterialTheme.colorScheme.onSecondaryContainer,
                            modifier = Modifier.padding(
                                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
                            )
                        )
                    }
                }
            }
        }

        // Already tried but unavailable
        document.fullTextUnavailable -> {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                Icon(
                    imageVector = Icons.Default.Warning,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.tertiary,
                    modifier = Modifier.size(16.dp)
                )
                Text(
                    text = "Full text not available",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )

                // Offer to open publisher website
                document.doi?.let { doi ->
                    OutlinedButton(
                        onClick = { onOpenPublisher?.invoke(doi) },
                        contentPadding = ButtonDefaults.ButtonWithIconContentPadding
                    ) {
                        Icon(
                            imageVector = Icons.Default.OpenInBrowser,
                            contentDescription = null,
                            modifier = Modifier.size(16.dp)
                        )
                        Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                        Text(
                            text = "Publisher",
                            style = MaterialTheme.typography.labelMedium
                        )
                    }
                }
            }
        }

        // Not yet attempted - show fetch button
        else -> {
            Row(
                verticalAlignment = Alignment.CenterVertically,
                horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
            ) {
                OutlinedButton(
                    onClick = { onGetFullText?.invoke() },
                    enabled = !isLoading,
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding
                ) {
                    if (isLoading) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(16.dp),
                            strokeWidth = 2.dp
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Default.Download,
                            contentDescription = null,
                            modifier = Modifier.size(18.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    Text(if (isLoading) "Fetching..." else "Get Full Text")
                }
            }
        }
    }
}

@Preview(showBackground = true)
@Composable
private fun DocumentDetailSheetPreview() {
    MedicalFactCheckerTheme {
        DocumentDetailSheet(
            document = DocumentEntity(
                sessionId = "session-1",
                pmid = "12345678",
                doi = "10.1234/example.2024",
                title = "Effect of Regular Exercise on Cardiovascular Health: A Randomized Controlled Trial",
                abstractText = "**Background:** Physical activity has been associated with reduced cardiovascular risk. " +
                    "We conducted a randomized controlled trial to evaluate the effects of regular exercise.\n\n" +
                    "**Methods:** 500 participants were randomized to exercise or control groups.\n\n" +
                    "**Results:** The exercise group showed significant improvements in cardiovascular outcomes.\n\n" +
                    "**Conclusions:** Regular exercise provides substantial cardiovascular benefits.",
                authors = listOf("Smith J", "Johnson M", "Williams K", "Brown R"),
                journal = "New England Journal of Medicine",
                publicationYear = 2024,
                relevanceScore = 5,
                scoreRationale = "Highly relevant RCT directly addressing the claim with strong methodology and clear results."
            ),
            onOpenInPubMed = {},
            onDismiss = {}
        )
    }
}
