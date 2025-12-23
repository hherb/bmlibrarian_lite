"""
Statistical calculations for quality benchmark analysis.

Provides functions for computing design agreement metrics, tier agreement,
and other statistics useful for comparing quality assessors.
"""

import statistics
from typing import Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from ..data_models import LiteDocument

from ..data_models import Evaluator
from ..quality.data_models import QualityAssessment, StudyDesign, QualityTier
from .quality_models import (
    QualityEvaluatorStats,
    QualityDocumentComparison,
    QualityEvaluation,
)


def compute_quality_evaluator_stats(
    evaluator: Evaluator,
    evaluations: list[QualityEvaluation],
) -> QualityEvaluatorStats:
    """
    Compute statistics for a single evaluator in a quality benchmark.

    Args:
        evaluator: The evaluator to compute stats for
        evaluations: All evaluations from this evaluator

    Returns:
        QualityEvaluatorStats with aggregated metrics
    """
    if not evaluations:
        return QualityEvaluatorStats(
            evaluator=evaluator,
            assessments=[],
            design_distribution={},
            tier_distribution={},
            mean_confidence=0.0,
            mean_latency_ms=0.0,
            total_tokens_input=0,
            total_tokens_output=0,
            total_cost_usd=0.0,
        )

    assessments = [e.assessment for e in evaluations]

    # Design distribution
    design_distribution: dict[str, int] = {}
    for assessment in assessments:
        design_name = assessment.study_design.value
        design_distribution[design_name] = design_distribution.get(design_name, 0) + 1

    # Tier distribution
    tier_distribution: dict[int, int] = {}
    for assessment in assessments:
        tier_value = assessment.quality_tier.value
        tier_distribution[tier_value] = tier_distribution.get(tier_value, 0) + 1

    # Confidence stats
    confidences = [a.confidence for a in assessments]
    mean_confidence = statistics.mean(confidences) if confidences else 0.0

    # Latency stats
    latencies = [e.latency_ms for e in evaluations if e.latency_ms > 0]
    mean_latency = statistics.mean(latencies) if latencies else 0.0

    # Token stats
    total_input = sum(e.tokens_input for e in evaluations)
    total_output = sum(e.tokens_output for e in evaluations)

    # Cost stats
    total_cost = sum(e.cost_usd for e in evaluations)

    return QualityEvaluatorStats(
        evaluator=evaluator,
        assessments=assessments,
        design_distribution=design_distribution,
        tier_distribution=tier_distribution,
        mean_confidence=mean_confidence,
        mean_latency_ms=mean_latency,
        total_tokens_input=total_input,
        total_tokens_output=total_output,
        total_cost_usd=total_cost,
    )


def compute_design_agreement(
    designs1: list[StudyDesign],
    designs2: list[StudyDesign],
) -> float:
    """
    Compute exact design agreement percentage between two evaluators.

    Args:
        designs1: First evaluator's study designs (ordered by document)
        designs2: Second evaluator's study designs (same order)

    Returns:
        Agreement percentage (0.0 to 1.0)

    Raises:
        ValueError: If design lists have different lengths
    """
    if len(designs1) != len(designs2):
        raise ValueError(
            f"Design lists must have same length: {len(designs1)} vs {len(designs2)}"
        )

    if not designs1:
        return 1.0  # Empty lists agree perfectly

    agreements = sum(1 for d1, d2 in zip(designs1, designs2) if d1 == d2)
    return agreements / len(designs1)


def compute_tier_agreement(
    tiers1: list[QualityTier],
    tiers2: list[QualityTier],
    tolerance: int = 1,
) -> float:
    """
    Compute tier agreement percentage between two evaluators.

    Agreement is defined as tier values being within the tolerance threshold.

    Args:
        tiers1: First evaluator's quality tiers (ordered by document)
        tiers2: Second evaluator's quality tiers (same order)
        tolerance: Maximum difference in tier values to count as agreement

    Returns:
        Agreement percentage (0.0 to 1.0)

    Raises:
        ValueError: If tier lists have different lengths
    """
    if len(tiers1) != len(tiers2):
        raise ValueError(
            f"Tier lists must have same length: {len(tiers1)} vs {len(tiers2)}"
        )

    if not tiers1:
        return 1.0  # Empty lists agree perfectly

    agreements = sum(
        1 for t1, t2 in zip(tiers1, tiers2) if abs(t1.value - t2.value) <= tolerance
    )
    return agreements / len(tiers1)


