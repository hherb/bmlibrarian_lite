# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Cancelling a benchmark stops it, and says what it evaluated (#324).

``BenchmarkWorker.cancel`` and ``QualityBenchmarkWorker.cancel`` only set a
flag neither runner could see. The flag muted the progress callback and
suppressed the terminal signal, so a cancelled benchmark went on calling
every model for every document -- **spending** -- and then threw its result
away. On the Systematic Review tab the Cancel re-enabled the Benchmark button
at once, so a second benchmark could start while the first thread was still
live, and its modal progress dialog was never closed. On the Research
Questions tab Cancel was disabled for a benchmark, because a cancel that only
dropped the result was worth less than none.

Both runners are now asked ``should_cancel`` before each evaluation, so a
cancel stops the run before it pays for one more. What ran before the cancel
is real: it is kept, stored as ``BenchmarkStatus.CANCELLED`` rather than
complete, and carried on the result as a
:class:`~bmlibrarian_lite.benchmarking.models.BenchmarkCancellation` so a
partial comparison never reads as a whole one. Cancelling is not failing, but
a failure mid-cancel is still named (golden rule 8).
"""

import json
from typing import Any
from unittest.mock import MagicMock

import pytest

from bmlibrarian_lite.benchmarking.display import (
    benchmark_cancelled_text,
    evaluations_text,
    partial_result_note,
)
from bmlibrarian_lite.benchmarking.models import (
    BenchmarkCancellation,
    BenchmarkResult,
)
from bmlibrarian_lite.benchmarking.quality_models import QualityBenchmarkResult
from bmlibrarian_lite.benchmarking.quality_runner import QualityBenchmarkRunner
from bmlibrarian_lite.benchmarking.runner import BenchmarkRunner
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.data_models import (
    BenchmarkStatus,
    DocumentSource,
    LiteDocument,
)
from bmlibrarian_lite.llm import LLMResponse
from bmlibrarian_lite.storage import LiteStorage

QUESTION = "Does aspirin prevent stroke?"
MODEL = "ollama:judge"
OTHER_MODEL = "ollama:second-judge"
ON_TOPIC = '{"score": 4, "explanation": "On topic."}'
RCT_ANSWER = json.dumps({"study_design": "rct", "confidence": 0.9})
#: Provider error text prints the request, which can carry a credential.
LEAKY_ERROR = "Connection refused: http://localhost:11434/api/chat?key=SECRET"


def make_document(pmid: str) -> LiteDocument:
    """A minimal document."""
    return LiteDocument(
        id=f"doc-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin reduced stroke incidence.",
        authors=["Smith J"],
        year=2024,
        journal="Journal",
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


class CountingClient:
    """An LLM client that answers every call, and counts them."""

    def __init__(self, answer: str) -> None:
        """Answer every call with the same body.

        Args:
            answer: The response body.
        """
        self.answer = answer
        self.calls = 0

    def chat(self, messages: Any, model: str, **_: Any) -> LLMResponse:
        """Answer one call.

        Args:
            messages: Ignored.
            model: Ignored.

        Returns:
            The scripted response.
        """
        self.calls += 1
        return LLMResponse(content=self.answer, input_tokens=100, output_tokens=20)


class CancelAfter:
    """A ``should_cancel`` that answers False a given number of times."""

    def __init__(self, evaluations: int) -> None:
        """Let this many evaluations run before asking for a stop.

        Args:
            evaluations: How many times to answer False.
        """
        self.remaining = evaluations
        self.asked = 0

    def __call__(self) -> bool:
        """Whether the run should stop now."""
        self.asked += 1
        if self.remaining > 0:
            self.remaining -= 1
            return False
        return True


@pytest.fixture
def storage(tmp_path: Any) -> LiteStorage:
    """A database this test owns."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    return LiteStorage(config)


def relevance_runner(storage: LiteStorage, client: CountingClient) -> BenchmarkRunner:
    """A relevance runner calling the counting client."""
    runner = BenchmarkRunner(config=storage.config, storage=storage)
    runner._llm_client = client  # type: ignore[assignment]
    return runner


def quality_runner(
    storage: LiteStorage, client: CountingClient
) -> QualityBenchmarkRunner:
    """A quality runner calling the counting client."""
    runner = QualityBenchmarkRunner(config=storage.config, storage=storage)
    runner._llm_client = client  # type: ignore[assignment]
    return runner


