# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A rerun scores a failed document again (#316).

The Research Questions tab's Re-run skipped every document with a row in
``scored_documents`` for the question -- including a scoring that failed.
So a document the model could not reach was treated as judged: the rerun
never fetched it again, and the only way to get it scored was to start the
question over. A document is judged when any scoring of it is a judgement;
one whose every scoring failed is scored again, and the user is told so.
"""

import sqlite3
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.exceptions import SQLiteError
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Does aspirin prevent stroke?"


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"pmid-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def record(
    storage: LiteStorage,
    document: LiteDocument,
    score: int,
    explanation: str = "Read and judged.",
    question: str = QUESTION,
) -> None:
    """Store one scoring of a document, in a run of its own."""
    storage.upsert_document(document)
    checkpoint = storage.create_checkpoint(research_question=question)
    storage.save_scored_document(ScoredDocument(document, score, explanation), checkpoint.id)


UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR.value


class TestTheSplit:
    """Which documents a rerun skips, and which it scores again."""

    def test_a_judgement_is_skipped(self, storage: LiteStorage) -> None:
        """Even a low one: the model read it."""
        record(storage, make_document("1"), 1)
        assert storage.get_rerun_document_ids_for_question(QUESTION) == ({"pmid-1"}, set())

    def test_a_failure_is_retried(self, storage: LiteStorage) -> None:
        """Skipped as scored, it was never retried."""
        record(storage, make_document("1"), UNREACHABLE)
        assert storage.get_rerun_document_ids_for_question(QUESTION) == (set(), {"pmid-1"})

    @pytest.mark.parametrize(
        "explanation", ["Scoring failed: Connection refused", "Could not parse response"]
    )
    def test_an_older_builds_failure_is_retried(
        self, storage: LiteStorage, explanation: str
    ) -> None:
        """Older builds stored a failure as a 1 with one of two explanations."""
        record(storage, make_document("1"), 1, explanation)
        assert storage.get_rerun_document_ids_for_question(QUESTION) == (set(), {"pmid-1"})

    def test_a_one_with_no_explanation_is_a_judgement(self, storage: LiteStorage) -> None:
        """The failure condition is NULL there; a NULL is not a failure."""
        record(storage, make_document("1"), 1, "")
        storage_rows = storage.get_rerun_document_ids_for_question(QUESTION)
        assert storage_rows == ({"pmid-1"}, set())

    def test_a_document_judged_once_is_judged(self, storage: LiteStorage) -> None:
        """A failure in one run does not undo the judgement of another."""
        document = make_document("1")
        record(storage, document, UNREACHABLE)
        record(storage, document, 4)
        assert storage.get_rerun_document_ids_for_question(QUESTION) == ({"pmid-1"}, set())

    def test_another_questions_scores_are_not_read(self, storage: LiteStorage) -> None:
        """A relevance score answers one question."""
        record(storage, make_document("1"), 4, question="Another question?")
        assert storage.get_rerun_document_ids_for_question(QUESTION) == (set(), set())

    def test_the_question_is_matched_as_the_table_matches_it(
        self, storage: LiteStorage
    ) -> None:
        """Case and surrounding space do not make it another question."""
        record(storage, make_document("1"), UNREACHABLE)
        assert storage.get_rerun_document_ids_for_question(f"  {QUESTION.upper()} ") == (
            set(),
            {"pmid-1"},
        )


class TestWhatTheRerunSays:
    """The messages the tab builds."""

    @pytest.fixture(autouse=True)
    def _needs_qt(self) -> None:
        """The tab's module imports PySide6."""
        pytest.importorskip("PySide6")

    def test_the_start_names_the_retried(self) -> None:
        """How many it skips, and how many it scores again."""
        from bmlibrarian_lite.gui.research_questions_tab import rerun_start_text

        assert rerun_start_text(12, 3, 0) == (
            "12 documents already scored; 3 whose scoring failed will be scored again"
        )
        assert rerun_start_text(1, 0, 0) == "1 document already scored"

    def test_the_start_names_what_cannot_be_retried(self) -> None:
        """A failed document whose record is gone cannot be loaded to score."""
        from bmlibrarian_lite.gui.research_questions_tab import rerun_start_text

        assert "2 whose scoring failed can no longer be loaded" in rerun_start_text(5, 0, 2)

    @pytest.mark.parametrize(
        "new, retried, text",
        [
            (5, 0, "Found 5 new documents"),
            (1, 0, "Found 1 new document"),
            (5, 3, "Found 5 new documents, and 3 whose scoring failed before"),
            (0, 3, "Found no new documents; 3 documents whose scoring failed before"),
            (0, 1, "Found no new documents; 1 document whose scoring failed before"),
        ],
    )
    def test_the_end_does_not_call_a_retried_document_new(
        self, new: int, retried: int, text: str
    ) -> None:
        """The retried documents are counted apart."""
        from bmlibrarian_lite.gui.research_questions_tab import rerun_found_text

        assert rerun_found_text(new, retried) == text


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the tab tests need."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class RecordingWorker:
    """Stands in for the search worker: records how the tab built it."""

    started: list[dict[str, Any]] = []

    def __init__(self, **kwargs: Any) -> None:
        """Record the arguments."""
        RecordingWorker.started.append(kwargs)
        self._signals: dict[str, MagicMock] = {}

    def __getattr__(self, name: str) -> MagicMock:
        """The same mock for a name every time."""
        return self.__dict__["_signals"].setdefault(name, MagicMock())


