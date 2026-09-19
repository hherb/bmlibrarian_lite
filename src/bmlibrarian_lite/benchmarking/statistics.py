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

"""
Statistical calculations for benchmark analysis.

Provides functions for computing agreement metrics, score distributions,
and other statistics useful for comparing evaluators.
"""

import statistics
from collections.abc import Sequence

from ..audit_records import (
    UNNAMED_FAILURE_REASON,
    is_scoring_failure,
    scoring_failure_reason,
)
from ..data_models import Evaluator, LiteDocument, ScoredDocument
from ..constants import DEFAULT_MIN_SCORE, SCORE_MAX, SCORE_MIN
from .models import EvaluatorStats, DocumentComparison


def compute_evaluator_stats(
    evaluator: Evaluator,
    scored_documents: list[ScoredDocument],
) -> EvaluatorStats:
    """
    Compute statistics for a single evaluator.

    A document the evaluator could not score -- or whose stored score is off
    the scale -- is counted as a failure and left out of every figure
    describing its judgements (#306). What the attempt cost is still
    counted: the call was made.

    Args:
        evaluator: The evaluator to compute stats for
        scored_documents: All scored documents from this evaluator,
            failures included

    Returns:
        EvaluatorStats with aggregated metrics
    """
    # A value off the scale (a stored 0, say) is no judgement either: kept
    # among the scores, it moved the mean while the distribution, which
    # counts 1-5 only, left it out
    judged = [
        sd
        for sd in scored_documents
        if not is_scoring_failure(sd) and SCORE_MIN <= sd.score <= SCORE_MAX
    ]
    scores = [sd.score for sd in judged]

    # Score distribution
    distribution = {i: 0 for i in range(SCORE_MIN, SCORE_MAX + 1)}
    for score in scores:
        distribution[score] += 1

    # Latency stats: how long the evaluator takes to answer, which a
    # timed-out attempt does not say
    latencies = [sd.latency_ms for sd in judged if sd.latency_ms is not None]
    mean_latency = statistics.mean(latencies) if latencies else None

    # Token stats
    total_input = sum(sd.tokens_input or 0 for sd in scored_documents)
    total_output = sum(sd.tokens_output or 0 for sd in scored_documents)

    # Cost stats
    total_cost = sum(sd.cost_usd or 0.0 for sd in scored_documents)

    if not scores:
        mean_score: float | None = None
        std_dev: float | None = None
    else:
        mean_score = statistics.mean(scores)
        std_dev = statistics.stdev(scores) if len(scores) > 1 else 0.0

    return EvaluatorStats(
        evaluator=evaluator,
        scores=scores,
        mean_score=mean_score,
        std_dev=std_dev,
        score_distribution=distribution,
        total_evaluations=len(judged),
        mean_latency_ms=mean_latency,
        total_tokens_input=total_input,
        total_tokens_output=total_output,
        total_cost_usd=total_cost,
        failed_evaluations=len(scored_documents) - len(judged),
    )


def _judged_pairs(
    scores1: Sequence[int | None],
    scores2: Sequence[int | None],
) -> list[tuple[int, int]]:
    """The documents both evaluators judged, as pairs of their scores.

    Args:
        scores1: First evaluator's scores, None where it gave none
        scores2: Second evaluator's scores (same order)

    Returns:
        One pair per document both scored.

    Raises:
        ValueError: If score lists have different lengths
    """
    if len(scores1) != len(scores2):
        raise ValueError(
            f"Score lists must have same length: {len(scores1)} vs {len(scores2)}"
        )
    return [
        (s1, s2)
        for s1, s2 in zip(scores1, scores2)
        if s1 is not None and s2 is not None
    ]


def _self_agreement(scores: Sequence[int | None]) -> float | None:
    """An evaluator's agreement with itself.

    Args:
        scores: Its scores, None where it gave none.

    Returns:
        1.0, or None for an evaluator that judged no document: it agrees
        with nothing, itself included.
    """
    return 1.0 if any(score is not None for score in scores) else None


