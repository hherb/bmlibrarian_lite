"""
Citations sub-tab for Audit Trail.

Displays document cards with highlighted citation passages.
Each card shows the document metadata and the extracted passage
highlighted within the abstract context.
"""

import logging
from typing import Optional, Dict, List

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QScrollArea,
    QLabel,
    QFrame,
    QHBoxLayout,
    QSizePolicy,
)
from PySide6.QtGui import QFont, QCursor

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..constants import AUDIT_CARD_SPACING, AUDIT_CARD_PADDING, AUDIT_CARD_BORDER_RADIUS
from ..data_models import Citation
from .card_utils import format_authors, format_metadata
from .text_highlighting import create_highlighted_passage_widget
from .quality_badge import QualityBadge

logger = logging.getLogger(__name__)


class CitationCard(QFrame):
    """
    Card displaying a citation with highlighted passage.

    Shows document metadata and the extracted passage
    highlighted within the abstract.

    Signals:
        clicked: Emitted when card is clicked (doc_id)

    Attributes:
        citation: The citation this card represents
    """

    clicked = Signal(str)  # doc_id

    def __init__(
        self,
        citation: Citation,
        index: int = 1,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the citation card.

        Args:
            citation: Citation to display
            index: Citation number (1-based)
            parent: Parent widget
        """
        super().__init__(parent)
        self.citation = citation
        self.index = index
        self._setup_ui()
        self._setup_interaction()

    def _setup_ui(self) -> None:
        """Set up the card UI."""
        self.setFrameShape(QFrame.Shape.StyledPanel)
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)

        # Card styling
        self.setStyleSheet(f"""
            QFrame {{
                background-color: #FFFFFF;
                border: 1px solid #E0E0E0;
                border-radius: {scaled(AUDIT_CARD_BORDER_RADIUS)}px;
            }}
            QFrame:hover {{
                background-color: #F5F5F5;
                border-color: #2196F3;
            }}
        """)

        # Layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )
        layout.setSpacing(scaled(8))

        doc = self.citation.document

        # Header row: index, quality badge, title
        header_layout = QHBoxLayout()
        header_layout.setSpacing(scaled(8))

        # Citation number
        index_label = QLabel(f"#{self.index}")
        index_font = QFont()
        index_font.setPointSize(scaled(10))
        index_font.setBold(True)
        index_label.setFont(index_font)
        index_label.setStyleSheet(
            "color: white; background-color: #1976D2; "
            f"padding: {scaled(4)}px {scaled(8)}px; "
            f"border-radius: {scaled(4)}px;"
        )
        header_layout.addWidget(index_label)

        # Quality badge (if available)
        if self.citation.assessment:
            quality_badge = QualityBadge(
                self.citation.assessment,
                show_design=True,
            )
            header_layout.addWidget(quality_badge)

        # Title
        title_label = QLabel(doc.title)
        title_label.setWordWrap(True)
        title_font = QFont()
        title_font.setPointSize(scaled(11))
        title_font.setBold(True)
        title_label.setFont(title_font)
        title_label.setStyleSheet("color: #1a1a1a;")
        header_layout.addWidget(title_label, stretch=1)

        layout.addLayout(header_layout)

        # Authors row
        authors_text = format_authors(doc.authors)
        authors_label = QLabel(f"Authors: {authors_text}")
        authors_label.setWordWrap(True)
        authors_label.setStyleSheet("color: #555555; font-size: 10pt;")
        layout.addWidget(authors_label)

        # Metadata row
        metadata_text = format_metadata(
            year=doc.year,
            journal=doc.journal,
            pmid=doc.pmid,
            doi=doc.doi,
        )
        metadata_label = QLabel(metadata_text)
        metadata_label.setWordWrap(True)
        metadata_label.setStyleSheet("color: #777777; font-size: 9pt;")
        layout.addWidget(metadata_label)

        # Relevance score
        score_label = QLabel(f"Relevance Score: {self.citation.relevance_score}/5")
        score_label.setStyleSheet("color: #333; font-size: 10pt; font-weight: bold;")
        layout.addWidget(score_label)

        # Context (why this passage is relevant)
        if self.citation.context:
            context_label = QLabel(f"Context: {self.citation.context}")
            context_label.setWordWrap(True)
            context_label.setStyleSheet(
                "color: #555; font-style: italic; font-size: 10pt;"
            )
            layout.addWidget(context_label)

        # Highlighted passage in abstract
        passage_widget = create_highlighted_passage_widget(
            abstract=doc.abstract,
            passage=self.citation.passage,
        )
        passage_widget.setMinimumHeight(scaled(100))
        passage_widget.setMaximumHeight(scaled(300))
        layout.addWidget(passage_widget)

    def _setup_interaction(self) -> None:
        """Set up mouse interaction."""
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))

    def mousePressEvent(self, event) -> None:
        """Handle mouse press - emit clicked signal."""
        if event.button() == Qt.MouseButton.LeftButton:
            self.clicked.emit(self.citation.document.id)
        super().mousePressEvent(event)

    @property
    def doc_id(self) -> str:
        """Get document ID."""
        return self.citation.document.id


class AuditCitationsTab(QWidget):
    """
    Citations sub-tab for the Audit Trail.

    Displays a scrollable list of citation cards showing
    extracted passages highlighted within their abstracts.

    Signals:
        document_clicked: Emitted when a citation card is clicked (doc_id)

    Attributes:
        citation_cards: List of citation cards
    """

    document_clicked = Signal(str)  # doc_id

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize the citations tab.

        Args:
            parent: Parent widget
        """
        super().__init__(parent)
        self._citation_cards: List[CitationCard] = []
        self._citations_by_doc_id: Dict[str, List[Citation]] = {}
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
            "No citations yet.\n\n"
            "Citations will appear here as they are extracted\n"
            "from relevant documents during the workflow."
        )
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder.setStyleSheet("color: #888; font-size: 11pt;")
        self.cards_layout.addWidget(self.placeholder)

        self.scroll_area.setWidget(self.cards_container)
        layout.addWidget(self.scroll_area)

    def add_citation(self, citation: Citation) -> CitationCard:
        """
        Add a citation to the display.

        Args:
            citation: Citation to add

        Returns:
            The created CitationCard
        """
        # Hide placeholder on first citation
        if len(self._citation_cards) == 0:
            self.placeholder.hide()

        # Store by document ID
        doc_id = citation.document.id
        if doc_id not in self._citations_by_doc_id:
            self._citations_by_doc_id[doc_id] = []
        self._citations_by_doc_id[doc_id].append(citation)

        # Create card
        card = CitationCard(
            citation=citation,
            index=len(self._citation_cards) + 1,
        )
        card.clicked.connect(self._on_card_clicked)

        # Store and display
        self._citation_cards.append(card)
        self.cards_layout.addWidget(card)

        return card

    def add_citations(self, citations: List[Citation]) -> None:
        """
        Add multiple citations to the display.

        Args:
            citations: List of citations to add
        """
        for citation in citations:
            self.add_citation(citation)

    def _on_card_clicked(self, doc_id: str) -> None:
        """Handle citation card click."""
        self.document_clicked.emit(doc_id)

    def get_citations_for_document(self, doc_id: str) -> List[Citation]:
        """
        Get all citations for a document.

        Args:
            doc_id: Document ID

        Returns:
            List of citations for the document
        """
        return self._citations_by_doc_id.get(doc_id, [])

    def clear(self) -> None:
        """Clear all citations from the display."""
        # Remove all cards
        for card in self._citation_cards:
            self.cards_layout.removeWidget(card)
            card.deleteLater()

        self._citation_cards.clear()
        self._citations_by_doc_id.clear()

        # Show placeholder
        self.placeholder.show()

    @property
    def citation_count(self) -> int:
        """Get number of citations displayed."""
        return len(self._citation_cards)
