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

package com.bmlibrarian.factchecker.ui.report

import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.ReportRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.ui.report.components.ReferenceInfo
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.PdfExporter
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import java.io.File
import java.util.Date
import javax.inject.Inject

/**
 * UI state for the Report screen.
 *
 * Contains all state needed to render the report view including the report
 * data, referenced documents, and UI interaction state.
 *
 * @property report The current report to display, or null if none available
 * @property documents List of documents referenced in the report
 * @property selectedDocument Document selected for detail view
 * @property showDocumentSheet Whether to show the document detail bottom sheet
 * @property isLoadingFullText Whether full text is being fetched for selected document
 * @property isExporting Whether a PDF export is in progress
 * @property exportError Error message if export failed, or null
 */
data class ReportUiState(
    val report: ReportEntity? = null,
    val documents: List<DocumentEntity> = emptyList(),
    val selectedDocument: DocumentEntity? = null,
    val showDocumentSheet: Boolean = false,
    val isLoadingFullText: Boolean = false,
    val isExporting: Boolean = false,
    val exportError: String? = null,
    val isLoading: Boolean = true,
    val canGetMoreEvidence: Boolean = false
)

/**
 * One-shot UI events emitted by the ViewModel.
 *
 * These events are consumed once by the UI layer to trigger side effects
 * like navigation, sharing, or opening external apps.
 */
sealed class ReportUiEvent {
    /**
     * Open a URL in the device browser.
     *
     * @property url The URL to open (e.g., PubMed article link)
     */
    data class OpenUrl(val url: String) : ReportUiEvent()

    /**
     * Share text content via Android share sheet.
     *
     * @property subject Subject line for the share
     * @property text Text content to share
     */
    data class ShareText(val subject: String, val text: String) : ReportUiEvent()

    /**
     * Share a file via Android share sheet.
     *
     * @property file The file to share
     * @property mimeType MIME type of the file
     */
    data class ShareFile(val file: File, val mimeType: String) : ReportUiEvent()

    /**
     * Show a snackbar message.
     *
     * @property message The message to display
     */
    data class ShowSnackbar(val message: String) : ReportUiEvent()

    /**
     * Navigate to full text viewer.
     *
     * @property documentId The document ID to view full text for
     */
    data class NavigateToFullText(val documentId: String) : ReportUiEvent()
}

/**
 * Paper size options for PDF export.
 */
enum class PaperSize {
    /** A4 paper (210 x 297 mm). */
    A4,

    /** US Letter paper (8.5 x 11 inches). */
    LETTER
}

/**
 * ViewModel for the Report screen.
 *
 * Manages the state for displaying evidence reports, handling reference clicks,
 * exporting to PDF, and sharing reports. Uses event-based architecture for
 * side effects to maintain clean separation from Android framework.
 *
 * @property sessionRepository Repository for session operations
 * @property reportRepository Repository for report operations
 * @property documentRepository Repository for document operations
 * @property fullTextService Service for fetching full text
 * @property settingsRepository Repository for app settings
 * @property pdfExporter Utility for PDF generation
 */
