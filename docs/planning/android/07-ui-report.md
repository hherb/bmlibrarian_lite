# Phase 7: UI - Report View

## Overview

This phase implements the Report screen where users view the generated evidence report. The report includes markdown rendering with clickable references, verdict display, and PDF export functionality.

**Estimated Duration**: 1 week
**Prerequisites**: Phases 1-6 completed
**Deliverable**: Complete report viewing and export functionality

## Report View Architecture

```
┌─────────────────────────────────────────────────────┐
│                   ReportScreen                       │
│  ┌───────────────────────────────────────────────┐  │
│  │              VerdictHeader                     │  │
│  │  [Verdict Badge] + Summary                     │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │              MarkdownReport                    │  │
│  │  - Rendered markdown                           │  │
│  │  - Clickable [1], [2] references               │  │
│  │  - Scrollable content                          │  │
│  └───────────────────────────────────────────────┘  │
│  ┌───────────────────────────────────────────────┐  │
│  │              ReportActions                     │  │
│  │  [Export PDF] [Share]                          │  │
│  └───────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────┘
```

## Tasks

### 7.1 Create Report ViewModel

```kotlin
// ui/report/ReportViewModel.kt
package com.bmlibrarian.factchecker.ui.report

import android.content.Context
import android.content.Intent
import android.net.Uri
import androidx.core.content.FileProvider
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.util.PdfExporter
import dagger.hilt.android.lifecycle.HiltViewModel
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import java.io.File
import javax.inject.Inject

/**
 * UI state for the Report screen.
 */
data class ReportUiState(
    val report: ReportEntity? = null,
    val documents: List<DocumentEntity> = emptyList(),
    val selectedDocument: DocumentEntity? = null,
    val showDocumentSheet: Boolean = false,
    val isExporting: Boolean = false,
    val exportError: String? = null
)

/**
 * ViewModel for the Report screen.
 */
@HiltViewModel
class ReportViewModel @Inject constructor(
    @ApplicationContext private val context: Context,
    private val sessionRepository: SessionRepository,
    private val documentRepository: DocumentRepository,
    private val reportDao: ReportDao,
    private val pdfExporter: PdfExporter
) : ViewModel() {

    private val _uiState = MutableStateFlow(ReportUiState())
    val uiState: StateFlow<ReportUiState> = _uiState.asStateFlow()

    // Current session ID to display
    private var currentSessionId: String? = null

    /**
     * Load report for a session.
     */
    fun loadReport(sessionId: String) {
        currentSessionId = sessionId
        viewModelScope.launch {
            // Load report
            val report = reportDao.getBySessionId(sessionId)
            _uiState.update { it.copy(report = report) }

            // Load documents for reference lookup
            documentRepository.getScoredDocumentsBySession(sessionId)
                .collect { docs ->
                    _uiState.update { it.copy(documents = docs) }
                }
        }
    }

    /**
     * Load the most recent report.
     */
    fun loadLatestReport() {
        viewModelScope.launch {
            sessionRepository.getCompletedSessions()
                .first()
                .firstOrNull()
                ?.let { session ->
                    loadReport(session.id)
                }
        }
    }

    /**
     * Handle click on a document reference in the report.
     * References are formatted as [1], [2], etc.
     */
    fun onReferenceClick(referenceNumber: Int) {
        val docs = _uiState.value.documents
        if (referenceNumber in 1..docs.size) {
            val document = docs[referenceNumber - 1]
            _uiState.update {
                it.copy(
                    selectedDocument = document,
                    showDocumentSheet = true
                )
            }
        }
    }

    /**
     * Dismiss the document detail sheet.
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
     * Open document in PubMed (external browser).
     */
    fun openInPubMed(pmid: String) {
        val url = "https://pubmed.ncbi.nlm.nih.gov/$pmid/"
        val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
        intent.flags = Intent.FLAG_ACTIVITY_NEW_TASK
        context.startActivity(intent)
    }

    /**
     * Export report as PDF.
     */
    fun exportPdf(paperSize: PdfExporter.PaperSize = PdfExporter.PaperSize.A4) {
        val report = _uiState.value.report ?: return

        viewModelScope.launch {
            _uiState.update { it.copy(isExporting = true, exportError = null) }

            try {
                val file = pdfExporter.exportReport(report, _uiState.value.documents, paperSize)

                // Share the file
                shareFile(file)

                _uiState.update { it.copy(isExporting = false) }
            } catch (e: Exception) {
                _uiState.update {
                    it.copy(
                        isExporting = false,
                        exportError = e.message ?: "Failed to export PDF"
                    )
                }
            }
        }
    }

    /**
     * Share the report as text.
     */
    fun shareReport() {
        val report = _uiState.value.report ?: return

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
        }

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "text/plain"
            putExtra(Intent.EXTRA_SUBJECT, "Medical Fact Check Report")
            putExtra(Intent.EXTRA_TEXT, shareText)
            flags = Intent.FLAG_ACTIVITY_NEW_TASK
        }

        context.startActivity(Intent.createChooser(intent, "Share Report"))
    }

    /**
     * Share a file using FileProvider.
     */
    private fun shareFile(file: File) {
        val uri = FileProvider.getUriForFile(
            context,
            "${context.packageName}.fileprovider",
            file
        )

        val intent = Intent(Intent.ACTION_SEND).apply {
            type = "application/pdf"
            putExtra(Intent.EXTRA_STREAM, uri)
            addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        }

        context.startActivity(Intent.createChooser(intent, "Share PDF"))
    }

    /**
     * Clear export error.
     */
    fun clearExportError() {
        _uiState.update { it.copy(exportError = null) }
    }

    init {
        // Load latest report on init
        loadLatestReport()
    }
}
```

