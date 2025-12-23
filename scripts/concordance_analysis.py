#!/usr/bin/env python3
"""
Cross-question concordance analysis for benchmark results.

Analyzes all benchmark results across all research questions in the database
and computes concordance matrices comparing each model to reference models
(Claude Opus/Sonnet).

Outputs:
1. Score concordance matrix (agreement within ±1 tolerance)
2. Inclusion/exclusion agreement matrix (binary decision agreement)
3. Per-model statistics compared to reference models

Usage:
    python scripts/concordance_analysis.py [--output-dir DIR] [--format csv|json]
"""

import argparse
import csv
import json
import sys
from collections import defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from typing import Optional

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.constants import DEFAULT_MIN_SCORE
from bmlibrarian_lite.benchmarking.statistics import (
    compute_agreement,
    compute_inclusion_agreement,
    compute_kendall_tau,
    compute_mean_absolute_difference,
)


# Reference model patterns (Claude Opus and Sonnet variants)
REFERENCE_MODEL_PATTERNS = [
    "claude-opus",
    "claude-sonnet",
]


@dataclass
class EvaluatorScoreData:
    """Aggregated score data for an evaluator across all questions."""

    evaluator_name: str
    evaluator_id: str
    total_documents: int
    scores: list[int]
    document_ids: list[str]


@dataclass
class PairwiseConcordance:
    """Concordance metrics between two evaluators."""

    evaluator1: str
    evaluator2: str
    documents_compared: int
    score_agreement: float  # Within ±1 tolerance
    exact_agreement: float  # Exact match
    inclusion_agreement: float  # Binary include/exclude decision
    mean_absolute_difference: float
    kendall_tau: Optional[float]


@dataclass
class ConcordanceReport:
    """Complete concordance report across all questions."""

    generated_at: str
    total_questions: int
    total_documents: int
    total_evaluators: int
    evaluator_names: list[str]
    reference_models: list[str]
    score_agreement_matrix: dict[tuple[str, str], float]
    inclusion_agreement_matrix: dict[tuple[str, str], float]
    pairwise_concordances: list[PairwiseConcordance]
    reference_concordance_summary: dict[str, dict[str, float]]


def is_reference_model(evaluator_name: str) -> bool:
    """Check if evaluator is a reference model (Opus or Sonnet)."""
    name_lower = evaluator_name.lower()
    return any(pattern in name_lower for pattern in REFERENCE_MODEL_PATTERNS)


def collect_all_scores(storage: LiteStorage) -> dict[str, EvaluatorScoreData]:
    """
    Collect all scores from all evaluators across all questions.

    This queries the scored_documents table directly to find ALL scores,
    not just those from formal benchmark runs.

    Returns:
        Dict mapping evaluator_name -> EvaluatorScoreData
    """
    # Get all research questions
    questions = storage.get_unique_research_questions(limit=1000)

    all_evaluator_scores: dict[str, dict[str, int]] = defaultdict(dict)
    evaluator_id_map: dict[str, str] = {}

    print(f"Found {len(questions)} research questions in database")

    # Get all evaluators that have scores
    evaluators = storage.get_evaluators()
    print(f"Found {len(evaluators)} evaluators with scores")

    for evaluator in evaluators:
        evaluator_id_map[evaluator.display_name] = evaluator.id

    # For each question, get all document IDs and then query scores
    for q_summary in questions:
        question = q_summary.question
        doc_ids = storage.get_document_ids_for_question(question)

        if not doc_ids:
            continue

        # For each evaluator, check for scores on these documents
        for evaluator in evaluators:
            for doc_id in doc_ids:
                scored_doc = storage.get_scored_document_by_evaluator(
                    doc_id, evaluator.id
                )
                if scored_doc and 1 <= scored_doc.score <= 5:
                    all_evaluator_scores[evaluator.display_name][doc_id] = scored_doc.score

    # Convert to EvaluatorScoreData
    result = {}
    for evaluator_name, doc_scores in all_evaluator_scores.items():
        if not doc_scores:
            continue  # Skip evaluators with no valid scores

        doc_ids = list(doc_scores.keys())
        scores = [doc_scores[doc_id] for doc_id in doc_ids]
        result[evaluator_name] = EvaluatorScoreData(
            evaluator_name=evaluator_name,
            evaluator_id=evaluator_id_map[evaluator_name],
            total_documents=len(scores),
            scores=scores,
            document_ids=doc_ids,
        )

    return result


