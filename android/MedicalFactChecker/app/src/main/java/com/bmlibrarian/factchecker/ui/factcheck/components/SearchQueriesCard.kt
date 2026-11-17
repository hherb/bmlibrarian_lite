/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.clickable
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.text.selection.SelectionContainer
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.ExpandLess
import androidx.compose.material.icons.filled.ExpandMore
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SearchQueryLog
import com.bmlibrarian.factchecker.domain.model.SearchQueryRow
import com.bmlibrarian.factchecker.util.Constants

/**
 * Every query a session ran, folded to the first until the reader taps it.
 *
 * Folded, the card shows the initial query on one line and how many more
 * queries were run; tapped, it unfolds every query (smart search's
 * alternatives, or the initial query asked of another provider), each with
 * how many documents it found and how many of those were relevant. Mirrors
 * iOS's `SearchQueriesView`.
 *
 * @param query The generated query, shown when no query has been run yet
 * @param rows Every query the session ran, with what each found
 */
@Composable
fun SearchQueriesCard(query: String, rows: List<SearchQueryRow>) {
    var expanded by remember { mutableStateOf(false) }

    Card(
        colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceVariant),
        modifier = Modifier
            .fillMaxWidth()
            .animateContentSize()
            .clickable { expanded = !expanded }
    ) {
        Column(modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)) {
            Row(verticalAlignment = Alignment.CenterVertically, modifier = Modifier.fillMaxWidth()) {
                Text(
                    text = headerTitle(rows),
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                    modifier = Modifier.weight(1f)
                )
                Icon(
                    imageVector = if (expanded) Icons.Default.ExpandLess else Icons.Default.ExpandMore,
                    contentDescription = if (expanded) "Collapse" else "Show all queries",
                    tint = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            if (!expanded) {
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                Text(
                    text = rows.firstOrNull()?.record?.query ?: query,
                    style = MaterialTheme.typography.bodySmall,
                    fontFamily = FontFamily.Monospace,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                if (rows.size > 1) {
                    Text(
                        text = moreQueriesText(rows.size - 1),
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.primary
                    )
                }
            }
            AnimatedVisibility(visible = expanded) {
                SelectionContainer {
                    Column(verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)) {
                        Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                        if (rows.isEmpty()) {
                            QueryText(query)
                        }
                        rows.forEachIndexed { index, row ->
                            if (index > 0) {
                                HorizontalDivider(color = MaterialTheme.colorScheme.outlineVariant)
                            }
                            SearchQueryRowContent(row, showsLabel = rows.size > 1)
                        }
                    }
                }
            }
        }
    }
}

/** One query: its name, its text (and Europe PMC's form), and its counts. */
@Composable
private fun SearchQueryRowContent(row: SearchQueryRow, showsLabel: Boolean) {
    Column(verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp)) {
        if (showsLabel) {
            Text(
                text = "${row.label} — ${providerName(row.record.provider)}",
                style = MaterialTheme.typography.labelSmall,
                fontWeight = FontWeight.SemiBold,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        QueryText(row.record.query)
        row.record.europePmcQuery?.let { europePmc ->
            Text(
                text = "As Europe PMC was asked it:",
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            QueryText(europePmc)
        }
        row.statistics?.let { statistics ->
            Text(
                text = SearchQueryLog.statisticsLine(statistics, row.record.totalHits),
                style = MaterialTheme.typography.labelSmall,
                color = MaterialTheme.colorScheme.primary
            )
        }
    }
}

/** A query's text. */
@Composable
private fun QueryText(text: String) {
    Text(
        text = text,
        style = MaterialTheme.typography.bodySmall,
        fontFamily = FontFamily.Monospace,
        color = MaterialTheme.colorScheme.onSurfaceVariant
    )
}

/** The header's text: the provider's query, or all the queries run. */
private fun headerTitle(rows: List<SearchQueryRow>): String = when {
    rows.size > 1 -> "Search Queries (${rows.size}):"
    rows.firstOrNull()?.record?.provider == SearchProvider.EUROPE_PMC -> "Europe PMC Query:"
    rows.firstOrNull()?.record?.provider == SearchProvider.BOTH -> "Search Query:"
    else -> "PubMed Query:"
}

/** The provider's name as the list shows it. */
private fun providerName(provider: SearchProvider): String =
    if (provider == SearchProvider.BOTH) "PubMed + Europe PMC" else provider.displayName

/** The folded card's hint that more queries are listed. */
private fun moreQueriesText(count: Int): String =
    if (count == 1) "+ 1 more query — tap to show" else "+ $count more queries — tap to show all"
