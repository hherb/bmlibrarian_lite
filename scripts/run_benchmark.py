#!/usr/bin/env python3
"""
Run benchmark scoring for a specified model across all research questions.

This script evaluates documents using a specified LLM model for all research
questions in the database. Previously scored documents are skipped unless
--force-rerun is specified.

Usage:
    python scripts/run_benchmark.py anthropic:claude-sonnet-4-20250514
    python scripts/run_benchmark.py ollama:medgemma-27b-text-it-Q8_0:latest
    python scripts/run_benchmark.py ollama:llama3.2 --force-rerun
    python scripts/run_benchmark.py anthropic:claude-opus-4-5-20251101 --questions "metformin,diabetes"

Examples:
    # Score all questions with a new model
    python scripts/run_benchmark.py ollama:my-new-model:latest

    # Re-run scoring for all documents (ignore cached scores)
    python scripts/run_benchmark.py anthropic:claude-sonnet-4-20250514 --force-rerun

    # Only process specific questions (substring match)
    python scripts/run_benchmark.py ollama:medgemma-27b --questions "cancer,treatment"
"""

import argparse
import logging
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Optional

from tqdm import tqdm

# Add src to path for imports
sys.path.insert(0, str(Path(__file__).parent.parent / "src"))

from bmlibrarian_lite.config import LiteConfig, TaskModelConfig
from bmlibrarian_lite.storage import LiteStorage
from bmlibrarian_lite.llm import LLMClient
from bmlibrarian_lite.agents.scoring_agent import LiteScoringAgent
from bmlibrarian_lite.data_models import (
    Evaluator,
    LiteDocument,
    ScoredDocument,
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


def get_documents_for_question(
    storage: LiteStorage,
    question: str,
) -> list[LiteDocument]:
    """
    Get all documents associated with a research question.

    Args:
        storage: Storage instance
        question: Research question text

    Returns:
        List of LiteDocument objects
    """
    doc_ids = storage.get_document_ids_for_question(question)
    documents = []

    for doc_id in doc_ids:
        doc = storage.get_document(doc_id)
        if doc:
            documents.append(doc)

    return documents


def get_already_scored_doc_ids(
    storage: LiteStorage,
    evaluator_id: str,
    document_ids: list[str],
    research_question: str,
) -> set[str]:
    """
    Find which documents have already been scored by this evaluator for this question.

    A score is always relative to a specific research question - the same document
    may have different relevance scores for different questions.

    Args:
        storage: Storage instance
        evaluator_id: Evaluator ID to check
        document_ids: Document IDs to check
        research_question: The research question context

    Returns:
        Set of document IDs that already have scores for this question
    """
    already_scored = set()

    for doc_id in document_ids:
        existing = storage.get_scored_document_for_question(
            doc_id, evaluator_id, research_question
        )
        if existing and existing.score > 0:  # Valid score (not error code)
            already_scored.add(doc_id)

    return already_scored


def score_documents_for_question(
    storage: LiteStorage,
    config: LiteConfig,
    llm_client: LLMClient,
    question: str,
    evaluator: Evaluator,
    documents: list[LiteDocument],
    force_rerun: bool = False,
    model_string: str = "",
    doc_progress_bar: Optional[tqdm] = None,
) -> dict:
    """
    Score documents for a single research question.

    Args:
        storage: Storage instance
        config: LiteConfig with model settings (should have document_scoring task configured)
        llm_client: LLM client for scoring
        question: Research question
        evaluator: Evaluator to use
        documents: Documents to score
        force_rerun: If True, re-score even if already scored
        model_string: Model string for progress bar display
        doc_progress_bar: Optional tqdm progress bar for document scoring

    Returns:
        Dict with scoring statistics
    """
    stats = {
        "question": question[:80] + "..." if len(question) > 80 else question,
        "total_documents": len(documents),
        "already_scored": 0,
        "newly_scored": 0,
        "failed": 0,
        "skipped": 0,
        "total_cost_usd": 0.0,
        "total_latency_ms": 0,
    }

    if not documents:
        return stats

    # Check which documents are already scored
    doc_ids = [d.id for d in documents]
    already_scored_ids = set()

    if not force_rerun:
        already_scored_ids = get_already_scored_doc_ids(
            storage, evaluator.id, doc_ids, question
        )
        stats["already_scored"] = len(already_scored_ids)

    # Filter to documents that need scoring
    docs_to_score = [d for d in documents if d.id not in already_scored_ids]
    stats["skipped"] = len(already_scored_ids)

    if not docs_to_score:
        return stats

    # Create checkpoint for this scoring run
    checkpoint = storage.create_checkpoint(
        research_question=question,
        metadata={
            "evaluator_id": evaluator.id,
            "evaluator_name": evaluator.display_name,
            "run_type": "benchmark_script",
            "started_at": datetime.now().isoformat(),
        },
    )

    # Create scoring agent with the pre-configured config
    scoring_agent = LiteScoringAgent(
        config=config,
        llm_client=llm_client,
    )

    # Update progress bar total and reset
    if doc_progress_bar is not None:
        doc_progress_bar.reset(total=len(docs_to_score))
        doc_progress_bar.set_description(f"Scoring [{model_string}]")

    # Score each document
    for doc in docs_to_score:
        start_time = time.time()

        try:
            scored_doc = scoring_agent.score_document(question, doc)
            latency_ms = int((time.time() - start_time) * 1000)

            # Add evaluator metadata to scored document
            scored_doc.evaluator_id = evaluator.id
            scored_doc.evaluator = evaluator
            scored_doc.latency_ms = latency_ms

            # Estimate tokens and cost (approximate)
            # Rough estimate: ~500 input tokens, ~50 output tokens per doc
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
                stats["newly_scored"] += 1
                stats["total_cost_usd"] += cost
                stats["total_latency_ms"] += latency_ms
            else:
                stats["failed"] += 1

        except Exception:
            stats["failed"] += 1

        # Update progress bar
        if doc_progress_bar is not None:
            doc_progress_bar.update(1)

    return stats


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


def run_benchmark(
    model_string: str,
    force_rerun: bool = False,
    question_filter: Optional[str] = None,
    dry_run: bool = False,
) -> None:
    """
    Run benchmark scoring for a model across all questions.

    Args:
        model_string: Model in "provider:model" format
        force_rerun: If True, re-score documents even if already scored
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

    # Override the document_scoring task config to use the benchmark model
    # This ensures the scoring agent uses the model specified on the command line
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

    # Get all research questions
    questions = storage.get_unique_research_questions(limit=1000)
    print(f"Found {len(questions)} research questions in database")

    # Apply question filter if specified
    if question_filter:
        filter_terms = [t.strip().lower() for t in question_filter.split(",")]
        filtered = []
        for q in questions:
            if any(term in q.question.lower() for term in filter_terms):
                filtered.append(q)
        questions = filtered
        print(f"Filtered to {len(questions)} questions matching: {question_filter}")

    if not questions:
        print("No questions to process")
        return

    # Create LLM client
    llm_client = LLMClient()

    # Summary statistics
    total_stats = {
        "questions_processed": 0,
        "total_documents": 0,
        "already_scored": 0,
        "newly_scored": 0,
        "failed": 0,
        "total_cost_usd": 0.0,
        "total_latency_ms": 0,
    }

    print()  # Blank line before progress bars

    # Create progress bars
    question_pbar = tqdm(
        questions,
        desc="Questions",
        unit="q",
        position=0,
        leave=True,
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )
    doc_pbar = tqdm(
        total=0,
        desc=f"Scoring [{model_string}]",
        unit="doc",
        position=1,
        leave=False,
        bar_format="{desc}: {percentage:3.0f}%|{bar}| {n_fmt}/{total_fmt} [{elapsed}<{remaining}]",
    )

    # Process each question
    for q_summary in question_pbar:
        question = q_summary.question
        # Truncate question for display
        display_question = question[:60] + "..." if len(question) > 60 else question
        question_pbar.set_description(f"Q: {display_question}")

        # Get documents for this question
        documents = get_documents_for_question(storage, question)

        if dry_run:
            # Check how many would be scored for this question
            already_scored = get_already_scored_doc_ids(
                storage, evaluator.id, [d.id for d in documents], question
            )
            total_stats["total_documents"] += len(documents)
            total_stats["already_scored"] += len(already_scored)
            continue

        # Score documents
        stats = score_documents_for_question(
            storage=storage,
            config=config,
            llm_client=llm_client,
            question=question,
            evaluator=evaluator,
            documents=documents,
            force_rerun=force_rerun,
            model_string=model_string,
            doc_progress_bar=doc_pbar,
        )

        # Update totals
        total_stats["questions_processed"] += 1
        total_stats["total_documents"] += stats["total_documents"]
        total_stats["already_scored"] += stats["already_scored"]
        total_stats["newly_scored"] += stats["newly_scored"]
        total_stats["failed"] += stats["failed"]
        total_stats["total_cost_usd"] += stats["total_cost_usd"]
        total_stats["total_latency_ms"] += stats["total_latency_ms"]

    # Close progress bars
    doc_pbar.close()
    question_pbar.close()

    # Calculate total elapsed time
    elapsed_time = time.time() - start_time

    # Final summary
    print("\n" + "=" * 70)
    print("BENCHMARK SUMMARY")
    print("=" * 70)
    print(f"Model: {model_string}")
    print(f"Evaluator ID: {evaluator.id}")
    print(f"Questions processed: {total_stats['questions_processed']}")
    print(f"Total documents: {total_stats['total_documents']}")
    print(f"Already scored (cached): {total_stats['already_scored']}")
    print(f"Newly scored: {total_stats['newly_scored']}")
    print(f"Failed: {total_stats['failed']}")
    if total_stats["newly_scored"] > 0:
        avg_latency = total_stats["total_latency_ms"] / total_stats["newly_scored"]
        print(f"Average latency: {avg_latency:.0f}ms")
        print(f"Estimated cost: ${total_stats['total_cost_usd']:.4f}")
    print(f"Total time: {format_duration(elapsed_time)}")
    print("=" * 70)


def main() -> None:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        description="Run benchmark scoring for a model across all research questions",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )
    parser.add_argument(
        "model",
        help="Model string in 'provider:model' format (e.g., 'anthropic:claude-sonnet-4-20250514')",
    )
    parser.add_argument(
        "--force-rerun",
        action="store_true",
        help="Re-score documents even if already scored by this evaluator",
    )
    parser.add_argument(
        "--questions",
        type=str,
        help="Comma-separated substrings to filter questions (e.g., 'cancer,treatment')",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Show what would be done without actually scoring",
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
        run_benchmark(
            model_string=args.model,
            force_rerun=args.force_rerun,
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
