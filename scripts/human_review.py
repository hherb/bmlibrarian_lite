#!/usr/bin/env python3
"""
Human Review Application for BMLibrarian Lite.

A standalone mini-application for human reviewers to score documents
for research questions. Scores are auto-saved to the database and can
be used alongside LLM evaluations for concordance analysis.

Features:
- Tab 1: Reviewer login and research question selection
- Tab 2: Document cards with quick score input (1-5)
- Auto-save on score entry
- No display of other evaluators' scores (blind review)

Usage:
    python scripts/human_review.py
"""

import logging
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional

from PySide6.QtCore import Qt, Signal, QTimer
from PySide6.QtGui import QFont, QIntValidator
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QFrame,
    QHBoxLayout,
    QLabel,
    QLineEdit,
    QListWidget,
    QListWidgetItem,
    QMainWindow,
    QMessageBox,
    QPushButton,
    QScrollArea,
    QSizePolicy,
    QSpacerItem,
    QStatusBar,
    QTabWidget,
    QTextEdit,
    QVBoxLayout,
    QWidget,
)

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import (
    AUDIT_CARD_BORDER_RADIUS,
    AUDIT_CARD_HEADER_COLOR,
    AUDIT_CARD_MIN_HEIGHT,
    AUDIT_CARD_PADDING,
    AUDIT_ABSTRACT_MAX_LINES,
)
from bmlibrarian_lite.data_models import (
    Evaluator,
    LiteDocument,
    ResearchQuestionSummary,
    ScoredDocument,
)
from bmlibrarian_lite.gui.card_utils import format_authors, format_metadata, get_score_color
from bmlibrarian_lite.resources.styles.dpi_scale import scaled
from bmlibrarian_lite.storage import LiteStorage

# Configure logging
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
logger = logging.getLogger(__name__)

# Application constants
WINDOW_TITLE = "BMLibrarian Lite - Human Review"
WINDOW_MIN_WIDTH = 900
WINDOW_MIN_HEIGHT = 700
STATUS_MESSAGE_TIMEOUT_MS = 3000