@HiltViewModel
class ReportViewModel @Inject constructor(
    private val sessionRepository: SessionRepository,
    private val reportRepository: ReportRepository,
    private val documentRepository: DocumentRepository,
    private val fullTextService: FullTextService,
    private val settingsRepository: SettingsRepository,
    private val pdfExporter: PdfExporter
) : ViewModel() {

    companion object {
        private const val TAG = "ReportViewModel"
    }

    private val _uiState = MutableStateFlow(ReportUiState())
    /** Observable UI state for the report screen. */
    val uiState: StateFlow<ReportUiState> = _uiState.asStateFlow()

    private val _events = Channel<ReportUiEvent>(Channel.BUFFERED)
    /** One-shot events for the UI to consume. */
    val events = _events.receiveAsFlow()

    /** Current session ID being displayed. */
    private var currentSessionId: String? = null

    /** Job for the current report loading operation, cancelled when a new load starts. */
    private var loadJob: kotlinx.coroutines.Job? = null

    /**
     * Load report for a specific session.
     *
     * Fetches the report and associated documents from the database.
     * Cancels any in-progress load operation before starting a new one.
     * Clears previous state immediately to avoid showing stale data.
     *
     * @param sessionId The session ID to load the report for
     */
    fun loadReport(sessionId: String) {
        // Cancel any previous load operation to prevent race conditions
        loadJob?.cancel()
        currentSessionId = sessionId

        // Clear previous state immediately to avoid showing stale data
        _uiState.update {
            it.copy(
                report = null,
                documents = emptyList(),
                isLoading = true,
                canGetMoreEvidence = false
            )
        }

        loadJob = viewModelScope.launch {
            try {
                // Load session to check if more evidence is available
                val session = sessionRepository.getSession(sessionId)
                val canGetMore = session?.canGetMoreEvidence ?: false

                // Load report
                val report = reportRepository.getReportBySession(sessionId)
                _uiState.update { it.copy(report = report, canGetMoreEvidence = canGetMore) }

                // Load documents for reference lookup (use first() to get single emission)
                val docs = documentRepository.getScoredDocumentsBySession(sessionId).first()
                _uiState.update { it.copy(documents = docs, isLoading = false) }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false) }
                _events.send(ReportUiEvent.ShowSnackbar("Failed to load report: ${e.message}"))
            }
        }
    }

    /**
     * Load the most recent report.
     *
     * Finds the latest completed session and loads its report.
     * Cancels any in-progress load operation before starting a new one.
     * Clears previous state immediately to avoid showing stale data.
     */
    fun loadLatestReport() {
        // Cancel any previous load operation to prevent race conditions
        loadJob?.cancel()

        // Clear previous state immediately to avoid showing stale data
        _uiState.update {
            it.copy(
                report = null,
                documents = emptyList(),
                isLoading = true,
                canGetMoreEvidence = false
            )
        }

        loadJob = viewModelScope.launch {
            try {
                val sessions = sessionRepository.getCompletedSessions().first()
                val latestSession = sessions.firstOrNull()

                if (latestSession != null) {
                    // Load the report directly instead of calling loadReport()
                    // to avoid creating a separate job
                    currentSessionId = latestSession.id
                    val canGetMore = latestSession.canGetMoreEvidence
                    val report = reportRepository.getReportBySession(latestSession.id)
                    _uiState.update { it.copy(report = report, canGetMoreEvidence = canGetMore) }

                    val docs = documentRepository.getScoredDocumentsBySession(latestSession.id).first()
                    _uiState.update { it.copy(documents = docs, isLoading = false) }
                } else {
                    _uiState.update { it.copy(report = null, isLoading = false) }
                }
            } catch (e: Exception) {
                _uiState.update { it.copy(isLoading = false) }
                _events.send(ReportUiEvent.ShowSnackbar("Failed to load report: ${e.message}"))
            }
        }
    }

    /**
     * Handle click on a document reference in the report.
     *
     * References use the iOS-style format [Author, Year](doc:pmid-12345678).
     * Lookup is performed by:
     * 1. Direct PMID lookup if documentId contains "pmid-"
     * 2. Fallback to author name and year matching
     *
     * @param referenceInfo Information about the clicked reference
     */
    fun onReferenceClick(referenceInfo: ReferenceInfo) {
        val docs = _uiState.value.documents
        val document = findDocumentByReference(docs, referenceInfo)

        if (document != null) {
            _uiState.update {
                it.copy(
                    selectedDocument = document,
                    showDocumentSheet = true
                )
            }
        }
    }

    /**
     * Find a document matching the reference info.
     *
     * Tries multiple lookup strategies:
     * 1. Direct PMID lookup from embedded document ID (e.g., "pmid-12345678")
     * 2. Author name and year matching as fallback
     *
     * @param documents List of documents to search
     * @param referenceInfo Reference information to match
     * @return Matching document or null
     */
    private fun findDocumentByReference(
        documents: List<DocumentEntity>,
        referenceInfo: ReferenceInfo
    ): DocumentEntity? {
        // Try direct PMID lookup first
        val docId = referenceInfo.documentId
        if (docId != null) {
            // Handle "pmid-12345678" format
            if (docId.startsWith("pmid-")) {
                val pmid = docId.removePrefix("pmid-")
                documents.find { it.pmid == pmid }?.let { return it }
            }
            // Try matching by document ID directly
            documents.find { it.id == docId }?.let { return it }
        }

        // Fallback to author/year matching
        val authorName = referenceInfo.authorName
        val year = referenceInfo.year

        if (authorName != null && year != null) {
            return documents.find { doc ->
                doc.publicationYear == year && doc.authors.any { author ->
                    val lastName = author.split(" ").firstOrNull()?.lowercase() ?: ""
                    lastName == authorName || author.lowercase().contains(authorName)
                }
            }
        }

        return null
    }

    /**
     * Dismiss the document detail bottom sheet.
     */
    fun dismissDocumentSheet() {
        _uiState.update {
            it.copy(
                selectedDocument = null,
                showDocumentSheet = false
            )
        }
    }

    /**
     * Open document in PubMed in the device browser.
     *
     * @param pmid The PubMed ID to open
     */
    fun openInPubMed(pmid: String) {
        viewModelScope.launch {
            val url = "${Constants.PUBMED_URL_PREFIX}$pmid/"
            _events.send(ReportUiEvent.OpenUrl(url))
        }
    }

    /**
     * Export report as PDF.
     *
     * Generates a PDF file and triggers sharing via the Android share sheet.
     *
     * @param paperSize The paper size for the PDF (default: A4)
     */
    fun exportPdf(paperSize: PaperSize = PaperSize.A4) {
        val report = _uiState.value.report ?: return

        viewModelScope.launch {
            _uiState.update { it.copy(isExporting = true, exportError = null) }

            try {
                val file = pdfExporter.exportReport(
                    report = report,
                    documents = _uiState.value.documents,
                    paperSize = paperSize
                )

                _uiState.update { it.copy(isExporting = false) }
                _events.send(ReportUiEvent.ShareFile(file, "application/pdf"))
            } catch (e: Exception) {
                val errorMessage = e.message ?: "Failed to export PDF"
                _uiState.update {
                    it.copy(
                        isExporting = false,
                        exportError = errorMessage
                    )
                }
                _events.send(ReportUiEvent.ShowSnackbar(errorMessage))
            }
        }
    }

    /**
     * Share the report as plain text.
     *
     * Creates a text representation of the report and triggers sharing
     * via the Android share sheet.
     */
    fun shareReport() {
        val report = _uiState.value.report ?: return

        viewModelScope.launch {
            val shareText = buildString {
                appendLine("Medical Fact Check Report")
                appendLine("========================")
                appendLine()
                appendLine("Verdict: ${report.verdict.displayName}")
                appendLine()
                appendLine(report.summary)
                appendLine()
                appendLine("---")
                appendLine()
                appendLine(report.fullReportMarkdown)
                report.footnotes?.let {
                    appendLine()
                    appendLine("---")
                    appendLine()
                    appendLine("References:")
                    appendLine(it)
                }
            }

            _events.send(
                ReportUiEvent.ShareText(
                    subject = "Medical Fact Check Report",
                    text = shareText
                )
            )
        }
    }

    /**
     * Clear export error state.
     */
    fun clearExportError() {
        _uiState.update { it.copy(exportError = null) }
    }

    /**
     * Fetch full text for the selected document.
     *
     * Attempts to retrieve full text from Europe PMC, Unpaywall, or DOI.
     * Updates the document in the database and UI state with the result.
     */
    fun fetchFullText() {
        val document = _uiState.value.selectedDocument ?: return

        viewModelScope.launch {
            _uiState.update { it.copy(isLoadingFullText = true) }

            try {
                val settings = settingsRepository.settings.value
                val email = settings.unpaywallEmail.ifEmpty { Constants.UNPAYWALL_DEFAULT_EMAIL }

                val result = fullTextService.fetchFullText(
                    pmcId = document.pmcId,
                    doi = document.doi,
                    pmid = document.pmid,
                    email = email
                )

                result.fold(
                    onSuccess = { fullTextResult ->
                        val updatedDoc = when (fullTextResult) {
                            is FullTextService.FullTextResult.EuropePmcXml -> {
                                document.copy(
                                    fullTextMarkdown = fullTextResult.markdown,
                                    fullTextHTML = fullTextResult.html,
                                    fullTextSource = Constants.FULLTEXT_SOURCE_EUROPE_PMC,
                                    fullTextFetchedAt = Date()
                                )
                            }
                            is FullTextService.FullTextResult.UnpaywallPdf -> {
                                val localPath = fullTextService.downloadPdf(
                                    fullTextResult.pdfUrl,
                                    document.id
                                )
                                document.copy(
                                    pdfPath = localPath,
                                    fullTextSource = Constants.FULLTEXT_SOURCE_UNPAYWALL,
                                    fullTextFetchedAt = Date()
                                )
                            }
                            is FullTextService.FullTextResult.DoiUrl -> {
                                document.copy(
                                    fullTextSource = Constants.FULLTEXT_SOURCE_DOI,
                                    fullTextFetchedAt = Date()
                                )
                            }
                            is FullTextService.FullTextResult.Unavailable -> {
                                document.copy(
                                    fullTextUnavailable = true,
                                    fullTextFetchedAt = Date()
                                )
                            }
                        }

                        documentRepository.updateDocument(updatedDoc)

                        // Update UI state with the updated document
                        _uiState.update { state ->
                            state.copy(
                                selectedDocument = updatedDoc,
                                documents = state.documents.map {
                                    if (it.id == updatedDoc.id) updatedDoc else it
                                },
                                isLoadingFullText = false
                            )
                        }

                        val success = fullTextResult !is FullTextService.FullTextResult.Unavailable
                        if (!success) {
                            _events.send(ReportUiEvent.ShowSnackbar("Full text not available"))
                        }
                        Log.d(TAG, "Full text fetch ${if (success) "succeeded" else "unavailable"} for ${document.id}")
                    },
                    onFailure = { error ->
                        Log.e(TAG, "Full text fetch failed: ${error.message}")
                        val updatedDoc = document.copy(
                            fullTextUnavailable = true,
                            fullTextFetchedAt = Date()
                        )
                        documentRepository.updateDocument(updatedDoc)

                        _uiState.update { state ->
                            state.copy(
                                selectedDocument = updatedDoc,
                                documents = state.documents.map {
                                    if (it.id == updatedDoc.id) updatedDoc else it
                                },
                                isLoadingFullText = false
                            )
                        }
                        _events.send(ReportUiEvent.ShowSnackbar("Failed to fetch full text"))
                    }
                )
            } catch (e: Exception) {
                Log.e(TAG, "Full text fetch error: ${e.message}")
                _uiState.update { it.copy(isLoadingFullText = false) }
                _events.send(ReportUiEvent.ShowSnackbar("Error fetching full text"))
            }
        }
    }

    /**
     * Navigate to full text viewer for the selected document.
     *
     * Emits an event to trigger navigation.
     */
    fun viewFullText() {
        val document = _uiState.value.selectedDocument ?: return
        viewModelScope.launch {
            _events.send(ReportUiEvent.NavigateToFullText(document.id))
        }
    }

    /**
     * Open DOI in browser.
     *
     * @param doi The DOI to open
     */
    fun openDoi(doi: String) {
        viewModelScope.launch {
            val url = "${Constants.DOI_URL_PREFIX}$doi"
            _events.send(ReportUiEvent.OpenUrl(url))
        }
    }
}