def compute_pairwise_concordance(
    eval1_data: EvaluatorScoreData,
    eval2_data: EvaluatorScoreData,
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> Optional[PairwiseConcordance]:
    """
    Compute concordance metrics between two evaluators.

    Only compares documents scored by both evaluators.
    """
    # Find common documents
    common_docs = set(eval1_data.document_ids) & set(eval2_data.document_ids)

    if len(common_docs) < 2:
        return None

    # Build aligned score lists
    doc_to_idx1 = {doc_id: i for i, doc_id in enumerate(eval1_data.document_ids)}
    doc_to_idx2 = {doc_id: i for i, doc_id in enumerate(eval2_data.document_ids)}

    scores1 = []
    scores2 = []
    for doc_id in common_docs:
        scores1.append(eval1_data.scores[doc_to_idx1[doc_id]])
        scores2.append(eval2_data.scores[doc_to_idx2[doc_id]])

    return PairwiseConcordance(
        evaluator1=eval1_data.evaluator_name,
        evaluator2=eval2_data.evaluator_name,
        documents_compared=len(common_docs),
        score_agreement=compute_agreement(scores1, scores2, tolerance=1),
        exact_agreement=compute_agreement(scores1, scores2, tolerance=0),
        inclusion_agreement=compute_inclusion_agreement(
            scores1, scores2, inclusion_threshold
        ),
        mean_absolute_difference=compute_mean_absolute_difference(scores1, scores2),
        kendall_tau=compute_kendall_tau(scores1, scores2),
    )


def build_concordance_report(
    evaluator_data: dict[str, EvaluatorScoreData],
    inclusion_threshold: int = DEFAULT_MIN_SCORE,
) -> ConcordanceReport:
    """
    Build complete concordance report from evaluator data.
    """
    evaluator_names = sorted(evaluator_data.keys())
    reference_models = [name for name in evaluator_names if is_reference_model(name)]

    print(f"Found {len(evaluator_names)} evaluators")
    print(f"Reference models: {reference_models}")

    # Compute all pairwise concordances
    pairwise_concordances = []
    score_agreement_matrix: dict[tuple[str, str], float] = {}
    inclusion_agreement_matrix: dict[tuple[str, str], float] = {}

    for i, name1 in enumerate(evaluator_names):
        for name2 in evaluator_names[i:]:
            if name1 == name2:
                score_agreement_matrix[(name1, name2)] = 1.0
                inclusion_agreement_matrix[(name1, name2)] = 1.0
                continue

            concordance = compute_pairwise_concordance(
                evaluator_data[name1],
                evaluator_data[name2],
                inclusion_threshold,
            )

            if concordance:
                pairwise_concordances.append(concordance)
                score_agreement_matrix[(name1, name2)] = concordance.score_agreement
                score_agreement_matrix[(name2, name1)] = concordance.score_agreement
                inclusion_agreement_matrix[(name1, name2)] = (
                    concordance.inclusion_agreement
                )
                inclusion_agreement_matrix[(name2, name1)] = (
                    concordance.inclusion_agreement
                )

    # Build reference model concordance summary
    reference_summary: dict[str, dict[str, float]] = {}
    for evaluator_name in evaluator_names:
        if evaluator_name in reference_models:
            continue

        ref_scores = {}
        for ref_model in reference_models:
            key = (evaluator_name, ref_model)
            if key in score_agreement_matrix:
                ref_scores[ref_model] = {
                    "score_agreement": score_agreement_matrix[key],
                    "inclusion_agreement": inclusion_agreement_matrix[key],
                }

        if ref_scores:
            reference_summary[evaluator_name] = ref_scores

    # Count total documents and questions
    total_docs = sum(d.total_documents for d in evaluator_data.values())
    unique_doc_ids: set[str] = set()
    for data in evaluator_data.values():
        unique_doc_ids.update(data.document_ids)

    return ConcordanceReport(
        generated_at=datetime.now().isoformat(),
        total_questions=len(unique_doc_ids),  # Approximation
        total_documents=len(unique_doc_ids),
        total_evaluators=len(evaluator_names),
        evaluator_names=evaluator_names,
        reference_models=reference_models,
        score_agreement_matrix=score_agreement_matrix,
        inclusion_agreement_matrix=inclusion_agreement_matrix,
        pairwise_concordances=pairwise_concordances,
        reference_concordance_summary=reference_summary,
    )


def format_matrix_table(
    matrix: dict[tuple[str, str], float],
    evaluator_names: list[str],
    title: str,
) -> str:
    """Format a concordance matrix as an ASCII table."""
    # Truncate names for display
    max_name_len = 25
    short_names = [name[:max_name_len] for name in evaluator_names]

    lines = [f"\n{'=' * 80}", title, "=" * 80]

    # Header row
    header = f"{'Evaluator':<{max_name_len}} |"
    for short_name in short_names:
        header += f" {short_name[:8]:>8}"
    lines.append(header)
    lines.append("-" * len(header))

    # Data rows
    for i, name in enumerate(evaluator_names):
        row = f"{short_names[i]:<{max_name_len}} |"
        for name2 in evaluator_names:
            value = matrix.get((name, name2), 0.0)
            row += f" {value * 100:>7.1f}%"
        lines.append(row)

    return "\n".join(lines)


def format_reference_summary(report: ConcordanceReport) -> str:
    """Format reference model concordance summary."""
    lines = [
        f"\n{'=' * 80}",
        "CONCORDANCE WITH REFERENCE MODELS (Claude Opus/Sonnet)",
        "=" * 80,
        "",
        f"{'Model':<40} | {'Ref Model':<25} | {'Score Agr':>10} | {'Incl Agr':>10}",
        "-" * 95,
    ]

    # Sort by average concordance with reference models
    model_avg_concordance = {}
    for model_name, ref_data in report.reference_concordance_summary.items():
        avg_score = sum(d["score_agreement"] for d in ref_data.values()) / len(ref_data)
        model_avg_concordance[model_name] = avg_score

    sorted_models = sorted(
        model_avg_concordance.keys(), key=lambda x: model_avg_concordance[x], reverse=True
    )

    for model_name in sorted_models:
        ref_data = report.reference_concordance_summary[model_name]
        for i, (ref_model, metrics) in enumerate(sorted(ref_data.items())):
            display_name = model_name if i == 0 else ""
            lines.append(
                f"{display_name:<40} | {ref_model:<25} | "
                f"{metrics['score_agreement'] * 100:>9.1f}% | "
                f"{metrics['inclusion_agreement'] * 100:>9.1f}%"
            )
        if len(ref_data) > 1:
            avg_score = sum(d["score_agreement"] for d in ref_data.values()) / len(
                ref_data
            )
            avg_incl = sum(d["inclusion_agreement"] for d in ref_data.values()) / len(
                ref_data
            )
            lines.append(
                f"{'':<40} | {'[Average]':<25} | "
                f"{avg_score * 100:>9.1f}% | {avg_incl * 100:>9.1f}%"
            )
        lines.append("")

    return "\n".join(lines)


def export_to_csv(report: ConcordanceReport, output_dir: Path) -> None:
    """Export concordance matrices to CSV files."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # Score agreement matrix
    score_csv = output_dir / "score_agreement_matrix.csv"
    with open(score_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Evaluator"] + report.evaluator_names)
        for name1 in report.evaluator_names:
            row = [name1]
            for name2 in report.evaluator_names:
                value = report.score_agreement_matrix.get((name1, name2), 0.0)
                row.append(f"{value:.4f}")
            writer.writerow(row)
    print(f"Wrote: {score_csv}")

    # Inclusion agreement matrix
    incl_csv = output_dir / "inclusion_agreement_matrix.csv"
    with open(incl_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(["Evaluator"] + report.evaluator_names)
        for name1 in report.evaluator_names:
            row = [name1]
            for name2 in report.evaluator_names:
                value = report.inclusion_agreement_matrix.get((name1, name2), 0.0)
                row.append(f"{value:.4f}")
            writer.writerow(row)
    print(f"Wrote: {incl_csv}")

    # Reference summary
    ref_csv = output_dir / "reference_concordance.csv"
    with open(ref_csv, "w", newline="") as f:
        writer = csv.writer(f)
        writer.writerow(
            ["Model", "Reference Model", "Score Agreement", "Inclusion Agreement"]
        )
        for model_name, ref_data in report.reference_concordance_summary.items():
            for ref_model, metrics in ref_data.items():
                writer.writerow(
                    [
                        model_name,
                        ref_model,
                        f"{metrics['score_agreement']:.4f}",
                        f"{metrics['inclusion_agreement']:.4f}",
                    ]
                )
    print(f"Wrote: {ref_csv}")


def export_to_json(report: ConcordanceReport, output_dir: Path) -> None:
    """Export concordance report to JSON."""
    output_dir.mkdir(parents=True, exist_ok=True)

    # Convert tuple keys to string for JSON
    json_data = {
        "generated_at": report.generated_at,
        "total_questions": report.total_questions,
        "total_documents": report.total_documents,
        "total_evaluators": report.total_evaluators,
        "evaluator_names": report.evaluator_names,
        "reference_models": report.reference_models,
        "score_agreement_matrix": {
            f"{k[0]}|{k[1]}": v for k, v in report.score_agreement_matrix.items()
        },
        "inclusion_agreement_matrix": {
            f"{k[0]}|{k[1]}": v for k, v in report.inclusion_agreement_matrix.items()
        },
        "pairwise_concordances": [
            {
                "evaluator1": pc.evaluator1,
                "evaluator2": pc.evaluator2,
                "documents_compared": pc.documents_compared,
                "score_agreement": pc.score_agreement,
                "exact_agreement": pc.exact_agreement,
                "inclusion_agreement": pc.inclusion_agreement,
                "mean_absolute_difference": pc.mean_absolute_difference,
                "kendall_tau": pc.kendall_tau,
            }
            for pc in report.pairwise_concordances
        ],
        "reference_concordance_summary": report.reference_concordance_summary,
    }

    json_path = output_dir / "concordance_report.json"
    with open(json_path, "w") as f:
        json.dump(json_data, f, indent=2)
    print(f"Wrote: {json_path}")


def export_to_markdown(
    report: ConcordanceReport,
    output_dir: Path,
    inclusion_threshold: int,
) -> None:
    """Export concordance report to Markdown format."""
    output_dir.mkdir(parents=True, exist_ok=True)

    lines = [
        "# Concordance Analysis Report",
        "",
        f"**Generated:** {report.generated_at}",
        "",
        "## Summary",
        "",
        "| Metric | Value |",
        "|--------|-------|",
        f"| Total Documents Analyzed | {report.total_documents} |",
        f"| Total Evaluators | {report.total_evaluators} |",
        f"| Reference Models | {', '.join(report.reference_models) or 'None found'} |",
        f"| Inclusion Threshold | >= {inclusion_threshold} |",
        "",
    ]

    # Reference model concordance summary (most important table)
    if report.reference_concordance_summary:
        lines.extend([
            "## Concordance with Reference Models",
            "",
            "Models ranked by score agreement with Claude Opus/Sonnet:",
            "",
            "| Model | Reference Model | Score Agreement | Inclusion Agreement |",
            "|-------|-----------------|----------------:|--------------------:|",
        ])

        # Sort by average concordance
        model_avg = {}
        for model_name, ref_data in report.reference_concordance_summary.items():
            avg = sum(d["score_agreement"] for d in ref_data.values()) / len(ref_data)
            model_avg[model_name] = avg

        sorted_models = sorted(
            model_avg.keys(), key=lambda x: model_avg[x], reverse=True
        )

        for model_name in sorted_models:
            ref_data = report.reference_concordance_summary[model_name]
            for ref_model, metrics in sorted(ref_data.items()):
                score_pct = metrics["score_agreement"] * 100
                incl_pct = metrics["inclusion_agreement"] * 100
                lines.append(
                    f"| {model_name} | {ref_model} | {score_pct:.1f}% | {incl_pct:.1f}% |"
                )

        lines.append("")

    # Score agreement matrix
    lines.extend([
        "## Score Agreement Matrix",
        "",
        "Percentage of documents where evaluators agree within ±1 score point:",
        "",
    ])
    lines.append(_format_markdown_matrix(
        report.score_agreement_matrix,
        report.evaluator_names,
    ))
    lines.append("")

    # Inclusion agreement matrix
    lines.extend([
        "## Inclusion Agreement Matrix",
        "",
        f"Percentage of documents where evaluators agree on include/exclude decision (threshold >= {inclusion_threshold}):",
        "",
    ])
    lines.append(_format_markdown_matrix(
        report.inclusion_agreement_matrix,
        report.evaluator_names,
    ))
    lines.append("")

    # Detailed pairwise statistics
    if report.pairwise_concordances:
        lines.extend([
            "## Detailed Pairwise Statistics",
            "",
            "| Evaluator 1 | Evaluator 2 | Docs | Score Agr | Exact Agr | Incl Agr | MAD | Kendall τ |",
            "|-------------|-------------|-----:|----------:|----------:|---------:|----:|----------:|",
        ])

        # Sort by score agreement descending
        sorted_pairs = sorted(
            report.pairwise_concordances,
            key=lambda x: x.score_agreement,
            reverse=True,
        )

        for pc in sorted_pairs:
            tau_str = f"{pc.kendall_tau:.3f}" if pc.kendall_tau is not None else "N/A"
            lines.append(
                f"| {pc.evaluator1} | {pc.evaluator2} | {pc.documents_compared} | "
                f"{pc.score_agreement * 100:.1f}% | {pc.exact_agreement * 100:.1f}% | "
                f"{pc.inclusion_agreement * 100:.1f}% | {pc.mean_absolute_difference:.2f} | {tau_str} |"
            )

        lines.append("")

    # Methodology notes
    lines.extend([
        "## Methodology",
        "",
        "- **Score Agreement**: Percentage of documents where scores differ by at most 1 point (on 1-5 scale)",
        "- **Exact Agreement**: Percentage of documents with identical scores",
        "- **Inclusion Agreement**: Percentage of documents where both evaluators agree on include/exclude decision",
        "- **MAD (Mean Absolute Difference)**: Average absolute score difference (0-4 scale)",
        "- **Kendall τ**: Rank correlation coefficient (-1 to +1, higher = better agreement on relative ordering)",
        "",
    ])

    md_path = output_dir / "concordance_report.md"
    with open(md_path, "w") as f:
        f.write("\n".join(lines))
    print(f"Wrote: {md_path}")


def _format_markdown_matrix(
    matrix: dict[tuple[str, str], float],
    evaluator_names: list[str],
) -> str:
    """Format a concordance matrix as a Markdown table."""
    # Create short names for column headers
    short_names = []
    for i, name in enumerate(evaluator_names):
        # Use abbreviation: first letters of each part
        parts = name.replace(":", " ").replace("-", " ").replace("_", " ").split()
        abbrev = "".join(p[0].upper() for p in parts[:4])
        short_names.append(f"{abbrev}[{i+1}]")

    lines = []

    # Header row
    header = "| Model |"
    for short in short_names:
        header += f" {short} |"
    lines.append(header)

    # Separator row
    sep = "|-------|"
    for _ in short_names:
        sep += "-------:|"
    lines.append(sep)

    # Data rows
    for i, name in enumerate(evaluator_names):
        row = f"| **[{i+1}]** {name} |"
        for name2 in evaluator_names:
            value = matrix.get((name, name2), 0.0)
            row += f" {value * 100:.1f}% |"
        lines.append(row)

    return "\n".join(lines)


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Analyze concordance across all benchmark results"
    )
    parser.add_argument(
        "--output-dir",
        type=Path,
        default=Path("concordance_output"),
        help="Directory for output files (default: concordance_output)",
    )
    parser.add_argument(
        "--format",
        choices=["csv", "json", "markdown", "md", "both", "all"],
        default="all",
        help="Output format: csv, json, markdown/md, both (csv+json), all (default: all)",
    )
    parser.add_argument(
        "--inclusion-threshold",
        type=int,
        default=DEFAULT_MIN_SCORE,
        help=f"Score threshold for inclusion decision (default: {DEFAULT_MIN_SCORE})",
    )
    args = parser.parse_args()

    print("Loading configuration and storage...")
    config = LiteConfig.load()
    storage = LiteStorage(config)

    print("\nCollecting scores from all benchmark runs...")
    evaluator_data = collect_all_scores(storage)

    if not evaluator_data:
        print("No benchmark scores found in database.")
        sys.exit(1)

    print(f"\nFound scores from {len(evaluator_data)} evaluators:")
    for name, data in sorted(evaluator_data.items()):
        print(f"  - {name}: {data.total_documents} documents")

    print("\nBuilding concordance report...")
    report = build_concordance_report(evaluator_data, args.inclusion_threshold)

    # Print summary to console
    print(f"\n{'=' * 80}")
    print("CONCORDANCE ANALYSIS SUMMARY")
    print("=" * 80)
    print(f"Generated: {report.generated_at}")
    print(f"Total documents analyzed: {report.total_documents}")
    print(f"Total evaluators: {report.total_evaluators}")
    print(f"Reference models found: {', '.join(report.reference_models)}")

    # Print score agreement matrix
    if report.score_agreement_matrix:
        print(
            format_matrix_table(
                report.score_agreement_matrix,
                report.evaluator_names,
                "SCORE AGREEMENT MATRIX (within ±1 tolerance)",
            )
        )

    # Print inclusion agreement matrix
    if report.inclusion_agreement_matrix:
        print(
            format_matrix_table(
                report.inclusion_agreement_matrix,
                report.evaluator_names,
                f"INCLUSION AGREEMENT MATRIX (threshold >= {args.inclusion_threshold})",
            )
        )

    # Print reference model summary
    if report.reference_concordance_summary:
        print(format_reference_summary(report))

    # Export to files
    if args.format in ("csv", "both", "all"):
        export_to_csv(report, args.output_dir)

    if args.format in ("json", "both", "all"):
        export_to_json(report, args.output_dir)

    if args.format in ("markdown", "md", "both", "all"):
        export_to_markdown(report, args.output_dir, args.inclusion_threshold)

    print(f"\nDone! Output written to: {args.output_dir}")


if __name__ == "__main__":
    main()
