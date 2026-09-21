# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A cancelled worker ends, and a failed pass names its cause (#326, #327).

#320 put the Research Questions tab's three workers on the ``SingleOutcome``
contract: a run ends with exactly one terminal signal, whatever happens to
it. The rest of ``gui/workers.py`` was still written the old way -- a bare
``return`` on cancel, or ``if not self._cancelled: self.finished.emit(...)``
-- so a cancelled run emitted nothing and whatever waited on those signals
waited forever (#326).

The passes themselves reported a pair of counts. "17 documents failed
classification" is the same sentence for an unreachable provider, a refused
key and seventeen unprocessable abstracts: one is a one-line fix, another an
afternoon in the log, and the user could not tell which they had (#327). The
cause is now classified per document -- never the provider's own words, which
can carry a credential (#330).
"""

import inspect
from typing import Any
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from PySide6.QtCore import QThread  # noqa: E402

from bmlibrarian_lite.analysis_failures import (  # noqa: E402
    advice_for_causes,
    analysis_failure_advice,
    failure_cause_text,
    pass_failure_detail,
    unclassified_text,
)
from bmlibrarian_lite.audit_records import (  # noqa: E402
    LEGACY_FAILURE_EXPLANATION_PREFIX,
    scoring_failure_cause,
)
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.constants import SCORE_MIN  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    AnalysisShortfall,
    AnalysisStage,
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    PassFailure,
    PassOutcome,
    ScoredDocument,
)
from bmlibrarian_lite.exceptions import APIError, RetryExhaustedError  # noqa: E402
from bmlibrarian_lite.gui import workers as workers_module  # noqa: E402
from bmlibrarian_lite.gui.workers import (  # noqa: E402
    AnswerWorker,
    FulltextDiscoveryWorker,
    OpenAthensAuthWorker,
    PDFDiscoveryWorker,
    QualityFilterWorker,
    ReclassifyWorker,
    RescoreWorker,
    SingleOutcome,
)
from bmlibrarian_lite.quality.data_models import (  # noqa: E402
    QualityAssessment,
    QualityFilter,
    QualityTier,
    StudyClassification,
    StudyDesign,
)
from bmlibrarian_lite.quality.quality_manager import QualityManager  # noqa: E402
from bmlibrarian_lite.utils import classify_analysis_exception  # noqa: E402

#: What a provider's error text can carry: the request, and with it a key.
LEAKY_ERROR = "Connection refused: http://localhost:11434/api/chat?key=SECRET"

#: Every signal that can end a run, across the workers in the module.
TERMINAL_SIGNALS = ("finished", "error", "cancelled", "paywall_detected")


def make_document(pmid: str) -> LiteDocument:
    """A minimal document.

    Args:
        pmid: Its PubMed identifier.

    Returns:
        The document.
    """
    return LiteDocument(
        id=f"pmid-{pmid}",
        title=f"Aspirin trial {pmid}",
        abstract="Aspirin and stroke.",
        authors=["Smith J"],
        year=2024,
        pmid=pmid,
        source=DocumentSource.PUBMED,
    )


class Recorder:
    """Collects every emission of the terminal signals a worker has."""

    def __init__(self, worker: Any) -> None:
        """Connect to whichever terminal signals this worker declares.

        Args:
            worker: The worker to watch.
        """
        self.calls: dict[str, list[tuple[Any, ...]]] = {}
        for name in TERMINAL_SIGNALS:
            signal = getattr(worker, name, None)
            if signal is not None:
                signal.connect(self._slot(name))

    def _slot(self, name: str) -> Any:
        """Build the slot that records one signal.

        Args:
            name: The signal's name.

        Returns:
            The slot.
        """

        def record(*args: Any) -> None:
            self.calls.setdefault(name, []).append(args)

        return record

    def only(self) -> tuple[str, tuple[Any, ...]]:
        """The one terminal signal emitted, and its arguments.

        Returns:
            The signal's name and arguments.

        Raises:
            ValueError: If none or more than one was emitted -- which is the
                defect both #320 and #326 are about.
        """
        [(name, calls)] = self.calls.items()
        [args] = calls
        return name, args


# ---------------------------------------------------------------------------
# #326: the contract, and that it is not merely documented
# ---------------------------------------------------------------------------


def worker_classes() -> list[type]:
    """Every worker thread this module defines.

    Returns:
        The ``QThread`` subclasses, so a worker added later is covered
        without anyone remembering to list it here.
    """
    return [
        value
        for value in vars(workers_module).values()
        if inspect.isclass(value)
        and issubclass(value, QThread)
        and value is not QThread
    ]


class TestEveryWorkerEndsItsRun:
    """The contract holds for the whole module, not just one tab's workers."""

    def test_the_module_defines_the_workers_this_suite_expects(self) -> None:
        """A guard on the sweep below: an empty sweep passes vacuously."""
        assert len(worker_classes()) == 8

    @pytest.mark.parametrize("worker", worker_classes(), ids=lambda c: c.__name__)
    def test_a_worker_ends_a_run_exactly_once(self, worker: type) -> None:
        """Enforced by ``SingleOutcome``, not by a docstring (#320, #326)."""
        assert issubclass(worker, SingleOutcome)

    @pytest.mark.parametrize("worker", worker_classes(), ids=lambda c: c.__name__)
    def test_a_worker_that_can_be_cancelled_says_when_it_was(
        self, worker: type
    ) -> None:
        """A cancel that emits nothing leaves its caller waiting forever.

        Both ways round: a ``cancelled`` signal no ``cancel`` can raise is a
        signal no caller will ever hear, which is the same silence.
        """
        assert hasattr(worker, "cancelled") == hasattr(worker, "cancel")


class TestAWorkerThatCannotBeCancelled:
    """``AnswerWorker`` and ``OpenAthensAuthWorker`` end a run too.

    Neither can be cancelled, and both already report what they anticipate.
    What the contract adds is the arm their bodies do not have: ``except
    Exception`` does not catch a ``BaseException``, which used to leave the
    thread with nothing emitted and the chat waiting for an answer.
    """

    def test_a_failure_no_except_exception_catches_still_ends_the_run(
        self,
    ) -> None:
        """It walked out of the thread in silence."""
        agent = MagicMock()
        agent.ask.side_effect = KeyboardInterrupt()
        worker = AnswerWorker(agent=agent, question="Does aspirin help?")
        recorder = Recorder(worker)

        with pytest.raises(KeyboardInterrupt):
            worker.run()

        assert recorder.only()[0] == "error"

    def test_the_agent_failing_is_still_an_error(self) -> None:
        """The control: an ordinary failure is still reported as one."""
        agent = MagicMock()
        agent.ask.side_effect = RuntimeError("no model configured")
        worker = AnswerWorker(agent=agent, question="Does aspirin help?")
        recorder = Recorder(worker)

        worker.run()

        assert recorder.only() == ("error", ("no model configured",))

    def test_an_answer_is_still_an_answer(self) -> None:
        """The control on the ordinary path."""
        agent = MagicMock()
        agent.ask.return_value = ("An answer.", [])
        worker = AnswerWorker(agent=agent, question="Does aspirin help?")
        recorder = Recorder(worker)

        worker.run()

        assert recorder.only() == ("finished", ("An answer.", []))

    def test_an_authentication_failure_no_except_catches_ends_the_run(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The same arm, on the other worker that cannot be cancelled."""

        def interrupt(_url: str) -> bool:
            raise KeyboardInterrupt()

        monkeypatch.setattr(workers_module.webbrowser, "open", interrupt)
        worker = OpenAthensAuthWorker(institution_url="https://example.edu")
        recorder = Recorder(worker)

        with pytest.raises(KeyboardInterrupt):
            worker.run()

        assert recorder.only()[0] == "error"


# ---------------------------------------------------------------------------
# #326: the discovery workers
# ---------------------------------------------------------------------------


class FakeDiscoveryResult:
    """What a discoverer comes back with."""

    def __init__(
        self,
        success: bool = False,
        is_paywall: bool = False,
        error: str | None = None,
    ) -> None:
        """Record the outcome.

        Args:
            success: Whether it found the article.
            is_paywall: Whether a paywall stopped it.
            error: What went wrong, if anything.
        """
        self.success = success
        self.is_paywall = is_paywall
        self.error = error
        self.file_path = "/tmp/article.pdf"
        self.verification_warning = None
        self.paywall_url = "https://example.org/article"
        self.markdown_content = "# Aspirin trial"
        self.source_type = MagicMock(value="europepmc_xml")


def make_discovery_worker(kind: type, doc_dict: dict[str, Any], tmp_path: Any) -> Any:
    """One of the two discovery workers, given what its constructor wants.

    Args:
        kind: The worker class.
        doc_dict: The document's identifiers.
        tmp_path: Where the PDF worker would write.

    Returns:
        The worker.
    """
    if kind is PDFDiscoveryWorker:
        return kind(doc_dict, tmp_path)
    return kind(doc_dict)


def discovery_worker(
    monkeypatch: pytest.MonkeyPatch,
    tmp_path: Any,
    kind: type,
    discoverer_name: str,
    method: str,
    result: Any = None,
    raises: Exception | None = None,
    cancel_during: bool = False,
) -> tuple[Any, Recorder]:
    """A discovery worker whose discoverer answers as the test asks.

    Args:
        monkeypatch: To stand the discoverer down.
        tmp_path: Where the PDF worker would write.
        kind: The worker class.
        discoverer_name: The discoverer attribute on the workers module.
        method: The discoverer method the worker calls.
        result: What that method returns.
        raises: What it raises instead.
        cancel_during: Whether the worker is cancelled while it runs, as the
            user clicking Cancel does.

    Returns:
        The worker and a recorder of its terminal signals.
    """
    worker = make_discovery_worker(
        kind, {"doi": "10.1000/x", "title": "Aspirin trial", "year": 2024}, tmp_path
    )

    def answer(*_args: Any, **_kwargs: Any) -> Any:
        if cancel_during:
            worker.cancel()
        if raises is not None:
            raise raises
        return result

    discoverer = MagicMock()
    setattr(discoverer, method, answer)
    monkeypatch.setattr(
        workers_module, discoverer_name, lambda **_kwargs: discoverer
    )
    return worker, Recorder(worker)


DISCOVERY_WORKERS = [
    pytest.param(
        PDFDiscoveryWorker,
        "PDFDiscoverer",
        "discover_and_download",
        id="pdf",
    ),
    pytest.param(
        FulltextDiscoveryWorker,
        "FulltextDiscoverer",
        "discover_fulltext",
        id="fulltext",
    ),
]


class TestADiscoveryWorkerThatIsCancelled:
    """A bare ``return`` on cancel is a run nobody is ever told ended."""

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_a_cancel_ends_the_run(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """Before #326 this emitted nothing at all."""
        worker, recorder = discovery_worker(
            monkeypatch,
            tmp_path,
            kind,
            discoverer,
            method,
            result=FakeDiscoveryResult(error="stopped"),
            cancel_during=True,
        )

        worker.run()

        assert recorder.only() == ("cancelled", ("",))

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_an_error_while_cancelling_carries_the_error(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """Cancelling is not failing, but a failure is not hidden (rule 8)."""
        worker, recorder = discovery_worker(
            monkeypatch,
            tmp_path,
            kind,
            discoverer,
            method,
            raises=RuntimeError("disk is full"),
            cancel_during=True,
        )

        worker.run()

        name, (error,) = recorder.only()
        assert name == "cancelled"
        assert "disk is full" in error

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_the_same_failure_uncancelled_is_still_an_error(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """The control: nothing was cancelled, so it failed."""
        worker, recorder = discovery_worker(
            monkeypatch,
            tmp_path,
            kind,
            discoverer,
            method,
            raises=RuntimeError("disk is full"),
        )

        worker.run()

        assert recorder.only()[0] == "error"

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_an_article_that_arrives_still_finishes(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """The control on the whole class: the ordinary path is untouched."""
        worker, recorder = discovery_worker(
            monkeypatch,
            tmp_path,
            kind,
            discoverer,
            method,
            result=FakeDiscoveryResult(success=True),
        )

        worker.run()

        assert recorder.only()[0] == "finished"

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_a_paywall_is_still_a_paywall(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """A paywall ends the run too, and must not become an error."""
        worker, recorder = discovery_worker(
            monkeypatch,
            tmp_path,
            kind,
            discoverer,
            method,
            result=FakeDiscoveryResult(is_paywall=True, error="subscription"),
        )

        worker.run()

        assert recorder.only()[0] == "paywall_detected"

    @pytest.mark.parametrize("kind, discoverer, method", DISCOVERY_WORKERS)
    def test_a_document_with_no_identifier_never_starts(
        self,
        monkeypatch: pytest.MonkeyPatch,
        tmp_path: Any,
        kind: type,
        discoverer: str,
        method: str,
    ) -> None:
        """The early return has to end the run as well."""
        worker = make_discovery_worker(kind, {"title": "Aspirin trial"}, tmp_path)
        recorder = Recorder(worker)

        worker.run()

        assert recorder.only()[0] == "error"


# ---------------------------------------------------------------------------
# #326: the quality filter worker, whose cancel the manager could not see
# ---------------------------------------------------------------------------


def make_assessment() -> QualityAssessment:
    """An assessment that passes any filter.

    Returns:
        The assessment.
    """
    return QualityAssessment(
        assessment_tier=1,
        extraction_method="metadata",
        study_design=StudyDesign.RCT,
        quality_tier=QualityTier.TIER_4_EXPERIMENTAL,
        quality_score=8.0,
        confidence=0.9,
    )


def quality_worker(
    count: int, cancel_at: int | None = None, raises: Exception | None = None
) -> tuple[QualityFilterWorker, Recorder, list[str]]:
    """A quality filter over ``count`` documents, cancelled at one of them.

    Args:
        count: How many documents to filter.
        cancel_at: The document at which the user clicks Cancel, 1-based.
        raises: What assessing that document raises instead.

    Returns:
        The worker, a recorder of its terminal signals, and the ids of the
        documents the manager was actually asked to assess.
    """
    documents = [make_document(str(i)) for i in range(1, count + 1)]
    assessed: list[str] = []
    manager = QualityManager.__new__(QualityManager)
    worker = QualityFilterWorker(
        quality_manager=manager,
        documents=documents,
        filter_settings=QualityFilter(),
    )

    def assess_document(document: LiteDocument, _settings: Any) -> QualityAssessment:
        assessed.append(document.id)
        if len(assessed) == cancel_at:
            worker.cancel()
            if raises is not None:
                raise raises
        return make_assessment()

    manager.assess_document = assess_document  # type: ignore[method-assign]
    return worker, Recorder(worker), assessed


class TestTheQualityFilterWorker:
    """Both its arms fell silent once cancelled."""

    def test_a_cancel_part_way_ends_the_run_and_keeps_what_was_assessed(
        self,
    ) -> None:
        """What was assessed is real, and is kept (#324's rule, one along)."""
        worker, recorder, _assessed = quality_worker(count=5, cancel_at=2)

        worker.run()

        name, (filtered, assessments, total, error) = recorder.only()
        assert (name, total, error) == ("cancelled", 5, "")
        assert len(assessments) == 2
        assert len(filtered) == 2

    def test_a_cancel_stops_the_run_rather_than_muting_it(self) -> None:
        """It only set a flag the manager was never given (#324's mistake)."""
        worker, _recorder, assessed = quality_worker(count=5, cancel_at=2)

        worker.run()

        assert assessed == ["pmid-1", "pmid-2"]

    def test_without_a_cancel_every_document_is_assessed(self) -> None:
        """The control: the stop above is the cancel's doing, not the loop's."""
        worker, _recorder, assessed = quality_worker(count=5)

        worker.run()

        assert len(assessed) == 5

    def test_a_cancel_at_the_last_document_stopped_nothing(self) -> None:
        """Nothing was left undone, so the run finished (#320's rule)."""
        worker, recorder, _assessed = quality_worker(count=2, cancel_at=2)

        worker.run()

        assert recorder.only()[0] == "finished"

    def test_an_error_while_cancelling_carries_the_error(self) -> None:
        """A crash mid-cancel used to read as an orderly stop (rule 8)."""
        worker, recorder, _assessed = quality_worker(
            count=5, cancel_at=2, raises=RuntimeError("database is locked")
        )

        worker.run()

        name, (_filtered, _assessments, total, error) = recorder.only()
        assert (name, total, error) == ("cancelled", 5, "database is locked")

    def test_the_same_failure_uncancelled_is_still_an_error(self) -> None:
        """The control: nothing was cancelled, so it failed."""
        documents = [make_document("1")]
        manager = QualityManager.__new__(QualityManager)
        manager.assess_document = MagicMock(  # type: ignore[method-assign]
            side_effect=RuntimeError("database is locked")
        )
        worker = QualityFilterWorker(
            quality_manager=manager,
            documents=documents,
            filter_settings=QualityFilter(),
        )
        recorder = Recorder(worker)

        worker.run()

        assert recorder.only() == ("error", ("database is locked",))


class TestFilterDocumentsHonoursACancel:
    """The manager's own half of it, apart from any worker."""

    def test_it_is_asked_before_each_document_it_would_pay_for(self) -> None:
        """Asked after, the run pays for one more assessment than it stopped."""
        manager = QualityManager.__new__(QualityManager)
        assessed: list[str] = []

        def assess_document(document: LiteDocument, _settings: Any) -> Any:
            assessed.append(document.id)
            return make_assessment()

        manager.assess_document = assess_document  # type: ignore[method-assign]

        filtered, assessments = manager.filter_documents(
            [make_document(str(i)) for i in range(1, 4)],
            QualityFilter(),
            should_cancel=lambda: len(assessed) >= 1,
        )

        assert assessed == ["pmid-1"]
        assert len(assessments) == 1
        assert len(filtered) == 1


# ---------------------------------------------------------------------------
# #327: a failure names a document and a classified cause
# ---------------------------------------------------------------------------


class TestPassFailure:
    """A failure that names neither a document nor a cause is the old count."""

    def test_it_names_a_document_and_a_cause(self) -> None:
        """The ordinary case."""
        failure = PassFailure("pmid-1", EvaluationErrorCode.API_TIMEOUT)

        assert (failure.document_id, failure.cause.name) == ("pmid-1", "API_TIMEOUT")

    @pytest.mark.parametrize(
        "document_id, cause",
        [
            ("", EvaluationErrorCode.API_TIMEOUT),
            (None, EvaluationErrorCode.API_TIMEOUT),
            ("pmid-1", "API_TIMEOUT"),
            ("pmid-1", EvaluationErrorCode.SUCCESS),
        ],
    )
    def test_it_refuses_what_cannot_be_a_failure(
        self, document_id: Any, cause: Any
    ) -> None:
        """Success is not a failure, and neither is an unnamed document."""
        with pytest.raises(ValueError):
            PassFailure(document_id, cause)


class TestPassOutcome:
    """Impossible counts are refused, never repaired (#261's rule)."""

    def test_it_counts_what_the_pass_reached_and_what_it_did_not(self) -> None:
        """Successes, failures and unclassified are all documents reached."""
        outcome = PassOutcome(
            succeeded=3,
            failures=(PassFailure("pmid-1", EvaluationErrorCode.API_TIMEOUT),),
            total=10,
            unclassified=2,
        )

        assert (outcome.failed, outcome.attempted, outcome.not_attempted) == (1, 6, 4)

    def test_it_refuses_more_work_than_it_was_given(self) -> None:
        """A clamp would read as a fact about the run, and be invisible."""
        with pytest.raises(ValueError):
            PassOutcome(succeeded=5, total=2)

    @pytest.mark.parametrize("count", [-1, True, 1.5, "3"])
    def test_it_refuses_a_count_that_is_not_one(self, count: Any) -> None:
        """``True`` is not a count, and neither is "3"."""
        with pytest.raises(ValueError):
            PassOutcome(succeeded=count, total=10)

    def test_its_causes_name_each_one_once(self) -> None:
        """Twelve timeouts have one cause between them, not twelve."""
        outcome = PassOutcome(
            succeeded=0,
            failures=tuple(
                PassFailure(f"pmid-{i}", EvaluationErrorCode.API_TIMEOUT)
                for i in range(3)
            )
            + (PassFailure("pmid-9", EvaluationErrorCode.JSON_PARSE_ERROR),),
            total=4,
        )

        assert outcome.causes == (
            EvaluationErrorCode.API_TIMEOUT,
            EvaluationErrorCode.JSON_PARSE_ERROR,
        )


class TestPassFailureDetail:
    """What the user reads instead of a bare count."""

    def test_a_pass_with_no_failures_says_nothing(self) -> None:
        """A clean pass must never read as a qualified one."""
        assert pass_failure_detail(()) == ""

    def test_one_failure_names_its_document(self) -> None:
        """"First:" of one document reads as though there were more."""
        text = pass_failure_detail(
            (PassFailure("pmid-1", EvaluationErrorCode.API_CONNECTION_ERROR),)
        )

        assert text.startswith(
            "The failure was: Failed to connect to API (pmid-1)."
        )

    def test_failures_that_share_a_cause_say_so(self) -> None:
        """Three of three is not "most", which invites a hunt for the rest."""
        text = pass_failure_detail(
            tuple(
                PassFailure(f"pmid-{i}", EvaluationErrorCode.API_AUTH_ERROR)
                for i in range(1, 4)
            )
        )

        assert text.startswith(
            "All 3 failures were: API authentication failed (first: pmid-1)."
        )

    def test_mixed_failures_name_the_dominant_cause_and_its_share(self) -> None:
        """The share is what says whether one fix covers them."""
        failures = tuple(
            PassFailure(f"pmid-{i}", EvaluationErrorCode.API_CONNECTION_ERROR)
            for i in range(1, 13)
        ) + (PassFailure("pmid-99", EvaluationErrorCode.JSON_PARSE_ERROR),)

        text = pass_failure_detail(failures)

        assert text.startswith(
            "Most failures (12 of 13) were: Failed to connect to API "
            "(first: pmid-1)."
        )

    def test_the_example_is_a_document_the_named_cause_happened_to(self) -> None:
        """An example of a different cause sends the user to the wrong log."""
        failures = (
            PassFailure("pmid-parse", EvaluationErrorCode.JSON_PARSE_ERROR),
            PassFailure("pmid-down-1", EvaluationErrorCode.API_CONNECTION_ERROR),
            PassFailure("pmid-down-2", EvaluationErrorCode.API_CONNECTION_ERROR),
        )

        text = pass_failure_detail(failures)

        assert "first: pmid-down-1" in text
        assert "pmid-parse" not in text

    def test_it_says_what_to_do_about_every_cause_among_them(self) -> None:
        """The dominant cause is named, but the advice covers the others."""
        failures = (
            PassFailure("pmid-1", EvaluationErrorCode.API_CONNECTION_ERROR),
            PassFailure("pmid-2", EvaluationErrorCode.API_AUTH_ERROR),
        )

        text = pass_failure_detail(failures)

        assert "check the API key in Settings" in text
        assert "Ollama running" in text

    def test_the_same_failures_always_name_the_same_cause(self) -> None:
        """A tie decided by hash order would reword itself between runs."""
        failures = (
            PassFailure("pmid-1", EvaluationErrorCode.API_TIMEOUT),
            PassFailure("pmid-2", EvaluationErrorCode.JSON_PARSE_ERROR),
        )

        assert {pass_failure_detail(failures) for _ in range(20)} == {
            pass_failure_detail(failures)
        }
        assert "API request timed out" in pass_failure_detail(failures)


class TestUnclassifiedIsNotFailed:
    """A model that names no design has not failed: nothing broke."""

    def test_nothing_unclassified_says_nothing(self) -> None:
        """The control."""
        assert unclassified_text(0) == ""

    def test_one_document_reads_as_one(self) -> None:
        """Its stored design is unchanged, which is what the user needs."""
        assert unclassified_text(1) == (
            " The model named no study design for 1 document; "
            "its stored design is unchanged."
        )

    def test_several_documents_read_as_several(self) -> None:
        """The plural, and the thousands separator."""
        assert "1,200 documents" in unclassified_text(1200)


class TestAdviceComesFromTheCausesAlone:
    """One place decides what the user can do, whatever recorded the failure."""

    def test_a_shortfall_and_a_set_of_causes_advise_alike(self) -> None:
        """They drifted the moment there were two copies of the rules."""
        causes = (
            EvaluationErrorCode.API_AUTH_ERROR,
            EvaluationErrorCode.API_CONNECTION_ERROR,
        )
        shortfall = AnalysisShortfall(
            stage=AnalysisStage.SCORING,
            documents_failed=2,
            documents_attempted=2,
            causes=causes,
        )

        assert analysis_failure_advice([shortfall]) == advice_for_causes(causes)

    def test_a_cause_nothing_specific_is_known_about_still_advises(self) -> None:
        """"Try again later" is the floor, never an empty string."""
        assert advice_for_causes([EvaluationErrorCode.UNKNOWN_ERROR]) == (
            "Try again later."
        )


class TestClassifyingWhatAStageRaised:
    """The wrapper is not the cause, and only the cause is actionable."""

    def test_spent_retries_are_classified_by_what_they_were_spent_on(self) -> None:
        """Recorded as the wrapper, an outage advised "try again later"."""
        exhausted = RetryExhaustedError(
            "gave up", last_error=APIError("refused", status_code=401)
        )

        assert classify_analysis_exception(exhausted) == (
            EvaluationErrorCode.API_AUTH_ERROR
        )

    def test_anything_else_is_classified_as_itself(self) -> None:
        """The control: an unwrapped failure is unaffected."""
        assert classify_analysis_exception(TimeoutError("slow")) == (
            EvaluationErrorCode.API_TIMEOUT
        )


class TestTheCauseOfAStoredFailedScoring:
    """The scoring agent returns a failure; the cause is in the row."""

    def test_a_judgement_has_no_failure_cause(self) -> None:
        """The control: a 4 is a judgement, not a failure."""
        scored = ScoredDocument(make_document("1"), 4, "Relevant.")

        assert scoring_failure_cause(scored) is None

    def test_a_stored_code_is_the_cause(self) -> None:
        """Every build since #306 stores the negative code."""
        code = EvaluationErrorCode.API_RATE_LIMIT
        scored = ScoredDocument(make_document("1"), code.value, code.description)

        assert scoring_failure_cause(scored) is code

    def test_an_older_builds_failure_has_no_nameable_cause(self) -> None:
        """Its cause was provider text, which is not shown (#315)."""
        scored = ScoredDocument(
            make_document("1"),
            SCORE_MIN,
            LEGACY_FAILURE_EXPLANATION_PREFIX + LEAKY_ERROR,
        )

        assert scoring_failure_cause(scored) is EvaluationErrorCode.UNKNOWN_ERROR


# ---------------------------------------------------------------------------
# #327: the passes themselves
# ---------------------------------------------------------------------------


class RecordingClassifier:
    """Classifies as the test asks, and cancels nothing."""

    answer: Any = None

    def __init__(self, config: Any) -> None:
        """Take the worker's argument and ignore it.

        Args:
            config: What the worker passes the real classifier.
        """

    def classify(self, document: LiteDocument) -> StudyClassification:
        """The answer the test set, or the failure it set.

        Args:
            document: The document to classify.

        Returns:
            The classification.

        Raises:
            Exception: Whatever the test set as the answer.
        """
        answer = RecordingClassifier.answer
        if isinstance(answer, Exception):
            raise answer
        return answer


def reclassify(
    monkeypatch: pytest.MonkeyPatch, answer: Any, count: int = 1
) -> tuple[str, PassOutcome]:
    """Run a re-classification whose classifier always gives one answer.

    Args:
        monkeypatch: To stand the classifier down.
        answer: The classification, or the exception to raise.
        count: How many documents to classify.

    Returns:
        The terminal signal's name and the outcome it carried.
    """
    RecordingClassifier.answer = answer
    monkeypatch.setattr(
        "bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier",
        RecordingClassifier,
    )
    worker = ReclassifyWorker(
        config=LiteConfig(),
        storage=MagicMock(),
        documents=[make_document(str(i)) for i in range(1, count + 1)],
    )
    recorder = Recorder(worker)
    worker.run()
    name, args = recorder.only()
    return name, args[0]


class TestTheReclassifyWorkerTellsThemApart:
    """An honest UNKNOWN and a crashed classifier were the same number."""

    def test_an_unknown_design_is_counted_apart(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Nothing broke, so nothing is reported as broken."""
        _name, outcome = reclassify(
            monkeypatch,
            StudyClassification(study_design=StudyDesign.UNKNOWN, confidence=0.4),
            count=3,
        )

        assert (outcome.succeeded, outcome.failed, outcome.unclassified) == (0, 0, 3)

    def test_a_classified_design_still_succeeds(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control."""
        _name, outcome = reclassify(
            monkeypatch,
            StudyClassification(study_design=StudyDesign.RCT, confidence=0.9),
            count=2,
        )

        assert (outcome.succeeded, outcome.failed, outcome.unclassified) == (2, 0, 0)

    def test_a_failure_names_its_document_and_its_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The count alone lumped every kind of failure together."""
        _name, outcome = reclassify(
            monkeypatch, APIError("refused", status_code=401), count=2
        )

        assert outcome.failed == 2
        assert outcome.failures[0].document_id == "pmid-1"
        assert outcome.causes == (EvaluationErrorCode.API_AUTH_ERROR,)

    def test_spent_retries_are_classified_by_what_they_were_spent_on(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """``llm_retry`` wraps every provider failure; the wrapper is useless."""
        _name, outcome = reclassify(
            monkeypatch,
            RetryExhaustedError(
                "gave up", last_error=APIError("too many", status_code=429)
            ),
        )

        assert outcome.causes == (EvaluationErrorCode.API_RATE_LIMIT,)

    def test_the_provider_text_is_not_the_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """It can print the request, credentials and all (#330)."""
        _name, outcome = reclassify(monkeypatch, RuntimeError(LEAKY_ERROR), count=1)

        assert "SECRET" not in pass_failure_detail(outcome.failures)


class FailingScoringAgent:
    """Scores every document as the test asks."""

    answer: Any = None

    def __init__(self, config: Any) -> None:
        """Take the worker's argument and ignore it.

        Args:
            config: What the worker passes the real agent.
        """

    def score_document(self, question: str, document: LiteDocument) -> ScoredDocument:
        """The score the test set, or the failure it set.

        Args:
            question: The research question.
            document: The document to score.

        Returns:
            The score.

        Raises:
            Exception: Whatever the test set as the answer.
        """
        answer = FailingScoringAgent.answer
        if isinstance(answer, Exception):
            raise answer
        return ScoredDocument(document, answer[0], answer[1])


def rescore(
    monkeypatch: pytest.MonkeyPatch, answer: Any, count: int = 1
) -> tuple[str, PassOutcome]:
    """Run a re-scoring whose agent always gives one answer.

    Args:
        monkeypatch: To stand the agent down.
        answer: A (score, explanation) pair, or the exception to raise.
        count: How many documents to score.

    Returns:
        The terminal signal's name and the outcome it carried.
    """
    FailingScoringAgent.answer = answer
    monkeypatch.setattr(
        "bmlibrarian_lite.agents.scoring_agent.LiteScoringAgent", FailingScoringAgent
    )
    worker = RescoreWorker(
        config=LiteConfig(),
        storage=MagicMock(),
        question="Does aspirin prevent stroke?",
        documents=[make_document(str(i)) for i in range(1, count + 1)],
    )
    recorder = Recorder(worker)
    worker.run()
    name, args = recorder.only()
    return name, args[0]


class TestTheRescoreWorkerNamesItsCauses:
    """The agent returns a failure rather than raising one."""

    def test_a_returned_failure_carries_the_cause_it_stored(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The row it just wrote says why; the worker no longer guesses."""
        code = EvaluationErrorCode.API_RATE_LIMIT
        _name, outcome = rescore(monkeypatch, (code.value, code.description), count=2)

        assert outcome.failed == 2
        assert outcome.causes == (code,)

    def test_an_older_builds_failure_row_has_no_nameable_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Recognised as a failure (#315), with the cause its text is not."""
        _name, outcome = rescore(
            monkeypatch,
            (SCORE_MIN, LEGACY_FAILURE_EXPLANATION_PREFIX + LEAKY_ERROR),
        )

        assert outcome.causes == (EvaluationErrorCode.UNKNOWN_ERROR,)
        assert "SECRET" not in pass_failure_detail(outcome.failures)

    def test_a_raised_failure_is_classified_too(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Saving can fail as well as scoring."""
        _name, outcome = rescore(monkeypatch, TimeoutError("slow"), count=1)

        assert outcome.causes == (EvaluationErrorCode.API_TIMEOUT,)

    def test_a_judgement_is_still_a_success(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control."""
        _name, outcome = rescore(monkeypatch, (4, "Relevant."), count=3)

        assert (outcome.succeeded, outcome.failed) == (3, 0)


# ---------------------------------------------------------------------------
# The cause reaches the user, on both tabs
# ---------------------------------------------------------------------------


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the tab tests need.

    Returns:
        The application, made once for the module.
    """
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


@pytest.fixture
def questions_tab(
    qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
) -> Any:
    """A Research Questions tab over one stored question, selected.

    Args:
        qapp: The application.
        monkeypatch: To stand the dialogs and timers down.
        tmp_path: A data directory this test owns.

    Returns:
        The tab.
    """
    from bmlibrarian_lite.gui import research_questions_tab as questions_module
    from bmlibrarian_lite.storage import LiteStorage

    question = "Does aspirin prevent stroke?"
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    storage = LiteStorage(config)
    document = make_document("1")
    storage.upsert_document(document)
    checkpoint = storage.create_checkpoint(research_question=question)
    storage.save_scored_document(
        ScoredDocument(document, 4, "Relevant."), checkpoint.id
    )
    storage.create_search_session("aspirin AND stroke", question, document_count=1)
    monkeypatch.setattr(questions_module, "QMessageBox", MagicMock())
    monkeypatch.setattr(questions_module.QTimer, "singleShot", MagicMock())
    widget = questions_module.ResearchQuestionsTab(config=config, storage=storage)
    widget.questions_table.selectRow(0)
    widget._module = questions_module
    return widget


def failing_outcome(cause: EvaluationErrorCode) -> PassOutcome:
    """An outcome in which three of ten documents failed alike.

    Args:
        cause: What each failure was.

    Returns:
        The outcome.
    """
    return PassOutcome(
        succeeded=7,
        failures=tuple(
            PassFailure(f"pmid-{i}", cause) for i in range(1, 4)
        ),
        total=10,
    )


PASSES = [
    pytest.param("_rescore_worker", "_on_rescore_finished", id="rescore"),
    pytest.param("_reclassify_worker", "_on_reclassify_finished", id="reclassify"),
]


class TestAFailedPassTellsTheUserWhy:
    """A count alone was all the user ever got (#327)."""

    @pytest.mark.parametrize("slot, handler", PASSES)
    def test_the_dialog_names_the_cause_and_what_to_do(
        self, questions_tab: Any, slot: str, handler: str
    ) -> None:
        """"3 documents failed" fits an outage and a dead end alike."""
        setattr(questions_tab, slot, MagicMock())

        getattr(questions_tab, handler)(
            failing_outcome(EvaluationErrorCode.API_CONNECTION_ERROR)
        )

        _args, kwargs = questions_tab._module.QMessageBox.warning.call_args
        shown = " ".join(str(part) for part in _args)
        assert "Failed to connect to API" in shown
        assert "first: pmid-1" in shown
        assert "Ollama running" in shown

    @pytest.mark.parametrize("slot, handler", PASSES)
    def test_a_pass_with_nothing_wrong_does_not_warn(
        self, questions_tab: Any, slot: str, handler: str
    ) -> None:
        """The control: a clean pass must not read as a qualified one."""
        setattr(questions_tab, slot, MagicMock())

        getattr(questions_tab, handler)(PassOutcome(succeeded=10, total=10))

        questions_tab._module.QMessageBox.warning.assert_not_called()

    def test_an_unclassified_document_is_not_reported_as_a_failure(
        self, questions_tab: Any
    ) -> None:
        """Nothing broke, so no warning -- but the user is still told."""
        questions_tab._reclassify_worker = MagicMock()

        questions_tab._on_reclassify_finished(
            PassOutcome(succeeded=4, total=10, unclassified=6)
        )

        questions_tab._module.QMessageBox.warning.assert_not_called()
        _args, _kwargs = questions_tab._module.QMessageBox.information.call_args
        assert "named no study design for 6 documents" in " ".join(
            str(part) for part in _args
        )

    @pytest.mark.parametrize("slot, handler", PASSES)
    def test_the_provider_text_never_reaches_the_dialog(
        self, questions_tab: Any, slot: str, handler: str
    ) -> None:
        """It can print the request, credentials and all (#330)."""
        setattr(questions_tab, slot, MagicMock())

        getattr(questions_tab, handler)(
            failing_outcome(EvaluationErrorCode.UNKNOWN_ERROR)
        )

        _args, _kwargs = questions_tab._module.QMessageBox.warning.call_args
        assert "SECRET" not in " ".join(str(part) for part in _args)


class TestTheInterrogationTabHearsTheCancel:
    """The handler that returns the tab to ready has to be connected."""

    def test_a_cancelled_full_text_releases_the_worker(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Unconnected, the thread ended and nothing was ever told."""
        tab = interrogation_tab(monkeypatch, tmp_path)
        tab._start_fulltext_discovery(
            {"doi": "10.1000/x"}, "Aspirin trial", MagicMock()
        )
        worker = tab._fulltext_worker
        assert worker is not None

        worker.cancelled.emit("")

        assert tab._fulltext_worker is None
        assert tab._pdf_progress_dialog is None

    def test_a_cancelled_pdf_releases_the_worker(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The same for the PDF path."""
        tab = interrogation_tab(monkeypatch, tmp_path)
        tab._start_pdf_discovery({"doi": "10.1000/x"}, "Aspirin trial")
        worker = tab._pdf_worker
        assert worker is not None

        worker.cancelled.emit("")

        assert tab._pdf_worker is None
        assert tab._pdf_progress_dialog is None

    def test_cancelling_does_not_drop_the_worker_before_it_has_stopped(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Only the worker knows when it stopped, and it says so."""
        tab = interrogation_tab(monkeypatch, tmp_path)
        tab._start_pdf_discovery({"doi": "10.1000/x"}, "Aspirin trial")

        tab._cancel_pdf_discovery()

        assert tab._pdf_worker is not None
        assert tab._pdf_worker.stopped

    def test_a_superseded_run_does_not_clobber_the_one_that_replaced_it(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A cancelled download can take many seconds to notice.

        The reference is kept until the worker says it stopped (#326), so a
        second fetch started in that window is the current one. Acting on
        the stale run's ``cancelled`` closed the new run's dialog and
        dropped its worker, leaving it running and no longer cancellable.
        """
        tab = interrogation_tab(monkeypatch, tmp_path)
        tab._start_pdf_discovery({"doi": "10.1000/first"}, "First")
        stale = tab._pdf_worker
        tab._cancel_pdf_discovery()

        tab._start_pdf_discovery({"doi": "10.1000/second"}, "Second")
        current = tab._pdf_worker
        assert current is not stale

        stale.cancelled.emit("")

        assert tab._pdf_worker is current
        assert tab._pdf_progress_dialog is not None

    def test_a_superseded_full_text_run_leaves_the_current_dialog_alone(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Both paths share one progress dialog, so this cuts both ways."""
        tab = interrogation_tab(monkeypatch, tmp_path)
        tab._start_fulltext_discovery({"doi": "10.1000/first"}, "First", MagicMock())
        stale = tab._fulltext_worker
        tab._cancel_fulltext_discovery()

        tab._start_fulltext_discovery({"doi": "10.1000/second"}, "Second", MagicMock())
        current = tab._fulltext_worker

        stale.cancelled.emit("")

        assert tab._fulltext_worker is current
        assert tab._pdf_progress_dialog is not None


class StubWorker:
    """A worker that starts nothing and emits when the test says so."""

    def __init__(self, *_args: Any, **_kwargs: Any) -> None:
        """Take the real worker's arguments and ignore them.

        Args:
            *_args: What the tab passes the real worker.
            **_kwargs: Likewise.
        """
        from PySide6.QtCore import QObject, Signal

        class Emitter(QObject):
            """Carries the real worker's signals."""

            progress = Signal(str, str)
            finished = Signal(str, str, str)
            verification_warning = Signal(str, str)
            paywall_detected = Signal(str, str)
            error = Signal(str)
            cancelled = Signal(str)

        self._emitter = Emitter()
        self.stopped = False

    def __getattr__(self, name: str) -> Any:
        """Hand out the emitter's signals.

        Args:
            name: The signal's name.

        Returns:
            The signal.
        """
        return getattr(self.__dict__["_emitter"], name)

    def start(self) -> None:
        """Nothing runs until the test emits."""

    def cancel(self) -> None:
        """Record that the tab stopped discovery."""
        self.stopped = True


def interrogation_tab(monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
    """An interrogation tab whose workers are stood in for.

    Args:
        monkeypatch: To stand the agent and workers down.
        tmp_path: A data directory this test owns.

    Returns:
        The tab, wired as in production apart from the workers.
    """
    from bmlibrarian_lite.gui import document_interrogation_tab as tab_module

    monkeypatch.setattr(tab_module, "LiteInterrogationAgent", MagicMock())
    monkeypatch.setattr(tab_module, "QMessageBox", MagicMock())
    monkeypatch.setattr(tab_module, "find_existing_fulltext", lambda _m: None)
    monkeypatch.setattr(tab_module, "find_existing_pdf", lambda _m: None)
    monkeypatch.setattr(tab_module, "FulltextDiscoveryWorker", StubWorker)
    monkeypatch.setattr(tab_module, "PDFDiscoveryWorker", StubWorker)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    widget = tab_module.DocumentInterrogationTab(config=config, storage=MagicMock())
    widget.document_view = MagicMock()
    return widget


# ---------------------------------------------------------------------------
# #326: the cancel has to reach the filter the user can actually start
# ---------------------------------------------------------------------------


class TestTheReviewsQualityFilterHonoursACancel:
    """``QualityFilterWorker`` is never constructed (#332).

    The quality filtering a user can actually start runs inside the
    systematic review's own worker, and it was calling ``filter_documents``
    without ``should_cancel`` -- so a cancel muted the progress callback
    while every remaining document was still assessed and paid for. That is
    #324's mistake one worker along, which is what #326 set out to end.
    """

    def test_a_cancelled_review_stops_assessing_documents(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The run stops at the cancel, not at the end of the documents."""
        from bmlibrarian_lite.gui import systematic_review_tab

        documents = [make_document(str(i)) for i in range(1, 6)]
        assessed: list[str] = []
        manager = QualityManager.__new__(QualityManager)
        config = LiteConfig()
        monkeypatch.setattr(config.transparency, "enabled", False)
        worker = systematic_review_tab.WorkflowWorker(
            question="Does aspirin help?",
            config=config,
            storage=MagicMock(),
            quality_filter=QualityFilter(minimum_tier=QualityTier.TIER_1_ANECDOTAL),
            quality_manager=manager,
            preloaded_documents=documents,
        )

        def assess_document(document: LiteDocument, _settings: Any) -> QualityAssessment:
            assessed.append(document.id)
            if len(assessed) == 2:
                worker.cancel()
            return make_assessment()

        manager.assess_document = assess_document  # type: ignore[method-assign]

        worker.run()

        assert assessed == ["pmid-1", "pmid-2"], (
            "the cancel was seen only after every document had been paid for"
        )


# ---------------------------------------------------------------------------
# #330: the error that ends a whole pass is classified too
# ---------------------------------------------------------------------------


class TestAFailedPassDoesNotLeakTheProviderText:
    """``PassFailure`` kept the provider's words off the screen per document.

    The failure that ends the *whole* pass reached the screen by another
    door: the worker emitted ``str(e)`` and the dialog printed it, so an
    error that echoes the request put the API key in a box the user can
    screenshot (#330).
    """

    def test_a_pass_that_dies_at_the_start_reports_a_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The classifier could not even be built."""

        def explode(**_kwargs: Any) -> Any:
            raise APIError(LEAKY_ERROR, status_code=401)

        monkeypatch.setattr(
            "bmlibrarian_lite.quality.study_classifier.LiteStudyClassifier", explode
        )
        worker = ReclassifyWorker(
            config=LiteConfig(), storage=MagicMock(), documents=[make_document("1")]
        )
        recorder = Recorder(worker)

        worker.run()

        name, args = recorder.only()
        assert name == "error"
        assert "SECRET" not in args[0]
        assert EvaluationErrorCode.API_AUTH_ERROR.description in args[0]

    def test_a_rescore_that_dies_at_the_start_reports_a_cause(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The same door, on the other pass."""

        def explode(**_kwargs: Any) -> Any:
            raise APIError(LEAKY_ERROR, status_code=401)

        monkeypatch.setattr(
            "bmlibrarian_lite.agents.scoring_agent.LiteScoringAgent", explode
        )
        worker = RescoreWorker(
            config=LiteConfig(),
            storage=MagicMock(),
            documents=[make_document("1")],
            question="Does aspirin help?",
        )
        recorder = Recorder(worker)

        worker.run()

        name, args = recorder.only()
        assert name == "error"
        assert "SECRET" not in args[0]

    def test_the_cause_carries_the_advice_for_it(self) -> None:
        """A cause with nothing to do about it is still only half a sentence."""
        text = failure_cause_text(EvaluationErrorCode.API_AUTH_ERROR)

        assert EvaluationErrorCode.API_AUTH_ERROR.description in text
        assert advice_for_causes((EvaluationErrorCode.API_AUTH_ERROR,)) in text


# ---------------------------------------------------------------------------
# #327: a cancel must account for every document it reached
# ---------------------------------------------------------------------------


class TestACancelledPassAccountsForEveryDocument:
    """``attempted`` folds in the documents the model named no design for.

    The sentence broke down only the successes and the failures, so those
    documents vanished between "after 9" and "7 re-classified, other 11" --
    and the dialog that would have explained them was gated on something
    having *failed*. A pass in which nothing went wrong said nothing about
    six documents whose stored designs it had left unchanged (#327).
    """

    def test_the_numbers_add_up(self) -> None:
        """Every attempted document is in the breakdown."""
        outcome = PassOutcome(succeeded=7, total=20, unclassified=2)

        text = questions_module_text(outcome)

        assert "9 of 20 documents" in text
        assert "7 re-classified" in text
        assert "2 with no study design named" in text

    def test_a_clean_cancel_still_explains_the_unclassified(
        self, questions_tab: Any
    ) -> None:
        """Nothing failed, so nothing was said -- about six documents."""
        questions_tab._reclassify_worker = MagicMock()
        outcome = PassOutcome(succeeded=34, total=100, unclassified=6)

        questions_tab._on_reclassify_cancelled(outcome, "")

        shown = questions_tab._module.QMessageBox.warning.call_args
        assert shown is not None, "a cancel that left 6 documents said nothing"
        assert "no study design" in shown[0][2]

    def test_a_cancel_with_nothing_to_report_stays_quiet(
        self, questions_tab: Any
    ) -> None:
        """The control: a clean cancel does not invent a warning."""
        questions_tab._module.QMessageBox.reset_mock()
        questions_tab._reclassify_worker = MagicMock()

        questions_tab._on_reclassify_cancelled(
            PassOutcome(succeeded=4, total=10), ""
        )

        assert questions_tab._module.QMessageBox.warning.call_args is None

    def test_a_finished_pass_label_accounts_for_them_too(self) -> None:
        """The label is what the user is left looking at."""
        from bmlibrarian_lite.gui.research_questions_tab import pass_finished_text

        text = pass_finished_text(
            "Re-classification",
            "re-classified",
            PassOutcome(succeeded=4, total=10, unclassified=6),
        )

        assert "6 with no study design named" in text


def questions_module_text(outcome: PassOutcome) -> str:
    """The cancelled-pass sentence for an outcome.

    Args:
        outcome: What the pass did.

    Returns:
        The sentence.
    """
    from bmlibrarian_lite.gui.research_questions_tab import pass_cancelled_text

    return pass_cancelled_text("Re-classification", "re-classified", outcome, "")


class TestAPassThatErrorsSaysWhatBecameOfTheTable:
    """Both passes save each document as they go (#320).

    A run that aborted part way had already changed everything it reached,
    but the error handlers left the table showing the values from before --
    so it read as though nothing had happened, and the user re-ran it.
    """

    @pytest.mark.parametrize(
        "handler",
        ["_on_reclassify_error", "_on_rescore_error"],
    )
    def test_the_table_is_refreshed(
        self, questions_tab: Any, monkeypatch: pytest.MonkeyPatch, handler: str
    ) -> None:
        """The cancelled path refreshes it; the error path has to as well."""
        questions_tab._reclassify_worker = MagicMock()
        questions_tab._rescore_worker = MagicMock()
        reloaded = MagicMock()
        monkeypatch.setattr(questions_tab, "_load_questions", reloaded)

        getattr(questions_tab, handler)("The provider refused the request.")

        assert reloaded.called, "the table still showed the pre-pass values"


class TestACancelThatAlsoFailedKeepsWhatWasAssessed:
    """The signal's own docstring promises the partial result.

    ``filtered``/``assessments`` only exist once ``filter_documents`` comes
    back, so a failure part way emitted two empty lists -- while the
    progress callback had already shown the user those assessments being
    made (#326).
    """

    def test_the_assessments_made_before_the_failure_survive(self) -> None:
        """Three documents were assessed; three are reported."""
        worker, recorder, assessed = quality_worker(
            count=5, cancel_at=3, raises=RuntimeError("the database went away")
        )

        worker.run()

        name, args = recorder.only()
        assert name == "cancelled"
        assert len(assessed) == 3
        assert len(args[1]) == 2, (
            "the assessments completed before the failure were thrown away"
        )
        assert args[2] == 5
