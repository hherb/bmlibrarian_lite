/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

import android.widget.TextView
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import io.noties.markwon.html.HtmlPlugin

/**
 * Composable that renders markdown text with basic formatting.
 *
 * Supports common markdown syntax including:
 * - Bold text: **text** or __text__
 * - Italic text: *text* or _text_
 * - Line breaks via double newlines
 * - HTML tags like <h4>, <strong>, <em>, etc.
 *
 * Used for rendering structured abstracts with section labels
 * like "**Background:** text" or "<h4>Background:</h4> text".
 *
 * @param text The markdown text to render
 * @param modifier Modifier for the component
 * @param textSizeSp Text size in SP units
 */
@Composable
fun MarkdownText(
    text: String,
    modifier: Modifier = Modifier,
    textSizeSp: Float = 14f
) {
    val context = LocalContext.current
    val textColor = MaterialTheme.colorScheme.onSurface.toArgb()

    val markwon = remember {
        Markwon.builder(context)
            .usePlugin(HtmlPlugin.create())
            .build()
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(textColor)
                textSize = textSizeSp
            }
        },
        update = { textView ->
            val spanned = markwon.toMarkdown(text)
            textView.text = spanned
        },
        modifier = modifier
    )
}
