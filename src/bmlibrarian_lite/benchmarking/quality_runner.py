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
Quality benchmark runner for comparing evaluator performance.

Orchestrates quality benchmark execution across multiple evaluators,
with reuse of the review's own assessments and progress tracking. Supports
both study classification (Tier 2) and detailed quality assessment (Tier 3).
"""

import json
import logging
import re
import time
from dataclasses import replace
from datetime import datetime
from typing import Any, Callable, Optional

from ..chunking import analysis_windows
from ..config import LiteConfig
from ..constants import (
    calculate_cost,
    CONFIDENCE_PARSE_FAILURE_DEFAULT,
    QUALITY_LLM_TEMPERATURE,
    QUALITY_CLASSIFIER_MAX_TOKENS,
    QUALITY_ASSESSOR_MAX_TOKENS,
)
from ..data_models import (
    BenchmarkRun,
    BenchmarkStatus,
    EvaluationErrorCode,
    Evaluator,
    LiteDocument,
)
from ..llm import LLMClient, LLMMessage
from ..llm.data_types import STOP_REASON_MAX_TOKENS
from ..quality.data_models import (
    BiasRisk,
    CLASSIFIER_ASSESSMENT_TIER,
    DETAILED_ASSESSMENT_TIER,
    QualityAssessment,
    StudyDesign,
    QualityTier,
    DESIGN_TO_TIER,
    DESIGN_TO_SCORE,
    llm_extraction_method,
)
from ..quality.json_fields import (
    as_bool,
    as_dict,
    as_float,
    as_int,
    as_str_list,
    as_text,
)
from ..quality.study_classifier import stated_study_design
from ..quality.window_reduce import reduce_by_design_vote
from ..storage import LiteStorage
from ..utils import classify_analysis_exception
from .models import BenchmarkCancellation
from .quality_models import (
    QualityBenchmarkResult,
    QualityEvaluation,
    QUALITY_TASK_STUDY_CLASSIFICATION,
    QUALITY_TASK_QUALITY_ASSESSMENT,
)
from .quality_statistics import (
    compute_design_agreement_matrix,
    compute_quality_document_comparison,
    compute_quality_evaluator_stats,
    compute_tier_agreement_matrix,
)

logger = logging.getLogger(__name__)

#: The assessment tier each benchmark task produces.
TASK_ASSESSMENT_TIER: dict[str, int] = {
    QUALITY_TASK_STUDY_CLASSIFICATION: CLASSIFIER_ASSESSMENT_TIER,
    QUALITY_TASK_QUALITY_ASSESSMENT: DETAILED_ASSESSMENT_TIER,
}


def is_reusable_assessment(
    assessment: QualityAssessment,
    task_type: str,
    model_string: str | None,
) -> bool:
    """Whether a review's assessment can stand as an evaluator's answer.

    Only an assessment that evaluator's model made, for the task
    benchmarked, answers for it -- as the review stored it, before any
    transparency downgrade changed its tier. The review's quality filter
    records a failed call as an "unknown" design (with no classifier call
    at all, as "unclassified"), and a design read from PubMed's publication
    types is no model's answer: replayed, each was counted as the baseline
    model's verdict (#314). An assessment that names no model, or another
    one, is asked again rather than credited to this one.

    Args:
        assessment: The review's assessment of a document.
        task_type: The benchmark's task.
        model_string: The evaluator's model, as "provider:model"; None for
            a human evaluator, who made no assessment of the review.

    Returns:
        True when the assessment is of the task's tier, names a design, was
        made by this model, and is as the model gave it.
    """
    return (
        model_string is not None
        and assessment.assessment_tier == TASK_ASSESSMENT_TIER.get(task_type)
        and assessment.study_design is not StudyDesign.UNKNOWN
        and assessment.extraction_method == llm_extraction_method(model_string)
        and not assessment.transparency_adjusted
    )


def parse_study_design(data: object) -> StudyDesign | None:
    """The study design an answer states, if it states one.

    Args:
        data: The answer, decoded from JSON.

    Returns:
        The design, or None when the answer is not an object, or names no
        design the classifier's mapping recognises -- "unknown" excluded:
        no prompt offers it, and read as a design, an unreadable answer
        became the model's verdict that it could not tell (#314).
    """
    if not isinstance(data, dict):
        return None
    return stated_study_design(data.get("study_design"), "study_design")


# System prompt for study classification (Tier 2 style)
CLASSIFICATION_SYSTEM_PROMPT = """You are a biomedical research classifier.
Your task is to classify the study design of research papers.

