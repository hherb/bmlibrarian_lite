package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.ui.theme.MedicalFactCheckerTheme
import com.bmlibrarian.factchecker.util.Constants

/**
 * A color-coded badge displaying the verdict.
 *
 * Shows the verdict text with appropriate background color to
 * quickly communicate the result to users.
 *
 * @param verdict The verdict to display
 * @param modifier Modifier for customizing the badge appearance
 */
@Composable
fun VerdictBadge(
    verdict: Verdict,
    modifier: Modifier = Modifier
) {
    Surface(
        color = verdict.color,
        shape = MaterialTheme.shapes.small,
        modifier = modifier
    ) {
        Text(
            text = verdict.displayName,
            style = MaterialTheme.typography.labelLarge,
            color = getTextColorForBackground(verdict.color),
            modifier = Modifier.padding(
                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
            )
        )
    }
}

/**
 * Determines appropriate text color for a given background color.
 *
 * Uses luminance calculation (ITU-R BT.601 Y' coefficients) to determine
 * if white or black text provides better contrast.
 *
 * @param backgroundColor The background color to check
 * @return White or black color for optimal text contrast
 */
private fun getTextColorForBackground(backgroundColor: Color): Color {
    // Calculate relative luminance using ITU-R BT.601 Y' coefficients
    val luminance = (Constants.LUMINANCE_RED_COEFFICIENT * backgroundColor.red +
            Constants.LUMINANCE_GREEN_COEFFICIENT * backgroundColor.green +
            Constants.LUMINANCE_BLUE_COEFFICIENT * backgroundColor.blue)

    return if (luminance > Constants.LUMINANCE_THRESHOLD) Color.Black else Color.White
}

@Preview(showBackground = true)
@Composable
private fun VerdictBadgeSupportedPreview() {
    MedicalFactCheckerTheme {
        VerdictBadge(verdict = Verdict.SUPPORTED)
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictBadgeLikelySupportedPreview() {
    MedicalFactCheckerTheme {
        VerdictBadge(verdict = Verdict.LIKELY_SUPPORTED)
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictBadgeUnclearPreview() {
    MedicalFactCheckerTheme {
        VerdictBadge(verdict = Verdict.UNCLEAR)
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictBadgeLikelyRefutedPreview() {
    MedicalFactCheckerTheme {
        VerdictBadge(verdict = Verdict.LIKELY_REFUTED)
    }
}

@Preview(showBackground = true)
@Composable
private fun VerdictBadgeRefutedPreview() {
    MedicalFactCheckerTheme {
        VerdictBadge(verdict = Verdict.REFUTED)
    }
}