def rerun_tab(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Any, storage: Any
) -> tuple[Any, MagicMock]:
    """A Research Questions tab over this storage, one question selected."""
    from bmlibrarian_lite.data_models import ResearchQuestionSummary
    from bmlibrarian_lite.gui import research_questions_tab as module

    RecordingWorker.started = []
    monkeypatch.setattr(module, "IncrementalSearchWorker", RecordingWorker)
    message_box = MagicMock()
    monkeypatch.setattr(module, "QMessageBox", message_box)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    tab = module.ResearchQuestionsTab(config=config, storage=storage)
    summary = MagicMock(spec=ResearchQuestionSummary)
    summary.question = QUESTION
    summary.pubmed_query = "aspirin AND stroke"
    monkeypatch.setattr(tab, "_get_selected_question", lambda: summary)
    return tab, message_box


class TestTheRerun:
    """The tab hands the failed documents to the search to score again."""

    def test_a_failed_document_is_retried_and_a_judged_one_skipped(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any, storage: LiteStorage
    ) -> None:
        """The search skips both; only the failed one is handed on to score."""
        record(storage, make_document("1"), 4)
        record(storage, make_document("2"), UNREACHABLE)
        tab, _ = rerun_tab(monkeypatch, tmp_path, storage)

        tab._on_rerun_clicked()

        [started] = RecordingWorker.started
        assert started["already_scored_ids"] == {"pmid-1", "pmid-2"}
        assert [d.id for d in started["retry_documents"]] == ["pmid-2"]
        assert tab.progress_label.text() == (
            "1 document already scored; 1 whose scoring failed will be scored again"
        )

    def test_a_failed_document_with_no_record_is_left_for_the_search(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any, storage: LiteStorage
    ) -> None:
        """Skipped as well, it could never be found again, as the tab promises."""
        record(storage, make_document("2"), UNREACHABLE)
        record(storage, make_document("3"), UNREACHABLE)
        loadable = storage.get_documents
        monkeypatch.setattr(
            storage,
            "get_documents",
            lambda ids: loadable([i for i in ids if i != "pmid-3"]),
        )
        tab, _ = rerun_tab(monkeypatch, tmp_path, storage)

        tab._on_rerun_clicked()

        [started] = RecordingWorker.started
        assert started["already_scored_ids"] == {"pmid-2"}
        assert [d.id for d in started["retry_documents"]] == ["pmid-2"]
        assert "1 whose scoring failed can no longer be loaded" in tab.progress_label.text()

    def test_the_finish_counts_the_retried_apart(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any, storage: LiteStorage
    ) -> None:
        """Handed on to score, but not called new."""
        record(storage, make_document("2"), UNREACHABLE)
        tab, message_box = rerun_tab(monkeypatch, tmp_path, storage)
        handed_on: list[tuple[Any, ...]] = []
        tab.new_documents_found.connect(lambda *args: handed_on.append(args))
        tab._on_rerun_clicked()

        tab._on_search_finished([make_document("2"), make_document("3")], [])

        assert tab.progress_label.text().startswith(
            "Found 1 new document, and 1 whose scoring failed before."
        )
        [(_, _, documents, _)] = handed_on
        assert [d.id for d in documents] == ["pmid-2", "pmid-3"]
        message_box.information.assert_called_once()

    def test_an_incomplete_search_that_found_only_retries_warns(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any, storage: LiteStorage
    ) -> None:
        """The retried documents go on to score; the warning counts them apart."""
        from bmlibrarian_lite.data_models import (
            RequestFailure,
            RequestFailureKind,
            RetrievalShortfall,
            SearchProvider,
        )

        record(storage, make_document("2"), UNREACHABLE)
        tab, message_box = rerun_tab(monkeypatch, tmp_path, storage)
        handed_on: list[tuple[Any, ...]] = []
        tab.new_documents_found.connect(lambda *args: handed_on.append(args))
        tab._on_rerun_clicked()
        pubmed_down = RetrievalShortfall(
            SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
        )

        tab._on_search_finished([make_document("2")], [pubmed_down])

        [(_, _, documents, shortfalls)] = handed_on
        assert [d.id for d in documents] == ["pmid-2"]
        assert shortfalls == [pubmed_down]
        message_box.warning.assert_called_once()
        _, title, text = message_box.warning.call_args.args
        assert title == "Search Incomplete"
        assert text.startswith(
            "Found no new documents; 1 document whose scoring failed before"
        )

    def test_unreadable_scores_stop_the_rerun_and_say_so(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Guessing which documents to skip would rescore or drop them."""
        storage = MagicMock()
        storage.get_research_questions_summary.return_value = []
        storage.get_rerun_document_ids_for_question.side_effect = SQLiteError("locked")
        tab, message_box = rerun_tab(monkeypatch, tmp_path, storage)

        tab._on_rerun_clicked()

        assert RecordingWorker.started == []
        message_box.warning.assert_called_once()

    def test_unloadable_failed_documents_stop_the_rerun_too(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The split read; loading the documents to retry did not."""
        storage = MagicMock()
        storage.get_research_questions_summary.return_value = []
        storage.get_rerun_document_ids_for_question.return_value = ({"pmid-1"}, {"pmid-2"})
        storage.get_documents.side_effect = sqlite3.Error("disk I/O error")
        tab, message_box = rerun_tab(monkeypatch, tmp_path, storage)

        tab._on_rerun_clicked()

        assert RecordingWorker.started == []
        message_box.warning.assert_called_once()