CRITICAL RULES:
1. Classify what THIS paper reports, NOT studies it references
2. Look for phrases like "we conducted", "this study", "our trial", "we analyzed"
3. Ignore phrases like "previous studies", "Smith et al. reported", "unlike RCTs"
4. If uncertain, return "other" with low confidence
5. Return ONLY valid JSON, no explanation"""


# System prompt for detailed quality assessment (Tier 3 style)
ASSESSMENT_SYSTEM_PROMPT = """You are a research quality assessment expert.
Evaluate the methodological quality of biomedical research papers.

CRITICAL RULES:
1. Extract ONLY information that is ACTUALLY PRESENT in the text
2. DO NOT invent, assume, or fabricate any information
3. If information is unclear or not mentioned, use null or "unclear"
4. Focus on THIS study's methodology, not studies it references
5. Return ONLY valid JSON, no explanation"""


class QualityBenchmarkRunner:
    """
    Orchestrates quality benchmark execution across multiple evaluators.

    Features:
    - Runs quality assessment with multiple model evaluators
    - Supports study classification (Tier 2) and detailed assessment (Tier 3)
    - Reuses the review's own assessments for the baseline model
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
        Initialize the quality benchmark runner.

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
        temperature: float = QUALITY_LLM_TEMPERATURE,
        max_tokens: int = QUALITY_CLASSIFIER_MAX_TOKENS,
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
        task_type: str = QUALITY_TASK_STUDY_CLASSIFICATION,
        description: Optional[str] = None,
    ) -> BenchmarkRun:
        """
        Create a new quality benchmark run.

        Args:
            name: Name for the benchmark
            question: Research question (for context)
            evaluators: List of evaluators to compare
            documents: List of documents to evaluate
            task_type: "study_classification" or "quality_assessment"
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
        existing_assessments: Optional[dict[str, QualityAssessment]] = None,
        reuse_cross_run: bool = True,
        should_cancel: Callable[[], bool] | None = None,
    ) -> QualityBenchmarkResult:
        """
        Execute a quality benchmark run.

        Args:
            run_id: Benchmark run ID
            checkpoint_id: Checkpoint ID to associate assessments with
            progress_callback: Called with (current, total, status_message)
            reuse_existing: Accepted for parity with the relevance benchmark,
                and ignored: reuse is of ``existing_assessments`` alone
            existing_assessments: Pre-existing assessments to reuse (doc_id -> assessment),
                for the baseline model only and only where
                :func:`is_reusable_assessment` allows
            reuse_cross_run: Accepted for parity with the relevance benchmark,
                and ignored: the quality benchmark stores no per-document
                evaluations, so there is nothing from earlier runs to reuse
            should_cancel: Asked before each evaluation, and the run stops at
                the first True -- before the call that evaluation would pay
                for. Until #324 the runner was given no way to see a cancel:
                it went on calling every model for every document, spending,
                and the caller threw the finished result away.

        Returns:
            Complete quality benchmark results. A run a cancel stopped
            carries a
            :class:`~bmlibrarian_lite.benchmarking.models.BenchmarkCancellation`
            and holds only what it evaluated, which is real and is kept.

        Raises:
            ValueError: If benchmark run not found
        """
        run = self.storage.get_benchmark_run(run_id)
        if not run:
            raise ValueError(f"Benchmark run not found: {run_id}")

        # Load evaluators and documents
        evaluators = [
            self.storage.get_evaluator(eid) for eid in run.evaluator_ids
        ]
        evaluators = [e for e in evaluators if e is not None]

        documents = [
            self.storage.get_document(did) for did in run.document_ids
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

        # Build lookup for existing assessments by document ID
        existing_map: dict[str, QualityAssessment] = existing_assessments or {}
        if existing_map:
            logger.info(f"Loaded {len(existing_map)} existing assessments for reuse")

        # Collect evaluations: evaluator_id -> document_id -> QualityEvaluation
        all_evaluations: dict[str, dict[str, QualityEvaluation]] = {}

        cancelled = False

        try:
            for evaluator in evaluators:
                if cancelled:
                    break
                all_evaluations[evaluator.id] = {}

                for document in documents:
                    # Asked before the evaluation, so a cancel stops the run
                    # before it pays for one more (#324)
                    if should_cancel is not None and should_cancel():
                        cancelled = True
                        break

                    current_op += 1
                    if progress_callback:
                        progress_callback(
                            current_op,
                            total_ops,
                            f"Assessing with {evaluator.display_name}...",
                        )

                    # Update progress
                    self.storage.update_benchmark_run(
                        run_id,
                        progress_current=current_op,
                    )

                    # The review's own assessment, where this evaluator's
                    # model made it for this task
                    existing = existing_map.get(document.id)
                    if existing is not None and is_reusable_assessment(
                        existing, run.task_type, evaluator.model_string
                    ):
                        logger.debug(
                            f"Reusing initial assessment for {document.id} "
                            f"(baseline model: {evaluator.display_name})"
                        )
                        evaluation = QualityEvaluation(
                            document_id=document.id,
                            evaluator=evaluator,
                            assessment=existing,
                            reused=True,
                        )
                        all_evaluations[evaluator.id][document.id] = evaluation
                        continue

                    # Run the evaluation based on task type
                    if run.task_type == QUALITY_TASK_QUALITY_ASSESSMENT:
                        evaluation = self._assess_document(
                            document=document,
                            evaluator=evaluator,
                        )
                    else:
                        # Default to study classification
                        evaluation = self._classify_document(
                            document=document,
                            evaluator=evaluator,
                        )
                    all_evaluations[evaluator.id][document.id] = evaluation

            # Compute statistics
            end_time = datetime.now()
            duration = (end_time - start_time).total_seconds()

            cancellation = (
                BenchmarkCancellation(
                    evaluations_made=sum(
                        len(e) for e in all_evaluations.values()
                    ),
                    evaluations_planned=total_ops,
                )
                if cancelled
                else None
            )

            result = self._compute_results(
                run_id=run_id,
                question=run.question,
                task_type=run.task_type,
                evaluators=evaluators,
                documents=documents,
                all_evaluations=all_evaluations,
                duration=duration,
                cancellation=cancellation,
            )

            # A cancelled run is stored as cancelled, never as complete: its
            # comparisons are over the part that ran (#324)
            self.storage.update_benchmark_run(
                run_id,
                status=(
                    BenchmarkStatus.CANCELLED if cancelled
                    else BenchmarkStatus.COMPLETED
                ),
                completed_at=end_time,
                results_summary=result.to_json(),
            )

            if cancellation is not None:
                logger.info(
                    f"Quality benchmark {run_id} cancelled after "
                    f"{cancellation.evaluations_made} of "
                    f"{cancellation.evaluations_planned} evaluations, "
                    f"{duration:.1f}s"
                )
            else:
                logger.info(
                    f"Quality benchmark {run_id} completed: {len(evaluators)} evaluators, "
                    f"{len(documents)} documents, {duration:.1f}s"
                )
            return result

        except Exception as e:
            logger.error(f"Quality benchmark {run_id} failed: {e}")
            # A crash after a cancel is still a cancelled run. Stored FAILED,
            # its evaluations fell outside get_all_scores_for_question, so the
            # user paid a second time for what the cancel had already bought
            # -- the very harm #324 exists to prevent (#329 review). The error
            # is kept either way: cancelling is not failing, but a failure is
            # never hidden (golden rule 8).
            self.storage.update_benchmark_run(
                run_id,
                status=(
                    BenchmarkStatus.CANCELLED if cancelled
                    else BenchmarkStatus.FAILED
                ),
                error_message=str(e),
                completed_at=datetime.now(),
            )
            raise

    def run_quick_benchmark(
        self,
        question: str,
        documents: list[LiteDocument],
        models: list[str],
        task_type: str = QUALITY_TASK_STUDY_CLASSIFICATION,
        checkpoint_id: Optional[str] = None,
        name: Optional[str] = None,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
        existing_assessments: Optional[dict[str, QualityAssessment]] = None,
        reuse_cross_run: bool = True,
        should_cancel: Callable[[], bool] | None = None,
    ) -> QualityBenchmarkResult:
        """
        Convenience method to create and run a quality benchmark in one call.

        Args:
            question: Research question (for context)
            documents: Documents to evaluate
            models: List of model strings ("provider:model")
            task_type: "study_classification" or "quality_assessment"
            checkpoint_id: Checkpoint ID (created if not provided)
            name: Optional benchmark name
            progress_callback: Progress callback
            existing_assessments: Pre-existing assessments for baseline model
            reuse_cross_run: Ignored; see :meth:`run_benchmark`
            should_cancel: Asked before each evaluation; see
                :meth:`run_benchmark`

        Returns:
            Quality benchmark results
        """
        # Determine max tokens based on task type
        max_tokens = (
            QUALITY_ASSESSOR_MAX_TOKENS
            if task_type == QUALITY_TASK_QUALITY_ASSESSMENT
            else QUALITY_CLASSIFIER_MAX_TOKENS
        )

        # Create a checkpoint if not provided
        if checkpoint_id is None:
            checkpoint = self.storage.create_checkpoint(
                research_question=question,
                metadata={"type": "quality_benchmark", "task_type": task_type, "models": models},
            )
            checkpoint_id = checkpoint.id
            logger.info(f"Created quality benchmark checkpoint {checkpoint_id}")

        # Create evaluators
        evaluators = self.create_evaluators_from_models(
            models, max_tokens=max_tokens
        )

        if not evaluators:
            raise ValueError("No valid evaluators could be created")

        # Create benchmark run
        run_name = name or f"Quality Benchmark {datetime.now().strftime('%Y-%m-%d %H:%M')}"
        run = self.create_benchmark(
            name=run_name,
            question=question,
            evaluators=evaluators,
            documents=documents,
            task_type=task_type,
        )

        # Execute benchmark
        return self.run_benchmark(
            run_id=run.id,
            checkpoint_id=checkpoint_id,
            progress_callback=progress_callback,
            existing_assessments=existing_assessments,
            reuse_cross_run=reuse_cross_run,
            should_cancel=should_cancel,
        )

    def _classify_document(
        self,
        document: LiteDocument,
        evaluator: Evaluator,
    ) -> QualityEvaluation:
        """
        Classify study design for a single document using an evaluator.

        Args:
            document: Document to classify
            evaluator: Evaluator to use

        Returns:
            QualityEvaluation with classification results
        """
        if not evaluator.is_model:
            raise ValueError("Human evaluation not yet supported in runner")

        title = document.title or "Untitled"
        windows = analysis_windows(document.abstract or "") or [""]
        return self._evaluate_windows(
            document,
            evaluator,
            [
                [
                    LLMMessage(role="system", content=CLASSIFICATION_SYSTEM_PROMPT),
                    LLMMessage(role="user", content=self._classification_prompt(
                        title, window, i, len(windows))),
                ]
                for i, window in enumerate(windows, start=1)
            ],
            QUALITY_CLASSIFIER_MAX_TOKENS,
            self._parse_classification_response,
        )

    @staticmethod
    def _classification_prompt(title: str, abstract: str, part: int, parts: int) -> str:
        """The prompt classifying one window of a paper's abstract.

        Args:
            title: The paper's title.
            abstract: The window's text.
            part: Which window, from 1.
            parts: How many windows the abstract has.

        Returns:
            The user prompt.
        """
        section = f" (section {part} of {parts})" if parts > 1 else ""
        return f"""Classify THIS paper's study design:

