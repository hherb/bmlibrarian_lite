"""
Benchmarking module for comparing evaluator performance.

This module provides tools for comparing LLM models and human reviewers
on document scoring and quality assessment tasks.

Usage:
    from bmlibrarian_lite.benchmarking import BenchmarkRunner, BenchmarkResult

    # Scoring benchmark
    runner = BenchmarkRunner(config, storage)
    result = runner.run_quick_benchmark(
        question="What is the effect of X on Y?",
        documents=docs,
        models=["anthropic:claude-sonnet-4-20250514", "anthropic:claude-3-5-haiku-20241022"],
        checkpoint_id=checkpoint_id,
    )

    print(f"Total cost: ${result.total_cost_usd:.4f}")
    for stats in result.evaluator_stats:
        print(f"{stats.evaluator.display_name}: mean={stats.mean_score:.2f}")

    # Quality benchmark
    from bmlibrarian_lite.benchmarking import QualityBenchmarkRunner, QualityBenchmarkResult

    quality_runner = QualityBenchmarkRunner(config, storage)
    quality_result = quality_runner.run_quick_benchmark(
        question="What is the effect of X on Y?",
        documents=docs,
        models=["anthropic:claude-sonnet-4-20250514", "anthropic:claude-3-5-haiku-20241022"],
        task_type="study_classification",
    )
"""

from .models import BenchmarkResult, DocumentComparison, EvaluatorStats
from .runner import BenchmarkRunner
from .statistics import (
    compute_agreement,
    compute_agreement_matrix,
    compute_document_comparison,
    compute_evaluator_stats,
    compute_exact_agreement,
    compute_kendall_tau,
    compute_mean_absolute_difference,
    compute_score_correlation,
    find_high_disagreement_documents,
)

# Quality benchmarking
from .quality_models import (
    QualityBenchmarkResult,
    QualityDocumentComparison,
    QualityEvaluatorStats,
    QualityEvaluation,
    QUALITY_TASK_STUDY_CLASSIFICATION,
    QUALITY_TASK_QUALITY_ASSESSMENT,
)
from .quality_runner import QualityBenchmarkRunner
from .quality_statistics import (
    compute_design_agreement,
    compute_design_agreement_matrix,
    compute_quality_document_comparison,
    compute_quality_evaluator_stats,
    compute_tier_agreement,
    compute_tier_agreement_matrix,
    find_design_disagreement_documents,
    find_tier_disagreement_documents,
)

__all__ = [
    # Scoring benchmark classes
    "BenchmarkRunner",
    "BenchmarkResult",
    "EvaluatorStats",
    "DocumentComparison",
    # Scoring statistics functions
    "compute_evaluator_stats",
    "compute_agreement",
    "compute_exact_agreement",
    "compute_agreement_matrix",
    "compute_kendall_tau",
    "compute_document_comparison",
    "compute_score_correlation",
    "compute_mean_absolute_difference",
    "find_high_disagreement_documents",
    # Quality benchmark classes
    "QualityBenchmarkRunner",
    "QualityBenchmarkResult",
    "QualityEvaluatorStats",
    "QualityDocumentComparison",
    "QualityEvaluation",
    "QUALITY_TASK_STUDY_CLASSIFICATION",
    "QUALITY_TASK_QUALITY_ASSESSMENT",
    # Quality statistics functions
    "compute_quality_evaluator_stats",
    "compute_design_agreement",
    "compute_design_agreement_matrix",
    "compute_tier_agreement",
    "compute_tier_agreement_matrix",
    "compute_quality_document_comparison",
    "find_design_disagreement_documents",
    "find_tier_disagreement_documents",
]