### 7.2 Create PDF Exporter Utility

```kotlin
// util/PdfExporter.kt
package com.bmlibrarian.factchecker.util

import android.content.Context
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import dagger.hilt.android.qualifiers.ApplicationContext
import java.io.File
import java.text.SimpleDateFormat
import java.util.*
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Utility for exporting reports as PDF.
 *
 * Note: For a production app, you would use a PDF library like iTextG.
 * This implementation creates a simple text file as a placeholder.
 */
@Singleton
class PdfExporter @Inject constructor(
    @ApplicationContext private val context: Context
) {

    enum class PaperSize {
        A4, LETTER
    }

    /**
     * Export a report to PDF.
     *
     * @param report The report to export
     * @param documents Referenced documents
     * @param paperSize Paper size for the PDF
     * @return The exported PDF file
     */
    suspend fun exportReport(
        report: ReportEntity,
        documents: List<DocumentEntity>,
        paperSize: PaperSize
    ): File {
        val dateFormat = SimpleDateFormat("yyyy-MM-dd_HHmmss", Locale.US)
        val timestamp = dateFormat.format(Date())
        val fileName = "factcheck_report_$timestamp.pdf"

        val outputDir = File(context.cacheDir, "exports")
        outputDir.mkdirs()
        val outputFile = File(outputDir, fileName)

        // For now, create a text representation
        // In production, use iTextG or similar for proper PDF
        val content = buildReportContent(report, documents)

        // Placeholder: Write as text (would be PDF in production)
        outputFile.writeText(content)

        return outputFile
    }

    private fun buildReportContent(
        report: ReportEntity,
        documents: List<DocumentEntity>
    ): String {
        val dateFormat = SimpleDateFormat("MMMM d, yyyy", Locale.US)

        return buildString {
            appendLine("MEDICAL FACT CHECK REPORT")
            appendLine("Generated: ${dateFormat.format(report.createdAt)}")
            appendLine("=" .repeat(50))
            appendLine()

            // Verdict
            appendLine("VERDICT: ${report.verdict.displayName.uppercase()}")
            appendLine()

            // Summary
            appendLine("SUMMARY")
            appendLine("-".repeat(30))
            appendLine(report.summary)
            appendLine()

            // Full report
            appendLine("DETAILED ANALYSIS")
            appendLine("-".repeat(30))
            appendLine(report.fullReportMarkdown)
            appendLine()

            // Statistics
            appendLine("STATISTICS")
            appendLine("-".repeat(30))
            appendLine("Documents reviewed: ${report.totalDocumentsReviewed}")
            appendLine("Relevant documents: ${report.relevantDocumentsCount}")
            appendLine("Citations extracted: ${report.citationsCount}")
            appendLine("Model used: ${report.modelUsed}")
            appendLine()

            // References
            if (documents.isNotEmpty()) {
                appendLine("REFERENCES")
                appendLine("-".repeat(30))
                documents.forEachIndexed { index, doc ->
                    appendLine("[${index + 1}] ${doc.citationString}")
                    doc.pmid?.let { appendLine("    PMID: $it") }
                    appendLine()
                }
            }

            // Footnotes
            report.footnotes?.let {
                appendLine()
                appendLine("FOOTNOTES")
                appendLine("-".repeat(30))
                appendLine(it)
            }

            // Disclaimer
            appendLine()
            appendLine("=" .repeat(50))
            appendLine("DISCLAIMER: This report is generated by AI and should")
            appendLine("not be used as a substitute for professional medical advice.")
        }
    }
}
```

