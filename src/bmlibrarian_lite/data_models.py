"""
Data models for BMLibrarian Lite.

Type-safe dataclasses for documents, chunks, search sessions,
citations, and review checkpoints. These models are used throughout
the lite module for consistent data handling.
"""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional, Any, TYPE_CHECKING
import hashlib
import json

if TYPE_CHECKING:
    from .quality.data_models import QualityAssessment


class DocumentSource(Enum):
    """Source of a document."""

    PUBMED = "pubmed"
    LOCAL_PDF = "local_pdf"
    LOCAL_TEXT = "local_text"


class EvaluationErrorCode(Enum):
    """
    Error codes for evaluation failures.

    Negative values indicate failure types, allowing the score field
    to signal errors while maintaining the expected int type.

    Usage:
        if scored_doc.score < 0:
            error_code = EvaluationErrorCode(scored_doc.score)
            handle_error(error_code)
    """

    # Success (not an error)
    SUCCESS = 0

    # API/Network errors (-1 to -10)
    API_TIMEOUT = -1
    API_RATE_LIMIT = -2
    API_AUTH_ERROR = -3
    API_CONNECTION_ERROR = -4
    API_SERVER_ERROR = -5

    # Response parsing errors (-11 to -20)
    JSON_PARSE_ERROR = -11
    INVALID_RESPONSE_FORMAT = -12
    EMPTY_RESPONSE = -13
    RESPONSE_TOO_LARGE = -14

    # Retry exhaustion (-21 to -30)
    RETRY_EXHAUSTED = -21

    # General errors (-31 to -40)
    UNKNOWN_ERROR = -31
    INVALID_INPUT = -32

    @property
    def is_retryable(self) -> bool:
        """Check if this error type can be retried."""
        retryable_codes = {
            self.API_TIMEOUT,
            self.API_RATE_LIMIT,
            self.API_CONNECTION_ERROR,
            self.API_SERVER_ERROR,
        }
        return self in retryable_codes

    @property
    def description(self) -> str:
        """Get human-readable description of the error."""
        descriptions = {
            self.SUCCESS: "Success",
            self.API_TIMEOUT: "API request timed out",
            self.API_RATE_LIMIT: "API rate limit exceeded",
            self.API_AUTH_ERROR: "API authentication failed",
            self.API_CONNECTION_ERROR: "Failed to connect to API",
            self.API_SERVER_ERROR: "API server error",
            self.JSON_PARSE_ERROR: "Failed to parse JSON response",
            self.INVALID_RESPONSE_FORMAT: "Invalid response format",
            self.EMPTY_RESPONSE: "Empty response received",
            self.RESPONSE_TOO_LARGE: "Response exceeded size limit",
            self.RETRY_EXHAUSTED: "All retry attempts exhausted",
            self.UNKNOWN_ERROR: "Unknown error occurred",
            self.INVALID_INPUT: "Invalid input provided",
        }
        return descriptions.get(self, "Unknown error")


class EvaluatorType(Enum):
    """Type of evaluator that produced an evaluation."""

    MODEL = "model"
    HUMAN = "human"


class BenchmarkStatus(Enum):
    """Status of a benchmark run."""

    PENDING = "pending"
    RUNNING = "running"
    COMPLETED = "completed"
    FAILED = "failed"
    CANCELLED = "cancelled"


