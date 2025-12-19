"""
Benchmark runner for comparing evaluator performance.

Orchestrates benchmark execution across multiple evaluators,
with caching of existing evaluations and progress tracking.
"""

import json
import logging
import re
import time
from datetime import datetime
from typing import Callable, Optional

from ..config import LiteConfig
from ..constants import calculate_cost
from ..data_models import (
    BenchmarkRun,
    BenchmarkStatus,
    Evaluator,
    LiteDocument,
    ScoredDocument,
)
from ..llm import LLMClient, LLMMessage
from ..storage import LiteStorage
from .models import BenchmarkResult, DocumentComparison, EvaluatorStats
from .statistics import (
    compute_agreement_matrix,
    compute_document_comparison,
    compute_evaluator_stats,
)

logger = logging.getLogger(__name__)

# System prompt for document scoring (from scoring_agent.py)
SCORING_SYSTEM_PROMPT = """You are a medical research relevance assessor. Your task is to evaluate how relevant a document is to answering a specific research question.

Score each document on a scale of 1-5:
- 5: Directly answers the question with strong evidence
- 4: Highly relevant, provides substantial supporting information
- 3: Moderately relevant, contains useful related information
- 2: Marginally relevant, tangentially related
- 1: Not relevant to the research question

Consider:
- How directly the abstract addresses the research question
- The quality and strength of evidence presented
- The specificity of findings to the question topic
- Whether the document provides actionable information

Respond in JSON format:
{
    "score": <1-5>,
    "explanation": "<brief explanation of relevance>"
}"""


