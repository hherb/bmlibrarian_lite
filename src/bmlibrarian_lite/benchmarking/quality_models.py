"""
Data models for quality assessment benchmarking.

These models store aggregated statistics from quality benchmark runs,
enabling comparison of evaluator performance on study design classification
and detailed quality assessment tasks.
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from ..data_models import LiteDocument

from ..data_models import Evaluator
from ..quality.data_models import (
    QualityAssessment,
    StudyDesign,
    QualityTier,
    StudyClassification,
)


@dataclass
class QualityEvaluatorStats:
    """
    Statistics for a single evaluator in a quality benchmark.

    Aggregates performance metrics across all documents
    evaluated by this evaluator for quality assessment.

    Attributes:
        evaluator: The evaluator these stats are for
        assessments: List of all quality assessments
        design_distribution: Count of each study design {design_name: count}
        tier_distribution: Count of each quality tier {tier_value: count}
        mean_confidence: Average confidence score (0-1)
        mean_latency_ms: Average response time
        total_tokens_input: Total input tokens used
        total_tokens_output: Total output tokens used
        total_cost_usd: Total estimated cost
    """

    evaluator: Evaluator
    assessments: list[QualityAssessment]
    design_distribution: dict[str, int]  # design_name -> count
    tier_distribution: dict[int, int]  # tier_value -> count
    mean_confidence: float
    mean_latency_ms: float
    total_tokens_input: int
    total_tokens_output: int
    total_cost_usd: float

    @property
    def total_evaluations(self) -> int:
        """Total number of documents evaluated."""
        return len(self.assessments)

    @property
    def cost_per_evaluation(self) -> float:
        """Average cost per document evaluation."""
        if self.total_evaluations == 0:
            return 0.0
        return self.total_cost_usd / self.total_evaluations

    @property
    def tokens_per_evaluation(self) -> float:
        """Average tokens per document evaluation."""
        if self.total_evaluations == 0:
            return 0.0
        total = self.total_tokens_input + self.total_tokens_output
        return total / self.total_evaluations

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "evaluator_id": self.evaluator.id,
            "evaluator_display_name": self.evaluator.display_name,
            "design_distribution": self.design_distribution,
            "tier_distribution": self.tier_distribution,
            "mean_confidence": self.mean_confidence,
            "total_evaluations": self.total_evaluations,
            "mean_latency_ms": self.mean_latency_ms,
            "total_tokens_input": self.total_tokens_input,
            "total_tokens_output": self.total_tokens_output,
            "total_cost_usd": self.total_cost_usd,
            "cost_per_evaluation": self.cost_per_evaluation,
            "tokens_per_evaluation": self.tokens_per_evaluation,
        }


@dataclass
class QualityDocumentComparison:
    """
    Comparison of quality assessments for a single document across evaluators.

    Attributes:
        document: The document being compared (for access to full metadata)
        assessments: Mapping of evaluator display name to QualityAssessment
        designs: Mapping of evaluator display name to StudyDesign
        tiers: Mapping of evaluator display name to QualityTier
        confidences: Mapping of evaluator display name to confidence score
    """

    document: "LiteDocument"
    assessments: dict[str, QualityAssessment]  # evaluator display name -> assessment
    designs: dict[str, StudyDesign]  # evaluator display name -> design
    tiers: dict[str, QualityTier]  # evaluator display name -> tier
    confidences: dict[str, float]  # evaluator display name -> confidence

    @property
    def document_id(self) -> str:
        """Get document ID for backwards compatibility."""
        return self.document.id

    @property
    def document_title(self) -> str:
        """Get document title for backwards compatibility."""
        return self.document.title

    @property
    def has_design_disagreement(self) -> bool:
        """Check if evaluators disagree on study design."""
        if len(self.designs) < 2:
            return False
        design_values = list(self.designs.values())
        return len(set(design_values)) > 1

    @property
    def has_tier_disagreement(self) -> bool:
        """Check if evaluators disagree on quality tier (diff > 1)."""
        return self.max_tier_difference > 1

    @property
    def max_tier_difference(self) -> int:
        """Maximum tier difference between any two evaluators."""
        if len(self.tiers) < 2:
            return 0
        tier_values = [t.value for t in self.tiers.values()]
        return max(tier_values) - min(tier_values)

    @property
    def unique_designs(self) -> set[StudyDesign]:
        """Set of unique study designs assigned by evaluators."""
        return set(self.designs.values())

    @property
    def unique_tiers(self) -> set[QualityTier]:
        """Set of unique quality tiers assigned by evaluators."""
        return set(self.tiers.values())

    def get_design_by_evaluator(self, evaluator_name: str) -> Optional[StudyDesign]:
        """Get the study design assigned by a specific evaluator."""
        return self.designs.get(evaluator_name)

    def get_tier_by_evaluator(self, evaluator_name: str) -> Optional[QualityTier]:
        """Get the quality tier assigned by a specific evaluator."""
        return self.tiers.get(evaluator_name)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document_id": self.document.id,
            "document_title": self.document.title,
            "designs": {k: v.value for k, v in self.designs.items()},
            "tiers": {k: v.value for k, v in self.tiers.items()},
            "confidences": self.confidences,
            "has_design_disagreement": self.has_design_disagreement,
            "has_tier_disagreement": self.has_tier_disagreement,
            "max_tier_difference": self.max_tier_difference,
        }


# Task types for quality benchmarking
QUALITY_TASK_STUDY_CLASSIFICATION = "study_classification"
QUALITY_TASK_QUALITY_ASSESSMENT = "quality_assessment"


@dataclass
class QualityBenchmarkResult:
    """
    Complete results of a quality benchmark run.

    Aggregates statistics across all evaluators and provides
    cross-evaluator comparison metrics for quality assessment tasks.

    Attributes:
        run_id: ID of the benchmark run
        question: Research question evaluated
        task_type: Type of task benchmarked ("study_classification" or
            "quality_assessment")
        evaluator_stats: Per-evaluator statistics
        document_comparisons: Per-document assessment comparisons
        design_agreement_matrix: Pairwise exact design match percentages
        tier_agreement_matrix: Pairwise within ±1 tier agreement percentages
        total_duration_seconds: Total benchmark execution time
        baseline_evaluator_name: Name of baseline evaluator (if applicable)
        created_at: When results were computed
    """

    run_id: str
    question: str
    task_type: str
    evaluator_stats: list[QualityEvaluatorStats]
    document_comparisons: list[QualityDocumentComparison]
    design_agreement_matrix: dict[tuple[str, str], float]  # (eval1, eval2) -> agreement%
    tier_agreement_matrix: dict[tuple[str, str], float]  # (eval1, eval2) -> agreement%
    total_duration_seconds: float = 0.0
    baseline_evaluator_name: Optional[str] = None
    created_at: datetime = field(default_factory=datetime.now)

    @property
    def total_evaluations(self) -> int:
        """Total number of evaluations across all evaluators."""
        return sum(s.total_evaluations for s in self.evaluator_stats)

    @property
    def total_cost_usd(self) -> float:
        """Total cost across all evaluators."""
        return sum(s.total_cost_usd for s in self.evaluator_stats)

    @property
    def documents_with_design_disagreement(self) -> list[QualityDocumentComparison]:
        """Documents where evaluators disagreed on study design."""
        return [d for d in self.document_comparisons if d.has_design_disagreement]

    @property
    def documents_with_tier_disagreement(self) -> list[QualityDocumentComparison]:
        """Documents where evaluators disagreed on quality tier (diff > 1)."""
        return [d for d in self.document_comparisons if d.has_tier_disagreement]

    @property
    def design_disagreement_rate(self) -> float:
        """Percentage of documents with study design disagreement."""
        if not self.document_comparisons:
            return 0.0
        return (
            len(self.documents_with_design_disagreement) / len(self.document_comparisons)
        )

    @property
    def tier_disagreement_rate(self) -> float:
        """Percentage of documents with tier disagreement (diff > 1)."""
        if not self.document_comparisons:
            return 0.0
        return (
            len(self.documents_with_tier_disagreement) / len(self.document_comparisons)
        )

    def get_ranking_by_confidence(self) -> list[tuple[Evaluator, float]]:
        """
        Rank evaluators by mean confidence (descending).

        Returns:
            List of (evaluator, mean_confidence) tuples, highest first
        """
        return sorted(
            [(s.evaluator, s.mean_confidence) for s in self.evaluator_stats],
            key=lambda x: x[1],
            reverse=True,
        )

    def get_ranking_by_cost(self) -> list[tuple[Evaluator, float]]:
        """
        Rank evaluators by cost efficiency (ascending).

        Returns:
            List of (evaluator, cost_per_eval) tuples, cheapest first
        """
        return sorted(
            [(s.evaluator, s.cost_per_evaluation) for s in self.evaluator_stats],
            key=lambda x: x[1],
        )

    def get_ranking_by_speed(self) -> list[tuple[Evaluator, float]]:
        """
        Rank evaluators by response speed (ascending).

        Returns:
            List of (evaluator, mean_latency_ms) tuples, fastest first
        """
        return sorted(
            [(s.evaluator, s.mean_latency_ms) for s in self.evaluator_stats],
            key=lambda x: x[1],
        )

    def get_design_distribution_summary(self) -> dict[str, dict[str, int]]:
        """
        Get design distribution per evaluator.

        Returns:
            Dict mapping evaluator name to design distribution
        """
        return {
            stats.evaluator.display_name: stats.design_distribution
            for stats in self.evaluator_stats
        }

    def get_tier_distribution_summary(self) -> dict[str, dict[int, int]]:
        """
        Get tier distribution per evaluator.

        Returns:
            Dict mapping evaluator name to tier distribution
        """
        return {
            stats.evaluator.display_name: stats.tier_distribution
            for stats in self.evaluator_stats
        }

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        # Convert tuple keys to string keys for JSON serialization
        serializable_design_matrix = {
            f"{k[0]}|{k[1]}": v for k, v in self.design_agreement_matrix.items()
        }
        serializable_tier_matrix = {
            f"{k[0]}|{k[1]}": v for k, v in self.tier_agreement_matrix.items()
        }
        return {
            "run_id": self.run_id,
            "question": self.question,
            "task_type": self.task_type,
            "evaluator_stats": [s.to_dict() for s in self.evaluator_stats],
            "document_comparisons": [d.to_dict() for d in self.document_comparisons],
            "design_agreement_matrix": serializable_design_matrix,
            "tier_agreement_matrix": serializable_tier_matrix,
            "total_duration_seconds": self.total_duration_seconds,
            "total_evaluations": self.total_evaluations,
            "total_cost_usd": self.total_cost_usd,
            "design_disagreement_rate": self.design_disagreement_rate,
            "tier_disagreement_rate": self.tier_disagreement_rate,
            "baseline_evaluator_name": self.baseline_evaluator_name,
            "created_at": self.created_at.isoformat(),
        }

    def to_json(self) -> str:
        """Serialize to JSON string."""
        import json

        return json.dumps(self.to_dict(), indent=2)


@dataclass
class QualityEvaluation:
    """
    A single quality evaluation result with metadata.

    Used for tracking individual evaluations during benchmark runs
    before aggregation into QualityEvaluatorStats.

    Attributes:
        document_id: ID of the evaluated document
        evaluator: Evaluator that produced this evaluation
        assessment: The quality assessment result
        latency_ms: Response time in milliseconds
        tokens_input: Number of input tokens used
        tokens_output: Number of output tokens used
        cost_usd: Estimated cost in USD
        timestamp: When this evaluation was performed
    """

    document_id: str
    evaluator: Evaluator
    assessment: QualityAssessment
    latency_ms: float = 0.0
    tokens_input: int = 0
    tokens_output: int = 0
    cost_usd: float = 0.0
    timestamp: datetime = field(default_factory=datetime.now)

    @property
    def study_design(self) -> StudyDesign:
        """Get the study design from the assessment."""
        return self.assessment.study_design

    @property
    def quality_tier(self) -> QualityTier:
        """Get the quality tier from the assessment."""
        return self.assessment.quality_tier

    @property
    def confidence(self) -> float:
        """Get the confidence from the assessment."""
        return self.assessment.confidence

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document_id": self.document_id,
            "evaluator_id": self.evaluator.id,
            "evaluator_display_name": self.evaluator.display_name,
            "study_design": self.assessment.study_design.value,
            "quality_tier": self.assessment.quality_tier.value,
            "confidence": self.assessment.confidence,
            "latency_ms": self.latency_ms,
            "tokens_input": self.tokens_input,
            "tokens_output": self.tokens_output,
            "cost_usd": self.cost_usd,
            "timestamp": self.timestamp.isoformat(),
        }