@dataclass
class Evaluator:
    """
    Represents an entity that can produce evaluations.

    An evaluator can be either an LLM model with specific parameters
    or a human reviewer. This enables tracking which model/human
    produced each score for benchmarking comparisons.

    Attributes:
        id: Unique identifier (auto-generated from params for models)
        type: Whether this is a model or human evaluator
        display_name: Human-readable name for UI display
        provider: LLM provider (anthropic, ollama) - None for human
        model_name: Model identifier - None for human
        temperature: Sampling temperature - None for human
        max_tokens: Max output tokens - None for human
        top_p: Nucleus sampling parameter - None for human
        top_k: Top-k sampling parameter - None for human
        human_name: Reviewer name - None for model
        human_email: Reviewer email - None for model
        description: Optional description
        created_at: When this evaluator was first created
    """

    id: str
    type: EvaluatorType
    display_name: str

    # Model-specific fields (None for human)
    provider: Optional[str] = None
    model_name: Optional[str] = None
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    top_p: Optional[float] = None
    top_k: Optional[int] = None

    # Human-specific fields (None for model)
    human_name: Optional[str] = None
    human_email: Optional[str] = None

    description: Optional[str] = None
    created_at: datetime = field(default_factory=datetime.now)

    @classmethod
    def from_model_config(
        cls,
        provider: str,
        model_name: str,
        temperature: float = 0.1,
        max_tokens: int = 256,
        top_p: Optional[float] = None,
        top_k: Optional[int] = None,
    ) -> "Evaluator":
        """
        Create a model evaluator from configuration.

        Generates a deterministic ID from the parameters so that
        the same model+params always produces the same evaluator ID.

        Args:
            provider: LLM provider (anthropic, ollama)
            model_name: Model identifier
            temperature: Sampling temperature
            max_tokens: Maximum output tokens
            top_p: Nucleus sampling parameter
            top_k: Top-k sampling parameter

        Returns:
            Evaluator configured for the specified model
        """
        # Generate deterministic ID from params
        params = {
            "provider": provider,
            "model": model_name,
            "temp": temperature,
            "max_tokens": max_tokens,
            "top_p": top_p,
            "top_k": top_k,
        }
        param_str = json.dumps(params, sort_keys=True)
        eval_id = f"eval_{hashlib.sha256(param_str.encode()).hexdigest()[:12]}"

        # Build display name
        display_name = f"{provider}:{model_name}"
        if temperature != 0.1:
            display_name += f" (t={temperature})"

        return cls(
            id=eval_id,
            type=EvaluatorType.MODEL,
            display_name=display_name,
            provider=provider,
            model_name=model_name,
            temperature=temperature,
            max_tokens=max_tokens,
            top_p=top_p,
            top_k=top_k,
        )

    @classmethod
    def from_human(
        cls,
        name: str,
        email: Optional[str] = None,
    ) -> "Evaluator":
        """
        Create a human evaluator.

        Args:
            name: Reviewer name
            email: Optional reviewer email

        Returns:
            Evaluator configured for human review
        """
        eval_id = f"human_{hashlib.sha256(name.encode()).hexdigest()[:12]}"
        return cls(
            id=eval_id,
            type=EvaluatorType.HUMAN,
            display_name=f"Human: {name}",
            human_name=name,
            human_email=email,
        )

    @property
    def is_model(self) -> bool:
        """Check if this is a model evaluator."""
        return self.type == EvaluatorType.MODEL

    @property
    def is_human(self) -> bool:
        """Check if this is a human evaluator."""
        return self.type == EvaluatorType.HUMAN

    @property
    def model_string(self) -> Optional[str]:
        """
        Get provider:model string for LLM client.

        Returns:
            Model string in "provider:model" format, or None for human
        """
        if self.is_model and self.provider and self.model_name:
            return f"{self.provider}:{self.model_name}"
        return None

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "type": self.type.value,
            "display_name": self.display_name,
            "provider": self.provider,
            "model_name": self.model_name,
            "temperature": self.temperature,
            "max_tokens": self.max_tokens,
            "top_p": self.top_p,
            "top_k": self.top_k,
            "human_name": self.human_name,
            "human_email": self.human_email,
            "description": self.description,
            "created_at": self.created_at.isoformat(),
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "Evaluator":
        """Create from dictionary."""
        created_at = data.get("created_at")
        if isinstance(created_at, str):
            created_at = datetime.fromisoformat(created_at)
        elif created_at is None:
            created_at = datetime.now()

        return cls(
            id=data["id"],
            type=EvaluatorType(data["type"]),
            display_name=data["display_name"],
            provider=data.get("provider"),
            model_name=data.get("model_name"),
            temperature=data.get("temperature"),
            max_tokens=data.get("max_tokens"),
            top_p=data.get("top_p"),
            top_k=data.get("top_k"),
            human_name=data.get("human_name"),
            human_email=data.get("human_email"),
            description=data.get("description"),
            created_at=created_at,
        )


