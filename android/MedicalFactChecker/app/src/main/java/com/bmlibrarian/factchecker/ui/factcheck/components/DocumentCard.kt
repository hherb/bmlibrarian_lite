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

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Article
import androidx.compose.material.icons.filled.Download
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material.icons.filled.FormatQuote
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.Card
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.text.font.FontStyle
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.ui.common.MarkdownText
import com.bmlibrarian.factchecker.ui.theme.scoreColor
import com.bmlibrarian.factchecker.util.Constants

/**
 * Colors for LLM reasoning/explanation display.
 *
 * Provides a visually distinct style for AI-generated explanations
 * to help users distinguish them from source text like abstracts.
 */
private object ReasoningColors {
    /** Background color for reasoning blocks (warm off-white). */
    val background = Color(0xFFFAF8EE)

    /** Border color for reasoning blocks. */
    val border = Color(0xFFD9D1B8)

    /** Text color for reasoning content. */
    val text = Color(0xFF595959)

    /** Accent color for reasoning icon. */
    val accent = Color(0xFF998C66)
}

/**
 * Card displaying a scored document.
 *
 * Shows document title, authors, journal, and relevance score.
 * Expands to show abstract, key passages, source badges, and score rationale.
 *
 * @param document The document to display
 * @param citations Optional list of extracted citations/key passages for this document
 * @param isLoadingFullText Whether full text is currently being fetched
 * @param onGetFullText Callback to fetch full text for this document
 * @param onViewFullText Callback to navigate to full text viewer
 * @param onOpenPublisher Callback to open publisher website (DOI link)
 * @param modifier Modifier for the component
 */
@Composable
fun DocumentCard(
    document: DocumentEntity,
    citations: List<CitationEntity> = emptyList(),
    isLoadingFullText: Boolean = false,
    onGetFullText: ((DocumentEntity) -> Unit)? = null,
    onViewFullText: ((DocumentEntity) -> Unit)? = null,
    onOpenPublisher: ((String) -> Unit)? = null,
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
            modifier = Modifier.padding(Constants.UI_CARD_PADDING_SMALL.dp)
        ) {
            Row(
                verticalAlignment = Alignment.Top,
                modifier = Modifier.fillMaxWidth()
            ) {
                // Score badges column (LLM + Embedding)
                Column(
                    horizontalAlignment = Alignment.CenterHorizontally,
                    verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp),
                    modifier = Modifier.padding(end = Constants.UI_ICON_TEXT_SPACING.dp)
                ) {
                    // LLM Score badge
                    document.relevanceScore?.let { score ->
                        ScoreBadge(
                            score = score,
                            label = "LLM"
                        )
                    }
                    // Embedding Score badge
                    document.embeddingScoreNormalized?.let { embScore ->
                        EmbeddingScoreBadge(score = embScore)
                    }
                }

                // Title and metadata
                Column(modifier = Modifier.weight(1f)) {
                    Text(
                        text = document.title,
                        style = MaterialTheme.typography.titleSmall,
                        maxLines = if (expanded) Int.MAX_VALUE else 2,
                        overflow = TextOverflow.Ellipsis
                    )

                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))

                    Text(
                        text = document.formattedAuthors,
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = TextOverflow.Ellipsis
                    )

                    Row(
                        horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
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
                Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))
                HorizontalDivider()
                Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))

                // LLM Reasoning - visually distinct box (shown first like iOS)
                document.scoreRationale?.let { rationale ->
                    Text(
                        text = "LLM Reasoning",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    LLMReasoningBox(rationale = rationale)
                    Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))
                }

                // Key Passages (citations extracted from this document)
                if (citations.isNotEmpty()) {
                    Text(
                        text = "Key Passages",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    citations.forEach { citation ->
                        KeyPassageBox(passage = citation.passage)
                        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    }
                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                }

                // Abstract (rendered as markdown for structured abstracts)
                document.abstractText?.let { abstract ->
                    Text(
                        text = "Abstract",
                        style = MaterialTheme.typography.labelMedium,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    MarkdownText(
                        text = abstract,
                        textSizeSp = Constants.ABSTRACT_TEXT_SIZE_SP
                    )
                    Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))
                }

                // Full Text Section
                if (onGetFullText != null || onViewFullText != null) {
                    HorizontalDivider()
                    Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))
                    FullTextSection(
                        document = document,
                        isLoading = isLoadingFullText,
                        onGetFullText = onGetFullText,
                        onViewFullText = onViewFullText,
                        onOpenPublisher = onOpenPublisher
                    )
                    Spacer(modifier = Modifier.height(Constants.UI_CARD_PADDING_SMALL.dp))
                }

                // Source badges and metadata
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
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
            }
        }
    }
}

/**
 * Badge displaying the relevance score with color coding.
 *
 * @param score The relevance score (1-5)
 * @param label Optional label to show below the score (e.g., "LLM")
 * @param modifier Modifier for the component
 */
