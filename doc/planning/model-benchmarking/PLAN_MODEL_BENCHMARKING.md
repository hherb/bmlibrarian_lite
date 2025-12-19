# Implementation Plan: Model Benchmarking System

## Implementation Status

| Phase | Description | Status |
|-------|-------------|--------|
| Phase 1 | Database & Data Models | ✅ Complete |
| Phase 2 | Core Benchmarking Engine | ✅ Complete |
| Phase 3 | Settings Integration | ✅ Complete |
| Phase 4 | Execution UI | ✅ Complete |
| Phase 5 | Results Display | ✅ Complete |
| Phase 6 | Polish & Documentation | ✅ Complete |

**Implementation Complete:** All 6 phases have been implemented and tested.

## Overview

This plan implements a comprehensive model benchmarking system that allows users to:
1. Compare LLM model performance across all task types (scoring, citation extraction, etc.)
2. Track evaluations by evaluator (model+params or human)
3. Store multiple evaluations per document for comparative analysis
4. Capture quality metrics, token usage, latency, and cost estimates
5. Enable side-by-side comparison with minimal user interaction

## Current Architecture Analysis

### Existing Evaluation Storage

**Current `scored_documents` Table:**
```sql
CREATE TABLE scored_documents (
    id TEXT PRIMARY KEY,
    checkpoint_id TEXT NOT NULL,
    document_id TEXT NOT NULL,
    score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
    explanation TEXT,
    scored_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id)
);
```

**Limitation:** No tracking of which model/evaluator produced the score. Each document can only have one score per checkpoint.

### Existing Model Configuration

Task-based model selection via `TASK_ID` in agents:
- `LiteScoringAgent.TASK_ID = "document_scoring"`
- `LiteCitationAgent.TASK_ID = "citation_extraction"`
- etc.

Models resolved through `config.models.get_task_config(task_id)`.

---

## Proposed Architecture

### Core Concept: Evaluator Entity

An **evaluator** is any entity that can produce an evaluation:
- **Model evaluator**: LLM with specific provider, model name, and parameters
- **Human evaluator**: Manual review with reviewer identity

This abstraction allows:
- Multiple models to evaluate the same document
- Human review alongside model evaluations
- Future support for ensemble evaluations

### 1. Database Schema

#### 1.1 Evaluators Table

```sql
CREATE TABLE evaluators (
    id TEXT PRIMARY KEY,

    -- Type discrimination
    type TEXT NOT NULL CHECK (type IN ('model', 'human')),

    -- Model-specific fields (NULL for human)
    provider TEXT,                    -- 'anthropic', 'ollama'
    model_name TEXT,                  -- 'claude-sonnet-4-20250514', 'llama3.2'
    temperature REAL,                 -- 0.0-2.0
    max_tokens INTEGER,               -- Max output tokens
    top_p REAL,                       -- Nucleus sampling
    top_k INTEGER,                    -- Top-k sampling

    -- Human-specific fields (NULL for model)
    human_name TEXT,                  -- Reviewer name/identifier
    human_email TEXT,                 -- Optional contact

    -- Common fields
    display_name TEXT NOT NULL,       -- Human-readable name for UI
    description TEXT,                 -- Optional description
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,

    -- Unique constraint for models (prevent duplicates)
    UNIQUE (type, provider, model_name, temperature, max_tokens, top_p, top_k)
);

CREATE INDEX idx_evaluators_type ON evaluators(type);
CREATE INDEX idx_evaluators_provider ON evaluators(provider);
```

#### 1.2 Extended Scored Documents Table

Modify existing table to support multiple evaluations per document:

```sql
-- Drop old constraints if needed, add new columns
ALTER TABLE scored_documents ADD COLUMN evaluator_id TEXT REFERENCES evaluators(id);
ALTER TABLE scored_documents ADD COLUMN latency_ms INTEGER;
ALTER TABLE scored_documents ADD COLUMN tokens_input INTEGER;
ALTER TABLE scored_documents ADD COLUMN tokens_output INTEGER;
ALTER TABLE scored_documents ADD COLUMN cost_usd REAL;

-- Remove unique constraint on (checkpoint_id, document_id) if exists
-- Allow multiple scores per document with different evaluators

-- New composite index for efficient lookups
CREATE INDEX idx_scored_docs_evaluator ON scored_documents(evaluator_id);
CREATE INDEX idx_scored_docs_doc_eval ON scored_documents(document_id, evaluator_id);
```

#### 1.3 Extended Citations Table

