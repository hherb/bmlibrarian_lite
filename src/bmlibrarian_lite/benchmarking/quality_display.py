# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""How a quality benchmark result is stated to its reader (#314).

The quality benchmark's counterpart of :mod:`.display`, whose conventions it
shares: a figure the benchmark could not compute is stated as missing, never
as a number that would rank or compare it, and a document an evaluator could
not assess says so, and why -- never "Unknown", which is an answer a model
gives. The functions are pure, so the Quality Benchmark tab's choices can be
tested without a window.
"""

from ..constants import (
    BENCHMARK_AGREEMENT_LOW,
    QUALITY_BENCHMARK_DESIGN_AGREEMENT_HIGH,
    QUALITY_BENCHMARK_DESIGN_AGREEMENT_MEDIUM,
    QUALITY_BENCHMARK_TIER_AGREEMENT_HIGH,
    QUALITY_BENCHMARK_TIER_AGREEMENT_MEDIUM,
)
from ..quality.data_models import DESIGN_LABELS, StudyDesign
from .display import FAILED_SCORE_TEXT, NO_SCORE_TEXT, NOT_AVAILABLE, agreement_background
from .quality_models import (
    QualityBenchmarkResult,
    QualityDocumentComparison,
    QualityEvaluatorStats,
)

#: What a document's cell says when the evaluator could not assess it.
FAILED_ASSESSMENT_TEXT = FAILED_SCORE_TEXT

#: What a document's cell says when the evaluator has no entry for it.
NO_ASSESSMENT_TEXT = NO_SCORE_TEXT


def design_label(design_value: str) -> str:
    """A study design's label, from its stored value.

    Args:
        design_value: The design's value, as the distributions key it.

    Returns:
        The label; the value itself when it names no design. The labels are
        keyed by the design, so looked up by its value they were never found
        and every cell showed the raw value.
    """
    try:
        design = StudyDesign(design_value)
    except ValueError:
        return design_value
    return DESIGN_LABELS.get(design, design_value)


def design_cell(
    comparison: QualityDocumentComparison, evaluator_name: str
) -> tuple[str, str | None]:
    """What one evaluator's cell says about one document.

    Args:
        comparison: The document's comparison.
        evaluator_name: The evaluator's display name.

    Returns:
        The cell's text and tooltip: the design's label and no tooltip; or
        :data:`FAILED_ASSESSMENT_TEXT` and why the assessment failed; or
        :data:`NO_ASSESSMENT_TEXT` when the evaluator has no entry.
    """
    design = comparison.designs.get(evaluator_name)
    if design is not None:
        return design_label(design.value), None
    if evaluator_name in comparison.failures:
        return FAILED_ASSESSMENT_TEXT, comparison.failures[evaluator_name]
    return NO_ASSESSMENT_TEXT, None


def export_design_value(comparison: QualityDocumentComparison, evaluator_name: str) -> str:
    """One evaluator's answer for one document, as the CSV export writes it.

    Args:
        comparison: The document's comparison.
        evaluator_name: The evaluator's display name.

    Returns:
        The design's value; :data:`FAILED_ASSESSMENT_TEXT` for a failure --
        an empty cell read as "not asked"; or "" when there is no entry.
    """
    design = comparison.designs.get(evaluator_name)
    if design is not None:
        return design.value
    if evaluator_name in comparison.failures:
        return FAILED_ASSESSMENT_TEXT
    return ""


def format_tier_difference(difference: int | None) -> str:
    """A document's tier difference across the models that assessed it.

    Args:
        difference: The widest difference, or None when fewer than two
            models assessed the document.

    Returns:
        The difference, or :data:`NOT_AVAILABLE` -- shown as 0, a document
        one model could not assess read as full agreement.
    """
    if difference is None:
        return NOT_AVAILABLE
    return str(difference)


def design_distribution_cell(stats: QualityEvaluatorStats, design: str) -> str:
    """How often an evaluator named a design, as its distribution cell.

    Args:
        stats: The evaluator's statistics.
        design: The design's value.

    Returns:
        "count (share%)", or :data:`NOT_AVAILABLE` for an evaluator that
        assessed nothing: shown as "0 (0%)" in every column, it read as a
        model that never named a design rather than one that could not.
    """
    if stats.total_evaluations == 0:
        return NOT_AVAILABLE
    count = stats.design_distribution.get(design, 0)
    return f"{count} ({count / stats.total_evaluations * 100:.0f}%)"


def failed_assessments_sentence(result: QualityBenchmarkResult) -> str | None:
    """What a finished quality benchmark says about the assessments that failed.

    Args:
        result: The benchmark result.

    Returns:
        "N of M assessments failed (see the Failed column)", or None when
        none did.
    """
    failed = result.failed_evaluations
    if failed == 0:
        return None
    attempted = failed + result.total_evaluations
    return f"{failed} of {attempted} assessments failed (see the Failed column)"


def quality_benchmark_finished_text(result: QualityBenchmarkResult) -> str:
    """The status line a finished quality benchmark leaves.

    Args:
        result: The benchmark result.

    Returns:
        e.g. "Quality benchmark complete - 2 of 4 assessments failed - Total
        cost: $0.0100". Its cost alone read as success when every
        assessment had failed.
    """
    parts = ["Quality benchmark complete"]
    failed = result.failed_evaluations
    if failed:
        parts.append(f"{failed} of {failed + result.total_evaluations} assessments failed")
    parts.append(f"Total cost: ${result.total_cost_usd:.4f}")
    return " - ".join(parts)


def quality_agreement_background(value: float | None, is_design: bool) -> str | None:
    """The background colour a quality agreement cell is drawn with.

    Args:
        value: Agreement from 0.0 to 1.0, or None when there is none.
        is_design: Whether the cell is exact design agreement (stricter
            thresholds) rather than tier agreement within one tier.

    Returns:
        The colour, or None for no figure: coloured as low agreement, a
        missing figure would still read as a finding.
    """
    if is_design:
        high, medium = (
            QUALITY_BENCHMARK_DESIGN_AGREEMENT_HIGH,
            QUALITY_BENCHMARK_DESIGN_AGREEMENT_MEDIUM,
        )
    else:
        high, medium = (
            QUALITY_BENCHMARK_TIER_AGREEMENT_HIGH,
            QUALITY_BENCHMARK_TIER_AGREEMENT_MEDIUM,
        )
    return agreement_background(value, high, medium, BENCHMARK_AGREEMENT_LOW)


def matrix_value(
    matrix: dict[tuple[str, str], float | None], name1: str, name2: str
) -> float | None:
    """One pair's agreement, whichever order the matrix stores it in.

    Args:
        matrix: The agreement matrix.
        name1: The row evaluator.
        name2: The column evaluator.

    Returns:
        The agreement, or None when the pair has none -- never 0.0, which
        read as total disagreement.
    """
    if (name1, name2) in matrix:
        return matrix[(name1, name2)]
    return matrix.get((name2, name1))
