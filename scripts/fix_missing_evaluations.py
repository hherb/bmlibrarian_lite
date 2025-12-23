#!/usr/bin/env python3
"""
Re-run failed evaluations for a specified model.

This script finds all documents where the previous evaluation resulted in an
error code (negative score) and re-runs scoring for those documents.

Usage:
    python scripts/fix_missing_evaluations.py anthropic:claude-sonnet-4-20250514
    python scripts/fix_missing_evaluations.py ollama:medgemma-27b-text-it-Q8_0:latest
    python scripts/fix_missing_evaluations.py ollama:llama3.2 --dry-run

Examples:
    # Fix all failed evaluations for a model
    python scripts/fix_missing_evaluations.py ollama:my-model:latest

    # Only show what would be fixed
    python scripts/fix_missing_evaluations.py anthropic:claude-sonnet-4-20250514 --dry-run

    # Only fix specific questions
    python scripts/fix_missing_evaluations.py ollama:medgemma-27b --questions "cancer"
"""

import argparse
import logging
import sqlite3
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Optional

from tqdm import tqdm

# Register adapters/converters for datetime to avoid Python 3.12 deprecation warning
sqlite3.register_adapter(datetime, lambda dt: dt.isoformat())
sqlite3.register_converter("TIMESTAMP", lambda b: datetime.fromisoformat(b.decode()))

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from bmlibrarian_lite.config import LiteConfig, TaskModelConfig
from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.llm import LLMClient
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.data_models import (
    Evaluator,
    EvaluationErrorCode,
    LiteDocument,
)
from bmlibrarian_lite.constants import (
    LLM_TASK_TYPES,
    calculate_cost,
)

# Configure logging - suppress HTTP request noise for clean progress bars
logging.basicConfig(
    level=logging.WARNING,
    format="%(asctime)s - %(levelname)s - %(message)s",
)
# Suppress httpx/httpcore logging
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logger = logging.getLogger(__name__)
logger.setLevel(logging.INFO)


def parse_model_string(model_string: str) -> tuple[str, str]:
    """
    Parse model string into provider and model name.

    Args:
        model_string: Model in "provider:model" format

    Returns:
        Tuple of (provider, model_name)

    Raises:
        ValueError: If model string is invalid
    """
    if ":" not in model_string:
        raise ValueError(
            f"Invalid model string '{model_string}'. "
            "Expected format: 'provider:model' (e.g., 'anthropic:claude-sonnet-4-20250514')"
        )

    parts = model_string.split(":", 1)
    return parts[0], parts[1]


def get_failed_evaluations(
    storage: LiteStorage,
    evaluator_id: str,
    question_filter: Optional[str] = None,
) -> list[dict[str, Any]]:
    """
    Get all failed evaluations for an evaluator.

    Args:
        storage: Storage instance
        evaluator_id: Evaluator ID to check
        question_filter: Optional comma-separated substrings to filter questions

    Returns:
        List of dicts with 'question', 'document_id', 'score', 'error_code'
    """
    # Build question filter terms
    filter_terms = []
    if question_filter:
        filter_terms = [t.strip().lower() for t in question_filter.split(",")]

    # Query for all negative scores from this evaluator
    query = """
        SELECT sd.document_id, sd.score, sd.explanation, sd.scored_at,
               rc.research_question
        FROM scored_documents sd
        JOIN review_checkpoints rc ON sd.checkpoint_id = rc.id
        WHERE sd.evaluator_id = ? AND sd.score < 0
        ORDER BY rc.research_question, sd.scored_at DESC
    """

    failed = []
    seen = set()  # Track (question, doc_id) pairs to avoid duplicates

    with storage._sqlite_connection() as conn:
        cursor = conn.execute(query, [evaluator_id])
        for row in cursor.fetchall():
            question = row["research_question"]
            doc_id = row["document_id"]

            # Apply question filter if specified
            if filter_terms:
                if not any(term in question.lower() for term in filter_terms):
                    continue

            # Skip duplicates (keep only the most recent failure)
            key = (question, doc_id)
            if key in seen:
                continue
            seen.add(key)

            # Get the error code name
            try:
                error_code = EvaluationErrorCode(row["score"])
                error_name = error_code.name
            except ValueError:
                error_name = f"UNKNOWN({row['score']})"

            failed.append({
                "question": question,
                "document_id": doc_id,
                "score": row["score"],
                "error_code": error_name,
                "explanation": row["explanation"],
                "scored_at": row["scored_at"],
            })

    return failed


