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

import android.util.Log
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.launch
import java.util.Date
import javax.inject.Inject

/**
 * ViewModel for the Full-Text Viewer screen.
 *
 * Manages full-text content loading, caching, and display state.
 */
@HiltViewModel
class FullTextViewModel @Inject constructor(
    savedStateHandle: SavedStateHandle,
    private val fullTextService: FullTextService,
    private val documentDao: DocumentDao,
    private val settingsRepository: SettingsRepository
) : ViewModel() {

    companion object {
        private const val TAG = "FullTextViewModel"
        const val DOCUMENT_ID_KEY = "documentId"
    }

    /**
     * State for full-text content display.
     */
    sealed class FullTextState {
        /** Initial state, no content loaded. */
        data object Idle : FullTextState()

        /** Loading full-text content. */
        data object Loading : FullTextState()

        /**
         * HTML content available (from JATS XML).
         *
         * @param html HTML content string.
         * @param title Document title.
         * @param source Source of the content.
         */
        data class HtmlContent(
            val html: String,
            val title: String,
            val source: String
        ) : FullTextState()

        /**
         * Markdown content available.
         *
         * @param markdown Markdown content string.
         * @param title Document title.
         * @param source Source of the content.
         */
        data class MarkdownContent(
            val markdown: String,
            val title: String,
            val source: String
        ) : FullTextState()

        /**
         * PDF content available.
         *
         * @param pdfPath Local path to PDF file.
         * @param title Document title.
         * @param source Source of the content.
         */
        data class PdfContent(
            val pdfPath: String,
            val title: String,
            val source: String
        ) : FullTextState()

        /**
         * Web URL for external viewing.
         *
         * @param url URL to open.
         * @param title Document title.
         */
        data class WebUrl(
            val url: String,
            val title: String
        ) : FullTextState()

        /**
         * Error loading full text.
         *
         * @param message Error message.
         * @param canRetry Whether retry is possible.
         */
        data class Error(
            val message: String,
            val canRetry: Boolean = true
        ) : FullTextState()

        /** Full text is unavailable from all sources. */
        data class Unavailable(val reason: String) : FullTextState()
    }

    private val _state = MutableStateFlow<FullTextState>(FullTextState.Idle)
    val state: StateFlow<FullTextState> = _state.asStateFlow()

    private val _document = MutableStateFlow<DocumentEntity?>(null)
    val document: StateFlow<DocumentEntity?> = _document.asStateFlow()

    private var currentDocumentId: String? = null

    init {
        // Get document ID from navigation arguments
        savedStateHandle.get<String>(DOCUMENT_ID_KEY)?.let { documentId ->
            loadDocument(documentId)
        }
    }

    /**
     * Load a document and fetch its full text.
     *
     * @param documentId ID of the document to load.
     */
    fun loadDocument(documentId: String) {
        if (currentDocumentId == documentId && _state.value !is FullTextState.Error) {
            return // Already loaded
        }

        currentDocumentId = documentId
        viewModelScope.launch {
            _state.value = FullTextState.Loading

            try {
                // Fetch document from database
                val doc = documentDao.getById(documentId)
                if (doc == null) {
                    _state.value = FullTextState.Error("Document not found")
                    return@launch
                }

                _document.value = doc

                // Check if we already have cached content
                if (!doc.fullTextMarkdown.isNullOrEmpty()) {
                    Log.d(TAG, "Using cached full-text markdown for ${doc.id}")
                    _state.value = FullTextState.MarkdownContent(
                        markdown = doc.fullTextMarkdown,
                        title = doc.title,
                        source = doc.fullTextSourceDisplay ?: Constants.FULLTEXT_SOURCE_CACHED
                    )
                    return@launch
                }

                // Check for cached PDF
                val cachedPdf = fullTextService.getCachedPdfPath(documentId)
                if (cachedPdf != null) {
                    Log.d(TAG, "Using cached PDF for ${doc.id}")
                    _state.value = FullTextState.PdfContent(
                        pdfPath = cachedPdf,
                        title = doc.title,
                        source = doc.fullTextSourceDisplay ?: Constants.FULLTEXT_SOURCE_CACHED
                    )
                    return@launch
                }

                // Check if already marked as unavailable
                if (doc.fullTextUnavailable) {
                    Log.d(TAG, "Full text previously marked unavailable for ${doc.id}")
                    _state.value = FullTextState.Unavailable("Full text not available for this article")
                    return@launch
                }

                // Fetch new full text
                fetchFullText(doc)

            } catch (e: Exception) {
                Log.e(TAG, "Error loading document: ${e.message}")
                _state.value = FullTextState.Error(
                    message = "Failed to load document: ${e.message}",
                    canRetry = true
                )
            }
        }
    }

    /**
     * Fetch full text from remote sources.
     *
     * @param doc Document to fetch full text for.
     */
    private suspend fun fetchFullText(doc: DocumentEntity) {
        try {
            val settings = settingsRepository.settingsFlow.first()

            val result = fullTextService.fetchFullText(
                pmcId = doc.pmcId,
                doi = doc.doi,
                pmid = doc.pmid,
                email = settings.unpaywallEmail.ifEmpty { Constants.UNPAYWALL_DEFAULT_EMAIL }
            )

            result.fold(
                onSuccess = { fullTextResult ->
                    handleFullTextResult(doc, fullTextResult)
                },
                onFailure = { error ->
                    Log.e(TAG, "Full-text fetch failed: ${error.message}")
                    _state.value = FullTextState.Error(
                        message = "Failed to fetch full text: ${error.message}",
                        canRetry = true
                    )
                }
            )
        } catch (e: Exception) {
            Log.e(TAG, "Full-text fetch error: ${e.message}")
            _state.value = FullTextState.Error(
                message = "Error fetching full text: ${e.message}",
                canRetry = true
            )
        }
    }

    /**
     * Handle the result of a full-text fetch.
     */
    private suspend fun handleFullTextResult(doc: DocumentEntity, result: FullTextResult) {
        when (result) {
            is FullTextResult.EuropePmcXml -> {
                Log.d(TAG, "Got Europe PMC XML content for ${doc.id}")

                // Cache the markdown content
                documentDao.update(
                    doc.copy(
                        fullTextMarkdown = result.markdown,
                        fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
                        fullTextFetchedAt = Date()
                    )
                )

                // Update local document state
                _document.value = doc.copy(
                    fullTextMarkdown = result.markdown,
                    fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC
                )

                // Display as HTML (better rendering for tables/figures)
                _state.value = FullTextState.HtmlContent(
                    html = wrapHtmlContent(result.html),
                    title = doc.title,
                    source = "Europe PMC"
                )
            }

            is FullTextResult.UnpaywallPdf -> {
                Log.d(TAG, "Got Unpaywall PDF URL for ${doc.id}: ${result.pdfUrl}")

                // Download the PDF
                val localPath = fullTextService.downloadPdf(result.pdfUrl, doc.id)

                if (localPath != null) {
                    // Update database with PDF path
                    documentDao.update(
                        doc.copy(
                            pdfPath = localPath,
                            fullTextSource = Constants.FULLTEXT_SOURCE_UNPAYWALL,
                            fullTextFetchedAt = Date()
                        )
                    )

                    _state.value = FullTextState.PdfContent(
                        pdfPath = localPath,
                        title = doc.title,
                        source = "Unpaywall"
                    )
                } else {
                    // Couldn't download, provide URL for external viewing
                    _state.value = FullTextState.WebUrl(
                        url = result.pdfUrl,
                        title = doc.title
                    )
                }
            }

            is FullTextResult.DoiUrl -> {
                Log.d(TAG, "Falling back to DOI URL for ${doc.id}: ${result.url}")

                // Update source but no content cached
                documentDao.update(
                    doc.copy(
                        fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
                        fullTextFetchedAt = Date()
                    )
                )

                _state.value = FullTextState.WebUrl(
                    url = result.url,
                    title = doc.title
                )
            }

            is FullTextResult.Unavailable -> {
                Log.d(TAG, "Full text unavailable for ${doc.id}: ${result.reason}")

                // Mark as unavailable to avoid future fetch attempts
                documentDao.update(
                    doc.copy(
                        fullTextUnavailable = true,
                        fullTextFetchedAt = Date()
                    )
                )

                _state.value = FullTextState.Unavailable(result.reason)
            }
        }
    }

    /**
     * Retry loading full text after an error.
     */
    fun retry() {
        currentDocumentId?.let { loadDocument(it) }
    }

    /**
     * Clear cached full text and reload.
     */
    fun refresh() {
        viewModelScope.launch {
            _document.value?.let { doc ->
                // Clear cached data
                documentDao.update(
                    doc.copy(
                        fullTextMarkdown = null,
                        fullTextSource = null,
                        pdfPath = null,
                        fullTextUnavailable = false,
                        fullTextFetchedAt = null
                    )
                )

                // Reload
                _state.value = FullTextState.Loading
                loadDocument(doc.id)
            }
        }
    }

    /**
     * Wrap HTML content with basic styling for WebView display.
     */
    private fun wrapHtmlContent(html: String): String {
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
                    table {
                        width: 100%;
                        border-collapse: collapse;
                        margin: 1em 0;
                        font-size: 14px;
                    }
                    th, td {
                        border: 1px solid #ddd;
                        padding: 8px;
                        text-align: left;
                    }
                    th { background-color: #f5f5f5; font-weight: bold; }
                    tr:nth-child(even) { background-color: #fafafa; }
                    figure {
                        margin: 1em 0;
                        text-align: center;
                    }
                    figure img {
                        max-width: 100%;
                        height: auto;
                    }
                    figcaption {
                        font-size: 14px;
                        color: #666;
                        margin-top: 8px;
                    }
                    .authors { color: #666; font-style: italic; }
                    .journal-info { color: #666; }
                    .identifiers { font-size: 14px; color: #888; }
                    .table-caption { font-size: 14px; color: #666; margin-bottom: 8px; }
                    .references { font-size: 14px; }
                    .references li { margin-bottom: 0.5em; }
                    @media (prefers-color-scheme: dark) {
                        body { background: #121212; color: #e0e0e0; }
                        a { color: #64B5F6; }
                        th { background-color: #333; }
                        th, td { border-color: #444; }
                        tr:nth-child(even) { background-color: #1e1e1e; }
                    }
                </style>
            </head>
            <body>
                $html
            </body>
            </html>
        """.trimIndent()
    }
}
