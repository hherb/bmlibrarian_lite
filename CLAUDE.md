# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

BMLibrarian Lite is a cross-platform biomedical literature research tool that provides AI-powered systematic review and medical fact-checking capabilities. The project includes:

1. **Desktop Application** (Python/PySide6): Uses SQLite + sqlite-vec for storage, FastEmbed for CPU-optimized embeddings, and supports Anthropic Claude or Ollama for LLM inference.

2. **iOS App** (Swift/SwiftUI): Native mobile app for medical fact-checking with SwiftData persistence, Apple NLEmbedding for on-device semantic similarity, and OpenAI-compatible LLM API support.

3. **macOS App** (Swift/SwiftUI): Native desktop app sharing code with iOS via the BioMedLit Swift package.

4. **Android App** (Kotlin/Jetpack Compose): Native mobile app using Room for persistence, Hilt for dependency injection, and the same OpenAI-compatible LLM API approach.

## Cross-Platform Architecture

### Shared Swift Package: BioMedLit

The `Packages/BioMedLit/` Swift package provides reusable, side-effect-free components shared between iOS and macOS:

- **JATS XML Parsing** (`JATSXMLParser`): Converts JATS XML to HTML and Markdown with figure URLs, table extraction, and reference parsing
- **Europe PMC Service** (`EuropePMCService`): Cursor-based search with pagination
- **PubMed Service** (`PubMedService`): NCBI E-utilities wrapper with rate limiting
- **Full-Text Service** (`FullTextService`): Unified retrieval with fallback chain (Europe PMC XML → Unpaywall PDF → DOI resolution)
- **Retry Helper** (`RetryHelper`): Exponential backoff with jitter

### Cross-Platform Documentation

All architectural decisions and platform-agnostic algorithms are documented in `doc/cross_platform/` using pseudocode that translates easily to Python, Swift, or Kotlin. Key documents:

- `hybrid_search.md` - Combined PubMed + Europe PMC search with pagination and deduplication
- `jats_parsing.md` - JATS XML parsing strategies and edge cases
- `fulltext_retrieval.md` - Full-text acquisition fallback chain

When implementing features, improvements should flow across all platforms:
1. Document the algorithm in `doc/cross_platform/`
2. Implement in the BioMedLit Swift package (iOS/macOS)
3. Port to Python for the desktop app
4. Port to Kotlin for Android

### Search Provider Strategy

BMLibrarian supports hybrid search across PubMed and Europe PMC:

- **PubMed**: NCBI E-utilities with offset-based pagination (max 9999)
- **Europe PMC**: REST API with cursor-based pagination (more scalable)

Both providers are queried in parallel, with results deduplicated by PMID → DOI → PMC ID → title similarity (Jaccard > 0.8).

### Full-Text Retrieval Chain

1. **Europe PMC XML** (preferred): Machine-readable JATS format
2. **Unpaywall PDF**: Open access PDFs via `https://api.unpaywall.org/v2/{doi}`
3. **DOI Resolution**: Fall back to publisher website

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

**Search Integration** (`pubmed/`, `europepmc.py`, `search_merger.py`)
- `PubMedSearchClient` - NCBI E-utilities wrapper with offset pagination
- `EuropePMCClient` - Europe PMC REST API with cursor pagination
- `SearchResultMerger` - Deduplicates and merges results from both providers
- `QueryTranslator` - Converts PubMed queries to Europe PMC syntax

**Full-Text Discovery** (`fulltext_discovery.py`, `pdf_discovery.py`)
- `FullTextDiscoverer` - Tries Europe PMC XML, Unpaywall, DOI resolution
- `PDFDiscoverer` - Legacy PDF-focused discovery

**Quality Assessment** (`quality/`)
- Study classification, evidence grading, and quality scoring
- `QualityManager` orchestrates the assessment workflow
- `QualityAssessment` dataclass with study design, quality tier, and extraction details

**Model Benchmarking** (`benchmarking/`)
- Compare multiple LLM models on document scoring tasks
- `BenchmarkRunner` - Orchestrates benchmark execution with caching and progress tracking
- `BenchmarkResult` - Complete results with per-evaluator statistics and agreement matrix

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

#### Audit Trail Tab

The Audit Trail provides transparency into the systematic review workflow with three sub-tabs:

- **Queries Tab** (`audit_queries_tab.py`): Displays generated PubMed queries with statistics
- **Literature Tab** (`audit_literature_tab.py`): Scrollable document cards with relevance scores and quality badges
- **Citations Tab** (`audit_citations_tab.py`): Document cards with highlighted citation passages

**Document Cards** (`document_card.py`):
- Collapsible cards - click to expand and show abstract
- Quality badges (RCT, SR, etc.) with color-coded study design
- Score badges (1-5) with color gradients
- Source badges showing PubMed, Europe PMC, or both
- LLM rationale display for scoring and quality decisions

### Data Flow