def compute_agreement(
    scores1: Sequence[int | None],
    scores2: Sequence[int | None],
    tolerance: int = 1,
) -> float | None:
    """
    Compute agreement percentage between two score lists.

    Agreement is defined as scores being within the tolerance threshold,
    over the documents both evaluators judged. A document one of them could
    not score is no evidence either way: compared as a score, an outage
    counted as a disagreement of several points (#306).

    Args:
        scores1: First evaluator's scores (ordered by document), None where
            it gave none
        scores2: Second evaluator's scores (same order)
        tolerance: Maximum difference to count as agreement

    Returns:
        Agreement percentage (0.0 to 1.0), or None when the two judged no
        document in common -- which "agreed perfectly" before, so two
        outages scored 100%

    Raises:
        ValueError: If score lists have different lengths
    """
    pairs = _judged_pairs(scores1, scores2)
    if not pairs:
        return None

    agreements = sum(1 for s1, s2 in pairs if abs(s1 - s2) <= tolerance)
    return agreements / len(pairs)


def compute_exact_agreement(
    scores1: Sequence[int | None],
    scores2: Sequence[int | None],
) -> float | None:
    """
    Compute exact agreement percentage (scores must match exactly).

    Args:
        scores1: First evaluator's scores, None where it gave none
        scores2: Second evaluator's scores

    Returns:
        Exact agreement percentage (0.0 to 1.0), or None when the two judged
        no document in common
    """
    return compute_agreement(scores1, scores2, tolerance=0)


def compute_agreement_matrix(
    evaluator_scores: dict[str, list[int | None]],
    tolerance: int = 1,
) -> dict[tuple[str, str], float | None]:
    """
    Compute pairwise agreement matrix for all evaluators.

    Args:
        evaluator_scores: Mapping of evaluator name to ordered score list,
            None where it gave no score
        tolerance: Maximum difference to count as agreement

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage;
        None for a pair that judged no document in common
    """
    evaluator_names = list(evaluator_scores.keys())
    matrix: dict[tuple[str, str], float | None] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                # Self-agreement, for an evaluator that judged anything
                matrix[(name1, name2)] = _self_agreement(evaluator_scores[name1])
            else:
                scores1 = evaluator_scores[name1]
                scores2 = evaluator_scores[name2]
                matrix[(name1, name2)] = compute_agreement(
                    scores1, scores2, tolerance
                )

    return matrix


