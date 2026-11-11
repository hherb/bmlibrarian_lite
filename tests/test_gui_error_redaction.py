# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A worker's error signal carries no credential (#330).

A provider prints the request, key and all, in its error. Each worker below
puts that text on a signal the tab shows the reader, so each redacts it.
"""

from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.gui import workers  # noqa: E402

SECRET = "SECRET123"
LEAKY = f"Client error for url 'https://h/p?key={SECRET}'"


def collect(signal: Any) -> list[tuple[Any, ...]]:
    """Connect a recorder to a signal; the list fills as it is emitted."""
    got: list[tuple[Any, ...]] = []
    signal.connect(lambda *args: got.append(args))
    return got


def test_the_shared_unexpected_error_path_redacts() -> None:
    """``SingleOutcome._run_once`` hands its fallback redacted text."""
    worker = workers.AnswerWorker(MagicMock(), "q")
    seen: list[str] = []

    def body() -> None:
        raise RuntimeError(LEAKY)

    worker._run_once(body, seen.append)

    [text] = seen
    assert SECRET not in text
    assert "Client error" in text


def test_a_stopped_run_still_ends_redacted_and_keeps_unwinding() -> None:
    """A ``BaseException`` ends the run with redacted text, then propagates."""
    worker = workers.AnswerWorker(MagicMock(), "q")
    seen: list[str] = []

    def body() -> None:
        raise SystemExit(LEAKY)

    with pytest.raises(SystemExit):
        worker._run_once(body, seen.append)

    [text] = seen
    assert SECRET not in text
    assert "Client error" in text


def test_the_interrogation_answer_error_redacts() -> None:
    """The error shown in the chat carries no key."""
    agent = MagicMock()
    agent.ask.side_effect = RuntimeError(LEAKY)
    worker = workers.AnswerWorker(agent, "q")
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text
    assert "Client error" in text


def test_the_quality_filter_error_redacts() -> None:
    """The quality filter's error signal carries no key."""
    manager = MagicMock()
    manager.filter_documents.side_effect = RuntimeError(LEAKY)
    worker = workers.QualityFilterWorker(manager, [], MagicMock())
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text
    assert "Client error" in text


def test_a_quality_filter_error_mid_cancel_redacts() -> None:
    """An error that also ends a cancelled filter reaches ``cancelled`` without its key.

    No tab connects this signal yet, so the worker is the only place it is
    redacted.
    """
    manager = MagicMock()
    worker = workers.QualityFilterWorker(manager, [], MagicMock())

    def cancel_then_fail(*args: Any, **kwargs: Any) -> None:
        worker.cancel()
        raise RuntimeError(LEAKY)

    manager.filter_documents.side_effect = cancel_then_fail
    cancelled = collect(worker.cancelled)

    worker.run()

    [(_, _, _, text)] = cancelled
    assert SECRET not in text
    assert "Client error" in text


@pytest.mark.parametrize(
    ("module", "worker_name", "runner_name"),
    [
        ("benchmark_dialog", "BenchmarkWorker", "BenchmarkRunner"),
        ("quality_benchmark_dialog", "QualityBenchmarkWorker", "QualityBenchmarkRunner"),
    ],
)
def test_a_benchmark_error_redacts(
    monkeypatch: pytest.MonkeyPatch, module: str, worker_name: str, runner_name: str
) -> None:
    """Both benchmark dialogs' error signals carry no key."""
    import importlib

    import bmlibrarian_lite.benchmarking as benchmarking

    runner = MagicMock()
    runner.run_quick_benchmark.side_effect = RuntimeError(LEAKY)
    monkeypatch.setattr(benchmarking, runner_name, lambda *a, **k: runner)
    dialog = importlib.import_module(f"bmlibrarian_lite.gui.{module}")
    worker = getattr(dialog, worker_name)(MagicMock(), MagicMock(), "q", [], ["m"])
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text
    assert "Client error" in text


