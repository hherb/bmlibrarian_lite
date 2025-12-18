"""
Document card widget for audit trail display.

Provides clickable document cards that display document metadata,
relevance scores, quality badges, and LLM rationales. Used in the
Literature and Citations sub-tabs of the Audit Trail.

Cards are collapsible - clicking expands to show the abstract and rationales.
Right-click context menu allows sending document to interrogator.
"""

import logging
from typing import Optional, List

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
    AUDIT_CARD_HEADER_COLOR,
    AUDIT_RATIONALE_COLOR,
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
            scaled(6), scaled(2), scaled(6), scaled(2)
        )
        layout.setSpacing(0)

        # Score label
        self.score_label = QLabel(f"{self._score}/{self._max_score}")
        self.score_label.setAlignment(Qt.AlignmentFlag.AlignCenter)

        # Style font
        font = QFont()
        font.setPointSize(scaled(9))
        font.setBold(True)
        self.score_label.setFont(font)

        # Apply colors
        color = get_score_color(self._score)
        self.setStyleSheet(f"""
            QFrame {{
                background-color: {color};
                border-radius: {scaled(3)}px;
                border: none;
            }}
        """)
        self.score_label.setStyleSheet("""
            QLabel {
                color: white;
                padding: 0px;
                background: transparent;
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
                border-radius: {scaled(3)}px;
                border: none;
            }}
        """)