```sql
ALTER TABLE citations ADD COLUMN evaluator_id TEXT REFERENCES evaluators(id);
ALTER TABLE citations ADD COLUMN latency_ms INTEGER;
ALTER TABLE citations ADD COLUMN tokens_input INTEGER;
ALTER TABLE citations ADD COLUMN tokens_output INTEGER;
ALTER TABLE citations ADD COLUMN cost_usd REAL;

CREATE INDEX idx_citations_evaluator ON citations(evaluator_id);
```

#### 1.4 Benchmark Runs Table

Track explicit benchmarking sessions:

```sql
CREATE TABLE benchmark_runs (
    id TEXT PRIMARY KEY,
    name TEXT,                        -- User-provided name
    description TEXT,                 -- Optional description
    question TEXT NOT NULL,           -- Research question being evaluated
    task_type TEXT NOT NULL,          -- 'document_scoring', 'citation_extraction', etc.

    -- Which evaluators are being compared
    evaluator_ids TEXT NOT NULL,      -- JSON array of evaluator IDs

    -- Document selection
    document_ids TEXT NOT NULL,       -- JSON array of document IDs to evaluate
    sample_size INTEGER,              -- Number of documents if sampled

    -- Status tracking
    status TEXT DEFAULT 'pending' CHECK (status IN ('pending', 'running', 'completed', 'failed', 'cancelled')),
    progress_current INTEGER DEFAULT 0,
    progress_total INTEGER DEFAULT 0,
    error_message TEXT,

    -- Timing
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    started_at TIMESTAMP,
    completed_at TIMESTAMP,

    -- Results summary (populated on completion)
    results_summary TEXT              -- JSON with aggregated statistics
);

CREATE INDEX idx_benchmark_runs_status ON benchmark_runs(status);
CREATE INDEX idx_benchmark_runs_task ON benchmark_runs(task_type);
```

#### 1.5 Complete ERD

```
┌─────────────────────┐
│   research_question │
│   (via checkpoint)  │
└──────────┬──────────┘
           │ 1:N
           ▼
┌─────────────────────┐         ┌─────────────────────┐
│     documents       │         │    evaluators       │
│  (in ChromaDB)      │         │                     │
└──────────┬──────────┘         └──────────┬──────────┘
           │ 1:N                           │
           │         ┌─────────────────────┘
           │         │ N:1
           ▼         ▼
┌─────────────────────────────────────────────────────┐
│                  scored_documents                    │
│  - document_id (FK)                                 │
│  - evaluator_id (FK)                                │
│  - score, explanation                               │
│  - latency_ms, tokens_input, tokens_output          │
│  - cost_usd                                         │
│                                                     │
│  (Multiple rows per document - one per evaluator)   │
└─────────────────────────────────────────────────────┘
           │
           │ N:1
           ▼
┌─────────────────────────────────────────────────────┐
│                  benchmark_runs                      │
│  - evaluator_ids (JSON array)                       │
│  - document_ids (JSON array)                        │
│  - results_summary (JSON)                           │
└─────────────────────────────────────────────────────┘
```

---

### 2. Data Models

#### 2.1 Evaluator Dataclass (`data_models.py`)

```python
from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import Optional
import hashlib
import json


class EvaluatorType(Enum):
    MODEL = "model"
    HUMAN = "human"


@dataclass
class Evaluator:
    """Represents an entity that can produce evaluations."""

    id: str
    type: EvaluatorType
    display_name: str

    # Model-specific (None for human)
    provider: Optional[str] = None
    model_name: Optional[str] = None
    temperature: Optional[float] = None
    max_tokens: Optional[int] = None
    top_p: Optional[float] = None
    top_k: Optional[int] = None

    # Human-specific (None for model)
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
        """Create a model evaluator from configuration."""
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
    def from_human(cls, name: str, email: Optional[str] = None) -> "Evaluator":
        """Create a human evaluator."""
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
        return self.type == EvaluatorType.MODEL

    @property
    def is_human(self) -> bool:
        return self.type == EvaluatorType.HUMAN

    @property
    def model_string(self) -> Optional[str]:
        """Get provider:model string for LLM client."""
        if self.is_model:
            return f"{self.provider}:{self.model_name}"
        return None
```

#### 2.2 Extended ScoredDocument (`data_models.py`)

