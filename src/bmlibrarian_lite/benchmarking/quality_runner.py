"""
Quality benchmark runner for comparing evaluator performance.

Orchestrates quality benchmark execution across multiple evaluators,
with caching of existing evaluations and progress tracking. Supports
both study classification (Tier 2) and detailed quality assessment (Tier 3).
"""

import json
import logging
import re
import time
from datetime import datetime
from typing import Callable, Optional

from ..config import LiteConfig
from ..constants import (
    calculate_cost,
    QUALITY_LLM_TEMPERATURE,
    QUALITY_CLASSIFIER_MAX_TOKENS,
    QUALITY_ASSESSOR_MAX_TOKENS,
)
from ..data_models import (
    BenchmarkRun,
    BenchmarkStatus,
    Evaluator,
    LiteDocument,
)
from ..llm import LLMClient, LLMMessage
from ..quality.data_models import (
    QualityAssessment,
    StudyDesign,
    QualityTier,
    StudyClassification,
    DESIGN_TO_TIER,
    DESIGN_TO_SCORE,
)
from ..quality.study_classifier import STUDY_DESIGN_MAPPING
from ..storage import LiteStorage
from .quality_models import (
    QualityBenchmarkResult,
    QualityDocumentComparison,
    QualityEvaluatorStats,
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
    ) -> QualityBenchmarkResult:
        """
        Execute a quality benchmark run.

        Args:
            run_id: Benchmark run ID
            checkpoint_id: Checkpoint ID to associate assessments with
            progress_callback: Called with (current, total, status_message)
            reuse_existing: If True, reuse cached evaluations from this run
            existing_assessments: Pre-existing assessments to reuse (doc_id -> assessment)
            reuse_cross_run: If True, reuse from previous runs of same question

        Returns:
            Complete quality benchmark results

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

        # Get the baseline model string (the model used for initial assessment)
        baseline_model = self.config.models.get_model_string("study_classification")
        logger.debug(f"Baseline model for quality assessment: {baseline_model}")

        # Collect evaluations: evaluator_id -> document_id -> QualityEvaluation
        all_evaluations: dict[str, dict[str, QualityEvaluation]] = {}

        try:
            for evaluator in evaluators:
                all_evaluations[evaluator.id] = {}

                for document in documents:
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

                    # Check for existing assessment from initial run
                    # if this evaluator matches the baseline model
                    if existing_map and evaluator.model_string == baseline_model:
                        if document.id in existing_map:
                            existing = existing_map[document.id]
                            logger.debug(
                                f"Reusing initial assessment for {document.id} "
                                f"(baseline model: {evaluator.display_name})"
                            )
                            evaluation = QualityEvaluation(
                                document_id=document.id,
                                evaluator=evaluator,
                                assessment=existing,
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

            result = self._compute_results(
                run_id=run_id,
                question=run.question,
                task_type=run.task_type,
                evaluators=evaluators,
                documents=documents,
                all_evaluations=all_evaluations,
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
                f"Quality benchmark {run_id} completed: {len(evaluators)} evaluators, "
                f"{len(documents)} documents, {duration:.1f}s"
            )
            return result

        except Exception as e:
            logger.error(f"Quality benchmark {run_id} failed: {e}")
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
        task_type: str = QUALITY_TASK_STUDY_CLASSIFICATION,
        checkpoint_id: Optional[str] = None,
        name: Optional[str] = None,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
        existing_assessments: Optional[dict[str, QualityAssessment]] = None,
        reuse_cross_run: bool = True,
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
            reuse_cross_run: If True, reuse from previous runs

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

        abstract = (document.abstract or "")[:3000]  # Limit for classification
        title = document.title or "Untitled"

        user_prompt = f"""Classify THIS paper's study design:

Title: {title}
Abstract: {abstract}

Return JSON:
{{
    "study_design": "systematic_review|meta_analysis|rct|cohort_prospective|cohort_retrospective|case_control|cross_sectional|case_series|case_report|editorial|letter|guideline|other",
    "is_randomized": true|false|null,
    "is_blinded": "none"|"single"|"double"|"triple"|null,
    "sample_size": <number or null>,
    "confidence": <0.0 to 1.0>
}}

