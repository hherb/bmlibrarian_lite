# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A fall back to the abstract is told to the reader, not only the log (#304).

Every failure on the citation full-text path -- discovery failing, the content
arriving empty, the load raising, PDF extraction yielding nothing -- fell back
to the abstract behind a ``logger.warning``. The user was then told
"Source: Abstract" and nothing more, and every answer after it was drawn from
the abstract alone while they believed they were interrogating the best
available content. In a fact-checking tool "the abstract says nothing about X"
and "the full text says nothing about X" are different claims.

#301 fixed this shape for MCP callers (#264) by adding ``interrogation_available``
and ``interrogation_error``; these tests follow it to the human's screen.
"""

from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    Citation,
    DocumentSource,
    LiteDocument,
)
from bmlibrarian_lite.gui import document_interrogation_tab as tab_module  # noqa: E402
from bmlibrarian_lite.gui.citation_loader import abstract_source_label  # noqa: E402
from bmlibrarian_lite.gui.document_interrogation_tab import (  # noqa: E402
    FULLTEXT_EMPTY,
    FULLTEXT_PAYWALLED,
    FULLTEXT_UNAVAILABLE,
    FULLTEXT_UNREADABLE,
    NO_FULLTEXT_IDENTIFIER,
    PDF_NO_TEXT,
    PDF_UNREADABLE,
    DocumentInterrogationTab,
)

#: An error string of the shape a live failure produces: it carries a URL, and
#: a URL is what an NCBI API key travels in.
LEAKY_ERROR = "HTTPError for https://eutils.ncbi.nlm.nih.gov/x?api_key=SECRET42"


@pytest.fixture
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def make_citation() -> Citation:
    """A citation whose document has an abstract to fall back to."""
    document = LiteDocument(
        id="doc-1",
        title="Aspirin trial",
        abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid="1",
        source=DocumentSource.EUROPEPMC,
    )
    return Citation(
        document=document,
        passage="Aspirin reduced stroke incidence.",
        relevance_score=4,
    )


class Bubbles:
    """What the tab said to the user, in order."""

    def __init__(self) -> None:
        """Start with nothing said."""
        self.said: list[str] = []

    def __call__(self, text: str, is_user: bool, track_history: bool = True) -> None:
        """Record one bubble.

        Args:
            text: The bubble's markdown.
            is_user: Whether the user wrote it.
            track_history: Ignored.
        """
        if not is_user:
            self.said.append(text)

    @property
    def last(self) -> str:
        """The most recent thing the tab said.

        Returns:
            The bubble's text.
        """
        assert self.said, "The tab said nothing"
        return self.said[-1]


@pytest.fixture
def tab(qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    """An interrogation tab whose agent, views and discovery are stood in for.

    ``discovery_on_error`` is the callback ``load_from_citation`` hands to
    full-text discovery -- the failure path production actually takes.
    """
    monkeypatch.setattr(tab_module, "LiteInterrogationAgent", MagicMock())
    monkeypatch.setattr(tab_module, "QMessageBox", MagicMock())
    monkeypatch.setattr(tab_module, "find_existing_fulltext", lambda _m: None)
    monkeypatch.setattr(tab_module, "find_existing_pdf", lambda _m: None)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    widget = DocumentInterrogationTab(config=config, storage=MagicMock())
    widget.document_view = MagicMock()
    widget._bubbles = Bubbles()
    monkeypatch.setattr(widget, "_add_chat_bubble", widget._bubbles)

    def capture(_doc: Any, _title: str, _citation: Any, on_error: Any = None) -> None:
        widget.discovery_on_error = on_error

    monkeypatch.setattr(widget, "_start_fulltext_discovery", capture)
    widget.load_from_citation(make_citation())
    return widget


class TestTheLabel:
    """The one place the degradation is named."""

    def test_an_abstract_nobody_fell_back_to_is_just_an_abstract(self) -> None:
        """A qualifier on every load is a qualifier nobody reads."""
        assert abstract_source_label(None) == "Abstract"

    def test_a_fallback_names_what_was_lost(self) -> None:
        """The reader decides how much to trust the answer from this."""
        assert abstract_source_label(FULLTEXT_UNREADABLE) == (
            f"Abstract ({FULLTEXT_UNREADABLE})"
        )


class TestEveryFallbackSaysSo:
    """Four paths fell back silently; each one now names its cause."""

    def test_a_failed_discovery_is_named(self, tab: Any) -> None:
        """The full text was never retrieved, and the reader is told.

        This drives the ``on_error`` callback, because that is the path
        production takes: ``load_from_citation`` is the only caller of
        ``_start_fulltext_discovery`` and it always passes one, so the
        fallback inside ``_on_fulltext_error`` is never reached. A safety net
        installed where production never runs is not installed.
        """
        tab.discovery_on_error(LEAKY_ERROR)

        assert FULLTEXT_UNAVAILABLE in tab._bubbles.last

    def test_the_unreached_branch_names_it_too(self, tab: Any) -> None:
        """The branch below the callback, for whoever calls without one."""
        tab._on_fulltext_error(LEAKY_ERROR, make_citation())

        assert FULLTEXT_UNAVAILABLE in tab._bubbles.last

    def test_an_article_with_no_identifier_to_search_by_is_named(
        self, tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """No failure occurred, but the abstract is still not the full text."""
        monkeypatch.setattr(tab_module, "has_pdf_identifiers", lambda _c: False)

        tab.load_from_citation(make_citation())

        assert NO_FULLTEXT_IDENTIFIER in tab._bubbles.last

    def test_skipping_a_paywall_is_named(self, tab: Any) -> None:
        """The user chose the abstract, and the header must keep saying so."""
        tab._pending_citation = make_citation()
        tab._skip_paywalled_fulltext(None)

        assert FULLTEXT_PAYWALLED in tab._bubbles.last

    def test_an_empty_full_text_is_named(self, tab: Any) -> None:
        """Content that arrived with nothing in it is not an abstract."""
        tab._load_citation_fulltext("   ", make_citation(), "Full Text (Europe PMC)")

        assert FULLTEXT_EMPTY in tab._bubbles.last

    def test_a_full_text_that_could_not_be_read_is_named(self, tab: Any) -> None:
        """It was retrieved and then dropped -- the worst silence of the four."""
        tab._agent.load_document.side_effect = [RuntimeError("boom"), None]

        tab._load_citation_fulltext(
            "# Aspirin trial", make_citation(), "Full Text (Europe PMC)"
        )

        assert FULLTEXT_UNREADABLE in tab._bubbles.last

    def test_a_pdf_with_no_extractable_text_is_named(
        self, tab: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A scanned deposit yields nothing, and the reader must know."""
        monkeypatch.setattr(tab_module, "extract_pdf_text", lambda _path: "")

        tab._load_citation_pdf(tmp_path / "a.pdf", make_citation(), "Full Text (PDF)")

        assert PDF_NO_TEXT in tab._bubbles.last

    def test_a_pdf_that_could_not_be_read_is_named(
        self, tab: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Extraction raising is not an article without a full text."""

        def explode(_path: Any) -> str:
            raise RuntimeError("boom")

        monkeypatch.setattr(tab_module, "extract_pdf_text", explode)

        tab._load_citation_pdf(tmp_path / "a.pdf", make_citation(), "Full Text (PDF)")

        assert PDF_UNREADABLE in tab._bubbles.last


class TestWhatIsNotSaid:
    """A message the user reads is not a place to print a provider's error."""

    def test_the_raw_error_never_reaches_the_screen(self, tab: Any) -> None:
        """A URL is what an NCBI API key travels in (the #196 rule)."""
        tab._on_fulltext_error(LEAKY_ERROR, make_citation())

        assert "SECRET42" not in tab._bubbles.last
        assert "api_key" not in tab._bubbles.last

    def test_an_abstract_asked_for_directly_is_not_qualified(self, tab: Any) -> None:
        """Nothing was lost, so nothing is reported as lost."""
        tab._load_citation_abstract(make_citation())

        assert "Source: Abstract\n" in tab._bubbles.last
        assert "could not" not in tab._bubbles.last


class TestTheDegradationReachesTheHeader:
    """The chat scrolls away; the header beside the document does not."""

    def test_the_document_header_carries_the_degradation(self, tab: Any) -> None:
        """A reader arriving at an old session still sees what was lost."""
        tab._on_fulltext_error(LEAKY_ERROR, make_citation())

        assert FULLTEXT_UNAVAILABLE in tab.doc_label.text()
