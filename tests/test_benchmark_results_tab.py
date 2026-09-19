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
from unittest.mock import MagicMock

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.benchmarking.display import (  # noqa: E402
    FAILED_SCORE_TEXT,
    NOT_AVAILABLE,
)
from bmlibrarian_lite.benchmarking.models import BenchmarkResult  # noqa: E402
from bmlibrarian_lite.benchmarking.statistics import (  # noqa: E402
    compute_agreement_matrix,
    compute_document_comparison,
    compute_evaluator_stats,
    compute_inclusion_agreement_matrix,
)
from bmlibrarian_lite.data_models import (  # noqa: E402
    DocumentSource,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)
from bmlibrarian_lite.gui.benchmark_results_dialog import (  # noqa: E402
    UNREADABLE_RESULT_TEXT,
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
    by_model: dict[str, list[int | None]] = {
        ANSWERED.display_name: [4, 4],
        DOWN.display_name: [None, None],
    }
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
        agreement_matrix=compute_agreement_matrix(by_model),
        inclusion_agreement_matrix=compute_inclusion_agreement_matrix(by_model),
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

    def test_a_model_that_judged_nothing_has_no_self_agreement(self, qapp: Any) -> None:
        """The diagonal was a green 100% for it too."""
        tab = BenchmarkResultsTab(result=outage_result())

        for matrix in tables_headed(tab, ANSWERED.display_name, DOWN.display_name):
            assert matrix.item(0, 0).text() == "100%"
            assert matrix.item(1, 1).text() == NOT_AVAILABLE

    def test_no_comparable_document_has_no_disagreement_rate(self, qapp: Any) -> None:
        """"0.0%" sat under a matrix that said n/a."""
        from PySide6.QtWidgets import QLabel

        tab = BenchmarkResultsTab(result=outage_result())

        rates = [
            label.text() for label in tab.findChildren(QLabel)
            if "inclusion disagreement:" in label.text()
        ]
        assert rates and all(f"</b> {NOT_AVAILABLE}" in text for text in rates)

    def test_a_document_one_model_judged_has_no_spread(self, qapp: Any) -> None:
        """Its "Max Diff" read 0 -- full agreement with nobody."""
        tab = BenchmarkResultsTab(result=outage_result())

        assert tab.details_table.item(0, 1).text() == NOT_AVAILABLE

    def test_a_model_that_judged_nothing_has_no_latency(self, qapp: Any) -> None:
        """"0ms" ranked it the fastest."""
        tab = BenchmarkResultsTab(result=outage_result())

        [comparison] = tables_headed(tab, "Model", "Mean Score")

        assert cell_texts(comparison, 1)[5] == NOT_AVAILABLE

    def test_a_failed_export_is_reported(
        self, qapp: Any, tmp_path: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Only logged, it left the user believing the file was saved."""
        from bmlibrarian_lite.gui import benchmark_results_dialog as module

        unwritable = tmp_path / "missing" / "results.csv"
        monkeypatch.setattr(
            module.QFileDialog,
            "getSaveFileName",
            lambda *_args, **_kwargs: (str(unwritable), ""),
        )
        warning = MagicMock()
        monkeypatch.setattr(module.QMessageBox, "warning", warning)
        tab = BenchmarkResultsTab(result=outage_result())

        tab._export_csv()
        tab._export_json()

        assert warning.call_count == 2

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


class TestTheConfirmDialog:
    """The cost estimate counts what can be reused, not that a run happened."""

    def test_a_run_that_failed_everywhere_is_not_promised_as_free(
        self, qapp: Any, tmp_path: Any
    ) -> None:
        """"$0.00 (reusing existing)" -- then every failure was scored, and billed."""
        from bmlibrarian_lite.benchmarking.runner import BenchmarkRunner
        from bmlibrarian_lite.config import BenchmarkModelConfig, LiteConfig
        from bmlibrarian_lite.gui.benchmark_dialog import BenchmarkConfirmDialog
        from bmlibrarian_lite.storage import LiteStorage

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        config.benchmark.models = [
            BenchmarkModelConfig(provider="anthropic", model="claude-sonnet-5")
        ]
        storage = LiteStorage(config)
        documents = [make_document("1"), make_document("2")]
        down = MagicMock()
        down.chat.side_effect = ConnectionError("refused")
        runner = BenchmarkRunner(config=config, storage=storage)
        runner._llm_client = down
        runner.run_quick_benchmark(
            question="Q", documents=documents, models=["anthropic:claude-sonnet-5"]
        )

        dialog = BenchmarkConfirmDialog(
            config=config, documents=documents, question="Q", storage=storage
        )

        assert "reusing" not in dialog.cost_label.text()


    def test_a_model_that_judged_some_documents_is_priced_for_the_rest(
        self, qapp: Any, tmp_path: Any
    ) -> None:
        """Only the documents it already judged are free; the rest are billed."""
        from bmlibrarian_lite.benchmarking.runner import BenchmarkRunner
        from bmlibrarian_lite.config import BenchmarkModelConfig, LiteConfig
        from bmlibrarian_lite.constants import calculate_cost
        from bmlibrarian_lite.gui.benchmark_dialog import BenchmarkConfirmDialog
        from bmlibrarian_lite.llm import LLMResponse
        from bmlibrarian_lite.storage import LiteStorage

        model = "anthropic:claude-sonnet-5"
        config = LiteConfig()
        config.storage.data_dir = tmp_path
        config.benchmark.models = [
            BenchmarkModelConfig(provider="anthropic", model="claude-sonnet-5")
        ]
        storage = LiteStorage(config)
        documents = [make_document(str(i)) for i in range(4)]
        judge = MagicMock()
        judge.chat.return_value = LLMResponse(
            content='{"score": 4, "explanation": "On topic."}',
            input_tokens=100,
            output_tokens=20,
        )
        runner = BenchmarkRunner(config=config, storage=storage)
        runner._llm_client = judge
        runner.run_quick_benchmark(question="Q", documents=documents[:2], models=[model])

        dialog = BenchmarkConfirmDialog(
            config=config, documents=documents, question="Q", storage=storage
        )

        two_documents = calculate_cost(model, 500 * 2, 100 * 2)
        assert f"~${two_documents:.4f}" in dialog.cost_label.text()


class TestTheCompletionMessage:
    """The Systematic Review tab's status line after a benchmark."""

    def test_it_names_the_failures(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch, tmp_path: Any
    ) -> None:
        """"Benchmark complete" alone hid a model that answered nothing."""
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui.systematic_review_tab import SystematicReviewTab

        config = LiteConfig()
        config.storage.data_dir = tmp_path
        tab = SystematicReviewTab(config=config, storage=MagicMock())
        tab._benchmark_progress_dialog = None

        tab._on_benchmark_finished(outage_result())

        assert "2 of 4 scorings failed" in tab.progress_label.text()


    def test_the_research_questions_tab_names_them_too(self, qapp: Any) -> None:
        """Only the Systematic Review tab's message was checked."""
        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui.research_questions_tab import ResearchQuestionsTab

        tab = ResearchQuestionsTab(config=LiteConfig(), storage=MagicMock())

        tab._on_benchmark_finished(outage_result())

        assert "2 of 4 scorings failed" in tab.progress_label.text()


class TestSelectingAQuestion:
    """A benchmark that cannot be loaded is not shown as another question's."""

    def test_a_failed_load_clears_the_previous_result(
        self, qapp: Any, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The last question's benchmark stayed on screen, only logged."""
        from bmlibrarian_lite.gui import app as app_module
        from bmlibrarian_lite.gui.app import LiteMainWindow

        broken = MagicMock()
        broken.return_value.get_latest_benchmark_result_for_question.side_effect = (
            OSError("disk I/O error")
        )
        monkeypatch.setattr(app_module, "BenchmarkRunner", broken)
        window = MagicMock()

        LiteMainWindow._load_benchmark_results_for_question(window, "Q")

        window.benchmark_tab.show_unreadable.assert_called_once_with()
        window.benchmark_tab.update_result.assert_not_called()

    def test_the_tab_says_it_could_not_load_rather_than_that_there_is_none(
        self, qapp: Any
    ) -> None:
        """The empty state's "Run a benchmark" is the wrong advice here."""
        tab = BenchmarkResultsTab()
        tab.update_result(outage_result())

        tab.show_unreadable()

        assert tab.result is None
        assert tab._content_widget.text() == UNREADABLE_RESULT_TEXT
