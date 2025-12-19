"""
Data models for benchmark results.

These models store aggregated statistics from benchmark runs,
enabling comparison of evaluator performance.
"""

from dataclasses import dataclass, field
from datetime import datetime
from typing import Any, Optional

from ..data_models import Evaluator


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
        document_id: The document being compared
        document_title: Document title for display
        scores: Mapping of evaluator_id to score
        explanations: Mapping of evaluator_id to explanation
        max_disagreement: Maximum score difference between evaluators
    """

    document_id: str
    document_title: str
    scores: dict[str, int]  # evaluator_id -> score
    explanations: dict[str, str]  # evaluator_id -> explanation

    @property
    def max_disagreement(self) -> int:
        """Maximum score difference between any two evaluators."""
        if len(self.scores) < 2:
            return 0
        score_values = list(self.scores.values())
        return max(score_values) - min(score_values)

    @property
    def has_disagreement(self) -> bool:
        """Check if evaluators disagree (diff > 1)."""
        return self.max_disagreement > 1

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document_id": self.document_id,
            "document_title": self.document_title,
            "scores": self.scores,
            "explanations": self.explanations,
            "max_disagreement": self.max_disagreement,
            "has_disagreement": self.has_disagreement,
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
        agreement_matrix: Pairwise agreement percentages
        total_duration_seconds: Total benchmark execution time
        created_at: When results were computed
    """

    run_id: str
    question: str
    task_type: str
    evaluator_stats: list[EvaluatorStats]
    document_comparisons: list[DocumentComparison]
    agreement_matrix: dict[str, dict[str, float]]  # eval1 -> eval2 -> agreement%
    total_duration_seconds: float
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
    def disagreement_rate(self) -> float:
        """Percentage of documents with evaluator disagreement."""
        if not self.document_comparisons:
            return 0.0
        return len(self.documents_with_disagreement) / len(self.document_comparisons)

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
        return {
            "run_id": self.run_id,
            "question": self.question,
            "task_type": self.task_type,
            "evaluator_stats": [s.to_dict() for s in self.evaluator_stats],
            "document_comparisons": [d.to_dict() for d in self.document_comparisons],
            "agreement_matrix": self.agreement_matrix,
            "total_duration_seconds": self.total_duration_seconds,
            "total_evaluations": self.total_evaluations,
            "total_cost_usd": self.total_cost_usd,
            "disagreement_rate": self.disagreement_rate,
            "created_at": self.created_at.isoformat(),
        }

    def to_json(self) -> str:
        """Serialize to JSON string."""
        import json
        return json.dumps(self.to_dict(), indent=2)