class BenchmarkRunner:
    """
    Orchestrates benchmark execution across multiple evaluators.

    Features:
    - Runs scoring with multiple model evaluators
    - Caches and reuses existing evaluations
    - Tracks progress with callbacks
    - Computes comparison statistics
    - Calculates costs and latency metrics

    Attributes:
        config: Application configuration
        storage: Storage instance for persistence
    """

    def __init__(
        self,
        config: Optional[LiteConfig] = None,
        storage: Optional[LiteStorage] = None,
    ):
        """
        Initialize the benchmark runner.

        Args:
            config: Application configuration
            storage: Storage instance (created if not provided)
        """
        self.config = config or LiteConfig.load()
        self.storage = storage or LiteStorage(self.config)
        self._llm_client: Optional[LLMClient] = None

    @property
    def llm_client(self) -> LLMClient:
        """Get or create LLM client."""
        if self._llm_client is None:
            self._llm_client = LLMClient()
        return self._llm_client

    def create_evaluators_from_models(
        self,
        models: list[str],
        temperature: float = 0.1,
        max_tokens: int = 256,
    ) -> list[Evaluator]:
        """
        Create evaluators from model strings.

        Args:
            models: List of model strings in "provider:model" format
            temperature: Temperature for all evaluators
            max_tokens: Max tokens for all evaluators

        Returns:
            List of Evaluator instances (saved to storage)
        """
        evaluators = []
        for model_str in models:
            if ":" not in model_str:
                logger.warning(f"Invalid model string (missing provider): {model_str}")
                continue

            provider, model_name = model_str.split(":", 1)
            evaluator = Evaluator.from_model_config(
                provider=provider,
                model_name=model_name,
                temperature=temperature,
                max_tokens=max_tokens,
            )
            self.storage.upsert_evaluator(evaluator)
            evaluators.append(evaluator)

        return evaluators

    def create_benchmark(
        self,
        name: str,
        question: str,
        evaluators: list[Evaluator],
        documents: list[LiteDocument],
        task_type: str = "document_scoring",
        description: Optional[str] = None,
    ) -> BenchmarkRun:
        """
        Create a new benchmark run.

        Args:
            name: Name for the benchmark
            question: Research question to evaluate
            evaluators: List of evaluators to compare
            documents: List of documents to evaluate
            task_type: Type of task (default: document_scoring)
            description: Optional description

        Returns:
            Created BenchmarkRun
        """
        # Ensure evaluators are stored
        for evaluator in evaluators:
            self.storage.upsert_evaluator(evaluator)

        # Ensure documents are stored
        for doc in documents:
            self.storage.upsert_document(doc)

        return self.storage.create_benchmark_run(
            name=name,
            question=question,
            task_type=task_type,
            evaluator_ids=[e.id for e in evaluators],
            document_ids=[d.id for d in documents],
            description=description,
        )

    def run_benchmark(
        self,
        run_id: str,
        checkpoint_id: str,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
        reuse_existing: bool = True,
    ) -> BenchmarkResult:
        """
        Execute a benchmark run.

        Args:
            run_id: Benchmark run ID
            checkpoint_id: Checkpoint ID to associate scores with
            progress_callback: Called with (current, total, status_message)
            reuse_existing: If True, reuse cached evaluations

        Returns:
            Complete benchmark results

        Raises:
            ValueError: If benchmark run not found
        """
        run = self.storage.get_benchmark_run(run_id)
        if not run:
            raise ValueError(f"Benchmark run not found: {run_id}")

        # Load evaluators and documents
        evaluators = [
            self.storage.get_evaluator(eid)
            for eid in run.evaluator_ids
        ]
        evaluators = [e for e in evaluators if e is not None]

        documents = [
            self.storage.get_document(did)
            for did in run.document_ids
        ]
        documents = [d for d in documents if d is not None]

        if not evaluators:
            raise ValueError("No valid evaluators found for benchmark")
        if not documents:
            raise ValueError("No valid documents found for benchmark")

        total_ops = len(evaluators) * len(documents)
        current_op = 0

        # Update status to running
        start_time = datetime.now()
        self.storage.update_benchmark_run(
            run_id,
            status=BenchmarkStatus.RUNNING,
            started_at=start_time,
        )

        # Collect scores: evaluator_id -> document_id -> ScoredDocument
        all_scores: dict[str, dict[str, ScoredDocument]] = {}

        try:
            for evaluator in evaluators:
                all_scores[evaluator.id] = {}

                for document in documents:
                    current_op += 1
                    if progress_callback:
                        progress_callback(
                            current_op,
                            total_ops,
                            f"Scoring with {evaluator.display_name}..."
                        )

                    # Update progress
                    self.storage.update_benchmark_run(
                        run_id,
                        progress_current=current_op,
                    )

                    # Check for existing evaluation
                    if reuse_existing:
                        existing = self.storage.get_scored_document_by_evaluator(
                            document_id=document.id,
                            evaluator_id=evaluator.id,
                            checkpoint_id=checkpoint_id,
                        )
                        if existing:
                            logger.debug(
                                f"Reusing existing score for {document.id} "
                                f"by {evaluator.display_name}"
                            )
                            all_scores[evaluator.id][document.id] = existing
                            continue

                    # Run the evaluation
                    scored = self._score_document(
                        document=document,
                        question=run.question,
                        evaluator=evaluator,
                    )
                    all_scores[evaluator.id][document.id] = scored

                    # Store result
                    self.storage.save_scored_document(scored, checkpoint_id)

            # Compute statistics
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()

            result = self._compute_results(
                run_id=run_id,
                question=run.question,
                task_type=run.task_type,
                evaluators=evaluators,
                documents=documents,
                all_scores=all_scores,
                duration=duration,
            )

            # Update run status
            self.storage.update_benchmark_run(
                run_id,
                status=BenchmarkStatus.COMPLETED,
                completed_at=end_time,
                results_summary=result.to_json(),
            )

            logger.info(
                f"Benchmark {run_id} completed: {len(evaluators)} evaluators, "
                f"{len(documents)} documents, {duration:.1f}s"
            )
            return result

        except Exception as e:
            logger.error(f"Benchmark {run_id} failed: {e}")
            self.storage.update_benchmark_run(
                run_id,
                status=BenchmarkStatus.FAILED,
                error_message=str(e),
                completed_at=datetime.now(),
            )
            raise

    def run_quick_benchmark(
        self,
        question: str,
        documents: list[LiteDocument],
        models: list[str],
        checkpoint_id: str,
        name: Optional[str] = None,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
    ) -> BenchmarkResult:
        """
        Convenience method to create and run a benchmark in one call.

        Args:
            question: Research question
            documents: Documents to evaluate
            models: List of model strings ("provider:model")
            checkpoint_id: Checkpoint ID to associate scores with
            name: Optional benchmark name
            progress_callback: Progress callback

        Returns:
            Benchmark results
        """
        # Create evaluators
        evaluators = self.create_evaluators_from_models(models)

        if not evaluators:
            raise ValueError("No valid evaluators could be created")

        # Create benchmark run
        run_name = name or f"Benchmark {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        run = self.create_benchmark(
            name=run_name,
            question=question,
            evaluators=evaluators,
            documents=documents,
        )

        # Execute benchmark
        return self.run_benchmark(
            run_id=run.id,
            checkpoint_id=checkpoint_id,
            progress_callback=progress_callback,
        )

    def _score_document(
        self,
        document: LiteDocument,
        question: str,
        evaluator: Evaluator,
    ) -> ScoredDocument:
        """
        Score a single document using an evaluator.

        Args:
            document: Document to score
            question: Research question
            evaluator: Evaluator to use

        Returns:
            ScoredDocument with score and metrics
        """
        if not evaluator.is_model:
            raise ValueError("Human evaluation not yet supported in runner")

        # Build prompt
        user_prompt = f"""Research Question: {question}

Document Title: {document.title}
Authors: {document.formatted_authors}
Year: {document.year or 'Unknown'}
Journal: {document.journal or 'Unknown'}

Abstract:
{document.abstract}

Evaluate the relevance of this document to the research question."""

        messages = [
            LLMMessage(role="system", content=SCORING_SYSTEM_PROMPT),
            LLMMessage(role="user", content=user_prompt),
        ]

        # Call LLM with timing
        start_time = time.time()
        try:
            response = self.llm_client.chat(
                messages=messages,
                model=evaluator.model_string,
                temperature=evaluator.temperature or 0.1,
                max_tokens=evaluator.max_tokens or 256,
                json_mode=True,
            )
            latency_ms = int((time.time() - start_time) * 1000)

            # Parse response
            score_data = self._parse_score_response(response.content)

            # Calculate cost
            cost = calculate_cost(
                evaluator.model_string or "",
                response.input_tokens,
                response.output_tokens,
            )

            return ScoredDocument(
                document=document,
                score=score_data["score"],
                explanation=score_data["explanation"],
                evaluator_id=evaluator.id,
                evaluator=evaluator,
                latency_ms=latency_ms,
                tokens_input=response.input_tokens,
                tokens_output=response.output_tokens,
                cost_usd=cost,
            )

        except Exception as e:
            logger.error(
                f"Failed to score document {document.id} with "
                f"{evaluator.display_name}: {e}"
            )
            latency_ms = int((time.time() - start_time) * 1000)
            return ScoredDocument(
                document=document,
                score=1,
                explanation=f"Scoring failed: {str(e)}",
                evaluator_id=evaluator.id,
                evaluator=evaluator,
                latency_ms=latency_ms,
            )

    def _parse_score_response(self, response: str) -> dict:
        """
        Parse LLM response to extract score and explanation.

        Args:
            response: LLM response text

        Returns:
            Dictionary with 'score' and 'explanation'
        """
        # Try to parse as JSON
        try:
            json_match = re.search(r'\{[^}]+\}', response, re.DOTALL)
            if json_match:
                data = json.loads(json_match.group())
                score = int(data.get("score", 1))
                score = max(1, min(5, score))  # Clamp to 1-5
                return {
                    "score": score,
                    "explanation": data.get("explanation", ""),
                }
        except (json.JSONDecodeError, ValueError, TypeError):
            pass

        # Fallback: try to extract score from text
        score_match = re.search(r'score[:\s]+(\d)', response, re.IGNORECASE)
        if score_match:
            score = int(score_match.group(1))
            score = max(1, min(5, score))
            return {"score": score, "explanation": response}

        # Default
        logger.warning(f"Could not parse score from: {response[:100]}")
        return {"score": 1, "explanation": "Could not parse response"}

    def _compute_results(
        self,
        run_id: str,
        question: str,
        task_type: str,
        evaluators: list[Evaluator],
        documents: list[LiteDocument],
        all_scores: dict[str, dict[str, ScoredDocument]],
        duration: float,
    ) -> BenchmarkResult:
        """
        Compute benchmark statistics from collected scores.

        Args:
            run_id: Benchmark run ID
            question: Research question
            task_type: Task type
            evaluators: List of evaluators
            documents: List of documents
            all_scores: Nested dict of evaluator_id -> doc_id -> ScoredDocument
            duration: Total execution time in seconds

        Returns:
            Complete BenchmarkResult
        """
        # Compute per-evaluator stats
        evaluator_stats = []
        for evaluator in evaluators:
            scored_docs = list(all_scores.get(evaluator.id, {}).values())
            stats = compute_evaluator_stats(evaluator, scored_docs)
            evaluator_stats.append(stats)

        # Compute document comparisons
        document_comparisons = []
        for doc in documents:
            scored_by_evaluator = {
                eval_id: scores[doc.id]
                for eval_id, scores in all_scores.items()
                if doc.id in scores
            }
            if scored_by_evaluator:
                comparison = compute_document_comparison(
                    document_id=doc.id,
                    document_title=doc.title,
                    scored_by_evaluator=scored_by_evaluator,
                )
                document_comparisons.append(comparison)

        # Compute agreement matrix
        # Build ordered score lists for each evaluator
        doc_ids = [d.id for d in documents]
        evaluator_scores: dict[str, list[int]] = {}
        for evaluator in evaluators:
            scores = []
            for doc_id in doc_ids:
                if doc_id in all_scores.get(evaluator.id, {}):
                    scores.append(all_scores[evaluator.id][doc_id].score)
                else:
                    scores.append(0)  # Missing score
            evaluator_scores[evaluator.id] = scores

        agreement_matrix = compute_agreement_matrix(evaluator_scores, tolerance=1)

        return BenchmarkResult(
            run_id=run_id,
            question=question,
            task_type=task_type,
            evaluator_stats=evaluator_stats,
            document_comparisons=document_comparisons,
            agreement_matrix=agreement_matrix,
            total_duration_seconds=duration,
        )

    def get_benchmark_result(self, run_id: str) -> Optional[BenchmarkResult]:
        """
        Get cached benchmark result from storage.

        Args:
            run_id: Benchmark run ID

        Returns:
            BenchmarkResult if available, None otherwise
        """
        run = self.storage.get_benchmark_run(run_id)
        if not run or not run.results_summary:
            return None

        try:
            # Parse stored JSON result
            data = json.loads(run.results_summary)

            # Reconstruct evaluator stats (without full Evaluator objects)
            evaluator_stats = []
            for stat_data in data.get("evaluator_stats", []):
                # Get evaluator from storage
                evaluator = self.storage.get_evaluator(stat_data["evaluator_id"])
                if evaluator:
                    stats = EvaluatorStats(
                        evaluator=evaluator,
                        scores=stat_data["scores"],
                        mean_score=stat_data["mean_score"],
                        std_dev=stat_data["std_dev"],
                        score_distribution=stat_data["score_distribution"],
                        total_evaluations=stat_data["total_evaluations"],
                        mean_latency_ms=stat_data["mean_latency_ms"],
                        total_tokens_input=stat_data["total_tokens_input"],
                        total_tokens_output=stat_data["total_tokens_output"],
                        total_cost_usd=stat_data["total_cost_usd"],
                    )
                    evaluator_stats.append(stats)

            # Reconstruct document comparisons
            document_comparisons = []
            for comp_data in data.get("document_comparisons", []):
                comparison = DocumentComparison(
                    document_id=comp_data["document_id"],
                    document_title=comp_data["document_title"],
                    scores=comp_data["scores"],
                    explanations=comp_data["explanations"],
                )
                document_comparisons.append(comparison)

            return BenchmarkResult(
                run_id=data["run_id"],
                question=data["question"],
                task_type=data["task_type"],
                evaluator_stats=evaluator_stats,
                document_comparisons=document_comparisons,
                agreement_matrix=data["agreement_matrix"],
                total_duration_seconds=data["total_duration_seconds"],
                created_at=datetime.fromisoformat(data["created_at"]),
            )

        except (json.JSONDecodeError, KeyError) as e:
            logger.error(f"Failed to parse benchmark result: {e}")
            return None