### 7.3 Create Report Screen

```kotlin
// ui/report/ReportScreen.kt
package com.bmlibrarian.factchecker.ui.report

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.report.components.DocumentDetailSheet
import com.bmlibrarian.factchecker.ui.report.components.MarkdownReport
import com.bmlibrarian.factchecker.ui.report.components.ReportStatistics
import com.bmlibrarian.factchecker.ui.report.components.VerdictHeader
import com.bmlibrarian.factchecker.util.PdfExporter

/**
 * Screen for viewing the evidence report.
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportScreen(
    viewModel: ReportViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val scrollState = rememberScrollState()

    // Paper size selection dialog
    var showPaperSizeDialog by remember { mutableStateOf(false) }

    // Document detail bottom sheet
    val sheetState = rememberModalBottomSheetState()

    if (uiState.report == null) {
        NoReportPlaceholder()
        return
    }

    val report = uiState.report!!

    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(16.dp)
    ) {
        // Verdict header
        VerdictHeader(
            verdict = report.verdict,
            summary = report.summary
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Report content (scrollable)
        Column(
            modifier = Modifier
                .weight(1f)
                .verticalScroll(scrollState)
        ) {
            // Markdown report with clickable references
            MarkdownReport(
                markdown = report.fullReportMarkdown,
                onReferenceClick = viewModel::onReferenceClick
            )

            Spacer(modifier = Modifier.height(16.dp))

            // Statistics
            ReportStatistics(
                totalDocuments = report.totalDocumentsReviewed,
                relevantDocuments = report.relevantDocumentsCount,
                citations = report.citationsCount,
                model = report.modelUsed,
                generatedAt = report.createdAt
            )
        }

        Spacer(modifier = Modifier.height(16.dp))

        // Action buttons
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            OutlinedButton(
                onClick = { showPaperSizeDialog = true },
                enabled = !uiState.isExporting,
                modifier = Modifier.weight(1f)
            ) {
                if (uiState.isExporting) {
                    CircularProgressIndicator(
                        modifier = Modifier.size(18.dp),
                        strokeWidth = 2.dp
                    )
                } else {
                    Icon(
                        imageVector = Icons.Default.PictureAsPdf,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                }
                Spacer(modifier = Modifier.width(8.dp))
                Text("Export PDF")
            }

            Button(
                onClick = viewModel::shareReport,
                modifier = Modifier.weight(1f)
            ) {
                Icon(
                    imageVector = Icons.Default.Share,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text("Share")
            }
        }
    }

    // Paper size selection dialog
    if (showPaperSizeDialog) {
        AlertDialog(
            onDismissRequest = { showPaperSizeDialog = false },
            title = { Text("Select Paper Size") },
            text = {
                Column {
                    PdfExporter.PaperSize.values().forEach { size ->
                        TextButton(
                            onClick = {
                                showPaperSizeDialog = false
                                viewModel.exportPdf(size)
                            },
                            modifier = Modifier.fillMaxWidth()
                        ) {
                            Text(size.name)
                        }
                    }
                }
            },
            confirmButton = {},
            dismissButton = {
                TextButton(onClick = { showPaperSizeDialog = false }) {
                    Text("Cancel")
                }
            }
        )
    }

    // Document detail bottom sheet
    if (uiState.showDocumentSheet && uiState.selectedDocument != null) {
        ModalBottomSheet(
            onDismissRequest = viewModel::dismissDocumentSheet,
            sheetState = sheetState
        ) {
            DocumentDetailSheet(
                document = uiState.selectedDocument!!,
                onOpenInPubMed = { pmid ->
                    viewModel.openInPubMed(pmid)
                },
                onDismiss = viewModel::dismissDocumentSheet
            )
        }
    }

    // Export error snackbar
    uiState.exportError?.let { error ->
        LaunchedEffect(error) {
            // Show snackbar would go here
            viewModel.clearExportError()
        }
    }
}

@Composable
private fun NoReportPlaceholder() {
    Box(
        contentAlignment = Alignment.Center,
        modifier = Modifier
            .fillMaxSize()
            .padding(32.dp)
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = "No Report Available",
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = "Complete a fact-check to see the evidence report here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
```

