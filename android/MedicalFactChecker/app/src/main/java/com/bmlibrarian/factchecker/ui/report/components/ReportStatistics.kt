package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale

/**
 * Statistics section showing report metadata.
 *
 * Displays key metrics from the fact-checking workflow including
 * document counts, model information, and generation timestamp.
 *
 * @param totalDocuments Total number of documents reviewed
 * @param relevantDocuments Number of documents meeting relevance threshold
 * @param citations Number of citations extracted
 * @param model LLM model used to generate the report
 * @param generatedAt Timestamp when the report was generated
 * @param modifier Modifier for customizing the component
 */
@Composable
fun ReportStatistics(
    totalDocuments: Int,
    relevantDocuments: Int,
    citations: Int,
    model: String,
    generatedAt: Date,
    modifier: Modifier = Modifier
) {
    val dateFormat = remember {
        SimpleDateFormat(Constants.REPORT_DATETIME_DISPLAY_PATTERN, Locale.getDefault())
    }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Text(
                text = "Report Statistics",
                style = MaterialTheme.typography.titleSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            // Statistics row
            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                StatItem(
                    label = "Documents Reviewed",
                    value = totalDocuments.toString()
                )
                StatItem(
                    label = "Relevant",
                    value = relevantDocuments.toString()
                )
                StatItem(
                    label = "Citations",
                    value = citations.toString()
                )
            }

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            HorizontalDivider(
                color = MaterialTheme.colorScheme.outline.copy(alpha = DIVIDER_ALPHA)
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            // Model info
            Text(
                text = "Model: $model",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            // Generated timestamp
            Text(
                text = "Generated: ${dateFormat.format(generatedAt)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * Individual statistic item with value and label.
 *
 * @param label Description of the statistic
 * @param value The numeric value to display
 */
@Composable
private fun StatItem(
    label: String,
    value: String
) {
    Column {
        Text(
            text = value,
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.primary
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}

/** Alpha for the divider line. */
private const val DIVIDER_ALPHA = 0.5f

@Preview(showBackground = true)
@Composable
private fun ReportStatisticsPreview() {
    MedicalFactCheckerTheme {
        ReportStatistics(
            totalDocuments = 25,
            relevantDocuments = 12,
            citations = 8,
            model = "claude-sonnet-4-20250514",
            generatedAt = Date()
        )
    }
}
