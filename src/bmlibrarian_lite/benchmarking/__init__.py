"""
Benchmarking module for comparing evaluator performance.

This module provides tools for comparing LLM models and human reviewers
on document scoring and other evaluation tasks.

Usage:
    from bmlibrarian_lite.benchmarking import BenchmarkRunner, BenchmarkResult

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

__all__ = [
    # Main classes
    "BenchmarkRunner",
    "BenchmarkResult",
    "EvaluatorStats",
    "DocumentComparison",
    # Statistics functions
    "compute_evaluator_stats",
    "compute_agreement",
    "compute_exact_agreement",
    "compute_agreement_matrix",
    "compute_kendall_tau",
    "compute_document_comparison",
    "compute_score_correlation",
    "compute_mean_absolute_difference",
    "find_high_disagreement_documents",
]
