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

"""How a benchmark result is stated to its reader (#306).

A figure the benchmark could not compute -- the mean of an evaluator that
judged nothing, the agreement of two that judged no document in common, a
count an older result never kept -- is stated as missing, never as a number
that would rank or compare it. A document an evaluator could not score says
so, and why. The functions are pure, so the Benchmark tab's choices can be
tested without a window.
"""

from collections.abc import Sequence

from ..constants import (
    BENCHMARK_AGREEMENT_HIGH,
    BENCHMARK_AGREEMENT_MEDIUM,
    BENCHMARK_RANKING_SIZE,
)
from .models import BenchmarkResult, DocumentComparison, EvaluatorStats

#: What stands in for a figure that does not exist.
NOT_AVAILABLE = "n/a"

#: What stands in for a count an older result never kept.
NOT_RECORDED = "not recorded"

#: What a document's cell says when the evaluator could not score it.
FAILED_SCORE_TEXT = "failed"

#: What a document's cell says when the evaluator has no entry for it.
NO_SCORE_TEXT = "-"


def format_statistic(value: float | None, decimals: int = 2) -> str:
    """A statistic as the tab shows it.

    Args:
        value: The statistic, or None when there is none.
        decimals: Digits after the decimal point.

    Returns:
        The formatted figure, or :data:`NOT_AVAILABLE`.
    """
    if value is None:
        return NOT_AVAILABLE
    return f"{value:.{decimals}f}"


def format_agreement(value: float | None) -> str:
    """An agreement fraction as a percentage.

    Args:
        value: Agreement from 0.0 to 1.0, or None for a pair that judged no
            document in common.

    Returns:
        The percentage, or :data:`NOT_AVAILABLE`.
    """
    if value is None:
        return NOT_AVAILABLE
    return f"{value * 100:.0f}%"


def agreement_background(
    value: float | None,
    high_threshold: float,
    medium_threshold: float,
    low_colour: str,
) -> str | None:
    """The background colour an agreement cell is drawn with.

    Args:
        value: Agreement from 0.0 to 1.0, or None when there is none.
        high_threshold: The fraction at or above which agreement is high.
        medium_threshold: The fraction at or above which it is medium.
        low_colour: The colour of agreement below the medium threshold.

    Returns:
        The colour, or None for no figure: coloured as low agreement, a
        missing figure would still read as a finding.
    """
    if value is None:
        return None
    if value >= high_threshold:
        return BENCHMARK_AGREEMENT_HIGH
    if value >= medium_threshold:
        return BENCHMARK_AGREEMENT_MEDIUM
    return low_colour


def score_cell(comparison: DocumentComparison, evaluator_name: str) -> tuple[str, str | None]:
    """What one evaluator's cell says about one document.

    Args:
        comparison: The document's comparison.
        evaluator_name: The evaluator's display name.

    Returns:
        The cell's text and tooltip: the score and no tooltip; or
        :data:`FAILED_SCORE_TEXT` and why the scoring failed; or
        :data:`NO_SCORE_TEXT` when the evaluator has no entry.
    """
    if evaluator_name in comparison.scores:
        return str(comparison.scores[evaluator_name]), None
    if evaluator_name in comparison.failures:
        return FAILED_SCORE_TEXT, comparison.failures[evaluator_name]
    return NO_SCORE_TEXT, None


def failed_count_text(stats: EvaluatorStats) -> str:
    """How many documents an evaluator could not score.

    Args:
        stats: The evaluator's statistics.

    Returns:
        The count, or :data:`NOT_RECORDED` for a result stored before
        failures were counted -- shown as 0, it would vouch for its 1s.
    """
    if stats.failed_evaluations is None:
        return NOT_RECORDED
    return str(stats.failed_evaluations)


def mean_score_ranking(result: BenchmarkResult, limit: int = BENCHMARK_RANKING_SIZE) -> str:
    """The evaluators ranked by mean score, as one line.

    Args:
        result: The benchmark result.
        limit: How many places to name.

    Returns:
        "1. name (mean), ..." highest first; an evaluator that judged no
        document has no mean and comes last.
    """
    return ", ".join(
        f"{place}. {evaluator.display_name} ({format_statistic(mean)})"
        for place, (evaluator, mean) in enumerate(
            result.get_ranking_by_mean_score()[:limit], start=1
        )
    )


def cost_ranking(
    evaluator_stats: Sequence[EvaluatorStats], limit: int = BENCHMARK_RANKING_SIZE
) -> str:
    """The evaluators ranked by what each judgement cost, as one line.

    The cost includes calls that failed, since they were billed, and is
    divided by the judgements they bought. An evaluator that judged nothing
    has no cost per judgement and comes last.

    Args:
        evaluator_stats: Every evaluator's statistics.
        limit: How many places to name.

    Returns:
        "1. name ($cost/eval), ..." cheapest first.
    """
    priced = sorted(
        (s for s in evaluator_stats if s.total_evaluations > 0),
        key=lambda s: s.total_cost_usd / s.total_evaluations,
    )
    unpriced = [s for s in evaluator_stats if s.total_evaluations == 0]
    entries = [
        f"{s.evaluator.display_name} (${s.total_cost_usd / s.total_evaluations:.4f}/eval)"
        for s in priced
    ] + [f"{s.evaluator.display_name} ({NOT_AVAILABLE})" for s in unpriced]
    return ", ".join(
        f"{place}. {entry}" for place, entry in enumerate(entries[:limit], start=1)
    )


def failures_note(result: BenchmarkResult) -> str | None:
    """The note a result needs when it cannot tell failures from scores.

    Args:
        result: The benchmark result.

    Returns:
        The note for a result stored before failures were counted, else
        None.
    """
    if result.failures_recorded:
        return None
    return (
        "This result was computed before failed scorings were told apart "
        "from scores: a document a model could not score may be counted "
        "here as a score of 1."
    )
