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

import copy
import json
from datetime import datetime
from typing import Any

import pytest

from bmlibrarian_lite.audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    LEGACY_REJECTION_REASON,
    UNKNOWN_FAILURE_CODE,
    DocumentOutcomes,
    classify_document_outcomes,
    outcome_entries,
    outcome_summary,
    predates_outcome_split,
    recorded_min_score,
    scoring_failure_reason,
    without_invented_reason,
)
from bmlibrarian_lite.data_models import (
    Citation,
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
    ReportMetadata,
    ReviewCheckpoint,
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

    def test_a_document_found_twice_is_counted_once(self) -> None:
        """A search that returns one record twice is not two documents.

        Refusing the duplicate cost the whole audit file: the report was
        saved without it, and only the log said so.
        """
        found = [make_document("1"), make_document("1")]

        outcomes = classify_document_outcomes(found, [], MIN_SCORE)

        assert [d.id for d in outcomes.not_scored] == ["doc-1"]

    def test_the_first_score_a_document_received_is_the_one_kept(self) -> None:
        """One document, one outcome -- and which one is not left to chance."""
        first = failed("1")

        outcomes = classify_document_outcomes(
            [make_document("1")], [first, accepted("1")], MIN_SCORE
        )

        assert outcomes.failed == (first,)
        assert outcomes.accepted == ()


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


class TestTheRecord:
    """The part of the audit record both the file and the dialog are built from."""

    def test_the_summary_states_the_threshold_the_split_was_made_at(self) -> None:
        """The threshold comes from the outcome, so it cannot disagree with it."""
        outcomes = classify_document_outcomes([], [rejected("1")], 4)

        assert outcome_summary(outcomes)["min_score_threshold"] == 4

    def test_a_threshold_nobody_recorded_is_not_stated(self) -> None:
        """A report restored from an older run never recorded its threshold."""
        outcomes = classify_document_outcomes([], [rejected("1")], MIN_SCORE)

        summary = outcome_summary(outcomes, threshold_recorded=False)

        assert summary["min_score_threshold"] is None

    def test_a_failed_entry_keeps_the_code_it_failed_with(self) -> None:
        """A later build that can name the code needs the code to name."""
        outcomes = classify_document_outcomes(
            [make_document("1")], [failed("1", code=-99)], MIN_SCORE
        )

        [entry] = outcome_entries(outcomes)["failed_documents"]

        assert entry["score"] == -99
        assert entry["error_code"] == UNKNOWN_FAILURE_CODE

    def test_an_accepted_entry_is_not_marked_irrelevant(self) -> None:
        """``is_relevant`` assumed a threshold of 3; a run at 2 accepts a 2."""
        at_two = scored(make_document("1"), 2, "Tangential but on topic.")
        outcomes = classify_document_outcomes([make_document("1")], [at_two], 2)

        [entry] = outcome_entries(outcomes)["scored_documents"]

        assert entry["is_relevant"] is True


class TestAnOlderRecord:
    """A record an older build wrote said "below threshold" of everything."""

    def test_a_record_without_the_failure_list_predates_the_split(self) -> None:
        """The key's absence marks it: every build since #302 writes the key."""
        assert predates_outcome_split({"rejected_documents": []})
        assert not predates_outcome_split({"failed_documents": []})

    def test_the_reason_nobody_gave_is_dropped(self) -> None:
        """It was written beside failures and filtered documents alike."""
        entry = {"title": "Aspirin trial 2", "reason": LEGACY_REJECTION_REASON}

        assert without_invented_reason(entry) == {"title": "Aspirin trial 2"}

    def test_a_reason_somebody_gave_is_kept(self) -> None:
        """Only the stock sentence is dropped, never the model's own words."""
        entry = {"title": "Aspirin trial 2", "reason": REJECTION}

        assert without_invented_reason(entry) == entry


class TestTheThresholdACheckpointRecorded:
    """A checkpoint's metadata is stored JSON, so it is input (golden rule 1)."""

    @pytest.mark.parametrize(
        ("metadata", "expected"),
        [
            ({CHECKPOINT_MIN_SCORE_KEY: 4}, 4),
            ({}, None),
            ({CHECKPOINT_MIN_SCORE_KEY: "4"}, None),
            ({CHECKPOINT_MIN_SCORE_KEY: 9}, None),
            ({CHECKPOINT_MIN_SCORE_KEY: True}, None),
            (None, None),
        ],
    )
    def test_only_a_usable_threshold_is_read(
        self, metadata: Any, expected: int | None
    ) -> None:
        """Anything else is "not recorded", never a guess."""
        assert recorded_min_score(metadata) == expected


class TestTheScoresOfOneRun:
    """A restored report is audited from the run that wrote it."""

    def test_a_restore_reads_the_scores_of_its_own_run(self, tmp_path: Any) -> None:
        """Every run of the question was merged, and the highest score won.

        So a document that failed in the run the report describes, but was
        accepted in an earlier one, was recorded as accepted -- #302 again.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)
        storage.add_document(make_document("1"))
        earlier = storage.create_checkpoint(research_question=QUESTION)
        this_run = storage.create_checkpoint(research_question=QUESTION)
        storage.save_scored_document(accepted("1"), earlier.id)
        storage.save_scored_document(failed("1"), this_run.id)

        [only] = storage.get_scored_documents_for_question(
            QUESTION, checkpoint_id=this_run.id
        )

        assert only.score == failed("1").score


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
        with pytest.raises(ValueError, match="one outcome"):
            DocumentOutcomes(
                accepted=(both,),
                rejected=(),
                failed=(both,),
                not_scored=(),
                min_score=MIN_SCORE,
            )

    @pytest.mark.parametrize(
        ("category", "document"),
        [
            ("rejected", failed("1")),
            ("failed", rejected("1")),
            ("rejected", accepted("1")),
            ("accepted", rejected("1")),
        ],
    )
    def test_a_document_cannot_sit_in_a_category_its_score_contradicts(
        self, category: str, document: ScoredDocument
    ) -> None:
        """A failure filed as a judgement is #302 itself."""
        categories: dict[str, Any] = {"accepted": (), "rejected": (), "failed": ()}
        categories[category] = (document,)

        with pytest.raises(ValueError):
            DocumentOutcomes(not_scored=(), min_score=MIN_SCORE, **categories)


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

    def test_every_score_still_reaches_the_audit_trail_tab(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """The slot now between the worker and the tab must pass each one on.

        The main window connects the tab's ``document_scored`` to the Audit
        Trail tab, which would otherwise receive no score at all.
        """
        tab = self.review_tab(monkeypatch, tmp_path)
        heard: list[ScoredDocument] = []
        tab.document_scored.connect(heard.append)
        could_not = failed("2")

        tab._on_document_scored(accepted("1"))
        tab._on_document_scored(could_not)

        assert len(heard) == 2
        assert could_not in heard

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


class TestTheThresholdTheRunUsed:
    """The split is made, and stated, at the threshold the run accepted at."""

    def test_a_run_at_a_higher_threshold_rejects_what_the_default_accepts(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """Audited at the default, a run at 4 listed its 3s as accepted."""
        at_three = scored(make_document("1"), 3, "Tangential.")

        tab.display_report(
            report="## Findings\n\nAspirin reduced stroke incidence.",
            question=QUESTION,
            citations=[],
            documents_found=[make_document("1")],
            all_scored_documents=[at_three],
            report_metadata=metadata(min_score=4),
        )
        audit = saved_audit(tab, tmp_path)

        assert [d["id"] for d in audit["rejected_documents"]] == ["doc-1"]
        assert audit["workflow_summary"]["min_score_threshold"] == 4

    def test_the_dialog_states_the_threshold(self, tab: ReportTab) -> None:
        """"Below threshold" means nothing to a reader who is not told which."""
        display(tab, [rejected("1")], [make_document("1")])

        assert f"- Relevance threshold: {MIN_SCORE}/5" in tab._audit_trail_text()


def restore(
    tab: ReportTab,
    threshold: int | None,
    all_scored: list[ScoredDocument],
) -> None:
    """Show a report as restoring it from the Research Questions tab does.

    Args:
        tab: The tab to display in.
        threshold: What the checkpoint recorded, if anything.
        all_scored: The scores of the checkpoint's own run.
    """
    tab.display_report(
        report="## Findings\n\nAspirin reduced stroke incidence.",
        question=QUESTION,
        citations=[],
        documents_found=[make_document("1")],
        all_scored_documents=all_scored,
        min_score_threshold=threshold,
        auto_save=False,
    )


class TestARestoredReport:
    """A report rebuilt from the database is shown, not written again."""

    def test_a_restored_report_writes_no_new_record(
        self, tab: ReportTab, tmp_path: Any
    ) -> None:
        """The run saved its own; a rebuild loses what the checkpoint never kept."""
        restore(tab, 4, [rejected("1")])

        assert list(tmp_path.iterdir()) == []

    def test_it_splits_at_the_threshold_its_run_recorded(self, tab: ReportTab) -> None:
        """Not at the default, which the run may never have used."""
        restore(tab, 4, [scored(make_document("1"), 3, "Tangential.")])

        text = tab._audit_trail_text()

        assert "- Documents rejected: 1" in text
        assert "- Relevance threshold: 4/5" in text

    def test_a_threshold_nobody_recorded_is_said_to_be_unrecorded(
        self, tab: ReportTab
    ) -> None:
        """An older run's split is shown at the default, and says so."""
        restore(tab, None, [rejected("1")])

        text = tab._audit_trail_text()

        assert "- Relevance threshold: not recorded" in text


#: An audit file exactly as the build before #302 wrote one -- here from a
#: restored review, which listed every score as relevant, failures included.
LEGACY_AUDIT: dict[str, Any] = {
    "metadata": {
        "timestamp": "2026-09-01T10:00:00",
        "research_question": QUESTION,
        "report_file": "/reports/20260901_100000_aspirin_report.md",
        "version": 1,
    },
    "methodology": None,
    "workflow_summary": {
        "documents_searched": 4,
        "documents_scored_relevant": 2,
        "documents_rejected": 2,
        "citations_extracted": 0,
        "quality_filter_applied": False,
        "quality_assessments_count": 0,
    },
    "quality_filter_settings": {},
    "documents_found": [],
    "scored_documents": [
        {
            "id": "doc-1",
            "title": "Aspirin trial 1",
            "score": 4,
            "explanation": "On topic.",
            "is_relevant": True,
        },
        {
            "id": "doc-4",
            "title": "Aspirin trial 4",
            "score": EvaluationErrorCode.API_CONNECTION_ERROR.value,
            "explanation": "Scoring failed",
            "is_relevant": False,
        },
    ],
    "rejected_documents": [
        {"id": "doc-2", "title": "Aspirin trial 2", "reason": LEGACY_REJECTION_REASON},
        {"id": "doc-3", "title": "Aspirin trial 3", "reason": LEGACY_REJECTION_REASON},
    ],
    "citations": [],
}


def load_saved_report(
    tab: ReportTab,
    tmp_path: Any,
    monkeypatch: pytest.MonkeyPatch,
    audit: dict[str, Any] | None,
) -> None:
    """Load a report from disk through the tab's own Load button.

    Args:
        tab: The tab to load into.
        tmp_path: Where the files are written.
        monkeypatch: To answer the file dialog.
        audit: The audit file beside the report, or None for none.
    """
    report_path = tmp_path / "20260901_100000_aspirin_report.md"
    report_path.write_text("## Findings\n\nAspirin helps.", encoding="utf-8")
    if audit is not None:
        audit_path = tmp_path / "20260901_100000_aspirin_audit.json"
        audit_path.write_text(json.dumps(audit), encoding="utf-8")
    monkeypatch.setattr(
        report_tab_module.QFileDialog,
        "getOpenFileName",
        lambda *_args, **_kwargs: (str(report_path), ""),
    )
    tab._load_report()


class TestAnAuditFileAnOlderBuildWrote:
    """A file an older build wrote: input (golden rule 1), and wrong (#302).

    Its rejected list is the one #302 found listing failures and filtered
    documents as judged, each with a reason nobody gave.
    """

    def text(self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch) -> str:
        """Load the legacy file from disk and render its audit trail.

        Args:
            tab: The tab to load into.
            tmp_path: Where the files are written.
            monkeypatch: To answer the file dialog.

        Returns:
            The dialog's markdown.
        """
        load_saved_report(tab, tmp_path, monkeypatch, copy.deepcopy(LEGACY_AUDIT))
        return tab._audit_trail_text()

    def test_it_renders(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The question and every document it lists still reach the reader."""
        text = self.text(tab, tmp_path, monkeypatch)

        assert QUESTION in text
        assert "Aspirin trial 2" in text
        assert "Aspirin trial 3" in text

    def test_it_says_its_rejections_may_not_be_judgements(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The file cannot be corrected, but the reader can be told."""
        assert "predates" in self.text(tab, tmp_path, monkeypatch)

    def test_the_reason_nobody_gave_is_not_shown(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The older dialog showed titles only; the new one must not add it."""
        assert LEGACY_REJECTION_REASON not in self.text(tab, tmp_path, monkeypatch)

    def test_it_claims_no_count_it_never_kept(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A zero here would say nothing failed, in a record that could not tell."""
        text = self.text(tab, tmp_path, monkeypatch)

        assert "- Documents that could not be scored:" not in text
        assert "- Documents scored:" not in text

    def test_a_failure_it_listed_as_relevant_is_not_given_a_score(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """"-4/5" is an error code shown as a relevance score."""
        text = self.text(tab, tmp_path, monkeypatch)

        assert f"{EvaluationErrorCode.API_CONNECTION_ERROR.value}/5" not in text
        assert "Failed to connect to API" in text

    def test_a_report_loaded_without_its_audit_file_drops_the_last_one(
        self, tab: ReportTab, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Otherwise the dialog answers about the previous report entirely."""
        tab._loaded_audit_data = copy.deepcopy(LEGACY_AUDIT)
        tab.audit_btn.setEnabled(True)

        load_saved_report(tab, tmp_path, monkeypatch, audit=None)

        assert tab._loaded_audit_data is None
        assert not tab.audit_btn.isEnabled()


class TestTheDialogShowsEveryOutcome:
    """The dialog's remaining categories and the record it is drawn from."""

    def test_it_lists_the_documents_scoring_never_reached(self, tab: ReportTab) -> None:
        """Counted in the summary, and named in their own section."""
        display(tab, [accepted("1")], [make_document("1"), make_document("2")])

        text = tab._audit_trail_text()

        assert "- Documents not scored: 1" in text
        assert "## Documents Not Scored" in text
        assert "Aspirin trial 2" in text

    def test_a_run_whose_every_score_failed_still_offers_its_audit_trail(
        self, tab: ReportTab
    ) -> None:
        """The run that most needs explaining is the one with no acceptance."""
        display(tab, [failed("1")], [make_document("1")])

        assert tab.audit_btn.isEnabled()

    def test_it_shows_a_citation_s_whole_passage(self, tab: ReportTab) -> None:
        """Golden rule 13; the saved file never cut it, so neither does this."""
        passage = "Aspirin reduced stroke incidence in the treated arm. " * 6
        tab.display_report(
            report="## Findings\n\nAspirin reduced stroke incidence.",
            question=QUESTION,
            citations=[
                Citation(document=make_document("1"), passage=passage, relevance_score=4)
            ],
            documents_found=[make_document("1")],
            all_scored_documents=[accepted("1")],
            report_metadata=metadata(),
        )

        assert passage.strip() in tab._audit_trail_text()


class TestRestoringAQuestion:
    """What the main window hands the Report tab when a question is reopened."""

    def restored(self, checkpoint_metadata: dict[str, Any]) -> Any:
        """Restore a question whose latest checkpoint carries the metadata.

        Args:
            checkpoint_metadata: What the checkpoint recorded.

        Returns:
            The stand-in window, holding the calls the restore made.
        """
        from unittest.mock import MagicMock

        from bmlibrarian_lite.gui.app import LiteMainWindow

        window = MagicMock()
        window.storage.get_checkpoint_for_question.return_value = ReviewCheckpoint(
            id="checkpoint-2",
            research_question=QUESTION,
            created_at=datetime.now(),
            updated_at=datetime.now(),
            step="complete",
            report="## Findings",
            metadata=checkpoint_metadata,
        )
        window.storage.get_document_ids_for_question.return_value = []
        window.storage.get_scored_documents_for_question.return_value = []
        window.storage.get_citations_for_question.return_value = []
        window.storage.get_quality_assessments_for_question.return_value = {}

        LiteMainWindow._on_question_selected(window, QUESTION, "aspirin")
        return window

    def test_it_reads_the_scores_of_the_run_it_shows(self) -> None:
        """Not every run of the question, merged."""
        window = self.restored({CHECKPOINT_MIN_SCORE_KEY: 4})

        window.storage.get_scored_documents_for_question.assert_called_once_with(
            QUESTION, checkpoint_id="checkpoint-2"
        )

    def test_it_states_the_threshold_the_run_recorded(self) -> None:
        """The checkpoint's threshold, not the default."""
        window = self.restored({CHECKPOINT_MIN_SCORE_KEY: 4})

        kwargs = window.report_tab.display_report.call_args.kwargs
        assert kwargs["min_score_threshold"] == 4

    def test_it_writes_no_new_record(self) -> None:
        """The run's own files are the record; a rebuild is not."""
        window = self.restored({})

        kwargs = window.report_tab.display_report.call_args.kwargs
        assert kwargs["auto_save"] is False
        assert kwargs["min_score_threshold"] is None
