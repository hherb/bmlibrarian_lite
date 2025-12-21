# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BMLibrarian Lite is a lightweight biomedical literature research tool that provides AI-powered systematic review and document interrogation capabilities. It uses ChromaDB + SQLite for storage (no PostgreSQL), FastEmbed for CPU-optimized embeddings, and supports Anthropic Claude or Ollama for LLM inference.

## Common Commands

```bash
# Create virtual environment and install with uv
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"

# Run the GUI (default)
python bmlibrarian_lite.py

# Run tests
pytest

# Run a single test file
pytest tests/test_foo.py

# Run a specific test
pytest tests/test_foo.py::test_function_name

# Run linting
ruff check .

# Run type checking
mypy src/

# CLI commands
python bmlibrarian_lite.py stats        # Storage statistics
python bmlibrarian_lite.py validate     # Validate configuration
python bmlibrarian_lite.py config       # Show configuration
python bmlibrarian_lite.py clear        # Clear all data
```

## Code Style Requirements

- **Docstrings are mandatory**: Use Google-style docstrings on all public functions, classes, and methods
- **Type hints are mandatory**: All function parameters and return types must be annotated
- **No magic numbers**: Always use named constants or configuration values; never hardcode numbers
- **Prefer pure functions**: Write small, reusable pure functions in focused modules over complex long files
- **Constants go in `constants.py`**: Centralize numeric and string constants
- **No inline stylesheets**: All stylesheets via the centralised styling system
- **No hardcoded pixel values**: Use `scaled()` from `dpi_scale.py` for DPI-aware dimensions

## Architecture

### Entry Points
- `bmlibrarian_lite.py` - CLI entry point with subcommands (gui, stats, validate, config, clear)
- `src/bmlibrarian_lite/gui/app.py` - PySide6 main window with tabbed interface

### Core Layers

**Configuration & Storage** (`config.py`, `storage.py`)
- `LiteConfig` - Dataclass-based configuration with JSON persistence in `~/.bmlibrarian_lite/`
- `LiteStorage` - Manages ChromaDB collections and SQLite metadata

**LLM Integration** (`llm/`)
- `LLMClient` - Unified client supporting both Anthropic and Ollama providers
- Model strings use format: `provider:model` (e.g., `anthropic:claude-sonnet-4-20250514`, `ollama:llama3.2`)

**Agent System** (`agents/`)
- `LiteBaseAgent` - Base class providing LLM communication via `_chat()` method
- Specialized agents: `SearchAgent`, `ScoringAgent`, `CitationAgent`, `ReportingAgent`, `InterrogationAgent`
- Agents inherit config and share LLM client instance

**PubMed Integration** (`pubmed/`)
- `PubMedSearchClient` - Wrapper around NCBI E-utilities API
- Converts natural language to PubMed queries
- Europe PMC full-text XML retrieval support

**PDF Discovery** (`pdf_discovery.py`)
- `PDFDiscoverer` - Finds and downloads PDFs from PubMed Central, Unpaywall, and DOI resolution

**Quality Assessment** (`quality/`)
- Study classification, evidence grading, and quality scoring
- `QualityManager` orchestrates the assessment workflow
- `QualityAssessment` dataclass with study design, quality tier, and extraction details

**Model Benchmarking** (`benchmarking/`)
- Compare multiple LLM models on document scoring tasks
- `BenchmarkRunner` - Orchestrates benchmark execution with caching and progress tracking
- `BenchmarkResult` - Complete results with per-evaluator statistics and agreement matrix
- `EvaluatorStats` - Per-model metrics (mean score, latency, tokens, cost)
- `DocumentComparison` - Per-document scores across all evaluators
- Statistics functions: `compute_agreement_matrix`, `compute_evaluator_stats`

### GUI Structure (`gui/`)

The PySide6 GUI uses a multi-tab design:
- `ResearchQuestionsTab` - List past research questions, re-run with deduplication
- `SystematicReviewTab` - Search PubMed, score documents, extract citations, generate reports
- `AuditTrailTab` - Real-time workflow visibility
- `ReportTab` - View and export generated reports
- `DocumentInterrogationTab` - Load documents and perform Q&A

#### Research Questions Tab

The Research Questions tab (`research_questions_tab.py`) enables re-running past searches:

- **Question List**: Shows past research questions with metadata (last run, doc count, scored count)
- **Incremental Search**: Re-runs PubMed query with offset pagination
- **Deduplication**: Skips documents already scored for this question
- **IncrementalSearchWorker**: Background worker for paginated search with progress

**Key Signals:**
- `new_documents_found(str, list)` - New documents found (question, documents)

#### Audit Trail Tab

The Audit Trail provides transparency into the systematic review workflow with three sub-tabs:

- **Queries Tab** (`audit_queries_tab.py`): Displays generated PubMed queries with statistics (docs found, scored, citations extracted)
- **Literature Tab** (`audit_literature_tab.py`): Scrollable document cards with relevance scores and quality badges
- **Citations Tab** (`audit_citations_tab.py`): Document cards with highlighted citation passages

**Document Cards** (`document_card.py`):
- Collapsible cards - click to expand and show abstract
- Quality badges (RCT, SR, etc.) with color-coded study design
- Score badges (1-5) with color gradients
- LLM rationale display for scoring and quality decisions
- Right-click context menu to send documents to interrogator
- Pale blue header background for visual distinction

