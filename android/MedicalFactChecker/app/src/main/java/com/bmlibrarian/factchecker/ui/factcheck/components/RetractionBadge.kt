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

import androidx.compose.foundation.layout.padding
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
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
