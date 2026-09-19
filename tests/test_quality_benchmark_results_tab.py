# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The Quality Benchmark tab shows a failed assessment as one (#314).

Once a failure stopped being an "unclassified" study, a model whose provider
was down for the whole run had no mean confidence, no latency and no
agreement with anyone. The tab formatted and coloured those figures as
numbers; these tests build the tab and the document dialog over such a
result, from a real run.
"""

import json
from typing import Any

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.benchmarking.display import (  # noqa: E402
    FAILED_SCORE_TEXT,
    NOT_AVAILABLE,
)
from bmlibrarian_lite.benchmarking.quality_models import QualityBenchmarkResult  # noqa: E402
from bmlibrarian_lite.benchmarking.quality_runner import QualityBenchmarkRunner  # noqa: E402
from bmlibrarian_lite.config import LiteConfig  # noqa: E402
from bmlibrarian_lite.data_models import (  # noqa: E402
    DocumentSource,
    EvaluationErrorCode,
    LiteDocument,
)
from bmlibrarian_lite.gui.quality_benchmark_results_dialog import (  # noqa: E402
    QualityBenchmarkResultsTab,
    QualityDocumentComparisonDialog,
)
from bmlibrarian_lite.llm import LLMResponse  # noqa: E402
from bmlibrarian_lite.storage import LiteStorage  # noqa: E402

ANSWERING = "ollama:classifier"
DOWN = "ollama:second-classifier"


@pytest.fixture
def qapp() -> Any:
    """The QApplication the widget tests need."""
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


class OneModelDown:
    """An LLM client whose second model's provider cannot be reached."""

    def chat(self, messages: Any, model: str, **_: Any) -> LLMResponse:
        """Answer for the first model; fail for the second.

        Args:
            messages: Ignored.
            model: The model the call is for.

        Returns:
            An RCT classification.

        Raises:
            ConnectionError: For the model that is down.
        """
        if model == DOWN:
            raise ConnectionError("Connection refused")
        return LLMResponse(
            content=json.dumps({"study_design": "rct", "confidence": 0.9}),
            input_tokens=100,
            output_tokens=20,
        )


@pytest.fixture
def outage_result(tmp_path: Any) -> QualityBenchmarkResult:
    """Two documents: one model classified both, the other reached neither."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    runner = QualityBenchmarkRunner(config=config, storage=LiteStorage(config))
    runner._llm_client = OneModelDown()  # type: ignore[assignment]
    documents = [
        LiteDocument(
            id=f"doc-{n}",
            title=f"Aspirin trial {n}",
            abstract="Patients were randomised.",
            authors=["Smith J"],
            year=2024,
            pmid=n,
            source=DocumentSource.PUBMED,
        )
        for n in ("1", "2")
    ]
    return runner.run_quick_benchmark(
        question="Does aspirin prevent stroke?",
        documents=documents,
        models=[ANSWERING, DOWN],
    )


def column_texts(table: Any, column: int) -> list[str]:
    """The text of every cell in one column."""
    return [table.item(row, column).text() for row in range(table.rowCount())]


class TestTheTabOverAnOutage:
    """The tab opens, and says what failed."""

    def test_the_tab_opens(self, qapp: Any, outage_result: QualityBenchmarkResult) -> None:
        """Formatting None as a number raised."""
        tab = QualityBenchmarkResultsTab(result=outage_result)
        assert tab.details_table.rowCount() == 2

    def test_a_failed_cell_says_so_and_why(
        self, qapp: Any, outage_result: QualityBenchmarkResult
    ) -> None:
        """Not "Unknown", which is an answer."""
        tab = QualityBenchmarkResultsTab(result=outage_result)
        down_column = 3  # Document, Tier Diff, then the models in order
        item = tab.details_table.item(0, down_column)
        assert item.text() == FAILED_SCORE_TEXT
        assert item.toolTip() == EvaluationErrorCode.API_CONNECTION_ERROR.description

    def test_a_document_one_model_assessed_has_no_tier_difference(
        self, qapp: Any, outage_result: QualityBenchmarkResult
    ) -> None:
        """Shown as 0, the outage read as full agreement."""
        tab = QualityBenchmarkResultsTab(result=outage_result)
        assert column_texts(tab.details_table, 1) == [NOT_AVAILABLE, NOT_AVAILABLE]

    def test_the_document_dialog_opens_for_a_failure(
        self, qapp: Any, outage_result: QualityBenchmarkResult
    ) -> None:
        """The failed model's panel names its failure instead of a design."""
        dialog = QualityDocumentComparisonDialog(
            outage_result.document_comparisons[0], outage_result.evaluator_stats
        )
        assert dialog.windowTitle() == "Quality Assessment Comparison"

    def test_the_result_counts_the_failures(
        self, outage_result: QualityBenchmarkResult
    ) -> None:
        """The run itself: two assessments, two failures, no agreement figure."""
        answering, down = outage_result.evaluator_stats
        assert (answering.total_evaluations, answering.failed_evaluations) == (2, 0)
        assert (down.total_evaluations, down.failed_evaluations) == (0, 2)
        names = (answering.evaluator.display_name, down.evaluator.display_name)
        assert outage_result.design_agreement_matrix[names] is None
        assert outage_result.design_agreement_matrix[(names[1], names[1])] is None
