"""
Tests for DocumentCard widget.

Tests the document card widget used in the audit trail.
"""

import pytest
from unittest.mock import MagicMock, patch

# Skip GUI tests if Qt not available
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication
from PySide6.QtCore import Qt

from bmlibrarian_lite.gui.document_card import DocumentCard, ScoreBadge
from bmlibrarian_lite.data_models import LiteDocument
from bmlibrarian_lite.quality.data_models import (
    QualityAssessment,
    StudyDesign,
    QualityTier,
)


@pytest.fixture(scope="module")
def qapp():
    """Create QApplication for tests."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    yield app


@pytest.fixture
def sample_document() -> LiteDocument:
    """Create a sample document for testing."""
    return LiteDocument(
        id="pmid-12345",
        title="Test Document Title",
        abstract="This is the abstract text for testing purposes.",
        authors=["Smith J", "Jones A", "Brown B"],
        year=2023,
        journal="Test Journal",
        pmid="12345",
        doi="10.1234/test.2023",
    )


class TestScoreBadge:
    """Tests for ScoreBadge widget."""

    def test_initialization(self, qapp) -> None:
        """Badge should initialize with score."""
        badge = ScoreBadge(score=4)
        assert badge.score == 4

    def test_score_display(self, qapp) -> None:
        """Badge should display score as fraction."""
        badge = ScoreBadge(score=4, max_score=5)
        assert badge.score_label.text() == "4/5"

    def test_set_score(self, qapp) -> None:
        """set_score should update the display."""
        badge = ScoreBadge(score=3)
        badge.set_score(5)
        assert badge.score == 5
        assert badge.score_label.text() == "5/5"

    def test_custom_max_score(self, qapp) -> None:
        """Custom max score should be reflected."""
        badge = ScoreBadge(score=8, max_score=10)
        assert badge.score_label.text() == "8/10"


class TestDocumentCard:
    """Tests for DocumentCard widget."""

    def test_initialization(self, qapp, sample_document) -> None:
        """Card should initialize with document."""
        card = DocumentCard(document=sample_document)
        assert card.document == sample_document
        assert card.doc_id == "pmid-12345"

    def test_title_displayed(self, qapp, sample_document) -> None:
        """Card should display document title."""
        card = DocumentCard(document=sample_document)
        assert card.title_label.text() == "Test Document Title"

    def test_authors_displayed(self, qapp, sample_document) -> None:
        """Card should display formatted authors in metadata."""
        card = DocumentCard(document=sample_document)
        # Authors are now displayed in the metadata label
        assert "Smith J" in card.metadata_label.text()

    def test_metadata_displayed(self, qapp, sample_document) -> None:
        """Card should display metadata."""
        card = DocumentCard(document=sample_document)
        metadata = card.metadata_label.text()
        assert "Test Journal" in metadata
        assert "2023" in metadata

    def test_score_not_shown_without_score(self, qapp, sample_document) -> None:
        """Card without score should not have score badge."""
        card = DocumentCard(document=sample_document)
        assert card._score_badge is None

    def test_score_shown_with_score(self, qapp, sample_document) -> None:
        """Card with score should have score badge."""
        card = DocumentCard(document=sample_document, score=4)
        assert card._score_badge is not None
        assert card.score == 4

    def test_set_score(self, qapp, sample_document) -> None:
        """set_score should update or create badge."""
        card = DocumentCard(document=sample_document)
        card.set_score(4)
        assert card.score == 4

    def test_clicked_signal(self, qapp, sample_document) -> None:
        """Clicking card should emit clicked signal with doc_id."""
        card = DocumentCard(document=sample_document)

        # Connect to signal
        received_doc_id = []
        card.clicked.connect(lambda doc_id: received_doc_id.append(doc_id))

        # Simulate click
        from PySide6.QtCore import QEvent
        from PySide6.QtGui import QMouseEvent

        event = QMouseEvent(
            QEvent.Type.MouseButtonPress,
            card.rect().center(),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
        )
        card.mousePressEvent(event)

        assert len(received_doc_id) == 1
        assert received_doc_id[0] == "pmid-12345"

    def test_cursor_is_pointer(self, qapp, sample_document) -> None:
        """Card should have pointer cursor."""
        card = DocumentCard(document=sample_document)
        assert card.cursor().shape() == Qt.CursorShape.PointingHandCursor

    def test_abstract_collapsed_by_default(self, qapp, sample_document) -> None:
        """Abstract should be collapsed by default."""
        card = DocumentCard(document=sample_document, show_abstract=False)
        # Card starts collapsed
        assert not card.expanded
        # Abstract widget exists but content section is hidden
        assert card._abstract_widget is not None
        # Use isHidden() on content widget since abstract is inside it
        assert card._content_widget.isHidden()

    def test_abstract_expanded_when_requested(self, qapp, sample_document) -> None:
        """Abstract should be expanded when show_abstract=True."""
        card = DocumentCard(document=sample_document, show_abstract=True)
        assert card.expanded
        # Content section is not hidden when expanded
        assert not card._content_widget.isHidden()

    def test_toggle_expand_collapse(self, qapp, sample_document) -> None:
        """Clicking card should toggle expand/collapse."""
        card = DocumentCard(document=sample_document)
        assert not card.expanded

        # Toggle to expand
        card._toggle_expanded()
        assert card.expanded
        assert not card._content_widget.isHidden()

        # Toggle to collapse
        card._toggle_expanded()
        assert not card.expanded
        assert card._content_widget.isHidden()

    def test_send_to_interrogator_signal(self, qapp, sample_document) -> None:
        """Context menu action should emit send_to_interrogator signal."""
        card = DocumentCard(document=sample_document)

        received = []
        card.send_to_interrogator.connect(lambda doc_id: received.append(doc_id))

        # Trigger the signal directly
        card._request_interrogation()

        assert len(received) == 1
        assert received[0] == "pmid-12345"

    def test_quality_badge_shown_at_init(self, qapp, sample_document) -> None:
        """Card with quality assessment should show badge at init."""
        assessment = QualityAssessment(
            assessment_tier=2,
            extraction_method="llm_haiku",
            study_design=StudyDesign.RCT,
            quality_tier=QualityTier.TIER_4_EXPERIMENTAL,
            quality_score=8.0,
            confidence=0.9,
        )
        card = DocumentCard(
            document=sample_document,
            quality_assessment=assessment,
        )
        assert card._quality_badge is not None
        assert card._quality_assessment == assessment

    def test_set_quality_assessment_creates_badge(self, qapp, sample_document) -> None:
        """set_quality_assessment should create badge dynamically."""
        card = DocumentCard(document=sample_document)
        assert card._quality_badge is None

        assessment = QualityAssessment(
            assessment_tier=2,
            extraction_method="llm_haiku",
            study_design=StudyDesign.SYSTEMATIC_REVIEW,
            quality_tier=QualityTier.TIER_5_SYNTHESIS,
            quality_score=10.0,
            confidence=0.95,
        )
        card.set_quality_assessment(assessment)

        assert card._quality_badge is not None
        assert card._quality_assessment == assessment

    def test_set_quality_assessment_updates_existing(self, qapp, sample_document) -> None:
        """set_quality_assessment should update existing badge."""
        initial_assessment = QualityAssessment(
            assessment_tier=1,
            extraction_method="metadata",
            study_design=StudyDesign.UNKNOWN,
            quality_tier=QualityTier.UNCLASSIFIED,
            quality_score=0.0,
            confidence=0.5,
        )
        card = DocumentCard(
            document=sample_document,
            quality_assessment=initial_assessment,
        )

        new_assessment = QualityAssessment(
            assessment_tier=2,
            extraction_method="llm_haiku",
            study_design=StudyDesign.COHORT_PROSPECTIVE,
            quality_tier=QualityTier.TIER_3_CONTROLLED,
            quality_score=6.0,
            confidence=0.85,
        )
        card.set_quality_assessment(new_assessment)

        assert card._quality_assessment == new_assessment
