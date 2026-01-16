package com.bmlibrarian.factchecker.ui.settings

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Settings
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
 * Settings and configuration screen.
 *
 * Allows users to configure LLM provider, API keys, budget limits,
 * and other app settings.
 * This is a placeholder implementation - full settings will be
 * implemented in a future phase.
 *
 * TODO: Implement full settings with:
 * - LLM provider selection (OpenAI, Anthropic, Ollama)
 * - API key entry with secure storage
 * - Model selection per provider
 * - Budget configuration (per-run and monthly limits)
 * - NCBI email configuration
 * - Search provider selection
 * - Data management (clear history, export data)
 */
@Composable
fun SettingsScreen() {
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
                imageVector = Icons.Default.Settings,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.height(Constants.UI_ICON_SIZE_LARGE.dp)
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "Settings",
                style = MaterialTheme.typography.headlineMedium,
                color = MaterialTheme.colorScheme.onBackground
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = "Coming Soon",
                style = MaterialTheme.typography.titleMedium,
                color = MaterialTheme.colorScheme.primary
            )

            Spacer(modifier = Modifier.height((Constants.UI_SECTION_SPACING + Constants.UI_ELEMENT_SPACING).dp))

            Text(
                text = "Configure your LLM provider, API keys, and budget limits.\n\nFor now, settings are configured via build configuration.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}