```python
@dataclass
class ScoredDocument:
    """A document with a relevance score from an evaluator."""

    document: LiteDocument
    score: int  # 1-5 scale
    explanation: str

    # Evaluator tracking
    evaluator_id: Optional[str] = None
    evaluator: Optional[Evaluator] = None

    # Performance metrics
    latency_ms: Optional[int] = None
    tokens_input: Optional[int] = None
    tokens_output: Optional[int] = None
    cost_usd: Optional[float] = None

    scored_at: datetime = field(default_factory=datetime.now)

    @property
    def is_relevant(self) -> bool:
        """Check if document meets minimum relevance threshold."""
        return self.score >= 3

    @property
    def total_tokens(self) -> int:
        """Total tokens used (input + output)."""
        return (self.tokens_input or 0) + (self.tokens_output or 0)
```

#### 2.3 Benchmark Result Models (`benchmarking/models.py`)

```python
@dataclass
class EvaluatorStats:
    """Statistics for a single evaluator in a benchmark."""

    evaluator: Evaluator

    # Score distribution
    scores: list[int]
    mean_score: float
    std_dev: float
    score_distribution: dict[int, int]  # score -> count

    # Performance metrics
    total_evaluations: int
    mean_latency_ms: float
    total_tokens_input: int
    total_tokens_output: int
    total_cost_usd: float

    # Agreement metrics (filled when comparing)
    agreement_with_others: Optional[dict[str, float]] = None  # evaluator_id -> agreement %


@dataclass
class BenchmarkResult:
    """Complete results of a benchmark run."""

    run_id: str
    question: str
    task_type: str

    # Evaluator statistics
    evaluator_stats: list[EvaluatorStats]

    # Cross-evaluator metrics
    agreement_matrix: dict[tuple[str, str], float]  # (eval1, eval2) -> agreement %
    kendall_tau: Optional[float]  # Ranking correlation

    # Document-level details
    document_scores: dict[str, dict[str, int]]  # doc_id -> {evaluator_id -> score}

    # Timing
    total_duration_seconds: float

    def get_model_ranking(self) -> list[tuple[Evaluator, float]]:
        """Rank evaluators by mean score (descending)."""
        return sorted(
            [(s.evaluator, s.mean_score) for s in self.evaluator_stats],
            key=lambda x: x[1],
            reverse=True,
        )

    def get_cost_ranking(self) -> list[tuple[Evaluator, float]]:
        """Rank evaluators by cost efficiency (cost per evaluation, ascending)."""
        return sorted(
            [(s.evaluator, s.total_cost_usd / s.total_evaluations)
             for s in self.evaluator_stats],
            key=lambda x: x[1],
        )
```

---

### 3. Cost Tracking

#### 3.1 Model Pricing Data (`constants.py`)

```python
# Pricing per 1M tokens (as of 2025)
MODEL_PRICING = {
    # Anthropic models
    "anthropic:claude-opus-4-20250514": {"input": 15.00, "output": 75.00},
    "anthropic:claude-sonnet-4-20250514": {"input": 3.00, "output": 15.00},
    "anthropic:claude-3-5-haiku-20241022": {"input": 0.80, "output": 4.00},

    # Ollama models (free/local)
    "ollama:llama3.2": {"input": 0.0, "output": 0.0},
    "ollama:llama3.1": {"input": 0.0, "output": 0.0},
    "ollama:mistral": {"input": 0.0, "output": 0.0},
    "ollama:mixtral": {"input": 0.0, "output": 0.0},
}

# Default for unknown models
DEFAULT_MODEL_PRICING = {"input": 1.00, "output": 5.00}
```

#### 3.2 Cost Calculator (`benchmarking/cost.py`)

```python
def calculate_cost(
    model_string: str,
    tokens_input: int,
    tokens_output: int,
) -> float:
    """
    Calculate cost in USD for an LLM call.

    Args:
        model_string: "provider:model" format
        tokens_input: Number of input tokens
        tokens_output: Number of output tokens

    Returns:
        Cost in USD
    """
    pricing = MODEL_PRICING.get(model_string, DEFAULT_MODEL_PRICING)

    input_cost = (tokens_input / 1_000_000) * pricing["input"]
    output_cost = (tokens_output / 1_000_000) * pricing["output"]

    return input_cost + output_cost
```

---

### 4. Benchmarking Engine

#### 4.1 Benchmark Runner (`benchmarking/runner.py`)

