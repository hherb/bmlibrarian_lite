# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The GUI tells the user when a search failed or came back incomplete (#247).

Before #247 a rate-limited systematic review ended with "No documents found
for this query.", and the Research Questions tab's search for more documents
ended with "No more results from PubMed" -- both read as the literature being
exhausted. The workers now carry the failure to the tab instead.
"""

from datetime import datetime
from http import HTTPStatus
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite import constants  # noqa: E402
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    DocumentSource,
    LiteDocument,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    ScoredDocument,
    SearchProvider,
    SearchSession,
)
from bmlibrarian_lite.exceptions import SearchFailedError  # noqa: E402
from bmlibrarian_lite.gui import systematic_review_tab  # noqa: E402
from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker  # noqa: E402
from bmlibrarian_lite.gui.workers import IncrementalSearchWorker  # noqa: E402
from bmlibrarian_lite.pubmed import search_client  # noqa: E402
from bmlibrarian_lite.search_failures import retrieval_shortfalls_to_metadata  # noqa: E402
from tests.eutils_answers import (  # noqa: E402
    EFETCH_PATH,
    ESEARCH_PATH,
    esearch_hits,
    pubmed_articles,
)
from tests.scripted_http_server import running, status_answer  # noqa: E402

RATE_LIMITED = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
UNAVAILABLE = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
PUBMED_DOWN = RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED)
NOTICE_START = "> **Incomplete search:**"
QUESTION = "Does aspirin prevent stroke?"


class Recorder:
    """Collects every emission of the signals it is connected to."""

    def __init__(self) -> None:
        """Start with nothing recorded."""
        self.calls: dict[str, list[tuple[Any, ...]]] = {}

    def slot(self, name: str) -> Any:
        """A callable recording its arguments under a name."""

        def record(*args: Any) -> None:
            self.calls.setdefault(name, []).append(args)

        return record


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.EUROPEPMC,
    )


def workflow_worker(
    monkeypatch: pytest.MonkeyPatch, search: tuple[SearchSession, list[LiteDocument]] | Exception
) -> tuple[WorkflowWorker, Recorder]:
    """A review worker whose search and scoring agents answer as scripted.

    Every document scores 1, below the threshold, so the workflow ends at its
    "none scored" exit without calling an LLM.
    """
    search_agent = MagicMock()
    if isinstance(search, Exception):
        search_agent.search.side_effect = search
    else:
        search_agent.search.return_value = search
    monkeypatch.setattr(systematic_review_tab, "LiteSearchAgent", lambda **_: search_agent)

    scoring_agent = MagicMock()
    scoring_agent.score_document.side_effect = lambda question, doc: ScoredDocument(
        document=doc, score=1, explanation="Not relevant."
    )
    monkeypatch.setattr(systematic_review_tab, "LiteScoringAgent", lambda **_: scoring_agent)

    config = LiteConfig()
    monkeypatch.setattr(config.parallel, "get_scoring_workers", lambda provider: 1)
    worker = WorkflowWorker(question=QUESTION, config=config, storage=MagicMock(), min_score=3)
    recorder = Recorder()
    worker.error.connect(recorder.slot("error"))
    worker.finished.connect(recorder.slot("finished"))
    worker.search_incomplete.connect(recorder.slot("search_incomplete"))
    return worker, recorder


def session_with(metadata: dict[str, Any]) -> SearchSession:
    """A search session carrying the given metadata."""
    return SearchSession(
        id="session-1",
        query="aspirin AND stroke",
        natural_language_query=QUESTION,
        created_at=datetime.now(),
        document_count=1,
        metadata=metadata,
    )


class TestTheSystematicReviewWorker:
    """A review never reports a failed search as an empty one."""

    def test_a_failed_search_is_an_error_in_the_search_step(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The #247 symptom was "No documents found for this query."."""
        worker, recorder = workflow_worker(monkeypatch, SearchFailedError([PUBMED_DOWN]))

        worker.run()

        assert "finished" not in recorder.calls
        [(step, message)] = recorder.calls["error"]
        assert step == "search"
        assert "PubMed could not be searched (HTTP 429 Too Many Requests)" in message
        assert "wait a minute and try again" in message

    def test_an_incomplete_search_is_signalled_and_qualifies_the_outcome(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The tab is told at once, and the message standing in for a report says it too."""
        session = session_with(
            {"provider": "both", **retrieval_shortfalls_to_metadata([PUBMED_DOWN])}
        )
        worker, recorder = workflow_worker(monkeypatch, (session, [make_document("1")]))

        worker.run()

        assert recorder.calls["search_incomplete"] == [
            ("PubMed could not be searched (HTTP 429 Too Many Requests)",)
        ]
        [(message, metadata)] = recorder.calls["finished"]
        assert message.startswith(NOTICE_START)
        assert "No documents scored 3 or higher" in message
        assert metadata.search_shortfalls == [PUBMED_DOWN]

    def test_preloaded_documents_keep_the_shortfalls_of_their_search(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Documents from an incomplete search for more are reviewed as incomplete."""
        worker, recorder = workflow_worker(monkeypatch, SearchFailedError([PUBMED_DOWN]))
        worker.preloaded_documents = [make_document("1")]
        worker.preloaded_search_shortfalls = [PUBMED_DOWN]

        worker.run()

        assert recorder.calls["search_incomplete"] == [
            ("PubMed could not be searched (HTTP 429 Too Many Requests)",)
        ]
        [(message, metadata)] = recorder.calls["finished"]
        assert message.startswith(NOTICE_START)
        assert metadata.search_shortfalls == [PUBMED_DOWN]

    def test_a_complete_search_is_not_qualified(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """No failure, no notice and no signal."""
        worker, recorder = workflow_worker(
            monkeypatch, (session_with({"provider": "pubmed"}), [make_document("1")])
        )

        worker.run()

        assert "search_incomplete" not in recorder.calls
        [(message, metadata)] = recorder.calls["finished"]
        assert message.startswith("No documents scored 3 or higher")
        assert metadata.search_shortfalls == []


def incremental_worker(target: int) -> tuple[IncrementalSearchWorker, Recorder]:
    """A search-for-more worker for a fresh question, recording its signals."""
    config = LiteConfig()
    config.pubmed.email = "test@example.com"
    config.pubmed.api_key = "0123456789abcdef0123456789abcdef0123"
    worker = IncrementalSearchWorker(
        question=QUESTION,
        pubmed_query="aspirin AND stroke",
        target_new_docs=target,
        already_scored_ids=set(),
        config=config,
        storage=MagicMock(),
    )
    recorder = Recorder()
    worker.error.connect(recorder.slot("error"))
    worker.finished.connect(recorder.slot("finished"))
    return worker, recorder


@pytest.fixture
def small_batches(monkeypatch: pytest.MonkeyPatch) -> None:
    """Two PMIDs per page, and no waiting between retries."""
    monkeypatch.setattr(constants, "INCREMENTAL_SEARCH_BATCH_SIZE", 2)
    monkeypatch.setattr(search_client, "INITIAL_RETRY_DELAY_SECONDS", 0.0)


def point_client_at(monkeypatch: pytest.MonkeyPatch, url: str) -> None:
    """Send the worker's PubMed requests to a scripted server."""
    monkeypatch.setattr(search_client, "ESEARCH_URL", f"{url}{ESEARCH_PATH}")
    monkeypatch.setattr(search_client, "EFETCH_URL", f"{url}{EFETCH_PATH}")


@pytest.mark.usefixtures("small_batches")
class TestTheIncrementalSearchWorker:
    """Searching for more documents distinguishes the end of the results from a failure."""

    def test_a_failed_first_page_is_an_error(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Before #247 it ended as "No new documents found"."""
        with running({ESEARCH_PATH: [status_answer(HTTPStatus.TOO_MANY_REQUESTS)]}) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        assert "finished" not in recorder.calls
        [(message,)] = recorder.calls["error"]
        assert "PubMed could not be searched (HTTP 429 Too Many Requests)" in message
        assert "An NCBI API key, set in Settings, raises PubMed's limit." in message

    def test_a_failed_later_page_keeps_what_was_found_and_says_why_it_stopped(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Two documents found before the failure are still offered for scoring."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=40),
                status_answer(HTTPStatus.TOO_MANY_REQUESTS),
            ],
            EFETCH_PATH: [pubmed_articles(["1", "2"])],
        }
        with running(script) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["1", "2"]
        assert shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=2)
        ]

    def test_records_that_could_not_be_fetched_are_reported(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A failed efetch batch is counted, not skipped."""
        script = {
            ESEARCH_PATH: [esearch_hits(["1", "2"], count=2), esearch_hits([], count=2)],
            EFETCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)],
        }
        with running(script) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert documents == []
        assert shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, records_missing=2)
        ]

    def test_the_end_of_the_results_carries_no_warning(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A short last page is the end of the results, as before."""
        script = {
            ESEARCH_PATH: [esearch_hits(["1"], count=1)],
            EFETCH_PATH: [pubmed_articles(["1"])],
        }
        with running(script) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["1"]
        assert shortfalls == []

    def test_a_short_page_is_not_the_end_of_the_results(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A page PubMed listed only in part is recorded, and the search goes on."""
        script = {
            ESEARCH_PATH: [esearch_hits(["1"], count=40), esearch_hits(["3", "4"], count=40)],
            EFETCH_PATH: [pubmed_articles(["1"]), pubmed_articles(["3", "4"])],
        }
        with running(script) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=3)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["1", "3", "4"]
        assert shortfalls == [
            RetrievalShortfall(
                SearchProvider.PUBMED,
                RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
                records_missing=1,
            )
        ]

    def test_a_failure_with_nothing_found_reports_every_shortfall(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Records lost earlier are not forgotten when a later page ends the search."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=40),
                status_answer(HTTPStatus.TOO_MANY_REQUESTS),
            ],
            EFETCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)],
        }
        with running(script) as server:
            point_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        assert "finished" not in recorder.calls
        [(message,)] = recorder.calls["error"]
        assert "2 PubMed records could not be retrieved (HTTP 503 Service Unavailable)" in message
        assert "2 PubMed records could not be retrieved (HTTP 429 Too Many Requests)" in message


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class TestTheHandoffToTheReview:
    """Shortfalls travel with documents from Research Questions to the report (#247 review)."""

    def test_the_research_questions_tab_hands_the_shortfalls_on(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The warning dialog is not the only place the user learns of them."""
        from bmlibrarian_lite.gui import research_questions_tab
        from bmlibrarian_lite.gui.research_questions_tab import ResearchQuestionsTab

        monkeypatch.setattr(research_questions_tab, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = MagicMock()
        storage.get_research_questions_summary.return_value = []
        tab = ResearchQuestionsTab(config=config, storage=storage)
        handed_on: list[tuple[Any, ...]] = []
        tab.new_documents_found.connect(lambda *args: handed_on.append(args))
        documents = [make_document("1")]

        tab._on_search_finished(documents, [PUBMED_DOWN])

        [(_, _, docs, shortfalls)] = handed_on
        assert docs == documents
        assert shortfalls == [PUBMED_DOWN]

    def test_the_main_window_passes_them_to_the_review(self) -> None:
        """The window's slot forwards the shortfalls with the documents."""
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = MagicMock()
        documents = [make_document("1")]

        LiteMainWindow._on_new_documents_found(
            window, QUESTION, "aspirin", documents, [PUBMED_DOWN]
        )

        window.systematic_review_tab.set_preloaded_documents.assert_called_once_with(
            documents, "aspirin", [PUBMED_DOWN]
        )

    def test_the_review_tab_gives_them_to_its_worker(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The preloaded review starts knowing its search was incomplete."""
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        started: list[dict[str, Any]] = []

        class RecordingWorker:
            """Records how the tab built its worker; every signal is a mock."""

            def __init__(self, **kwargs: Any) -> None:
                started.append(kwargs)

            def __getattr__(self, name: str) -> MagicMock:
                return MagicMock()

        monkeypatch.setattr(systematic_review_tab, "WorkflowWorker", RecordingWorker)
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = SystematicReviewTab(config=config, storage=MagicMock())
        tab.question_input.setPlainText(QUESTION)

        tab.set_preloaded_documents([make_document("1")], "aspirin", [PUBMED_DOWN])
        tab._run_workflow()

        [kwargs] = started
        assert kwargs["preloaded_search_shortfalls"] == [PUBMED_DOWN]