IMPORTANT: Classify what THIS study did, not studies it references."""

        messages = [
            LLMMessage(role="system", content=CLASSIFICATION_SYSTEM_PROMPT),
            LLMMessage(role="user", content=user_prompt),
        ]

        # Call LLM with timing
        start_time = time.time()
        try:
            response = self.llm_client.chat(
                messages=messages,
                model=evaluator.model_string,
                temperature=evaluator.temperature or QUALITY_LLM_TEMPERATURE,
                max_tokens=evaluator.max_tokens or QUALITY_CLASSIFIER_MAX_TOKENS,
                json_mode=True,
            )
            latency_ms = int((time.time() - start_time) * 1000)

            # Parse response
            assessment = self._parse_classification_response(response.content)

            # Calculate cost
            cost = calculate_cost(
                evaluator.model_string or "",
                response.input_tokens,
                response.output_tokens,
            )

            return QualityEvaluation(
                document_id=document.id,
                evaluator=evaluator,
                assessment=assessment,
                latency_ms=latency_ms,
                tokens_input=response.input_tokens,
                tokens_output=response.output_tokens,
                cost_usd=cost,
            )

        except Exception as e:
            logger.error(
                f"Failed to classify document {document.id} with "
                f"{evaluator.display_name}: {e}"
            )
            latency_ms = int((time.time() - start_time) * 1000)
            return QualityEvaluation(
                document_id=document.id,
                evaluator=evaluator,
                assessment=QualityAssessment.unclassified(),
                latency_ms=latency_ms,
            )

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

        abstract = (document.abstract or "")[:4000]  # Allow more for detailed assessment
        title = document.title or "Untitled"

        user_prompt = f"""Assess this research paper's methodological quality:

