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
import android.graphics.Bitmap
import android.graphics.pdf.PdfRenderer
import android.net.Uri
import android.os.ParcelFileDescriptor
import android.webkit.WebView
import android.webkit.WebViewClient
import androidx.compose.foundation.Image
import androidx.compose.foundation.background
import androidx.compose.foundation.gestures.detectTransformGestures
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material.icons.filled.ChevronLeft
import androidx.compose.material.icons.filled.ChevronRight
import androidx.compose.material.icons.filled.ErrorOutline
import androidx.compose.material.icons.filled.OpenInBrowser
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.ZoomIn
import androidx.compose.material.icons.filled.ZoomOut
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.FilledTonalIconButton
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.TopAppBarDefaults
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableFloatStateOf
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.asImageBitmap
import androidx.compose.ui.graphics.graphicsLayer
import androidx.compose.ui.input.pointer.pointerInput
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.fulltext.FullTextViewModel.FullTextState
import com.bmlibrarian.factchecker.ui.fulltext.components.FullTextSourceBadge
import com.bmlibrarian.factchecker.util.Constants
import java.io.File

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
                    PdfViewer(
                        pdfPath = currentState.pdfPath,
                        onOpenExternal = {
                            // Open PDF with external viewer
                            try {
                                val file = File(currentState.pdfPath)
                                val uri = androidx.core.content.FileProvider.getUriForFile(
                                    context,
                                    "${context.packageName}.fileprovider",
                                    file
                                )
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/pdf")
                                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                                }
                                context.startActivity(intent)
                            } catch (e: Exception) {
                                // Fallback: try with file:// URI
                                val uri = Uri.parse("file://${currentState.pdfPath}")
                                val intent = Intent(Intent.ACTION_VIEW).apply {
                                    setDataAndType(uri, "application/pdf")
                                    flags = Intent.FLAG_GRANT_READ_URI_PERMISSION
                                }
                                context.startActivity(intent)
                            }
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
 * In-app PDF viewer using Android's PdfRenderer.
 *
 * Displays PDF pages in a scrollable list with zoom controls.
 * Falls back to external viewer button if rendering fails.
 *
 * @param pdfPath Path to the PDF file
 * @param onOpenExternal Callback to open PDF in external viewer
 */
@Composable
private fun PdfViewer(
    pdfPath: String,
    onOpenExternal: () -> Unit
) {
    var pdfRenderer by remember { mutableStateOf<PdfRenderer?>(null) }
    var pageCount by remember { mutableIntStateOf(0) }
    var pageBitmaps by remember { mutableStateOf<List<Bitmap>>(emptyList()) }
    var loadError by remember { mutableStateOf<String?>(null) }
    var scale by remember { mutableFloatStateOf(1f) }
    val listState = rememberLazyListState()

    // Load PDF
    DisposableEffect(pdfPath) {
        try {
            val file = File(pdfPath)
            if (file.exists()) {
                val pfd = ParcelFileDescriptor.open(file, ParcelFileDescriptor.MODE_READ_ONLY)
                val renderer = PdfRenderer(pfd)
                pdfRenderer = renderer
                pageCount = renderer.pageCount

                // Render all pages to bitmaps
                val bitmaps = mutableListOf<Bitmap>()
                for (i in 0 until renderer.pageCount) {
                    val page = renderer.openPage(i)
                    // Scale up for better quality
                    val bitmap = Bitmap.createBitmap(
                        page.width * Constants.PDF_RENDER_SCALE_FACTOR,
                        page.height * Constants.PDF_RENDER_SCALE_FACTOR,
                        Bitmap.Config.ARGB_8888
                    )
                    bitmap.eraseColor(android.graphics.Color.WHITE)
                    page.render(bitmap, null, null, PdfRenderer.Page.RENDER_MODE_FOR_DISPLAY)
                    page.close()
                    bitmaps.add(bitmap)
                }
                pageBitmaps = bitmaps
            } else {
                loadError = "PDF file not found"
            }
        } catch (e: Exception) {
            loadError = "Error loading PDF: ${e.message}"
        }

        onDispose {
            pdfRenderer?.close()
            pageBitmaps.forEach { it.recycle() }
        }
    }

    // Show error state or PDF content
    if (loadError != null) {
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
                    text = "PDF Preview Unavailable",
                    style = MaterialTheme.typography.titleLarge
                )
                Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))
                Text(
                    text = loadError ?: "Unknown error",
                    style = MaterialTheme.typography.bodyMedium,
                    textAlign = TextAlign.Center,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))
                Button(onClick = onOpenExternal) {
                    Icon(
                        imageVector = Icons.Default.OpenInBrowser,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.padding(Constants.UI_ELEMENT_SPACING_SMALL.dp))
                    Text("Open in External Viewer")
                }
            }
        }
    } else if (pageBitmaps.isEmpty()) {
        // Loading state
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
                    text = "Loading PDF...",
                    style = MaterialTheme.typography.bodyMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }
    } else {
        // PDF content
        Column(modifier = Modifier.fillMaxSize()) {
            // Zoom controls and page info
            Row(
                modifier = Modifier
                    .fillMaxWidth()
                    .background(MaterialTheme.colorScheme.surfaceVariant)
                    .padding(
                        horizontal = Constants.UI_CARD_PADDING_SMALL.dp,
                        vertical = Constants.PDF_CONTROLS_VERTICAL_PADDING.dp
                    ),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                // Page info
                Text(
                    text = "$pageCount page${if (pageCount != 1) "s" else ""}",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )

                // Zoom controls
                Row(
                    horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING_SMALL.dp),
                    verticalAlignment = Alignment.CenterVertically
                ) {
                    FilledTonalIconButton(
                        onClick = {
                            scale = (scale - Constants.PDF_ZOOM_STEP).coerceAtLeast(Constants.PDF_ZOOM_MIN)
                        },
                        modifier = Modifier.size(Constants.PDF_ZOOM_BUTTON_SIZE.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.ZoomOut,
                            contentDescription = "Zoom out",
                            modifier = Modifier.size(Constants.PDF_ZOOM_ICON_SIZE.dp)
                        )
                    }
                    Text(
                        text = "${(scale * 100).toInt()}%",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant
                    )
                    FilledTonalIconButton(
                        onClick = {
                            scale = (scale + Constants.PDF_ZOOM_STEP).coerceAtMost(Constants.PDF_ZOOM_MAX)
                        },
                        modifier = Modifier.size(Constants.PDF_ZOOM_BUTTON_SIZE.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.ZoomIn,
                            contentDescription = "Zoom in",
                            modifier = Modifier.size(Constants.PDF_ZOOM_ICON_SIZE.dp)
                        )
                    }
                }

                // Open external button
                OutlinedButton(
                    onClick = onOpenExternal
                ) {
                    Text("Open External", style = MaterialTheme.typography.labelSmall)
                }
            }

            // PDF pages
            LazyColumn(
                state = listState,
                modifier = Modifier
                    .fillMaxSize()
                    .background(MaterialTheme.colorScheme.surfaceContainerLow),
                horizontalAlignment = Alignment.CenterHorizontally,
                verticalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp)
            ) {
                items(pageBitmaps.size) { index ->
                    val bitmap = pageBitmaps[index]
                    Box(
                        modifier = Modifier
                            .fillMaxWidth()
                            .padding(horizontal = Constants.UI_ELEMENT_SPACING.dp)
                            .graphicsLayer(
                                scaleX = scale,
                                scaleY = scale
                            ),
                        contentAlignment = Alignment.Center
                    ) {
                        Image(
                            bitmap = bitmap.asImageBitmap(),
                            contentDescription = "Page ${index + 1}",
                            modifier = Modifier.fillMaxWidth()
                        )
                    }
                }
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
                    modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                )
                Spacer(modifier = Modifier.padding(Constants.UI_ELEMENT_SPACING_SMALL.dp))
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
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.padding(Constants.UI_ELEMENT_SPACING_SMALL.dp))
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
