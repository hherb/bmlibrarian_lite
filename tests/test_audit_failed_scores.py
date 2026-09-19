# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The Audit Trail tab shows a document it could not score as one (#307).

Since #305 every scoring result reaches the Audit Trail tab, failures
included -- and a failure arrives carrying its negative error code where a
score would be. The literature card drew it as a red "-4/5": an error code
presented as a relevance score, the worst one on the scale, with nothing to
say the document was never judged. The Queries card counted it among the
documents scored.

#302 fixed this in the audit record; these tests follow it into the tab the
reader watches while the review runs.
"""

from typing import Any

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.audit_records import outcome_sort_key  # noqa: E402
from bmlibrarian_lite.constants import SCORE_COLOR_POOR  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    EvaluationErrorCode,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.gui.audit_literature_tab import AuditLiteratureTab  # noqa: E402
from bmlibrarian_lite.gui.audit_trail_tab import AuditTrailTab  # noqa: E402
from bmlibrarian_lite.gui.card_utils import (  # noqa: E402
    SCORING_FAILED_TEXT,
    format_query_stats,
    score_badge_color,
    score_badge_text,
    score_badge_tooltip,
)
from bmlibrarian_lite.gui.document_card import DocumentCard, ScoreBadge  # noqa: E402

UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR
QUERY = "(aspirin) AND (stroke)"


@pytest.fixture
def qapp() -> Any:
    """The QApplication the widget tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


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
    )


def scored(pmid: str, score: int) -> ScoredDocument:
    """A document the model read and scored."""
    return ScoredDocument(make_document(pmid), score, "Read and judged.")


def failed(pmid: str) -> ScoredDocument:
    """A document the model could not score."""
    return ScoredDocument(
        make_document(pmid),
        UNREACHABLE.value,
        f"Scoring failed: {UNREACHABLE.description}",
    )


class TestTheBadge:
    """A failure's badge names the failure, not a score."""

    def test_a_failure_is_not_a_fraction_of_five(self) -> None:
        """It read "-4/5"."""
        assert score_badge_text(UNREACHABLE.value) == SCORING_FAILED_TEXT
        assert score_badge_text(4) == "4/5"

    def test_a_failure_is_not_coloured_as_the_worst_score(self) -> None:
        """Red is the colour of a document judged irrelevant."""
        assert score_badge_color(UNREACHABLE.value) != SCORE_COLOR_POOR
        assert score_badge_color(1) == SCORE_COLOR_POOR

    def test_a_failure_says_why(self) -> None:
        """The reader can see what went wrong without the log."""
        tooltip = score_badge_tooltip(UNREACHABLE.value)

        assert tooltip is not None and UNREACHABLE.description in tooltip
        assert score_badge_tooltip(4) is None

    def test_the_widget_follows(self, qapp: Any) -> None:
        """Both ways a badge gets its score."""
        badge = ScoreBadge(score=UNREACHABLE.value)
        assert badge.score_label.text() == SCORING_FAILED_TEXT

        badge.set_score(3)
        assert badge.score_label.text() == "3/5"
        assert badge.toolTip() == ""

        badge.set_score(UNREACHABLE.value)
        assert UNREACHABLE.description in badge.toolTip()


class TestTheCard:
    """A card's rationale says the document was not judged."""

    def test_the_rationale_names_the_failure(self, qapp: Any) -> None:
        """"Score: Scoring failed: …" read as a judgement with a reason."""
        document = make_document("1")
        card = DocumentCard(document=document)

        card.set_score(UNREACHABLE.value, f"Scoring failed: {UNREACHABLE.description}")

        text = card._build_rationale_text()
        assert text.startswith(SCORING_FAILED_TEXT)
        assert UNREACHABLE.description in text
        assert not text.startswith("Score:")

    def test_a_failure_with_no_text_replaces_what_the_card_showed(
        self, qapp: Any
    ) -> None:
        """With no rationale passed, the card kept showing the earlier score's."""
        card = DocumentCard(document=make_document("1"))
        card.set_score(4, "On topic.")
        assert card._rationale_widget is not None

        card.set_score(UNREACHABLE.value, "")

        shown = card._rationale_widget.text()
        assert shown.startswith(SCORING_FAILED_TEXT)
        assert "On topic." not in shown


