# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The audit trail records what happened, not what absence suggests (#302).

The durable record -- ``~/bmlibrarian_reports/*_audit.json`` and the Audit
Trail dialog -- built its "Rejected Documents" list from every found document
that was not among the accepted ones, and gave each the reason "Score below
minimum threshold". Nobody gave that reason. A document the model could not
score, and a document the quality filter removed before scoring, were both
written out as judged irrelevant, so a run with a flaky provider produced a
report saying "3 of 20 documents could not be scored" beside an audit file
asserting those 3 were read and found wanting.

#301 fixed this in ``ReportMetadata``; these tests follow it into the record
that outlives the session.
"""

import json
from typing import Any

import pytest

from bmlibrarian_lite.audit_records import (
    DocumentOutcomes,
    classify_document_outcomes,
    scoring_failure_reason,
)
from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ReportMetadata,
    ScoredDocument,
)

MIN_SCORE = 3
QUESTION = "Does aspirin prevent stroke?"
REJECTION = "Reports a different outcome measure."


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
        source=DocumentSource.EUROPEPMC,
    )


def scored(document: LiteDocument, score: int, explanation: str) -> ScoredDocument:
    """A document the model answered about, well or badly."""
    return ScoredDocument(document=document, score=score, explanation=explanation)


def accepted(pmid: str) -> ScoredDocument:
    """A document that met the threshold."""
    return scored(make_document(pmid), 4, "On topic.")


def rejected(pmid: str) -> ScoredDocument:
    """A document the model read and judged below the threshold."""
    return scored(make_document(pmid), 1, REJECTION)


def failed(pmid: str, code: EvaluationErrorCode | int = -4) -> ScoredDocument:
    """A document the model could not score."""
    value = code.value if isinstance(code, EvaluationErrorCode) else code
    return scored(make_document(pmid), value, "Scoring failed")


class TestTheCategoriesAreWhatHappened:
    """Four outcomes, told apart by the score the document actually got."""

    def test_a_document_that_could_not_be_scored_is_not_a_rejected_one(self) -> None:
        """#302's harm: a failure written into the record as a judgement."""
        could_not = failed("2")
        found = [make_document("1"), make_document("2")]

        outcomes = classify_document_outcomes(found, [accepted("1"), could_not], MIN_SCORE)

        assert outcomes.failed == (could_not,)
        assert outcomes.rejected == ()

    def test_a_rejected_document_keeps_the_reason_the_model_gave(self) -> None:
        """The record carries the model's words, not a sentence we made up."""
        outcomes = classify_document_outcomes(
            [make_document("1")], [rejected("1")], MIN_SCORE
        )

        assert outcomes.rejected[0].explanation == REJECTION

    def test_a_document_that_was_never_scored_is_neither(self) -> None:
        """The quality filter removes documents before scoring reaches them."""
        found = [make_document("1"), make_document("2")]

        outcomes = classify_document_outcomes(found, [accepted("1")], MIN_SCORE)

        assert [d.id for d in outcomes.not_scored] == ["doc-2"]
        assert outcomes.rejected == ()
        assert outcomes.failed == ()

    def test_the_threshold_decides_accepted_from_rejected(self) -> None:
        """A document exactly at the threshold was accepted."""
        at_threshold = scored(make_document("1"), MIN_SCORE, "On topic.")
        below = scored(make_document("2"), MIN_SCORE - 1, REJECTION)

        outcomes = classify_document_outcomes(
            [make_document("1"), make_document("2")], [at_threshold, below], MIN_SCORE
        )

        assert outcomes.accepted == (at_threshold,)
        assert outcomes.rejected == (below,)

    def test_every_found_document_lands_in_exactly_one_category(self) -> None:
        """A record whose numbers do not reconcile hides what it lost."""
        found = [make_document(str(n)) for n in range(1, 5)]
        outcomes = classify_document_outcomes(
            found, [accepted("1"), rejected("2"), failed("3")], MIN_SCORE
        )

        counted = (
            len(outcomes.accepted)
            + len(outcomes.rejected)
            + len(outcomes.failed)
            + len(outcomes.not_scored)
        )
        assert counted == len(found)
        assert outcomes.documents_scored == 2

    def test_a_document_scored_but_never_found_is_still_counted(self) -> None:
        """A restored session can hold scores for documents the list has lost."""
        only = accepted("1")

        outcomes = classify_document_outcomes([], [only], MIN_SCORE)

        assert outcomes.accepted == (only,)
        assert outcomes.not_scored == ()


class TestTheReasonIsNeverInvented:
    """What a failed document's record says it failed of."""

    def test_the_cause_is_the_error_the_scoring_recorded(self) -> None:
        """"Failed to connect to API" is a fact; "below threshold" was not."""
        assert scoring_failure_reason(failed("1")) == "Failed to connect to API"

    def test_a_cause_this_build_cannot_name_degrades_without_vanishing(self) -> None:
        """An unknown code still reads as a failure, never as a judgement."""
        reason = scoring_failure_reason(failed("1", code=-99))

        assert "threshold" not in reason.lower()
        assert reason

    def test_a_document_that_did_not_fail_has_no_failure_reason(self) -> None:
        """Only a negative score means the scoring failed."""
        assert scoring_failure_reason(rejected("1")) is None


pytest.importorskip("PySide6")

from bmlibrarian_lite.gui import report_tab as report_tab_module  # noqa: E402
from bmlibrarian_lite.gui.report_tab import ReportTab  # noqa: E402


@pytest.fixture
def qapp() -> Any:
    """The QApplication the tab tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


@pytest.fixture
def tab(
    qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
) -> ReportTab:
    """A report tab auto-saving into a directory this test owns."""
    from unittest.mock import MagicMock

    monkeypatch.setattr(report_tab_module, "REPORTS_DIR", tmp_path)
    return ReportTab(config=MagicMock(), storage=MagicMock())


def metadata(min_score: int = MIN_SCORE) -> ReportMetadata:
    """Report metadata stating the threshold the run used."""
    return ReportMetadata(research_question=QUESTION, min_score_threshold=min_score)


def saved_audit(tab: ReportTab, tmp_path: Any) -> dict[str, Any]:
    """The audit JSON the tab wrote beside its report.

    Args:
        tab: The tab that displayed a report.
        tmp_path: The directory it auto-saved into.

    Returns:
        The parsed audit trail.
    """
    audits = sorted(tmp_path.glob("*_audit.json"))
    assert audits, "The tab saved no audit trail"
    return json.loads(audits[-1].read_text(encoding="utf-8"))


def display(tab: ReportTab, all_scored: list[ScoredDocument], found: list[LiteDocument]) -> None:
    """Show a finished report built from the given scoring record.

    Args:
        tab: The tab to display in.
        all_scored: Every document that received a score.
        found: Every document the search found.
    """
    tab.display_report(
        report="## Findings\n\nAspirin reduced stroke incidence.",
        question=QUESTION,
        citations=[],
        documents_found=found,
        all_scored_documents=all_scored,
        report_metadata=metadata(),
    )


class TestTheSavedAuditTrail:
    """The file that outlives the session says what happened."""

    def test_a_failed_document_is_not_listed_as_rejected(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """The durable record is the one that was wrong (#302)."""
        found = [make_document("1"), make_document("2")]
        display(tab, [accepted("1"), failed("2")], found)

        audit = saved_audit(tab, tmp_path)

        assert [d["id"] for d in audit["rejected_documents"]] == []
        assert [d["id"] for d in audit["failed_documents"]] == ["doc-2"]

    def test_a_failed_document_records_the_cause_it_failed_of(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """A reader can act on "Failed to connect to API"."""
        display(tab, [failed("1")], [make_document("1")])

        entry = saved_audit(tab, tmp_path)["failed_documents"][0]

        assert entry["reason"] == "Failed to connect to API"
        assert entry["error_code"] == "API_CONNECTION_ERROR"

    def test_a_rejected_document_records_the_model_s_own_reason(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """"Score below minimum threshold" was nobody's words."""
        display(tab, [rejected("1")], [make_document("1")])

        entry = saved_audit(tab, tmp_path)["rejected_documents"][0]

        assert entry["reason"] == REJECTION
        assert entry["score"] == 1

    def test_a_document_the_quality_filter_removed_is_not_rejected(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """It was never read, so it was never judged."""
        found = [make_document("1"), make_document("2")]
        display(tab, [accepted("1")], found)

        audit = saved_audit(tab, tmp_path)

        assert audit["rejected_documents"] == []
        assert [d["id"] for d in audit["unscored_documents"]] == ["doc-2"]

    def test_the_summary_counts_reconcile_with_the_documents_found(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """Four categories, summing to what the search found."""
        found = [make_document(str(n)) for n in range(1, 5)]
        display(tab, [accepted("1"), rejected("2"), failed("3")], found)

        summary = saved_audit(tab, tmp_path)["workflow_summary"]

        assert summary["documents_scored_relevant"] == 1
        assert summary["documents_rejected"] == 1
        assert summary["documents_failed"] == 1
        assert summary["documents_not_scored"] == 1
        assert summary["documents_searched"] == 4
        assert summary["documents_scored"] == 2

    def test_the_record_states_the_threshold_its_split_was_made_with(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """A reader cannot check "below threshold" without knowing which."""
        display(tab, [rejected("1")], [make_document("1")])

        assert saved_audit(tab, tmp_path)["workflow_summary"][
            "min_score_threshold"
        ] == MIN_SCORE


class TestTheAuditTrailDialog:
    """What a person reading the dialog is told."""

    def test_the_dialog_counts_failures_apart_from_rejections(
        self, tab: ReportTab
    ) -> None:
        """The same split the file records, on the screen."""
        found = [make_document(str(n)) for n in range(1, 4)]
        display(tab, [accepted("1"), rejected("2"), failed("3")], found)

        text = tab._audit_trail_text()

        assert "- Documents rejected: 1" in text
        assert "- Documents that could not be scored: 1" in text

    def test_the_dialog_names_why_a_document_could_not_be_scored(
        self, tab: ReportTab
    ) -> None:
        """A count alone leaves the reader nothing to act on."""
        display(tab, [failed("1")], [make_document("1")])

        text = tab._audit_trail_text()

        assert "Failed to connect to API" in text

    def test_a_run_that_lost_nothing_draws_no_failure_section(
        self, tab: ReportTab
    ) -> None:
        """A section that is always there is a section nobody reads.

        The summary still carries its zero, because the four categories only
        reconcile against the documents found if all four are shown.
        """
        display(tab, [accepted("1")], [make_document("1")])

        text = tab._audit_trail_text()

        assert "## Documents That Could Not Be Scored" not in text
        assert "- Documents that could not be scored: 0" in text

    def test_a_loaded_audit_file_without_the_new_keys_still_renders(
        self, tab: ReportTab
    ) -> None:
        """Golden rule 1: a file written by an older build is input."""
        tab._loaded_audit_data = {
            "metadata": {"research_question": QUESTION},
            "workflow_summary": {"documents_searched": 2},
            "rejected_documents": [{"id": "doc-2", "title": "Aspirin trial 2"}],
        }

        text = tab._audit_trail_text()

        assert QUESTION in text
        assert "Aspirin trial 2" in text


class TestTheOutcomesType:
    """The type refuses to hold a contradiction (the #301 lesson)."""

    def test_a_document_cannot_be_both_accepted_and_failed(self) -> None:
        """Counting one document twice is how a total stops reconciling."""
        both = accepted("1")
        with pytest.raises(ValueError):
            DocumentOutcomes(
                accepted=(both,),
                rejected=(),
                failed=(both,),
                not_scored=(),
            )


class TestTheLivePathCarriesEveryScore:
    """The Report tab can only tell the outcomes apart if it is given them.

    ``step_complete("scoring", ...)`` carries only the accepted documents, so
    the tab that emits ``report_generated`` has to keep the whole scoring
    record itself, from the per-document signal the worker already emits.
    """

    def review_tab(self, monkeypatch: pytest.MonkeyPatch, tmp_path: Any) -> Any:
        """A Systematic Review tab whose worker never runs.

        Args:
            monkeypatch: To stand the worker down.
            tmp_path: A data directory this test owns.

        Returns:
            The tab.
        """
        from unittest.mock import MagicMock

        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui import systematic_review_tab as review_module
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        monkeypatch.setattr(review_module, "WorkflowWorker", MagicMock())
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        return SystematicReviewTab(config=config, storage=MagicMock())

    def test_the_report_signal_carries_the_failed_documents_too(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """Without them the Report tab cannot tell a failure from a rejection."""
        tab = self.review_tab(monkeypatch, tmp_path)
        emitted: list[Any] = []
        tab.report_generated.connect(lambda *args: emitted.append(args))

        could_not = failed("2")
        tab._on_document_scored(accepted("1"))
        tab._on_document_scored(rejected("3"))
        tab._on_document_scored(could_not)
        tab._on_step_complete("scoring", [accepted("1")])
        tab._on_finished("# Evidence Report", metadata())

        assert emitted, "The tab emitted no report"
        scored_argument = emitted[0][4]
        assert could_not in scored_argument
        assert len(scored_argument) == 3

    def test_a_new_run_starts_from_an_empty_scoring_record(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """A previous run's failures must not be recorded against this one."""
        tab = self.review_tab(monkeypatch, tmp_path)
        tab._on_document_scored(failed("1"))

        tab.question_input.setPlainText(QUESTION)
        tab._run_workflow()

        assert tab._all_scored_documents == []


class TestAFreshReportGetsAFreshRecord:
    """A loaded file must not stand in for the review just run."""

    def test_displaying_a_report_drops_an_audit_loaded_from_disk(
        self, tab: ReportTab
    ) -> None:
        """Otherwise the dialog answers about a different review entirely."""
        tab._loaded_audit_data = {
            "metadata": {"research_question": "An older question"},
            "workflow_summary": {"documents_searched": 99},
        }

        display(tab, [failed("1")], [make_document("1")])

        text = tab._audit_trail_text()
        assert "An older question" not in text
        assert QUESTION in text
