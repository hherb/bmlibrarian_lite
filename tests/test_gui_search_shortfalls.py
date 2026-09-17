# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The GUI tells the user when a search failed or came back incomplete (#247).

Before #247 a rate-limited systematic review ended with "No documents found
for this query.", and the Research Questions tab's search for more documents
ended with "No new documents found. All available documents have been
scored." -- both read as the literature being exhausted. The workers now carry
the failure to the tab instead.
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
    point_pubmed_client_at,
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

    def test_a_search_that_matched_nothing_still_says_so(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A genuinely empty search keeps its message, unqualified."""
        worker, recorder = workflow_worker(monkeypatch, (session_with({"provider": "pubmed"}), []))

        worker.run()

        assert "search_incomplete" not in recorder.calls
        assert recorder.calls["finished"][0][0] == "No documents found for this query."

    def test_the_quality_filter_message_carries_the_notice(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """"No documents passed quality filter" means less when a provider never answered."""
        session = session_with(
            {"provider": "both", **retrieval_shortfalls_to_metadata([PUBMED_DOWN])}
        )
        worker, recorder = workflow_worker(monkeypatch, (session, [make_document("1")]))
        worker.quality_filter = MagicMock()
        worker.quality_filter.minimum_tier.value = 1
        worker.quality_manager = MagicMock()
        worker.quality_manager.filter_documents.return_value = ([], [])

        worker.run()

        [(message, _)] = recorder.calls["finished"]
        assert message.startswith(NOTICE_START)
        assert "No documents passed quality filter" in message


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


@pytest.mark.usefixtures("small_batches")
class TestTheIncrementalSearchWorker:
    """Searching for more documents distinguishes the end of the results from a failure."""

    def test_a_failed_first_page_is_an_error(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Before #247 it ended as "No new documents found"."""
        with running({ESEARCH_PATH: [status_answer(HTTPStatus.TOO_MANY_REQUESTS)]}) as server:
            point_pubmed_client_at(monkeypatch, server.url)
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
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["1", "2"]
        assert shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=2)
        ]

    def test_records_that_could_not_be_fetched_and_nothing_new_is_an_error(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A failed efetch batch is counted, and leaving nothing new it is no empty result."""
        script = {
            ESEARCH_PATH: [esearch_hits(["1", "2"], count=2)],
            EFETCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)],
        }
        with running(script) as server:
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        assert "finished" not in recorder.calls
        [(message,)] = recorder.calls["error"]
        assert message == (
            "The search could not be completed: 2 PubMed records could not be "
            "retrieved (HTTP 503 Service Unavailable).\n\nTry again later."
        )

    def test_records_that_could_not_be_fetched_are_reported_with_what_was_found(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A failed batch costs that batch; the search goes on, and says one clause per failure."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=6),
                esearch_hits(["3", "4"], count=6),
                esearch_hits(["5", "6"], count=6),
            ],
            # Each failed batch is tried three times.
            EFETCH_PATH: [status_answer(HTTPStatus.SERVICE_UNAVAILABLE)] * 6
            + [pubmed_articles(["5", "6"])],
        }
        with running(script) as server:
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["5", "6"]
        assert shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, UNAVAILABLE, records_missing=4)
        ]

    def test_a_full_last_page_is_the_end_and_no_page_past_it_is_asked_for(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A request past the end could only fail as "0 PubMed records could not be retrieved"."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=2),
                status_answer(HTTPStatus.TOO_MANY_REQUESTS),
            ],
            EFETCH_PATH: [pubmed_articles(["1", "2"])],
        }
        with running(script) as server:
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

            assert len(server.requests_to(ESEARCH_PATH)) == 1

        [(documents, shortfalls)] = recorder.calls["finished"]
        assert [document.pmid for document in documents] == ["1", "2"]
        assert shortfalls == []

    def test_a_complete_search_of_scored_documents_is_not_a_failure(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every result already scored: "no new documents", not "could not be completed"."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=2),
                status_answer(HTTPStatus.TOO_MANY_REQUESTS),
            ],
            EFETCH_PATH: [pubmed_articles(["1", "2"])],
        }
        with running(script) as server:
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)
            worker.already_scored_ids = {"pmid-1", "pmid-2"}

            worker.run()

        assert "error" not in recorder.calls
        assert recorder.calls["finished"] == [([], [])]

    def test_a_failed_last_page_counts_only_the_records_left(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Three results in pages of two: the failed second page held one."""
        script = {
            ESEARCH_PATH: [
                esearch_hits(["1", "2"], count=3),
                status_answer(HTTPStatus.TOO_MANY_REQUESTS),
            ],
            EFETCH_PATH: [pubmed_articles(["1", "2"])],
        }
        with running(script) as server:
            point_pubmed_client_at(monkeypatch, server.url)
            worker, recorder = incremental_worker(target=5)

            worker.run()

        [(_, shortfalls)] = recorder.calls["finished"]
        assert shortfalls == [
            RetrievalShortfall(SearchProvider.PUBMED, RATE_LIMITED, records_missing=1)
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
            point_pubmed_client_at(monkeypatch, server.url)
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
            point_pubmed_client_at(monkeypatch, server.url)
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
            point_pubmed_client_at(monkeypatch, server.url)
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


def research_questions_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> tuple[Any, MagicMock]:
    """A Research Questions tab over empty storage, its message boxes mocked."""
    from bmlibrarian_lite.gui import research_questions_tab as module
    from bmlibrarian_lite.gui.research_questions_tab import ResearchQuestionsTab

    message_box = MagicMock()
    monkeypatch.setattr(module, "QMessageBox", message_box)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = MagicMock()
    storage.get_research_questions_summary.return_value = []
    return ResearchQuestionsTab(config=config, storage=storage), message_box


class RecordingWorker:
    """Stands in for the review worker: records its arguments; each signal a lasting mock."""

    started: list[dict[str, Any]] = []

    def __init__(self, **kwargs: Any) -> None:
        """Record how the tab built the worker."""
        RecordingWorker.started.append(kwargs)
        self._signals: dict[str, MagicMock] = {}

    def __getattr__(self, name: str) -> MagicMock:
        """The same mock for a name every time, so connections can be checked."""
        return self.__dict__["_signals"].setdefault(name, MagicMock())


def review_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> tuple[Any, MagicMock]:
    """A Systematic Review tab whose worker records and whose message boxes are mocked."""
    from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

    RecordingWorker.started = []
    monkeypatch.setattr(systematic_review_tab, "WorkflowWorker", RecordingWorker)
    message_box = MagicMock()
    monkeypatch.setattr(systematic_review_tab, "QMessageBox", message_box)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    tab = SystematicReviewTab(config=config, storage=MagicMock())
    tab.question_input.setPlainText(QUESTION)
    return tab, message_box


class TestTheResearchQuestionsTab:
    """The tab never reports a failed search for more as one that ran out of documents."""

    def test_nothing_retrieved_with_shortfalls_is_not_the_end_of_the_results(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """"No new documents found. All available documents have been scored." was #247."""
        tab, message_box = research_questions_tab(monkeypatch, tmp_path)
        handed_on: list[tuple[Any, ...]] = []
        tab.new_documents_found.connect(lambda *args: handed_on.append(args))

        tab._on_search_finished([], [PUBMED_DOWN])

        label = tab.progress_label.text()
        assert "No new documents found" not in label
        assert "PubMed could not be searched (HTTP 429 Too Many Requests)" in label
        message_box.warning.assert_called_once()
        message_box.information.assert_not_called()
        assert handed_on == []

    def test_documents_from_an_incomplete_search_come_with_a_warning(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Not the "Search Complete" dialog."""
        tab, message_box = research_questions_tab(monkeypatch, tmp_path)

        tab._on_search_finished([make_document("1")], [PUBMED_DOWN])

        message_box.warning.assert_called_once()
        message_box.information.assert_not_called()

    def test_a_complete_search_with_nothing_new_says_so(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The end of the results still reads as the end of the results."""
        tab, message_box = research_questions_tab(monkeypatch, tmp_path)

        tab._on_search_finished([], [])

        assert tab.progress_label.text().startswith("No new documents found")
        message_box.warning.assert_not_called()


class TestTheSystematicReviewTab:
    """The tab shows what the worker says about the search, and recovers from any error."""

    def test_an_empty_error_message_still_resets_the_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """``str(TimeoutError())`` is empty; the Run button must not stay disabled."""
        tab, _ = review_tab(monkeypatch, tmp_path)
        tab.run_btn.setEnabled(False)

        tab._on_error("workflow", str(TimeoutError()))

        assert tab.run_btn.isEnabled()
        assert tab.progress_label.text() == "Error in workflow: "

    def test_an_error_from_a_step_without_a_dialog_shows_in_full(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Without a dialog, the label is the only place the message appears.

        The steps that end the review -- search, scoring and report (#261,
        #262) -- get a dialog instead; see test_gui_analysis_failures.py.
        """
        tab, message_box = review_tab(monkeypatch, tmp_path)

        tab._on_error("workflow", "The model failed.\nIt answered nothing.")

        assert tab.progress_label.text() == "Error in workflow: The model failed.\nIt answered nothing."
        message_box.warning.assert_not_called()

    def test_a_failed_search_gets_a_dialog_with_the_whole_message(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """What failed and what to do next are too long for the progress label."""
        tab, message_box = review_tab(monkeypatch, tmp_path)
        message = "The search could not be completed: PubMed ….\n\nTry again later."

        tab._on_error("search", message)

        assert tab.progress_label.text() == "Error in search: The search could not be completed: PubMed …."
        message_box.warning.assert_called_once_with(tab, "Search Failed", message)

    def test_the_incomplete_search_warning_is_shown_and_cleared(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Shown for an incomplete search, gone for a complete one and at the next run."""
        tab, _ = review_tab(monkeypatch, tmp_path)

        tab.set_preloaded_documents([make_document("1")], "aspirin", [PUBMED_DOWN])
        assert not tab.search_notice_label.isHidden()
        assert "PubMed could not be searched" in tab.search_notice_label.text()

        tab.set_preloaded_documents([make_document("2")], "aspirin", [])
        assert tab.search_notice_label.isHidden()

        tab._on_search_incomplete("PubMed could not be searched (HTTP 429 Too Many Requests)")
        tab._run_workflow()
        assert tab.search_notice_label.isHidden()

    def test_the_worker_signal_reaches_the_warning(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The tab listens to the worker's search_incomplete signal."""
        tab, _ = review_tab(monkeypatch, tmp_path)

        tab._run_workflow()

        tab._worker.search_incomplete.connect.assert_called_once_with(tab._on_search_incomplete)


class TestTheReportTab:
    """A message standing in for a report is not saved as one, notice or not."""

    @pytest.mark.parametrize(
        "report, saved",
        [
            ("No documents scored 3 or higher.", False),
            ("> **Incomplete search:** PubMed could not be searched.\n\nNo documents scored 3 or higher.", False),
            ("> **Incomplete search:** PubMed could not be searched.\n\n# Evidence Report", True),
            ("# Evidence Report", True),
        ],
        ids=["stand-in", "stand-in-with-notice", "report-with-notice", "report"],
    )
    def test_only_a_report_is_auto_saved(
        self,
        qapp: Any,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        report: str,
        saved: bool,
    ) -> None:
        """The #247 notice in front of a stand-in message made it look like a report."""
        from bmlibrarian_lite.gui.report_tab import ReportTab

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = ReportTab(config=config, storage=MagicMock())
        auto_save = MagicMock()
        monkeypatch.setattr(tab, "_auto_save_report", auto_save)

        tab.display_report(report, QUESTION, [], [], [])

        assert auto_save.called is saved


class TestTheHandoffToTheReview:
    """Shortfalls travel with documents from Research Questions to the report."""

    def test_the_research_questions_tab_hands_the_shortfalls_on(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The warning dialog is not the only place the user learns of them."""
        tab, _ = research_questions_tab(monkeypatch, tmp_path)
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
        tab, _ = review_tab(monkeypatch, tmp_path)

        tab.set_preloaded_documents([make_document("1")], "aspirin", [PUBMED_DOWN])
        tab._run_workflow()

        [kwargs] = RecordingWorker.started
        assert kwargs["preloaded_search_shortfalls"] == [PUBMED_DOWN]