class TestTheOrder:
    """Judged documents first, then failures, then the never scored."""

    def test_the_sort_key_follows_the_audit_categories(self) -> None:
        """A failure's code sorted it below every judged document by accident."""
        keys = [
            outcome_sort_key(None),
            outcome_sort_key(UNREACHABLE.value),
            outcome_sort_key(1),
            outcome_sort_key(5),
        ]

        assert sorted(keys) == [keys[3], keys[2], keys[1], keys[0]]

    def test_the_tab_resorts_by_it(self, qapp: Any) -> None:
        """The order the reader sees after the workflow finishes."""
        tab = AuditLiteratureTab()
        documents = [make_document(p) for p in ("never", "failed", "low", "high")]
        tab.add_documents(documents)
        tab.update_score(failed("failed"))
        tab.update_score(scored("low", 2))
        tab.update_score(scored("high", 5))

        tab.resort_by_score()

        layout = tab.cards_layout
        order = [
            layout.itemAt(i).widget().doc_id
            for i in range(layout.count())
            if isinstance(layout.itemAt(i).widget(), DocumentCard)
        ]
        assert order == ["doc-high", "doc-low", "doc-failed", "doc-never"]

    def test_a_failure_is_not_counted_as_scored(self, qapp: Any) -> None:
        """The tab's own count agreed with the Queries card's."""
        tab = AuditLiteratureTab()
        tab.add_documents([make_document("1"), make_document("2")])
        tab.update_score(scored("1", 4))
        tab.update_score(failed("2"))

        assert (tab.scored_count, tab.failed_count) == (1, 1)


class TestTheQueryCard:
    """The Queries card counts failures apart from the documents scored."""

    def test_the_stats_line_names_failures_only_when_there_are_some(self) -> None:
        """A line that always says "0 failed" is a line nobody reads."""
        assert format_query_stats(10, 8, 3) == "Found: 10 | Scored: 8 | Citations: 3"
        assert format_query_stats(10, 8, 3, documents_failed=2) == (
            "Found: 10 | Scored: 8 | Could not score: 2 | Citations: 3"
        )

    def test_the_tab_counts_them_apart(self, qapp: Any) -> None:
        """Counted among the scored, a failure read as a judged document."""
        from unittest.mock import MagicMock

        tab = AuditTrailTab(MagicMock(), MagicMock())
        tab.on_query_generated(QUERY, "aspirin and stroke")
        tab.on_documents_found([make_document("1"), make_document("2")])
        tab.on_document_scored(scored("1", 4))
        tab.on_document_scored(failed("2"))
        tab.on_workflow_finished()

        card = tab.queries_tab._query_cards[QUERY]
        assert card.stats_label.text() == (
            "Found: 2 | Scored: 1 | Could not score: 1 | Citations: 0"
        )


class TestTheResearchQuestionsCount:
    """The Research Questions tab counts a failure apart from the scores."""

    def test_the_database_counts_failures_apart(self, tmp_path: Any) -> None:
        """Counted as scored, an outage read as a finished review.

        A document scored after an earlier failure is scored; an older
        build's failure, stored as a 1, is a failure; a 1 with no
        explanation is a score.
        """
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        storage = LiteStorage(config)
        checkpoint = storage.create_checkpoint(research_question="Q")
        rows = [
            scored("1", 4),
            failed("2"),
            ScoredDocument(make_document("3"), 1, "Scoring failed: Connection refused"),
            failed("4"),
            scored("4", 3),
            ScoredDocument(make_document("5"), 1, None),  # type: ignore[arg-type]
        ]
        for row in rows:
            storage.upsert_document(row.document)
            storage.save_scored_document(row, checkpoint.id)

        with storage._sqlite_connection() as conn:
            counts = storage._count_scored_documents_for_question(conn, "Q")

        assert counts == (3, 2)

    def test_the_column_names_the_failures(self) -> None:
        """Shown only when there are any."""
        from datetime import datetime

        from bmlibrarian_lite.data_models import ResearchQuestionSummary
        from bmlibrarian_lite.gui.research_questions_tab import scored_count_text

        question = ResearchQuestionSummary(
            question="Q", question_hash="h", pubmed_query="q", last_run_at=datetime.now()
        )
        question.scored_documents = 12

        assert scored_count_text(question) == "12"

        question.failed_documents = 3

        assert scored_count_text(question) == "12 (+3 failed)"


class TestAnOlderFailureIsAuditedAsOne:
    """Classification reads an older build's failure, whoever loaded it."""

    def test_a_stored_one_that_was_a_failure_is_failed_not_rejected(self) -> None:
        """Only the restore converted it; any other path audited it as rejected (#315)."""
        from bmlibrarian_lite.audit_records import classify_document_outcomes

        older = ScoredDocument(make_document("1"), 1, "Scoring failed: SECRET text")
        judged = scored("2", 1)

        outcomes = classify_document_outcomes(
            [older.document, judged.document], [older, judged], min_score=3
        )

        assert [sd.document.id for sd in outcomes.failed] == ["doc-1"]
        assert "SECRET" not in outcomes.failed[0].explanation
        assert [sd.document.id for sd in outcomes.rejected] == ["doc-2"]
