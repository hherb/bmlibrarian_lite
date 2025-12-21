"""
Data models for benchmark results.

These models store aggregated statistics from benchmark runs,
enabling comparison of evaluator performance.
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional, TYPE_CHECKING

if TYPE_CHECKING:
    from ..data_models import LiteDocument

from ..data_models import Evaluator
from ..constants import DEFAULT_MIN_SCORE


@dataclass
class EvaluatorStats:
    """
    Statistics for a single evaluator in a benchmark.

    Aggregates performance metrics across all documents
    evaluated by this evaluator.

    Attributes:
        evaluator: The evaluator these stats are for
        scores: List of all scores assigned
        mean_score: Average score
        std_dev: Standard deviation of scores
        score_distribution: Count of each score value (1-5)
        total_evaluations: Number of documents evaluated
        mean_latency_ms: Average response time
        total_tokens_input: Total input tokens used
        total_tokens_output: Total output tokens used
        total_cost_usd: Total estimated cost
    """

    evaluator: Evaluator
    scores: list[int]
    mean_score: float
    std_dev: float
    score_distribution: dict[int, int]  # score -> count
    total_evaluations: int
    mean_latency_ms: float
    total_tokens_input: int
    total_tokens_output: int
    total_cost_usd: float

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
            "scores": self.scores,
            "mean_score": self.mean_score,
            "std_dev": self.std_dev,
            "score_distribution": self.score_distribution,
            "total_evaluations": self.total_evaluations,
            "mean_latency_ms": self.mean_latency_ms,
            "total_tokens_input": self.total_tokens_input,
            "total_tokens_output": self.total_tokens_output,
            "total_cost_usd": self.total_cost_usd,
            "cost_per_evaluation": self.cost_per_evaluation,
            "tokens_per_evaluation": self.tokens_per_evaluation,
        }


@dataclass
class DocumentComparison:
    """
    Comparison of scores for a single document across evaluators.

    Attributes:
        document: The document being compared (for access to full metadata)
        scores: Mapping of evaluator display name to score
        explanations: Mapping of evaluator display name to explanation
        max_score_difference: Maximum score difference between evaluators
    """

    document: "LiteDocument"
    scores: dict[str, int]  # evaluator display name -> score
    explanations: dict[str, str]  # evaluator display name -> explanation

    @property
    def document_id(self) -> str:
        """Get document ID for backwards compatibility."""
        return self.document.id

    @property
    def document_title(self) -> str:
        """Get document title for backwards compatibility."""
        return self.document.title

    @property
    def max_score_difference(self) -> int:
        """Maximum score difference between any two evaluators."""
        if len(self.scores) < 2:
            return 0
        score_values = list(self.scores.values())
        return max(score_values) - min(score_values)

    @property
    def max_disagreement(self) -> int:
        """Alias for max_score_difference for backwards compatibility."""
        return self.max_score_difference

    @property
    def has_disagreement(self) -> bool:
        """Check if evaluators disagree (diff > 1)."""
        return self.max_score_difference > 1

    def has_inclusion_disagreement(
        self, inclusion_threshold: int = DEFAULT_MIN_SCORE
    ) -> bool:
        """
        Check if evaluators disagree on inclusion decision.

        This is a more clinically significant disagreement than score difference.
        It occurs when one evaluator's score would include the document
        (score >= threshold) while another would exclude it (score < threshold).

        Args:
            inclusion_threshold: Minimum score for document inclusion

        Returns:
            True if at least one evaluator would include and another exclude
        """
        if len(self.scores) < 2:
            return False
        score_values = list(self.scores.values())
        includes = any(s >= inclusion_threshold for s in score_values)
        excludes = any(s < inclusion_threshold for s in score_values)
        return includes and excludes

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document_id": self.document.id,
            "document_title": self.document.title,
            "scores": self.scores,
            "explanations": self.explanations,
            "max_score_difference": self.max_score_difference,
            "has_disagreement": self.has_disagreement,
            "has_inclusion_disagreement": self.has_inclusion_disagreement(),
        }


@dataclass
class BenchmarkResult:
    """
    Complete results of a benchmark run.

    Aggregates statistics across all evaluators and provides
    cross-evaluator comparison metrics.

    Attributes:
        run_id: ID of the benchmark run
        question: Research question evaluated
        task_type: Type of task benchmarked
        evaluator_stats: Per-evaluator statistics
        document_comparisons: Per-document score comparisons
        agreement_matrix: Pairwise agreement percentages (score within ±1)
        inclusion_agreement_matrix: Pairwise inclusion decision agreement
        inclusion_threshold: Score threshold for document inclusion
        total_duration_seconds: Total benchmark execution time
        created_at: When results were computed
    """

    run_id: str
    question: str
    task_type: str
    evaluator_stats: list[EvaluatorStats]
    document_comparisons: list[DocumentComparison]
    agreement_matrix: dict[tuple[str, str], float]  # (eval1, eval2) -> agreement%
    inclusion_agreement_matrix: dict[tuple[str, str], float] = field(
        default_factory=dict
    )  # (eval1, eval2) -> inclusion agreement%
    inclusion_threshold: int = DEFAULT_MIN_SCORE
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
    def documents_with_disagreement(self) -> list[DocumentComparison]:
        """Documents where evaluators disagreed (score diff > 1)."""
        return [d for d in self.document_comparisons if d.has_disagreement]

    @property
    def documents_with_inclusion_disagreement(self) -> list[DocumentComparison]:
        """
        Documents where evaluators disagree on inclusion decision.

        This is the most clinically significant disagreement - one model
        would include the document while another would exclude it.
        """
        return [
            d for d in self.document_comparisons
            if d.has_inclusion_disagreement(self.inclusion_threshold)
        ]

    @property
    def disagreement_rate(self) -> float:
        """Percentage of documents with evaluator disagreement."""
        if not self.document_comparisons:
            return 0.0
        return len(self.documents_with_disagreement) / len(self.document_comparisons)

    @property
    def inclusion_disagreement_rate(self) -> float:
        """
        Percentage of documents with inclusion decision disagreement.

        This is the most clinically significant metric - it represents
        documents that would be included or excluded differently depending
        on which model was used.
        """
        if not self.document_comparisons:
            return 0.0
        return (
            len(self.documents_with_inclusion_disagreement) /
            len(self.document_comparisons)
        )

    def get_ranking_by_mean_score(self) -> list[tuple[Evaluator, float]]:
        """
        Rank evaluators by mean score (descending).

        Returns:
            List of (evaluator, mean_score) tuples, highest first
        """
        return sorted(
            [(s.evaluator, s.mean_score) for s in self.evaluator_stats],
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

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        # Convert tuple keys to string keys for JSON serialization
        serializable_matrix = {
            f"{k[0]}|{k[1]}": v for k, v in self.agreement_matrix.items()
        }
        serializable_inclusion_matrix = {
            f"{k[0]}|{k[1]}": v for k, v in self.inclusion_agreement_matrix.items()
        }
        return {
            "run_id": self.run_id,
            "question": self.question,
            "task_type": self.task_type,
            "evaluator_stats": [s.to_dict() for s in self.evaluator_stats],
            "document_comparisons": [d.to_dict() for d in self.document_comparisons],
            "agreement_matrix": serializable_matrix,
            "inclusion_agreement_matrix": serializable_inclusion_matrix,
            "inclusion_threshold": self.inclusion_threshold,
            "total_duration_seconds": self.total_duration_seconds,
            "total_evaluations": self.total_evaluations,
            "total_cost_usd": self.total_cost_usd,
            "disagreement_rate": self.disagreement_rate,
            "inclusion_disagreement_rate": self.inclusion_disagreement_rate,
            "created_at": self.created_at.isoformat(),
        }

    def to_json(self) -> str:
        """Serialize to JSON string."""
        import json
        return json.dumps(self.to_dict(), indent=2)
