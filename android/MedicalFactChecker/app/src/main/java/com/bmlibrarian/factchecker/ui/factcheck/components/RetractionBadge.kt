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

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.padding
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.retraction.PaperRetractionCheck
import com.bmlibrarian.factchecker.util.retraction.RetractionText
import org.bmlib.ffi.RetractionStatus

/**
 * What a retraction badge says (Swift's `RetractionBadge.Content`, the
 * desktop's `retraction_badge`): clear shows nothing; a paper never checked
 * shows NOT CHECKED only in a detail view, so a list stays quiet about
 * papers never checked (one whose check came back unchecked shows it).
 *
 * @property text The badge's text
 * @property statusLine The paper's status line, read aloud
 * @property isRetracted Whether it is drawn in the error colour
 * @property isConcern Whether it is drawn in the warning colour
 */
data class RetractionBadgeContent(val text: String, val statusLine: String, val isRetracted: Boolean, val isConcern: Boolean) {
    companion object {
        /**
         * The content for a check, or null when no badge is shown.
         *
         * @param check The paper's check; null when it was never checked
         * @param inDetail Whether this is a detail view, where a never-checked paper is NOT CHECKED
         */
        fun of(check: PaperRetractionCheck?, inDetail: Boolean = false): RetractionBadgeContent? {
            if (check == null) {
                return if (inDetail) RetractionBadgeContent(NOT_CHECKED, RetractionText.checkedOnLine(null), false, false) else null
            }
            // exhaustive: a status bmlib adds must be given its badge, never read as clear
            val text = when (check.retractionStatus) {
                RetractionStatus.RETRACTED -> "RETRACTED"
                RetractionStatus.CONCERN -> "CONCERN"
                RetractionStatus.UNCHECKED -> NOT_CHECKED
                RetractionStatus.CLEAR -> return null
            }
            return RetractionBadgeContent(text, RetractionText.paperStatusLine(check), check.isRetracted, check.isConcern)
        }

        private const val NOT_CHECKED = "NOT CHECKED"

        /** A detail view's paper whose check could not be read: NOT CHECKED, said as unread, not never checked. */
        val UNREAD = RetractionBadgeContent(NOT_CHECKED, RetractionText.STATUS_UNREAD, false, false)
    }
}

/**
 * A paper's retraction status as a badge: RETRACTED, CONCERN or NOT CHECKED.
 *
 * @param content What it says ([RetractionBadgeContent.of])
 */
@Composable
fun RetractionBadge(content: RetractionBadgeContent, modifier: Modifier = Modifier) {
    val colors = MaterialTheme.colorScheme
    val (background, foreground) = when {
        content.isRetracted -> colors.errorContainer to colors.onErrorContainer
        content.isConcern -> colors.tertiaryContainer to colors.onTertiaryContainer
        else -> colors.surfaceVariant to colors.onSurfaceVariant
    }
    Surface(
        color = background,
        shape = MaterialTheme.shapes.small,
        modifier = modifier.semantics { contentDescription = content.statusLine }
    ) {
        Text(
            text = content.text,
            style = MaterialTheme.typography.labelSmall,
            color = foreground,
            modifier = Modifier.padding(
                horizontal = Constants.UI_BADGE_PADDING_HORIZONTAL.dp,
                vertical = Constants.UI_BADGE_PADDING_VERTICAL.dp
            )
        )
    }
}

/**
 * A restored session's retraction line with *Check again*, and the warning
 * when a paper its report cites is now retracted or under concern (the
 * desktop's report-tab line, button and warning; Swift's
 * `RetractionSavedWorkSection`). While the check runs, the button stops it.
 *
 * @param line The saved-work line
 * @param warning The warning, or null
 * @param checking Whether *Check again* is running
 * @param enabled Whether *Check again* may start (no run is going)
 * @param onCheckAgain Starts *Check again*
 * @param onCancel Stops it
 */
@Composable
fun RetractionSavedWorkCard(
    line: String,
    warning: String?,
    checking: Boolean,
    enabled: Boolean,
    onCheckAgain: () -> Unit,
    onCancel: () -> Unit
) {
    Column(verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp)
        ) {
            Text(
                text = line,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                modifier = Modifier.weight(1f)
            )
            if (checking) {
                OutlinedButton(onClick = onCancel) { Text("Cancel") }
            } else {
                OutlinedButton(onClick = onCheckAgain, enabled = enabled) { Text(RetractionText.CHECK_AGAIN_LABEL) }
            }
        }
        warning?.let {
            Card(
                colors = CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.errorContainer),
                modifier = Modifier.fillMaxWidth()
            ) {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onErrorContainer,
                    modifier = Modifier.padding(Constants.UI_CARD_PADDING.dp)
                )
            }
        }
    }
}
