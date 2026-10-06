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

package com.bmlibrarian.factchecker.ui.fulltext.components

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Link
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.ButtonDefaults
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.FullTextLinkKind
import com.bmlibrarian.factchecker.util.Constants

/**
 * A card's full-text section for a record whose last fetch left only a link
 * (#471).
 *
 * Says what the link is ([FullTextLinkKind.statement]) instead of the
 * "not yet attempted" fetch button, which read as though the chain had never
 * run. The retry stays, labelled as one: an open-access lookup that went
 * unsettled invites it, and a PDF that failed to download may download now.
 * The link offered is the one the record keeps: the PDF's address when a PDF
 * was served and not saved (#480), which the caching note beside it says is
 * all that was kept; otherwise the publisher's page, when there is a DOI to
 * open.
 *
 * @param kind What the record's link is
 * @param doi The record's DOI, or null when it has none
 * @param pdfUrl The PDF address the record keeps
 *   ([com.bmlibrarian.factchecker.data.local.entity.DocumentEntity.linkOnlyPdfUrl]),
 *   offered in place of the publisher's page; null when it keeps none
 * @param isLoading Whether a fetch is running
 * @param retryEnabled Whether the retry may start (false while another action runs)
 * @param onRetry Runs the full-text chain again
 * @param onOpenPublisher Opens the publisher's page for a DOI
 * @param onOpenUrl Opens an address, here the kept PDF's
 */
@Composable
fun LinkOnlyFullTextSection(
    kind: FullTextLinkKind,
    doi: String?,
    pdfUrl: String?,
    isLoading: Boolean,
    retryEnabled: Boolean,
    onRetry: (() -> Unit)?,
    onOpenPublisher: ((String) -> Unit)?,
    onOpenUrl: ((String) -> Unit)?
) {
    Column(verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
        ) {
            Icon(
                imageVector = Icons.Default.Link,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
            )
            Text(
                text = kind.statement,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }

        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
        ) {
            OutlinedButton(
                onClick = { onRetry?.invoke() },
                enabled = retryEnabled && !isLoading,
                contentPadding = ButtonDefaults.ButtonWithIconContentPadding
            ) {
                if (isLoading) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp),
                        strokeWidth = 2.dp
                    )
                } else {
                    Icon(
                        imageVector = Icons.Default.Refresh,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                }
                Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                Text(if (isLoading) "Fetching..." else "Try Again")
            }

            if (pdfUrl != null) {
                OutlinedButton(
                    onClick = { onOpenUrl?.invoke(pdfUrl) },
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding
                ) {
                    Icon(
                        imageVector = Icons.Default.OpenInBrowser,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    Text("Open PDF")
                }
            } else doi?.takeIf { it.isNotBlank() }?.let { publisherDoi ->
                OutlinedButton(
                    onClick = { onOpenPublisher?.invoke(publisherDoi) },
                    contentPadding = ButtonDefaults.ButtonWithIconContentPadding
                ) {
                    Icon(
                        imageVector = Icons.Default.OpenInBrowser,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    Text("Publisher")
                }
            }
        }
    }
}