```python
class BenchmarkRunner:
    """Orchestrates benchmark execution across multiple evaluators."""

    def __init__(
        self,
        config: LiteConfig,
        storage: LiteStorage,
    ):
        self.config = config
        self.storage = storage
        self._llm_client: Optional[LLMClient] = None

    @property
    def llm_client(self) -> LLMClient:
        if self._llm_client is None:
            self._llm_client = LLMClient(config=self.config)
        return self._llm_client

    def create_benchmark_run(
        self,
        question: str,
        task_type: str,
        evaluators: list[Evaluator],
        documents: list[LiteDocument],
        name: Optional[str] = None,
    ) -> str:
        """
        Create a new benchmark run.

        Returns:
            Benchmark run ID
        """
        run_id = f"bench_{uuid.uuid4().hex[:12]}"

        # Store in database
        self.storage.create_benchmark_run(
            run_id=run_id,
            name=name or f"Benchmark {datetime.now().strftime('%Y-%m-%d %H:%M')}",
            question=question,
            task_type=task_type,
            evaluator_ids=[e.id for e in evaluators],
            document_ids=[d.id for d in documents],
        )

        # Ensure evaluators exist in DB
        for evaluator in evaluators:
            self.storage.upsert_evaluator(evaluator)

        return run_id

    def run_benchmark(
        self,
        run_id: str,
        progress_callback: Optional[Callable[[int, int, str], None]] = None,
    ) -> BenchmarkResult:
        """
        Execute a benchmark run.

        Args:
            run_id: Benchmark run ID
            progress_callback: Called with (current, total, status_message)

        Returns:
            Complete benchmark results
        """
        run = self.storage.get_benchmark_run(run_id)
        evaluators = [self.storage.get_evaluator(eid) for eid in run.evaluator_ids]
        documents = [self.storage.get_document(did) for did in run.document_ids]

        total_ops = len(evaluators) * len(documents)
        current_op = 0

        self.storage.update_benchmark_status(run_id, "running")
        start_time = time.time()

        all_scores: dict[str, dict[str, ScoredDocument]] = {}  # doc_id -> eval_id -> scored

        for evaluator in evaluators:
            all_scores_for_eval: dict[str, ScoredDocument] = {}

            for document in documents:
                current_op += 1
                if progress_callback:
                    progress_callback(
                        current_op,
                        total_ops,
                        f"Scoring with {evaluator.display_name}..."
                    )

                # Check if we already have this evaluation
                existing = self.storage.get_scored_document(
                    document_id=document.id,
                    evaluator_id=evaluator.id,
                    question=run.question,
                )

                if existing:
                    all_scores_for_eval[document.id] = existing
                else:
                    # Run the evaluation
                    scored = self._evaluate_document(
                        document=document,
                        question=run.question,
                        evaluator=evaluator,
                        task_type=run.task_type,
                    )
                    all_scores_for_eval[document.id] = scored

                    # Store result
                    self.storage.save_scored_document(scored, run.checkpoint_id)

            all_scores[evaluator.id] = all_scores_for_eval

        # Compute statistics
        result = self._compute_statistics(
            run_id=run_id,
            question=run.question,
            task_type=run.task_type,
            evaluators=evaluators,
            all_scores=all_scores,
            duration=time.time() - start_time,
        )

        # Update run status
        self.storage.update_benchmark_status(
            run_id,
            "completed",
            results_summary=result.to_json(),
        )

        return result

    def _evaluate_document(
        self,
        document: LiteDocument,
        question: str,
        evaluator: Evaluator,
        task_type: str,
    ) -> ScoredDocument:
        """Run a single evaluation."""
        if task_type == "document_scoring":
            return self._score_document(document, question, evaluator)
        elif task_type == "citation_extraction":
            return self._extract_citation(document, question, evaluator)
        else:
            raise ValueError(f"Unknown task type: {task_type}")

    def _score_document(
        self,
        document: LiteDocument,
        question: str,
        evaluator: Evaluator,
    ) -> ScoredDocument:
        """Score a document using the evaluator's model."""
        from bmlibrarian_lite.agents.scoring_agent import SCORING_SYSTEM_PROMPT

        # Build prompt
        user_prompt = f"""Research Question: {question}

Document to evaluate:
Title: {document.title}
Authors: {', '.join(document.authors[:3])}
Year: {document.year}
Journal: {document.journal}

Abstract:
{document.abstract}

Please score this document's relevance (1-5) and explain your reasoning."""

        messages = [
            {"role": "system", "content": SCORING_SYSTEM_PROMPT},
            {"role": "user", "content": user_prompt},
        ]

        # Call LLM with timing
        start_time = time.time()
        response = self.llm_client.chat(
            messages=messages,
            model=evaluator.model_string,
            temperature=evaluator.temperature,
            max_tokens=evaluator.max_tokens,
            top_p=evaluator.top_p,
            json_mode=True,
        )
        latency_ms = int((time.time() - start_time) * 1000)

        # Parse response
        score_data = json.loads(response.content)

        # Calculate cost
        cost = calculate_cost(
            evaluator.model_string,
            response.usage.input_tokens,
            response.usage.output_tokens,
        )

        return ScoredDocument(
            document=document,
            score=score_data["score"],
            explanation=score_data.get("explanation", ""),
            evaluator_id=evaluator.id,
            evaluator=evaluator,
            latency_ms=latency_ms,
            tokens_input=response.usage.input_tokens,
            tokens_output=response.usage.output_tokens,
            cost_usd=cost,
        )
```