1. User enters research question → `SearchAgent` converts to search queries
2. `SearchService` fetches from PubMed + Europe PMC in parallel
3. `SearchResultMerger` deduplicates results → stored in `LiteStorage`
4. `LiteEmbedder` (FastEmbed) creates embeddings → stored in ChromaDB
5. `QualityManager` assesses study quality (optional)
6. `ScoringAgent` scores relevance → `CitationAgent` extracts citations
7. `ReportingAgent` generates final report
8. Audit Trail tab displays real-time progress throughout

## Key Patterns

- **Lazy initialization**: LLM clients and embedders are created on first use
- **Qt signals/slots**: GUI components communicate via Qt signal system
- **Dataclasses throughout**: `LiteDocument`, `LiteChunk`, `SearchSession`, etc.
- **Thread-safe updates**: Use `threading.RLock()` for concurrent access
- **DPI scaling**: Use `scaled()` function for all pixel dimensions

## Constants (from `constants.py`)

Key search constants:
- `EUROPEPMC_SEARCH_PAGE_SIZE` - Europe PMC batch size (default: 100)
- `EUROPEPMC_INITIAL_CURSOR` - Initial cursor value ("*")
- `TITLE_SIMILARITY_THRESHOLD` - Jaccard threshold for deduplication (0.8)

Key audit trail constants:
- `AUDIT_CARD_PADDING`, `AUDIT_CARD_SPACING` - Card layout dimensions
- `AUDIT_CARD_HEADER_COLOR` - Pale light blue header (`#E3F2FD`)
- `MAX_AUTHORS_BEFORE_ET_AL` - Authors to show before "et al." (3)

Key benchmarking constants:
- `MODEL_PRICING` - Cost per 1M tokens for each supported model
- `BENCHMARK_QUESTION_HASH_LENGTH` - Hash length for question matching (16)

## Environment Variables

