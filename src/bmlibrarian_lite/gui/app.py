"""
Main application window for BMLibrarian Lite.

A lightweight version of BMLibrarian with three tabs:
- Systematic Review: Search PubMed, score, extract, and generate reports
- Report: View and interact with generated reports
- Document Interrogation: Q&A with loaded documents
"""

import logging
import os
import sys
from typing import Optional

# Suppress tokenizers parallelism warning when forking for Qt threads
# This must be set before importing any HuggingFace/FastEmbed modules
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

from PySide6.QtWidgets import (
    QApplication,
    QMainWindow,
    QTabWidget,
    QVBoxLayout,
    QWidget,
    QStatusBar,
    QPushButton,
    QLabel,
)
from PySide6.QtCore import QTimer

from bmlibrarian_lite.resources.styles.dpi_scale import scaled
from bmlibrarian_lite.resources.styles.stylesheet_generator import StylesheetGenerator
from bmlibrarian_lite.llm.token_tracker import get_token_tracker

from ..config import LiteConfig
from ..storage import LiteStorage
from .systematic_review_tab import SystematicReviewTab
from .audit_trail_tab import AuditTrailTab
from .report_tab import ReportTab
from .document_interrogation_tab import DocumentInterrogationTab
from .settings_dialog import SettingsDialog

logger = logging.getLogger(__name__)

# Update interval for token usage display (milliseconds)
TOKEN_USAGE_UPDATE_INTERVAL_MS = 1000


