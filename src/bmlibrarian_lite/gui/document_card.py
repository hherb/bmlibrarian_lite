"""
Document card widget for audit trail display.

Provides clickable document cards that display document metadata,
relevance scores, and quality badges. Used in the Literature and
Citations sub-tabs of the Audit Trail.

Cards are collapsible - clicking expands to show the abstract.
Right-click context menu allows sending document to interrogator.
"""

import logging
from typing import Optional

from PySide6.QtCore import Qt, Signal
from PySide6.QtWidgets import (
    QFrame,
    QVBoxLayout,
    QHBoxLayout,
    QLabel,
    QWidget,
    QSizePolicy,
    QTextEdit,
    QMenu,
)
from PySide6.QtGui import QFont, QCursor, QAction

from bmlibrarian_lite.resources.styles.dpi_scale import scaled

from ..constants import (
    AUDIT_CARD_PADDING,
    AUDIT_CARD_BORDER_RADIUS,
    AUDIT_CARD_MIN_HEIGHT,
    AUDIT_ABSTRACT_MAX_LINES,
)
from ..data_models import LiteDocument
from ..quality.data_models import QualityAssessment
from .card_utils import format_authors, format_metadata, get_score_color
from .quality_badge import QualityBadge

logger = logging.getLogger(__name__)