class DocumentCard(QFrame):
    """
    Collapsible card displaying document information.

    Shows document title, authors, metadata, and optional score/quality badges.
    When expanded, shows abstract and LLM rationales for scoring/quality.
    Click to expand/collapse. Right-click for context menu.

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
        score_rationale: Optional[str] = None,
        quality_assessment: Optional[QualityAssessment] = None,
        citation_rationale: Optional[str] = None,
        show_abstract: bool = False,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the document card.

        Args:
            document: Document to display
            score: Optional relevance score (1-5)
            score_rationale: LLM explanation for the score
            quality_assessment: Optional quality assessment
            citation_rationale: Why this passage was selected as citation
            show_abstract: Whether to initially show abstract (expanded state)
            parent: Parent widget
        """
        super().__init__(parent)
        self.document = document
        self._score = score
        self._score_rationale = score_rationale
        self._quality_assessment = quality_assessment
        self._citation_rationale = citation_rationale
        self._expanded = show_abstract

        # Track child widgets for updates
        self._score_badge: Optional[ScoreBadge] = None
        self._quality_badge: Optional[QualityBadge] = None
        self._abstract_widget: Optional[QTextEdit] = None
        self._rationale_widget: Optional[QLabel] = None
        self._header_widget: Optional[QWidget] = None

        self._setup_ui()
        self._setup_interaction()

    def _setup_ui(self) -> None:
        """Set up the card UI."""
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setMinimumHeight(scaled(AUDIT_CARD_MIN_HEIGHT))
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)

        # Card styling - single border around entire card
        self._update_card_style()

        # Main layout - minimal spacing
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # Header section with colored background
        self._header_widget = QWidget()
        self._header_widget.setStyleSheet(f"""
            QWidget {{
                background-color: {AUDIT_CARD_HEADER_COLOR};
                border: none;
            }}
        """)
        header_layout = QVBoxLayout(self._header_widget)
        header_layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(6),
            scaled(AUDIT_CARD_PADDING),
            scaled(6),
        )
        header_layout.setSpacing(scaled(2))

        # Title row with badges
        title_row = QHBoxLayout()
        title_row.setSpacing(scaled(6))

        # Quality badge (if available)
        if self._quality_assessment:
            self._quality_badge = QualityBadge(
                self._quality_assessment,
                show_design=True,
            )
            title_row.addWidget(self._quality_badge)

        # Score badge (if available)
        if self._score is not None:
            self._score_badge = ScoreBadge(self._score)
            title_row.addWidget(self._score_badge)

        # Title
        self.title_label = QLabel(self.document.title)
        self.title_label.setWordWrap(True)
        font = QFont()
        font.setPointSize(scaled(10))
        font.setBold(True)
        self.title_label.setFont(font)
        self.title_label.setStyleSheet("color: #1a1a1a; background: transparent;")
        title_row.addWidget(self.title_label, stretch=1)

        header_layout.addLayout(title_row)

        # Metadata row: authors | journal (year) | PMID - compact
        metadata_parts = []

        if self.document.authors:
            authors_text = format_authors(self.document.authors, max_authors=2)
            metadata_parts.append(authors_text)

        journal_year = format_metadata(
            year=self.document.year,
            journal=self.document.journal,
        )
        if journal_year and journal_year != "No metadata available":
            metadata_parts.append(journal_year)

        if self.document.pmid:
            metadata_parts.append(f"PMID: {self.document.pmid}")
        elif self.document.doi:
            metadata_parts.append(f"DOI: {self.document.doi}")

        metadata_text = " | ".join(metadata_parts) if metadata_parts else ""
        if metadata_text:
            self.metadata_label = QLabel(metadata_text)
            self.metadata_label.setWordWrap(True)
            self.metadata_label.setStyleSheet(
                "color: #555555; font-size: 9pt; background: transparent;"
            )
            header_layout.addWidget(self.metadata_label)

        main_layout.addWidget(self._header_widget)

        # Content section (expandable) - abstract and rationales
        self._content_widget = QWidget()
        self._content_widget.setStyleSheet("background: #FFFFFF; border: none;")
        content_layout = QVBoxLayout(self._content_widget)
        content_layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(4),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )
        content_layout.setSpacing(scaled(4))

        # Abstract
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

            self._abstract_widget.setStyleSheet("""
                QTextEdit {
                    background-color: #FAFAFA;
                    color: #333;
                    font-size: 10pt;
                    padding: 2px;
                    margin: 0px;
                    border: none;
                }
            """)
            # Remove document margin that causes large gap
            self._abstract_widget.document().setDocumentMargin(2)

            content_layout.addWidget(self._abstract_widget)

        # Rationale section - shows LLM reasoning
        rationale_text = self._build_rationale_text()
        if rationale_text:
            self._rationale_widget = QLabel(rationale_text)
            self._rationale_widget.setWordWrap(True)
            self._rationale_widget.setStyleSheet(f"""
                QLabel {{
                    color: {AUDIT_RATIONALE_COLOR};
                    font-size: 9pt;
                    font-style: italic;
                    background: transparent;
                    padding: 0px;
                    margin: 0px;
                }}
            """)
            content_layout.addWidget(self._rationale_widget)

        main_layout.addWidget(self._content_widget)

        # Set initial visibility of content
        self._content_widget.setVisible(self._expanded)

    def _build_rationale_text(self) -> str:
        """
        Build combined rationale text from all sources.

        Returns:
            Combined rationale string or empty string
        """
        parts: List[str] = []

        # Score rationale
        if self._score_rationale:
            parts.append(f"Score: {self._score_rationale}")

        # Quality assessment rationale
        if self._quality_assessment and self._quality_assessment.extraction_details:
            quality_text = "; ".join(self._quality_assessment.extraction_details)
            parts.append(f"Quality: {quality_text}")

        # Citation rationale
        if self._citation_rationale:
            parts.append(f"Citation: {self._citation_rationale}")

        return " | ".join(parts)

    def _update_card_style(self) -> None:
        """Update card styling based on expanded state."""
        border_color = "#2196F3" if self._expanded else "#D0D0D0"

        self.setStyleSheet(f"""
            DocumentCard {{
                background-color: #FFFFFF;
                border: 1px solid {border_color};
                border-radius: {scaled(AUDIT_CARD_BORDER_RADIUS)}px;
            }}
            DocumentCard:hover {{
                border-color: #2196F3;
            }}
        """)

    def _setup_interaction(self) -> None:
        """Set up mouse interaction."""
        self.setCursor(QCursor(Qt.CursorShape.PointingHandCursor))
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

        if hasattr(self, "_content_widget") and self._content_widget:
            self._content_widget.setVisible(self._expanded)

        self._update_card_style()
        self.clicked.emit(self.document.id)

    def _show_context_menu(self, position) -> None:
        """Show right-click context menu."""
        menu = QMenu(self)

        interrogate_action = QAction("Send to Interrogator", self)
        interrogate_action.triggered.connect(self._request_interrogation)
        menu.addAction(interrogate_action)

        if self.document.pmid:
            copy_pmid_action = QAction(f"Copy PMID ({self.document.pmid})", self)
            copy_pmid_action.triggered.connect(self._copy_pmid)
            menu.addAction(copy_pmid_action)

        if self.document.doi:
            copy_doi_action = QAction("Copy DOI", self)
            copy_doi_action.triggered.connect(self._copy_doi)
            menu.addAction(copy_doi_action)

        menu.addSeparator()

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

    def set_score(self, score: int, rationale: Optional[str] = None) -> None:
        """
        Update the document score.

        Creates score badge if not present, otherwise updates existing.

        Args:
            score: New relevance score (1-5)
            rationale: LLM explanation for the score
        """
        self._score = score
        if rationale:
            self._score_rationale = rationale
            self._update_rationale_display()

        if self._score_badge:
            self._score_badge.set_score(score)
        else:
            self._score_badge = ScoreBadge(score)

            # Find title row in header and insert badge
            if self._header_widget:
                header_layout = self._header_widget.layout()
                if header_layout and header_layout.count() > 0:
                    title_row_item = header_layout.itemAt(0)
                    if title_row_item and title_row_item.layout():
                        title_row = title_row_item.layout()
                        insert_index = 1 if self._quality_badge else 0
                        title_row.insertWidget(insert_index, self._score_badge)

    def set_quality_assessment(self, assessment: QualityAssessment) -> None:
        """
        Update the quality assessment.

        Creates quality badge if not present, otherwise updates existing.

        Args:
            assessment: New quality assessment
        """
        self._quality_assessment = assessment
        self._update_rationale_display()

        if self._quality_badge:
            self._quality_badge.update_assessment(assessment)
        else:
            self._quality_badge = QualityBadge(
                assessment,
                show_design=True,
            )

            # Find title row in header and insert badge at beginning
            if self._header_widget:
                header_layout = self._header_widget.layout()
                if header_layout and header_layout.count() > 0:
                    title_row_item = header_layout.itemAt(0)
                    if title_row_item and title_row_item.layout():
                        title_row = title_row_item.layout()
                        title_row.insertWidget(0, self._quality_badge)
                        logger.debug(
                            f"Quality badge added for {self.document.id}: "
                            f"{assessment.study_design.value}"
                        )

    def set_citation_rationale(self, rationale: str) -> None:
        """
        Set the citation rationale.

        Args:
            rationale: Why this passage was selected
        """
        self._citation_rationale = rationale
        self._update_rationale_display()

    def _update_rationale_display(self) -> None:
        """Update the rationale label with current rationales."""
        rationale_text = self._build_rationale_text()

        if self._rationale_widget:
            if rationale_text:
                self._rationale_widget.setText(rationale_text)
                self._rationale_widget.setVisible(True)
            else:
                self._rationale_widget.setVisible(False)
        elif rationale_text and hasattr(self, "_content_widget") and self._content_widget:
            # Create rationale widget if it doesn't exist
            self._rationale_widget = QLabel(rationale_text)
            self._rationale_widget.setWordWrap(True)
            self._rationale_widget.setStyleSheet(f"""
                QLabel {{
                    color: {AUDIT_RATIONALE_COLOR};
                    font-size: 9pt;
                    font-style: italic;
                    background: transparent;
                    padding: 0px;
                    margin: 0px;
                }}
            """)
            content_layout = self._content_widget.layout()
            if content_layout:
                content_layout.addWidget(self._rationale_widget)

    @property
    def doc_id(self) -> str:
        """Get document ID."""
        return self.document.id