class TestWhatACancelledRunHadDone:
    """``BenchmarkCancellation`` refuses counts a run cannot have had."""

    def test_it_holds_what_was_made_and_what_was_planned(self) -> None:
        """The two counts the message and the note are built from."""
        cancellation = BenchmarkCancellation(
            evaluations_made=12, evaluations_planned=40
        )

        assert cancellation.evaluations_made == 12
        assert cancellation.evaluations_planned == 40
        assert cancellation.evaluations_skipped == 28

    def test_a_run_stopped_before_its_first_evaluation_is_representable(self) -> None:
        """Cancelling at once is the case that costs nothing, and must state it."""
        assert BenchmarkCancellation(0, 40).evaluations_skipped == 40

    @pytest.mark.parametrize(
        "made, planned",
        [
            (-1, 40),
            (12, -1),
            # Repaired with max() instead, this would read as a finished run
            (41, 40),
        ],
    )
    def test_an_impossible_pair_is_refused(self, made: int, planned: int) -> None:
        """Refused, never repaired: a repaired count is a false statement."""
        with pytest.raises(ValueError):
            BenchmarkCancellation(made, planned)

    def test_a_stored_cancellation_reads_back(self) -> None:
        """A stored partial result must not read back as a whole one."""
        stored = BenchmarkCancellation(3, 9).to_dict()

        assert BenchmarkCancellation.from_stored(stored) == BenchmarkCancellation(3, 9)

    @pytest.mark.parametrize(
        "stored",
        [
            None,
            "cancelled",
            {},
            {"evaluations_made": 3},
            {"evaluations_made": "3", "evaluations_planned": 9},
            # bool is an int, and True would read as "one evaluation made"
            {"evaluations_made": True, "evaluations_planned": 9},
            # Damage must not make a complete result look partial
            {"evaluations_made": 12, "evaluations_planned": 9},
            {"evaluations_made": -1, "evaluations_planned": 9},
        ],
    )
    def test_a_summary_that_states_no_cancellation_reads_as_none(
        self, stored: object
    ) -> None:
        """Read as input (golden rule 1): a run is not made partial by damage."""
        assert BenchmarkCancellation.from_stored(stored) is None


class TestWhatACancelledBenchmarkSays:
    """The message is a pure function of the counts."""

    def test_it_names_what_was_made_of_what_was_planned(self) -> None:
        """"Benchmark cancelled" alone said nothing about the spend."""
        text = benchmark_cancelled_text(BenchmarkCancellation(12, 40))

        assert "12 of 40 evaluations" in text
        assert "The other 28 were not made, and were not paid for." in text
        assert "What was evaluated is kept." in text

    def test_one_evaluation_left_is_said_in_the_singular(self) -> None:
        """A count and its words agree."""
        assert "The other one was not made" in benchmark_cancelled_text(
            BenchmarkCancellation(3, 4)
        )

    def test_a_run_that_evaluated_nothing_claims_to_keep_nothing(self) -> None:
        """"What was evaluated is kept" over nothing is an empty promise."""
        text = benchmark_cancelled_text(BenchmarkCancellation(0, 9))

        assert "0 of 9 evaluations" in text
        assert "What was evaluated is kept." not in text

    def test_a_run_a_cancel_could_not_shorten_says_nothing_was_skipped(self) -> None:
        """Nothing was left out, so nothing is claimed to have been."""
        assert "not paid for" not in benchmark_cancelled_text(
            BenchmarkCancellation(9, 9)
        )

    def test_an_error_that_also_ended_the_run_is_named(self) -> None:
        """A crash mid-cancel read as an orderly stop (golden rule 8)."""
        text = benchmark_cancelled_text(BenchmarkCancellation(3, 9), "Provider down")

        assert "It also stopped on an error: Provider down" in text

    def test_no_error_adds_no_clause(self) -> None:
        """An orderly cancel is not dressed up as a failure."""
        assert "error" not in benchmark_cancelled_text(BenchmarkCancellation(3, 9))

    def test_one_evaluation_is_counted_in_the_singular(self) -> None:
        """The shared counter the message and the note use."""
        assert evaluations_text(1) == "1 evaluation"
        assert evaluations_text(2) == "2 evaluations"