- `ANTHROPIC_API_KEY` - Required for Claude API
- `OLLAMA_HOST` - Ollama server URL (default: http://localhost:11434)
- `NCBI_EMAIL` - Recommended for PubMed API
- `TOKENIZERS_PARALLELISM=false` - Set automatically to avoid HuggingFace warnings

## Documentation Structure

```
doc/
├── user/              # End-user documentation
│   └── guide.md
├── developer/         # Developer documentation
│   ├── guide.md
│   └── europepmc_and_pubmed.md  # API integration guide
├── llm/               # LLM assistant context
│   ├── context.md
│   ├── database-schema.md
│   └── golden_rules.md
├── cross_platform/    # Platform-agnostic algorithms (pseudocode)
│   ├── hybrid_search.md
│   ├── jats_parsing.md
│   └── fulltext_retrieval.md
└── planning/          # Planning documents
    ├── android/       # Android implementation plans
    └── fulltext_retrieval/  # Full-text feature plans
```

## iOS App Architecture (`ios/MedicalFactChecker/`)

The iOS app is a native SwiftUI application for medical fact-checking.

### Project Structure

```
ios/MedicalFactChecker/
├── Sources/
│   ├── App/
│   │   ├── MedicalFactCheckerApp.swift  # App entry point, URL handling
│   │   └── ContentView.swift             # Tab-based navigation
│   ├── Models/
│   │   ├── AppSettings.swift            # UserDefaults + Keychain settings
│   │   ├── FactCheckSession.swift       # @Model for workflow sessions
│   │   ├── Document.swift               # @Model for documents
│   │   ├── SearchProvider.swift         # PubMed, Europe PMC, or both
│   │   ├── StructuredQuery.swift        # Cross-provider query representation
│   │   └── QueryConstants.swift         # Query builder constants
│   ├── Services/
│   │   ├── FactCheckWorkflow.swift      # Main workflow orchestration
│   │   ├── SearchServiceProtocol.swift  # Unified search interface
│   │   ├── LLMService.swift             # OpenAI-compatible API client
│   │   └── EmbeddingService.swift       # Apple NLEmbedding scoring
│   ├── Views/
│   │   ├── FactCheck/
│   │   │   ├── FactCheckView.swift      # Main fact-checking UI
│   │   │   ├── ScoredDocumentsView.swift # Document cards
│   │   │   └── FullTextViewer.swift     # JATS/PDF viewer
│   │   └── Components/
│   │       ├── SearchOptionsView.swift  # Provider selection
│   │       ├── DocumentSourceBadge.swift # Source indicator
│   │       └── FullTextSourceBadge.swift # Full-text source indicator
│   └── Utilities/
│       ├── BioMedLitAdapters.swift      # Adapters for BioMedLit package
│       ├── SearchResultMerger.swift     # Deduplication logic
│       ├── QueryTranslator.swift        # PubMed ↔ Europe PMC queries
│       └── JATSXMLParser.swift          # Legacy (now uses BioMedLit)
└── Package.swift                         # BioMedLit dependency
```

### Key iOS Patterns

**SwiftData Models**
- All data models use `@Model` macro for SwiftData persistence
- `Document.source` tracks origin (PubMed, Europe PMC, or both)
- `Document.fullTextSource` tracks how full text was obtained

**Search Provider Selection**
- `SearchProvider` enum: `.pubMed`, `.europePMC`, `.both`
- `StructuredQuery` represents provider-agnostic queries
- `QueryTranslator` converts between provider-specific syntaxes

**Full-Text Viewing**
- `FullTextViewer` displays JATS XML (via BioMedLit parser) or PDFs
- Figure images loaded from Europe PMC URLs
- HTML rendering for complex tables

**Workflow Steps** (in `FactCheckWorkflow`)
1. `convertingQuery` - LLM converts claim to structured query
2. `searchingPubMed` - Fetch from selected providers
3. `scoringDocuments` - LLM + embedding scoring
4. `extractingCitations` - Extract key passages
5. `generatingReport` - Synthesize evidence report

## macOS App Architecture (`macos/MedicalFactCheckerMac/`)

The macOS app shares most code with iOS via the BioMedLit package.

### Key Differences from iOS

- Uses `MacContentView` instead of `ContentView`
- Platform-specific views prefixed with `Mac` (e.g., `MacFactCheckView`)
- Larger layouts optimized for desktop
- Menu bar integration

### Shared via BioMedLit Package

- `JATSXMLParser` - JATS XML parsing
- `EuropePMCService` - Search API client
- `PubMedService` - Search API client
- `FullTextService` - Full-text retrieval
- `RetryHelper` - Network retry logic

## Android App Architecture (`android/MedicalFactChecker/`)

The Android app uses Jetpack Compose with MVVM architecture.

### Project Structure

```
android/MedicalFactChecker/
├── app/src/main/java/com/bmlibrarian/factchecker/
│   ├── data/
│   │   ├── local/
│   │   │   ├── AppDatabase.kt           # Room database
│   │   │   ├── dao/                     # Data access objects
│   │   │   └── entity/                  # Room entities
│   │   ├── remote/
│   │   │   ├── pubmed/                  # PubMed API
│   │   │   ├── europepmc/               # Europe PMC API
│   │   │   │   ├── EuropePMCApi.kt      # Retrofit interface
│   │   │   │   ├── EuropePMCService.kt  # Service wrapper
│   │   │   │   └── EuropePMCModels.kt   # Response models
│   │   │   └── llm/                     # LLM API
│   │   └── repository/                  # Repository pattern
│   ├── domain/
│   │   ├── model/
│   │   │   ├── SearchProvider.kt        # Provider enum
│   │   │   └── EuropePMCError.kt        # Error types
│   │   ├── usecase/                     # Use cases
│   │   └── workflow/
│   │       ├── FactCheckWorkflow.kt     # Workflow orchestration
│   │       └── WorkflowState.kt         # State machine
│   ├── ui/
│   │   ├── factcheck/                   # Fact check screen
│   │   │   ├── FactCheckScreen.kt
│   │   │   ├── FactCheckViewModel.kt
│   │   │   └── components/
│   │   │       ├── DocumentCard.kt
│   │   │       └── SearchProviderSelector.kt
│   │   ├── settings/                    # Settings screen
│   │   ├── history/                     # History screen
│   │   └── report/                      # Report screen
│   ├── di/                              # Hilt modules
│   │   ├── NetworkModule.kt
│   │   └── WorkflowModule.kt
│   └── util/
│       ├── Constants.kt                 # App constants
│       ├── NetworkRetry.kt              # Retry logic
│       └── ResponseParser.kt            # LLM response parsing
└── app/src/test/                        # Unit tests
```

### Key Android Patterns

**Architecture**
- MVVM with Hilt dependency injection
- Room for local persistence
- Retrofit + OkHttp for networking
- Kotlin coroutines + Flow for async

**Search Integration**
- `SearchProvider` enum mirrors iOS/macOS
- `EuropePMCService` implements cursor-based pagination
- `NetworkRetry.withExponentialBackoff()` for resilient requests

**State Management**
- `WorkflowState` sealed class for workflow states
- `StateFlow` for reactive UI updates
- `ViewModel` survives configuration changes

## BioMedLit Swift Package (`Packages/BioMedLit/`)

Reusable Swift package for biomedical literature services.

### Public API

```swift
// Configuration
BioMedLit.configure(with: BioMedLitConfiguration(
    ncbiEmail: "your@email.com",
    logger: MyLogger()
))

// JATS Parsing
let parser = JATSXMLParser(data: xmlData, knownPMCId: "PMC1234567")
let markdown = try parser.parseToMarkdown()
let html = try parser.parseToHTML()
let article = try parser.parseToArticle()

// Search
let europePMC = EuropePMCService()
let results = try await europePMC.search(query: "COVID-19")

let pubmed = PubMedService(email: "your@email.com")
let results = try await pubmed.search(query: "COVID-19")

// Full Text
let fullText = FullTextService(email: "your@email.com")
let result = try await fullText.fetchFullText(pmcId: "PMC1234567")
```

### Key Types

- `JATSArticle` - Parsed article with sections, figures, tables, references
- `SearchArticle` - Search result from either provider
- `SearchResult` - Results container with pagination
- `FullTextResult` - Enum for different full-text sources

## Related Documentation

- `doc/llm/golden_rules.md` - MUST READ: Coding standards and rules
- `doc/developer/europepmc_and_pubmed.md` - API integration details
- `doc/cross_platform/` - Platform-agnostic algorithm documentation
- `Packages/BioMedLit/README.md` - Swift package documentation
