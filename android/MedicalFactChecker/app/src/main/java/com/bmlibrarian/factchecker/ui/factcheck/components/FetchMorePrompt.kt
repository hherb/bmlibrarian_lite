package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.FilledTonalButton
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

/**
 * Prompt asking user if they want to fetch more documents.
 *
 * Displayed when the workflow finds fewer relevant documents than desired
 * but more are available from the search provider.
 *
 * @param relevantCount Current count of relevant documents found
 * @param targetCount Target number of relevant documents
 * @param availableCount Number of additional documents available
 * @param onFetchMore Callback when user chooses to fetch more
 * @param onSkip Callback when user chooses to skip and continue
 * @param modifier Modifier for the component
 */
@Composable
fun FetchMorePrompt(
    relevantCount: Int,
    targetCount: Int,
    availableCount: Int,
    onFetchMore: () -> Unit,
    onSkip: () -> Unit,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.secondaryContainer
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Fetch More Documents?",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer
            )

            Spacer(modifier = Modifier.height(8.dp))

            Text(
                text = buildPromptMessage(relevantCount, targetCount, availableCount),
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSecondaryContainer
            )

            Spacer(modifier = Modifier.height(16.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(12.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                OutlinedButton(
                    onClick = onSkip,
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Continue Without")
                }

                FilledTonalButton(
                    onClick = onFetchMore,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        imageVector = Icons.Default.Search,
                        contentDescription = null
                    )
                    Text("Fetch More")
                }
            }
        }
    }
}

/**
 * Build the prompt message based on document counts.
 *
 * @param relevantCount Number of relevant documents found
 * @param targetCount Target number of relevant documents
 * @param availableCount Number of additional documents available
 * @return Formatted message string
 */
private fun buildPromptMessage(
    relevantCount: Int,
    targetCount: Int,
    availableCount: Int
): String {
    return buildString {
        append("Found $relevantCount relevant document")
        if (relevantCount != 1) append("s")
        append(" (target: $targetCount).\n\n")
        append("Approximately $availableCount more document")
        if (availableCount != 1) append("s are")
        else append(" is")
        append(" available. Would you like to search for more?")
    }
}