def delete_failed_evaluation(
    storage: LiteStorage,
    document_id: str,
    evaluator_id: str,
) -> bool:
    """
    Delete a failed evaluation so it can be re-run.

    Args:
        storage: Storage instance
        document_id: Document ID
        evaluator_id: Evaluator ID

    Returns:
        True if deleted, False otherwise
    """
    query = """
        DELETE FROM scored_documents
        WHERE document_id = ? AND evaluator_id = ? AND score < 0
    """

    with storage._sqlite_connection() as conn:
        cursor = conn.execute(query, [document_id, evaluator_id])
        conn.commit()
        return cursor.rowcount > 0


def format_duration(seconds: float) -> str:
    """
    Format duration in seconds to human-readable string.

    Args:
        seconds: Duration in seconds

    Returns:
        Formatted string like "1h 23m 45s" or "5m 30s" or "45s"
    """
    hours, remainder = divmod(int(seconds), 3600)
    minutes, secs = divmod(remainder, 60)

    if hours > 0:
        return f"{hours}h {minutes}m {secs}s"
    elif minutes > 0:
        return f"{minutes}m {secs}s"
    else:
        return f"{secs}s"


def fix_failed_evaluations(
    model_string: str,
    question_filter: Optional[str] = None,
    dry_run: bool = False,
) -> None:
    """
    Re-run failed evaluations for a model.

    Args:
        model_string: Model in "provider:model" format
        question_filter: Optional comma-separated substrings to filter questions
        dry_run: If True, only show what would be done
    """
    # Track total time
    start_time = time.time()

    # Parse and validate model string
    provider, model_name = parse_model_string(model_string)
    print(f"Model: {model_string}")

    # Load config and storage
    config = LiteConfig.load()
    config.load_env()  # Load API keys from .env file
    storage = LiteStorage(config)

    # Get temperature and max_tokens from task type config
    scoring_defaults = LLM_TASK_TYPES.get("document_scoring", {})
    temperature = scoring_defaults.get("default_temperature", 0.1)
    max_tokens = scoring_defaults.get("default_max_tokens", 256)

    # Override the document_scoring task config to use the specified model
    config.models.tasks["document_scoring"] = TaskModelConfig(
        provider=provider,
        model=model_name,
        temperature=temperature,
        max_tokens=max_tokens,
    )

    # Create evaluator
    evaluator = Evaluator.from_model_config(
        provider=provider,
        model_name=model_name,
        temperature=temperature,
        max_tokens=max_tokens,
    )
    storage.upsert_evaluator(evaluator)
    print(f"Evaluator ID: {evaluator.id}")

    # Find all failed evaluations
    print("Scanning for failed evaluations...")
    failed = get_failed_evaluations(storage, evaluator.id, question_filter)

    if not failed:
        print("No failed evaluations found!")
        return

    # Group by error code for summary
    error_counts: dict[str, int] = {}
    for f in failed:
        error_counts[f["error_code"]] = error_counts.get(f["error_code"], 0) + 1

    print(f"\nFound {len(failed)} failed evaluations:")
    for error_code, count in sorted(error_counts.items()):
        print(f"  {error_code}: {count}")

    if dry_run:
        print("\n[DRY RUN] Would re-run the above evaluations")
        # Show a sample of failed documents
        print("\nSample of failed documents:")
        for f in failed[:5]:
            q_short = f["question"][:50] + "..." if len(f["question"]) > 50 else f["question"]
            print(f"  - {f['document_id'][:12]}... ({f['error_code']}) Q: {q_short}")
        if len(failed) > 5:
            print(f"  ... and {len(failed) - 5} more")
        return

    # Create LLM client
    llm_client = LLMClient()

    # Group failed evaluations by question for checkpoint creation
    by_question: dict[str, list[dict]] = {}
    for f in failed:
        if f["question"] not in by_question:
            by_question[f["question"]] = []
        by_question[f["question"]].append(f)

    # Statistics
    stats = {
        "total": len(failed),
        "fixed": 0,
        "still_failed": 0,
        "total_cost_usd": 0.0,
        "total_latency_ms": 0,
    }

    print()  # Blank line before progress bars

    # Create progress bars
    question_pbar = tqdm(
        list(by_question.keys()),
        desc="Questions",
        unit="q",
        position=0,
        leave=True,
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )
    doc_pbar = tqdm(
        total=len(failed),
        desc=f"Re-scoring [{model_string}]",
        unit="doc",
        position=1,
        leave=False,
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )

    # Process each question
    for question in question_pbar:
        failed_docs = by_question[question]

        # Truncate question for display
        display_question = question[:60] + "..." if len(question) > 60 else question
        question_pbar.set_description(f"Q: {display_question}")

        # Create checkpoint for this fix run
        checkpoint = storage.create_checkpoint(
            research_question=question,
            metadata={
                "evaluator_id": evaluator.id,
                "evaluator_name": evaluator.display_name,
                "run_type": "fix_failed_evaluations",
                "started_at": datetime.now().isoformat(),
                "original_failures": len(failed_docs),
            },
        )

        # Create scoring agent
        scoring_agent = LiteScoringAgent(
            config=config,
            llm_client=llm_client,
        )

        # Process each failed document
        for failure in failed_docs:
            doc_id = failure["document_id"]

            # Get the document
            doc = storage.get_document(doc_id)
            if not doc:
                stats["still_failed"] += 1
                doc_pbar.update(1)
                continue

            # Delete the old failed evaluation
            delete_failed_evaluation(storage, doc_id, evaluator.id)

            # Re-score
            score_start = time.time()
            try:
                scored_doc = scoring_agent.score_document(question, doc)
                latency_ms = int((time.time() - score_start) * 1000)

                # Add evaluator metadata
                scored_doc.evaluator_id = evaluator.id
                scored_doc.evaluator = evaluator
                scored_doc.latency_ms = latency_ms

                # Estimate tokens and cost
                tokens_input = 500
                tokens_output = 50
                cost = calculate_cost(
                    f"{evaluator.provider}:{evaluator.model_name}",
                    tokens_input,
                    tokens_output,
                )
                scored_doc.tokens_input = tokens_input
                scored_doc.tokens_output = tokens_output
                scored_doc.cost_usd = cost

                # Save to storage
                storage.save_scored_document(scored_doc, checkpoint.id)

                if scored_doc.score > 0:
                    stats["fixed"] += 1
                    stats["total_cost_usd"] += cost
                    stats["total_latency_ms"] += latency_ms
                else:
                    stats["still_failed"] += 1

            except Exception:
                stats["still_failed"] += 1

            doc_pbar.update(1)

    # Close progress bars
    doc_pbar.close()
    question_pbar.close()

    # Calculate total elapsed time
    elapsed_time = time.time() - start_time

    # Final summary
    print("\n" + "=" * 70)
    print("FIX FAILED EVALUATIONS SUMMARY")
    print("=" * 70)
    print(f"Model: {model_string}")
    print(f"Evaluator ID: {evaluator.id}")
    print(f"Total failed evaluations: {stats['total']}")
    print(f"Successfully fixed: {stats['fixed']}")
    print(f"Still failing: {stats['still_failed']}")
    if stats["fixed"] > 0:
        avg_latency = stats["total_latency_ms"] / stats["fixed"]
        print(f"Average latency: {avg_latency:.0f}ms")
        print(f"Estimated cost: ${stats['total_cost_usd']:.4f}")
    print(f"Total time: {format_duration(elapsed_time)}")
    print("=" * 70)


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Re-run failed evaluations for a model",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "model",
        help="Model string in 'provider:model' format (e.g., 'anthropic:claude-sonnet-4-20250514')",
    )
    parser.add_argument(
        "--questions",
        type=str,
        help="Comma-separated substrings to filter questions (e.g., 'cancer,treatment')",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without actually re-scoring",
    )
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Enable verbose logging",
    )
    args = parser.parse_args()

    if args.verbose:
        logging.getLogger().setLevel(logging.DEBUG)

    try:
        fix_failed_evaluations(
            model_string=args.model,
            question_filter=args.questions,
            dry_run=args.dry_run,
        )
    except ValueError as e:
        logger.error(str(e))
        sys.exit(1)
    except KeyboardInterrupt:
        logger.info("\nInterrupted by user")
        sys.exit(130)


if __name__ == "__main__":
    main()