class ScoreInput(QFrame):
    """
    Compact score input widget with number field and color indicator.

    Allows quick entry of scores 1-5 via keyboard. Shows color-coded
    background based on current score.

    Signals:
        score_changed: Emitted when score changes (score: int)
    """

    score_changed = Signal(int)

    def __init__(
        self,
        initial_score: Optional[int] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the score input.

        Args:
            initial_score: Pre-existing score to display
            parent: Parent widget
        """
        super().__init__(parent)
        self._score: Optional[int] = initial_score
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the input UI."""
        layout = QHBoxLayout(self)
        layout.setContentsMargins(scaled(4), scaled(2), scaled(4), scaled(2))
        layout.setSpacing(scaled(4))

        # Score label
        score_label = QLabel("Score:")
        score_label.setStyleSheet("font-weight: bold;")
        layout.addWidget(score_label)

        # Score input field
        self.score_input = QLineEdit()
        self.score_input.setFixedWidth(scaled(40))
        self.score_input.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.score_input.setValidator(QIntValidator(1, 5))
        self.score_input.setPlaceholderText("1-5")
        self.score_input.setStyleSheet("""
            QLineEdit {
                font-size: 14pt;
                font-weight: bold;
                border: 2px solid #ccc;
                border-radius: 4px;
                padding: 2px;
            }
            QLineEdit:focus {
                border-color: #2196F3;
            }
        """)

        if self._score is not None:
            self.score_input.setText(str(self._score))

        # Connect signal
        self.score_input.textChanged.connect(self._on_text_changed)

        layout.addWidget(self.score_input)

        # Max score label
        max_label = QLabel("/ 5")
        layout.addWidget(max_label)

        # Update styling
        self._update_style()

    def _on_text_changed(self, text: str) -> None:
        """Handle text change in input."""
        if text and text.isdigit():
            score = int(text)
            if 1 <= score <= 5:
                self._score = score
                self._update_style()
                self.score_changed.emit(score)

    def _update_style(self) -> None:
        """Update styling based on current score."""
        if self._score is not None:
            color = get_score_color(self._score)
            self.setStyleSheet(f"""
                ScoreInput {{
                    background-color: {color};
                    border-radius: {scaled(4)}px;
                }}
            """)
            self.score_input.setStyleSheet("""
                QLineEdit {
                    font-size: 14pt;
                    font-weight: bold;
                    border: 2px solid white;
                    border-radius: 4px;
                    padding: 2px;
                    background-color: white;
                }
            """)
        else:
            self.setStyleSheet(f"""
                ScoreInput {{
                    background-color: #f0f0f0;
                    border-radius: {scaled(4)}px;
                }}
            """)

    @property
    def score(self) -> Optional[int]:
        """Get current score."""
        return self._score

    def set_score(self, score: Optional[int]) -> None:
        """Set the score value."""
        self._score = score
        if score is not None:
            self.score_input.setText(str(score))
        else:
            self.score_input.clear()
        self._update_style()

    def clear(self) -> None:
        """Clear the score."""
        self._score = None
        self.score_input.clear()
        self._update_style()


class ReviewDocumentCard(QFrame):
    """
    Document card for human review with score input.

    Shows document information and provides score input field.
    Auto-saves score when entered.

    Signals:
        score_submitted: Emitted when score is entered (doc_id: str, score: int)
    """

    score_submitted = Signal(str, int)

    def __init__(
        self,
        document: LiteDocument,
        existing_score: Optional[int] = None,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the review card.

        Args:
            document: Document to display
            existing_score: Pre-existing score from this reviewer
            parent: Parent widget
        """
        super().__init__(parent)
        self.document = document
        self._existing_score = existing_score
        self._expanded = False
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the card UI."""
        self.setFrameShape(QFrame.Shape.NoFrame)
        self.setMinimumHeight(scaled(AUDIT_CARD_MIN_HEIGHT))
        self.setSizePolicy(QSizePolicy.Policy.Expanding, QSizePolicy.Policy.Minimum)

        # Card styling
        self.setStyleSheet(f"""
            ReviewDocumentCard {{
                background-color: #FFFFFF;
                border: 1px solid #D0D0D0;
                border-radius: {scaled(AUDIT_CARD_BORDER_RADIUS)}px;
            }}
        """)

        # Main layout
        main_layout = QVBoxLayout(self)
        main_layout.setContentsMargins(0, 0, 0, 0)
        main_layout.setSpacing(0)

        # Header section
        header_widget = QWidget()
        header_widget.setStyleSheet(f"""
            QWidget {{
                background-color: {AUDIT_CARD_HEADER_COLOR};
                border: none;
            }}
        """)
        header_layout = QVBoxLayout(header_widget)
        header_layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(6),
            scaled(AUDIT_CARD_PADDING),
            scaled(6),
        )
        header_layout.setSpacing(scaled(4))

        # Title row with score input
        title_row = QHBoxLayout()
        title_row.setSpacing(scaled(8))

        # Score input
        self.score_input = ScoreInput(self._existing_score)
        self.score_input.score_changed.connect(self._on_score_changed)
        title_row.addWidget(self.score_input)

        # Title
        title_label = QLabel(self.document.title)
        title_label.setWordWrap(True)
        font = QFont()
        font.setPointSize(scaled(10))
        font.setBold(True)
        title_label.setFont(font)
        title_label.setStyleSheet("color: #1a1a1a; background: transparent;")
        title_row.addWidget(title_label, stretch=1)

        # Expand/collapse button
        self.expand_btn = QPushButton("Show Abstract")
        self.expand_btn.setFixedWidth(scaled(100))
        self.expand_btn.clicked.connect(self._toggle_expanded)
        self.expand_btn.setStyleSheet("""
            QPushButton {
                background-color: #e0e0e0;
                border: none;
                border-radius: 4px;
                padding: 4px 8px;
            }
            QPushButton:hover {
                background-color: #d0d0d0;
            }
        """)
        title_row.addWidget(self.expand_btn)

        header_layout.addLayout(title_row)

        # Metadata row
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
            metadata_label = QLabel(metadata_text)
            metadata_label.setWordWrap(True)
            metadata_label.setStyleSheet(
                "color: #555555; font-size: 9pt; background: transparent;"
            )
            header_layout.addWidget(metadata_label)

        main_layout.addWidget(header_widget)

        # Content section (expandable) - abstract
        self._content_widget = QWidget()
        self._content_widget.setStyleSheet("background: #FFFFFF; border: none;")
        content_layout = QVBoxLayout(self._content_widget)
        content_layout.setContentsMargins(
            scaled(AUDIT_CARD_PADDING),
            scaled(4),
            scaled(AUDIT_CARD_PADDING),
            scaled(AUDIT_CARD_PADDING),
        )

        # Abstract
        if self.document.abstract:
            abstract_widget = QTextEdit()
            abstract_widget.setPlainText(self.document.abstract)
            abstract_widget.setReadOnly(True)
            abstract_widget.setFrameShape(QFrame.Shape.NoFrame)

            # Calculate height based on line count
            font_metrics = abstract_widget.fontMetrics()
            line_height = font_metrics.lineSpacing()
            max_height = line_height * AUDIT_ABSTRACT_MAX_LINES + scaled(8)

            abstract_widget.setMaximumHeight(max_height)
            abstract_widget.setVerticalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAsNeeded
            )
            abstract_widget.setHorizontalScrollBarPolicy(
                Qt.ScrollBarPolicy.ScrollBarAlwaysOff
            )

            abstract_widget.setStyleSheet("""
                QTextEdit {
                    background-color: #FAFAFA;
                    color: #333;
                    font-size: 10pt;
                    padding: 4px;
                    border: none;
                }
            """)
            abstract_widget.document().setDocumentMargin(2)

            content_layout.addWidget(abstract_widget)

        main_layout.addWidget(self._content_widget)

        # Initially collapsed
        self._content_widget.setVisible(False)

    def _toggle_expanded(self) -> None:
        """Toggle abstract visibility."""
        self._expanded = not self._expanded
        self._content_widget.setVisible(self._expanded)
        self.expand_btn.setText("Hide Abstract" if self._expanded else "Show Abstract")

    def _on_score_changed(self, score: int) -> None:
        """Handle score change - emit signal for auto-save."""
        self.score_submitted.emit(self.document.id, score)

    def focus_score_input(self) -> None:
        """Focus the score input field."""
        self.score_input.score_input.setFocus()
        self.score_input.score_input.selectAll()


