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

from ..data_models import EvaluationErrorCode, Evaluator
from ..quality.data_models import (
    QualityAssessment,
    StudyDesign,
    QualityTier,
)


@dataclass
class QualityEvaluatorStats:
    """
    Statistics for a single evaluator in a quality benchmark.

    Aggregates performance metrics across all documents evaluated by this
    evaluator for quality assessment. An assessment the evaluator could not
    produce is counted apart, never among its assessments. (Before #314 a
    failure was recorded as "unclassified", so an outage read as the model's
    own verdict that it could not tell the design.)

    Attributes:
        evaluator: The evaluator these stats are for
        assessments: The assessments it made, failures excluded
        design_distribution: Count of each study design {design_name: count}
        tier_distribution: Count of each quality tier {tier_value: count}
        mean_confidence: Average confidence score (0-1); None when it
            assessed no document
        mean_latency_ms: Average response time of its assessments; None when
            no assessment recorded one
        total_tokens_input: Total input tokens used, failed calls included
        total_tokens_output: Total output tokens used, failed calls included
        total_cost_usd: Total estimated cost, failed calls included
        failed_evaluations: Number of documents it could not assess
        reused_evaluations: Of its assessments, how many were the review's
            own, replayed at no cost
    """

    evaluator: Evaluator
    assessments: list[QualityAssessment]
    design_distribution: dict[str, int]  # design_name -> count
    tier_distribution: dict[int, int]  # tier_value -> count
    mean_confidence: float | None
    mean_latency_ms: float | None
    total_tokens_input: int
    total_tokens_output: int
    total_cost_usd: float
    failed_evaluations: int
    reused_evaluations: int = 0

    @property
    def total_evaluations(self) -> int:
        """Number of documents it assessed, failures excluded."""
        return len(self.assessments)

    @property
    def cost_per_evaluation(self) -> float | None:
        """What each assessment cost, failed calls included.

        Returns:
            The cost, failed calls included since they were billed, divided
            by the assessments it bought in this run -- not those replayed
            from the review, which cost nothing and made the baseline look
            cheap; None when it bought none. As 0.0, a model whose every call
            failed ranked as the cheapest.
        """
        bought = self.total_evaluations - self.reused_evaluations
        if bought <= 0:
            return None
        return self.total_cost_usd / bought

    @property
    def tokens_per_evaluation(self) -> float | None:
        """What each assessment took in tokens, failed calls included.

        Returns:
            The tokens, failed calls included, divided by the assessments
            bought in this run; None when it bought none.
        """
        bought = self.total_evaluations - self.reused_evaluations
        if bought <= 0:
            return None
        total = self.total_tokens_input + self.total_tokens_output
        return total / bought

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
            "failed_evaluations": self.failed_evaluations,
            "reused_evaluations": self.reused_evaluations,
        }