def test_the_openathens_error_redacts(monkeypatch: pytest.MonkeyPatch) -> None:
    """An OpenAthens failure says ``Authentication error`` without the key."""

    def fail(url: str) -> bool:
        raise RuntimeError(LEAKY)

    monkeypatch.setattr(workers.webbrowser, "open", fail)
    worker = workers.OpenAthensAuthWorker("https://login.example.org")
    errors = collect(worker.error)

    worker.run()

    [(text,)] = errors
    assert SECRET not in text
    assert text.startswith("Authentication error: Client error")


@pytest.mark.parametrize("cancel", [False, True], ids=["error", "cancelled"])
def test_an_unexpected_rerun_search_error_redacts(
    monkeypatch: pytest.MonkeyPatch, cancel: bool
) -> None:
    """A rerun's search that stops on an unexpected error ends without the key.

    Both arms are covered: the error, and the cancel the error also ended.
    """
    from bmlibrarian_lite.config import LiteConfig

    config = LiteConfig()
    config.pubmed.email = "test@example.com"
    worker = workers.IncrementalSearchWorker(
        question="q",
        pubmed_query="q",
        target_new_docs=1,
        already_scored_ids=set(),
        config=config,
        storage=MagicMock(),
    )

    def fail(*args: Any, **kwargs: Any) -> Any:
        if cancel:
            worker.cancel()
        raise RuntimeError(LEAKY)

    monkeypatch.setattr("bmlibrarian_lite.pubmed.PubMedSearchClient.search_with_offset", fail)
    ended = collect(worker.cancelled if cancel else worker.error)

    worker.run()

    [(text,)] = ended
    assert SECRET not in text
    assert "Client error" in text


@pytest.mark.parametrize(
    ("module", "worker_name", "runner_name"),
    [
        ("benchmark_dialog", "BenchmarkWorker", "BenchmarkRunner"),
        ("quality_benchmark_dialog", "QualityBenchmarkWorker", "QualityBenchmarkRunner"),
    ],
)
def test_a_benchmark_error_mid_cancel_redacts(
    monkeypatch: pytest.MonkeyPatch, module: str, worker_name: str, runner_name: str
) -> None:
    """An error that also ends a cancelled benchmark reaches ``cancelled`` without its key."""
    import importlib

    import bmlibrarian_lite.benchmarking as benchmarking

    runner = MagicMock()
    monkeypatch.setattr(benchmarking, runner_name, lambda *a, **k: runner)
    dialog = importlib.import_module(f"bmlibrarian_lite.gui.{module}")
    worker = getattr(dialog, worker_name)(MagicMock(), MagicMock(), "q", [], ["m"])

    def cancel_then_fail(*args: Any, **kwargs: Any) -> None:
        worker.cancel()
        raise RuntimeError(LEAKY)

    runner.run_quick_benchmark.side_effect = cancel_then_fail
    cancelled = collect(worker.cancelled)

    worker.run()

    [(partial, text)] = cancelled
    assert partial is None
    assert SECRET not in text
    assert "Client error" in text


@pytest.mark.parametrize(
    ("worker_name", "method", "args"),
    [
        ("PDFDiscoveryWorker", "discover_and_download", ({"doi": "10.1/x"}, MagicMock())),
        ("FulltextDiscoveryWorker", "discover_fulltext", ({"doi": "10.1/x"},)),
    ],
)
def test_a_discovery_error_redacts(
    monkeypatch: pytest.MonkeyPatch, worker_name: str, method: str, args: tuple[Any, ...]
) -> None:
    """A discoverer that raises, or reports a failure, shows no key."""
    monkeypatch.setattr(workers, "generate_pdf_path", lambda *a: MagicMock())
    for discoverer_fails in (
        lambda d: setattr(getattr(d, method), "side_effect", RuntimeError(LEAKY)),
        lambda d: setattr(
            getattr(d, method),
            "return_value",
            MagicMock(success=False, is_paywall=False, error=LEAKY, set_aside=None,
                      set_aside_pdf_note=None, lookups=[]),
        ),
    ):
        discoverer = MagicMock()
        discoverer_fails(discoverer)
        worker = getattr(workers, worker_name)(*args)
        monkeypatch.setattr(worker, "_build_discoverer", lambda d=discoverer: d)
        errors = collect(worker.error)

        worker.run()

        [(text,)] = errors
        assert SECRET not in text
        assert "Client error" in text