#### 4.2 Statistics Calculator (`benchmarking/statistics.py`)

```python
def compute_agreement(
    scores1: list[int],
    scores2: list[int],
    tolerance: int = 1,
) -> float:
    """
    Compute agreement percentage between two score lists.

    Args:
        scores1: First evaluator's scores
        scores2: Second evaluator's scores
        tolerance: Allow scores within this difference to count as agreement

    Returns:
        Agreement percentage (0.0 to 1.0)
    """
    if len(scores1) != len(scores2):
        raise ValueError("Score lists must have same length")

    agreements = sum(
        1 for s1, s2 in zip(scores1, scores2)
        if abs(s1 - s2) <= tolerance
    )

    return agreements / len(scores1)


def compute_kendall_tau(
    scores1: list[int],
    scores2: list[int],
) -> float:
    """Compute Kendall's tau correlation between rankings."""
    from scipy.stats import kendalltau
    tau, _ = kendalltau(scores1, scores2)
    return tau


def compute_evaluator_stats(
    evaluator: Evaluator,
    scored_documents: list[ScoredDocument],
) -> EvaluatorStats:
    """Compute statistics for a single evaluator."""
    scores = [sd.score for sd in scored_documents]

    # Score distribution
    distribution = {i: 0 for i in range(1, 6)}
    for score in scores:
        distribution[score] += 1

    return EvaluatorStats(
        evaluator=evaluator,
        scores=scores,
        mean_score=statistics.mean(scores),
        std_dev=statistics.stdev(scores) if len(scores) > 1 else 0.0,
        score_distribution=distribution,
        total_evaluations=len(scored_documents),
        mean_latency_ms=statistics.mean([sd.latency_ms for sd in scored_documents]),
        total_tokens_input=sum(sd.tokens_input or 0 for sd in scored_documents),
        total_tokens_output=sum(sd.tokens_output or 0 for sd in scored_documents),
        total_cost_usd=sum(sd.cost_usd or 0.0 for sd in scored_documents),
    )
```

---

### 5. Settings Integration

#### 5.1 Benchmarking Tab in Settings Dialog

```
┌─────────────────────────────────────────────────────────────────┐
│ [Providers] [Tasks] [Benchmarking] [Embeddings] [PubMed] [...]  │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ BENCHMARKING CONFIGURATION                                      │
│                                                                 │
│ ☑ Enable Benchmarking Mode                                      │
│   When enabled, adds "Run Benchmark" option after scoring       │
│                                                                 │
│ ─────────────────────────────────────────────────────────────   │
│                                                                 │
│ Models to Compare:                                              │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ ☑ anthropic:claude-sonnet-4-20250514      [Default]        │ │
│ │ ☑ anthropic:claude-3-5-haiku-20241022                      │ │
│ │ ☐ ollama:llama3.2                                          │ │
│ │ ☐ ollama:mistral                                           │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ [+ Add Model...]  [Configure Parameters...]                     │
│                                                                 │
│ ─────────────────────────────────────────────────────────────   │
│                                                                 │
│ Default Benchmark Settings:                                     │
│                                                                 │
│ Sample Size:  [All documents ▼]                                 │
│               ○ All documents                                   │
│               ○ Random sample: [10] documents                   │
│               ○ Top scoring: [10] documents                     │
│                                                                 │
│ Tasks to Benchmark:                                             │
│ ☑ Document Scoring                                              │
│ ☐ Citation Extraction                                           │
│ ☐ Quality Assessment                                            │
│                                                                 │
│ ─────────────────────────────────────────────────────────────   │
│                                                                 │
│ Cost Estimation:                                                │
│ With current settings, benchmarking 100 documents would cost:   │
│ • claude-sonnet-4-20250514: ~$0.45                             │
│ • claude-3-5-haiku-20241022: ~$0.12                            │
│ • ollama models: $0.00 (local)                                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 5.2 Config Extensions (`config.py`)

```python
@dataclass
class BenchmarkModelConfig:
    """Configuration for a single model in benchmarks."""
    provider: str
    model_name: str
    temperature: float = 0.1
    max_tokens: int = 256
    enabled: bool = True
    is_default: bool = False


