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

from collections.abc import Mapping, Sequence

from ..analysis_failures import also_failed_text
from ..audit_records import is_scoring_failure
from ..constants import (
    BENCHMARK_AGREEMENT_HIGH,
    BENCHMARK_AGREEMENT_MEDIUM,
    BENCHMARK_RANKING_SIZE,
)
from ..data_models import ScoredDocument
from .models import (
    BenchmarkCancellation,
    BenchmarkResult,
    DocumentComparison,
    EvaluatorStats,
)

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


def format_spread(spread: int | None) -> str:
    """A document's score spread across the models that judged it.

    Args:
        spread: The widest difference, or None when fewer than two models
            judged the document.

    Returns:
        The spread, or :data:`NOT_AVAILABLE` -- shown as 0, a document one
        model could not score read as full agreement.
    """
    if spread is None:
        return NOT_AVAILABLE
    return str(spread)


def format_latency(milliseconds: float | None) -> str:
    """A mean latency as the tab shows it.

    Args:
        milliseconds: The latency, or None when no judgement recorded one.

    Returns:
        "Nms", or :data:`NOT_AVAILABLE` -- shown as 0ms, a model that
        answered nothing read as the fastest.
    """
    if milliseconds is None:
        return NOT_AVAILABLE
    return f"{milliseconds:.0f}ms"


def format_rate(value: float | None) -> str:
    """A fraction of documents as a percentage with one decimal.

    Args:
        value: The fraction, or None when no document could be compared.

    Returns:
        "N.N%", or :data:`NOT_AVAILABLE`.
    """
    if value is None:
        return NOT_AVAILABLE
    return f"{value * 100:.1f}%"


def failed_scorings_sentence(result: BenchmarkResult) -> str | None:
    """What a finished benchmark says about the scorings that failed.

    Args:
        result: The benchmark result.

    Returns:
        "N of M scorings failed (see the Failed column)", or None when none
        did -- or when the result never counted them.
    """
    if not result.failures_recorded:
        return None
    failed = sum(s.failed_evaluations or 0 for s in result.evaluator_stats)
    if failed == 0:
        return None
    attempted = failed + sum(s.total_evaluations for s in result.evaluator_stats)
    return f"{failed} of {attempted} scorings failed (see the Failed column)"


def reusable_documents_by_model(
    stored_scores: Mapping[str, Mapping[str, ScoredDocument]],
) -> dict[str, set[str]]:
    """Which documents each model has a judgement for that a benchmark reuses.

    A stored failure is scored again rather than reused (#306), so a model
    whose earlier run failed everywhere has nothing to reuse -- its cost is
    not $0.00.

    Args:
        stored_scores: Evaluator id to document id to its latest stored
            score, as ``LiteStorage.get_all_scores_for_question`` answers.

    Returns:
        Model string ("provider:model") to the documents it has judged; a
        model with no judgement is absent.
    """
    reusable: dict[str, set[str]] = {}
    for by_document in stored_scores.values():
        for document_id, scored in by_document.items():
            model = scored.evaluator.model_string if scored.evaluator else None
            if model and not is_scoring_failure(scored):
                reusable.setdefault(model, set()).add(document_id)
    return reusable


def documents_left_to_score(
    documents_benchmarked: int,
    documents_available: int,
    documents_reusable: int,
) -> int:
    """How many documents a model will be asked to score, for an estimate.

    Args:
        documents_benchmarked: How many documents the benchmark will use.
        documents_available: How many it draws them from.
        documents_reusable: How many of those the model already judged.

    Returns:
        The documents left to score. Using every document, that is exact;
        for a random sample, its expected share of the unjudged ones.
    """
    if documents_available <= 0:
        return documents_benchmarked
    unjudged = max(documents_available - documents_reusable, 0)
    return -(-documents_benchmarked * unjudged // documents_available)


def distribution_cell(stats: EvaluatorStats, score: int) -> str:
    """How often an evaluator gave a score, as its distribution cell.

    Args:
        stats: The evaluator's statistics.
        score: The score on the scale.

    Returns:
        "count (share%)", or n/a for an evaluator that judged nothing: shown
        as "0 (0%)" in every column, it read as a model that never gave any
        score rather than one that could not give one.
    """
    if stats.total_evaluations == 0:
        return NOT_AVAILABLE
    count = stats.score_distribution.get(score, 0)
    return f"{count} ({count / stats.total_evaluations * 100:.0f}%)"


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
    costs = [(s.evaluator.display_name, s.cost_per_evaluation) for s in evaluator_stats]
    priced = sorted(
        ((name, cost) for name, cost in costs if cost is not None),
        key=lambda entry: entry[1],
    )
    unpriced = [name for name, cost in costs if cost is None]
    entries = [f"{name} (${cost:.4f}/eval)" for name, cost in priced] + [
        f"{name} ({NOT_AVAILABLE})" for name in unpriced
    ]
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
        "from scores: a document a model could not score may be counted as "
        "a score of 1 in its statistics and agreement figures, even where "
        "the documents table shows it as failed -- and an answer that held "
        "no score was recorded as a 1 that cannot be told apart at all."
    )


def evaluations_text(count: int) -> str:
    """A count of evaluations, in words that agree with it.

    Args:
        count: The evaluations.

    Returns:
        e.g. "1 evaluation", "12 evaluations".
    """
    return f"{count} evaluation" if count == 1 else f"{count} evaluations"


def benchmark_cancelled_text(
    cancellation: BenchmarkCancellation,
    error: str = "",
) -> str:
    """What a cancelled benchmark says it did before it stopped.

    Args:
        cancellation: What the run had evaluated when it stopped.
        error: The error that also ended the run, or an empty string.

    Returns:
        e.g. "Benchmark cancelled after 12 of 40 evaluations. The other 28
        were not made, and were not paid for. What was evaluated is kept."
        What ran before the cancel is real and is counted, not called off
        (#324).
    """
    text = (
        f"Benchmark cancelled after {cancellation.evaluations_made} of "
        f"{evaluations_text(cancellation.evaluations_planned)}."
    )
    skipped = cancellation.evaluations_skipped
    if skipped == 1:
        text += " The other one was not made, and was not paid for."
    elif skipped > 1:
        text += f" The other {skipped} were not made, and were not paid for."
    if cancellation.evaluations_made:
        text += " What was evaluated is kept."
    return text + also_failed_text(error)


def partial_result_note(cancellation: BenchmarkCancellation | None) -> str | None:
    """The note a result needs when a cancel stopped it part way.

    Args:
        cancellation: What the run had evaluated when it stopped, or None
            for a run that was not cancelled.

    Returns:
        The note, or None for a benchmark that ran to the end. Shown without
        it, a partial comparison reads as a whole one: a model the cancel cut
        short looks like one that judged fewer documents (#324).
    """
    if cancellation is None:
        return None
    return (
        "This benchmark was cancelled after "
        f"{cancellation.evaluations_made} of "
        f"{evaluations_text(cancellation.evaluations_planned)}: every figure "
        "below is over that part of the run only, and a model the cancel "
        "reached last may have been asked about fewer documents than the "
        "others."
    )
