package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.width
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants

/**
 * Header component showing the verdict badge and summary.
 *
 * Displays at the top of the report screen with a colored background
 * that corresponds to the verdict type.
 *
 * @param verdict The verdict to display
 * @param summary Brief summary text of the evidence
 * @param modifier Modifier for customizing the header
 */
@Composable
fun VerdictHeader(
    verdict: Verdict,
    summary: String,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = verdict.color.copy(alpha = BACKGROUND_ALPHA)
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Verdict:",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))

                VerdictBadge(verdict = verdict)
            }

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = summary,
                style = MaterialTheme.typography.bodyLarge,
                color = MaterialTheme.colorScheme.onSurface
            )
        }
    }
}

/** Alpha value for the verdict background color. */
private const val BACKGROUND_ALPHA = 0.1f

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderSupportedPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.SUPPORTED,
            summary = "Strong evidence from multiple randomized controlled trials supports the claim that regular exercise reduces cardiovascular disease risk."
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderUnclearPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.UNCLEAR,
            summary = "Evidence is mixed regarding the effectiveness of vitamin D supplementation for preventing respiratory infections."
        )
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictHeaderRefutedPreview() {
    MedicalFactCheckerTheme {
        VerdictHeader(
            verdict = Verdict.REFUTED,
            summary = "No credible scientific evidence supports the claim. Multiple systematic reviews have found no benefit."
        )
    }
}
