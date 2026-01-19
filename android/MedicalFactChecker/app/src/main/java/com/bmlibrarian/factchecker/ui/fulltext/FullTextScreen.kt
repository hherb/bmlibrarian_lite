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

package com.bmlibrarian.factchecker.ui.fulltext

import android.content.Intent
import android.net.Uri
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.fulltext.FullTextViewModel.FullTextState
import com.bmlibrarian.factchecker.ui.fulltext.components.FullTextSourceBadge
import com.bmlibrarian.factchecker.util.Constants

/**
 * Full-text viewer screen.
 *
 * Displays full-text content from Europe PMC (HTML), PDFs, or web URLs.
 *
 * @param documentId ID of the document to display.
 * @param onNavigateBack Callback to navigate back.
 * @param viewModel ViewModel instance.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun FullTextScreen(
    documentId: String,
    onNavigateBack: () -> Unit,
    viewModel: FullTextViewModel = hiltViewModel()
) {
    val state by viewModel.state.collectAsState()
    val document by viewModel.document.collectAsState()
    val context = LocalContext.current

    // Load document on entry
    LaunchedEffect(documentId) {
        viewModel.loadDocument(documentId)
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = {
                    Column {
                        Text(
                            text = document?.title ?: "Full Text",
                            maxLines = 1,
                            overflow = TextOverflow.Ellipsis,
                            style = MaterialTheme.typography.titleMedium
                        )
                        when (val currentState = state) {
                            is FullTextState.HtmlContent -> {
                                FullTextSourceBadge(source = currentState.source)
                            }
                            is FullTextState.MarkdownContent -> {
                                FullTextSourceBadge(source = currentState.source)
                            }
                            is FullTextState.PdfContent -> {
                                FullTextSourceBadge(source = currentState.source)
                            }
                            else -> {}
                        }
                    }
                },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(
                            imageVector = Icons.AutoMirrored.Filled.ArrowBack,
                            contentDescription = "Back"
                        )
                    }
                },
                actions = {
                    // Refresh button
                    if (state !is FullTextState.Loading) {
                        IconButton(onClick = { viewModel.refresh() }) {
                            Icon(
                                imageVector = Icons.Default.Refresh,
                                contentDescription = "Refresh"
                            )
                        }
                    }

                    // Open in browser for web URLs
                    (state as? FullTextState.WebUrl)?.let { webState ->
                        IconButton(onClick = {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(webState.url))
                            context.startActivity(intent)
                        }) {
                            Icon(
                                imageVector = Icons.Default.OpenInBrowser,
                                contentDescription = "Open in browser"
                            )
                        }
                    }
                },
                colors = TopAppBarDefaults.topAppBarColors(
                    containerColor = MaterialTheme.colorScheme.surface
                )
            )
        }
    ) { paddingValues ->
        Box(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
        ) {
            when (val currentState = state) {
                is FullTextState.Idle,
                is FullTextState.Loading -> {
                    LoadingContent()
                }

                is FullTextState.HtmlContent -> {
                    HtmlViewer(html = currentState.html)
                }

                is FullTextState.MarkdownContent -> {
                    // For now, render markdown as HTML in WebView
                    HtmlViewer(html = markdownToBasicHtml(currentState.markdown))
                }

                is FullTextState.PdfContent -> {
                    // TODO: Implement PDF viewer
                    PdfPlaceholder(
                        pdfPath = currentState.pdfPath,
                        onOpenExternal = {
                            // Open PDF with external viewer
                            val uri = Uri.parse("file://${currentState.pdfPath}")
                            val intent = Intent(Intent.ACTION_VIEW).apply {
                                setDataAndType(uri, "application/pdf")
                                flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                            }
                            context.startActivity(intent)
                        }
                    )
                }

                is FullTextState.WebUrl -> {
                    WebUrlContent(
                        url = currentState.url,
                        onOpenInBrowser = {
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(currentState.url))
                            context.startActivity(intent)
                        }
                    )
                }

                is FullTextState.Error -> {
                    ErrorContent(
                        message = currentState.message,
                        canRetry = currentState.canRetry,
                        onRetry = { viewModel.retry() }
                    )
                }

                is FullTextState.Unavailable -> {
                    UnavailableContent(
                        reason = currentState.reason,
                        doi = document?.doi,
                        onOpenDoi = { doi ->
                            val url = "${Constants.DOI_URL_PREFIX}$doi"
                            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                            context.startActivity(intent)
                        }
                    )
                }
            }
        }
    }
}

/**
 * Loading indicator content.
 */
@Composable
private fun LoadingContent() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center
        ) {
            CircularProgressIndicator()
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = "Loading full text...",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

/**
 * HTML content viewer using WebView.
 */
@Composable
private fun HtmlViewer(html: String) {
    AndroidView(
        modifier = Modifier.fillMaxSize(),
        factory = { context ->
            WebView(context).apply {
                settings.apply {
                    javaScriptEnabled = true
                    loadWithOverviewMode = true
                    useWideViewPort = true
                    builtInZoomControls = true
                    displayZoomControls = false
                }
                webViewClient = WebViewClient()
            }
        },
        update = { webView ->
            webView.loadDataWithBaseURL(
                null,
                html,
                "text/html",
                "UTF-8",
                null
            )
        }
    )
}

/**
 * PDF placeholder (until PDF viewer is implemented).
 */
@Composable
private fun PdfPlaceholder(
    pdfPath: String,
    onOpenExternal: () -> Unit
) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            Text(
                text = "PDF Available",
                style = MaterialTheme.typography.titleLarge
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = "The full text is available as a PDF.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            Button(onClick = onOpenExternal) {
                Text("Open PDF")
            }
        }
    }
}