@dataclass
class BenchmarkConfig:
    """Benchmarking configuration."""

    enabled: bool = False

    # Models to compare
    models: list[BenchmarkModelConfig] = field(default_factory=list)

    # Default settings
    sample_mode: str = "all"  # "all", "random", "top"
    sample_size: int = 10

    # Tasks to benchmark
    tasks: list[str] = field(default_factory=lambda: ["document_scoring"])

    def get_enabled_models(self) -> list[BenchmarkModelConfig]:
        """Get list of enabled benchmark models."""
        return [m for m in self.models if m.enabled]

    def get_default_model(self) -> Optional[BenchmarkModelConfig]:
        """Get the default model for comparison baseline."""
        for m in self.models:
            if m.is_default:
                return m
        return self.models[0] if self.models else None


# Add to LiteConfig
@dataclass
class LiteConfig:
    # ... existing fields ...
    benchmark: BenchmarkConfig = field(default_factory=BenchmarkConfig)
```

---

### 6. GUI Integration

#### 6.1 Benchmark Button in Systematic Review Tab

After scoring completes, show a "Run Benchmark" button:

```python
# In systematic_review_tab.py

def _on_scoring_complete(self, scored_docs: list[ScoredDocument]):
    """Handle scoring completion."""
    # ... existing code ...

    # Show benchmark option if enabled
    if self.config.benchmark.enabled:
        self.benchmark_button.setVisible(True)
        self.benchmark_button.setEnabled(True)
        self.benchmark_button.setText(
            f"Run Benchmark ({len(self.config.benchmark.get_enabled_models())} models)"
        )

def _on_benchmark_clicked(self):
    """Start benchmark run."""
    dialog = BenchmarkConfigDialog(
        config=self.config,
        documents=self.scored_documents,
        question=self.current_question,
        parent=self,
    )

    if dialog.exec() == QDialog.Accepted:
        self._run_benchmark(dialog.get_config())
```

#### 6.2 Benchmark Results Dialog

```
┌─────────────────────────────────────────────────────────────────┐
│ Benchmark Results                                         [X]   │
├─────────────────────────────────────────────────────────────────┤
│                                                                 │
│ Question: "Effects of exercise on depression in elderly"        │
│ Task: Document Scoring | Documents: 50 | Duration: 2m 34s       │
│                                                                 │
│ ═══════════════════════════════════════════════════════════════ │
│                                                                 │
│ MODEL COMPARISON                                                │
│ ┌───────────────────┬───────┬───────┬─────────┬───────────────┐ │
│ │ Model             │ Mean  │ StdDev│ Latency │ Cost          │ │
│ ├───────────────────┼───────┼───────┼─────────┼───────────────┤ │
│ │ claude-sonnet-4   │ 3.42  │ 1.21  │ 1.2s    │ $0.23         │ │
│ │ claude-3-5-haiku  │ 3.38  │ 1.18  │ 0.4s    │ $0.06         │ │
│ │ llama3.2          │ 3.15  │ 1.45  │ 2.1s    │ $0.00         │ │
│ └───────────────────┴───────┴───────┴─────────┴───────────────┘ │
│                                                                 │
│ AGREEMENT MATRIX (within ±1 score)                              │
│ ┌───────────────────┬──────────┬──────────┬──────────┐          │
│ │                   │ sonnet-4 │ haiku    │ llama3.2 │          │
│ ├───────────────────┼──────────┼──────────┼──────────┤          │
│ │ claude-sonnet-4   │ 100%     │ 92%      │ 78%      │          │
│ │ claude-3-5-haiku  │ 92%      │ 100%     │ 76%      │          │
│ │ llama3.2          │ 78%      │ 76%      │ 100%     │          │
│ └───────────────────┴──────────┴──────────┴──────────┘          │
│                                                                 │
│ SCORE DISTRIBUTION                                              │
│ [Stacked bar chart showing score distribution per model]        │
│                                                                 │
│ ═══════════════════════════════════════════════════════════════ │
│                                                                 │
│ [View Details]  [Export CSV]  [Export JSON]           [Close]   │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