class ScoreBadge(QFrame):
    """
    Color-coded badge displaying relevance score.

    Shows score as fraction (e.g., "4/5") with background color
    indicating quality level.

    Attributes:
        score: Current relevance score (1-5)
    """

    def __init__(
        self,
        score: int,
        max_score: int = 5,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the score badge.

        Args:
            score: Relevance score (1-5)
            max_score: Maximum possible score
            parent: Parent widget
        """
        super().__init__(parent)
        self._score = score
        self._max_score = max_score
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the badge UI."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(
            scaled(8), scaled(4), scaled(8), scaled(4)
        )
        layout.setSpacing(scaled(4))

        # Score label
        self.score_label = QLabel(f"{self._score}/{self._max_score}")
        self.score_label.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # Style font
        font = QFont()
        font.setPointSize(scaled(10))
        font.setBold(True)
        self.score_label.setFont(font)

        # Apply colors
        color = get_score_color(self._score)
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {color};
                border-radius: {scaled(4)}px;
            }}
        """)
        self.score_label.setStyleSheet("""
            QLabel {
                color: white;
                padding: 0px;
            }
        """)

        layout.addWidget(self.score_label)

    @property
    def score(self) -> int:
        """Get current score."""
        return self._score

    def set_score(self, score: int) -> None:
        """
        Update the displayed score.

        Args:
            score: New score value (1-5)
        """
        self._score = score
        self.score_label.setText(f"{self._score}/{self._max_score}")

        # Update color
        color = get_score_color(self._score)
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {color};
                border-radius: {scaled(4)}px;
            }}
        """)


class DocumentCard(QFrame):
    """
    Collapsible card displaying document information.

    Shows document title, authors, metadata, and optional score/quality badges.
    Click to expand/collapse abstract. Right-click for context menu.

    Signals:
        clicked: Emitted when card is clicked (doc_id: str)
        send_to_interrogator: Emitted when user requests to interrogate document

    Attributes:
        document: The document this card represents
        score: Optional relevance score (1-5)
        quality_assessment: Optional quality assessment
    """

    clicked = Signal(str)  # Emits document ID
    send_to_interrogator = Signal(str)  # Emits document ID for interrogation

    def __init__(
        self,
        document: LiteDocument,
        score: Optional[int] = None,
        quality_assessment: Optional[QualityAssessment] = None,
        show_abstract: bool = False,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the document card.

        Args:
            document: Document to display
            score: Optional relevance score (1-5)
            quality_assessment: Optional quality assessment
            show_abstract: Whether to initially show abstract (expanded state)
            parent: Parent widget
        """
        super().__init__(parent)
        self.document = document
        self._score = score
        self._quality_assessment = quality_assessment
        self._expanded = show_abstract

        # Track child widgets for updates
        self._score_badge: Optional[ScoreBadge] = None
        self._quality_badge: Optional[QualityBadge] = None
        self._abstract_widget: Optional[QTextEdit] = None

        self._setup_ui()
        self._setup_interaction()

    def _setup_ui(self) -> None:
        """Set up the card UI."""
        self.setFrameShape(QFrame.Shape.StyledPanel)
        self.setMinimumHeight(scaled(AUDIT_CARD_MIN_HEIGHT))
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)

        # Card styling
        self._update_card_style()

        # Main layout
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )
        main_layout.setSpacing(scaled(4))

        # Header row: quality badge + score badge + title
        header_layout = QHBoxLayout()
        header_layout.setSpacing(scaled(8))

        # Quality badge (if available)
        if self._quality_assessment:
            self._quality_badge = QualityBadge(
                self._quality_assessment,
                show_design=True,
            )
            header_layout.addWidget(self._quality_badge)

        # Score badge inline with title (if available)
        if self._score is not None:
            self._score_badge = ScoreBadge(self._score)
            header_layout.addWidget(self._score_badge)

        # Title
        self.title_label = QLabel(self.document.title)
        self.title_label.setWordWrap(True)
        font = QFont()
        font.setPointSize(scaled(11))
        font.setBold(True)
        self.title_label.setFont(font)
        self.title_label.setStyleSheet("color: #1a1a1a; background: transparent;")
        header_layout.addWidget(self.title_label, stretch=1)

        main_layout.addLayout(header_layout)

        # Metadata row: authors | journal (year) | PMID
        metadata_parts = []

        # Authors (abbreviated)
        if self.document.authors:
            authors_text = format_authors(self.document.authors, max_authors=2)
            metadata_parts.append(authors_text)

        # Journal and year
        journal_year = format_metadata(
            year=self.document.year,
            journal=self.document.journal,
        )
        if journal_year and journal_year != "No metadata available":
            metadata_parts.append(journal_year)

        # PMID/DOI
        if self.document.pmid:
            metadata_parts.append(f"PMID: {self.document.pmid}")
        elif self.document.doi:
            metadata_parts.append(f"DOI: {self.document.doi}")

        metadata_text = " | ".join(metadata_parts) if metadata_parts else ""
        if metadata_text:
            self.metadata_label = QLabel(metadata_text)
            self.metadata_label.setWordWrap(True)
            self.metadata_label.setStyleSheet(
                "color: #666666; font-size: 9pt; background: transparent;"
            )
            main_layout.addWidget(self.metadata_label)

        # Abstract (collapsible) - create but hide initially unless expanded
        if self.document.abstract:
            self._abstract_widget = QTextEdit()
            self._abstract_widget.setPlainText(self.document.abstract)
            self._abstract_widget.setReadOnly(True)
            self._abstract_widget.setFrameShape(QFrame.Shape.NoFrame)

            # Calculate height based on line count
            font_metrics = self._abstract_widget.fontMetrics()
            line_height = font_metrics.lineSpacing()
            max_height = line_height * AUDIT_ABSTRACT_MAX_LINES + scaled(8)

            self._abstract_widget.setMaximumHeight(max_height)
            self._abstract_widget.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAsNeeded
            )
            self._abstract_widget.setHorizontalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAlwaysOff
            )

            # Minimal styling - no large margins
            self._abstract_widget.setStyleSheet("""
                QTextEdit {
                    background-color: #F8F8F8;
                    color: #333;
                    font-size: 10pt;
                    padding: 4px;
                    border: none;
                    border-top: 1px solid #E0E0E0;
                }
            """)

            main_layout.addWidget(self._abstract_widget)

            # Set initial visibility
            self._abstract_widget.setVisible(self._expanded)

    def _update_card_style(self) -> None:
        """Update card styling based on expanded state."""
        border_color = "#2196F3" if self._expanded else "#E0E0E0"
        bg_color = "#FFFFFF"

        self.setStyleSheet(f"""
            QFrame {{
                background-color: {bg_color};
                border: 1px solid {border_color};
                border-radius: {scaled(AUDIT_CARD_BORDER_RADIUS)}px;
            }}
            QFrame:hover {{
                background-color: #FAFAFA;
                border-color: #2196F3;
            }}
        """)

    def _setup_interaction(self) -> None:
        """Set up mouse interaction."""
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
        # Enable context menu
        self.setContextMenuPolicy(Qt.ContextMenuPolicy.CustomContextMenu)
        self.customContextMenuRequested.connect(self._show_context_menu)

    def mousePressEvent(self, event) -> None:
        """Handle mouse press - toggle expand/collapse on left click."""
        if event.button() == Qt.MouseButton.LeftButton:
            self._toggle_expanded()
        super().mousePressEvent(event)

    def _toggle_expanded(self) -> None:
        """Toggle the expanded/collapsed state."""
        self._expanded = not self._expanded

        if self._abstract_widget:
            self._abstract_widget.setVisible(self._expanded)

        self._update_card_style()

        # Emit clicked signal
        self.clicked.emit(self.document.id)

    def _show_context_menu(self, position) -> None:
        """Show right-click context menu."""
        menu = QMenu(self)

        # Send to Interrogator action
        interrogate_action = QAction("Send to Interrogator", self)
        interrogate_action.triggered.connect(self._request_interrogation)
        menu.addAction(interrogate_action)

        # Copy PMID action (if available)
        if self.document.pmid:
            copy_pmid_action = QAction(f"Copy PMID ({self.document.pmid})", self)
            copy_pmid_action.triggered.connect(self._copy_pmid)
            menu.addAction(copy_pmid_action)

        # Copy DOI action (if available)
        if self.document.doi:
            copy_doi_action = QAction("Copy DOI", self)
            copy_doi_action.triggered.connect(self._copy_doi)
            menu.addAction(copy_doi_action)

        menu.addSeparator()

        # Expand/Collapse action
        if self._expanded:
            collapse_action = QAction("Collapse", self)
            collapse_action.triggered.connect(self._toggle_expanded)
            menu.addAction(collapse_action)
        else:
            expand_action = QAction("Expand", self)
            expand_action.triggered.connect(self._toggle_expanded)
            menu.addAction(expand_action)

        menu.exec(self.mapToGlobal(position))

    def _request_interrogation(self) -> None:
        """Request to send this document to the interrogator."""
        logger.info(f"Requesting interrogation for document: {self.document.id}")
        self.send_to_interrogator.emit(self.document.id)

    def _copy_pmid(self) -> None:
        """Copy PMID to clipboard."""
        from PySide6.QtWidgets import QApplication
        clipboard = QApplication.clipboard()
        clipboard.setText(self.document.pmid)

    def _copy_doi(self) -> None:
        """Copy DOI to clipboard."""
        from PySide6.QtWidgets import QApplication
        clipboard = QApplication.clipboard()
        clipboard.setText(self.document.doi)

    @property
    def score(self) -> Optional[int]:
        """Get current score."""
        return self._score

    @property
    def expanded(self) -> bool:
        """Get expanded state."""
        return self._expanded

    def set_expanded(self, expanded: bool) -> None:
        """
        Set the expanded state.

        Args:
            expanded: Whether card should be expanded
        """
        if self._expanded != expanded:
            self._toggle_expanded()

    def set_score(self, score: int) -> None:
        """
        Update the document score.

        Creates score badge if not present, otherwise updates existing.

        Args:
            score: New relevance score (1-5)
        """
        self._score = score

        if self._score_badge:
            self._score_badge.set_score(score)
        else:
            # Create score badge dynamically and insert into header
            self._score_badge = ScoreBadge(score)

            # Find header layout (first layout in main layout)
            main_layout = self.layout()
            if main_layout and main_layout.count() > 0:
                header_item = main_layout.itemAt(0)
                if header_item and header_item.layout():
                    header_layout = header_item.layout()
                    # Insert after quality badge (index 0 or 1)
                    insert_index = 1 if self._quality_badge else 0
                    header_layout.insertWidget(insert_index, self._score_badge)

    def set_quality_assessment(self, assessment: QualityAssessment) -> None:
        """
        Update the quality assessment.

        Creates quality badge if not present, otherwise updates existing.

        Args:
            assessment: New quality assessment
        """
        self._quality_assessment = assessment

        if self._quality_badge:
            self._quality_badge.update_assessment(assessment)
        else:
            # Create and insert badge into header layout
            self._quality_badge = QualityBadge(
                assessment,
                show_design=True,
            )

            # Find header layout (first layout in main layout)
            main_layout = self.layout()
            if main_layout and main_layout.count() > 0:
                header_item = main_layout.itemAt(0)
                if header_item and header_item.layout():
                    header_layout = header_item.layout()
                    # Insert badge at beginning of header
                    header_layout.insertWidget(0, self._quality_badge)
                    logger.debug(
                        f"Quality badge added for {self.document.id}: "
                        f"{assessment.study_design.value}"
                    )

    @property
    def doc_id(self) -> str:
        """Get document ID."""
        return self.document.id
