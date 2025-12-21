"""
Statistical calculations for benchmark analysis.

Provides functions for computing agreement metrics, score distributions,
and other statistics useful for comparing evaluators.
"""

import statistics
from typing import Optional

from ..data_models import Evaluator, ScoredDocument
from ..constants import DEFAULT_MIN_SCORE
from .models import EvaluatorStats, DocumentComparison


def compute_evaluator_stats(
    evaluator: Evaluator,
    scored_documents: list[ScoredDocument],
) -> EvaluatorStats:
    """
    Compute statistics for a single evaluator.

    Args:
        evaluator: The evaluator to compute stats for
        scored_documents: All scored documents from this evaluator

    Returns:
        EvaluatorStats with aggregated metrics
    """
    if not scored_documents:
        return EvaluatorStats(
            evaluator=evaluator,
            scores=[],
            mean_score=0.0,
            std_dev=0.0,
            score_distribution={1: 0, 2: 0, 3: 0, 4: 0, 5: 0},
            total_evaluations=0,
            mean_latency_ms=0.0,
            total_tokens_input=0,
            total_tokens_output=0,
            total_cost_usd=0.0,
        )

    scores = [sd.score for sd in scored_documents]

    # Score distribution
    distribution = {i: 0 for i in range(1, 6)}
    for score in scores:
        if 1 <= score <= 5:
            distribution[score] += 1

    # Latency stats
    latencies = [sd.latency_ms for sd in scored_documents if sd.latency_ms is not None]
    mean_latency = statistics.mean(latencies) if latencies else 0.0

    # Token stats
    total_input = sum(sd.tokens_input or 0 for sd in scored_documents)
    total_output = sum(sd.tokens_output or 0 for sd in scored_documents)

    # Cost stats
    total_cost = sum(sd.cost_usd or 0.0 for sd in scored_documents)

    return EvaluatorStats(
        evaluator=evaluator,
        scores=scores,
        mean_score=statistics.mean(scores),
        std_dev=statistics.stdev(scores) if len(scores) > 1 else 0.0,
        score_distribution=distribution,
        total_evaluations=len(scored_documents),
        mean_latency_ms=mean_latency,
        total_tokens_input=total_input,
        total_tokens_output=total_output,
        total_cost_usd=total_cost,
    )


def compute_agreement(
    scores1: list[int],
    scores2: list[int],
    tolerance: int = 1,
) -> float:
    """
    Compute agreement percentage between two score lists.

    Agreement is defined as scores being within the tolerance threshold.

    Args:
        scores1: First evaluator's scores (ordered by document)
        scores2: Second evaluator's scores (same order)
        tolerance: Maximum difference to count as agreement

    Returns:
        Agreement percentage (0.0 to 1.0)

    Raises:
        ValueError: If score lists have different lengths
    """
    if len(scores1) != len(scores2):
        raise ValueError(
            f"Score lists must have same length: {len(scores1)} vs {len(scores2)}"
        )

    if not scores1:
        return 1.0  # Empty lists agree perfectly

    agreements = sum(
        1 for s1, s2 in zip(scores1, scores2)
        if abs(s1 - s2) <= tolerance
    )

    return agreements / len(scores1)


def compute_exact_agreement(
    scores1: list[int],
    scores2: list[int],
) -> float:
    """
    Compute exact agreement percentage (scores must match exactly).

    Args:
        scores1: First evaluator's scores
        scores2: Second evaluator's scores

    Returns:
        Exact agreement percentage (0.0 to 1.0)
    """
    return compute_agreement(scores1, scores2, tolerance=0)


def compute_agreement_matrix(
    evaluator_scores: dict[str, list[int]],
    tolerance: int = 1,
) -> dict[tuple[str, str], float]:
    """
    Compute pairwise agreement matrix for all evaluators.

    Args:
        evaluator_scores: Mapping of evaluator name to ordered score list
        tolerance: Maximum difference to count as agreement

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage
    """
    evaluator_names = list(evaluator_scores.keys())
    matrix: dict[tuple[str, str], float] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                matrix[(name1, name2)] = 1.0  # Perfect self-agreement
            else:
                scores1 = evaluator_scores[name1]
                scores2 = evaluator_scores[name2]
                matrix[(name1, name2)] = compute_agreement(
                    scores1, scores2, tolerance
                )

    return matrix


def compute_inclusion_agreement(
    scores1: list[int],
    scores2: list[int],
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> float:
    """
    Compute inclusion decision agreement between two score lists.

    Inclusion agreement measures whether evaluators agree on the binary
    decision of including or excluding a document based on the threshold.
    This is more clinically significant than score agreement since it
    directly affects which documents appear in final results.

    Args:
        scores1: First evaluator's scores (ordered by document)
        scores2: Second evaluator's scores (same order)
        inclusion_threshold: Minimum score for document inclusion

    Returns:
        Inclusion agreement percentage (0.0 to 1.0)

    Raises:
        ValueError: If score lists have different lengths
    """
    if len(scores1) != len(scores2):
        raise ValueError(
            f"Score lists must have same length: {len(scores1)} vs {len(scores2)}"
        )

    if not scores1:
        return 1.0  # Empty lists agree perfectly

    agreements = sum(
        1 for s1, s2 in zip(scores1, scores2)
        if (s1 >= inclusion_threshold) == (s2 >= inclusion_threshold)
    )

    return agreements / len(scores1)


def compute_inclusion_agreement_matrix(
    evaluator_scores: dict[str, list[int]],
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> dict[tuple[str, str], float]:
    """
    Compute pairwise inclusion agreement matrix for all evaluators.

    Unlike score agreement (within ±1), inclusion agreement measures whether
    evaluators agree on the binary include/exclude decision. This is the most
    clinically significant form of agreement.

    Args:
        evaluator_scores: Mapping of evaluator name to ordered score list
        inclusion_threshold: Minimum score for document inclusion

    Returns:
        Dict with (name1, name2) tuple keys mapping to inclusion agreement percentage
    """
    evaluator_names = list(evaluator_scores.keys())
    matrix: dict[tuple[str, str], float] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                matrix[(name1, name2)] = 1.0  # Perfect self-agreement
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
) -> Optional[float]:
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
    document: "LiteDocument",
    scored_by_evaluator: dict[str, ScoredDocument],
) -> DocumentComparison:
    """
    Create a document comparison from scores by different evaluators.

    Args:
        document: The document being compared
        scored_by_evaluator: Mapping of evaluator display name to ScoredDocument

    Returns:
        DocumentComparison with all evaluator scores
    """
    from ..data_models import LiteDocument  # Import here to avoid circular

    scores = {
        eval_name: sd.score
        for eval_name, sd in scored_by_evaluator.items()
    }
    explanations = {
        eval_name: sd.explanation
        for eval_name, sd in scored_by_evaluator.items()
    }

    return DocumentComparison(
        document=document,
        scores=scores,
        explanations=explanations,
    )


def compute_score_correlation(
    scores1: list[int],
    scores2: list[int],
) -> Optional[float]:
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
        if dc.max_disagreement >= threshold
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