#### 6.3 Document-Level Comparison View

Accessible via "View Details":

```
┌─────────────────────────────────────────────────────────────────┐
│ Document Comparison                                       [X]   │
├─────────────────────────────────────────────────────────────────┤
│ [Search: _______________]  [Filter: Score diff > 1 ▼]           │
│                                                                 │
│ ┌─────────────────────────────────────────────────────────────┐ │
│ │ ▼ "Exercise and Depression in Older Adults" (2023)          │ │
│ │   Smith et al. | Nature Medicine                            │ │
│ │   ┌─────────────┬─────────────┬─────────────┐               │ │
│ │   │ sonnet-4: 5 │ haiku: 5    │ llama3.2: 4 │               │ │
│ │   └─────────────┴─────────────┴─────────────┘               │ │
│ │   [Show explanations]                                       │ │
│ ├─────────────────────────────────────────────────────────────┤ │
│ │ ▼ "Meta-analysis of Physical Activity..." (2022)            │ │
│ │   Jones et al. | JAMA                                       │ │
│ │   ┌─────────────┬─────────────┬─────────────┐               │ │
│ │   │ sonnet-4: 4 │ haiku: 5    │ llama3.2: 3 │  ⚠ Disagree  │ │
│ │   └─────────────┴─────────────┴─────────────┘               │ │
│ │   [Show explanations]                                       │ │
│ │                                                             │ │
│ │   Expanded explanations:                                    │ │
│ │   ┌─ claude-sonnet-4 ─────────────────────────────────────┐ │ │
│ │   │ Score 4: Strong meta-analysis but focuses on general  │ │ │
│ │   │ adult population, not specifically elderly.           │ │ │
│ │   └───────────────────────────────────────────────────────┘ │ │
│ │   ┌─ claude-3-5-haiku ────────────────────────────────────┐ │ │
│ │   │ Score 5: Comprehensive meta-analysis directly         │ │ │
│ │   │ relevant to exercise and depression.                  │ │ │
│ │   └───────────────────────────────────────────────────────┘ │ │
│ └─────────────────────────────────────────────────────────────┘ │
│                                                                 │
│ Showing 50 documents | 8 with disagreements (>1 score diff)     │
│                                                         [Close] │
└─────────────────────────────────────────────────────────────────┘
```

---

### 7. Workflow: Minimal User Interaction

#### 7.1 One-Time Setup

1. User opens Settings → Benchmarking tab
2. Enables benchmarking mode
3. Selects models to compare (checkboxes)
4. Configures sample size (optional)
5. Saves settings

#### 7.2 Per-Review Benchmarking

1. User runs normal systematic review (scoring happens with default model)
2. After scoring completes, "Run Benchmark" button appears
3. User clicks button → Confirmation dialog shows estimated cost/time
4. Benchmark runs automatically in background
5. Results dialog opens when complete
6. User can export or review disagreements

#### 7.3 Re-using Existing Evaluations

```python
def run_benchmark(self, run_id: str, ...):
    for evaluator in evaluators:
        for document in documents:
            # Check for existing evaluation with same evaluator
            existing = self.storage.get_scored_document(
                document_id=document.id,
                evaluator_id=evaluator.id,
                question=run.question,
            )

            if existing:
                # Reuse existing evaluation - no API call needed
                all_scores_for_eval[document.id] = existing
            else:
                # Run new evaluation
                scored = self._evaluate_document(...)
```

This means:
- If user runs benchmark twice with same models, cached results are reused
- Only new models require API calls
- Changing the question invalidates cache (different context)

---

### 8. File Structure

```
src/bmlibrarian_lite/
├── benchmarking/
│   ├── __init__.py
│   ├── models.py           # Evaluator, EvaluatorStats, BenchmarkResult
│   ├── runner.py           # BenchmarkRunner class
│   ├── statistics.py       # Agreement, correlation calculations
│   ├── cost.py             # Cost calculation utilities
│   └── storage.py          # Benchmark-specific DB operations
├── gui/
│   ├── settings_dialog.py  # Add BenchmarkingTab
│   ├── benchmark_dialog.py # Results display dialog
│   ├── benchmark_details_dialog.py  # Document-level comparison
│   └── widgets/
│       ├── benchmark_table.py       # Results table widget
│       └── score_comparison.py      # Score comparison chips
├── data_models.py          # Extend ScoredDocument, add Evaluator
├── storage.py              # Add evaluators table, extend scored_documents
└── constants.py            # Add MODEL_PRICING
```

