package com.bmlibrarian.factchecker.ui.history

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.History
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.util.Constants

/**
 * Session history screen.
 *
 * Shows past fact-checking sessions with their claims and verdicts.
 * This is a placeholder implementation - full history browsing will
 * be implemented in a future phase.
 *
 * @param onSessionClick Callback when a session is selected
 *
 * TODO: Implement full history with:
 * - List of past sessions with claim text
 * - Verdict badges and timestamps
 * - Search/filter functionality
 * - Delete session capability
 * - Click to view report
 */
@Composable
fun HistoryScreen(
    onSessionClick: (String) -> Unit = {}
) {
    Box(
        modifier = Modifier
            .fillMaxSize()
            .padding(Constants.UI_PLACEHOLDER_PADDING.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.History,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.height(Constants.UI_ICON_SIZE_LARGE.dp)
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "History",
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onBackground
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = "No Sessions Yet",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary
            )

            Spacer(modifier = Modifier.height((Constants.UI_SECTION_SPACING + Constants.UI_ELEMENT_SPACING).dp))

            Text(
                text = "Your fact-checking sessions will appear here.\n\nStart a fact-check to see your history.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}