class LiteMainWindow(QMainWindow):
    """
    Main window for BMLibrarian Lite.

    Provides a two-tab interface for systematic review and document
    interrogation workflows.

    Attributes:
        config: Lite configuration instance
        storage: Storage layer instance
    """

    # Window dimensions relative to font metrics
    DEFAULT_WIDTH_CHARS = 120
    DEFAULT_HEIGHT_CHARS = 40

    def __init__(
        self,
        config: Optional[LiteConfig] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the main window.

        Args:
            config: Lite configuration (uses defaults if not provided)
            parent: Optional parent widget
        """
        super().__init__(parent)

        self.config = config or LiteConfig.load()
        self.config.ensure_directories()
        self.config.load_env()

        self.storage = LiteStorage(self.config)

        # Token tracker for usage display
        self._token_tracker = get_token_tracker()
        self._last_token_count = 0

        self._setup_ui()
        self._apply_styles()
        self._setup_token_tracking()

        logger.info("BMLibrarian Lite initialized")

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        self.setWindowTitle("BMLibrarian Lite")

        # Calculate window size from font metrics
        fm = self.fontMetrics()
        width = fm.horizontalAdvance('x') * self.DEFAULT_WIDTH_CHARS
        height = fm.height() * self.DEFAULT_HEIGHT_CHARS
        self.resize(width, height)

        # Central widget and layout
        central = QWidget()
        self.setCentralWidget(central)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(scaled(8), scaled(8), scaled(8), scaled(8))

        # Tab widget
        self.tab_widget = QTabWidget()
        layout.addWidget(self.tab_widget)

        # Create tabs
        self.systematic_review_tab = SystematicReviewTab(
            config=self.config,
            storage=self.storage,
            parent=self,
        )
        self.tab_widget.addTab(self.systematic_review_tab, "Systematic Review")

        # Audit Trail tab - between Systematic Review and Report
        self.audit_trail_tab = AuditTrailTab(
            config=self.config,
            storage=self.storage,
            parent=self,
        )
        self.tab_widget.addTab(self.audit_trail_tab, "Audit Trail")

        self.report_tab = ReportTab(
            config=self.config,
            storage=self.storage,
            parent=self,
        )
        self.tab_widget.addTab(self.report_tab, "Report")

        self.interrogation_tab = DocumentInterrogationTab(
            config=self.config,
            storage=self.storage,
            parent=self,
        )
        self.tab_widget.addTab(self.interrogation_tab, "Document Interrogation")

        # Connect report generation signal to display in Report tab
        self.systematic_review_tab.report_generated.connect(
            self._on_report_generated
        )

        # Connect citation click signal from Report tab to load document
        self.report_tab.document_requested.connect(
            self._on_document_requested
        )

        # Connect Audit Trail signals from Systematic Review tab
        self.systematic_review_tab.workflow_started.connect(
            self.audit_trail_tab.on_workflow_started
        )
        self.systematic_review_tab.workflow_finished.connect(
            self.audit_trail_tab.on_workflow_finished
        )
        self.systematic_review_tab.query_generated.connect(
            self.audit_trail_tab.on_query_generated
        )
        self.systematic_review_tab.documents_found.connect(
            self.audit_trail_tab.on_documents_found
        )
        self.systematic_review_tab.document_scored.connect(
            self.audit_trail_tab.on_document_scored
        )
        self.systematic_review_tab.citation_extracted.connect(
            self.audit_trail_tab.on_citation_extracted
        )
        self.systematic_review_tab.quality_assessed.connect(
            self.audit_trail_tab.on_quality_assessed
        )

        # Connect Audit Trail document request to load document
        self.audit_trail_tab.document_requested.connect(
            self._on_document_requested_from_audit
        )

        # Status bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Ready")

        # Token usage label in status bar (permanent, left of settings)
        self.token_usage_label = QLabel("Tokens: 0 | Cost: $0.0000")
        self.token_usage_label.setToolTip(
            "Cumulative token usage and estimated cost for this session"
        )
        self.status_bar.addPermanentWidget(self.token_usage_label)

        # Settings button in status bar
        settings_btn = QPushButton("Settings")
        settings_btn.clicked.connect(self._show_settings)
        self.status_bar.addPermanentWidget(settings_btn)

    def _apply_styles(self) -> None:
        """Apply stylesheet to the application."""
        generator = StylesheetGenerator()
        stylesheet = generator.generate()
        self.setStyleSheet(stylesheet)

    def _show_settings(self) -> None:
        """Show the settings dialog."""
        dialog = SettingsDialog(self.config, parent=self)
        if dialog.exec():
            # Reload configuration
            self.config = LiteConfig.load()
            self.status_bar.showMessage("Settings saved", 3000)

    def set_status(self, message: str, timeout: int = 0) -> None:
        """
        Set status bar message.

        Args:
            message: Status message
            timeout: Timeout in milliseconds (0 = permanent)
        """
        self.status_bar.showMessage(message, timeout)

    def _setup_token_tracking(self) -> None:
        """Set up periodic token usage updates."""
        self._token_timer = QTimer(self)
        self._token_timer.timeout.connect(self._update_token_usage)
        self._token_timer.start(TOKEN_USAGE_UPDATE_INTERVAL_MS)
        # Initial update
        self._update_token_usage()

    def _update_token_usage(self) -> None:
        """
        Update the token usage display in the status bar.

        Only updates when there's new usage to minimize UI updates.
        """
        summary = self._token_tracker.get_summary()
        current_tokens = summary.total_tokens

        # Only update UI if tokens have changed
        if current_tokens != self._last_token_count:
            self._last_token_count = current_tokens
            cost = summary.total_cost_usd
            self.token_usage_label.setText(
                f"Tokens: {current_tokens:,} | Cost: ${cost:.4f}"
            )

    def update_token_display(self) -> None:
        """
        Force an immediate update of the token usage display.

        Call this method after LLM operations to immediately reflect
        new token usage without waiting for the timer.
        """
        self._update_token_usage()

    def _on_report_generated(
        self,
        report: str,
        question: str,
        citations: list,
        documents_found: list,
        scored_documents: list,
        quality_assessments: dict,
        quality_filter_settings: dict,
    ) -> None:
        """
        Handle report generation from systematic review.

        Displays the report in the Report tab and switches to it.

        Args:
            report: Generated markdown report
            question: Research question
            citations: List of citations extracted
            documents_found: All documents found in search
            scored_documents: Documents that passed scoring
            quality_assessments: Quality assessments by doc ID
            quality_filter_settings: Quality filter settings used
        """
        # Display report in the Report tab
        self.report_tab.display_report(
            report=report,
            question=question,
            citations=citations,
            documents_found=documents_found,
            scored_documents=scored_documents,
            quality_assessments=quality_assessments,
            quality_filter_settings=quality_filter_settings,
        )

        # Switch to Report tab
        self.tab_widget.setCurrentWidget(self.report_tab)

        self.status_bar.showMessage(
            f"Report generated with {len(citations)} citations", 5000
        )

    def _on_document_requested(self, doc_id: str) -> None:
        """
        Handle document request from citation click in Report tab.

        Switches to the Document Interrogation tab and loads
        the requested document for Q&A.

        Args:
            doc_id: Document ID from the citation
        """
        # Get the citation from the Report tab
        citation = self.report_tab.get_citation(doc_id)

        if not citation:
            logger.warning(f"Citation not found for doc_id: {doc_id}")
            self.status_bar.showMessage(f"Document not found: {doc_id}", 5000)
            return

        # Switch to interrogation tab
        self.tab_widget.setCurrentWidget(self.interrogation_tab)

        # Load the document
        self.interrogation_tab.load_from_citation(citation)

        self.status_bar.showMessage(
            f"Loading document: {citation.document.title[:50]}...", 3000
        )

    def _on_document_requested_from_audit(self, doc_id: str) -> None:
        """
        Handle document request from Audit Trail tab.

        Gets the document from the Audit Trail and loads it
        in the Document Interrogation tab for Q&A.

        Args:
            doc_id: Document ID clicked in audit trail
        """
        # Try to get citation from the citations tab first
        citations = self.audit_trail_tab.get_citations_for_document(doc_id)

        if citations:
            # Use the first citation if available
            citation = citations[0]
            self.tab_widget.setCurrentWidget(self.interrogation_tab)
            self.interrogation_tab.load_from_citation(citation)
            self.status_bar.showMessage(
                f"Loading document: {citation.document.title[:50]}...", 3000
            )
            return

        # Otherwise get the document directly
        document = self.audit_trail_tab.get_document(doc_id)

        if not document:
            logger.warning(f"Document not found in audit trail: {doc_id}")
            self.status_bar.showMessage(f"Document not found: {doc_id}", 5000)
            return

        # Switch to interrogation tab and load document
        self.tab_widget.setCurrentWidget(self.interrogation_tab)

        # Create a minimal citation for loading
        from ..data_models import Citation
        citation = Citation(
            document=document,
            passage="",  # No specific passage
            relevance_score=0,
            context="Loaded from audit trail",
        )
        self.interrogation_tab.load_from_citation(citation)

        self.status_bar.showMessage(
            f"Loading document: {document.title[:50]}...", 3000
        )


def run_lite_app() -> int:
    """
    Run the BMLibrarian Lite application.

    Returns:
        Application exit code
    """
    app = QApplication(sys.argv)
    app.setApplicationName("BMLibrarian Lite")
    app.setOrganizationName("BMLibrarian")

    window = LiteMainWindow()
    window.show()

    return app.exec()
