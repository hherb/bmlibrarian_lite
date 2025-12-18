"""
Tests for AuditTrailTab and sub-tabs.

Tests the audit trail functionality including queries,
literature, and citations sub-tabs.
"""

import pytest
from unittest.mock import MagicMock, patch

# Skip GUI tests if Qt not available
pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication

from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab
from bmlibrarian_lite.gui.audit_queries_tab import AuditQueriesTab, QueryCard
from bmlibrarian_lite.gui.audit_literature_tab import AuditLiteratureTab
from bmlibrarian_lite.gui.audit_citations_tab import AuditCitationsTab, CitationCard
from bmlibrarian_lite.data_models import LiteDocument, ScoredDocument, Citation
from bmlibrarian_lite.config import LiteConfig


@pytest.fixture(scope="module")
def qapp():
    """Create QApplication for tests."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    yield app


@pytest.fixture
def mock_config():
    """Create mock config."""
    return MagicMock(spec=LiteConfig)


@pytest.fixture
def mock_storage():
    """Create mock storage."""
    return MagicMock()


@pytest.fixture
def sample_document() -> LiteDocument:
    """Create a sample document for testing."""
    return LiteDocument(
        id="pmid-12345",
        title="Test Document Title",
        abstract="This is the abstract text for testing purposes.",
        authors=["Smith J", "Jones A"],
        year=2023,
        journal="Test Journal",
        pmid="12345",
    )


@pytest.fixture
def sample_scored_doc(sample_document) -> ScoredDocument:
    """Create a sample scored document."""
    return ScoredDocument(
        document=sample_document,
        score=4,
        explanation="Highly relevant to the research question.",
    )


@pytest.fixture
def sample_citation(sample_document) -> Citation:
    """Create a sample citation."""
    return Citation(
        document=sample_document,
        passage="This is an important finding from the study.",
        relevance_score=4,
        context="Supports the main hypothesis.",
    )


class TestAuditQueriesTab:
    """Tests for AuditQueriesTab."""

    def test_initialization(self, qapp) -> None:
        """Tab should initialize correctly."""
        tab = AuditQueriesTab()
        assert tab.query_count == 0

    def test_placeholder_not_hidden_when_empty(self, qapp) -> None:
        """Placeholder should not be hidden when no queries."""
        tab = AuditQueriesTab()
        # Note: isVisible() requires widget to be shown, so we check isHidden() is False
        assert not tab.placeholder.isHidden()

    def test_add_query(self, qapp) -> None:
        """Adding query should create card and hide placeholder."""
        tab = AuditQueriesTab()
        card = tab.add_query(
            "(cardiovascular) AND (exercise)",
            "cardiovascular benefits of exercise",
        )

        assert tab.query_count == 1
        assert not tab.placeholder.isVisible()
        assert card is not None

    def test_update_query_stats(self, qapp) -> None:
        """Query stats should be updateable."""
        tab = AuditQueriesTab()
        query = "(cardiovascular) AND (exercise)"
        tab.add_query(query, "test query")

        tab.update_query_stats(
            query,
            documents_found=100,
            documents_scored=25,
            citations_extracted=10,
        )

        card = tab.get_query_card(query)
        assert card is not None
        assert card._documents_found == 100
        assert card._documents_scored == 25
        assert card._citations_extracted == 10

    def test_clear(self, qapp) -> None:
        """Clear should remove all queries."""
        tab = AuditQueriesTab()
        tab.add_query("query1", "nl1")
        tab.add_query("query2", "nl2")

        tab.clear()

        assert tab.query_count == 0
        assert not tab.placeholder.isHidden()


class TestAuditLiteratureTab:
    """Tests for AuditLiteratureTab."""

    def test_initialization(self, qapp) -> None:
        """Tab should initialize correctly."""
        tab = AuditLiteratureTab()
        assert tab.document_count == 0

    def test_placeholder_not_hidden_when_empty(self, qapp) -> None:
        """Placeholder should not be hidden when no documents."""
        tab = AuditLiteratureTab()
        assert not tab.placeholder.isHidden()

    def test_add_documents(self, qapp, sample_document) -> None:
        """Adding documents should create cards."""
        tab = AuditLiteratureTab()
        tab.add_documents([sample_document])

        assert tab.document_count == 1
        assert not tab.placeholder.isVisible()

    def test_get_card(self, qapp, sample_document) -> None:
        """Should be able to get card by doc_id."""
        tab = AuditLiteratureTab()
        tab.add_documents([sample_document])

        card = tab.get_card(sample_document.id)
        assert card is not None
        assert card.doc_id == sample_document.id

    def test_update_score(self, qapp, sample_document, sample_scored_doc) -> None:
        """Score should be updateable."""
        tab = AuditLiteratureTab()
        tab.add_documents([sample_document])

        tab.update_score(sample_scored_doc)

        assert tab.scored_count == 1
        card = tab.get_card(sample_document.id)
        assert card is not None

    def test_document_clicked_signal(self, qapp, sample_document) -> None:
        """Clicking document should emit signal."""
        tab = AuditLiteratureTab()
        tab.add_documents([sample_document])

        received = []
        tab.document_clicked.connect(lambda doc_id: received.append(doc_id))

        card = tab.get_card(sample_document.id)
        # Simulate card click signal
        card.clicked.emit(sample_document.id)

        assert len(received) == 1
        assert received[0] == sample_document.id

    def test_clear(self, qapp, sample_document) -> None:
        """Clear should remove all documents."""
        tab = AuditLiteratureTab()
        tab.add_documents([sample_document])

        tab.clear()

        assert tab.document_count == 0
        assert not tab.placeholder.isHidden()


class TestAuditCitationsTab:
    """Tests for AuditCitationsTab."""

    def test_initialization(self, qapp) -> None:
        """Tab should initialize correctly."""
        tab = AuditCitationsTab()
        assert tab.citation_count == 0

    def test_placeholder_not_hidden_when_empty(self, qapp) -> None:
        """Placeholder should not be hidden when no citations."""
        tab = AuditCitationsTab()
        assert not tab.placeholder.isHidden()

    def test_add_citation(self, qapp, sample_citation) -> None:
        """Adding citation should create card."""
        tab = AuditCitationsTab()
        card = tab.add_citation(sample_citation)

        assert tab.citation_count == 1
        assert not tab.placeholder.isVisible()
        assert card is not None

    def test_get_citations_for_document(self, qapp, sample_citation) -> None:
        """Should be able to get citations by doc_id."""
        tab = AuditCitationsTab()
        tab.add_citation(sample_citation)

        citations = tab.get_citations_for_document(sample_citation.document.id)
        assert len(citations) == 1
        assert citations[0] == sample_citation

    def test_clear(self, qapp, sample_citation) -> None:
        """Clear should remove all citations."""
        tab = AuditCitationsTab()
        tab.add_citation(sample_citation)

        tab.clear()

        assert tab.citation_count == 0
        assert not tab.placeholder.isHidden()


class TestAuditTrailTab:
    """Tests for AuditTrailTab container."""

    def test_initialization(self, qapp, mock_config, mock_storage) -> None:
        """Tab should initialize with sub-tabs."""
        tab = AuditTrailTab(mock_config, mock_storage)

        assert tab.queries_tab is not None
        assert tab.literature_tab is not None
        assert tab.citations_tab is not None

    def test_on_workflow_started_clears_data(
        self, qapp, mock_config, mock_storage, sample_document
    ) -> None:
        """workflow_started should clear all sub-tabs."""
        tab = AuditTrailTab(mock_config, mock_storage)

        # Add some data
        tab.queries_tab.add_query("test", "test")
        tab.literature_tab.add_documents([sample_document])

        # Clear
        tab.on_workflow_started()

        assert tab.query_count == 0
        assert tab.document_count == 0
        assert tab.citation_count == 0

    def test_on_query_generated(self, qapp, mock_config, mock_storage) -> None:
        """on_query_generated should add query to queries tab."""
        tab = AuditTrailTab(mock_config, mock_storage)

        tab.on_query_generated(
            "(cardiovascular) AND (exercise)",
            "cardiovascular exercise",
        )

        assert tab.query_count == 1

    def test_on_documents_found(
        self, qapp, mock_config, mock_storage, sample_document
    ) -> None:
        """on_documents_found should add documents to literature tab."""
        tab = AuditTrailTab(mock_config, mock_storage)

        # Need a query first for stats
        tab.on_query_generated("test", "test")
        tab.on_documents_found([sample_document])

        assert tab.document_count == 1

    def test_on_document_scored(
        self, qapp, mock_config, mock_storage, sample_document, sample_scored_doc
    ) -> None:
        """on_document_scored should update score in literature tab."""
        tab = AuditTrailTab(mock_config, mock_storage)

        tab.on_query_generated("test", "test")
        tab.on_documents_found([sample_document])
        tab.on_document_scored(sample_scored_doc)

        assert tab.literature_tab.scored_count == 1

    def test_on_citation_extracted(
        self, qapp, mock_config, mock_storage, sample_citation
    ) -> None:
        """on_citation_extracted should add citation to citations tab."""
        tab = AuditTrailTab(mock_config, mock_storage)

        tab.on_query_generated("test", "test")
        tab.on_citation_extracted(sample_citation)

        assert tab.citation_count == 1

    def test_document_requested_signal(
        self, qapp, mock_config, mock_storage, sample_document
    ) -> None:
        """Context menu 'Send to Interrogator' should emit document_requested signal."""
        tab = AuditTrailTab(mock_config, mock_storage)
        tab.on_documents_found([sample_document])

        received = []
        tab.document_requested.connect(lambda doc_id: received.append(doc_id))

        # Simulate "Send to Interrogator" context menu action
        card = tab.literature_tab.get_card(sample_document.id)
        card.send_to_interrogator.emit(sample_document.id)

        assert len(received) == 1
        assert received[0] == sample_document.id

    def test_card_click_toggles_expand(
        self, qapp, mock_config, mock_storage, sample_document
    ) -> None:
        """Clicking document card should toggle expand/collapse."""
        tab = AuditTrailTab(mock_config, mock_storage)
        tab.on_documents_found([sample_document])

        card = tab.literature_tab.get_card(sample_document.id)
        assert not card.expanded

        # Click should toggle expand
        card._toggle_expanded()
        assert card.expanded

        # Click again should collapse
        card._toggle_expanded()
        assert not card.expanded

    def test_get_document(
        self, qapp, mock_config, mock_storage, sample_document
    ) -> None:
        """get_document should return document from literature tab."""
        tab = AuditTrailTab(mock_config, mock_storage)
        tab.on_documents_found([sample_document])

        doc = tab.get_document(sample_document.id)
        assert doc is not None
        assert doc.id == sample_document.id

    def test_get_citations_for_document(
        self, qapp, mock_config, mock_storage, sample_citation
    ) -> None:
        """get_citations_for_document should return citations."""
        tab = AuditTrailTab(mock_config, mock_storage)
        tab.on_citation_extracted(sample_citation)

        citations = tab.get_citations_for_document(sample_citation.document.id)
        assert len(citations) == 1