def compute_inclusion_agreement(
    scores1: Sequence[int | None],
    scores2: Sequence[int | None],
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> float | None:
    """
    Compute inclusion decision agreement between two score lists.

    Inclusion agreement measures whether evaluators agree on the binary
    decision of including or excluding a document based on the threshold.
    This is more clinically significant than score agreement since it
    directly affects which documents appear in final results. Only the
    documents both evaluators judged are compared: a document one of them
    could not score was not excluded by it.

    Args:
        scores1: First evaluator's scores (ordered by document), None where
            it gave none
        scores2: Second evaluator's scores (same order)
        inclusion_threshold: Minimum score for document inclusion

    Returns:
        Inclusion agreement percentage (0.0 to 1.0), or None when the two
        judged no document in common

    Raises:
        ValueError: If score lists have different lengths
    """
    pairs = _judged_pairs(scores1, scores2)
    if not pairs:
        return None

    agreements = sum(
        1 for s1, s2 in pairs
        if (s1 >= inclusion_threshold) == (s2 >= inclusion_threshold)
    )
    return agreements / len(pairs)


def compute_inclusion_agreement_matrix(
    evaluator_scores: dict[str, list[int | None]],
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> dict[tuple[str, str], float | None]:
    """
    Compute pairwise inclusion agreement matrix for all evaluators.

    Unlike score agreement (within ±1), inclusion agreement measures whether
    evaluators agree on the binary include/exclude decision. This is the most
    clinically significant form of agreement.

    Args:
        evaluator_scores: Mapping of evaluator name to ordered score list,
            None where it gave no score
        inclusion_threshold: Minimum score for document inclusion

    Returns:
        Dict with (name1, name2) tuple keys mapping to inclusion agreement
        percentage; None for a pair that judged no document in common
    """
    evaluator_names = list(evaluator_scores.keys())
    matrix: dict[tuple[str, str], float | None] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                # Self-agreement, for an evaluator that judged anything
                matrix[(name1, name2)] = _self_agreement(evaluator_scores[name1])
            else:
                scores1 = evaluator_scores[name1]
                scores2 = evaluator_scores[name2]
                matrix[(name1, name2)] = compute_inclusion_agreement(
                    scores1, scores2, inclusion_threshold
                )

    return matrix


def compute_kendall_tau(
    scores1: list[int],
    scores2: list[int],
) -> float | None:
    """
    Compute Kendall's tau rank correlation between two score lists.

    Measures how well the relative ordering agrees between evaluators.
    A value of 1 means perfect agreement in ranking, -1 means perfect
    disagreement, and 0 means no correlation.

    Args:
        scores1: First evaluator's scores
        scores2: Second evaluator's scores

    Returns:
        Kendall's tau coefficient (-1.0 to 1.0), or None if cannot compute
    """
    if len(scores1) != len(scores2) or len(scores1) < 2:
        return None

    try:
        from scipy.stats import kendalltau
        tau, _ = kendalltau(scores1, scores2)
        return float(tau) if tau == tau else None  # Handle NaN
    except ImportError:
        # Fallback: simple concordance calculation
        n = len(scores1)
        concordant = 0
        discordant = 0

        for i in range(n):
            for j in range(i + 1, n):
                diff1 = scores1[i] - scores1[j]
                diff2 = scores2[i] - scores2[j]
                product = diff1 * diff2

                if product > 0:
                    concordant += 1
                elif product < 0:
                    discordant += 1
                # Ties (product == 0) are not counted

        total_pairs = concordant + discordant
        if total_pairs == 0:
            return None

        return (concordant - discordant) / total_pairs


def compute_document_comparison(
    document: LiteDocument,
    scored_by_evaluator: dict[str, ScoredDocument],
) -> DocumentComparison:
    """
    Create a document comparison from scores by different evaluators.

    An evaluator that could not score the document is named among the
    failures, with why, and not among the scores (#306).

    Args:
        document: The document being compared
        scored_by_evaluator: Mapping of evaluator display name to ScoredDocument

    Returns:
        DocumentComparison with every evaluator's score or failure
    """
    scores: dict[str, int] = {}
    explanations: dict[str, str] = {}
    failures: dict[str, str] = {}
    for eval_name, sd in scored_by_evaluator.items():
        if is_scoring_failure(sd):
            failures[eval_name] = scoring_failure_reason(sd) or UNNAMED_FAILURE_REASON
        else:
            scores[eval_name] = sd.score
            explanations[eval_name] = sd.explanation

    return DocumentComparison(
        document=document,
        scores=scores,
        explanations=explanations,
        failures=failures,
    )


def compute_score_correlation(
    scores1: list[int],
    scores2: list[int],
) -> float | None:
    """
    Compute Pearson correlation between two score lists.

    Args:
        scores1: First evaluator's scores
        scores2: Second evaluator's scores

    Returns:
        Pearson correlation coefficient (-1.0 to 1.0), or None if cannot compute
    """
    if len(scores1) != len(scores2) or len(scores1) < 2:
        return None

    try:
        # Check if either list has zero variance
        if len(set(scores1)) == 1 or len(set(scores2)) == 1:
            return None

        mean1 = statistics.mean(scores1)
        mean2 = statistics.mean(scores2)
        std1 = statistics.stdev(scores1)
        std2 = statistics.stdev(scores2)

        if std1 == 0 or std2 == 0:
            return None

        n = len(scores1)
        covariance = sum(
            (s1 - mean1) * (s2 - mean2)
            for s1, s2 in zip(scores1, scores2)
        ) / (n - 1)

        return covariance / (std1 * std2)
    except (ZeroDivisionError, statistics.StatisticsError):
        return None


def find_high_disagreement_documents(
    document_comparisons: list[DocumentComparison],
    threshold: int = 2,
) -> list[DocumentComparison]:
    """
    Find documents with high evaluator disagreement.

    Args:
        document_comparisons: All document comparisons
        threshold: Minimum score difference to flag

    Returns:
        Documents where max disagreement >= threshold
    """
    return [
        dc for dc in document_comparisons
        if dc.max_disagreement is not None and dc.max_disagreement >= threshold
    ]


def compute_mean_absolute_difference(
    scores1: list[int],
    scores2: list[int],
) -> float:
    """
    Compute mean absolute difference between score lists.

    Args:
        scores1: First evaluator's scores
        scores2: Second evaluator's scores

    Returns:
        Mean absolute difference (0.0 to 4.0 for 1-5 scale)
    """
    if len(scores1) != len(scores2) or not scores1:
        return 0.0

    total_diff = sum(abs(s1 - s2) for s1, s2 in zip(scores1, scores2))
    return total_diff / len(scores1)
