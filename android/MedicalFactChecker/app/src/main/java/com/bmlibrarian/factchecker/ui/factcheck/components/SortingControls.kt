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

import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.material3.FilterChip
import androidx.compose.material3.FilterChipDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.DocumentSortOrder
import com.bmlibrarian.factchecker.util.Constants

/**
 * Horizontal row of filter chips for selecting document sort order.
 *
 * Mirrors iOS DocumentSortOrder functionality with Material 3 design.
 * Shows all sort options as horizontally scrollable chips.
 *
 * @param selectedSortOrder The currently selected sort order
 * @param onSortOrderChange Callback when user selects a different sort order
 * @param modifier Modifier for the component
 */
@Composable
fun SortingControls(
    selectedSortOrder: DocumentSortOrder,
    onSortOrderChange: (DocumentSortOrder) -> Unit,
    modifier: Modifier = Modifier
) {
    Row(
        horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
        verticalAlignment = Alignment.CenterVertically,
        modifier = modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(vertical = Constants.UI_ELEMENT_SPACING_SMALL.dp)
    ) {
        Text(
            text = "Sort:",
            style = MaterialTheme.typography.labelMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        DocumentSortOrder.entries.forEach { sortOrder ->
            SortOrderChip(
                sortOrder = sortOrder,
                isSelected = sortOrder == selectedSortOrder,
                onClick = { onSortOrderChange(sortOrder) }
            )
        }
    }
}

/**
 * Individual sort order filter chip.
 *
 * @param sortOrder The sort order this chip represents
 * @param isSelected Whether this chip is currently selected
 * @param onClick Callback when chip is clicked
 */
@Composable
private fun SortOrderChip(
    sortOrder: DocumentSortOrder,
    isSelected: Boolean,
    onClick: () -> Unit
) {
    FilterChip(
        selected = isSelected,
        onClick = onClick,
        label = {
            Text(
                text = sortOrder.displayName,
                style = MaterialTheme.typography.labelMedium
            )
        },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = MaterialTheme.colorScheme.primaryContainer,
            selectedLabelColor = MaterialTheme.colorScheme.onPrimaryContainer
        )
    )
}
