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
Statistical calculations for quality benchmark analysis.

Provides functions for computing design agreement metrics, tier agreement,
and other statistics useful for comparing quality assessors.
"""

import statistics
from collections.abc import Sequence
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

    A document the evaluator could not assess is counted as a failure and
    left out of every figure describing its assessments (#314). What the
    attempt cost is still counted: the call was made.

    Args:
        evaluator: The evaluator to compute stats for
        evaluations: All evaluations from this evaluator, failures included

    Returns:
        QualityEvaluatorStats with aggregated metrics
    """
    judged = [e for e in evaluations if e.assessment is not None]
    assessments = [e.assessment for e in judged if e.assessment is not None]

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
    mean_confidence = statistics.mean(confidences) if confidences else None

    # Latency stats: how long the evaluator takes to answer, which neither a
    # timed-out attempt nor a replayed review assessment says
    latencies = [e.latency_ms for e in judged if not e.reused]
    mean_latency = statistics.mean(latencies) if latencies else None

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
        failed_evaluations=len(evaluations) - len(judged),
        reused_evaluations=sum(1 for e in judged if e.reused),
    )


def _assessed_pairs[Judgement](
    values1: Sequence[Judgement | None],
    values2: Sequence[Judgement | None],
) -> list[tuple[Judgement, Judgement]]:
    """The documents both evaluators assessed, as pairs of their answers.

    Args:
        values1: First evaluator's answers (ordered by document), None where
            it gave none
        values2: Second evaluator's answers (same order)

    Returns:
        One pair per document both assessed.

    Raises:
        ValueError: If the lists have different lengths
    """
    if len(values1) != len(values2):
        raise ValueError(
            f"Lists must have same length: {len(values1)} vs {len(values2)}"
        )
    return [
        (v1, v2) for v1, v2 in zip(values1, values2) if v1 is not None and v2 is not None
    ]


def _self_agreement(values: Sequence[object | None]) -> float | None:
    """An evaluator's agreement with itself.

    Args:
        values: Its answers, None where it gave none.

    Returns:
        1.0, or None for an evaluator that assessed no document: it agrees
        with nothing, itself included.
    """
    return 1.0 if any(value is not None for value in values) else None


def compute_design_agreement(
    designs1: Sequence[StudyDesign | None],
    designs2: Sequence[StudyDesign | None],
) -> float | None:
    """
    Compute exact design agreement percentage between two evaluators.

    Only the documents both evaluators assessed are compared. A document one
    of them could not assess is no evidence either way: compared as
    "unknown", an outage counted as a disagreement (#314).

    Args:
        designs1: First evaluator's study designs (ordered by document),
            None where it gave none
        designs2: Second evaluator's study designs (same order)

    Returns:
        Agreement percentage (0.0 to 1.0), or None when the two assessed no
        document in common -- which "agreed perfectly" before

    Raises:
        ValueError: If design lists have different lengths
    """
    pairs = _assessed_pairs(designs1, designs2)
    if not pairs:
        return None

    agreements = sum(1 for d1, d2 in pairs if d1 == d2)
    return agreements / len(pairs)


def compute_tier_agreement(
    tiers1: Sequence[QualityTier | None],
    tiers2: Sequence[QualityTier | None],
    tolerance: int = 1,
) -> float | None:
    """
    Compute tier agreement percentage between two evaluators.

    Agreement is defined as tier values being within the tolerance threshold,
    over the documents both evaluators assessed.

    Args:
        tiers1: First evaluator's quality tiers (ordered by document), None
            where it gave none
        tiers2: Second evaluator's quality tiers (same order)
        tolerance: Maximum difference in tier values to count as agreement

    Returns:
        Agreement percentage (0.0 to 1.0), or None when the two assessed no
        document in common

    Raises:
        ValueError: If tier lists have different lengths
    """
    pairs = _assessed_pairs(tiers1, tiers2)
    if not pairs:
        return None

    agreements = sum(1 for t1, t2 in pairs if abs(t1.value - t2.value) <= tolerance)
    return agreements / len(pairs)


def compute_design_agreement_matrix(
    evaluator_designs: dict[str, list[StudyDesign | None]],
) -> dict[tuple[str, str], float | None]:
    """
    Compute pairwise exact design agreement matrix for all evaluators.

    Args:
        evaluator_designs: Mapping of evaluator name to ordered design list,
            None where it gave no design

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage;
        None for a pair that assessed no document in common
    """
    evaluator_names = list(evaluator_designs.keys())
    matrix: dict[tuple[str, str], float | None] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                # Self-agreement, for an evaluator that assessed anything
                matrix[(name1, name2)] = _self_agreement(evaluator_designs[name1])
            else:
                designs1 = evaluator_designs[name1]
                designs2 = evaluator_designs[name2]
                matrix[(name1, name2)] = compute_design_agreement(designs1, designs2)

    return matrix


