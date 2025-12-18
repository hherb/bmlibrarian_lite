"""
Queries sub-tab for Audit Trail.

Displays generated PubMed queries with real-time statistics
showing documents found, scored, and citations extracted.
"""

import logging
from typing import Optional, Dict

from PySide6.QtCore import Qt
from PySide6.QtWidgets import (
    QWidget,
    QVBoxLayout,
    QScrollArea,
    QFrame,
    QLabel,
    QHBoxLayout,
    QSizePolicy,
)
from PySide6.QtGui import QFont

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..constants import (
    AUDIT_CARD_PADDING,
    AUDIT_CARD_BORDER_RADIUS,
    AUDIT_CARD_SPACING,
)
from .card_utils import format_query_stats

logger = logging.getLogger(__name__)


class QueryCard(QFrame):
    """
    Card displaying a PubMed query with statistics.

    Shows the query text and counts for documents found,
    scored, and citations extracted.

    Attributes:
        pubmed_query: The PubMed query string
        nl_query: Natural language version of the query
    """

    def __init__(
        self,
        pubmed_query: str,
        nl_query: str,
        index: int = 1,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the query card.

        Args:
            pubmed_query: PubMed query string
            nl_query: Natural language query
            index: Query number (1-based)
            parent: Parent widget
        """
        super().__init__(parent)
        self.pubmed_query = pubmed_query
        self.nl_query = nl_query
        self.index = index

        # Statistics (updated during workflow)
        self._documents_found = 0
        self._documents_scored = 0
        self._citations_extracted = 0

        self._setup_ui()

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
        """)

        # Layout
        layout = QVBoxLayout(self)
        layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )
        layout.setSpacing(scaled(6))

        # Query header
        header = QLabel(f"Query {self.index}")
        font = QFont()
        font.setPointSize(scaled(10))
        font.setBold(True)
        header.setFont(font)
        header.setStyleSheet("color: #1976D2;")
        layout.addWidget(header)

        # Query text (PubMed format)
        self.query_label = QLabel(self.pubmed_query)
        self.query_label.setWordWrap(True)
        self.query_label.setStyleSheet(
            "color: #333; font-family: monospace; font-size: 10pt; "
            f"background-color: #F5F5F5; padding: {scaled(8)}px; "
            f"border-radius: {scaled(4)}px;"
        )
        layout.addWidget(self.query_label)

        # Natural language version (if different)
        if self.nl_query and self.nl_query != self.pubmed_query:
            nl_label = QLabel(f"From: \"{self.nl_query}\"")
            nl_label.setWordWrap(True)
            nl_label.setStyleSheet("color: #666; font-style: italic; font-size: 9pt;")
            layout.addWidget(nl_label)

        # Statistics row
        stats_layout = QHBoxLayout()
        stats_layout.setSpacing(scaled(16))

        self.stats_label = QLabel(
            format_query_stats(
                self._documents_found,
                self._documents_scored,
                self._citations_extracted,
            )
        )
        self.stats_label.setStyleSheet("color: #555; font-size: 10pt;")
        stats_layout.addWidget(self.stats_label)

        stats_layout.addStretch()
        layout.addLayout(stats_layout)

    def set_documents_found(self, count: int) -> None:
        """
        Update documents found count.

        Args:
            count: Number of documents found
        """
        self._documents_found = count
        self._update_stats()

    def set_documents_scored(self, count: int) -> None:
        """
        Update documents scored count.

        Args:
            count: Number of documents scored
        """
        self._documents_scored = count
        self._update_stats()

    def set_citations_extracted(self, count: int) -> None:
        """
        Update citations extracted count.

        Args:
            count: Number of citations extracted
        """
        self._citations_extracted = count
        self._update_stats()

    def _update_stats(self) -> None:
        """Update the statistics label."""
        self.stats_label.setText(
            format_query_stats(
                self._documents_found,
                self._documents_scored,
                self._citations_extracted,
            )
        )


class AuditQueriesTab(QWidget):
    """
    Queries sub-tab for the Audit Trail.

    Displays a scrollable list of query cards showing
    generated PubMed queries and their statistics.

    Attributes:
        queries: Dictionary of query cards by query text
    """

    def __init__(self, parent: Optional[QWidget] = None) -> None:
        """
        Initialize the queries tab.

        Args:
            parent: Parent widget
        """
        super().__init__(parent)
        self._query_cards: Dict[str, QueryCard] = {}
        self._query_count = 0
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
            "No queries yet.\n\n"
            "Queries will appear here as they are generated\n"
            "during the systematic review workflow."
        )
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder.setStyleSheet("color: #888; font-size: 11pt;")
        self.cards_layout.addWidget(self.placeholder)

        self.scroll_area.setWidget(self.cards_container)
        layout.addWidget(self.scroll_area)

    def add_query(self, pubmed_query: str, nl_query: str) -> QueryCard:
        """
        Add a new query to the display.

        Args:
            pubmed_query: PubMed query string
            nl_query: Natural language query

        Returns:
            The created QueryCard
        """
        # Hide placeholder on first query
        if self._query_count == 0:
            self.placeholder.hide()

        self._query_count += 1

        # Create card
        card = QueryCard(
            pubmed_query=pubmed_query,
            nl_query=nl_query,
            index=self._query_count,
        )

        # Store and display
        self._query_cards[pubmed_query] = card
        self.cards_layout.addWidget(card)

        return card

    def get_query_card(self, pubmed_query: str) -> Optional[QueryCard]:
        """
        Get query card by query text.

        Args:
            pubmed_query: PubMed query string

        Returns:
            QueryCard if found, None otherwise
        """
        return self._query_cards.get(pubmed_query)

    def update_query_stats(
        self,
        pubmed_query: str,
        documents_found: Optional[int] = None,
        documents_scored: Optional[int] = None,
        citations_extracted: Optional[int] = None,
    ) -> None:
        """
        Update statistics for a query.

        Args:
            pubmed_query: PubMed query string to update
            documents_found: New documents found count
            documents_scored: New documents scored count
            citations_extracted: New citations extracted count
        """
        card = self._query_cards.get(pubmed_query)
        if not card:
            logger.warning(f"Query card not found for: {pubmed_query[:50]}...")
            return

        if documents_found is not None:
            card.set_documents_found(documents_found)
        if documents_scored is not None:
            card.set_documents_scored(documents_scored)
        if citations_extracted is not None:
            card.set_citations_extracted(citations_extracted)

    def clear(self) -> None:
        """Clear all queries from the display."""
        # Remove all cards
        for card in list(self._query_cards.values()):
            self.cards_layout.removeWidget(card)
            card.deleteLater()

        self._query_cards.clear()
        self._query_count = 0

        # Show placeholder
        self.placeholder.show()

    @property
    def query_count(self) -> int:
        """Get number of queries displayed."""
        return self._query_count