@dataclass
class LiteDocument:
    """
    Document representation for Lite version.

    Stores essential document metadata and abstract text.
    Used for both PubMed articles and local documents.

    Attributes:
        id: Unique identifier (e.g., "pmid-12345" or UUID)
        title: Document title
        abstract: Document abstract text
        authors: List of author names
        year: Publication year
        journal: Journal name
        doi: Digital Object Identifier
        pmid: PubMed ID
        pmc_id: PubMed Central ID (for open access articles)
        url: URL to the article
        mesh_terms: MeSH terms associated with the article
        source: Source of the document (PubMed, local PDF, etc.)
        metadata: Additional custom metadata
    """

    id: str  # Unique identifier (e.g., "pmid-12345" or UUID)
    title: str
    abstract: str
    authors: list[str] = field(default_factory=list)
    year: Optional[int] = None
    journal: Optional[str] = None
    doi: Optional[str] = None
    pmid: Optional[str] = None
    pmc_id: Optional[str] = None
    url: Optional[str] = None
    mesh_terms: list[str] = field(default_factory=list)
    source: DocumentSource = DocumentSource.PUBMED
    metadata: dict[str, Any] = field(default_factory=dict)

    @property
    def formatted_authors(self) -> str:
        """
        Return formatted author string.

        Returns:
            Formatted authors (e.g., "Smith J, Jones A" or "Smith J et al.")
        """
        if not self.authors:
            return "Unknown"
        if len(self.authors) <= 3:
            return ", ".join(self.authors)
        return f"{self.authors[0]} et al."

    @property
    def citation(self) -> str:
        """
        Return formatted citation string.

        Returns:
            Citation in standard format
        """
        parts = [self.formatted_authors]
        if self.year:
            parts.append(f"({self.year})")
        parts.append(self.title)
        if self.journal:
            parts.append(self.journal)
        return ". ".join(parts)

    def to_dict(self) -> dict[str, Any]:
        """
        Convert to dictionary for serialization.

        Returns:
            Dictionary representation
        """
        return {
            "id": self.id,
            "title": self.title,
            "abstract": self.abstract,
            "authors": self.authors,
            "year": self.year,
            "journal": self.journal,
            "doi": self.doi,
            "pmid": self.pmid,
            "pmc_id": self.pmc_id,
            "url": self.url,
            "mesh_terms": self.mesh_terms,
            "source": self.source.value,
            "metadata": self.metadata,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "LiteDocument":
        """
        Create from dictionary.

        Args:
            data: Dictionary representation

        Returns:
            LiteDocument instance
        """
        return cls(
            id=data["id"],
            title=data["title"],
            abstract=data["abstract"],
            authors=data.get("authors", []),
            year=data.get("year"),
            journal=data.get("journal"),
            doi=data.get("doi"),
            pmid=data.get("pmid"),
            pmc_id=data.get("pmc_id"),
            url=data.get("url"),
            mesh_terms=data.get("mesh_terms", []),
            source=DocumentSource(data.get("source", "pubmed")),
            metadata=data.get("metadata", {}),
        )


@dataclass
class LiteChunk:
    """
    A chunk of a document for embedding and retrieval.

    Used in document interrogation for semantic search
    over document sections.
    """

    id: str  # Unique chunk ID (e.g., "doc-123_chunk_0")
    document_id: str  # Parent document ID
    text: str  # Chunk text content
    chunk_index: int  # Position in document (0-indexed)
    start_char: int  # Start character position in original
    end_char: int  # End character position in original
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "document_id": self.document_id,
            "text": self.text,
            "chunk_index": self.chunk_index,
            "start_char": self.start_char,
            "end_char": self.end_char,
            "metadata": self.metadata,
        }


@dataclass
class SearchSession:
    """
    A PubMed search session.

    Tracks search queries and their results for history
    and reproducibility.
    """

    id: str  # Session UUID
    query: str  # PubMed query string
    natural_language_query: str  # Original user question
    created_at: datetime
    document_count: int  # Number of documents found
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "query": self.query,
            "natural_language_query": self.natural_language_query,
            "created_at": self.created_at.isoformat(),
            "document_count": self.document_count,
            "metadata": self.metadata,
        }