def compute_tier_agreement_matrix(
    evaluator_tiers: dict[str, list[QualityTier | None]],
    tolerance: int = 1,
) -> dict[tuple[str, str], float | None]:
    """
    Compute pairwise tier agreement matrix for all evaluators.

    Args:
        evaluator_tiers: Mapping of evaluator name to ordered tier list, None
            where it gave no tier
        tolerance: Maximum difference in tier values to count as agreement

    Returns:
        Dict with (name1, name2) tuple keys mapping to agreement percentage;
        None for a pair that assessed no document in common
    """
    evaluator_names = list(evaluator_tiers.keys())
    matrix: dict[tuple[str, str], float | None] = {}

    for name1 in evaluator_names:
        for name2 in evaluator_names:
            if name1 == name2:
                # Self-agreement, for an evaluator that assessed anything
                matrix[(name1, name2)] = _self_agreement(evaluator_tiers[name1])
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
        evaluations_by_evaluator: Mapping of evaluator display name to
            evaluation, failures included

    Returns:
        QualityDocumentComparison with every evaluator's assessment, and
        each evaluator that could not assess the document named with why
    """
    assessments = {
        eval_name: e.assessment
        for eval_name, e in evaluations_by_evaluator.items()
        if e.assessment is not None
    }
    failures = {
        eval_name: e.failure.description
        for eval_name, e in evaluations_by_evaluator.items()
        if e.failure is not None
    }

    return QualityDocumentComparison(
        document=document,
        assessments=assessments,
        designs={name: a.study_design for name, a in assessments.items()},
        tiers={name: a.quality_tier for name, a in assessments.items()},
        confidences={name: a.confidence for name, a in assessments.items()},
        failures=failures,
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
        Documents where max tier difference >= threshold; a document fewer
        than two evaluators assessed has no difference
    """
    return [
        dc
        for dc in document_comparisons
        if (difference := dc.max_tier_difference) is not None and difference >= threshold
    ]


def compute_confidence_correlation(
    confidences1: Sequence[float | None],
    confidences2: Sequence[float | None],
) -> Optional[float]:
    """
    Compute Pearson correlation between confidence scores of two evaluators.

    Args:
        confidences1: First evaluator's confidence scores (ordered by
            document), None where it assessed none
        confidences2: Second evaluator's confidence scores (same order)

    Returns:
        Pearson correlation coefficient (-1.0 to 1.0) over the documents both
        assessed, or None if cannot compute
    """
    if len(confidences1) != len(confidences2):
        return None
    pairs = _assessed_pairs(confidences1, confidences2)
    if len(pairs) < 2:
        return None
    xs = [c1 for c1, _ in pairs]
    ys = [c2 for _, c2 in pairs]

    try:
        # Check if either list has zero variance
        if len(set(xs)) == 1 or len(set(ys)) == 1:
            return None

        mean1 = statistics.mean(xs)
        mean2 = statistics.mean(ys)
        std1 = statistics.stdev(xs)
        std2 = statistics.stdev(ys)

        if std1 == 0 or std2 == 0:
            return None

        n = len(xs)
        covariance = sum(
            (c1 - mean1) * (c2 - mean2) for c1, c2 in zip(xs, ys)
        ) / (n - 1)

        return covariance / (std1 * std2)
    except (ZeroDivisionError, statistics.StatisticsError):
        return None


def compute_mean_tier_difference(
    tiers1: Sequence[QualityTier | None],
    tiers2: Sequence[QualityTier | None],
) -> float | None:
    """
    Compute mean absolute difference between tier values.

    Args:
        tiers1: First evaluator's quality tiers (ordered by document), None
            where it assessed none
        tiers2: Second evaluator's quality tiers (same order)

    Returns:
        Mean absolute difference (0.0 to 5.0 for 0-5 tier scale) over the
        documents both assessed; None when there are none, or the lists
        differ in length. As 0.0, no data read as full agreement.
    """
    if len(tiers1) != len(tiers2):
        return None
    pairs = _assessed_pairs(tiers1, tiers2)
    if not pairs:
        return None
    return sum(abs(t1.value - t2.value) for t1, t2 in pairs) / len(pairs)


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
