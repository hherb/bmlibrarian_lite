# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""
Audit Trail tab for BMLibrarian Lite.

Provides a dedicated view for tracking the systematic review workflow
with three sub-tabs:
- Queries: Generated PubMed queries with statistics
- Literature: Document cards with scores and quality badges
- Citations: Document cards with highlighted citation passages

This tab receives signals from the SystematicReviewTab and updates
its sub-tabs in real-time during workflow execution.
"""

import logging
from typing import Optional, List

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QTabWidget,
)

from ..config import LiteConfig
from ..storage import LiteStorage
from ..data_models import LiteDocument, ScoredDocument, Citation
from ..quality.data_models import QualityAssessment
from ..transparency import TransparencyResult

from .audit_queries_tab import AuditQueriesTab
from .audit_literature_tab import AuditLiteratureTab
from .audit_citations_tab import AuditCitationsTab

logger = logging.getLogger(__name__)


class AuditTrailTab(QWidget):
    """
    Audit Trail tab widget.

    Container for three sub-tabs that display workflow progress:
    - Queries: Shows generated PubMed queries with statistics
    - Literature: Shows all documents with scores and quality
    - Citations: Shows extracted citations with highlighted passages

    Receives signals from SystematicReviewTab to update in real-time.

    Signals:
        document_requested: Emitted when user clicks a document (doc_id)

    Attributes:
        config: Lite configuration
        storage: Storage layer
        queries_tab: Queries sub-tab
        literature_tab: Literature sub-tab
        citations_tab: Citations sub-tab
    """

    # Emitted when user clicks a document to open in Interrogation tab
    document_requested = Signal(str)  # doc_id

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the audit trail tab.

        Args:
            config: Lite configuration
            storage: Storage layer
            parent: Optional parent widget
        """
        super().__init__(parent)
        self.config = config
        self.storage = storage

        # Track current query for statistics updates
        self._current_query: Optional[str] = None
        self._documents_found_count = 0
        self._documents_scored_count = 0
        self._citations_count = 0

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the user interface."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Tab widget for sub-tabs
        self.tab_widget = QTabWidget()

        # Create sub-tabs
        self.queries_tab = AuditQueriesTab()
        self.literature_tab = AuditLiteratureTab()
        self.citations_tab = AuditCitationsTab()

        # Add sub-tabs
        self.tab_widget.addTab(self.queries_tab, "Queries")
        self.tab_widget.addTab(self.literature_tab, "Literature")
        self.tab_widget.addTab(self.citations_tab, "Citations")

        # Connect document click signals
        self.literature_tab.document_clicked.connect(self._on_document_clicked)
        self.citations_tab.document_clicked.connect(self._on_document_clicked)

        # Connect send to interrogator signal
        self.literature_tab.send_to_interrogator.connect(self._on_send_to_interrogator)

        layout.addWidget(self.tab_widget)

    def _on_document_clicked(self, doc_id: str) -> None:
        """
        Handle document click from sub-tabs.

        Note: Document clicks now toggle expand/collapse.
        This signal is still emitted for potential future use.

        Args:
            doc_id: Clicked document ID
        """
        logger.debug(f"Document clicked in audit trail: {doc_id}")
        # Don't navigate on click - cards now expand/collapse instead
        # The document_requested signal is emitted via context menu

    def _on_send_to_interrogator(self, doc_id: str) -> None:
        """
        Handle request to send document to interrogator (via context menu).

        Args:
            doc_id: Document ID to interrogate
        """
        logger.info(f"Document requested for interrogation: {doc_id}")
        self.document_requested.emit(doc_id)

    # =========================================================================
    # Workflow Event Handlers
    # =========================================================================

    def on_workflow_started(self) -> None:
        """
        Handle workflow start.

        Clears all previous data from sub-tabs.
        """
        logger.debug("Audit trail: workflow started")
        self.clear()

    def on_workflow_finished(self) -> None:
        """
        Handle workflow completion.

        Re-sorts literature by score.
        """
        logger.debug("Audit trail: workflow finished")
        self.literature_tab.resort_by_score()

        # Update final statistics
        if self._current_query:
            self.queries_tab.update_query_stats(
                self._current_query,
                documents_found=self._documents_found_count,
                documents_scored=self._documents_scored_count,
                citations_extracted=self._citations_count,
            )

    def on_query_generated(self, pubmed_query: str, nl_query: str) -> None:
        """
        Handle query generation.

        Adds query to the Queries sub-tab.

        Args:
            pubmed_query: Generated PubMed query string
            nl_query: Original natural language query
        """
        logger.debug(f"Audit trail: query generated - {pubmed_query[:50]}...")
        self._current_query = pubmed_query
        self._documents_found_count = 0
        self._documents_scored_count = 0
        self._citations_count = 0

        self.queries_tab.add_query(pubmed_query, nl_query)

    def on_documents_found(self, documents: List[LiteDocument]) -> None:
        """
        Handle documents found.

        Adds documents to the Literature sub-tab.

        Args:
            documents: List of found documents
        """
        logger.debug(f"Audit trail: {len(documents)} documents found")
        self._documents_found_count = len(documents)

        self.literature_tab.add_documents(documents)

        # Update query statistics
        if self._current_query:
            self.queries_tab.update_query_stats(
                self._current_query,
                documents_found=self._documents_found_count,
            )

    def on_document_scored(self, scored_doc: ScoredDocument) -> None:
        """
        Handle document scoring.

        Updates score in the Literature sub-tab.

        Args:
            scored_doc: Scored document
        """
        logger.debug(
            f"Audit trail: document scored - {scored_doc.document.id} = {scored_doc.score}"
        )
        self._documents_scored_count += 1

        self.literature_tab.update_score(scored_doc)

        # Update query statistics
        if self._current_query:
            self.queries_tab.update_query_stats(
                self._current_query,
                documents_scored=self._documents_scored_count,
            )

    def on_citation_extracted(self, citation: Citation) -> None:
        """
        Handle citation extraction.

        Adds citation to the Citations sub-tab.

        Args:
            citation: Extracted citation
        """
        logger.debug(f"Audit trail: citation extracted from {citation.document.id}")
        self._citations_count += 1

        self.citations_tab.add_citation(citation)

        # Update query statistics
        if self._current_query:
            self.queries_tab.update_query_stats(
                self._current_query,
                citations_extracted=self._citations_count,
            )

    def on_quality_assessed(self, doc_id: str, assessment: QualityAssessment) -> None:
        """
        Handle quality assessment.

        Updates quality badge in the Literature sub-tab.

        Args:
            doc_id: Document ID
            assessment: Quality assessment
        """
        logger.debug(f"Audit trail: quality assessed - {doc_id}")
        self.literature_tab.update_quality(doc_id, assessment)

    def on_transparency_assessed(
        self,
        doc_id: str,
        result: TransparencyResult,
    ) -> None:
        """
        Handle transparency assessment result.

        Updates transparency badge in the Literature sub-tab.

        Args:
            doc_id: Document ID
            result: Transparency analysis result
        """
        logger.debug(
            f"Audit trail: transparency assessed - {doc_id} "
            f"(risk: {result.risk_level.value})"
        )
        self.literature_tab.update_transparency(doc_id, result)

    # =========================================================================
    # Data Access
    # =========================================================================

    def get_document(self, doc_id: str) -> Optional[LiteDocument]:
        """
        Get document by ID from the literature tab.

        Args:
            doc_id: Document ID

        Returns:
            LiteDocument if found, None otherwise
        """
        return self.literature_tab.get_document(doc_id)

    def get_citations_for_document(self, doc_id: str) -> List[Citation]:
        """
        Get all citations for a document.

        Args:
            doc_id: Document ID

        Returns:
            List of citations for the document
        """
        return self.citations_tab.get_citations_for_document(doc_id)

    def clear(self) -> None:
        """Clear all data from all sub-tabs."""
        self._current_query = None
        self._documents_found_count = 0
        self._documents_scored_count = 0
        self._citations_count = 0

        self.queries_tab.clear()
        self.literature_tab.clear()
        self.citations_tab.clear()

    # =========================================================================
    # Statistics
    # =========================================================================

    @property
    def query_count(self) -> int:
        """Get number of queries."""
        return self.queries_tab.query_count

    @property
    def document_count(self) -> int:
        """Get number of documents."""
        return self.literature_tab.document_count

    @property
    def citation_count(self) -> int:
        """Get number of citations."""
        return self.citations_tab.citation_count