@dataclass
class ScoredDocument:
    """
    Document with relevance score.

    Result of document scoring by an evaluator (LLM model or human).
    Includes performance metrics for benchmarking comparisons.

    Attributes:
        document: The scored document
        score: Relevance score (1-5 scale)
        explanation: Rationale for the score
        evaluator_id: ID of the evaluator that produced this score
        evaluator: Full evaluator object (optional, for convenience)
        latency_ms: Time taken to produce the score (milliseconds)
        tokens_input: Number of input tokens used
        tokens_output: Number of output tokens used
        cost_usd: Estimated cost in USD
        scored_at: Timestamp when scoring occurred
    """

    document: LiteDocument
    score: int  # 1-5 scale
    explanation: str  # Why this score was assigned

    # Evaluator tracking
    evaluator_id: Optional[str] = None
    evaluator: Optional[Evaluator] = None

    # Performance metrics for benchmarking
    latency_ms: Optional[int] = None
    tokens_input: Optional[int] = None
    tokens_output: Optional[int] = None
    cost_usd: Optional[float] = None

    scored_at: datetime = field(default_factory=datetime.now)

    @property
    def is_relevant(self) -> bool:
        """Check if document meets minimum relevance threshold (score >= 3)."""
        return self.score >= 3

    @property
    def total_tokens(self) -> int:
        """Total tokens used (input + output)."""
        return (self.tokens_input or 0) + (self.tokens_output or 0)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "document": self.document.to_dict(),
            "score": self.score,
            "explanation": self.explanation,
            "evaluator_id": self.evaluator_id,
            "latency_ms": self.latency_ms,
            "tokens_input": self.tokens_input,
            "tokens_output": self.tokens_output,
            "cost_usd": self.cost_usd,
            "scored_at": self.scored_at.isoformat(),
        }


@dataclass
class Citation:
    """
    Extracted citation from a document.

    Contains a specific passage that supports answering
    the research question.
    """

    document: LiteDocument
    passage: str  # Extracted text passage
    relevance_score: int  # Score of parent document
    context: str = ""  # Why this passage is relevant
    assessment: Optional["QualityAssessment"] = None  # Quality assessment if available

    @property
    def formatted_citation(self) -> str:
        """
        Return formatted citation with passage.

        Returns:
            Citation with quoted passage
        """
        return f'"{self.passage}" [{self.document.formatted_authors}, {self.document.year or "n.d."}]'

    @property
    def formatted_reference(self) -> str:
        """
        Return a short reference string.

        Returns:
            Short reference (e.g., "Smith et al., 2023")
        """
        if self.document.authors:
            first_author = self.document.authors[0].split(",")[0].split()[-1]
            if len(self.document.authors) > 1:
                author_str = f"{first_author} et al."
            else:
                author_str = first_author
        else:
            author_str = "Unknown"
        year = self.document.year or "n.d."
        return f"{author_str}, {year}"

    @property
    def quality_annotation(self) -> str:
        """
        Get quality annotation for inline use.

        Returns:
            Quality annotation string or empty string
        """
        if not self.assessment:
            return ""

        parts = []
        design = self.assessment.study_design.value.replace("_", " ").title()
        if design.lower() not in ["unknown", "other"]:
            parts.append(design)

        if self.assessment.sample_size:
            parts.append(f"n={self.assessment.sample_size:,}")

        if self.assessment.is_blinded and self.assessment.is_blinded != "none":
            parts.append(f"{self.assessment.is_blinded}-blind")

        if parts:
            return f"**{', '.join(parts)}**"
        return ""


@dataclass
class ReviewCheckpoint:
    """
    Checkpoint for systematic review progress.

    Allows resuming reviews from any step in the workflow.
    """

    id: str  # Checkpoint UUID
    research_question: str
    created_at: datetime
    updated_at: datetime
    step: str  # Current workflow step (e.g., "search", "scoring", "report")
    search_session_id: Optional[str] = None
    scored_documents: list[ScoredDocument] = field(default_factory=list)
    citations: list[Citation] = field(default_factory=list)
    report: Optional[str] = None
    metadata: dict[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "research_question": self.research_question,
            "created_at": self.created_at.isoformat(),
            "updated_at": self.updated_at.isoformat(),
            "step": self.step,
            "search_session_id": self.search_session_id,
            "report": self.report,
            "metadata": self.metadata,
        }


@dataclass
class InterrogationSession:
    """
    Session for document interrogation.

    Tracks the loaded document and conversation history.
    """

    id: str  # Session UUID
    document_id: str  # ID of loaded document
    document_title: str
    created_at: datetime
    messages: list[dict[str, str]] = field(default_factory=list)  # Chat history
    metadata: dict[str, Any] = field(default_factory=dict)

    def add_message(self, role: str, content: str) -> None:
        """
        Add a message to the conversation history.

        Args:
            role: "user" or "assistant"
            content: Message text
        """
        self.messages.append({
            "role": role,
            "content": content,
            "timestamp": datetime.now().isoformat(),
        })


