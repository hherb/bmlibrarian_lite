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

package com.bmlibrarian.factchecker.ui.report.components

import android.graphics.Typeface
import android.text.Spannable
import android.text.SpannableStringBuilder
import android.text.method.LinkMovementMethod
import android.text.style.ClickableSpan
import android.text.style.ForegroundColorSpan
import android.text.style.StyleSpan
import android.view.View
import android.widget.TextView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.Composable
import androidx.compose.runtime.remember
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import com.bmlibrarian.factchecker.util.Constants
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin
import java.util.regex.Pattern

/**
 * Information about a clicked reference.
 *
 * Contains either a document ID (from embedded link) or author/year
 * information for fallback lookup.
 *
 * @property documentId Document ID if embedded in reference (e.g., "pmid-12345678")
 * @property displayText Display text of the reference (e.g., "Smith et al., 2021")
 * @property authorName Parsed author name for fallback lookup
 * @property year Parsed year for fallback lookup
 */
data class ReferenceInfo(
    val documentId: String? = null,
    val displayText: String,
    val authorName: String? = null,
    val year: Int? = null
)

/**
 * Renders markdown content with clickable citation references.
 *
 * Uses Markwon library for markdown rendering and adds custom handling
 * for author/year style references like [Smith et al., 2021](doc:pmid-12345678)
 * that can be clicked to show the corresponding document.
 *
 * Supports two reference formats (matching iOS implementation):
 * 1. With embedded ID: [Author, Year](doc:pmid-12345678)
 * 2. Legacy format: [Author, Year]
 *
 * @param markdown The markdown content to render
 * @param onReferenceClick Callback when a reference is clicked, passes reference info
 * @param modifier Modifier for customizing the component
 */
@Composable
fun MarkdownReport(
    markdown: String,
    onReferenceClick: (ReferenceInfo) -> Unit,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val textColor = MaterialTheme.colorScheme.onSurface.toArgb()
    val linkColor = MaterialTheme.colorScheme.primary.toArgb()

    // Create Markwon instance with table support
    val markwon = remember {
        Markwon.builder(context)
            .usePlugin(TablePlugin.create(context))
            .build()
    }

    AndroidView(
        factory = { ctx ->
            TextView(ctx).apply {
                setTextColor(textColor)
                setLinkTextColor(linkColor)
                textSize = Constants.MARKDOWN_TEXT_SIZE_SP
                movementMethod = LinkMovementMethod.getInstance()
                // Enable selectable text for copy/paste
                setTextIsSelectable(true)
            }
        },
        update = { textView ->
            // First render markdown with Markwon
            val spanned = markwon.toMarkdown(markdown)

            // Then process references to make them clickable
            val processedText = processReferences(
                text = spanned,
                linkColor = linkColor,
                onReferenceClick = onReferenceClick
            )

            textView.text = processedText
        },
        modifier = modifier.fillMaxWidth()
    )
}

/**
 * Process markdown text to add clickable reference spans.
 *
 * Finds author/year references like [Smith et al., 2021](doc:pmid-12345678)
 * and wraps them in ClickableSpan instances that trigger the callback when tapped.
 *
 * @param text The spannable text from Markwon
 * @param linkColor Color for reference links
 * @param onReferenceClick Callback when a reference is clicked
 * @return SpannableStringBuilder with clickable references
 */
private fun processReferences(
    text: CharSequence,
    linkColor: Int,
    onReferenceClick: (ReferenceInfo) -> Unit
): SpannableStringBuilder {
    val builder = SpannableStringBuilder(text)

    // Try new author/year format first
    val matches = mutableListOf<ReferenceMatch>()
    val pattern = Pattern.compile(Constants.REFERENCE_PATTERN)
    val matcher = pattern.matcher(builder)

    while (matcher.find()) {
        val start = matcher.start()
        val end = matcher.end()
        val displayText = matcher.group(1) ?: continue
        val documentId = matcher.group(2) // May be null for legacy format

        // Parse author and year from display text
        val (authorName, year) = parseAuthorYear(displayText)

        matches.add(
            ReferenceMatch(
                start = start,
                end = end,
                info = ReferenceInfo(
                    documentId = documentId,
                    displayText = displayText,
                    authorName = authorName,
                    year = year
                )
            )
        )
    }

    // If no author/year matches found, try legacy numeric pattern
    if (matches.isEmpty()) {
        val legacyPattern = Pattern.compile(Constants.LEGACY_REFERENCE_PATTERN)
        val legacyMatcher = legacyPattern.matcher(builder)

        while (legacyMatcher.find()) {
            val start = legacyMatcher.start()
            val end = legacyMatcher.end()
            val refNumber = legacyMatcher.group(1)?.toIntOrNull() ?: continue

            matches.add(
                ReferenceMatch(
                    start = start,
                    end = end,
                    info = ReferenceInfo(
                        documentId = null,
                        displayText = "[$refNumber]",
                        authorName = null,
                        year = null
                    )
                )
            )
        }
    }

    // Apply spans in reverse order to avoid position shifts
    for (match in matches.asReversed()) {
        // Add clickable span
        val clickableSpan = object : ClickableSpan() {
            override fun onClick(widget: View) {
                onReferenceClick(match.info)
            }

            override fun updateDrawState(ds: android.text.TextPaint) {
                super.updateDrawState(ds)
                ds.color = linkColor
                ds.isUnderlineText = false
            }
        }

        builder.setSpan(
            clickableSpan,
            match.start,
            match.end,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
        )

        // Add color span
        builder.setSpan(
            ForegroundColorSpan(linkColor),
            match.start,
            match.end,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
        )

        // Make it bold for emphasis
        builder.setSpan(
            StyleSpan(Typeface.BOLD),
            match.start,
            match.end,
            Spannable.SPAN_EXCLUSIVE_EXCLUSIVE
        )
    }

    return builder
}

/**
 * Parse author name and year from reference display text.
 *
 * Handles formats like:
 * - "Smith et al., 2021"
 * - "Smith, 2021"
 * - "Smith and Jones, 2021"
 *
 * @param displayText The display text to parse
 * @return Pair of (authorName, year) - either may be null
 */
private fun parseAuthorYear(displayText: String): Pair<String?, Int?> {
    // Split by comma to separate author part from year
    val parts = displayText.split(",")
    if (parts.size < 2) return null to null

    // Author is everything before the last comma
    val authorPart = parts.dropLast(1).joinToString(",").trim()
        .replace(" et al.", "")
        .replace(" and ", " ")

    // Year is after the last comma, remove any suffix letters (2021a -> 2021)
    val yearPart = parts.last().trim()
        .filter { it.isDigit() }

    val authorName = authorPart.split(" ").firstOrNull()?.lowercase()
    val year = yearPart.toIntOrNull()

    return authorName to year
}

/**
 * Data class to hold reference match information.
 *
 * @property start Start position in the text
 * @property end End position in the text
 * @property info Reference information for lookup
 */
private data class ReferenceMatch(
    val start: Int,
    val end: Int,
    val info: ReferenceInfo
)