---

### 9. Implementation Phases

#### Phase 1: Database & Data Models ✅ COMPLETE
1. ✅ Create `evaluators` table schema
2. ✅ Extend `scored_documents` table with evaluator tracking
3. ✅ Create `benchmark_runs` table
4. ✅ Implement `Evaluator` dataclass
5. ✅ Extend `ScoredDocument` with metrics fields
6. ✅ Add storage methods for new tables
7. ✅ Add migration for existing data

#### Phase 2: Core Benchmarking Engine ✅ COMPLETE
1. ✅ Implement `BenchmarkRunner` class
2. ✅ Implement scoring with evaluator tracking
3. ✅ Add cost calculation utilities
4. ✅ Implement statistics calculations
5. ✅ Add caching/reuse of existing evaluations
6. ✅ Create `BenchmarkResult` model

#### Phase 3: Settings Integration ✅ COMPLETE
1. ✅ Create `BenchmarkConfig` dataclass
2. ✅ Add to `LiteConfig`
3. ✅ Create `BenchmarkingTab` for settings dialog
4. ✅ Implement model selection UI
5. ✅ Add cost estimation display

#### Phase 4: Execution UI ✅ COMPLETE
1. ✅ Add "Run Benchmark" button to SystematicReviewTab
2. ✅ Create benchmark confirmation dialog
3. ✅ Implement background worker for benchmark execution
4. ✅ Add progress display

#### Phase 5: Results Display ✅ COMPLETE
1. ✅ Create `BenchmarkResultsDialog`
2. ✅ Implement model comparison table
3. ✅ Implement agreement matrix display
4. ✅ Create score distribution visualization
5. ✅ Create document-level comparison view
6. ✅ Add export functionality (CSV, JSON)

#### Phase 6: Polish & Documentation ✅ COMPLETE
1. ✅ Add unit tests for statistics calculations
2. ✅ Add integration tests for benchmark workflow
3. ✅ Handle edge cases (network errors, model failures)
4. ✅ Optimize for large document sets
5. ✅ Add documentation (CLAUDE.md updated)

---

### 10. Future Extensions

1. **Human Evaluation UI**: Add interface for human reviewers to provide scores
2. **Active Learning**: Use disagreements to identify documents needing human review
3. **Model Fine-tuning Data**: Export evaluation data for model training
4. **Automated Model Selection**: Recommend models based on benchmark results
5. **Scheduled Benchmarks**: Run benchmarks automatically on new documents
6. **Ensemble Scoring**: Combine multiple model scores with weighting
7. **Task-Specific Benchmarks**: Extend to citation extraction, quality assessment
8. **Benchmark Presets**: Save and load benchmark configurations
9. **Historical Tracking**: Track model performance over time
10. **API Integration**: Expose benchmark functionality via API

---

### 11. Migration Strategy

For existing `scored_documents` entries without evaluator tracking:

```python
def migrate_scored_documents(storage: LiteStorage, config: LiteConfig):
    """Migrate existing scored documents to include evaluator."""

    # Create a default evaluator based on current config
    default_model = config.models.get_model_string("document_scoring")
    provider, model_name = default_model.split(":", 1)

    default_evaluator = Evaluator.from_model_config(
        provider=provider,
        model_name=model_name,
        temperature=0.1,  # Scoring default
    )

    # Ensure evaluator exists
    storage.upsert_evaluator(default_evaluator)

    # Update all scored_documents without evaluator_id
    storage.execute("""
        UPDATE scored_documents
        SET evaluator_id = ?
        WHERE evaluator_id IS NULL
    """, (default_evaluator.id,))
```

---

### 12. Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Evaluator as first-class entity | Separate `evaluators` table | Enables human evaluation, parameter variations, future ensemble |
| Extend existing tables vs. new | Extend `scored_documents` | Preserves existing workflow, gradual adoption |
| Caching strategy | Cache by (doc_id, evaluator_id, question) | Avoid redundant API calls, enable incremental benchmarks |
| Cost tracking granularity | Per-evaluation | Enables accurate cost comparison, budget tracking |
| Statistics in DB vs. computed | Computed on demand, summary cached | Flexibility for new metrics, storage efficiency |
| UI integration point | Button after scoring | Natural workflow, minimal disruption |
| Sample selection | User choice (all/random/top) | Balance thoroughness vs. cost |
