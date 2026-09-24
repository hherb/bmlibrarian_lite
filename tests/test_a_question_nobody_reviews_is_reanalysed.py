# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""A correction reaches a question nobody reviews again (#373, #372).

#360 made a stored row an earlier analyser wrote a cache miss, re-analysed
the next time a review asks for its document. Nothing else asked:
``get_documents_pending_transparency`` had no production caller, so every
study the user did not happen to review again kept a withheld badge for
good -- and a question reloaded from the store showed no transparency badge
at all, current or not, so a missing badge meant a fourth thing beside
disabled, still running and failed.

Three halves, all here: a reloaded question shows what the store holds
without fetching anything; an explicit pass on the Research Questions tab
re-analyses what is pending, through the same body the review runs; and the
report says what its withheld counts are a share of, since the reference
list annotates only the cited studies (#372).
"""

import json
import sqlite3
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.analysis_failures import (
    REANALYSE_TRANSPARENCY_ACTION,
    not_stored_assessment_caveat,
    provisional_text,
    reanalysis_advice,
    superseded_assessment_caveat,
    transparency_failure_text,
    unreadable_assessment_caveat,
    unreadable_assessments_clause,
)
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    PassOutcome,
    ReportMetadata,
    TransparencyAnalysisFailure,
)
from bmlibrarian_lite.transparency import (
    LEGACY_ANALYZER_VERSION,
    TRANSPARENCY_ANALYZER_VERSION,
    TransparencyResult,
    TransparencyRisk,
    TransparencyUnassessed,
    count_transparency_over,
    pending_transparency_ids,
    stored_transparency_outcomes,
)


def a_row(
    document_id: str,
    version: str = TRANSPARENCY_ANALYZER_VERSION,
    risk: TransparencyRisk = TransparencyRisk.LOW,
    unreachable: bool = False,
) -> TransparencyResult:
    """Build a stored assessment.

    Args:
        document_id: The document it belongs to.
        version: The analyser version that wrote it.
        risk: The risk level it found.
        unreachable: Whether a source it scores against could not be read.

    Returns:
        The result.
    """
    return TransparencyResult(
        document_id=document_id,
        transparency_score=80,
        risk_level=risk,
        analyzer_version=version,
        sources_unreachable=unreachable,
    )


def a_document(
    document_id: str,
    pmid: str | None = "12345678",
    doi: str | None = None,
) -> LiteDocument:
    """Build a document.

    Args:
        document_id: Its id.
        pmid: Its PubMed ID, or None.
        doi: Its DOI, or None.

    Returns:
        The document.
    """
    return LiteDocument(
        id=document_id,
        title=f"Study {document_id}",
        abstract="An abstract.",
        authors=["A"],
        year=2024,
        pmid=pmid,
        doi=doi,
        source=DocumentSource.PUBMED,
    )


# ---------------------------------------------------------------------------
# Which documents are pending
# ---------------------------------------------------------------------------


class TestPendingIsTheCachesOwnQuestion:
    """The pass and the review may not disagree about what is done."""

    def test_each_kind_of_unfinished_row_is_pending(self) -> None:
        """No row, a superseded one and a provisional one are all work."""
        stored = {
            "stale": a_row("stale", version=LEGACY_ANALYZER_VERSION),
            "provisional": a_row("provisional", unreachable=True),
            "current": a_row("current"),
            "later": a_row("later", version="10.0"),
        }

        pending = pending_transparency_ids(
            stored, ["missing", "stale", "provisional", "current", "later"]
        )

        assert pending == ["missing", "stale", "provisional"]

    def test_a_repeated_id_is_pending_once_in_first_order(self) -> None:
        """A pass that analysed one study twice would pay for it twice."""
        assert pending_transparency_ids({}, ["b", "a", "b"]) == ["b", "a"]

    def test_the_verdict_matches_the_managers_cache(self) -> None:
        """Pending exactly when the cache would miss: one predicate, not two."""
        rows = [
            a_row("x", version=LEGACY_ANALYZER_VERSION),
            a_row("x", unreachable=True),
            a_row("x"),
            a_row("x", version="10.0"),
        ]
        for row in rows:
            assert (pending_transparency_ids({"x": row}, ["x"]) == ["x"]) is (
                not row.is_final
            )


# ---------------------------------------------------------------------------
# A reloaded question shows what the store holds
# ---------------------------------------------------------------------------


class TestAReloadedQuestionShowsItsBadges:
    """A question loaded from the store showed no badge at all (#373)."""

    def test_a_current_row_is_shown_as_the_finding_it_is(self) -> None:
        """The control: withholding everything would be the opposite defect."""
        row = a_row("a", risk=TransparencyRisk.HIGH)

        outcomes = stored_transparency_outcomes([a_document("a")], {"a": row})

        assert outcomes["a"] is row

    def test_a_provisional_row_is_still_shown(self) -> None:
        """A weakened finding, presented with its caveat -- as in a review."""
        row = a_row("a", unreachable=True)

        outcomes = stored_transparency_outcomes([a_document("a")], {"a": row})

        assert outcomes["a"] is row

    def test_a_superseded_row_is_withheld_and_says_how_to_redo_it(self) -> None:
        """No risk level the corrections retracted, and a way forward."""
        stored = {"a": a_row("a", version=LEGACY_ANALYZER_VERSION)}

        outcome = stored_transparency_outcomes([a_document("a")], stored)["a"]

        assert isinstance(outcome, TransparencyUnassessed)
        assert outcome.reason == superseded_assessment_caveat() + reanalysis_advice()

    def test_a_document_with_no_row_is_named_not_left_blank(self) -> None:
        """A blank badge read as "still running"."""
        outcome = stored_transparency_outcomes([a_document("a")], {})["a"]

        assert isinstance(outcome, TransparencyUnassessed)
        assert outcome.reason == not_stored_assessment_caveat() + reanalysis_advice()

    def test_a_document_nothing_can_look_up_is_not_sent_to_the_pass(
        self,
    ) -> None:
        """Advice the pass cannot honour is a wrong remedy, not a smaller one."""
        document = a_document("a", pmid=None, doi=None)

        outcome = stored_transparency_outcomes([document], {})["a"]

        assert isinstance(outcome, TransparencyUnassessed)
        assert outcome.reason == transparency_failure_text(
            TransparencyAnalysisFailure.no_identifier("a")
        )
        assert REANALYSE_TRANSPARENCY_ACTION not in outcome.reason

    def test_a_current_row_stands_without_an_identifier(self) -> None:
        """A finding already made needs no identifier to be shown.

        Checked for an identifier first, a valid finding would be withheld.
        """
        document = a_document("a", pmid=None, doi=None)
        row = a_row("a", risk=TransparencyRisk.HIGH)

        outcomes = stored_transparency_outcomes([document], {"a": row})

        assert outcomes["a"] is row

    def test_a_superseded_row_without_an_identifier_is_not_sent_to_the_pass(
        self,
    ) -> None:
        """Its row is out of date, but no re-analysis can look it up."""
        document = a_document("a", pmid=None, doi=None)
        stored = {"a": a_row("a", version=LEGACY_ANALYZER_VERSION)}

        outcome = stored_transparency_outcomes([document], stored)["a"]

        assert isinstance(outcome, TransparencyUnassessed)
        assert outcome.reason == transparency_failure_text(
            TransparencyAnalysisFailure.no_identifier("a")
        )

    def test_a_doi_alone_is_enough_to_be_analysable(self) -> None:
        """Preprints carry a DOI and no PMID; they are first-class."""
        document = a_document("a", pmid=None, doi="10.1101/2024.01.01.000001")

        outcome = stored_transparency_outcomes([document], {})["a"]

        assert isinstance(outcome, TransparencyUnassessed)
        assert REANALYSE_TRANSPARENCY_ACTION in outcome.reason

    def test_every_document_gets_an_outcome(self) -> None:
        """Four states, four documents, four badges."""
        documents = [
            a_document("current"),
            a_document("stale"),
            a_document("missing"),
            a_document("anonymous", pmid=None),
        ]
        stored = {
            "current": a_row("current"),
            "stale": a_row("stale", version=LEGACY_ANALYZER_VERSION),
        }

        outcomes = stored_transparency_outcomes(documents, stored)

        assert set(outcomes) == {"current", "stale", "missing", "anonymous"}


class TestTheCaveatSaysOnlyWhatIsTrue:
    """"Is being re-analysed" was true only inside a running review."""

    def test_the_superseded_caveat_claims_no_work_in_progress(self) -> None:
        """A reloaded question shows it with nothing running at all."""
        caveat = superseded_assessment_caveat()

        assert "is being re-analysed" not in caveat
        assert "has not been re-analysed yet" in caveat

    def test_the_advice_names_the_action_the_menu_shows(self) -> None:
        """A label renamed on the menu alone would send the reader nowhere."""
        actions = menu_actions(enabled=True, busy=False, total_documents=3)

        assert REANALYSE_TRANSPARENCY_ACTION in reanalysis_advice()
        assert REANALYSE_TRANSPARENCY_ACTION in actions


def menu_actions(enabled: bool, busy: bool, total_documents: int) -> dict[str, Any]:
    """Build the Research Questions context menu with stand-in actions.

    Args:
        enabled: Whether transparency analysis is switched on.
        busy: Whether a run is already under way.
        total_documents: How many documents the selected question has.

    Returns:
        Each action the menu was given, by its label.
    """
    pytest.importorskip("PySide6")
    from PySide6.QtCore import QPoint

    from bmlibrarian_lite.gui import research_questions_tab as module

    actions: dict[str, Any] = {}

    def make_action(label: str, _parent: Any) -> Any:
        action = MagicMock()
        actions[label] = action
        return action

    tab = MagicMock()
    tab.config.transparency.enabled = enabled
    tab._is_busy.return_value = busy
    tab._get_selected_question.return_value.total_documents = total_documents
    with patch.object(module, "QAction", side_effect=make_action), \
            patch.object(module, "QMenu"):
        module.ResearchQuestionsTab._show_context_menu(tab, QPoint())
    return actions


class TestTheMenuOffersTheAction:
    """Where the reader can reach it, and only when it can run."""

    def test_it_is_offered_when_it_can_run(self) -> None:
        """The control."""
        action = menu_actions(enabled=True, busy=False, total_documents=3)[
            REANALYSE_TRANSPARENCY_ACTION
        ]

        action.setEnabled.assert_called_once_with(True)

    def test_it_is_not_offered_with_the_analysis_switched_off(self) -> None:
        """Advice to run it is only ever given with the analysis on."""
        actions = menu_actions(enabled=False, busy=False, total_documents=3)

        assert REANALYSE_TRANSPARENCY_ACTION not in actions
        assert "Re-score Documents" in actions

    def test_it_waits_for_a_running_pass(self) -> None:
        """Otherwise a second run could start on top of it (#320)."""
        action = menu_actions(enabled=True, busy=True, total_documents=3)[
            REANALYSE_TRANSPARENCY_ACTION
        ]

        action.setEnabled.assert_called_once_with(False)

    def test_a_question_with_no_documents_has_nothing_to_analyse(self) -> None:
        """No document, no request."""
        action = menu_actions(enabled=True, busy=False, total_documents=0)[
            REANALYSE_TRANSPARENCY_ACTION
        ]

        action.setEnabled.assert_called_once_with(False)


class TestTheWindowShowsThemOnLoad:
    """Asserted where the loading happens, with a stand-in window."""

    @staticmethod
    def _window(enabled: bool, stored: dict) -> Any:
        """Build a stand-in main window.

        Args:
            enabled: Whether transparency analysis is switched on.
            stored: What the store holds, by document id.

        Returns:
            The stand-in.
        """
        window = MagicMock()
        window.config.transparency.enabled = enabled
        window.storage.get_transparency_results_batch.return_value = stored
        return window

    def test_loading_a_question_hands_every_document_an_outcome(self) -> None:
        """The badges a reloaded question never had."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        row = a_row("a")
        window = self._window(True, {"a": row})

        LiteMainWindow._show_stored_transparency(
            window, [a_document("a"), a_document("b")]
        )

        [call] = window.audit_trail_tab.show_transparency_outcomes.call_args_list
        outcomes = call.args[0]
        assert outcomes["a"] is row
        assert isinstance(outcomes["b"], TransparencyUnassessed)

    def test_nothing_is_shown_when_the_analysis_is_switched_off(self) -> None:
        """The control: a review run with it off shows no badge either."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = self._window(False, {})

        LiteMainWindow._show_stored_transparency(window, [a_document("a")])

        window.audit_trail_tab.show_transparency_outcomes.assert_not_called()
        window.storage.get_transparency_results_batch.assert_not_called()

    def test_a_failed_read_leaves_the_rest_of_the_load_standing(
        self,
    ) -> None:
        """A table that cannot be read must not take the report down with it.

        A single row that will not decode no longer reaches this catch: the
        reader withholds it alone (#374), which the storage tests assert.
        """
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = self._window(True, {})
        window.storage.get_transparency_results_batch.side_effect = (
            sqlite3.OperationalError("unable to open /Users/someone/lite.db")
        )

        clause = LiteMainWindow._show_stored_transparency(
            window, [a_document("a"), a_document("b")]
        )

        assert clause == unreadable_assessments_clause("OperationalError")
        # The error's own text can carry a path; only its class shows
        assert "someone" not in clause
        [call] = window.audit_trail_tab.show_transparency_outcomes.call_args_list
        outcomes = call.args[0]
        assert set(outcomes) == {"a", "b"}
        assert all(
            outcome == TransparencyUnassessed(unreadable_assessment_caveat())
            for outcome in outcomes.values()
        )

    @staticmethod
    def _loaded(stored: dict | Exception) -> Any:
        """Load a question through the window's own load path.

        Args:
            stored: What reading the stored assessments returns, or raises.

        Returns:
            The stand-in window, after the load.
        """
        from datetime import datetime

        from bmlibrarian_lite.data_models import ReviewCheckpoint
        from bmlibrarian_lite.gui.app import LiteMainWindow

        documents = {"a": a_document("a"), "b": a_document("b")}
        window = TestTheWindowShowsThemOnLoad._window(True, {})
        if isinstance(stored, Exception):
            window.storage.get_transparency_results_batch.side_effect = stored
        else:
            window.storage.get_transparency_results_batch.return_value = stored
        window._show_stored_transparency.side_effect = (
            lambda docs: LiteMainWindow._show_stored_transparency(window, docs)
        )
        window.storage.get_checkpoint_for_question.return_value = ReviewCheckpoint(
            id="checkpoint-1",
            research_question="Q",
            created_at=datetime.now(),
            updated_at=datetime.now(),
            step="complete",
            report="## Findings",
            metadata={},
        )
        window.storage.get_document_ids_for_question.return_value = list(documents)
        window.storage.get_document.side_effect = documents.get
        window.storage.get_scored_documents_for_question.return_value = []
        window.storage.get_citations_for_question.return_value = []
        window.storage.get_quality_assessments_for_question.return_value = {}

        LiteMainWindow._on_question_selected(window, "Q", "query")
        return window

    def test_the_load_path_shows_the_badges(self) -> None:
        """Extracted, so a second place for the same defect: drive the load."""
        pytest.importorskip("PySide6")

        window = self._loaded({"a": a_row("a")})

        [call] = window.audit_trail_tab.show_transparency_outcomes.call_args_list
        assert set(call.args[0]) == {"a", "b"}
        last_message = window.status_bar.showMessage.call_args.args[0]
        assert "could not be loaded" not in last_message

    def test_a_failed_read_survives_the_load_summary(self) -> None:
        """Posted on its own, it was replaced within the same call.

        The load's summary is the status bar's last word, so the failure is
        a clause of it -- and every badge says why it shows no finding.
        """
        pytest.importorskip("PySide6")

        window = self._loaded(sqlite3.OperationalError("database is locked"))

        last_message = window.status_bar.showMessage.call_args.args[0]
        assert last_message.startswith("Loaded question")
        assert unreadable_assessments_clause("OperationalError") in last_message
        [call] = window.audit_trail_tab.show_transparency_outcomes.call_args_list
        assert set(call.args[0]) == {"a", "b"}

    def test_a_reanalysis_updates_the_badges_on_screen(self) -> None:
        """The pass's outcomes reach the slot a review's outcomes reach."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = MagicMock()
        LiteMainWindow._connect_signals(window)

        signal = window.research_questions_tab.transparency_outcome_ready
        signal.connect.assert_called_once_with(
            window.audit_trail_tab.on_transparency_outcome
        )

    def test_the_audit_trail_shows_a_decided_outcome_on_its_card(
        self, qapp: Any
    ) -> None:
        """End to end on the real tab: the card carries the reason."""
        from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab

        tab = AuditTrailTab(config=MagicMock(), storage=MagicMock())
        tab.literature_tab._add_document_card(a_document("a"))
        reason = not_stored_assessment_caveat() + reanalysis_advice()

        tab.show_transparency_outcomes({"a": TransparencyUnassessed(reason=reason)})

        card = tab.literature_tab._cards_by_doc_id["a"]
        assert card.get_transparency_result() is None
        assert tab.literature_tab._transparency_outcomes["a"].reason == reason


@pytest.fixture(scope="module")
def qapp() -> Any:
    """The QApplication the widget tests need.

    Returns:
        The application, made once for the module.
    """
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


# ---------------------------------------------------------------------------
# The pass
# ---------------------------------------------------------------------------


def run_pass(
    answers: dict[str, Any],
    cancel_before: bool = False,
    documents: list[LiteDocument] | None = None,
    config: Any = None,
    cancel_during: str | None = None,
    analyzer_error: Exception | None = None,
    calls: list[tuple[Any, ...]] | None = None,
) -> tuple[str, tuple[Any, ...], list[tuple[str, Any]]]:
    """Run a re-analysis whose analyses give fixed answers.

    Args:
        answers: By document id, the stored result or the exception raised.
        cancel_before: Whether to cancel before the run starts.
        documents: The documents to re-analyse; one per answer when None.
        config: The configuration to run under; the defaults when None.
        cancel_during: A document whose analysis the user cancels during.
        analyzer_error: What creating the analyser raises, if anything.
        calls: Filled with the arguments each analysis was given, after the
            analyser, when a list is passed.

    Returns:
        The terminal signal's name, its arguments, and every per-document
        outcome emitted, in order.
    """
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker

    def assess(_analyzer: Any, *args: Any) -> TransparencyResult:
        """Answer for one document."""
        if calls is not None:
            calls.append(args)
        doc_id = args[2]
        if doc_id == cancel_during:
            worker.cancel()
        answer = answers[doc_id]
        if isinstance(answer, BaseException):
            raise answer
        return answer

    worker = TransparencyReanalysisWorker(
        config=config if config is not None else LiteConfig(),
        storage=MagicMock(),
        documents=(
            documents
            if documents is not None
            else [a_document(doc_id) for doc_id in answers]
        ),
    )
    terminal: list[tuple[str, tuple[Any, ...]]] = []
    for name in ("finished", "error", "cancelled"):
        getattr(worker, name).connect(
            lambda *args, _name=name: terminal.append((_name, args))
        )
    outcomes: list[tuple[str, Any]] = []
    worker.outcome_ready.connect(lambda doc_id, o: outcomes.append((doc_id, o)))
    if cancel_before:
        worker.cancel()
    with patch(
        "bmlibrarian_lite.transparency.assessment.assess_document", assess
    ), patch(
        "bmlibrarian_lite.transparency.assessment.create_background_analyzer",
        side_effect=analyzer_error,
    ):
        worker.run()
    [(name, args)] = terminal
    return name, args, outcomes


class TestThePassAccountsForEveryDocument:
    """Each document it reaches is a success, provisional, or a failure."""

    def test_a_clean_pass_counts_its_successes(self) -> None:
        """The control."""
        name, (outcome,), outcomes = run_pass({"a": a_row("a"), "b": a_row("b")})

        assert name == "finished"
        assert (outcome.succeeded, outcome.failed, outcome.provisional) == (2, 0, 0)
        assert [doc_id for doc_id, _ in outcomes] == ["a", "b"]

    def test_an_unreadable_source_is_provisional_not_a_success(self) -> None:
        """Counted as re-analysed, a throttled PubMed read as all-clear."""
        name, (outcome,), outcomes = run_pass(
            {"a": a_row("a", unreachable=True), "b": a_row("b")}
        )

        assert name == "finished"
        assert (outcome.succeeded, outcome.provisional) == (1, 1)
        assert outcome.attempted == 2
        # Stored and shown, so the badge gets it like any other result
        assert isinstance(outcomes[0][1], TransparencyResult)

    def test_a_failure_is_classified_and_reaches_the_badge(self) -> None:
        """The raw text can carry a credential; the value cannot (#330)."""
        name, (outcome,), outcomes = run_pass(
            {"a": TimeoutError("https://x/?api_key=SECRET"), "b": a_row("b")}
        )

        assert name == "finished"
        assert outcome.causes == (EvaluationErrorCode.API_TIMEOUT,)
        failure = outcomes[0][1]
        assert isinstance(failure, TransparencyAnalysisFailure)
        assert failure.cause is EvaluationErrorCode.API_TIMEOUT
        assert "SECRET" not in transparency_failure_text(failure)

    def test_a_cancel_before_the_first_document_does_nothing(self) -> None:
        """What a cancel stopped is counted, not called off (#320)."""
        name, (outcome, error), outcomes = run_pass(
            {"a": a_row("a")}, cancel_before=True
        )

        assert name == "cancelled"
        assert (outcome.attempted, outcome.not_attempted, error) == (0, 1, "")
        assert outcomes == []


    def test_each_analysis_gets_its_own_documents_identifiers(self) -> None:
        """Swapped or dropped, a DOI-only preprint is looked up by nothing."""
        from bmlibrarian_lite.config import LiteConfig

        config = LiteConfig()
        calls: list[tuple[Any, ...]] = []
        run_pass(
            {"pmid-only": a_row("pmid-only"), "doi-only": a_row("doi-only")},
            documents=[
                a_document("pmid-only", pmid="111"),
                a_document("doi-only", pmid=None, doi="10.1101/2024.01.01"),
            ],
            config=config,
            calls=calls,
        )

        # After the analyser: storage, settings, id, PMID, DOI
        assert all(call[1] is config.transparency for call in calls)
        assert [call[2:] for call in calls] == [
            ("pmid-only", "111", None),
            ("doi-only", None, "10.1101/2024.01.01"),
        ]

    def test_a_cancel_between_documents_says_what_was_left(self) -> None:
        """The analysis under way finishes; the next one is not started."""
        calls: list[tuple[Any, ...]] = []
        name, (outcome, error), outcomes = run_pass(
            {"a": a_row("a"), "b": a_row("b")}, cancel_during="a", calls=calls
        )

        assert name == "cancelled"
        assert error == ""
        assert (outcome.succeeded, outcome.not_attempted) == (1, 1)
        assert [call[2] for call in calls] == ["a"]
        assert [doc_id for doc_id, _ in outcomes] == ["a"]

    def test_a_cancel_after_the_last_document_stopped_nothing(self) -> None:
        """The control: every document was re-analysed, so it finished."""
        name, (outcome,), _ = run_pass(
            {"a": a_row("a"), "b": a_row("b")}, cancel_during="b"
        )

        assert name == "finished"
        assert outcome.succeeded == 2

    def test_a_pass_that_cannot_start_says_why_in_its_own_words(self) -> None:
        """The provider's text can print the request, credentials and all."""
        name, (error,), outcomes = run_pass(
            {"a": a_row("a")},
            analyzer_error=RuntimeError("GET https://x?api_key=SECRET failed"),
        )

        assert name == "error"
        assert error
        assert "SECRET" not in error
        assert outcomes == []

    def test_a_pass_that_cannot_start_while_cancelling_is_a_cancel(self) -> None:
        """Cancelling is not failing, but the failure is still reported."""
        name, (outcome, error), _ = run_pass(
            {"a": a_row("a")},
            cancel_before=True,
            analyzer_error=RuntimeError("GET https://x?api_key=SECRET failed"),
        )

        assert name == "cancelled"
        assert error and "SECRET" not in error
        assert outcome.attempted == 0

    def test_a_document_nothing_can_look_up_is_refused(self) -> None:
        """Let through, it would read as a provider failure."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker

        with pytest.raises(ValueError, match="neither a PMID nor a DOI"):
            TransparencyReanalysisWorker(
                config=LiteConfig(),
                storage=MagicMock(),
                documents=[a_document("a"), a_document("b", pmid=None)],
            )


class TestThePassSaysWhatItDid:
    """The sentences a provisional result adds."""

    def test_a_provisional_result_is_named_in_the_summary(self) -> None:
        """So the numbers add up on their own."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.research_questions_tab import pass_finished_text

        outcome = PassOutcome(succeeded=3, total=5, provisional=2)

        assert pass_finished_text(
            "Transparency re-analysis", "re-analysed", outcome
        ) == "Transparency re-analysis complete: 3 re-analysed, 2 provisional."

    def test_the_explanation_says_why_they_stay_pending(self) -> None:
        """A count alone does not say what the reader is looking at."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.research_questions_tab import (
            pass_failure_explanation,
        )

        outcome = PassOutcome(succeeded=0, total=2, provisional=2)

        assert pass_failure_explanation(outcome) == provisional_text(2)
        assert "stay pending" in provisional_text(2)

    def test_a_clean_pass_explains_nothing(self) -> None:
        """The control."""
        assert provisional_text(0) == ""

    def test_the_scope_names_what_cannot_be_looked_up(self) -> None:
        """So a badge still reading "Not assessed" is not a mystery."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.research_questions_tab import (
            reanalysis_scope_text,
        )

        assert reanalysis_scope_text(12, 2) == (
            "12 documents have no settled transparency assessment (missing, "
            "provisional, out of date or unreadable) and can be re-analysed. "
            "2 more carry no PubMed ID or DOI to look one up by."
        )
        assert reanalysis_scope_text(1, 1) == (
            "1 document has no settled transparency assessment (missing, "
            "provisional, out of date or unreadable) and can be re-analysed. "
            "1 more carries no PubMed ID or DOI to look one up by."
        )
        assert reanalysis_scope_text(0, 0) == (
            "Every document that can be analysed has a settled assessment."
        )

    def test_the_scope_does_not_call_a_provisional_row_absent(self) -> None:
        """A provisional row is current, and its badge is on screen (review)."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.research_questions_tab import (
            reanalysis_scope_text,
        )

        assert "no current" not in reanalysis_scope_text(3, 0)
        assert "provisional" in reanalysis_scope_text(3, 0)

    def test_a_provisional_count_must_be_whole(self) -> None:
        """PassOutcome refuses counts that cannot be true."""
        with pytest.raises(ValueError):
            PassOutcome(succeeded=0, total=1, provisional=-1)
        with pytest.raises(ValueError):
            PassOutcome(succeeded=1, total=1, provisional=1)


class TestTheTabOffersOnlyWhatIsPending:
    """The action's handler, driven with a stand-in tab."""

    @staticmethod
    def _tab(pending: list[str], documents: list[LiteDocument]) -> Any:
        """Build a stand-in Research Questions tab.

        Args:
            pending: What the store says is pending.
            documents: What the store returns for them.

        Returns:
            The stand-in.
        """
        tab = MagicMock()
        tab._get_selected_question.return_value.question = "Q"
        tab.storage.get_documents_pending_transparency.return_value = pending
        tab.storage.get_documents.return_value = documents
        return tab

    def test_nothing_to_do_starts_nothing_and_says_so(self) -> None:
        """A question whose assessments are current costs no request."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui import research_questions_tab as module

        tab = self._tab(["anon"], [a_document("anon", pmid=None)])

        with patch.object(module, "TransparencyReanalysisWorker") as worker_cls:
            module.ResearchQuestionsTab._on_reanalyse_transparency_clicked(tab)

        worker_cls.assert_not_called()
        tab.progress_label.setText.assert_called_once_with(
            module.reanalysis_scope_text(0, 1)
        )

    def test_the_pass_is_given_the_analysable_pending_documents(self) -> None:
        """And its outcomes are forwarded to the badges."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QMessageBox

        from bmlibrarian_lite.gui import research_questions_tab as module

        stale = a_document("stale")
        anon = a_document("anon", pmid=None)
        tab = self._tab(["stale", "anon"], [stale, anon])

        with patch.object(module, "TransparencyReanalysisWorker") as worker_cls, \
                patch.object(
                    module.QMessageBox,
                    "question",
                    return_value=QMessageBox.StandardButton.Yes,
                ):
            module.ResearchQuestionsTab._on_reanalyse_transparency_clicked(tab)

        tab.storage.get_documents_pending_transparency.assert_called_once_with("Q")
        assert worker_cls.call_args.kwargs["documents"] == [stale]
        worker = worker_cls.return_value
        worker.outcome_ready.connect.assert_called_once_with(
            tab.transparency_outcome_ready
        )
        worker.start.assert_called_once()

    def test_the_dialog_opens_with_what_the_pass_would_cover(self) -> None:
        """The scope sentence is the choice the user is asked to make."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QMessageBox

        from bmlibrarian_lite.gui import research_questions_tab as module

        tab = self._tab(["stale", "anon"], [a_document("stale"), a_document("anon", pmid=None)])

        with patch.object(module, "TransparencyReanalysisWorker"), \
                patch.object(
                    module.QMessageBox,
                    "question",
                    return_value=QMessageBox.StandardButton.No,
                ) as question:
            module.ResearchQuestionsTab._on_reanalyse_transparency_clicked(tab)

        body = question.call_args.args[2]
        assert body.startswith(module.reanalysis_scope_text(1, 1))

    def test_a_store_it_cannot_read_starts_nothing_and_says_so(self) -> None:
        """A stored document that will not decode must not crash the tab."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui import research_questions_tab as module

        tab = self._tab([], [])
        tab.storage.get_documents.side_effect = json.JSONDecodeError(
            "Expecting value", "", 0
        )

        with patch.object(module, "TransparencyReanalysisWorker") as worker_cls:
            module.ResearchQuestionsTab._on_reanalyse_transparency_clicked(tab)

        worker_cls.assert_not_called()
        [call] = tab.progress_label.setText.call_args_list
        assert call.args[0] == (
            "Could not read this question's stored documents or "
            "assessments: JSONDecodeError"
        )

    def test_declining_starts_nothing(self) -> None:
        """The control: the dialog is a real choice."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QMessageBox

        from bmlibrarian_lite.gui import research_questions_tab as module

        tab = self._tab(["stale"], [a_document("stale")])

        with patch.object(module, "TransparencyReanalysisWorker") as worker_cls, \
                patch.object(
                    module.QMessageBox,
                    "question",
                    return_value=QMessageBox.StandardButton.No,
                ):
            module.ResearchQuestionsTab._on_reanalyse_transparency_clicked(tab)

        worker_cls.assert_not_called()

    @staticmethod
    def _ended(handler: str, *args: Any) -> Any:
        """Run one of the tab's end-of-pass handlers with its dialogs replaced.

        Args:
            handler: The handler's name.
            *args: What the worker's signal carried.

        Returns:
            The stand-in QMessageBox the handler reported through.
        """
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui import research_questions_tab as module

        tab = MagicMock()
        with patch.object(module, "QMessageBox") as box, \
                patch.object(module, "QTimer"):
            getattr(module.ResearchQuestionsTab, handler)(tab, *args)
        return box

    def test_a_clean_pass_ends_on_information(self) -> None:
        """The control."""
        box = self._ended(
            "_on_transparency_finished", PassOutcome(succeeded=2, total=2)
        )

        box.information.assert_called_once()
        box.warning.assert_not_called()

    def test_a_provisional_pass_ends_on_a_warning(self) -> None:
        """Provisional is the point: a throttled source is not all-clear."""
        box = self._ended(
            "_on_transparency_finished",
            PassOutcome(succeeded=1, total=2, provisional=1),
        )

        box.warning.assert_called_once()
        box.information.assert_not_called()
        assert provisional_text(1).strip() in box.warning.call_args.args[2]

    def test_a_cancel_names_its_provisional_results(self) -> None:
        """Left out, the counts in the sentence did not add up (#327)."""
        from bmlibrarian_lite.gui.research_questions_tab import pass_cancelled_text

        text = pass_cancelled_text(
            "Transparency re-analysis",
            "re-analysed",
            PassOutcome(succeeded=1, total=3, provisional=1),
        )

        assert text == (
            "Transparency re-analysis cancelled after 2 of 3 documents: "
            "1 re-analysed, 1 provisional. The other one was not re-analysed."
        )

    def test_a_running_pass_keeps_the_tab_busy(self) -> None:
        """Otherwise a second run could start on top of it (#320)."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.research_questions_tab import ResearchQuestionsTab

        tab = MagicMock()
        tab._worker = tab._benchmark_worker = None
        tab._reclassify_worker = tab._rescore_worker = None
        tab._transparency_worker = object()

        assert ResearchQuestionsTab._is_busy(tab)


# ---------------------------------------------------------------------------
# #372: the report names what its counts are a share of
# ---------------------------------------------------------------------------


class TestTheCountsNameTheirPopulations:
    """One figure over the reviewed set, annotations over the cited set."""

    def test_counting_over_ids_accounts_for_every_document(self) -> None:
        """Rows, missing rows and repeats, each counted once."""
        stored = {
            "low": a_row("low"),
            "stale": a_row("stale", version=LEGACY_ANALYZER_VERSION),
            "unknown": a_row("unknown", risk=TransparencyRisk.UNKNOWN),
            "elsewhere": a_row("elsewhere"),
        }

        counts = count_transparency_over(
            stored, ["low", "stale", "unknown", "missing", "low"]
        )

        assert (counts.low, counts.superseded) == (1, 1)
        assert (counts.unknown, counts.not_stored, counts.not_assessed) == (1, 1, 2)
        assert counts.considered == 4

    def test_the_workflow_counts_the_cited_share(self) -> None:
        """The figures the report states, from the worker that fills them."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = {
            "s1": a_row("s1", version=LEGACY_ANALYZER_VERSION),
            "s2": a_row("s2", version=LEGACY_ANALYZER_VERSION),
            "ok": a_row("ok"),
        }
        metadata = ReportMetadata(research_question="Q")

        WorkflowWorker._record_transparency_counts(
            worker, metadata, ["s1", "s2", "ok", "gone"], cited_ids=["s1", "ok"]
        )

        assert metadata.transparency_documents_considered == 4
        assert metadata.transparency_superseded_count == 2
        assert metadata.transparency_superseded_cited_count == 1
        assert metadata.transparency_unassessed_count == 1
        assert metadata.transparency_unassessed_cited_count == 0

    def test_without_the_cited_set_no_share_is_claimed(self) -> None:
        """The control: None, not a zero the report would print as fact."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        worker = MagicMock()
        worker.storage.get_transparency_results_batch.return_value = {}
        metadata = ReportMetadata(research_question="Q")

        WorkflowWorker._record_transparency_counts(worker, metadata, ["a"])

        assert metadata.transparency_superseded_cited_count is None
        assert metadata.transparency_unassessed_cited_count is None

    def test_the_workflow_passes_the_cited_documents(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A parameter nobody passes is the #361 defect one level on."""
        pytest.importorskip("PySide6")
        from tests.test_gui_extraction_failures import CITED, run_worker

        reporting_agent = MagicMock()
        run_worker(
            monkeypatch,
            reporting_agent=reporting_agent,
            transparency_reads=[{}],
        )

        metadata = reporting_agent.generate_report.call_args.args[2]
        # CITED is the one cited study, with no stored row: its share is named
        assert metadata.transparency_unassessed_cited_count == 1
        assert metadata.transparency_documents_considered == 3
        assert CITED.id not in (
            reporting_agent.generate_report.call_args.kwargs["transparency_results"]
        )

    def test_the_counts_and_the_annotations_come_from_one_read(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A row stored between two reads split the count from its notes.

        Background analyses store rows while the review runs. Counted from
        one read and annotated from a second, a cited study counted "Not
        assessed" could carry a risk annotation instead.
        """
        pytest.importorskip("PySide6")
        from tests.test_gui_extraction_failures import CITED, run_worker

        reporting_agent = MagicMock()
        landed_late = {CITED.id: a_row(CITED.id)}
        run_worker(
            monkeypatch,
            reporting_agent=reporting_agent,
            transparency_reads=[{}, landed_late],
        )

        call = reporting_agent.generate_report.call_args
        assert call.args[2].transparency_unassessed_cited_count == 1
        assert call.kwargs["transparency_results"] == {}

    def test_rows_the_count_read_are_the_ones_annotated(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The control: a row already stored reaches the report's references."""
        pytest.importorskip("PySide6")
        from tests.test_gui_extraction_failures import CITED, run_worker

        reporting_agent = MagicMock()
        stored = {CITED.id: a_row(CITED.id)}
        run_worker(
            monkeypatch,
            reporting_agent=reporting_agent,
            # However often it is read, the store holds the same row
            transparency_reads=[stored, stored],
        )

        call = reporting_agent.generate_report.call_args
        assert call.args[2].transparency_unassessed_cited_count == 0
        assert call.kwargs["transparency_results"] == stored

    def test_one_study_reviewed_is_one_study(self) -> None:
        """The singular, which the plural's test cannot reach."""
        from bmlibrarian_lite.agents.reporting_agent import withheld_population_text

        assert withheld_population_text(1, 1, 1) == (
            "1 of the 1 study reviewed; it is cited in this report"
        )

    def test_populations_that_cannot_hold_the_count_are_not_named(self) -> None:
        """A share larger than its whole is no claim a reader can check."""
        from bmlibrarian_lite.agents.reporting_agent import withheld_population_text

        assert withheld_population_text(3, 40, 5) == "3 of the 40 studies reviewed"
        assert withheld_population_text(3, 2, 1) == (
            "3; 1 of them is cited in this report"
        )
        assert withheld_population_text(3, 40, -1) == "3 of the 40 studies reviewed"

    def test_the_report_names_both_populations(self) -> None:
        """The sentence the reader actually gets."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent

        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True
        metadata.transparency_low_risk_count = 25
        metadata.transparency_superseded_count = 12
        metadata.transparency_unassessed_count = 3
        metadata.transparency_documents_considered = 40
        metadata.transparency_superseded_cited_count = 3
        metadata.transparency_unassessed_cited_count = 0

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "Documents Analyzed:** 25 of the 40 studies reviewed\n" in section
        assert (
            "Awaiting re-analysis:** 12 of the 40 studies reviewed; "
            "3 of them are cited in this report." in section
        )
        assert (
            "Not assessed:** 3 of the 40 studies reviewed; "
            "none of them is cited in this report." in section
        )

    def test_an_older_report_keeps_its_bare_count(self) -> None:
        """No population recorded, none invented."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent

        metadata = ReportMetadata.from_dict(
            {
                "research_question": "Q",
                "transparency_analysis_applied": True,
                "transparency_superseded_count": 4,
            }
        )

        section = LiteReportingAgent.format_methodology_section(
            MagicMock(), metadata
        )

        assert "Awaiting re-analysis:** 4. Their stored" in section

    def test_the_populations_survive_a_round_trip(self) -> None:
        """A field in to_dict and not in from_dict is lost on reload."""
        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_documents_considered = 40
        metadata.transparency_superseded_cited_count = 3
        metadata.transparency_unassessed_cited_count = 0

        reloaded = ReportMetadata.from_dict(metadata.to_dict())

        assert reloaded.transparency_documents_considered == 40
        assert reloaded.transparency_superseded_cited_count == 3
        assert reloaded.transparency_unassessed_cited_count == 0

    @pytest.mark.parametrize(
        ("count", "cited", "clause"),
        [
            (1, 1, "it is cited in this report"),
            (1, 0, "it is not cited in this report"),
            (5, 0, "none of them is cited in this report"),
            (5, 5, "all of them are cited in this report"),
            (5, 1, "1 of them is cited in this report"),
            (5, 3, "3 of them are cited in this report"),
        ],
    )
    def test_the_cited_clause_agrees_with_its_numbers(
        self, count: int, cited: int, clause: str
    ) -> None:
        """Every branch, since each is a sentence a reader gets."""
        from bmlibrarian_lite.agents.reporting_agent import cited_share_text

        assert cited_share_text(count, cited) == clause


class TestEveryCountedStudyCanBeFoundInTheReferences:
    """A cited share of "Not assessed" must point at annotated entries."""

    def test_each_kind_of_withheld_study_is_annotated(self) -> None:
        """Superseded, never stored, and at no nameable level."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            withheld_reference_caveats,
        )
        from bmlibrarian_lite.analysis_failures import no_risk_level_caveat

        stored = {
            "stale": a_row("stale", version=LEGACY_ANALYZER_VERSION),
            "unknown": a_row("unknown", risk=TransparencyRisk.UNKNOWN),
            "low": a_row("low"),
            "provisional": a_row("provisional", unreachable=True),
        }

        caveats = withheld_reference_caveats(
            ["stale", "unknown", "low", "provisional", "missing"], stored, True
        )

        assert caveats == {
            "stale": superseded_assessment_caveat(),
            "unknown": no_risk_level_caveat(),
            "missing": not_stored_assessment_caveat(),
        }

    def test_a_missing_row_says_nothing_when_nothing_was_asked(self) -> None:
        """The control: with the analysis off, no row is the expected state."""
        from bmlibrarian_lite.agents.report_risk_helpers import (
            withheld_reference_caveats,
        )

        assert withheld_reference_caveats(["missing"], {}, False) == {}

    def test_the_report_annotates_a_cited_study_with_no_row(self) -> None:
        """End to end: the reader can find the study the count names."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import Citation
        from bmlibrarian_lite.transparency import TransparencySettings

        config = MagicMock()
        config.transparency = TransparencySettings(enabled=True)
        citation = Citation(
            document=a_document("gone"), passage="P.", relevance_score=4
        )
        metadata = ReportMetadata(research_question="Q")
        metadata.transparency_analysis_applied = True

        with patch.object(
            LiteReportingAgent, "_chat", return_value="Body [A](docid:gone)."
        ):
            report = LiteReportingAgent(config=config).generate_report(
                "Q", [citation], metadata, transparency_results={}
            )

        assert "TRANSPARENCY NOT ASSESSED" in report
        assert not_stored_assessment_caveat() in report

    def test_a_report_with_the_analysis_off_annotates_nothing(self) -> None:
        """The control."""
        from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
        from bmlibrarian_lite.data_models import Citation
        from bmlibrarian_lite.transparency import TransparencySettings

        config = MagicMock()
        config.transparency = TransparencySettings(enabled=False)
        citation = Citation(
            document=a_document("gone"), passage="P.", relevance_score=4
        )

        with patch.object(
            LiteReportingAgent, "_chat", return_value="Body [A](docid:gone)."
        ):
            report = LiteReportingAgent(config=config).generate_report(
                "Q", [citation], ReportMetadata(research_question="Q"),
                transparency_results={},
            )

        assert "TRANSPARENCY NOT ASSESSED" not in report