def compute_design_agreement_matrix(
    evaluator_designs: dict[str, list[StudyDesign]],
) -> dict[tuple[str, str], float]:
    """
    Compute pairwise exact design agreement matrix for all evaluators.

    Args:
        evaluator_designs: Mapping of evaluator name to ordered design list

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage
    """
    evaluator_names = list(evaluator_designs.keys())
    matrix: dict[tuple[str, str], float] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                matrix[(name1, name2)] = 1.0  # Perfect self-agreement
            else:
                designs1 = evaluator_designs[name1]
                designs2 = evaluator_designs[name2]
                matrix[(name1, name2)] = compute_design_agreement(designs1, designs2)

    return matrix


def compute_tier_agreement_matrix(
    evaluator_tiers: dict[str, list[QualityTier]],
    tolerance: int = 1,
) -> dict[tuple[str, str], float]:
    """
    Compute pairwise tier agreement matrix for all evaluators.

    Args:
        evaluator_tiers: Mapping of evaluator name to ordered tier list
        tolerance: Maximum difference in tier values to count as agreement

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage
    """
    evaluator_names = list(evaluator_tiers.keys())
    matrix: dict[tuple[str, str], float] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                matrix[(name1, name2)] = 1.0  # Perfect self-agreement
            else:
                tiers1 = evaluator_tiers[name1]
                tiers2 = evaluator_tiers[name2]
                matrix[(name1, name2)] = compute_tier_agreement(tiers1, tiers2, tolerance)

    return matrix


def compute_quality_document_comparison(
    document: "LiteDocument",
    evaluations_by_evaluator: dict[str, QualityEvaluation],
) -> QualityDocumentComparison:
    """
    Create a document comparison from quality evaluations by different evaluators.

    Args:
        document: The document being compared
        evaluations_by_evaluator: Mapping of evaluator display name to evaluation

    Returns:
        QualityDocumentComparison with all evaluator assessments
    """
    assessments = {
        eval_name: e.assessment for eval_name, e in evaluations_by_evaluator.items()
    }
    designs = {
        eval_name: e.study_design for eval_name, e in evaluations_by_evaluator.items()
    }
    tiers = {
        eval_name: e.quality_tier for eval_name, e in evaluations_by_evaluator.items()
    }
    confidences = {
        eval_name: e.confidence for eval_name, e in evaluations_by_evaluator.items()
    }

    return QualityDocumentComparison(
        document=document,
        assessments=assessments,
        designs=designs,
        tiers=tiers,
        confidences=confidences,
    )


def find_design_disagreement_documents(
    document_comparisons: list[QualityDocumentComparison],
) -> list[QualityDocumentComparison]:
    """
    Find documents where evaluators disagree on study design.

    Args:
        document_comparisons: All document comparisons

    Returns:
        Documents where evaluators assigned different study designs
    """
    return [dc for dc in document_comparisons if dc.has_design_disagreement]


def find_tier_disagreement_documents(
    document_comparisons: list[QualityDocumentComparison],
    threshold: int = 2,
) -> list[QualityDocumentComparison]:
    """
    Find documents with high tier disagreement.

    Args:
        document_comparisons: All document comparisons
        threshold: Minimum tier difference to flag

    Returns:
        Documents where max tier difference >= threshold
    """
    return [dc for dc in document_comparisons if dc.max_tier_difference >= threshold]