Title: {title}
Abstract: {abstract}

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

        messages = [
            LLMMessage(role="system", content=ASSESSMENT_SYSTEM_PROMPT),
            LLMMessage(role="user", content=user_prompt),
        ]

        # Call LLM with timing
        start_time = time.time()
        try:
            response = self.llm_client.chat(
                messages=messages,
                model=evaluator.model_string,
                temperature=evaluator.temperature or QUALITY_LLM_TEMPERATURE,
                max_tokens=evaluator.max_tokens or QUALITY_ASSESSOR_MAX_TOKENS,
                json_mode=True,
            )
            latency_ms = int((time.time() - start_time) * 1000)

            # Parse response
            assessment = self._parse_assessment_response(response.content)

            # Calculate cost
            cost = calculate_cost(
                evaluator.model_string or "",
                response.input_tokens,
                response.output_tokens,
            )

            return QualityEvaluation(
                document_id=document.id,
                evaluator=evaluator,
                assessment=assessment,
                latency_ms=latency_ms,
                tokens_input=response.input_tokens,
                tokens_output=response.output_tokens,
                cost_usd=cost,
            )

        except Exception as e:
            logger.error(
                f"Failed to assess document {document.id} with "
                f"{evaluator.display_name}: {e}"
            )
            latency_ms = int((time.time() - start_time) * 1000)
            return QualityEvaluation(
                document_id=document.id,
                evaluator=evaluator,
                assessment=QualityAssessment.unclassified(),
                latency_ms=latency_ms,
            )

    def _parse_classification_response(self, response: str) -> QualityAssessment:
        """
        Parse classification response into QualityAssessment.

        Args:
            response: LLM response text

        Returns:
            QualityAssessment (Tier 2 style)
        """
        try:
            cleaned = self._clean_json_response(response)
            if not cleaned:
                return QualityAssessment.unclassified()

            data = json.loads(cleaned)

            # Parse study design
            design_str = data.get("study_design", "unknown").lower().strip()
            study_design = STUDY_DESIGN_MAPPING.get(design_str, StudyDesign.UNKNOWN)

            # Parse blinding
            is_blinded = self._parse_blinding(data.get("is_blinded"))

            # Parse sample size
            sample_size = self._parse_sample_size(data.get("sample_size"))

            # Parse confidence
            confidence = self._parse_confidence(data.get("confidence", 0.5))

            return QualityAssessment(
                assessment_tier=2,
                extraction_method="llm_benchmark",
                study_design=study_design,
                quality_tier=DESIGN_TO_TIER.get(study_design, QualityTier.UNCLASSIFIED),
                quality_score=DESIGN_TO_SCORE.get(study_design, 0.0),
                is_randomized=data.get("is_randomized"),
                is_blinded=is_blinded,
                sample_size=sample_size,
                confidence=confidence,
                extraction_details=["Benchmark classification"],
            )

        except (json.JSONDecodeError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse classification response: {e}")
            return QualityAssessment.unclassified()

    def _parse_assessment_response(self, response: str) -> QualityAssessment:
        """
        Parse detailed assessment response into QualityAssessment.

        Args:
            response: LLM response text

        Returns:
            QualityAssessment (Tier 3 style)
        """
        from ..quality.data_models import BiasRisk

        try:
            cleaned = self._clean_json_response(response)
            if not cleaned:
                return QualityAssessment.unclassified()

            data = json.loads(cleaned)

            # Parse study design
            design_str = data.get("study_design", "unknown").lower().strip()
            study_design = STUDY_DESIGN_MAPPING.get(design_str, StudyDesign.UNKNOWN)

            # Parse design characteristics
            chars = data.get("design_characteristics", {})

            # Parse bias risk
            bias_data = data.get("bias_risk", {})
            bias_risk = BiasRisk.from_dict(bias_data) if bias_data else None

            # Parse sample size
            sample_size = self._parse_sample_size(data.get("sample_size"))

            # Parse blinding
            is_blinded = self._parse_blinding(chars.get("blinded"))

            # Parse quality score
            quality_score = self._parse_quality_score(data.get("quality_score", 0))

            # Parse confidence
            confidence = self._parse_confidence(data.get("confidence", 0.5))

            return QualityAssessment(
                assessment_tier=3,
                extraction_method="llm_benchmark_detailed",
                study_design=study_design,
                quality_tier=DESIGN_TO_TIER.get(study_design, QualityTier.UNCLASSIFIED),
                quality_score=quality_score,
                evidence_level=data.get("evidence_level"),
                is_randomized=chars.get("randomized"),
                is_controlled=chars.get("controlled"),
                is_blinded=is_blinded,
                is_prospective=chars.get("prospective"),
                is_multicenter=chars.get("multicenter"),
                sample_size=sample_size,
                confidence=confidence,
                bias_risk=bias_risk,
                strengths=data.get("strengths", []),
                limitations=data.get("limitations", []),
                extraction_details=["Benchmark detailed assessment"],
            )

        except (json.JSONDecodeError, ValueError, TypeError) as e:
            logger.warning(f"Failed to parse assessment response: {e}")
            return QualityAssessment.unclassified()

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

    def _parse_blinding(self, value: Optional[str]) -> Optional[str]:
        """Parse and validate blinding value."""
        if value is None:
            return None
        normalized = str(value).lower().strip()
        valid_values = ("none", "single", "double", "triple")
        return normalized if normalized in valid_values else None

    def _parse_sample_size(self, value: Optional[int | str]) -> Optional[int]:
        """Parse sample size to integer."""
        if value is None:
            return None
        try:
            return int(value)
        except (ValueError, TypeError):
            return None

    def _parse_quality_score(self, value: float | str) -> float:
        """Parse and clamp quality score."""
        try:
            score = float(value)
            return max(0.0, min(10.0, score))
        except (ValueError, TypeError):
            return 0.0

    def _parse_confidence(self, value: float | str) -> float:
        """Parse and clamp confidence value."""
        try:
            conf = float(value)
            return max(0.0, min(1.0, conf))
        except (ValueError, TypeError):
            return 0.5

    def _compute_results(
        self,
        run_id: str,
        question: str,
        task_type: str,
        evaluators: list[Evaluator],
        documents: list[LiteDocument],
        all_evaluations: dict[str, dict[str, QualityEvaluation]],
        duration: float,
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

        # Design agreement matrix
        evaluator_designs: dict[str, list[StudyDesign]] = {}
        for evaluator in evaluators:
            designs = []
            for doc_id in doc_ids:
                if doc_id in all_evaluations.get(evaluator.id, {}):
                    designs.append(
                        all_evaluations[evaluator.id][doc_id].study_design
                    )
                else:
                    designs.append(StudyDesign.UNKNOWN)
            evaluator_designs[evaluator.display_name] = designs

        design_agreement_matrix = compute_design_agreement_matrix(evaluator_designs)

        # Tier agreement matrix
        evaluator_tiers: dict[str, list[QualityTier]] = {}
        for evaluator in evaluators:
            tiers = []
            for doc_id in doc_ids:
                if doc_id in all_evaluations.get(evaluator.id, {}):
                    tiers.append(
                        all_evaluations[evaluator.id][doc_id].quality_tier
                    )
                else:
                    tiers.append(QualityTier.UNCLASSIFIED)
            evaluator_tiers[evaluator.display_name] = tiers

        tier_agreement_matrix = compute_tier_agreement_matrix(
            evaluator_tiers, tolerance=1
        )

        # Determine baseline evaluator name from config
        baseline_name = None
        baseline_model = self.config.models.get_model_string("study_classification")
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
        )
