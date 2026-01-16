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
 * Renders markdown content with clickable citation references.
 *
 * Uses Markwon library for markdown rendering and adds custom handling
 * for [1], [2], etc. style references that can be clicked to show
 * the corresponding document.
 *
 * @param markdown The markdown content to render
 * @param onReferenceClick Callback when a reference is clicked, passes the reference number
 * @param modifier Modifier for customizing the component
 */
@Composable
fun MarkdownReport(
    markdown: String,
    onReferenceClick: (Int) -> Unit,
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
                textSize = TEXT_SIZE_SP
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
 * Finds all [1], [2], etc. patterns in the text and wraps them
 * in ClickableSpan instances that trigger the callback when tapped.
 *
 * @param text The spannable text from Markwon
 * @param linkColor Color for reference links
 * @param onReferenceClick Callback when a reference is clicked
 * @return SpannableStringBuilder with clickable references
 */
private fun processReferences(
    text: CharSequence,
    linkColor: Int,
    onReferenceClick: (Int) -> Unit
): SpannableStringBuilder {
    val builder = SpannableStringBuilder(text)
    val pattern = Pattern.compile(Constants.REFERENCE_PATTERN)
    val matcher = pattern.matcher(builder)

    // Find all matches and store their positions
    // We need to do this because adding spans while iterating can cause issues
    val matches = mutableListOf<ReferenceMatch>()

    while (matcher.find()) {
        val start = matcher.start()
        val end = matcher.end()
        val refNumber = matcher.group(1)?.toIntOrNull() ?: continue

        matches.add(ReferenceMatch(start, end, refNumber))
    }

    // Apply spans in reverse order to avoid position shifts
    for (match in matches.asReversed()) {
        // Add clickable span
        val clickableSpan = object : ClickableSpan() {
            override fun onClick(widget: View) {
                onReferenceClick(match.referenceNumber)
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
 * Data class to hold reference match information.
 *
 * @property start Start position in the text
 * @property end End position in the text
 * @property referenceNumber The extracted reference number
 */
private data class ReferenceMatch(
    val start: Int,
    val end: Int,
    val referenceNumber: Int
)

/** Text size in SP for the markdown content. */
private const val TEXT_SIZE_SP = 16f