def compute_confidence_correlation(
    confidences1: list[float],
    confidences2: list[float],
) -> Optional[float]:
    """
    Compute Pearson correlation between confidence scores of two evaluators.

    Args:
        confidences1: First evaluator's confidence scores
        confidences2: Second evaluator's confidence scores

    Returns:
        Pearson correlation coefficient (-1.0 to 1.0), or None if cannot compute
    """
    if len(confidences1) != len(confidences2) or len(confidences1) < 2:
        return None

    try:
        # Check if either list has zero variance
        if len(set(confidences1)) == 1 or len(set(confidences2)) == 1:
            return None

        mean1 = statistics.mean(confidences1)
        mean2 = statistics.mean(confidences2)
        std1 = statistics.stdev(confidences1)
        std2 = statistics.stdev(confidences2)

        if std1 == 0 or std2 == 0:
            return None

        n = len(confidences1)
        covariance = sum(
            (c1 - mean1) * (c2 - mean2) for c1, c2 in zip(confidences1, confidences2)
        ) / (n - 1)

        return covariance / (std1 * std2)
    except (ZeroDivisionError, statistics.StatisticsError):
        return None


def compute_mean_tier_difference(
    tiers1: list[QualityTier],
    tiers2: list[QualityTier],
) -> float:
    """
    Compute mean absolute difference between tier values.

    Args:
        tiers1: First evaluator's quality tiers
        tiers2: Second evaluator's quality tiers

    Returns:
        Mean absolute difference (0.0 to 5.0 for 0-5 tier scale)
    """
    if len(tiers1) != len(tiers2) or not tiers1:
        return 0.0

    total_diff = sum(abs(t1.value - t2.value) for t1, t2 in zip(tiers1, tiers2))
    return total_diff / len(tiers1)


def compute_design_distribution(
    assessments: list[QualityAssessment],
) -> dict[str, int]:
    """
    Compute distribution of study designs across assessments.

    Args:
        assessments: List of quality assessments

    Returns:
        Dict mapping study design name to count
    """
    distribution: dict[str, int] = {}
    for assessment in assessments:
        design_name = assessment.study_design.value
        distribution[design_name] = distribution.get(design_name, 0) + 1
    return distribution


def compute_tier_distribution(
    assessments: list[QualityAssessment],
) -> dict[int, int]:
    """
    Compute distribution of quality tiers across assessments.

    Args:
        assessments: List of quality assessments

    Returns:
        Dict mapping tier value to count
    """
    distribution: dict[int, int] = {}
    for assessment in assessments:
        tier_value = assessment.quality_tier.value
        distribution[tier_value] = distribution.get(tier_value, 0) + 1
    return distribution


def aggregate_assessments_by_design(
    assessments: list[QualityAssessment],
) -> dict[StudyDesign, list[QualityAssessment]]:
    """
    Group assessments by study design.

    Args:
        assessments: List of quality assessments

    Returns:
        Dict mapping study design to list of assessments with that design
    """
    grouped: dict[StudyDesign, list[QualityAssessment]] = {}
    for assessment in assessments:
        design = assessment.study_design
        if design not in grouped:
            grouped[design] = []
        grouped[design].append(assessment)
    return grouped


def aggregate_assessments_by_tier(
    assessments: list[QualityAssessment],
) -> dict[QualityTier, list[QualityAssessment]]:
    """
    Group assessments by quality tier.

    Args:
        assessments: List of quality assessments

    Returns:
        Dict mapping quality tier to list of assessments with that tier
    """
    grouped: dict[QualityTier, list[QualityAssessment]] = {}
    for assessment in assessments:
        tier = assessment.quality_tier
        if tier not in grouped:
            grouped[tier] = []
        grouped[tier].append(assessment)
    return grouped


def compute_mean_confidence_by_design(
    assessments: list[QualityAssessment],
) -> dict[StudyDesign, float]:
    """
    Compute mean confidence score per study design.

    Args:
        assessments: List of quality assessments

    Returns:
        Dict mapping study design to mean confidence
    """
    grouped = aggregate_assessments_by_design(assessments)
    return {
        design: statistics.mean([a.confidence for a in design_assessments])
        for design, design_assessments in grouped.items()
        if design_assessments
    }