class ReviewerTab(QWidget):
    """
    Tab for reviewer login and research question selection.

    Allows reviewer to enter their name and select a research question
    to review.

    Signals:
        review_started: Emitted when ready to start review
            (evaluator: Evaluator, question: str)
    """

    review_started = Signal(object, str)

    def __init__(
        self,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the reviewer tab.

        Args:
            storage: Storage instance
            parent: Parent widget
        """
        super().__init__(parent)
        self.storage = storage
        self._current_evaluator: Optional[Evaluator] = None
        self._setup_ui()
        self._load_questions()

    def _setup_ui(self) -> None:
        """Set up the tab UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(scaled(20), scaled(20), scaled(20), scaled(20))
        layout.setSpacing(scaled(16))

        # Title
        title = QLabel("Human Document Review")
        title_font = QFont()
        title_font.setPointSize(scaled(16))
        title_font.setBold(True)
        title.setFont(title_font)
        title.setAlignment(Qt.AlignmentFlag.AlignCenter)
        layout.addWidget(title)

        # Instructions
        instructions = QLabel(
            "Enter your name and select a research question to review documents.\n"
            "Your scores will be saved automatically as you enter them."
        )
        instructions.setAlignment(Qt.AlignmentFlag.AlignCenter)
        instructions.setStyleSheet("color: #666; font-size: 10pt;")
        layout.addWidget(instructions)

        layout.addSpacing(scaled(20))

        # Reviewer name section
        name_section = QWidget()
        name_layout = QHBoxLayout(name_section)
        name_layout.setContentsMargins(0, 0, 0, 0)

        name_label = QLabel("Reviewer Name:")
        name_label.setStyleSheet("font-weight: bold;")
        name_layout.addWidget(name_label)

        self.name_input = QLineEdit()
        self.name_input.setPlaceholderText("Enter your name...")
        self.name_input.setMinimumWidth(scaled(300))
        self.name_input.textChanged.connect(self._on_name_changed)
        name_layout.addWidget(self.name_input)

        name_layout.addStretch()
        layout.addWidget(name_section)

        # Research question selection
        question_label = QLabel("Select Research Question:")
        question_label.setStyleSheet("font-weight: bold;")
        layout.addWidget(question_label)

        self.question_list = QListWidget()
        self.question_list.setMinimumHeight(scaled(300))
        self.question_list.itemSelectionChanged.connect(self._on_selection_changed)
        self.question_list.itemDoubleClicked.connect(self._on_start_review)
        layout.addWidget(self.question_list)

        # Start button
        self.start_button = QPushButton("Start Review")
        self.start_button.setEnabled(False)
        self.start_button.setMinimumHeight(scaled(40))
        self.start_button.setStyleSheet("""
            QPushButton {
                background-color: #2196F3;
                color: white;
                font-weight: bold;
                font-size: 12pt;
                border: none;
                border-radius: 6px;
            }
            QPushButton:disabled {
                background-color: #ccc;
            }
            QPushButton:hover:!disabled {
                background-color: #1976D2;
            }
        """)
        self.start_button.clicked.connect(self._on_start_review)
        layout.addWidget(self.start_button)

        layout.addStretch()

    def _load_questions(self) -> None:
        """Load research questions from database."""
        self.question_list.clear()

        questions = self.storage.get_unique_research_questions(limit=100)

        for q in questions:
            item = QListWidgetItem()
            # Format: question text with document count
            text = f"{q.question}\n   Documents: {q.total_documents}"
            item.setText(text)
            item.setData(Qt.ItemDataRole.UserRole, q.question)
            self.question_list.addItem(item)

        if not questions:
            item = QListWidgetItem("No research questions found in database")
            item.setFlags(item.flags() & ~Qt.ItemFlag.ItemIsEnabled)
            self.question_list.addItem(item)

    def _on_name_changed(self, text: str) -> None:
        """Handle name input change."""
        self._update_start_button()

    def _on_selection_changed(self) -> None:
        """Handle question selection change."""
        self._update_start_button()

    def _update_start_button(self) -> None:
        """Update start button enabled state."""
        has_name = bool(self.name_input.text().strip())
        has_selection = bool(self.question_list.selectedItems())
        self.start_button.setEnabled(has_name and has_selection)

    def _on_start_review(self) -> None:
        """Start the review process."""
        name = self.name_input.text().strip()
        if not name:
            QMessageBox.warning(self, "Name Required", "Please enter your name.")
            return

        selected_items = self.question_list.selectedItems()
        if not selected_items:
            QMessageBox.warning(
                self, "Question Required", "Please select a research question."
            )
            return

        question = selected_items[0].data(Qt.ItemDataRole.UserRole)

        # Create or get human evaluator
        evaluator = Evaluator.from_human(name=name)
        self.storage.upsert_evaluator(evaluator)
        self._current_evaluator = evaluator

        logger.info(f"Starting review: {name} reviewing '{question[:50]}...'")

        self.review_started.emit(evaluator, question)


class DocumentsTab(QWidget):
    """
    Tab for reviewing and scoring documents.

    Displays document cards with score inputs. Scores are auto-saved
    when entered.

    Signals:
        document_scored: Emitted when a document is scored
            (doc_id: str, score: int)
    """

    document_scored = Signal(str, int)

    def __init__(
        self,
        storage: LiteStorage,
        parent: Optional[QWidget] = None,
    ) -> None:
        """
        Initialize the documents tab.

        Args:
            storage: Storage instance
            parent: Parent widget
        """
        super().__init__(parent)
        self.storage = storage
        self._evaluator: Optional[Evaluator] = None
        self._question: Optional[str] = None
        self._documents: list[LiteDocument] = []
        self._document_cards: dict[str, ReviewDocumentCard] = {}
        self._checkpoint_id: Optional[str] = None
        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the tab UI."""
        layout = QVBoxLayout(self)
        layout.setContentsMargins(scaled(12), scaled(12), scaled(12), scaled(12))
        layout.setSpacing(scaled(8))

        # Header
        header = QWidget()
        header_layout = QHBoxLayout(header)
        header_layout.setContentsMargins(0, 0, 0, 0)

        self.question_label = QLabel("No question selected")
        self.question_label.setWordWrap(True)
        self.question_label.setStyleSheet("font-weight: bold; font-size: 11pt;")
        header_layout.addWidget(self.question_label, stretch=1)

        self.progress_label = QLabel("")
        self.progress_label.setStyleSheet("color: #666;")
        header_layout.addWidget(self.progress_label)

        layout.addWidget(header)

        # Scroll area for document cards
        scroll_area = QScrollArea()
        scroll_area.setWidgetResizable(True)
        scroll_area.setHorizontalScrollBarPolicy(Qt.ScrollBarPolicy.ScrollBarAlwaysOff)
        scroll_area.setStyleSheet("""
            QScrollArea {
                border: none;
                background-color: #f5f5f5;
            }
        """)

        # Container for cards
        self.cards_container = QWidget()
        self.cards_layout = QVBoxLayout(self.cards_container)
        self.cards_layout.setContentsMargins(0, 0, scaled(8), 0)
        self.cards_layout.setSpacing(scaled(8))
        self.cards_layout.addStretch()

        scroll_area.setWidget(self.cards_container)
        layout.addWidget(scroll_area)

        # Placeholder when no documents
        self.placeholder = QLabel("Select a research question to begin reviewing")
        self.placeholder.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.placeholder.setStyleSheet("color: #999; font-size: 12pt;")
        self.cards_layout.insertWidget(0, self.placeholder)

    def load_documents(self, evaluator: Evaluator, question: str) -> None:
        """
        Load documents for the selected question.

        Args:
            evaluator: Human evaluator
            question: Research question text
        """
        self._evaluator = evaluator
        self._question = question

        # Update header
        display_question = (
            question[:100] + "..." if len(question) > 100 else question
        )
        self.question_label.setText(f"Reviewing: {display_question}")

        # Clear existing cards
        self._clear_cards()

        # Get documents for this question
        doc_ids = self.storage.get_document_ids_for_question(question)
        self._documents = []

        for doc_id in doc_ids:
            doc = self.storage.get_document(doc_id)
            if doc:
                self._documents.append(doc)

        # Create a checkpoint for this review session
        checkpoint = self.storage.create_checkpoint(
            research_question=question,
            metadata={
                "evaluator_id": evaluator.id,
                "evaluator_name": evaluator.display_name,
                "run_type": "human_review",
                "started_at": datetime.now().isoformat(),
            },
        )
        self._checkpoint_id = checkpoint.id

        # Hide placeholder
        self.placeholder.setVisible(False)

        # Create cards for each document
        scored_count = 0
        for doc in self._documents:
            # Check for existing score from this evaluator FOR THIS QUESTION
            existing_scored = self.storage.get_scored_document_for_question(
                doc.id, evaluator.id, question
            )
            existing_score = (
                existing_scored.score
                if existing_scored and existing_scored.score > 0
                else None
            )

            if existing_score is not None:
                scored_count += 1

            card = ReviewDocumentCard(doc, existing_score=existing_score)
            card.score_submitted.connect(self._on_score_submitted)
            self._document_cards[doc.id] = card

            # Insert before stretch
            self.cards_layout.insertWidget(
                self.cards_layout.count() - 1, card
            )

        # Update progress
        self._update_progress(scored_count)

        logger.info(
            f"Loaded {len(self._documents)} documents for review, "
            f"{scored_count} already scored"
        )

    def _clear_cards(self) -> None:
        """Remove all document cards."""
        for card in self._document_cards.values():
            card.deleteLater()
        self._document_cards.clear()

    def _on_score_submitted(self, doc_id: str, score: int) -> None:
        """
        Handle score submission - auto-save to database.

        Args:
            doc_id: Document ID
            score: Score value (1-5)
        """
        if not self._evaluator or not self._checkpoint_id:
            return

        # Find the document
        doc = next((d for d in self._documents if d.id == doc_id), None)
        if not doc:
            return

        # Create scored document
        scored_doc = ScoredDocument(
            document=doc,
            score=score,
            explanation="Human review",
            evaluator_id=self._evaluator.id,
            evaluator=self._evaluator,
        )

        # Check if already scored by this evaluator - if so, update
        existing = self.storage.get_scored_document_by_evaluator(
            doc_id, self._evaluator.id
        )

        if existing:
            # Update existing score by saving new one (overwrites)
            self.storage.save_scored_document(scored_doc, self._checkpoint_id)
            logger.info(f"Updated score for {doc_id}: {score}")
        else:
            # New score
            self.storage.save_scored_document(scored_doc, self._checkpoint_id)
            logger.info(f"Saved new score for {doc_id}: {score}")

        # Update progress
        self._update_progress()

        # Emit signal
        self.document_scored.emit(doc_id, score)

    def _update_progress(self, scored_count: Optional[int] = None) -> None:
        """Update the progress label."""
        if scored_count is None:
            # Count scored documents for this question
            scored_count = 0
            for doc in self._documents:
                if self._evaluator and self._question:
                    existing = self.storage.get_scored_document_for_question(
                        doc.id, self._evaluator.id, self._question
                    )
                    if existing and existing.score > 0:
                        scored_count += 1

        total = len(self._documents)
        self.progress_label.setText(f"Scored: {scored_count} / {total}")


class HumanReviewApp(QMainWindow):
    """
    Main application window for human review.

    Two-tab interface:
    - Tab 1: Reviewer login and question selection
    - Tab 2: Document scoring
    """

    def __init__(self) -> None:
        """Initialize the application."""
        super().__init__()

        # Load config and storage
        self.config = LiteConfig.load()
        self.storage = LiteStorage(self.config)

        self._setup_ui()

    def _setup_ui(self) -> None:
        """Set up the main window UI."""
        self.setWindowTitle(WINDOW_TITLE)
        self.setMinimumSize(WINDOW_MIN_WIDTH, WINDOW_MIN_HEIGHT)

        # Central widget with tabs
        self.tab_widget = QTabWidget()
        self.setCentralWidget(self.tab_widget)

        # Tab 1: Reviewer selection
        self.reviewer_tab = ReviewerTab(self.storage)
        self.reviewer_tab.review_started.connect(self._on_review_started)
        self.tab_widget.addTab(self.reviewer_tab, "Reviewer & Question")

        # Tab 2: Documents
        self.documents_tab = DocumentsTab(self.storage)
        self.documents_tab.document_scored.connect(self._on_document_scored)
        self.tab_widget.addTab(self.documents_tab, "Documents")

        # Disable documents tab until review is started
        self.tab_widget.setTabEnabled(1, False)

        # Status bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.status_bar.showMessage("Enter your name and select a research question")

    def _on_review_started(self, evaluator: Evaluator, question: str) -> None:
        """
        Handle review start.

        Args:
            evaluator: Human evaluator
            question: Research question
        """
        # Load documents in documents tab
        self.documents_tab.load_documents(evaluator, question)

        # Enable and switch to documents tab
        self.tab_widget.setTabEnabled(1, True)
        self.tab_widget.setCurrentIndex(1)

        self.status_bar.showMessage(
            f"Reviewing as {evaluator.display_name}", STATUS_MESSAGE_TIMEOUT_MS
        )

    def _on_document_scored(self, doc_id: str, score: int) -> None:
        """
        Handle document scored.

        Args:
            doc_id: Document ID
            score: Score value
        """
        self.status_bar.showMessage(
            f"Score saved: {score}/5", STATUS_MESSAGE_TIMEOUT_MS
        )


def main() -> None:
    """Main entry point."""
    app = QApplication(sys.argv)
    app.setStyle("Fusion")

    window = HumanReviewApp()
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
