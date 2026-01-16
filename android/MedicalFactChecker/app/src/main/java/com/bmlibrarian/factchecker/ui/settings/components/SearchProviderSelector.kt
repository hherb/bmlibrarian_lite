package com.bmlibrarian.factchecker.ui.settings.components

import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.SegmentedButton
import androidx.compose.material3.SegmentedButtonDefaults
import androidx.compose.material3.SingleChoiceSegmentedButtonRow
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import com.bmlibrarian.factchecker.domain.model.SearchProvider

/**
 * Segmented button selector for search providers.
 *
 * Displays a row of segmented buttons for selecting which literature
 * database(s) to search: PubMed only, Europe PMC only, or both.
 *
 * @param selectedProvider The currently selected search provider
 * @param onProviderSelected Callback invoked when a provider is selected
 * @param modifier Modifier to be applied to the button row
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SearchProviderSelector(
    selectedProvider: SearchProvider,
    onProviderSelected: (SearchProvider) -> Unit,
    modifier: Modifier = Modifier
) {
    val providers = SearchProvider.entries

    SingleChoiceSegmentedButtonRow(modifier = modifier.fillMaxWidth()) {
        providers.forEachIndexed { index, provider ->
            SegmentedButton(
                selected = selectedProvider == provider,
                onClick = { onProviderSelected(provider) },
                shape = SegmentedButtonDefaults.itemShape(
                    index = index,
                    count = providers.size
                )
            ) {
                Text(provider.displayName)
            }
        }
    }
}
