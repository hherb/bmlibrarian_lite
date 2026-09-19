# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The concordance script compares judgements, never failures (#306).

``scripts/concordance_analysis.py`` compares every model's scores with the
reference models' across every question. A failure counted there as a 1 made
an unreachable model a harsh judge; a pair of models with too few documents in
common to compare was shown as 0% agreement; and cutting each question to 50
characters let two questions overwrite each other's scores.
"""

import importlib.util
import re
import sys
from pathlib import Path
from types import ModuleType
from typing import Any

from bmlibrarian_lite.data_models import (
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)

SCRIPT_PATH = (
    Path(__file__).resolve().parent.parent / "scripts" / "concordance_analysis.py"
)
PREFIX = "Does aspirin prevent stroke in adults over sixty-five years of age"
FIRST_QUESTION = f"{PREFIX} with atrial fibrillation?"
SECOND_QUESTION = f"{PREFIX} without atrial fibrillation?"
#: A 0% agreement as any rendering writes it ("0.0%", "0.0000"), but not the
#: tail of "100.0%".
ZERO_AGREEMENT = re.compile(r"(?<![\d.])0\.0(?:%|000)")


def _load_script() -> ModuleType:
    """Load concordance_analysis.py as a module (scripts/ is not a package).

    Returns:
        The loaded module.
    """
    spec = importlib.util.spec_from_file_location("concordance_analysis", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["concordance_analysis"] = module
    spec.loader.exec_module(module)
    return module


concordance = _load_script()


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


def make_evaluator(name: str) -> Evaluator:
    """The evaluator for an Ollama model of this name."""
    return Evaluator.from_model_config(provider="ollama", model_name=name)


class FakeQuestion:
    """What ``get_unique_research_questions`` answers with."""

    def __init__(self, question: str) -> None:
        """Name the question.

        Args:
            question: The research question.
        """
        self.question = question


class FakeStorage:
    """The four storage reads the script makes, answered from a table."""

    def __init__(
        self,
        evaluators: list[Evaluator],
        rows: dict[tuple[str, str, str], ScoredDocument],
    ) -> None:
        """Hold the stored rows.

        Args:
            evaluators: Every evaluator with a score.
            rows: The latest row per (document id, evaluator id, question).
        """
        self._evaluators = evaluators
        self._rows = rows

    def get_unique_research_questions(self, limit: int) -> list[FakeQuestion]:
        """Every question with a row."""
        return [FakeQuestion(q) for q in sorted({key[2] for key in self._rows})]

    def get_evaluators(self) -> list[Evaluator]:
        """Every evaluator."""
        return self._evaluators

    def get_document_ids_for_question(self, question: str) -> set[str]:
        """The documents with a row for the question."""
        return {key[0] for key in self._rows if key[2] == question}

    def get_scored_document_for_question(
        self, document_id: str, evaluator_id: str, question: str
    ) -> ScoredDocument | None:
        """The row, if one is stored."""
        return self._rows.get((document_id, evaluator_id, question))


def row(
    evaluator: Evaluator,
    pmid: str,
    question: str,
    score: int,
    explanation: str = "Read and judged.",
) -> tuple[tuple[str, str, str], ScoredDocument]:
    """One stored row, keyed as the fake storage looks it up."""
    document = make_document(pmid)
    scored = ScoredDocument(
        document=document,
        score=score,
        explanation=explanation,
        evaluator_id=evaluator.id,
        evaluator=evaluator,
        latency_ms=100,
    )
    return (document.id, evaluator.id, question), scored


def collect(evaluators: list[Evaluator], *rows: Any) -> dict[str, Any]:
    """What the script collects from these rows."""
    return concordance.collect_all_scores(FakeStorage(evaluators, dict(rows)))


class TestFailuresAreNotScores:
    """A failure is counted apart and compared with nothing."""

    def test_a_failure_is_counted_and_not_compared(self) -> None:
        """Both the error-code form and the form older builds stored as a 1."""
        judge = make_evaluator("judge")

        data = collect(
            [judge],
            row(judge, "1", FIRST_QUESTION, 4),
            row(judge, "2", FIRST_QUESTION, EvaluationErrorCode.API_TIMEOUT.value),
            row(judge, "3", FIRST_QUESTION, 1, "Scoring failed: Connection refused"),
        )

        collected = data[judge.display_name]
        assert collected.scores == [4]
        assert collected.failed_documents == 2

    def test_a_question_is_not_cut_short(self) -> None:
        """Two questions sharing their first 50 characters kept one score."""
        judge = make_evaluator("judge")

        data = collect(
            [judge],
            row(judge, "1", FIRST_QUESTION, 5),
            row(judge, "1", SECOND_QUESTION, 2),
        )

        assert sorted(data[judge.display_name].scores) == [2, 5]

    def test_no_latency_recorded_is_not_zero(self) -> None:
        """At 0.0 ms, a model with no timing ranked as the fastest."""
        judge = make_evaluator("judge")
        key, scored = row(judge, "1", FIRST_QUESTION, 4)
        scored.latency_ms = None

        data = collect([judge], (key, scored))

        assert data[judge.display_name].avg_latency_ms is None


class TestAPairWithNothingInCommonIsNotADisagreement:
    """Too few shared documents is "n/a", never 0%."""

    def report(self) -> Any:
        """Two models that judged different documents."""
        first, second = make_evaluator("first"), make_evaluator("second")
        data = collect(
            [first, second],
            row(first, "1", FIRST_QUESTION, 4),
            row(first, "2", FIRST_QUESTION, 5),
            row(second, "3", FIRST_QUESTION, 4),
            row(second, "4", FIRST_QUESTION, 5),
        )
        return concordance.build_concordance_report(data)

    def test_the_matrix_holds_no_figure(self) -> None:
        """The pair is recorded as not comparable, not left to default to 0."""
        report = self.report()
        first, second = report.evaluator_names

        assert report.score_agreement_matrix[(first, second)] is None
        assert report.inclusion_agreement_matrix[(second, first)] is None

    def test_every_rendering_says_n_a(self, tmp_path: Path) -> None:
        """The text table, both CSVs and the markdown report."""
        report = self.report()

        table = concordance.format_matrix_table(
            report.score_agreement_matrix, report.evaluator_names, "Scores"
        )
        concordance.export_to_csv(report, tmp_path)
        concordance.export_to_markdown(report, tmp_path, inclusion_threshold=3)

        for text in (
            table,
            (tmp_path / "score_agreement_matrix.csv").read_text(),
            (tmp_path / "inclusion_agreement_matrix.csv").read_text(),
            (tmp_path / "concordance_report.md").read_text(),
        ):
            assert concordance.NOT_AVAILABLE in text
            assert ZERO_AGREEMENT.search(text) is None

    def test_the_markdown_report_counts_failures(self, tmp_path: Path) -> None:
        """Left out of the agreement, a model's failures are still shown."""
        judge, other = make_evaluator("judge"), make_evaluator("other")
        data = collect(
            [judge, other],
            row(judge, "1", FIRST_QUESTION, 4),
            row(judge, "2", FIRST_QUESTION, EvaluationErrorCode.API_TIMEOUT.value),
            row(other, "1", FIRST_QUESTION, 4),
        )
        report = concordance.build_concordance_report(data)

        concordance.export_to_markdown(report, tmp_path, inclusion_threshold=3)

        markdown = (tmp_path / "concordance_report.md").read_text()
        assert f"| {judge.display_name} | 1 | 1 |" in markdown
