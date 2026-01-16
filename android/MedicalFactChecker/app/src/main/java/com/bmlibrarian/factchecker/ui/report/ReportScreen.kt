package com.bmlibrarian.factchecker.ui.report

import android.content.Context
import android.content.Intent
import android.net.Uri
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
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Description
import androidx.compose.material.icons.filled.PictureAsPdf
import androidx.compose.material.icons.filled.Share
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.Scaffold
import androidx.compose.material3.SnackbarHost
import androidx.compose.material3.SnackbarHostState
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.dp
import androidx.core.content.FileProvider
import androidx.hilt.navigation.compose.hiltViewModel
import com.bmlibrarian.factchecker.ui.report.components.DocumentDetailSheet
import com.bmlibrarian.factchecker.ui.report.components.MarkdownReport
import com.bmlibrarian.factchecker.ui.report.components.ReportStatistics
import com.bmlibrarian.factchecker.ui.report.components.VerdictHeader
import com.bmlibrarian.factchecker.util.Constants

/**
 * Evidence report display screen.
 *
 * Shows the generated evidence report from the fact-checking workflow
 * including verdict, summary, full markdown report with clickable
 * references, statistics, and export/share functionality.
 *
 * @param viewModel The ViewModel for managing report state
 */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun ReportScreen(
    viewModel: ReportViewModel = hiltViewModel()
) {
    val uiState by viewModel.uiState.collectAsState()
    val context = LocalContext.current
    val scrollState = rememberScrollState()
    val snackbarHostState = remember { SnackbarHostState() }

    // Paper size selection dialog state
    var showPaperSizeDialog by remember { mutableStateOf(false) }

    // Document detail bottom sheet state
    val sheetState = rememberModalBottomSheetState()

    // Handle one-shot events
    LaunchedEffect(Unit) {
        viewModel.events.collect { event ->
            handleEvent(event, context, snackbarHostState)
        }
    }

    Scaffold(
        snackbarHost = { SnackbarHost(snackbarHostState) }
    ) { paddingValues ->
        // Show loading indicator
        if (uiState.isLoading) {
            Box(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues),
                contentAlignment = Alignment.Center
            ) {
                CircularProgressIndicator()
            }
            return@Scaffold
        }

        // Show placeholder if no report
        if (uiState.report == null) {
            NoReportPlaceholder(
                modifier = Modifier.padding(paddingValues)
            )
            return@Scaffold
        }

        val report = uiState.report!!

        Column(
            modifier = Modifier
                .fillMaxSize()
                .padding(paddingValues)
                .padding(Constants.UI_SCREEN_PADDING.dp)
        ) {
            // Verdict header
            VerdictHeader(
                verdict = report.verdict,
                summary = report.summary
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

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

                Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

                // Statistics
                ReportStatistics(
                    totalDocuments = report.totalDocumentsReviewed,
                    relevantDocuments = report.relevantDocumentsCount,
                    citations = report.citationsCount,
                    model = report.modelUsed,
                    generatedAt = report.createdAt
                )
            }

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            // Action buttons
            Row(
                horizontalArrangement = Arrangement.spacedBy(Constants.UI_ELEMENT_SPACING.dp),
                modifier = Modifier.fillMaxWidth()
            ) {
                OutlinedButton(
                    onClick = { showPaperSizeDialog = true },
                    enabled = !uiState.isExporting,
                    modifier = Modifier.weight(1f)
                ) {
                    if (uiState.isExporting) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(Constants.UI_ICON_SIZE.dp),
                            strokeWidth = Constants.PROGRESS_STROKE_WIDTH_SMALL.dp
                        )
                    } else {
                        Icon(
                            imageVector = Icons.Default.PictureAsPdf,
                            contentDescription = null,
                            modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                        )
                    }
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))
                    Text("Export PDF")
                }

                Button(
                    onClick = viewModel::shareReport,
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(
                        imageVector = Icons.Default.Share,
                        contentDescription = null,
                        modifier = Modifier.size(Constants.UI_ICON_SIZE.dp)
                    )
                    Spacer(modifier = Modifier.width(Constants.UI_ELEMENT_SPACING.dp))
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
                        PaperSize.entries.forEach { size ->
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
    }
}

/**
 * Handle UI events by performing side effects.
 *
 * @param event The event to handle
 * @param context Android context for launching intents
 * @param snackbarHostState State for showing snackbars
 */
private suspend fun handleEvent(
    event: ReportUiEvent,
    context: Context,
    snackbarHostState: SnackbarHostState
) {
    when (event) {
        is ReportUiEvent.OpenUrl -> {
            val intent = Intent(Intent.ACTION_VIEW, Uri.parse(event.url))
            context.startActivity(intent)
        }

        is ReportUiEvent.ShareText -> {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_SUBJECT, event.subject)
                putExtra(Intent.EXTRA_TEXT, event.text)
            }
            context.startActivity(Intent.createChooser(intent, "Share Report"))
        }

        is ReportUiEvent.ShareFile -> {
            val uri = FileProvider.getUriForFile(
                context,
                "${context.packageName}.fileprovider",
                event.file
            )

            val intent = Intent(Intent.ACTION_SEND).apply {
                type = event.mimeType
                putExtra(Intent.EXTRA_STREAM, uri)
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
            }
            context.startActivity(Intent.createChooser(intent, "Share PDF"))
        }

        is ReportUiEvent.ShowSnackbar -> {
            snackbarHostState.showSnackbar(event.message)
        }
    }
}

/**
 * Placeholder shown when no report is available.
 */
@Composable
private fun NoReportPlaceholder(
    modifier: Modifier = Modifier
) {
    Box(
        modifier = modifier
            .fillMaxSize()
            .padding(Constants.UI_PLACEHOLDER_PADDING.dp),
        contentAlignment = Alignment.Center
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Icon(
                imageVector = Icons.Default.Description,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(Constants.UI_ICON_SIZE_LARGE.dp)
            )

            Spacer(modifier = Modifier.height(Constants.UI_SECTION_SPACING.dp))

            Text(
                text = "No Report Available",
                style = MaterialTheme.typography.headlineSmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )

            Spacer(modifier = Modifier.height(Constants.UI_ELEMENT_SPACING.dp))

            Text(
                text = "Complete a fact-check to see the evidence report here.",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                textAlign = TextAlign.Center
            )
        }
    }
}