Title: {title}
Abstract{section}: {abstract}

Return JSON:
{{
    "study_design": "systematic_review|meta_analysis|rct|cohort_prospective|cohort_retrospective|case_control|cross_sectional|case_series|case_report|editorial|letter|guideline|other",
    "is_randomized": true|false|null,
    "is_blinded": "none"|"single"|"double"|"triple"|null,
    "sample_size": <number or null>,
    "confidence": <0.0 to 1.0>
}}

IMPORTANT: Classify what THIS study did, not studies it references."""

    def _assess_document(
        self,
        document: LiteDocument,
        evaluator: Evaluator,
    ) -> QualityEvaluation:
        """
        Perform detailed quality assessment for a single document.

        Args:
            document: Document to assess
            evaluator: Evaluator to use

        Returns:
            QualityEvaluation with detailed assessment
        """
        if not evaluator.is_model:
            raise ValueError("Human evaluation not yet supported in runner")

        title = document.title or "Untitled"
        windows = analysis_windows(document.abstract or "") or [""]
        return self._evaluate_windows(
            document,
            evaluator,
            [
                [
                    LLMMessage(role="system", content=ASSESSMENT_SYSTEM_PROMPT),
                    LLMMessage(role="user", content=self._assessment_prompt(
                        title, window, i, len(windows))),
                ]
                for i, window in enumerate(windows, start=1)
            ],
            QUALITY_ASSESSOR_MAX_TOKENS,
            self._parse_assessment_response,
        )

    @staticmethod
    def _assessment_prompt(title: str, abstract: str, part: int, parts: int) -> str:
        """The prompt assessing one window of a paper's abstract.

        Args:
            title: The paper's title.
            abstract: The window's text.
            part: Which window, from 1.
            parts: How many windows the abstract has.

        Returns:
            The user prompt.
        """
        section = f" (section {part} of {parts})" if parts > 1 else ""
        return f"""Assess this research paper's methodological quality:

Title: {title}
Abstract{section}: {abstract}

Return JSON:
{{
    "study_design": "systematic_review|meta_analysis|rct|cohort_prospective|cohort_retrospective|case_control|cross_sectional|case_series|case_report|editorial|letter|guideline|other",
    "quality_score": <1-10>,
    "evidence_level": "1a|1b|2a|2b|3a|3b|4|5|null",
    "design_characteristics": {{
        "randomized": true|false|null,
        "controlled": true|false|null,
        "blinded": "none"|"single"|"double"|"triple"|null,
        "prospective": true|false|null,
        "multicenter": true|false|null
    }},
    "sample_size": <number or null>,
    "bias_risk": {{
        "selection": "low"|"unclear"|"high",
        "performance": "low"|"unclear"|"high",
        "detection": "low"|"unclear"|"high",
        "attrition": "low"|"unclear"|"high",
        "reporting": "low"|"unclear"|"high"
    }},
    "strengths": ["2-3 methodological strengths"],
    "limitations": ["2-3 methodological limitations"],
    "confidence": <0.0 to 1.0>
}}

Focus on THIS study's methodology, not studies it references."""

    def _evaluate_windows(
        self,
        document: LiteDocument,
        evaluator: Evaluator,
        prompts: list[list[LLMMessage]],
        max_tokens: int,
        parse: Callable[[str], QualityAssessment | EvaluationErrorCode],
    ) -> QualityEvaluation:
        """Evaluate a paper window by window, and reduce the answers to one.

        A window that fails fails the paper, and no later window is asked: an
        assessment of part of the abstract is not the paper's. Every call made
        is counted in the latency, tokens and cost.

        Args:
            document: Document to assess
            evaluator: Evaluator to use
            prompts: One prompt per window
            max_tokens: Token limit when the evaluator sets none
            parse: Reads one answer

        Returns:
            The evaluation: the windows' answers reduced by
            :func:`reduce_by_design_vote`, or the first window's failure.
        """
        done: list[QualityEvaluation] = []
        for messages in prompts:
            done.append(self._evaluate(document, evaluator, messages, max_tokens, parse))
            if done[-1].failure is not None:
                break
        if len(done) == 1:
            return done[0]
        failed = done[-1].failure is not None
        answers = [e.assessment for e in done if e.assessment is not None]
        return replace(
            done[-1] if failed else done[0],
            assessment=None if failed else reduce_by_design_vote(answers),
            latency_ms=sum(e.latency_ms for e in done),
            tokens_input=sum(e.tokens_input for e in done),
            tokens_output=sum(e.tokens_output for e in done),
            cost_usd=sum(e.cost_usd for e in done),
        )

    def _evaluate(
        self,
        document: LiteDocument,
        evaluator: Evaluator,
        messages: list[LLMMessage],
        max_tokens: int,
        parse: Callable[[str], QualityAssessment | EvaluationErrorCode],
    ) -> QualityEvaluation:
        """Ask an evaluator for its assessment, recording a failure as one.

        A failed call, and an answer that names no design, are recorded as
        their error code -- never as an "unclassified" assessment, which is
        what a model that read the abstract and could not tell the design
        answers (#314). The provider's text stays in the log: it can print
        the request, and the result is shown to the user.

        Args:
            document: Document to assess
            evaluator: Evaluator to use
            messages: The prompt
            max_tokens: Token limit when the evaluator sets none
            parse: Reads the answer: the assessment, or why it holds none

        Returns:
            QualityEvaluation with the assessment, or the failure
        """
        start_time = time.time()
        try:
            response = self.llm_client.chat(
                messages=messages,
                model=evaluator.model_string,
                temperature=evaluator.temperature or QUALITY_LLM_TEMPERATURE,
                max_tokens=evaluator.max_tokens or max_tokens,
                json_mode=True,
            )
        except Exception as e:
            error_code = classify_analysis_exception(e)
            logger.error(
                f"Failed to assess document {document.id} with "
                f"{evaluator.display_name} ({error_code.name}): {e}"
            )
            return QualityEvaluation(
                document_id=document.id,
                evaluator=evaluator,
                failure=error_code,
                latency_ms=int((time.time() - start_time) * 1000),
            )
        latency_ms = int((time.time() - start_time) * 1000)

        # The call was made and billed whether or not its answer is usable
        cost = calculate_cost(
            evaluator.model_string or "",
            response.input_tokens,
            response.output_tokens,
        )

        # As the review's _chat records it: what a cut-off answer holds is not its verdict
        if response.stop_reason == STOP_REASON_MAX_TOKENS:
            parsed: QualityAssessment | EvaluationErrorCode = EvaluationErrorCode.RESPONSE_TOO_LARGE
        else:
            # One answer the parser did not foresee is that document's failure,
            # not the end of the whole run
            try:
                parsed = parse(response.content)
            except Exception:
                logger.exception(
                    f"Unexpected error reading {evaluator.display_name}'s "
                    f"assessment of document {document.id}"
                )
                parsed = EvaluationErrorCode.INVALID_RESPONSE_FORMAT
        if isinstance(parsed, EvaluationErrorCode):
            logger.warning(
                f"{evaluator.display_name} gave no readable assessment of "
                f"document {document.id} ({parsed.name})"
            )
            assessment, failure = None, parsed
        else:
            assessment, failure = parsed, None
        return QualityEvaluation(
            document_id=document.id,
            evaluator=evaluator,
            assessment=assessment,
            failure=failure,
            latency_ms=latency_ms,
            tokens_input=response.input_tokens,
            tokens_output=response.output_tokens,
            cost_usd=cost,
        )

    def _read_answer(
        self, response: str
    ) -> tuple[dict[str, Any], StudyDesign] | EvaluationErrorCode:
        """The JSON object an answer holds, and the design it names.

        Args:
            response: LLM response text

        Returns:
            The decoded object and its design, or why there is none: EMPTY_RESPONSE for
            nothing, JSON_PARSE_ERROR for text holding no JSON, and
            INVALID_RESPONSE_FORMAT for JSON naming no study design -- a
            well-formed answer is not reported as unreadable.
        """
        if not response or not response.strip():
            return EvaluationErrorCode.EMPTY_RESPONSE
        cleaned = self._clean_json_response(response)
        if not cleaned:
            return EvaluationErrorCode.JSON_PARSE_ERROR
        try:
            data = json.loads(cleaned)
        except ValueError as e:
            # A JSONDecodeError, or the plain ValueError json.loads raises
            # for an integer longer than sys.get_int_max_str_digits()
            logger.warning(f"Failed to parse benchmark answer as JSON: {e}")
            return EvaluationErrorCode.JSON_PARSE_ERROR
        study_design = parse_study_design(data)
        if study_design is None:
            return EvaluationErrorCode.INVALID_RESPONSE_FORMAT
        return data, study_design

    def _parse_classification_response(
        self, response: str
    ) -> QualityAssessment | EvaluationErrorCode:
        """
        Parse classification response into QualityAssessment.

        Args:
            response: LLM response text

        Returns:
            QualityAssessment (Tier 2 style), or why the answer holds none
        """
        answer = self._read_answer(response)
        if isinstance(answer, EvaluationErrorCode):
            return answer
        data, study_design = answer
        # Every value is narrowed as the classifier narrows it (bmlib#295,
        # bmlib#320): a null or wrong-typed answer reads as unstated, and a
        # well-formed answer naming a design is never an unreadable one.
        return QualityAssessment(
            assessment_tier=CLASSIFIER_ASSESSMENT_TIER,
            extraction_method="llm_benchmark",
            study_design=study_design,
            quality_tier=DESIGN_TO_TIER.get(study_design, QualityTier.UNCLASSIFIED),
            quality_score=DESIGN_TO_SCORE.get(study_design, 0.0),
            is_randomized=as_bool(data.get("is_randomized"), "is_randomized"),
            is_blinded=self._parse_blinding(data.get("is_blinded")),
            sample_size=self._parse_sample_size(data.get("sample_size")),
            confidence=self._parse_confidence(data.get("confidence")),
            extraction_details=["Benchmark classification"],
        )

    def _parse_assessment_response(
        self, response: str
    ) -> QualityAssessment | EvaluationErrorCode:
        """
        Parse detailed assessment response into QualityAssessment.

        Args:
            response: LLM response text

        Returns:
            QualityAssessment (Tier 3 style), or why the answer holds none
        """
        answer = self._read_answer(response)
        if isinstance(answer, EvaluationErrorCode):
            return answer
        data, study_design = answer
        # Every value is narrowed as the Tier 3 assessor narrows it
        # (bmlib#295, bmlib#320): a null design_characteristics raised
        # AttributeError here, and a well-formed answer naming a design was
        # scored as INVALID_RESPONSE_FORMAT.
        chars = as_dict(data.get("design_characteristics"), "design_characteristics")
        bias_data = as_dict(data.get("bias_risk"), "bias_risk")
        return QualityAssessment(
            assessment_tier=DETAILED_ASSESSMENT_TIER,
            extraction_method="llm_benchmark_detailed",
            study_design=study_design,
            quality_tier=DESIGN_TO_TIER.get(study_design, QualityTier.UNCLASSIFIED),
            quality_score=self._parse_quality_score(data.get("quality_score")),
            evidence_level=as_text(data.get("evidence_level"), "evidence_level"),
            is_randomized=as_bool(chars.get("randomized"), "randomized"),
            is_controlled=as_bool(chars.get("controlled"), "controlled"),
            is_blinded=self._parse_blinding(chars.get("blinded")),
            is_prospective=as_bool(chars.get("prospective"), "prospective"),
            is_multicenter=as_bool(chars.get("multicenter"), "multicenter"),
            sample_size=self._parse_sample_size(data.get("sample_size")),
            confidence=self._parse_confidence(data.get("confidence")),
            bias_risk=BiasRisk.from_dict(bias_data) if bias_data else None,
            strengths=as_str_list(data.get("strengths"), "strengths") or [],
            limitations=as_str_list(data.get("limitations"), "limitations") or [],
            extraction_details=["Benchmark detailed assessment"],
        )

    def _clean_json_response(self, response: str) -> str:
        """
        Clean LLM response by extracting JSON content.

        Args:
            response: Raw response string

        Returns:
            Cleaned JSON string
        """
        if not response:
            return ""

        cleaned = response.strip()

        # If it starts with { or [, it's likely already JSON
        if cleaned.startswith("{") or cleaned.startswith("["):
            return cleaned

        # Extract from markdown code blocks
        if "```" in cleaned:
            parts = cleaned.split("```")
            for part in parts:
                part = part.strip()
                if part.startswith("json"):
                    part = part[4:].strip()
                elif part.startswith("JSON"):
                    part = part[4:].strip()
                if part.startswith("{") or part.startswith("["):
                    return part

        # Find JSON object using regex
        json_match = re.search(r'\{[^{}]*(?:\{[^{}]*\}[^{}]*)*\}', cleaned)
        if json_match:
            return json_match.group(0)

        # More aggressive - find first { and last }
        first_brace = cleaned.find("{")
        last_brace = cleaned.rfind("}")
        if first_brace != -1 and last_brace > first_brace:
            return cleaned[first_brace:last_brace + 1]

        return ""

    def _parse_blinding(self, value: object) -> Optional[str]:
        """Parse and validate blinding value; a non-string is unstated."""
        text = as_text(value, "blinded")
        if text is None:
            return None
        normalized = text.lower().strip()
        valid_values = ("none", "single", "double", "triple")
        return normalized if normalized in valid_values else None

    def _parse_sample_size(self, value: object) -> Optional[int]:
        """Parse sample size to integer.

        A bool is no count (``int(True)`` is 1), an infinity is no number,
        and a negative count is none, as the quality tiers read them.
        """
        result = as_int(value, "sample_size")
        if result is None or result < 0:
            return None
        return result

    def _parse_quality_score(self, value: object) -> float:
        """Parse and clamp quality score; unstated or non-finite is 0.0.

        NaN would clamp to the top of the scale, and ``true`` read as 1.0.
        """
        score = as_float(value, "quality_score")
        if score is None:
            return 0.0
        return max(0.0, min(10.0, score))

    def _parse_confidence(self, value: object) -> float:
        """Parse and clamp confidence value.

        Unstated, a bool and anything non-finite read as
        CONFIDENCE_PARSE_FAILURE_DEFAULT, as both quality tiers read them:
        ``true`` was 1.0, the most confident answer there is, NaN clamped
        to it, and the statistics averaged it.
        """
        conf = as_float(value, "confidence")
        if conf is None:
            return CONFIDENCE_PARSE_FAILURE_DEFAULT
        return max(0.0, min(1.0, conf))

    def _compute_results(
        self,
        run_id: str,
        question: str,
        task_type: str,
        evaluators: list[Evaluator],
        documents: list[LiteDocument],
        all_evaluations: dict[str, dict[str, QualityEvaluation]],
        duration: float,
        cancellation: BenchmarkCancellation | None = None,
    ) -> QualityBenchmarkResult:
        """
        Compute quality benchmark statistics from collected evaluations.

        Args:
            run_id: Benchmark run ID
            question: Research question
            task_type: Task type
            evaluators: List of evaluators
            documents: List of documents
            all_evaluations: Nested dict of evaluator_id -> doc_id -> QualityEvaluation
            duration: Total execution time in seconds
            cancellation: What the run had evaluated when a cancel stopped
                it, or None for a run that reached the end

        Returns:
            Complete QualityBenchmarkResult
        """
        # Compute per-evaluator stats
        evaluator_stats = []
        for evaluator in evaluators:
            evals = list(all_evaluations.get(evaluator.id, {}).values())
            stats = compute_quality_evaluator_stats(evaluator, evals)
            evaluator_stats.append(stats)

        # Compute document comparisons using display names
        document_comparisons = []
        for doc in documents:
            evals_by_name = {}
            for evaluator in evaluators:
                if doc.id in all_evaluations.get(evaluator.id, {}):
                    evals_by_name[evaluator.display_name] = (
                        all_evaluations[evaluator.id][doc.id]
                    )
            if evals_by_name:
                comparison = compute_quality_document_comparison(
                    document=doc,
                    evaluations_by_evaluator=evals_by_name,
                )
                document_comparisons.append(comparison)

        # Compute agreement matrices using display names
        doc_ids = [d.id for d in documents]

        # Agreement is over the documents both evaluators assessed: a
        # document with no assessment -- a failure, or never asked -- is
        # None, never "unknown", which compared as a disagreement (#314)
        evaluator_designs: dict[str, list[StudyDesign | None]] = {}
        evaluator_tiers: dict[str, list[QualityTier | None]] = {}
        for evaluator in evaluators:
            by_document = all_evaluations.get(evaluator.id, {})
            evaluations = [by_document.get(doc_id) for doc_id in doc_ids]
            evaluator_designs[evaluator.display_name] = [
                e.study_design if e is not None else None for e in evaluations
            ]
            evaluator_tiers[evaluator.display_name] = [
                e.quality_tier if e is not None else None for e in evaluations
            ]

        design_agreement_matrix = compute_design_agreement_matrix(evaluator_designs)

        tier_agreement_matrix = compute_tier_agreement_matrix(
            evaluator_tiers, tolerance=1
        )

        # The baseline is the model the review used for this task
        baseline_name = None
        baseline_model = self.config.models.get_model_string(task_type)
        if baseline_model:
            for evaluator in evaluators:
                if evaluator.model_string == baseline_model:
                    baseline_name = evaluator.display_name
                    break

        return QualityBenchmarkResult(
            run_id=run_id,
            question=question,
            task_type=task_type,
            evaluator_stats=evaluator_stats,
            document_comparisons=document_comparisons,
            design_agreement_matrix=design_agreement_matrix,
            tier_agreement_matrix=tier_agreement_matrix,
            total_duration_seconds=duration,
            baseline_evaluator_name=baseline_name,
            cancellation=cancellation,
        )