@dataclass
class BenchmarkRun:
    """
    A benchmark comparison run.

    Tracks a benchmarking session that compares multiple evaluators
    on a set of documents for a given research question.

    Attributes:
        id: Unique identifier for this benchmark run
        name: User-provided name for the run
        description: Optional description
        question: Research question being evaluated
        question_hash: Normalized hash of question for efficient lookup
        task_type: Type of task being benchmarked (e.g., document_scoring)
        evaluator_ids: List of evaluator IDs to compare
        document_ids: List of document IDs to evaluate
        status: Current status of the benchmark
        progress_current: Current progress count
        progress_total: Total items to process
        error_message: Error message if failed
        results_summary: JSON string with aggregated statistics
        created_at: When the run was created
        started_at: When execution started
        completed_at: When execution completed
    """

    id: str
    name: str
    question: str
    task_type: str
    evaluator_ids: list[str]
    document_ids: list[str]

    description: Optional[str] = None
    question_hash: Optional[str] = None
    status: BenchmarkStatus = BenchmarkStatus.PENDING
    progress_current: int = 0
    progress_total: int = 0
    error_message: Optional[str] = None
    results_summary: Optional[str] = None

    created_at: datetime = field(default_factory=datetime.now)
    started_at: Optional[datetime] = None
    completed_at: Optional[datetime] = None

    @property
    def is_complete(self) -> bool:
        """Check if benchmark has finished (successfully or not)."""
        return self.status in (
            BenchmarkStatus.COMPLETED,
            BenchmarkStatus.FAILED,
            BenchmarkStatus.CANCELLED,
        )

    @property
    def progress_percent(self) -> float:
        """Get progress as percentage (0.0 to 100.0)."""
        if self.progress_total == 0:
            return 0.0
        return (self.progress_current / self.progress_total) * 100.0

    @property
    def duration_seconds(self) -> Optional[float]:
        """Get duration in seconds if completed."""
        if self.started_at is None:
            return None
        end_time = self.completed_at or datetime.now()
        return (end_time - self.started_at).total_seconds()

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for serialization."""
        return {
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "question": self.question,
            "question_hash": self.question_hash,
            "task_type": self.task_type,
            "evaluator_ids": self.evaluator_ids,
            "document_ids": self.document_ids,
            "status": self.status.value,
            "progress_current": self.progress_current,
            "progress_total": self.progress_total,
            "error_message": self.error_message,
            "results_summary": self.results_summary,
            "created_at": self.created_at.isoformat(),
            "started_at": self.started_at.isoformat() if self.started_at else None,
            "completed_at": self.completed_at.isoformat() if self.completed_at else None,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "BenchmarkRun":
        """Create from dictionary."""
        def parse_datetime(val: Any) -> Optional[datetime]:
            if val is None:
                return None
            if isinstance(val, datetime):
                return val
            return datetime.fromisoformat(val)

        return cls(
            id=data["id"],
            name=data["name"],
            description=data.get("description"),
            question=data["question"],
            question_hash=data.get("question_hash"),
            task_type=data["task_type"],
            evaluator_ids=data["evaluator_ids"],
            document_ids=data["document_ids"],
            status=BenchmarkStatus(data.get("status", "pending")),
            progress_current=data.get("progress_current", 0),
            progress_total=data.get("progress_total", 0),
            error_message=data.get("error_message"),
            results_summary=data.get("results_summary"),
            created_at=parse_datetime(data.get("created_at")) or datetime.now(),
            started_at=parse_datetime(data.get("started_at")),
            completed_at=parse_datetime(data.get("completed_at")),
        )


@dataclass
class ResearchQuestionSummary:
    """
    Summary of a research question for the Research Questions tab.

    Contains metadata about past runs of a research question including
    the most recent PubMed query, document counts, and scoring status.

    Attributes:
        question: The natural language research question
        question_hash: Normalized hash for matching variations
        pubmed_query: Most recent PubMed query string used
        last_run_at: When the question was last run
        total_documents: Total documents found across all runs
        scored_documents: Count of scored documents
        run_count: Number of times this question has been run
    """

    question: str
    question_hash: str
    pubmed_query: str
    last_run_at: datetime
    total_documents: int = 0
    scored_documents: int = 0
    run_count: int = 1


@dataclass
class ReportMetadata:
    """
    Metadata for report reproducibility and versioning.

    Captures all parameters and statistics from a systematic review
    workflow for inclusion in the report methodology section.

    Attributes:
        version: Report version number (increments for re-runs)
        generated_at: When the report was generated

        research_question: The natural language research question
        pubmed_query: PubMed query string used for search
        pubmed_search_date: When the PubMed search was executed
        total_results_available: Total results available in PubMed
        documents_retrieved: Number of documents actually retrieved

        documents_scored: Total documents that were scored
        documents_accepted: Documents that met the score threshold
        documents_rejected: Documents below the score threshold
        min_score_threshold: Minimum relevance score used (1-5)
        score_distribution: Count of documents at each score level

        quality_filter_applied: Whether quality filtering was used
        quality_filter_settings: Quality filter configuration
        documents_filtered_by_quality: Documents removed by quality filter

        model_configs: LLM configuration for each workflow task
        citations_extracted: Total citation passages extracted
        unique_sources_cited: Number of unique documents cited
    """

    # Version info
    version: int = 1
    generated_at: datetime = field(default_factory=datetime.now)

    # Search info
    research_question: str = ""
    pubmed_query: str = ""
    pubmed_search_date: Optional[datetime] = None
    total_results_available: int = 0
    documents_retrieved: int = 0

    # Scoring info
    documents_scored: int = 0
    documents_accepted: int = 0
    documents_rejected: int = 0
    min_score_threshold: int = 3
    score_distribution: dict[int, int] = field(default_factory=dict)

    # Quality filter info
    quality_filter_applied: bool = False
    quality_filter_settings: Optional[dict[str, Any]] = None
    documents_filtered_by_quality: int = 0

    # LLM configuration by task
    model_configs: dict[str, dict[str, Any]] = field(default_factory=dict)

    # Citations info
    citations_extracted: int = 0
    unique_sources_cited: int = 0

    def to_dict(self) -> dict[str, Any]:
        """Convert to dictionary for JSON serialization."""
        return {
            "version": self.version,
            "generated_at": self.generated_at.isoformat(),
            "research_question": self.research_question,
            "pubmed_query": self.pubmed_query,
            "pubmed_search_date": (
                self.pubmed_search_date.isoformat()
                if self.pubmed_search_date
                else None
            ),
            "total_results_available": self.total_results_available,
            "documents_retrieved": self.documents_retrieved,
            "documents_scored": self.documents_scored,
            "documents_accepted": self.documents_accepted,
            "documents_rejected": self.documents_rejected,
            "min_score_threshold": self.min_score_threshold,
            "score_distribution": self.score_distribution,
            "quality_filter_applied": self.quality_filter_applied,
            "quality_filter_settings": self.quality_filter_settings,
            "documents_filtered_by_quality": self.documents_filtered_by_quality,
            "model_configs": self.model_configs,
            "citations_extracted": self.citations_extracted,
            "unique_sources_cited": self.unique_sources_cited,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "ReportMetadata":
        """Create from dictionary."""
        generated_at = data.get("generated_at")
        if isinstance(generated_at, str):
            generated_at = datetime.fromisoformat(generated_at)
        elif generated_at is None:
            generated_at = datetime.now()

        search_date = data.get("pubmed_search_date")
        if isinstance(search_date, str):
            search_date = datetime.fromisoformat(search_date)

        return cls(
            version=data.get("version", 1),
            generated_at=generated_at,
            research_question=data.get("research_question", ""),
            pubmed_query=data.get("pubmed_query", ""),
            pubmed_search_date=search_date,
            total_results_available=data.get("total_results_available", 0),
            documents_retrieved=data.get("documents_retrieved", 0),
            documents_scored=data.get("documents_scored", 0),
            documents_accepted=data.get("documents_accepted", 0),
            documents_rejected=data.get("documents_rejected", 0),
            min_score_threshold=data.get("min_score_threshold", 3),
            score_distribution=data.get("score_distribution", {}),
            quality_filter_applied=data.get("quality_filter_applied", False),
            quality_filter_settings=data.get("quality_filter_settings"),
            documents_filtered_by_quality=data.get("documents_filtered_by_quality", 0),
            model_configs=data.get("model_configs", {}),
            citations_extracted=data.get("citations_extracted", 0),
            unique_sources_cited=data.get("unique_sources_cited", 0),
        )
