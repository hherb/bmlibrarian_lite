# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The Benchmark tab shows a failed scoring as one (#306).

Once a failure stopped being a score of 1, a model whose provider was down
for the whole run had no mean, no cost per evaluation and no agreement with
anyone -- and the tab formatted, divided and coloured those figures as
numbers, so it could not open at all. These tests build the tab and the
document dialog over such a result.
"""

from typing import Any

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.benchmarking.display import (  # noqa: E402
    FAILED_SCORE_TEXT,
    NOT_AVAILABLE,
)
from bmlibrarian_lite.benchmarking.models import BenchmarkResult  # noqa: E402
from bmlibrarian_lite.benchmarking.statistics import (  # noqa: E402
    compute_document_comparison,
    compute_evaluator_stats,
)
from bmlibrarian_lite.data_models import (  # noqa: E402
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.gui.benchmark_results_dialog import (  # noqa: E402
    BenchmarkResultsTab,
    DocumentExplanationsDialog,
)

ANSWERED = Evaluator.from_model_config(provider="ollama", model_name="judge")
DOWN = Evaluator.from_model_config(provider="ollama", model_name="second-judge")
UNREACHABLE = EvaluationErrorCode.API_CONNECTION_ERROR


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
        source=DocumentSource.PUBMED,
    )


def outage_result() -> BenchmarkResult:
    """Two documents, one model answering both and one reaching neither."""
    documents = [make_document("1"), make_document("2")]
    answered = [
        ScoredDocument(d, 4, "On topic.", evaluator_id=ANSWERED.id, evaluator=ANSWERED)
        for d in documents
    ]
    down = [
        ScoredDocument(
            d,
            UNREACHABLE.value,
            f"Scoring failed: {UNREACHABLE.description}",
            evaluator_id=DOWN.id,
            evaluator=DOWN,
        )
        for d in documents
    ]
    return BenchmarkResult(
        run_id="run",
        question="Does aspirin prevent stroke?",
        task_type="document_scoring",
        evaluator_stats=[
            compute_evaluator_stats(ANSWERED, answered),
            compute_evaluator_stats(DOWN, down),
        ],
        document_comparisons=[
            compute_document_comparison(
                d, {ANSWERED.display_name: a, DOWN.display_name: f}
            )
            for d, a, f in zip(documents, answered, down, strict=True)
        ],
        agreement_matrix={(ANSWERED.display_name, DOWN.display_name): None},
        inclusion_agreement_matrix={(ANSWERED.display_name, DOWN.display_name): None},
    )


def tables_headed(widget: Any, *labels: str) -> list[Any]:
    """The tables whose column headers begin with these labels.

    ``findChildren`` does not return them in the order they were built.
    """
    from PySide6.QtWidgets import QTableWidget

    def headers(table: Any) -> list[str]:
        return [
            table.horizontalHeaderItem(col).text()
            for col in range(table.columnCount())
            if table.horizontalHeaderItem(col) is not None
        ]

    return [
        table
        for table in widget.findChildren(QTableWidget)
        if headers(table)[: len(labels)] == list(labels)
    ]


def cell_texts(table: Any, row: int) -> list[str]:
    """One table row's text."""
    return [
        table.item(row, col).text() if table.item(row, col) else ""
        for col in range(table.columnCount())
    ]


class TestTheTabOpensOverAnOutage:
    """A model that scored nothing is shown, not computed with."""

    def test_the_comparison_row_states_what_is_missing(self, qapp: Any) -> None:
        """Formatting its mean as a number crashed the tab."""
        tab = BenchmarkResultsTab(result=outage_result())

        [comparison] = tables_headed(tab, "Model", "Mean Score")
        row = cell_texts(comparison, 1)

        assert row[1:5] == [NOT_AVAILABLE, NOT_AVAILABLE, "0", "2"]

    def test_a_pair_with_nothing_in_common_has_no_agreement(self, qapp: Any) -> None:
        """Shown as 0%, it read as the widest possible disagreement."""
        tab = BenchmarkResultsTab(result=outage_result())

        matrices = tables_headed(tab, ANSWERED.display_name, DOWN.display_name)

        assert len(matrices) == 2  # score and inclusion agreement
        for matrix in matrices:
            assert matrix.item(0, 1).text() == NOT_AVAILABLE

    def test_a_failed_cell_says_so_and_why(self, qapp: Any) -> None:
        """Shown as "-", the model looked as though it was never asked."""
        tab = BenchmarkResultsTab(result=outage_result())

        details = tab.details_table
        cell = details.item(0, 3)

        assert cell.text() == FAILED_SCORE_TEXT
        assert cell.toolTip() == UNREACHABLE.description

    def test_an_older_result_says_it_cannot_tell(self, qapp: Any) -> None:
        """Its 1s may be outages, and the tab says so."""
        from PySide6.QtWidgets import QLabel

        result = outage_result()
        for stats in result.evaluator_stats:
            stats.failed_evaluations = None
        tab = BenchmarkResultsTab(result=result)

        assert any("score of 1" in label.text() for label in tab.findChildren(QLabel))


class TestTheDocumentDialog:
    """One document's review names the model that could not score it."""

    def test_the_failed_model_is_not_a_gold_standard(self, qapp: Any) -> None:
        """It made no assessment to choose."""
        result = outage_result()
        dialog = DocumentExplanationsDialog(
            result.document_comparisons[0], result.evaluator_stats
        )

        button = dialog._gold_buttons[DOWN.display_name]

        assert not button.isEnabled()
        assert FAILED_SCORE_TEXT in button.text()
