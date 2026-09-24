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

package com.bmlibrarian.factchecker.ui.common

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.domain.transparency.HighRiskTransparencySection
import com.bmlibrarian.factchecker.domain.transparency.TransparencyCertainty
import com.bmlibrarian.factchecker.domain.transparency.TransparencyConstants
import com.bmlibrarian.factchecker.domain.transparency.TransparencyRiskExplanation
import com.bmlibrarian.factchecker.domain.transparency.TransparencyRiskLevel
import com.bmlibrarian.factchecker.domain.transparency.transparencyCertainty
import com.bmlibrarian.factchecker.domain.transparency.transparencyResult
import com.bmlibrarian.factchecker.ui.theme.Disabled
import com.bmlibrarian.factchecker.ui.theme.Warning
import com.bmlibrarian.factchecker.ui.theme.riskColor
import com.bmlibrarian.factchecker.util.Constants

/** Opacity of a risk badge's background tint. */
private const val RISK_BADGE_BACKGROUND_ALPHA = 0.15f

/**
 * A document's transparency risk, qualified when its certainty is limited.
 *
 * Full-text analysis is the standard; a rating short of it reads
 * "High · limited", so it cannot be mistaken for one that met it.
 *
 * @param level The risk level
 * @param certainty How far the rating can be relied on; null shows the level alone
 * @param unassessed Whether the rating is shown as unassessed rather than high: every reason
 *   for it rests on statements in full text that was not searched
 */
@Composable
fun TransparencyRiskBadge(
    level: TransparencyRiskLevel,
    certainty: TransparencyCertainty?,
    unassessed: Boolean,
    modifier: Modifier = Modifier
) {
    val color = if (unassessed) Disabled else riskColor(level)
    val levelLabel = if (unassessed) TransparencyConstants.UNASSESSED_LABEL else level.shortLabel
    val label = if (certainty?.isLimited == true) {
        "$levelLabel ${TransparencyConstants.LIMITED_CERTAINTY_BADGE_SUFFIX}"
    } else {
        levelLabel
    }
    val spokenLevel = if (unassessed) TransparencyConstants.UNASSESSED_LABEL else level.fullLabel
    val spoken = listOfNotNull("Transparency risk: $spokenLevel", certainty?.note).joinToString(". ")
    Surface(
        color = color.copy(alpha = RISK_BADGE_BACKGROUND_ALPHA),
        shape = MaterialTheme.shapes.small,
        modifier = modifier.semantics { contentDescription = spoken }
    ) {
        Text(
            text = "Risk: $label",
            style = MaterialTheme.typography.labelSmall,
            color = color,
            modifier = Modifier.padding(
                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
            )
        )
    }
}

/**
 * A document's transparency analysis: its rating, what limits it, and why.
 *
 * Shows nothing for a document never analysed, and says so for one whose
 * stored analysis can no longer be read.
 *
 * @param document The document
 */
@Composable
fun TransparencyDetails(document: DocumentEntity, modifier: Modifier = Modifier) {
    if (document.transparencyResultJson == null) return
    val result = document.transparencyResult
    if (result == null) {
        Text(
            text = "This document's transparency analysis could not be read. It carries no rating.",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.error,
            modifier = modifier
        )
        return
    }
    val certainty = document.transparencyCertainty
    val explanation = TransparencyRiskExplanation.of(result, certainty)

    Column(
        modifier = modifier,
        verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp)
    ) {
        Text(
            text = "Transparency Analysis",
            style = MaterialTheme.typography.titleSmall,
            color = MaterialTheme.colorScheme.onSurface
        )
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
        ) {
            TransparencyRiskBadge(
                level = result.riskLevel,
                certainty = certainty,
                unassessed = explanation.isUnassessed
            )
            Text(
                text = "Score ${explanation.score}/${TransparencyConstants.MAX_TRANSPARENCY_SCORE}",
                style = MaterialTheme.typography.labelLarge,
                color = if (explanation.isUnassessed) Disabled else riskColor(result.riskLevel)
            )
        }
        explanation.certainty.note?.let {
            Text(
                text = it,
                style = MaterialTheme.typography.bodySmall,
                fontWeight = FontWeight.SemiBold,
                color = Warning
            )
        }
        if (explanation.isUnassessed) {
            Text(
                text = TransparencyConstants.UNASSESSED_NOTE,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        if (result.isStale) {
            Text(
                text = "Analysed by an earlier version of the analyser; its score may not be comparable with a current one.",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
        BulletList(
            if (explanation.isUnassessed) {
                HighRiskTransparencySection.UNASSESSED_REASONS_LABEL
            } else {
                HighRiskTransparencySection.REASONS_LABEL
            },
            explanation.reasons
        )
        BulletList(
            HighRiskTransparencySection.SCORE_BREAKDOWN_LABEL,
            explanation.scoreBreakdown.map { "${it.label}: ${it.signedPoints}" }
        )
        BulletList(HighRiskTransparencySection.OTHER_CONCERNS_LABEL, explanation.otherConcerns)
        BulletList(HighRiskTransparencySection.CAVEATS_LABEL, explanation.caveats)
    }
}

/** A labelled list, or nothing when it has no items. */
@Composable
private fun BulletList(label: String, items: List<String>) {
    if (items.isEmpty()) return
    Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING_SMALL.dp))
    Text(
        text = label,
        style = MaterialTheme.typography.labelMedium,
        color = MaterialTheme.colorScheme.onSurface
    )
    items.forEach { item ->
        Text(
            text = "• $item",
            style = MaterialTheme.typography.bodySmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