/**
 * Web URL content with button to open in browser.
 */
@Composable
private fun WebUrlContent(
    url: String,
    onOpenInBrowser: () -> Unit
) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            Icon(
                imageVector = Icons.Default.OpenInBrowser,
                contentDescription = null,
                modifier = Modifier.size(Constants.UI_ICON_SIZE_LARGE.dp),
                tint = MaterialTheme.colorScheme.primary
            )
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            Text(
                text = "External Full Text",
                style = MaterialTheme.typography.titleLarge
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = "Full text is available on the publisher's website.",
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            Button(onClick = onOpenInBrowser) {
                Icon(
                    imageVector = Icons.Default.OpenInBrowser,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.padding(4.dp))
                Text("Open in Browser")
            }
        }
    }
}

/**
 * Error content with retry option.
 */
@Composable
private fun ErrorContent(
    message: String,
    canRetry: Boolean,
    onRetry: () -> Unit
) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            Icon(
                imageVector = Icons.Default.ErrorOutline,
                contentDescription = null,
                modifier = Modifier.size(Constants.UI_ICON_SIZE_LARGE.dp),
                tint = MaterialTheme.colorScheme.error
            )
            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
            Text(
                text = "Error Loading Content",
                style = MaterialTheme.typography.titleLarge
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = message,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (canRetry) {
                Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
                Button(onClick = onRetry) {
                    Text("Retry")
                }
            }
        }
    }
}

/**
 * Content unavailable placeholder.
 */
@Composable
private fun UnavailableContent(
    reason: String,
    doi: String?,
    onOpenDoi: (String) -> Unit
) {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
            modifier = Modifier.padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            Text(
                text = "Full Text Unavailable",
                style = MaterialTheme.typography.titleLarge
            )
            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
            Text(
                text = reason,
                style = MaterialTheme.typography.bodyMedium,
                textAlign = TextAlign.Center,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            if (!doi.isNullOrEmpty()) {
                Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
                OutlinedButton(onClick = { onOpenDoi(doi) }) {
                    Icon(
                        imageVector = Icons.Default.OpenInBrowser,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.padding(4.dp))
                    Text("Try Publisher Website")
                }
            }
        }
    }
}

/**
 * Convert basic markdown to HTML for display.
 *
 * This is a simple converter for basic markdown features.
 * For full markdown support, consider using a library like Markwon.
 */
private fun markdownToBasicHtml(markdown: String): String {
    var html = markdown

    // Headers
    html = html.replace(Regex("^###### (.+)$", RegexOption.MULTILINE), "<h6>$1</h6>")
    html = html.replace(Regex("^##### (.+)$", RegexOption.MULTILINE), "<h5>$1</h5>")
    html = html.replace(Regex("^#### (.+)$", RegexOption.MULTILINE), "<h4>$1</h4>")
    html = html.replace(Regex("^### (.+)$", RegexOption.MULTILINE), "<h3>$1</h3>")
    html = html.replace(Regex("^## (.+)$", RegexOption.MULTILINE), "<h2>$1</h2>")
    html = html.replace(Regex("^# (.+)$", RegexOption.MULTILINE), "<h1>$1</h1>")

    // Bold and italic
    html = html.replace(Regex("\\*\\*(.+?)\\*\\*"), "<strong>$1</strong>")
    html = html.replace(Regex("\\*(.+?)\\*"), "<em>$1</em>")

    // Links
    html = html.replace(Regex("\\[([^]]+)]\\(([^)]+)\\)"), "<a href=\"$2\">$1</a>")

    // Images
    html = html.replace(Regex("!\\[([^]]*)]\\(([^)]+)\\)"), "<img src=\"$2\" alt=\"$1\" style=\"max-width: 100%;\">")

    // Paragraphs (double newlines)
    html = html.replace(Regex("\n\n+"), "</p><p>")
    html = "<p>$html</p>"

    // Clean up empty paragraphs
    html = html.replace("<p></p>", "")
    html = html.replace("<p>\n</p>", "")

    return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif;
                    font-size: 16px;
                    line-height: 1.6;
                    padding: 16px;
                    color: #212121;
                    background: #ffffff;
                }
                h1 { font-size: 1.5em; margin-bottom: 0.5em; }
                h2 { font-size: 1.3em; margin-top: 1.5em; margin-bottom: 0.5em; }
                h3 { font-size: 1.1em; margin-top: 1.2em; margin-bottom: 0.4em; }
                p { margin-bottom: 1em; }
                a { color: #1976D2; }
                img { max-width: 100%; height: auto; }
                @media (prefers-color-scheme: dark) {
                    body { background: #121212; color: #e0e0e0; }
                    a { color: #64B5F6; }
                }
            </style>
        </head>
        <body>
            $html
        </body>
        </html>
    """.trimIndent()
}
