# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A fall back to the abstract is told to the reader, not only the log (#304).

Every failure on the citation full-text path -- discovery failing, the content
arriving empty, the load raising, PDF extraction yielding nothing -- fell back
to the abstract with at most a line in the log. The user was then told
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

from PySide6.QtCore import QObject, Signal  # noqa: E402

from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    Citation,
    DocumentSource,
    LiteDocument,
)
from bmlibrarian_lite.gui import document_interrogation_tab as tab_module  # noqa: E402
from bmlibrarian_lite.gui.citation_loader import abstract_source_label  # noqa: E402
from bmlibrarian_lite.gui.document_interrogation_tab import (  # noqa: E402
    FULLTEXT_CANCELLED,
    FULLTEXT_EMPTY,
    FULLTEXT_PAYWALLED,
    FULLTEXT_UNAVAILABLE,
    FULLTEXT_UNREADABLE,
    NO_FULLTEXT_IDENTIFIER,
    PDF_NO_TEXT,
    PDF_UNREADABLE,
    DocumentInterrogationTab,
)

#: What a provider's error text can carry on this path: the Unpaywall request
#: URL holds the user's email address, and a URL is what error text prints.
LEAKED_ADDRESS = "reader@example.org"
LEAKY_ERROR = (
    f"HTTPError for https://api.unpaywall.org/v2/10.1000/x?email={LEAKED_ADDRESS}"
)

#: A full text as Europe PMC discovery delivers it.
FULL_TEXT = "# Aspirin trial\n\nAspirin reduced stroke incidence in 4,000 patients."


class StubFulltextWorker(QObject):
    """Full-text discovery that answers only when the test emits for it."""

    progress = Signal(str, str)
    finished = Signal(str, str, str)
    paywall_detected = Signal(str, str)
    error = Signal(str)

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        """Take the real worker's arguments and ignore them.

        Args:
            *_args: What the tab passes the real worker.
            **_kwargs: Likewise.
        """
        super().__init__()
        self.cancelled = False

    def start(self) -> None:
        """Nothing runs until the test emits a result."""

    def cancel(self) -> None:
        """Record that the tab stopped discovery."""
        self.cancelled = True


class StubPdfWorker(QObject):
    """PDF discovery that answers only when the test emits for it."""

    progress = Signal(str, str)
    finished = Signal(str)
    verification_warning = Signal(str, str)
    paywall_detected = Signal(str, str)
    error = Signal(str)

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        """Take the real worker's arguments and ignore them.

        Args:
            *_args: What the tab passes the real worker.
            **_kwargs: Likewise.
        """
        super().__init__()

    def start(self) -> None:
        """Nothing runs until the test emits a result."""

    def cancel(self) -> None:
        """Nothing to stop."""


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