class TestAPartialResultSaysSo:
    """A reader must not take a cancelled comparison for a whole one."""

    def test_a_complete_run_needs_no_note(self) -> None:
        """Nothing was cut short, so nothing is qualified."""
        assert partial_result_note(None) is None

    def test_a_cancelled_run_names_its_counts_and_its_uneven_models(self) -> None:
        """The cancel reaches the last model first, so it was asked less."""
        note = partial_result_note(BenchmarkCancellation(12, 40))

        assert note is not None
        assert "12 of 40 evaluations" in note
        assert "fewer documents" in note


class TestTheRelevanceRunnerHonoursACancel:
    """The heart of #324: a cancel stops the spending."""

    def test_a_cancel_before_the_first_evaluation_makes_no_call(
        self, storage: LiteStorage
    ) -> None:
        """It went on calling every model for every document regardless."""
        client = CountingClient(ON_TOPIC)
        documents = [make_document(str(n)) for n in range(3)]

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL, OTHER_MODEL],
            should_cancel=lambda: True,
        )

        assert client.calls == 0
        assert result.cancellation == BenchmarkCancellation(0, 6)

    def test_a_cancel_part_way_stops_at_the_next_evaluation(
        self, storage: LiteStorage
    ) -> None:
        """Two documents were paid for, and the other four were not."""
        client = CountingClient(ON_TOPIC)
        documents = [make_document(str(n)) for n in range(3)]

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL, OTHER_MODEL],
            should_cancel=CancelAfter(2),
        )

        assert client.calls == 2
        assert result.cancellation == BenchmarkCancellation(2, 6)

    def test_what_it_evaluated_is_kept(self, storage: LiteStorage) -> None:
        """The run was paid for; dropping it would charge for it twice."""
        client = CountingClient(ON_TOPIC)
        documents = [make_document(str(n)) for n in range(3)]

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL],
            should_cancel=CancelAfter(2),
        )

        assert len(result.document_comparisons) == 2
        assert result.total_evaluations == 2
        # And reachable for reuse: bought again, the user pays twice for
        # what the cancel did not stop in time
        reusable = storage.get_all_scores_for_question(
            QUESTION, [d.id for d in documents]
        )
        assert sum(len(by_document) for by_document in reusable.values()) == 2

    def test_the_run_is_stored_as_cancelled(self, storage: LiteStorage) -> None:
        """Stored as complete, a partial run read as the question's benchmark."""
        client = CountingClient(ON_TOPIC)

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(1),
        )

        run = storage.get_benchmark_run(result.run_id)
        assert run is not None
        assert run.status == BenchmarkStatus.CANCELLED

    def test_a_cancelled_run_is_not_the_questions_latest_benchmark(
        self, storage: LiteStorage
    ) -> None:
        """Only a run that reached the end answers for the question."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(1),
        )

        assert runner.get_latest_benchmark_result_for_question(QUESTION) is None

    def test_a_run_nobody_cancelled_is_complete(self, storage: LiteStorage) -> None:
        """The ordinary case keeps its status and carries no cancellation."""
        client = CountingClient(ON_TOPIC)
        documents = [make_document(str(n)) for n in range(3)]

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL],
            should_cancel=lambda: False,
        )

        assert client.calls == 3
        assert result.cancellation is None
        run = storage.get_benchmark_run(result.run_id)
        assert run is not None
        assert run.status == BenchmarkStatus.COMPLETED

    def test_a_run_asked_nothing_is_complete(self, storage: LiteStorage) -> None:
        """``should_cancel`` is optional; every other caller is unchanged."""
        client = CountingClient(ON_TOPIC)

        result = relevance_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(2)],
            models=[MODEL],
        )

        assert client.calls == 2
        assert result.cancellation is None

    def test_a_stored_partial_result_reads_back_as_partial(
        self, storage: LiteStorage
    ) -> None:
        """Read back without it, the result would look like a whole run."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        result = runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(2),
        )

        loaded = runner.get_benchmark_result(result.run_id)

        assert loaded is not None
        assert loaded.cancellation == BenchmarkCancellation(2, 3)

    def test_a_stored_complete_result_reads_back_as_complete(
        self, storage: LiteStorage
    ) -> None:
        """The control: nothing marks an ordinary run partial."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        result = runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )

        loaded = runner.get_benchmark_result(result.run_id)

        assert loaded is not None
        assert loaded.cancellation is None


class TestTheQualityRunnerHonoursACancel:
    """The quality benchmark spends the same way, and stops the same way."""

    def test_a_cancel_before_the_first_evaluation_makes_no_call(
        self, storage: LiteStorage
    ) -> None:
        """It went on assessing every document with every model regardless."""
        client = CountingClient(RCT_ANSWER)

        result = quality_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL, OTHER_MODEL],
            should_cancel=lambda: True,
        )

        assert client.calls == 0
        assert result.cancellation == BenchmarkCancellation(0, 6)

    def test_a_cancel_part_way_stops_at_the_next_evaluation(
        self, storage: LiteStorage
    ) -> None:
        """What was assessed is kept; what was not was not paid for."""
        client = CountingClient(RCT_ANSWER)

        result = quality_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL, OTHER_MODEL],
            should_cancel=CancelAfter(2),
        )

        assert client.calls == 2
        assert result.cancellation == BenchmarkCancellation(2, 6)
        assert len(result.document_comparisons) == 2

    def test_the_run_is_stored_as_cancelled(self, storage: LiteStorage) -> None:
        """Stored as complete, a partial run read as a whole one."""
        result = quality_runner(storage, CountingClient(RCT_ANSWER)).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(1),
        )

        run = storage.get_benchmark_run(result.run_id)
        assert run is not None
        assert run.status == BenchmarkStatus.CANCELLED

    def test_a_run_nobody_cancelled_is_complete(self, storage: LiteStorage) -> None:
        """The ordinary case is unchanged."""
        client = CountingClient(RCT_ANSWER)

        result = quality_runner(storage, client).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
        )

        assert client.calls == 3
        assert result.cancellation is None
        run = storage.get_benchmark_run(result.run_id)
        assert run is not None
        assert run.status == BenchmarkStatus.COMPLETED


pytest.importorskip("PySide6")

from bmlibrarian_lite.gui import research_questions_tab as questions_module  # noqa: E402
from bmlibrarian_lite.gui import systematic_review_tab as review_module  # noqa: E402
from bmlibrarian_lite.gui.benchmark_dialog import BenchmarkWorker  # noqa: E402
from bmlibrarian_lite.gui.benchmark_results_dialog import (  # noqa: E402
    BenchmarkResultsTab,
)
from bmlibrarian_lite.gui.quality_benchmark_dialog import (  # noqa: E402
    QualityBenchmarkWorker,
)
from bmlibrarian_lite.gui.quality_benchmark_results_dialog import (  # noqa: E402
    QualityBenchmarkResultsTab,
)

TERMINAL_SIGNALS = ("finished", "error", "cancelled")


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class Recorder:
    """Collects every emission of the terminal signals it is connected to."""

    def __init__(self, worker: Any) -> None:
        """Connect to the worker's terminal signals.

        Args:
            worker: The worker to watch.
        """
        self.calls: dict[str, list[tuple[Any, ...]]] = {}
        for name in TERMINAL_SIGNALS:
            getattr(worker, name).connect(self._slot(name))

    def _slot(self, name: str) -> Any:
        """A slot recording one signal's emissions.

        Args:
            name: The signal's name.

        Returns:
            The slot.
        """

        def record(*args: Any) -> None:
            self.calls.setdefault(name, []).append(args)

        return record

    def only(self) -> tuple[str, tuple[Any, ...]]:
        """The one terminal signal emitted, and its arguments."""
        [(name, calls)] = self.calls.items()
        [args] = calls
        return name, args


def partial(cancellation: BenchmarkCancellation | None) -> Any:
    """A result the runner would return, cancelled or not.

    Args:
        cancellation: What the run had evaluated, or None.

    Returns:
        A ``BenchmarkResult`` carrying it.
    """
    return BenchmarkResult(
        run_id="run",
        question=QUESTION,
        task_type="document_scoring",
        evaluator_stats=[],
        document_comparisons=[],
        agreement_matrix={},
        cancellation=cancellation,
    )


def make_worker(kind: type, answer: Any) -> Any:
    """A benchmark worker whose runner answers as told.

    Args:
        kind: ``BenchmarkWorker`` or ``QualityBenchmarkWorker``.
        answer: The result to return, or an exception to raise.

    Returns:
        The worker, with its runner class patched in its module.
    """
    worker = kind(
        config=LiteConfig(),
        storage=MagicMock(),
        question=QUESTION,
        documents=[make_document("1")],
        models=[MODEL],
    )

    def run_quick_benchmark(**kwargs: Any) -> Any:
        if isinstance(answer, Exception):
            raise answer
        return answer

    runner = MagicMock()
    runner.run_quick_benchmark.side_effect = run_quick_benchmark
    worker._runner_for_test = runner
    return worker


class TestABenchmarkWorkerEndsExactlyOnce:
    """The #320 contract, now covering both benchmark workers."""

    @pytest.fixture(params=[BenchmarkWorker, QualityBenchmarkWorker])
    def kind(self, request: Any) -> type:
        """Each benchmark worker in turn."""
        return request.param

    def worker_running(
        self, kind: type, monkeypatch: pytest.MonkeyPatch, answer: Any
    ) -> Any:
        """A worker whose runner answers as told, already run.

        Args:
            kind: The worker class.
            monkeypatch: Used to replace the runner the worker builds.
            answer: The result to return, or an exception to raise.

        Returns:
            The recorder of its terminal signals, and the worker.
        """
        module = (
            "bmlibrarian_lite.benchmarking.BenchmarkRunner"
            if kind is BenchmarkWorker
            else "bmlibrarian_lite.benchmarking.QualityBenchmarkRunner"
        )

        class Runner:
            """Stands in for the real runner."""

            def __init__(self, *_: Any, **__: Any) -> None:
                """Accept whatever the worker passes."""

            def run_quick_benchmark(self, **kwargs: Any) -> Any:
                """Answer as the test told it to.

                Args:
                    kwargs: Ignored except for ``should_cancel``.

                Returns:
                    The scripted result.

                Raises:
                    Exception: When the script says so.
                """
                self.should_cancel = kwargs.get("should_cancel")
                if isinstance(answer, Exception):
                    raise answer
                return answer

        monkeypatch.setattr(module, Runner)
        worker = kind(
            config=LiteConfig(),
            storage=MagicMock(),
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )
        recorder = Recorder(worker)
        return recorder, worker

    def test_a_finished_run_emits_finished(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The ordinary case."""
        result = partial(None)
        recorder, worker = self.worker_running(kind, monkeypatch, result)

        worker.run()

        assert recorder.only() == ("finished", (result,))

    def test_a_cancelled_run_emits_its_partial_result(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Dropped, the run the user paid for was lost."""
        result = partial(BenchmarkCancellation(2, 6))
        recorder, worker = self.worker_running(kind, monkeypatch, result)
        worker.cancel()

        worker.run()

        assert recorder.only() == ("cancelled", (result, ""))

    def test_a_cancel_that_stopped_nothing_leaves_the_run_finished(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A cancel after the last evaluation must not throw the result away."""
        result = partial(None)
        recorder, worker = self.worker_running(kind, monkeypatch, result)
        worker.cancel()  # too late: the runner never saw it

        worker.run()

        assert recorder.only() == ("finished", (result,))

    def test_a_failure_is_an_error(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing was cancelled, so nothing reads as an orderly stop."""
        recorder, worker = self.worker_running(
            kind, monkeypatch, RuntimeError("Provider down")
        )

        worker.run()

        name, args = recorder.only()
        assert name == "error"
        assert "Provider down" in args[0]

    def test_a_failure_mid_cancel_is_named_on_the_cancel(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Cancelling is not failing, but a failure is never hidden."""
        recorder, worker = self.worker_running(
            kind, monkeypatch, RuntimeError("Provider down")
        )
        worker.cancel()

        worker.run()

        name, args = recorder.only()
        assert name == "cancelled"
        assert args[0] is None
        assert "Provider down" in args[1]

    def test_the_runner_is_given_a_way_to_see_the_cancel(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The whole of #324: without this the runner spends on regardless."""
        seen: list[Any] = []

        module = (
            "bmlibrarian_lite.benchmarking.BenchmarkRunner"
            if kind is BenchmarkWorker
            else "bmlibrarian_lite.benchmarking.QualityBenchmarkRunner"
        )

        class Runner:
            """Records the ``should_cancel`` it was given."""

            def __init__(self, *_: Any, **__: Any) -> None:
                """Accept whatever the worker passes."""

            def run_quick_benchmark(self, **kwargs: Any) -> Any:
                """Record ``should_cancel`` and answer.

                Args:
                    kwargs: The worker's arguments.

                Returns:
                    A complete result.
                """
                seen.append(kwargs.get("should_cancel"))
                return partial(None)

        monkeypatch.setattr(module, Runner)
        worker = kind(
            config=LiteConfig(),
            storage=MagicMock(),
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )
        worker.run()

        [should_cancel] = seen
        assert should_cancel is not None
        assert should_cancel() is False
        worker.cancel()
        assert should_cancel() is True

    def test_a_body_that_raises_before_the_runner_still_ends_the_run(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Ending in silence is what left the tab stuck (#320)."""
        module = (
            "bmlibrarian_lite.benchmarking.BenchmarkRunner"
            if kind is BenchmarkWorker
            else "bmlibrarian_lite.benchmarking.QualityBenchmarkRunner"
        )

        def explode(*_: Any, **__: Any) -> Any:
            raise ImportError("no runner here")

        monkeypatch.setattr(module, explode)
        worker = kind(
            config=LiteConfig(),
            storage=MagicMock(),
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )
        recorder = Recorder(worker)

        worker.run()

        name, args = recorder.only()
        assert name == "error"
        assert "no runner here" in args[0]


class TestTheSystematicReviewTabWaitsForTheThread:
    """Re-enabling Benchmark at once let a second run start on the first."""

    @pytest.fixture
    def tab(self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
        """The tab, with its timer and dialogs stubbed out."""
        monkeypatch.setattr(review_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(review_module, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = review_module.SystematicReviewTab(config=config, storage=MagicMock())
        tab._benchmark_worker = MagicMock()
        tab._benchmark_progress_dialog = MagicMock()
        tab._quality_benchmark_worker = MagicMock()
        tab._quality_benchmark_progress_dialog = MagicMock()
        return tab

    def test_cancelling_leaves_benchmark_disabled(self, tab: Any) -> None:
        """A second benchmark would overwrite a thread still live and spending."""
        tab.benchmark_btn.setEnabled(False)

        tab._cancel_benchmark()

        assert tab._benchmark_worker.cancel.called
        assert not tab.benchmark_btn.isEnabled()

    def test_cancelling_quality_leaves_it_disabled(self, tab: Any) -> None:
        """The same for the quality benchmark."""
        tab.quality_benchmark_btn.setEnabled(False)

        tab._cancel_quality_benchmark()

        assert tab._quality_benchmark_worker.cancel.called
        assert not tab.quality_benchmark_btn.isEnabled()

    def test_the_cancel_ends_by_closing_the_modal_dialog(self, tab: Any) -> None:
        """It was left on screen with a dead Cancel button."""
        dialog = tab._benchmark_progress_dialog

        tab._on_benchmark_cancelled(partial(BenchmarkCancellation(2, 6)), "")

        assert dialog.close.called
        assert tab.benchmark_btn.isEnabled()

    def test_the_quality_cancel_ends_by_closing_its_dialog(self, tab: Any) -> None:
        """The same for the quality benchmark."""
        dialog = tab._quality_benchmark_progress_dialog

        tab._on_quality_benchmark_cancelled(None, "")

        assert dialog.close.called
        assert tab.quality_benchmark_btn.isEnabled()

    def test_a_partial_result_is_shown_rather_than_dropped(self, tab: Any) -> None:
        """It was paid for; dropping it charges the user for it twice."""
        shown: list[Any] = []
        tab.benchmark_completed.connect(shown.append)
        result = partial(BenchmarkCancellation(2, 6))

        tab._on_benchmark_cancelled(result, "")

        assert shown == [result]
        assert "2 of 6 evaluations" in tab.progress_label.text()

    def test_a_partial_quality_result_is_shown_rather_than_dropped(
        self, tab: Any
    ) -> None:
        """The same for the quality benchmark."""
        shown: list[Any] = []
        tab.quality_benchmark_completed.connect(shown.append)
        result = QualityBenchmarkResult(
            run_id="run",
            question=QUESTION,
            task_type="study_classification",
            evaluator_stats=[],
            document_comparisons=[],
            design_agreement_matrix={},
            tier_agreement_matrix={},
            cancellation=BenchmarkCancellation(2, 6),
        )

        tab._on_quality_benchmark_cancelled(result, "")

        assert shown == [result]
        assert "2 of 6 evaluations" in tab.progress_label.text()

    def test_a_cancel_with_no_result_still_returns_the_tab_to_ready(
        self, tab: Any
    ) -> None:
        """The run stopped before a result could be computed."""
        tab._on_benchmark_cancelled(None, "Provider down")

        assert tab.benchmark_btn.isEnabled()
        assert "Provider down" in tab.progress_label.text()


class TestTheResearchQuestionsTabCanCancelABenchmark:
    """Cancel was disabled for a benchmark, because it could not stop one."""

    @pytest.fixture
    def tab(self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
        """The tab, with its timer stubbed out."""
        monkeypatch.setattr(questions_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(questions_module, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return questions_module.ResearchQuestionsTab(
            config=config, storage=LiteStorage(config)
        )

    def test_cancel_reaches_the_benchmark_worker(self, tab: Any) -> None:
        """It reached only the search, re-classification and re-scoring."""
        worker = MagicMock()
        tab._benchmark_worker = worker
        tab.cancel_btn.setEnabled(True)

        tab._on_cancel_clicked()

        assert worker.cancel.called
        assert not tab.cancel_btn.isEnabled()
        assert tab.progress_label.text() == "Cancelling..."

    def test_a_cancelled_benchmark_returns_the_tab_to_ready(self, tab: Any) -> None:
        """A run that emitted nothing left the tab stuck on "Cancelling..."."""
        result = partial(BenchmarkCancellation(2, 6))
        shown: list[Any] = []
        tab.benchmark_completed.connect(shown.append)

        tab._on_benchmark_cancelled(result, "")

        assert shown == [result]
        assert "2 of 6 evaluations" in tab.progress_label.text()
        assert not tab.cancel_btn.isEnabled()

    def test_a_cancel_with_no_result_says_so(self, tab: Any) -> None:
        """Nothing was computed, so nothing is claimed to have been."""
        tab._on_benchmark_cancelled(None, "Provider down")

        assert "Benchmark cancelled." in tab.progress_label.text()
        assert "Provider down" in tab.progress_label.text()


def quality_result(cancellation: BenchmarkCancellation | None) -> QualityBenchmarkResult:
    """A quality result the runner would return, cancelled or not.

    Args:
        cancellation: What the run had evaluated, or None.

    Returns:
        A ``QualityBenchmarkResult`` carrying it.
    """
    return QualityBenchmarkResult(
        run_id="run",
        question=QUESTION,
        task_type="study_classification",
        evaluator_stats=[],
        document_comparisons=[],
        design_agreement_matrix={},
        tier_agreement_matrix={},
        cancellation=cancellation,
    )


class TestTheResultsTabSaysAResultIsPartial:
    """Shown without a note, a cancelled comparison reads as a whole one."""

    def label_texts(self, widget: Any) -> list[str]:
        """Every label the widget holds.

        Args:
            widget: The results tab.

        Returns:
            Their texts.
        """
        from PySide6.QtWidgets import QLabel

        return [label.text() for label in widget.findChildren(QLabel)]

    def test_a_cancelled_relevance_result_is_marked_partial(self, qapp: Any) -> None:
        """Its figures are over the part of the run that happened."""
        tab = BenchmarkResultsTab(result=partial(BenchmarkCancellation(2, 6)))

        assert any(
            "2 of 6 evaluations" in text for text in self.label_texts(tab)
        )

    def test_a_complete_relevance_result_is_not(self, qapp: Any) -> None:
        """The control: an ordinary run is not qualified."""
        tab = BenchmarkResultsTab(result=partial(None))

        assert not any("cancelled" in text for text in self.label_texts(tab))

    def test_a_cancelled_quality_result_is_marked_partial(self, qapp: Any) -> None:
        """The same for the quality benchmark."""
        tab = QualityBenchmarkResultsTab(
            result=quality_result(BenchmarkCancellation(2, 6))
        )

        assert any(
            "2 of 6 evaluations" in text for text in self.label_texts(tab)
        )

    def test_a_complete_quality_result_is_not(self, qapp: Any) -> None:
        """The control."""
        tab = QualityBenchmarkResultsTab(result=quality_result(None))

        assert not any("cancelled" in text for text in self.label_texts(tab))