### 7.4 Create Report Components

#### VerdictHeader

```kotlin
// ui/report/components/VerdictHeader.kt
package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.domain.model.Verdict

/**
 * Header showing the verdict with color-coded badge.
 */
@Composable
fun VerdictHeader(
    verdict: Verdict,
    summary: String,
    modifier: Modifier = Modifier
) {
    Card(
        colors = CardDefaults.cardColors(
            containerColor = verdict.color.copy(alpha = 0.1f)
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = "Verdict:",
                    style = MaterialTheme.typography.labelLarge,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.width(8.dp))
                VerdictBadge(verdict = verdict)
            }

            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = summary,
                style = MaterialTheme.typography.bodyLarge
            )
        }
    }
}

@Composable
fun VerdictBadge(
    verdict: Verdict,
    modifier: Modifier = Modifier
) {
    Surface(
        color = verdict.color,
        shape = MaterialTheme.shapes.small,
        modifier = modifier
    ) {
        Text(
            text = verdict.displayName,
            style = MaterialTheme.typography.labelLarge,
            color = MaterialTheme.colorScheme.onPrimary,
            modifier = Modifier.padding(horizontal = 12.dp, vertical = 6.dp)
        )
    }
}
```

#### MarkdownReport

```kotlin
// ui/report/components/MarkdownReport.kt
package com.bmlibrarian.factchecker.ui.report.components

import android.widget.TextView
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.material3.MaterialTheme
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.toArgb
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.viewinterop.AndroidView
import io.noties.markwon.Markwon
import io.noties.markwon.ext.tables.TablePlugin

/**
 * Renders markdown content with clickable reference links.
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

    // Process markdown to make references clickable
    val processedMarkdown = remember(markdown) {
        processReferences(markdown)
    }

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
                textSize = 16f
                // Set up click listener for reference spans
                // This would require a custom Markwon span handler in production
            }
        },
        update = { textView ->
            markwon.setMarkdown(textView, processedMarkdown)
        },
        modifier = modifier.fillMaxWidth()
    )
}

/**
 * Process markdown to add reference markers.
 * Converts [1], [2], etc. to clickable spans.
 */
private fun processReferences(markdown: String): String {
    // In production, this would create proper clickable spans
    // For now, just return the markdown as-is
    return markdown
}
```

#### ReportStatistics

```kotlin
// ui/report/components/ReportStatistics.kt
package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import java.text.SimpleDateFormat
import java.util.*

/**
 * Statistics section showing report metadata.
 */
@Composable
fun ReportStatistics(
    totalDocuments: Int,
    relevantDocuments: Int,
    citations: Int,
    model: String,
    generatedAt: Date,
    modifier: Modifier = Modifier
) {
    val dateFormat = remember { SimpleDateFormat("MMM d, yyyy 'at' h:mm a", Locale.getDefault()) }

    Card(
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        ),
        modifier = modifier.fillMaxWidth()
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Text(
                text = "Report Statistics",
                style = MaterialTheme.typography.titleSmall
            )

            Spacer(modifier = Modifier.height(12.dp))

            Row(
                horizontalArrangement = Arrangement.SpaceBetween,
                modifier = Modifier.fillMaxWidth()
            ) {
                StatItem(label = "Documents Reviewed", value = totalDocuments.toString())
                StatItem(label = "Relevant", value = relevantDocuments.toString())
                StatItem(label = "Citations", value = citations.toString())
            }

            Spacer(modifier = Modifier.height(12.dp))

            HorizontalDivider()

            Spacer(modifier = Modifier.height(12.dp))

            Text(
                text = "Model: $model",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
            Text(
                text = "Generated: ${dateFormat.format(generatedAt)}",
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}

@Composable
private fun StatItem(
    label: String,
    value: String
) {
    Column {
        Text(
            text = value,
            style = MaterialTheme.typography.headlineMedium,
            color = MaterialTheme.colorScheme.primary
        )
        Text(
            text = label,
            style = MaterialTheme.typography.labelSmall,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
    }
}
```

