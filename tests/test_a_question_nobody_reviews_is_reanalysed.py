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
        pytest.importorskip("PySide6")
        import inspect

        from bmlibrarian_lite.gui.research_questions_tab import ResearchQuestionsTab

        menu = inspect.getsource(ResearchQuestionsTab._show_context_menu)

        assert REANALYSE_TRANSPARENCY_ACTION in reanalysis_advice()
        assert "QAction(REANALYSE_TRANSPARENCY_ACTION" in menu


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

    def test_an_undecodable_row_leaves_the_rest_of_the_load_standing(
        self,
    ) -> None:
        """A newer build's risk level must not take the report down with it."""
        pytest.importorskip("PySide6")
        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = self._window(True, {})
        window.storage.get_transparency_results_batch.side_effect = ValueError(
            "'extreme' is not a valid TransparencyRisk"
        )

        LiteMainWindow._show_stored_transparency(window, [a_document("a")])

        window.audit_trail_tab.show_transparency_outcomes.assert_not_called()
        [call] = window.status_bar.showMessage.call_args_list
        assert "could not be loaded" in call.args[0]

    def test_the_load_path_calls_it(self) -> None:
        """Extracted, so a second place for the same defect: assert the call."""
        pytest.importorskip("PySide6")
        import inspect

        from bmlibrarian_lite.gui.app import LiteMainWindow

        source = inspect.getsource(LiteMainWindow._on_question_selected)
        assert "self._show_stored_transparency(documents_found)" in source

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
    answers: dict[str, Any], cancel_before: bool = False
) -> tuple[str, tuple[Any, ...], list[tuple[str, Any]]]:
    """Run a re-analysis whose analyses give fixed answers.

    Args:
        answers: By document id, the stored result or the exception raised.
        cancel_before: Whether to cancel before the run starts.

    Returns:
        The terminal signal's name, its arguments, and every per-document
        outcome emitted, in order.
    """
    pytest.importorskip("PySide6")
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.gui.workers import TransparencyReanalysisWorker

    def assess(
        _analyzer: Any, _storage: Any, _settings: Any, doc_id: str, *_: Any
    ) -> TransparencyResult:
        """Answer for one document."""
        answer = answers[doc_id]
        if isinstance(answer, BaseException):
            raise answer
        return answer

    worker = TransparencyReanalysisWorker(
        config=LiteConfig(),
        storage=MagicMock(),
        documents=[a_document(doc_id) for doc_id in answers],
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
        "bmlibrarian_lite.transparency.assessment.create_background_analyzer"
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
            "provisional or out of date) and can be re-analysed. 2 more carry "
            "no PubMed ID or DOI to look one up by."
        )
        assert reanalysis_scope_text(1, 1) == (
            "1 document has no settled transparency assessment (missing, "
            "provisional or out of date) and can be re-analysed. 1 more "
            "carries no PubMed ID or DOI to look one up by."
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

    def test_the_workflow_passes_the_cited_documents(self) -> None:
        """A parameter nobody passes is the #361 defect one level on."""
        pytest.importorskip("PySide6")
        import inspect

        from bmlibrarian_lite.gui.systematic_review_tab import WorkflowWorker

        assert "cited_ids=list(unique_docs)" in inspect.getsource(WorkflowWorker.run)

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