@dataclass
class QualityDocumentComparison:
    """
    Comparison of quality assessments for a single document across evaluators.

    Only assessments are compared. An evaluator that could not assess the
    document is named in ``failures`` instead. (Before #314 it was among the
    assessments, and its "unknown" design made the document look like a
    disagreement.)

    Attributes:
        document: The document being compared (for access to full metadata)
        assessments: Mapping of evaluator display name to QualityAssessment
        designs: Mapping of evaluator display name to StudyDesign
        tiers: Mapping of evaluator display name to QualityTier
        confidences: Mapping of evaluator display name to confidence score
        failures: Mapping of evaluator display name to why it could not
            assess the document
    """

    document: "LiteDocument"
    assessments: dict[str, QualityAssessment]  # evaluator display name -> assessment
    designs: dict[str, StudyDesign]  # evaluator display name -> design
    tiers: dict[str, QualityTier]  # evaluator display name -> tier
    confidences: dict[str, float]  # evaluator display name -> confidence
    failures: dict[str, str] = field(default_factory=dict)

    def __post_init__(self) -> None:
        """Refuse an evaluator both assessed and failed, or half-recorded.

        Raises:
            ValueError: If the designs, tiers and confidences are not of the
                same evaluators as the assessments, or an evaluator is among
                both the assessments and the failures.
        """
        assessed = set(self.assessments)
        if not assessed == set(self.designs) == set(self.tiers) == set(self.confidences):
            raise ValueError(
                f"Comparison of {self.document.id}: designs, tiers and "
                "confidences must be of the evaluators that assessed it"
            )
        both = assessed & set(self.failures)
        if both:
            raise ValueError(
                f"Comparison of {self.document.id}: {sorted(both)} both "
                "assessed the document and failed"
            )

    @property
    def document_id(self) -> str:
        """Get document ID for backwards compatibility."""
        return self.document.id

    @property
    def document_title(self) -> str:
        """Get document title for backwards compatibility."""
        return self.document.title

    @property
    def is_comparable(self) -> bool:
        """Whether at least two evaluators assessed the document.

        Returns:
            True when there is a difference to measure.
        """
        return len(self.designs) >= 2

    @property
    def has_design_disagreement(self) -> bool:
        """Check if evaluators disagree on study design."""
        if not self.is_comparable:
            return False
        design_values = list(self.designs.values())
        return len(set(design_values)) > 1

    @property
    def has_tier_disagreement(self) -> bool:
        """Check if evaluators disagree on quality tier (diff > 1)."""
        difference = self.max_tier_difference
        return difference is not None and difference > 1

    @property
    def max_tier_difference(self) -> int | None:
        """Maximum tier difference between any two evaluators.

        Returns:
            The difference, or None when fewer than two evaluators assessed
            the document: read as 0, a document one model could not assess
            looked like full agreement.
        """
        if len(self.tiers) < 2:
            return None
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
            "failures": self.failures,
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
        design_agreement_matrix: Pairwise exact design match percentages,
            over the documents both evaluators assessed; None for a pair
            that assessed no document in common
        tier_agreement_matrix: Pairwise within ±1 tier agreement percentages,
            likewise
        total_duration_seconds: Total benchmark execution time
        baseline_evaluator_name: Name of baseline evaluator (if applicable)
        created_at: When results were computed
    """

    run_id: str
    question: str
    task_type: str
    evaluator_stats: list[QualityEvaluatorStats]
    document_comparisons: list[QualityDocumentComparison]
    # (eval1, eval2) -> agreement%
    design_agreement_matrix: dict[tuple[str, str], float | None]
    tier_agreement_matrix: dict[tuple[str, str], float | None]
    total_duration_seconds: float = 0.0
    baseline_evaluator_name: Optional[str] = None
    created_at: datetime = field(default_factory=datetime.now)

    @property
    def total_evaluations(self) -> int:
        """Total number of evaluations across all evaluators."""
        return sum(s.total_evaluations for s in self.evaluator_stats)

    @property
    def failed_evaluations(self) -> int:
        """Total number of assessments that failed, across all evaluators."""
        return sum(s.failed_evaluations for s in self.evaluator_stats)

    @property
    def total_cost_usd(self) -> float:
        """Total cost across all evaluators."""
        return sum(s.total_cost_usd for s in self.evaluator_stats)

    @property
    def comparable_documents(self) -> list[QualityDocumentComparison]:
        """Documents at least two evaluators assessed: the ones rates are over.

        A document only one model could assess cannot agree or disagree;
        counted, it diluted every rate.
        """
        return [d for d in self.document_comparisons if d.is_comparable]

    @property
    def documents_with_design_disagreement(self) -> list[QualityDocumentComparison]:
        """Documents where evaluators disagreed on study design."""
        return [d for d in self.document_comparisons if d.has_design_disagreement]

    @property
    def documents_with_tier_disagreement(self) -> list[QualityDocumentComparison]:
        """Documents where evaluators disagreed on quality tier (diff > 1)."""
        return [d for d in self.document_comparisons if d.has_tier_disagreement]

    @property
    def design_disagreement_rate(self) -> float | None:
        """Fraction of comparable documents with study design disagreement.

        Returns:
            The fraction, or None when no document was comparable.
        """
        comparable = self.comparable_documents
        if not comparable:
            return None
        return len(self.documents_with_design_disagreement) / len(comparable)

    @property
    def tier_disagreement_rate(self) -> float | None:
        """Fraction of comparable documents with tier disagreement (diff > 1).

        Returns:
            The fraction, or None when no document was comparable.
        """
        comparable = self.comparable_documents
        if not comparable:
            return None
        return len(self.documents_with_tier_disagreement) / len(comparable)

    def _ranking(
        self,
        values: list[tuple[Evaluator, float | None]],
        descending: bool = False,
    ) -> list[tuple[Evaluator, float | None]]:
        """Evaluators ranked by a figure, those without one last.

        Args:
            values: Each evaluator and its figure, None where it has none.
            descending: Whether the highest figure ranks first.

        Returns:
            The ranked evaluators; an evaluator with no figure is never
            ranked as best or worst by a stand-in value.
        """
        ranked: list[tuple[Evaluator, float | None]] = sorted(
            ((evaluator, value) for evaluator, value in values if value is not None),
            key=lambda entry: entry[1] or 0.0,
            reverse=descending,
        )
        unranked: list[tuple[Evaluator, float | None]] = [
            (evaluator, value) for evaluator, value in values if value is None
        ]
        return ranked + unranked

    def get_ranking_by_confidence(self) -> list[tuple[Evaluator, float | None]]:
        """
        Rank evaluators by mean confidence (descending).

        Returns:
            List of (evaluator, mean_confidence) tuples, highest first; an
            evaluator that assessed no document comes last
        """
        return self._ranking(
            [(s.evaluator, s.mean_confidence) for s in self.evaluator_stats],
            descending=True,
        )

    def get_ranking_by_cost(self) -> list[tuple[Evaluator, float | None]]:
        """
        Rank evaluators by cost efficiency (ascending).

        Returns:
            List of (evaluator, cost_per_eval) tuples, cheapest first; an
            evaluator that assessed no document comes last
        """
        return self._ranking(
            [(s.evaluator, s.cost_per_evaluation) for s in self.evaluator_stats]
        )

    def get_ranking_by_speed(self) -> list[tuple[Evaluator, float | None]]:
        """
        Rank evaluators by response speed (ascending).

        Returns:
            List of (evaluator, mean_latency_ms) tuples, fastest first; an
            evaluator with no latency recorded comes last
        """
        return self._ranking(
            [(s.evaluator, s.mean_latency_ms) for s in self.evaluator_stats]
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
            "failed_evaluations": self.failed_evaluations,
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


@dataclass(frozen=True)
class QualityEvaluation:
    """
    A single quality evaluation result with metadata.

    Used for tracking individual evaluations during benchmark runs
    before aggregation into QualityEvaluatorStats. It holds either the
    model's assessment or why there is none -- never both, and never a
    stand-in assessment for a failure (#314).

    Attributes:
        document_id: ID of the evaluated document
        evaluator: Evaluator that produced this evaluation
        assessment: The quality assessment result; None when it failed
        failure: Why the evaluator could not assess the document; None when
            it did
        latency_ms: Response time in milliseconds
        tokens_input: Number of input tokens used
        tokens_output: Number of output tokens used
        cost_usd: Estimated cost in USD
        timestamp: When this evaluation was performed
        reused: Whether the assessment is the review's own, replayed rather
            than bought in this run -- so it took no time and cost nothing
    """

    document_id: str
    evaluator: Evaluator
    assessment: QualityAssessment | None = None
    failure: EvaluationErrorCode | None = None
    latency_ms: float = 0.0
    tokens_input: int = 0
    tokens_output: int = 0
    cost_usd: float = 0.0
    timestamp: datetime = field(default_factory=datetime.now)
    reused: bool = False

    def __post_init__(self) -> None:
        """Refuse an evaluation that is both, or neither, an answer and a failure.

        Raises:
            ValueError: If exactly one of ``assessment`` and ``failure`` is
                not given, the failure is ``SUCCESS``, the assessment names
                the "unknown" design, or a failure is marked reused.
        """
        if (self.assessment is None) == (self.failure is None):
            raise ValueError(
                f"Evaluation of {self.document_id} needs exactly one of an "
                "assessment and a failure"
            )
        if self.failure is EvaluationErrorCode.SUCCESS:
            raise ValueError(f"Evaluation of {self.document_id}: SUCCESS is not a failure")
        # No prompt offers "unknown" ("other" is the uncertain answer): it is
        # how the review's filter records a failure, not a model's verdict
        if (
            self.assessment is not None
            and self.assessment.study_design is StudyDesign.UNKNOWN
        ):
            raise ValueError(
                f"Evaluation of {self.document_id}: an \"unknown\" design is a "
                "failure, not an assessment"
            )
        if self.reused and self.assessment is None:
            raise ValueError(f"Evaluation of {self.document_id}: a failure cannot be reused")

    @property
    def is_failure(self) -> bool:
        """Whether the evaluator could not assess the document."""
        return self.failure is not None

    @property
    def study_design(self) -> StudyDesign | None:
        """The study design from the assessment; None when it failed."""
        return self.assessment.study_design if self.assessment is not None else None

    @property
    def quality_tier(self) -> QualityTier | None:
        """The quality tier from the assessment; None when it failed."""
        return self.assessment.quality_tier if self.assessment is not None else None

    @property
    def confidence(self) -> float | None:
        """The confidence from the assessment; None when it failed."""
        return self.assessment.confidence if self.assessment is not None else None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document_id": self.document_id,
            "evaluator_id": self.evaluator.id,
            "evaluator_display_name": self.evaluator.display_name,
            "study_design": (
                self.study_design.value if self.study_design is not None else None
            ),
            "quality_tier": (
                self.quality_tier.value if self.quality_tier is not None else None
            ),
            "confidence": self.confidence,
            "failure": self.failure.name if self.failure else None,
            "latency_ms": self.latency_ms,
            "tokens_input": self.tokens_input,
            "tokens_output": self.tokens_output,
            "cost_usd": self.cost_usd,
            "timestamp": self.timestamp.isoformat(),
            "reused": self.reused,
        }