def make_tab(tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    """An interrogation tab whose agent, views and caches are stood in for.

    Args:
        tmp_path: A data directory this test owns.
        monkeypatch: To stand the collaborators down.

    Returns:
        The tab, recording what it says in ``_bubbles``.
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
    return widget


@pytest.fixture
def tab(qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    """An interrogation tab whose discovery is stood in for as well.

    ``discovery_on_error`` is the callback ``load_from_citation`` hands to
    full-text discovery -- the failure path production actually takes.
    """
    widget = make_tab(tmp_path, monkeypatch)

    def capture(
        _doc: Any,
        _title: str,
        _citation: Any,
        on_error: Any = None,
        on_cancel: Any = None,
    ) -> None:
        widget.discovery_on_error = on_error

    monkeypatch.setattr(widget, "_start_fulltext_discovery", capture)
    widget.load_from_citation(make_citation())
    return widget


@pytest.fixture
def live_tab(qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> Any:
    """An interrogation tab whose discovery is wired exactly as in production.

    Only the workers are stood in for, so the progress dialog, its
    ``canceled`` signal and every handler that closes it run for real.
    ``_fulltext_worker`` is the stub the citation load started.
    """
    monkeypatch.setattr(tab_module, "FulltextDiscoveryWorker", StubFulltextWorker)
    monkeypatch.setattr(tab_module, "PDFDiscoveryWorker", StubPdfWorker)
    widget = make_tab(tmp_path, monkeypatch)
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
    """Seven paths fell back silently; each one now names its cause."""

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
        """Error text prints the request URL, and this one holds an address.

        This drives the callback production takes; the branch below it is
        covered too, by the test after this one.
        """
        tab.discovery_on_error(LEAKY_ERROR)

        assert LEAKED_ADDRESS not in tab._bubbles.last
        assert LEAKED_ADDRESS not in tab.doc_label.text()

    def test_the_unreached_branch_keeps_the_error_off_the_screen_too(
        self, tab: Any
    ) -> None:
        """The same rule below the callback, for whoever calls without one."""
        tab._on_fulltext_error(LEAKY_ERROR, make_citation())

        assert LEAKED_ADDRESS not in tab._bubbles.last

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


def said_unavailable(tab: Any) -> bool:
    """Whether the tab ever told the user the full text could not be had.

    Args:
        tab: The tab under test.

    Returns:
        True if any bubble named that cause.
    """
    return any(FULLTEXT_UNAVAILABLE in said for said in tab._bubbles.said)


class TestClosingTheProgressDialogIsNotCancellingIt:
    """``QProgressDialog.close()`` emits ``canceled`` (#305 review).

    ``canceled`` was wired to the fall back to the abstract, and every handler
    closed the dialog before doing its work -- so a full text that arrived was
    first announced as one that "could not be retrieved". These drive the real
    discovery wiring; only the worker is a stand-in.
    """

    def test_a_full_text_that_arrives_is_never_called_unretrieved(
        self, live_tab: Any
    ) -> None:
        """The false claim was made on every successful load."""
        live_tab._fulltext_worker.finished.emit(FULL_TEXT, "", "europepmc_xml")

        assert not said_unavailable(live_tab)
        assert "Source: Full Text (Europe PMC)" in live_tab._bubbles.last

    def test_a_failed_discovery_falls_back_once(self, live_tab: Any) -> None:
        """Closing the dialog loaded the abstract a second time."""
        live_tab._fulltext_worker.error.emit(LEAKY_ERROR)

        fallbacks = [s for s in live_tab._bubbles.said if "Source: Abstract" in s]
        assert len(fallbacks) == 1
        assert FULLTEXT_UNAVAILABLE in fallbacks[0]

    def test_the_live_failure_keeps_the_error_off_the_screen(
        self, live_tab: Any
    ) -> None:
        """The worker's own error text is what carries the address."""
        live_tab._fulltext_worker.error.emit(LEAKY_ERROR)

        assert LEAKED_ADDRESS not in "\n".join(live_tab._bubbles.said)
        assert LEAKED_ADDRESS not in live_tab.doc_label.text()

    def test_a_paywall_is_not_first_announced_as_unretrievable(
        self, live_tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The prompt asks what to do; nothing has failed to arrive yet."""
        prompt = tab_module.OpenAthensPromptDialog
        monkeypatch.setattr(prompt, "get_action", lambda _self: prompt.ACTION_CANCEL)

        live_tab._fulltext_worker.paywall_detected.emit(
            "https://publisher.example/article", "Access requires subscription"
        )

        assert not said_unavailable(live_tab)

    def test_a_user_who_cancels_is_told_they_cancelled(self, live_tab: Any) -> None:
        """Nothing failed to be retrieved; the user stopped it."""
        live_tab._pdf_progress_dialog.canceled.emit()

        assert FULLTEXT_CANCELLED in live_tab._bubbles.last
        assert not said_unavailable(live_tab)
        assert live_tab._fulltext_worker.cancelled

    def test_a_pdf_that_arrives_after_sign_in_is_not_reported_as_failed(
        self, live_tab: Any
    ) -> None:
        """The OpenAthens retry closed its dialog into "Could not download"."""
        succeeded: list[str] = []
        failed: list[str] = []
        live_tab._start_pdf_discovery(
            {"doi": "10.1000/x"},
            "Aspirin trial",
            on_success=succeeded.append,
            on_error=failed.append,
        )

        live_tab._pdf_worker.finished.emit("/tmp/aspirin.pdf")

        assert succeeded == ["/tmp/aspirin.pdf"]
        assert failed == []
