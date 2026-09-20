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
    benchmark_status_text,
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
        assert "The other 28 were not started: no model was called for them." in text
        assert "What was evaluated is kept." in text

    def test_one_evaluation_left_is_said_in_the_singular(self) -> None:
        """A count and its words agree."""
        assert "The other one was not started" in benchmark_cancelled_text(
            BenchmarkCancellation(3, 4)
        )

    def test_it_never_claims_the_evaluations_made_were_paid_for(self) -> None:
        """evaluations_made counts reuses, which cost nothing (#329 review).

        "The other 28 were not made, and were not paid for" told the reader
        by implication that the 12 were -- and after a re-benchmark most of
        them are replays of scores already bought.
        """
        text = benchmark_cancelled_text(BenchmarkCancellation(12, 40))

        assert "paid" not in text

    def test_it_can_name_the_run_it_is_about(self) -> None:
        """Both runs write into one label: "Benchmark" named the other one."""
        text = benchmark_cancelled_text(
            BenchmarkCancellation(5, 20), subject="Quality benchmark"
        )

        assert text.startswith("Quality benchmark cancelled after 5 of 20")

    def test_it_is_a_benchmark_unless_told_otherwise(self) -> None:
        """The relevance benchmark keeps the wording it had."""
        assert benchmark_cancelled_text(BenchmarkCancellation(5, 20)).startswith(
            "Benchmark cancelled after 5 of 20"
        )

    def test_a_run_that_evaluated_nothing_claims_to_keep_nothing(self) -> None:
        """"What was evaluated is kept" over nothing is an empty promise."""
        text = benchmark_cancelled_text(BenchmarkCancellation(0, 9))

        assert "0 of 9 evaluations" in text
        assert "What was evaluated is kept." not in text

    def test_a_run_a_cancel_could_not_shorten_says_nothing_was_skipped(self) -> None:
        """Nothing was left out, so nothing is claimed to have been."""
        assert "The other" not in benchmark_cancelled_text(
            BenchmarkCancellation(9, 9)
        )

    def test_an_error_that_also_ended_the_run_is_named(self) -> None:
        """A crash mid-cancel read as an orderly stop (golden rule 8)."""
        text = benchmark_cancelled_text(BenchmarkCancellation(3, 9), "Provider down")

        assert "It also stopped on an error: Provider down" in text

    def test_no_error_adds_no_clause(self) -> None:
        """An orderly cancel is not dressed up as a failure."""
        assert "It also stopped on an error" not in benchmark_cancelled_text(
            BenchmarkCancellation(3, 9)
        )

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

    def test_a_cancelled_run_does_not_displace_the_completed_one(
        self, storage: LiteStorage
    ) -> None:
        """The cancelled run is skipped, not merely the only one missing.

        Asserted over a single cancelled run, "there is no latest benchmark"
        also passes for a lookup that finds nothing at all (#329 review).
        """
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        documents = [make_document(str(n)) for n in range(3)]
        whole = runner.run_quick_benchmark(
            question=QUESTION, documents=documents, models=[MODEL]
        )
        runner.run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL],
            should_cancel=CancelAfter(1),
        )

        latest = runner.get_latest_benchmark_result_for_question(QUESTION)

        assert latest is not None
        assert latest.run_id == whole.run_id
        assert latest.cancellation is None

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
                # The real runner reports the evaluation it was already
                # making, which is what the worker has to mute once cancelled
                progress = kwargs.get("progress_callback")
                if progress is not None:
                    progress(1, 6, "Evaluating doc-1")
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

    def test_progress_is_muted_once_the_cancel_is_in(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """"Cancelling..." was overwritten by the evaluation already running.

        The user then had no sign the cancel had been heard, and clicked
        again.
        """
        result = partial(BenchmarkCancellation(1, 6))
        recorder, worker = self.worker_running(kind, monkeypatch, result)
        ticks: list[Any] = []
        worker.progress.connect(lambda *a: ticks.append(a))
        worker.cancel()

        worker.run()

        assert ticks == []

    def test_progress_is_reported_while_the_run_is_going(
        self, kind: type, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control: muting is the cancel's doing, not the harness's."""
        recorder, worker = self.worker_running(kind, monkeypatch, partial(None))
        ticks: list[Any] = []
        worker.progress.connect(lambda *a: ticks.append(a))

        worker.run()

        assert ticks == [(1, 6, "Evaluating doc-1")]

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


class TestACrashMidCancelKeepsWhatWasBought:
    """Stored FAILED, a cancelled run's purchases were bought twice."""

    def test_a_run_cancelled_then_crashing_is_stored_cancelled(
        self, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """FAILED put its evaluations outside get_all_scores_for_question.

        The reuse lookup admits COMPLETED and CANCELLED runs only, so a run
        stored FAILED lost the paid-for scores the cancel had already bought
        -- the very harm #324 exists to prevent (#329 review).
        """
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        real_update = storage.update_benchmark_run
        calls: list[Any] = []

        def update(run_id: str, **kwargs: Any) -> Any:
            # Fail the write that stores the cancelled run, the way a locked
            # database or a full disk would
            if kwargs.get("status") is BenchmarkStatus.CANCELLED and not calls:
                calls.append(kwargs)
                raise RuntimeError("database is locked")
            return real_update(run_id, **kwargs)

        monkeypatch.setattr(storage, "update_benchmark_run", update)

        with pytest.raises(RuntimeError):
            runner.run_quick_benchmark(
                question=QUESTION,
                documents=[make_document(str(n)) for n in range(3)],
                models=[MODEL],
                should_cancel=CancelAfter(2),
            )

        runs = storage.get_benchmark_runs_by_question(
            QUESTION, status=BenchmarkStatus.CANCELLED
        )
        assert len(runs) == 1
        assert "database is locked" in (runs[0].error_message or "")

    def test_the_scores_it_bought_stay_reusable(
        self, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """What the user already paid for is not bought again."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        real_update = storage.update_benchmark_run
        failed: list[bool] = []

        def update(run_id: str, **kwargs: Any) -> Any:
            if kwargs.get("status") is BenchmarkStatus.CANCELLED and not failed:
                failed.append(True)
                raise RuntimeError("database is locked")
            return real_update(run_id, **kwargs)

        monkeypatch.setattr(storage, "update_benchmark_run", update)

        with pytest.raises(RuntimeError):
            runner.run_quick_benchmark(
                question=QUESTION,
                documents=[make_document(str(n)) for n in range(3)],
                models=[MODEL],
                should_cancel=CancelAfter(2),
            )

        reusable = storage.get_all_scores_for_question(QUESTION)
        assert sum(len(d) for d in reusable.values()) == 2

    def test_a_crash_with_no_cancel_is_still_a_failure(
        self, storage: LiteStorage, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A cancel is not invented for a run nobody stopped."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))

        def update(run_id: str, **kwargs: Any) -> Any:
            if kwargs.get("status") is BenchmarkStatus.COMPLETED:
                raise RuntimeError("database is locked")
            return None

        monkeypatch.setattr(storage, "update_benchmark_run", update)

        with pytest.raises(RuntimeError):
            runner.run_quick_benchmark(
                question=QUESTION,
                documents=[make_document("1")],
                models=[MODEL],
            )

        assert not storage.get_benchmark_runs_by_question(
            QUESTION, status=BenchmarkStatus.CANCELLED
        )


class TestAModelTheCancelNeverReached:
    """Every planned model keeps a row, and the note says why one is empty."""

    def test_it_keeps_its_row_with_nothing_in_it(self, storage: LiteStorage) -> None:
        """Dropped, the reader could not see the model had been planned.

        Kept, the empty row needs explaining -- otherwise it reads as a model
        that failed rather than one that never ran (#329 review).
        """
        result = relevance_runner(
            storage, CountingClient(ON_TOPIC)
        ).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(2)],
            models=[MODEL, OTHER_MODEL, "ollama:third-judge"],
            should_cancel=CancelAfter(3),
        )

        assert result.cancellation == BenchmarkCancellation(3, 6)
        assert len(result.evaluator_stats) == 3
        never_reached = [s for s in result.evaluator_stats if s.total_evaluations == 0]
        assert len(never_reached) == 1
        assert never_reached[0].mean_score is None

    def test_the_note_says_an_empty_row_did_not_fail(self) -> None:
        """The reader is told what the empty row means."""
        note = partial_result_note(BenchmarkCancellation(3, 6))

        assert note is not None
        assert "never reached was asked about none at all" in note
        assert "not because it failed" in note

    def test_the_run_stops_asking_once_it_has_been_told_to_stop(
        self, storage: LiteStorage
    ) -> None:
        """It breaks out of the models too, not just the documents.

        Left looping over the remaining models, the run kept asking after it
        had its answer -- work the user had already said to stop.
        """
        cancel = CancelAfter(3)
        relevance_runner(storage, CountingClient(ON_TOPIC)).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(2)],
            models=[MODEL, OTHER_MODEL, "ollama:third-judge"],
            should_cancel=cancel,
        )

        # Three Falses, then the one True that stopped it -- and no more
        assert cancel.asked == 4


class TestACancelCountsWhatItReplayed:
    """evaluations_made counts reuses, so the message must not claim spend."""

    def test_a_reused_evaluation_counts_but_costs_nothing(
        self, storage: LiteStorage
    ) -> None:
        """A re-benchmark replays scores the user already bought."""
        documents = [make_document(str(n)) for n in range(3)]
        first = CountingClient(ON_TOPIC)
        relevance_runner(storage, first).run_quick_benchmark(
            question=QUESTION, documents=documents, models=[MODEL]
        )
        assert first.calls == 3

        second = CountingClient(ON_TOPIC)
        result = relevance_runner(storage, second).run_quick_benchmark(
            question=QUESTION,
            documents=documents,
            models=[MODEL],
            should_cancel=CancelAfter(2),
        )

        # Two evaluations were "made", and neither was paid for
        assert result.cancellation == BenchmarkCancellation(2, 3)
        assert second.calls == 0
        assert "paid" not in benchmark_cancelled_text(result.cancellation)


class TestADamagedCancellationIsNotSilence:
    """Unreadable is not absent -- how every other stored field is read."""

    def test_a_cancelled_run_whose_counts_are_damaged_refuses_to_read(
        self, storage: LiteStorage
    ) -> None:
        """Answered as "not cancelled", it rendered with no partial note."""
        from bmlibrarian_lite.exceptions import StoredResultUnreadableError

        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        result = runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(1),
        )
        run = storage.get_benchmark_run(result.run_id)
        assert run is not None
        summary = json.loads(run.results_summary or "{}")
        summary["cancellation"] = {"evaluations_made": "many"}
        storage.update_benchmark_run(
            result.run_id, results_summary=json.dumps(summary)
        )

        with pytest.raises(StoredResultUnreadableError):
            runner.get_benchmark_result(result.run_id)

    def test_a_completed_run_without_one_reads_back_whole(
        self, storage: LiteStorage
    ) -> None:
        """The control: damage must not make a whole result look partial."""
        runner = relevance_runner(storage, CountingClient(ON_TOPIC))
        result = runner.run_quick_benchmark(
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )

        read_back = runner.get_benchmark_result(result.run_id)

        assert read_back is not None
        assert read_back.cancellation is None

    def test_a_planned_count_of_true_is_not_a_count(self) -> None:
        """``True`` is an ``int``: 0 of True would read as a finished run."""
        assert (
            BenchmarkCancellation.from_stored(
                {"evaluations_made": 0, "evaluations_planned": True}
            )
            is None
        )


class TestACancelledQualityRunRecordsItself:
    """Written and never read, the field's guarantee holds by luck."""

    def test_the_stored_summary_carries_the_counts(
        self, storage: LiteStorage
    ) -> None:
        """A later reader needs them to know the run was partial."""
        result = quality_runner(
            storage, CountingClient(RCT_ANSWER)
        ).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document(str(n)) for n in range(3)],
            models=[MODEL],
            should_cancel=CancelAfter(2),
        )

        stored = json.loads(result.to_json())

        assert stored["cancellation"] == {
            "evaluations_made": 2,
            "evaluations_planned": 3,
        }

    def test_a_complete_quality_run_stores_none(self, storage: LiteStorage) -> None:
        """The control."""
        result = quality_runner(
            storage, CountingClient(RCT_ANSWER)
        ).run_quick_benchmark(
            question=QUESTION,
            documents=[make_document("1")],
            models=[MODEL],
        )

        assert json.loads(result.to_json())["cancellation"] is None


class Recording:
    """Stands in for a worker or dialog: every attribute is one mock."""

    def __init__(self, **kwargs: Any) -> None:
        """Hold a mock per attribute.

        Args:
            kwargs: Whatever the tab passes; ignored.
        """
        self._mocks: dict[str, MagicMock] = {}

    def __getattr__(self, name: str) -> MagicMock:
        """The same mock for a name every time.

        Args:
            name: The attribute.

        Returns:
            Its mock.
        """
        return self.__dict__["_mocks"].setdefault(name, MagicMock())


class TestTheCancelledSignalIsActuallyWiredUp:
    """Every tab test calls the handler directly, so the connect was unpinned.

    Deleted, the runner still stopped and the worker still emitted -- and
    nothing listened: the modal dialog stayed open, the button stayed dead
    and the partial result was dropped (#329 review).
    """

    @pytest.fixture
    def review_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """A Systematic Review tab that will start a stubbed worker."""
        monkeypatch.setattr(review_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(review_module, "QMessageBox", MagicMock())
        for name in (
            "BenchmarkConfirmDialog",
            "QualityBenchmarkConfirmDialog",
            "BenchmarkProgressDialog",
            "QualityBenchmarkProgressDialog",
            "BenchmarkWorker",
            "QualityBenchmarkWorker",
        ):
            monkeypatch.setattr(review_module, name, Recording)

        document = make_document("1")
        storage = MagicMock()
        storage.get_scored_document_ids_for_question.return_value = [document.id]
        storage.get_documents.return_value = [document]

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = review_module.SystematicReviewTab(config=config, storage=storage)
        tab._current_question = QUESTION
        return tab

    def _accept(self, monkeypatch: pytest.MonkeyPatch, document: Any) -> None:
        """Make every confirm dialog answer Accepted with one model."""
        accepted = review_module.QDialog.Accepted

        class Confirm(Recording):
            """A confirm dialog the user accepted."""

            def exec(self) -> Any:
                """Accept."""
                return accepted

            def get_selected_models(self) -> list[str]:
                """One model."""
                return [MODEL]

            def get_documents_to_benchmark(self) -> list[Any]:
                """One document."""
                return [document]

            def get_task_type(self) -> str:
                """The quality task."""
                return "study_classification"

            def get_reuse_cross_run(self) -> bool:
                """Reuse, as the dialog defaults to."""
                return True

        monkeypatch.setattr(review_module, "BenchmarkConfirmDialog", Confirm)
        monkeypatch.setattr(review_module, "QualityBenchmarkConfirmDialog", Confirm)

    def test_the_review_tabs_benchmark_listens_for_cancelled(
        self, review_tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The Systematic Review tab's relevance benchmark."""
        self._accept(monkeypatch, make_document("1"))

        review_tab._run_benchmark()

        worker = review_tab._benchmark_worker
        assert worker is not None
        worker.cancelled.connect.assert_called_once_with(
            review_tab._on_benchmark_cancelled
        )

    def test_the_review_tabs_quality_benchmark_listens_for_cancelled(
        self, review_tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The Systematic Review tab's quality benchmark."""
        self._accept(monkeypatch, make_document("1"))

        review_tab._run_quality_benchmark()

        worker = review_tab._quality_benchmark_worker
        assert worker is not None
        worker.cancelled.connect.assert_called_once_with(
            review_tab._on_quality_benchmark_cancelled
        )

    def test_the_progress_dialogs_cancel_reaches_the_tab(
        self, review_tab: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The modal dialog's Cancel button is the only way to stop it."""
        self._accept(monkeypatch, make_document("1"))

        review_tab._run_benchmark()

        dialog = review_tab._benchmark_progress_dialog
        assert dialog is not None
        dialog.cancelled.connect.assert_called_once_with(
            review_tab._cancel_benchmark
        )


class TestACancelThatEvaluatedNothingPublishesNothing:
    """An empty comparison must not replace a whole one on screen."""

    @pytest.fixture
    def review_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """The Systematic Review tab, with its timer and dialogs stubbed."""
        monkeypatch.setattr(review_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(review_module, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = review_module.SystematicReviewTab(config=config, storage=MagicMock())
        tab._benchmark_progress_dialog = MagicMock()
        tab._quality_benchmark_progress_dialog = MagicMock()
        return tab

    @pytest.fixture
    def questions_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """The Research Questions tab, with its timer stubbed."""
        monkeypatch.setattr(questions_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(questions_module, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return questions_module.ResearchQuestionsTab(
            config=config, storage=LiteStorage(config)
        )

    def test_the_review_tab_publishes_no_empty_comparison(
        self, review_tab: Any
    ) -> None:
        """The reader would be switched to it, losing the one on screen."""
        shown: list[Any] = []
        review_tab.benchmark_completed.connect(shown.append)

        review_tab._on_benchmark_cancelled(partial(BenchmarkCancellation(0, 6)), "")

        assert shown == []
        assert "0 of 6 evaluations" in review_tab.progress_label.text()
        assert review_tab.benchmark_btn.isEnabled()

    def test_the_questions_tab_publishes_no_empty_comparison(
        self, questions_tab: Any
    ) -> None:
        """The same on the other tab."""
        shown: list[Any] = []
        questions_tab.benchmark_completed.connect(shown.append)

        questions_tab._on_benchmark_cancelled(
            partial(BenchmarkCancellation(0, 6)), ""
        )

        assert shown == []
        assert "0 of 6 evaluations" in questions_tab.progress_label.text()

    def test_one_evaluation_is_still_worth_publishing(
        self, review_tab: Any
    ) -> None:
        """The control: what ran is real and is shown."""
        result = partial(BenchmarkCancellation(1, 6))
        shown: list[Any] = []
        review_tab.benchmark_completed.connect(shown.append)

        review_tab._on_benchmark_cancelled(result, "")

        assert shown == [result]

    def test_the_quality_tab_publishes_no_empty_comparison(
        self, review_tab: Any
    ) -> None:
        """The same for the quality benchmark."""
        shown: list[Any] = []
        review_tab.quality_benchmark_completed.connect(shown.append)

        review_tab._on_quality_benchmark_cancelled(
            quality_result(BenchmarkCancellation(0, 6)), ""
        )

        assert shown == []


class TestACancelledQualityRunNamesItself:
    """Both runs write into one label, and "Benchmark" named the other."""

    @pytest.fixture
    def review_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """The Systematic Review tab."""
        monkeypatch.setattr(review_module.QTimer, "singleShot", MagicMock())
        monkeypatch.setattr(review_module, "QMessageBox", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = review_module.SystematicReviewTab(config=config, storage=MagicMock())
        tab._quality_benchmark_progress_dialog = MagicMock()
        tab._benchmark_progress_dialog = MagicMock()
        return tab

    def test_the_quality_cancel_says_quality_benchmark(
        self, review_tab: Any
    ) -> None:
        """It reported itself as the relevance run."""
        review_tab._on_quality_benchmark_cancelled(
            quality_result(BenchmarkCancellation(5, 20)), ""
        )

        assert review_tab.progress_label.text().startswith(
            "Quality benchmark cancelled after 5 of 20"
        )

    def test_the_relevance_cancel_still_says_benchmark(
        self, review_tab: Any
    ) -> None:
        """The control."""
        review_tab._on_benchmark_cancelled(partial(BenchmarkCancellation(5, 20)), "")

        assert review_tab.progress_label.text().startswith(
            "Benchmark cancelled after 5 of 20"
        )


class TestACrashMidCancelIsStillReportedAsOne:
    """Demoted to a label, a real failure lost the dialog it would have had."""

    @pytest.fixture
    def questions_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """The Research Questions tab, with its message box captured."""
        monkeypatch.setattr(questions_module.QTimer, "singleShot", MagicMock())
        box = MagicMock()
        monkeypatch.setattr(questions_module, "QMessageBox", box)
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = questions_module.ResearchQuestionsTab(
            config=config, storage=LiteStorage(config)
        )
        tab._message_box_for_test = box
        return tab

    def test_an_error_mid_cancel_is_shown_the_way_an_error_is(
        self, questions_tab: Any
    ) -> None:
        """_on_benchmark_error raises a modal for the same class of failure."""
        questions_tab._on_benchmark_cancelled(None, "Provider down")

        assert questions_tab._message_box_for_test.warning.called
        assert "Provider down" in str(
            questions_tab._message_box_for_test.warning.call_args
        )

    def test_an_orderly_cancel_raises_no_dialog(self, questions_tab: Any) -> None:
        """The control: cancelling is not failing."""
        questions_tab._on_benchmark_cancelled(partial(BenchmarkCancellation(2, 6)), "")

        assert not questions_tab._message_box_for_test.warning.called


class TestTheStatusBarDoesNotSayComplete:
    """"Benchmark complete" is the one message that flashes at the reader."""

    def test_a_cancelled_run_is_announced_as_cancelled(self) -> None:
        """It said the opposite of the truth (#329 review)."""
        text = benchmark_status_text(
            "Benchmark", BenchmarkCancellation(12, 40), 9, 0.0412
        )

        assert "complete" not in text
        assert "cancelled after 12 of 40 evaluations" in text
        assert "partial results shown" in text

    def test_a_whole_run_is_still_announced_as_complete(self) -> None:
        """The control."""
        assert benchmark_status_text("Benchmark", None, 9, 0.0412) == (
            "Benchmark complete: 9 documents, $0.0412"
        )

    def test_the_quality_run_keeps_its_own_name(self) -> None:
        """The quality benchmark names its task type."""
        text = benchmark_status_text(
            "Quality benchmark (study_classification)",
            BenchmarkCancellation(2, 6),
            3,
            0.01,
        )

        assert text.startswith("Quality benchmark (study_classification) cancelled")


class TestAnExportedPartialResultSaysItIsPartial:
    """The note lived in a Qt label; the file outlives the window.

    A reader who is mailed the export sees agreement matrices and per-model
    means over an arbitrary truncated subset, with nothing saying so (#329
    review).
    """

    @pytest.fixture
    def saving_to(
        self, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> Any:
        """Answer every save dialog with a path under tmp_path.

        Returns:
            A function taking the module and filename, returning the path.
        """
        from bmlibrarian_lite.gui import (
            benchmark_results_dialog as results_module,
        )
        from bmlibrarian_lite.gui import (
            quality_benchmark_results_dialog as quality_results_module,
        )

        def answer(name: str) -> Any:
            path = tmp_path / name
            for module in (results_module, quality_results_module):
                dialog = MagicMock()
                dialog.getSaveFileName.return_value = (str(path), "")
                monkeypatch.setattr(module, "QFileDialog", dialog)
            return path

        return answer

    def test_the_relevance_json_carries_the_counts(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """It hand-builds its dict and left the cancellation out."""
        path = saving_to("results.json")
        tab = BenchmarkResultsTab(result=partial(BenchmarkCancellation(12, 40)))

        tab._export_json()

        assert json.loads(path.read_text())["cancellation"] == {
            "evaluations_made": 12,
            "evaluations_planned": 40,
        }

    def test_a_whole_relevance_json_carries_none(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """The control."""
        path = saving_to("results.json")
        tab = BenchmarkResultsTab(result=partial(None))

        tab._export_json()

        assert json.loads(path.read_text())["cancellation"] is None

    def test_the_relevance_csv_leads_with_the_note(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """The CSV carried no header metadata at all."""
        path = saving_to("results.csv")
        tab = BenchmarkResultsTab(result=partial(BenchmarkCancellation(12, 40)))

        tab._export_csv()

        first_line = path.read_text().splitlines()[0]
        assert "cancelled after 12 of 40 evaluations" in first_line

    def test_a_whole_relevance_csv_leads_with_its_header(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """The control: an ordinary export is unchanged."""
        path = saving_to("results.csv")
        tab = BenchmarkResultsTab(result=partial(None))

        tab._export_csv()

        assert path.read_text().splitlines()[0].startswith("Document ID")

    def test_the_quality_csv_leads_with_the_note(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """The same for the quality benchmark."""
        path = saving_to("quality.csv")
        tab = QualityBenchmarkResultsTab(
            result=quality_result(BenchmarkCancellation(2, 6))
        )

        tab._export_csv()

        assert "cancelled after 2 of 6 evaluations" in path.read_text().splitlines()[0]

    def test_the_quality_json_already_carried_the_counts(
        self, qapp: Any, saving_to: Any
    ) -> None:
        """It serializes the whole result, so it did -- pinned so it stays."""
        path = saving_to("quality.json")
        tab = QualityBenchmarkResultsTab(
            result=quality_result(BenchmarkCancellation(2, 6))
        )

        tab._export_json()

        assert json.loads(path.read_text())["cancellation"] == {
            "evaluations_made": 2,
            "evaluations_planned": 6,
        }
