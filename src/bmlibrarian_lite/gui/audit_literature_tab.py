"""
Literature sub-tab for Audit Trail.

Displays a scrollable list of document cards showing all documents
found during the systematic review. Cards are updated with scores
and quality assessments as they become available, and re-sorted
by score after the workflow completes.
"""

import logging
import threading
from typing import Optional, Dict, List

from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QScrollArea,
    QLabel,
    QSizePolicy,
)

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..constants import AUDIT_CARD_SPACING, AUDIT_UI_UPDATE_DELAY_MS
from ..data_models import LiteDocument, ScoredDocument
from ..quality.data_models import QualityAssessment
from .document_card import DocumentCard

logger = logging.getLogger(__name__)


class AuditLiteratureTab(QWidget):
    """
    Literature sub-tab for the Audit Trail.

    Displays a scrollable list of document cards. Documents are
    initially sorted by publication date (newest first), then
    re-sorted by score (highest first) after scoring completes.

    Signals:
        document_clicked: Emitted when a document card is clicked (doc_id)
        send_to_interrogator: Emitted when user requests to interrogate document

    Attributes:
        cards_by_doc_id: Dictionary mapping doc IDs to cards
    """

    document_clicked = Signal(str)  # doc_id
    send_to_interrogator = Signal(str)  # doc_id for interrogation

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize the literature tab.

        Args:
            parent: Parent widget
        """
        super().__init__(parent)
        self._cards_by_doc_id: Dict[str, DocumentCard] = {}
        self._documents: Dict[str, LiteDocument] = {}
        self._scores: Dict[str, int] = {}
        self._score_rationales: Dict[str, str] = {}
        self._quality_assessments: Dict[str, QualityAssessment] = {}

        # Thread safety
        self._lock = threading.RLock()

        # Batched updates
        self._pending_updates: List[tuple] = []
        self._update_timer = QTimer(self)
        self._update_timer.setInterval(AUDIT_UI_UPDATE_DELAY_MS)
        self._update_timer.timeout.connect(self._process_pending_updates)

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the tab UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)
        layout.setSpacing(0)

        # Scroll area for cards
        self.scroll_area = QScrollArea()
        self.scroll_area.setWidgetResizable(True)
        self.scroll_area.setHorizontalScrollBarPolicy(
            Qt.ScrollBarPolicy.ScrollBarAlwaysOff
        )
        self.scroll_area.setStyleSheet("""
            QScrollArea {
                border: none;
                background-color: #FAFAFA;
            }
        """)

        # Container for cards
        self.cards_container = QWidget()
        self.cards_layout = QVBoxLayout(self.cards_container)
        self.cards_layout.setContentsMargins(
            scaled(8), scaled(8), scaled(8), scaled(8)
        )
        self.cards_layout.setSpacing(scaled(AUDIT_CARD_SPACING))
        self.cards_layout.setAlignment(Qt.AlignmentFlag.AlignTop)

        # Placeholder when empty
        self.placeholder = QLabel(
            "No documents yet.\n\n"
            "Documents will appear here as they are found\n"
            "during the systematic review workflow."
        )
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder.setStyleSheet("color: #888; font-size: 11pt;")
        self.cards_layout.addWidget(self.placeholder)

        self.scroll_area.setWidget(self.cards_container)
        layout.addWidget(self.scroll_area)

    def add_documents(self, documents: List[LiteDocument]) -> None:
        """
        Add multiple documents to the display.

        Documents are sorted by publication date (newest first).

        Args:
            documents: List of documents to add
        """
        # Hide placeholder on first documents
        if len(self._cards_by_doc_id) == 0 and documents:
            self.placeholder.hide()

        # Sort by publication date (newest first)
        sorted_docs = sorted(
            documents,
            key=lambda d: d.year or 0,
            reverse=True,
        )

        for doc in sorted_docs:
            self._add_document_card(doc)

    def add_document(self, document: LiteDocument) -> DocumentCard:
        """
        Add a single document to the display.

        Uses batched updates to prevent UI lag.

        Args:
            document: Document to add

        Returns:
            The created DocumentCard
        """
        self._pending_updates.append(("add", document))
        if not self._update_timer.isActive():
            self._update_timer.start()

        # Return a placeholder card - actual card created in batch
        # This is a limitation of batched updates
        return self._cards_by_doc_id.get(document.id)

    def _add_document_card(self, document: LiteDocument) -> DocumentCard:
        """
        Internal method to add a document card.

        Args:
            document: Document to add

        Returns:
            The created DocumentCard
        """
        with self._lock:
            # Check if already exists
            if document.id in self._cards_by_doc_id:
                return self._cards_by_doc_id[document.id]

            # Store document
            self._documents[document.id] = document

            # Get any existing score/quality/rationale
            score = self._scores.get(document.id)
            score_rationale = self._score_rationales.get(document.id)
            quality = self._quality_assessments.get(document.id)

            # Create card
            card = DocumentCard(
                document=document,
                score=score,
                score_rationale=score_rationale,
                quality_assessment=quality,
            )
            card.clicked.connect(self._on_card_clicked)
            card.send_to_interrogator.connect(self._on_send_to_interrogator)

            # Store and display
            self._cards_by_doc_id[document.id] = card
            self.cards_layout.addWidget(card)

            # Hide placeholder if needed
            if self.placeholder.isVisible():
                self.placeholder.hide()

            return card

    def update_score(self, scored_doc: ScoredDocument) -> None:
        """
        Update score for a document.

        Args:
            scored_doc: Scored document with score and explanation
        """
        doc_id = scored_doc.document.id
        score = scored_doc.score
        rationale = scored_doc.explanation

        with self._lock:
            self._scores[doc_id] = score
            if rationale:
                self._score_rationales[doc_id] = rationale

            card = self._cards_by_doc_id.get(doc_id)
            if card:
                card.set_score(score, rationale)
            else:
                # Document not yet added - store for later
                logger.debug(f"Score received before document: {doc_id}")

    def update_quality(self, doc_id: str, assessment: QualityAssessment) -> None:
        """
        Update quality assessment for a document.

        Args:
            doc_id: Document ID
            assessment: Quality assessment
        """
        with self._lock:
            self._quality_assessments[doc_id] = assessment

            card = self._cards_by_doc_id.get(doc_id)
            if card:
                card.set_quality_assessment(assessment)

    def _on_card_clicked(self, doc_id: str) -> None:
        """Handle document card click."""
        self.document_clicked.emit(doc_id)

    def _on_send_to_interrogator(self, doc_id: str) -> None:
        """Handle request to send document to interrogator."""
        self.send_to_interrogator.emit(doc_id)

    def _process_pending_updates(self) -> None:
        """Process batched updates."""
        updates = self._pending_updates.copy()
        self._pending_updates.clear()
        self._update_timer.stop()

        for update_type, data in updates:
            if update_type == "add":
                self._add_document_card(data)

    def resort_by_score(self) -> None:
        """
        Re-sort cards by score (highest first).

        Called after scoring completes to reorder documents.
        Documents without scores are placed at the end.
        """
        with self._lock:
            # Get cards with scores
            cards_with_scores = [
                (card, self._scores.get(card.doc_id, 0))
                for card in self._cards_by_doc_id.values()
            ]

            # Sort by score descending
            cards_with_scores.sort(key=lambda x: x[1], reverse=True)

            # Remove all cards from layout
            for card, _ in cards_with_scores:
                self.cards_layout.removeWidget(card)

            # Re-add in sorted order
            for card, _ in cards_with_scores:
                self.cards_layout.addWidget(card)

    def get_card(self, doc_id: str) -> Optional[DocumentCard]:
        """
        Get document card by ID.

        Args:
            doc_id: Document ID

        Returns:
            DocumentCard if found, None otherwise
        """
        with self._lock:
            return self._cards_by_doc_id.get(doc_id)

    def get_document(self, doc_id: str) -> Optional[LiteDocument]:
        """
        Get document by ID.

        Args:
            doc_id: Document ID

        Returns:
            LiteDocument if found, None otherwise
        """
        with self._lock:
            return self._documents.get(doc_id)

    def clear(self) -> None:
        """Clear all documents from the display."""
        with self._lock:
            # Stop any pending updates
            self._update_timer.stop()
            self._pending_updates.clear()

            # Remove all cards
            for card in list(self._cards_by_doc_id.values()):
                self.cards_layout.removeWidget(card)
                card.deleteLater()

            self._cards_by_doc_id.clear()
            self._documents.clear()
            self._scores.clear()
            self._score_rationales.clear()
            self._quality_assessments.clear()

            # Show placeholder
            self.placeholder.show()

    @property
    def document_count(self) -> int:
        """Get number of documents displayed."""
        return len(self._cards_by_doc_id)

    @property
    def scored_count(self) -> int:
        """Get number of documents with scores."""
        return len(self._scores)