#### DocumentDetailSheet

```kotlin
// ui/report/components/DocumentDetailSheet.kt
package com.bmlibrarian.factchecker.ui.report.components

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.OpenInNew
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity

/**
 * Bottom sheet showing document details.
 */
@Composable
fun DocumentDetailSheet(
    document: DocumentEntity,
    onOpenInPubMed: (String) -> Unit,
    onDismiss: () -> Unit,
    modifier: Modifier = Modifier
) {
    Column(
        modifier = modifier
            .fillMaxWidth()
            .padding(16.dp)
            .verticalScroll(rememberScrollState())
    ) {
        // Title
        Text(
            text = document.title,
            style = MaterialTheme.typography.titleMedium
        )

        Spacer(modifier = Modifier.height(8.dp))

        // Authors
        Text(
            text = document.formattedAuthors,
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Journal and year
        Row {
            document.journal?.let {
                Text(
                    text = it,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
            document.publicationYear?.let {
                Text(
                    text = " ($it)",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        Spacer(modifier = Modifier.height(12.dp))

        // Identifiers
        Row(
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            document.pmid?.let {
                Text(
                    text = "PMID: $it",
                    style = MaterialTheme.typography.labelMedium
                )
            }
            document.doi?.let {
                Text(
                    text = "DOI: $it",
                    style = MaterialTheme.typography.labelMedium
                )
            }
        }

        // Relevance score
        document.relevanceScore?.let { score ->
            Spacer(modifier = Modifier.height(12.dp))
            Text(
                text = "Relevance Score: $score/5",
                style = MaterialTheme.typography.labelLarge
            )
            document.scoreRationale?.let { rationale ->
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = rationale,
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }
        }

        // Abstract
        document.abstractText?.let { abstract ->
            Spacer(modifier = Modifier.height(16.dp))
            Text(
                text = "Abstract",
                style = MaterialTheme.typography.titleSmall
            )
            Spacer(modifier = Modifier.height(8.dp))
            Text(
                text = abstract,
                style = MaterialTheme.typography.bodyMedium
            )
        }

        Spacer(modifier = Modifier.height(24.dp))

        // Actions
        Row(
            horizontalArrangement = Arrangement.spacedBy(12.dp),
            modifier = Modifier.fillMaxWidth()
        ) {
            OutlinedButton(
                onClick = onDismiss,
                modifier = Modifier.weight(1f)
            ) {
                Text("Close")
            }

            document.pmid?.let { pmid ->
                Button(
                    onClick = { onOpenInPubMed(pmid) },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        imageVector = Icons.Default.OpenInNew,
                        contentDescription = null,
                        modifier = Modifier.size(18.dp)
                    )
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("PubMed")
                }
            }
        }

        Spacer(modifier = Modifier.height(32.dp)) // Bottom padding for navigation bar
    }
}
```

### 7.5 Add FileProvider Configuration

Add to `AndroidManifest.xml`:

```xml
<provider
    android:name="androidx.core.content.FileProvider"
    android:authorities="${applicationId}.fileprovider"
    android:exported="false"
    android:grantUriPermissions="true">
    <meta-data
        android:name="android.support.FILE_PROVIDER_PATHS"
        android:resource="@xml/file_paths" />
</provider>
```

Create `res/xml/file_paths.xml`:

```xml
<?xml version="1.0" encoding="utf-8"?>
<paths>
    <cache-path name="exports" path="exports/" />
</paths>
```

## Verification Checklist

- [ ] Report displays verdict with correct color
- [ ] Summary is clearly visible
- [ ] Markdown renders correctly
- [ ] References are identified in text
- [ ] Document sheet shows on reference click
- [ ] Statistics display accurately
- [ ] PDF export works (placeholder)
- [ ] Share functionality works
- [ ] PubMed link opens browser
- [ ] No report placeholder shows when empty

## Next Phase

Continue to [Phase 8: UI - History View](./08-ui-history.md)