**Key Audit Trail Signals:**
- `workflow_started` - Clears previous audit data
- `query_generated(str)` - New PubMed query generated
- `documents_found(list[LiteDocument])` - Documents retrieved
- `document_scored(ScoredDocument)` - Relevance score assigned
- `quality_assessed(str, QualityAssessment)` - Quality assessment complete
- `citation_extracted(Citation)` - Citation passage extracted

Background operations use `QThread` workers in `workers.py` to keep the UI responsive.

#### Benchmarking Dialogs

The benchmarking system adds model comparison capabilities:

- **BenchmarkConfirmDialog** (`benchmark_dialog.py`): Configure benchmark runs - select models, sampling, view cost estimates
- **BenchmarkProgressDialog** (`benchmark_dialog.py`): Show progress during benchmark execution
- **BenchmarkResultsDialog** (`benchmark_results_dialog.py`): Four-tab results display:
  - *Model Comparison*: Table with mean score, std dev, latency, tokens, cost per evaluator
  - *Agreement Matrix*: Pairwise agreement percentages (within ±1 score tolerance)
  - *Score Distribution*: Score counts (1-5) per evaluator
  - *Document Details*: Per-document scores with filter for disagreements

**Benchmark Workflow:**
1. After scoring completes, "Run Benchmark" button appears (if benchmarking enabled in settings)
2. User configures models and sample size in confirmation dialog
3. `BenchmarkWorker` executes benchmark in background thread
4. Results dialog displays comparison with export options (CSV, JSON)

**Benchmark Signals:**
- `BenchmarkWorker.progress(int, int, str)` - Progress updates (current, total, message)
- `BenchmarkWorker.finished(BenchmarkResult)` - Benchmark complete
- `BenchmarkWorker.error(str)` - Error occurred

### Data Flow

1. User enters research question → `SearchAgent` converts to PubMed query
2. `PubMedSearchClient` fetches articles → stored in `LiteStorage`
3. `LiteEmbedder` (FastEmbed) creates embeddings → stored in ChromaDB
4. `QualityManager` assesses study quality (optional)
5. `ScoringAgent` scores relevance → `CitationAgent` extracts citations
6. (Optional) `BenchmarkRunner` compares multiple models on scored documents
7. `ReportingAgent` generates final report
8. Audit Trail tab displays real-time progress throughout

## Key Patterns

- **Lazy initialization**: LLM clients and embedders are created on first use
- **Qt signals/slots**: GUI components communicate via Qt signal system
- **Dataclasses throughout**: `LiteDocument`, `LiteChunk`, `SearchSession`, etc.
- **Thread-safe updates**: Use `threading.RLock()` for concurrent access
- **DPI scaling**: Use `scaled()` function for all pixel dimensions

## Constants (from `constants.py`)

Key audit trail constants:
- `AUDIT_CARD_PADDING`, `AUDIT_CARD_SPACING` - Card layout dimensions
- `AUDIT_CARD_BORDER_RADIUS`, `AUDIT_CARD_MIN_HEIGHT` - Card styling
- `AUDIT_CARD_HEADER_COLOR` - Pale light blue header (`#E3F2FD`)
- `AUDIT_RATIONALE_COLOR` - Muted text for LLM rationales (`#555555`)
- `AUDIT_ABSTRACT_MAX_LINES` - Maximum abstract lines before scroll (15)
- `MAX_AUTHORS_BEFORE_ET_AL` - Authors to show before "et al." (3)

Key benchmarking constants:
- `MODEL_PRICING` - Cost per 1M tokens for each supported model
- `DEFAULT_MODEL_PRICING` - Fallback pricing for unknown models
- `get_model_pricing(model_string)` - Get pricing for a model
- `calculate_cost(model, input_tokens, output_tokens)` - Calculate cost in USD
- `BENCHMARK_QUESTION_HASH_LENGTH` - Hash length for question matching (16)

Key incremental search constants:
- `INCREMENTAL_SEARCH_BATCH_SIZE` - Batch size for PubMed offset pagination (100)
- `DEFAULT_TARGET_NEW_DOCUMENTS` - Default target new documents (50)
- `MAX_PUBMED_SEARCH_OFFSET` - Maximum PubMed API offset (9999)

## Environment Variables

- `ANTHROPIC_API_KEY` - Required for Claude API
- `OLLAMA_HOST` - Ollama server URL (default: http://localhost:11434)
- `NCBI_EMAIL` - Recommended for PubMed API
- `TOKENIZERS_PARALLELISM=false` - Set automatically to avoid HuggingFace warnings

## Documentation Structure

```
doc/
├── user/           # End-user documentation
│   └── guide.md    # User guide
├── developer/      # Developer documentation
│   └── guide.md    # Developer guide
├── llm/            # LLM assistant context
│   ├── context.md  # General LLM context
│   ├── database-schema.md  # Database schema reference
│   └── golden_rules.md     # Coding standards
└── planning/       # Planning documents
```

## Related Documentation

- `doc/llm/golden_rules.md` - MUST READ: Coding standards and rules
- `doc/llm/database-schema.md` - Database schema reference
- `doc/llm/context.md` - Extended LLM context
- `doc/developer/guide.md` - Developer guide
- `doc/user/guide.md` - User guide