@pytest.fixture
def interrogation_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """The Document Interrogation tab, its agent failing every load with a key in the error (#747).

    The QApplication is never pumped; the tab is deleted at the end so it
    does not leak into later tests (#516).
    """
    from PySide6.QtWidgets import QApplication

    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui import document_interrogation_tab as tab_module
    from bmlibrarian_lite.storage import LiteStorage

    QApplication.instance() or QApplication([])
    monkeypatch.setattr(tab_module, "LiteInterrogationAgent", MagicMock())
    monkeypatch.setattr(tab_module, "RetractionCheckWorker", MagicMock())
    monkeypatch.setattr(tab_module, "keep_until_finished", MagicMock())
    monkeypatch.setattr(tab_module, "QMessageBox", MagicMock())
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    tab = tab_module.DocumentInterrogationTab(config=config, storage=LiteStorage(config))
    tab.document_view = MagicMock()
    tab.document_view.load_file.return_value = "Some text."
    tab._agent.load_document.side_effect = RuntimeError(LEAKY)
    yield tab, tab_module
    tab.close()
    tab.deleteLater()


def shown_error(tab_module: Any) -> str:
    """The text of the one error box the tab showed."""
    [call] = tab_module.QMessageBox.critical.call_args_list
    return str(call.args[2])


def test_a_file_load_error_redacts(interrogation_tab: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """Loading a file: neither the document label nor the error box shows the key."""
    tab, tab_module = interrogation_tab
    path = tmp_path / "paper.txt"
    path.write_text("Some text.")
    monkeypatch.setattr(tab_module.QFileDialog, "getOpenFileName", lambda *a, **k: (str(path), ""))

    tab._load_document()

    for text in (tab.doc_label.text(), shown_error(tab_module)):
        assert SECRET not in text
        assert "Client error" in text


def test_a_discovered_pdf_load_error_redacts(
    interrogation_tab: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Loading a PDF that discovery found: the error box shows no key."""
    tab, tab_module = interrogation_tab
    path = tmp_path / "paper.pdf"
    path.write_bytes(b"%PDF-1.4")
    monkeypatch.setattr(tab_module, "extract_pdf_text", lambda _p: "Some text.")

    tab._load_pdf_file(path, "Paper")

    text = shown_error(tab_module)
    assert SECRET not in text
    assert "Client error" in text


def test_an_abstract_load_error_redacts(interrogation_tab: Any) -> None:
    """Loading a citation's abstract: the error box shows no key."""
    from bmlibrarian_lite.data_models import Citation, DocumentSource, LiteDocument

    tab, tab_module = interrogation_tab
    document = LiteDocument(id="doc-1", title="Trial", abstract="An abstract.", authors=["Smith J"],
                            year=2024, journal="J", pmid="1", source=DocumentSource.PUBMED)

    tab._load_citation_abstract(Citation(document=document, passage="An abstract.", relevance_score=4))

    text = shown_error(tab_module)
    assert SECRET not in text
    assert "Client error" in text


def test_a_save_error_redacts(interrogation_tab: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> None:
    """Saving the conversation: the error box shows no key."""
    tab, tab_module = interrogation_tab
    target = tmp_path / "conversation.json"
    monkeypatch.setattr(tab_module.QFileDialog, "getSaveFileName", lambda *a, **k: (str(target), ""))
    tab.conversation_history = [{"role": "user", "content": "Q"}]

    def failing_export(*_args: Any) -> str:
        raise RuntimeError(LEAKY)

    tab._save_as_format("json", failing_export)

    text = shown_error(tab_module)
    assert SECRET not in text
    assert "Client error" in text