@Composable
fun ScoreBadge(
    score: Int,
    label: String? = null,
    modifier: Modifier = Modifier
) {
    val backgroundColor = scoreColor(score)

    Surface(
        color = backgroundColor,
        shape = MaterialTheme.shapes.small,
        modifier = modifier
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(
                horizontal = Constants.UI_CARD_PADDING_SMALL.dp,
                vertical = Constants.UI_ELEMENT_SPACING_SMALL.dp
            )
        ) {
            Text(
                text = score.toString(),
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onPrimary
            )
            label?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.onPrimary
                )
            }
        }
    }
}

/**
 * Badge displaying the embedding similarity score with distinct styling.
 *
 * @param score The normalized embedding score (1-5)
 * @param modifier Modifier for the component
 */
@Composable
private fun EmbeddingScoreBadge(
    score: Int,
    modifier: Modifier = Modifier
) {
    val backgroundColor = scoreColor(score)

    Surface(
        color = backgroundColor.copy(alpha = 0.7f),
        shape = MaterialTheme.shapes.small,
        border = BorderStroke(1.dp, backgroundColor),
        modifier = modifier
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            modifier = Modifier.padding(
                horizontal = Constants.UI_CARD_PADDING_SMALL.dp,
                vertical = Constants.UI_ELEMENT_SPACING_SMALL.dp
            )
        ) {
            Text(
                text = score.toString(),
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onPrimary
            )
            Text(
                text = "Emb",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onPrimary
            )
        }
    }
}

/**
 * Badge displaying the document source.
 *
 * @param source The source identifier (pubmed, europepmc, etc.)
 */
@Composable
private fun SourceBadge(source: String) {
    val displayText = when (source.lowercase()) {
        Constants.SOURCE_PUBMED.lowercase() -> "PubMed"
        Constants.SOURCE_EUROPE_PMC.lowercase() -> "Europe PMC"
        Constants.SOURCE_PREPRINT.lowercase() -> "Preprint"
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
            modifier = Modifier.padding(
                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
            )
        )
    }
}

/**
 * Badge indicating the document is a preprint.
 */
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
            modifier = Modifier.padding(
                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
            )
        )
    }
}

/**
 * Styled box displaying LLM reasoning/explanation.
 *
 * Renders the LLM's rationale in a visually distinct box with a warm
 * off-white background, border, and brain icon to distinguish it from
 * source text like abstracts.
 *
 * @param rationale The LLM explanation text
 * @param modifier Modifier for the component
 */
@Composable
private fun LLMReasoningBox(
    rationale: String,
    modifier: Modifier = Modifier
) {
    Surface(
        color = ReasoningColors.background,
        shape = MaterialTheme.shapes.small,
        border = BorderStroke(1.dp, ReasoningColors.border),
        modifier = modifier.fillMaxWidth()
    ) {
        Row(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING_SMALL.dp),
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Psychology,
                contentDescription = "LLM reasoning",
                tint = ReasoningColors.accent,
                modifier = Modifier.size(16.dp)
            )
            Text(
                text = rationale,
                style = MaterialTheme.typography.bodySmall,
                fontStyle = FontStyle.Italic,
                color = ReasoningColors.text
            )
        }
    }
}

/**
 * Styled box displaying a key passage (citation) from the document.
 *
 * Renders the extracted passage with a quote icon and accent-colored
 * background to visually indicate quoted text from the source.
 *
 * @param passage The extracted passage text
 * @param modifier Modifier for the component
 */
@Composable
private fun KeyPassageBox(
    passage: String,
    modifier: Modifier = Modifier
) {
    Row(
        modifier = modifier
            .fillMaxWidth()
            .clip(RoundedCornerShape(Constants.KEY_PASSAGE_CORNER_RADIUS.dp))
            .background(
                MaterialTheme.colorScheme.primaryContainer.copy(
                    alpha = Constants.KEY_PASSAGE_BACKGROUND_ALPHA
                )
            )
            .padding(Constants.UI_CARD_PADDING_SMALL.dp),
        horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
    ) {
        Icon(
            imageVector = Icons.Default.FormatQuote,
            contentDescription = "Quote",
            tint = MaterialTheme.colorScheme.primary.copy(alpha = Constants.KEY_PASSAGE_ICON_ALPHA),
            modifier = Modifier.size(Constants.KEY_PASSAGE_ICON_SIZE.dp)
        )
        Text(
            text = passage,
            style = MaterialTheme.typography.bodySmall,
            fontStyle = FontStyle.Italic,
            color = MaterialTheme.colorScheme.onSurface.copy(alpha = Constants.KEY_PASSAGE_TEXT_ALPHA)
        )
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
    onGetFullText: ((DocumentEntity) -> Unit)?,
    onViewFullText: ((DocumentEntity) -> Unit)?,
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
                    onClick = { onViewFullText?.invoke(document) },
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
                    onClick = { onGetFullText?.invoke(document) },
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
