# CLAUDE.md

## Project Overview

BMLibrarian Lite: Cross-platform biomedical literature research with AI-powered systematic review and fact-checking.

**Platforms:**
- **Desktop** (Python/PySide6): SQLite + sqlite-vec, FastEmbed, Anthropic/Ollama
- **iOS/macOS** (Swift/SwiftUI): SwiftData, NLEmbedding, OpenAI-compatible API
- **Android** (Kotlin/Compose): Room, Hilt, MVVM

**Current version:** 0.3.0

## Commands

```bash
# Setup
uv venv && source .venv/bin/activate && uv pip install -e ".[dev]"

# Run
bmll                    # CLI
bmlibrarian-lite-gui    # GUI

# Dev
pytest tests/
ruff check .
mypy src/
```

## Python Structure (`src/bmlibrarian_lite/`)

```
agents/               # SearchAgent, ScoringAgent, CitationAgent, ReportingAgent, InterrogationAgent, report_risk_helpers
benchmarking/         # Model comparison, statistics (relevance + quality)
gui/                  # PySide6: SystematicReview, ResearchQuestions, AuditTrail, Report, DocumentInterrogation tabs
                      #   transparency_badge, transparency_settings_dialog, quality_badge, quality_filter_panel
llm/                  # LLMClient (Anthropic/Ollama providers), token_tracker
pubmed/               # PubMedSearchClient
quality/              # QualityManager, study classification, evidence_summary, metadata_filter
transparency/         # TransparencyManager, transparency_models, transparency_settings
study_transparency_analyzer/  # Full LLM-based transparency analysis (funding, COI, data availability, trial registration)
config.py             # LiteConfig (~/.bmlibrarian_lite/)
storage.py            # LiteStorage (SQLite + sqlite-vec)
data_models.py        # LiteDocument, ScoredDocument, Citation, SearchProvider, pagination models
europepmc.py          # EuropePMCClient (cursor pagination)
search_service.py     # Unified search across PubMed + Europe PMC
search_merger.py      # Deduplication (PMID/DOI/PMC/title)
query_translator.py   # Natural language → structured query
fulltext_discovery.py # Europe PMC XML → Unpaywall PDF → DOI fallback
pdf_discovery.py      # PDF source discovery
embeddings.py         # LiteEmbedder (FastEmbed)
chunking.py           # Text chunking utilities
pdf_utils.py          # PDF text extraction
constants.py          # Application constants
exceptions.py         # Custom exception hierarchy
```

## Mobile Apps

**iOS** (`ios/MedicalFactChecker/`), **macOS** (`macos/MedicalFactCheckerMac/`):
- SwiftUI + SwiftData models (Document, FactCheckSession, SearchProvider, FullTextSource, SchemaVersions)
- Services: FactCheckWorkflow, LLMService, EmbeddingService, ParallelScoringService, ParallelCitationService, CheckpointedScoringService, CheckpointManager, ModelFetchService, CloudKitConfiguration, BackgroundTaskManager
- Views: FactCheck, FullText, History, Report, Settings, Onboarding
- Components: TransparencyDetailView, TransparencyRiskBadge, TransparencySummarySection, ErrorQueueView, ProcessingProgressView

**Android** (`android/MedicalFactChecker/`):
- data/local: Room DB + DAOs
- data/remote: PubMed, Europe PMC, LLM, Unpaywall, FullText APIs
- domain: Models, WorkflowState, workflow/ (scoring, searching, reporting)
- ui: Compose screens + ViewModels (factcheck, report, history, settings, fulltext, onboarding)
- ui/components: DocumentCard (with transparency), FullTextSourceBadge, SortingControls
- util: JATSXMLParser, JATSModels, CostCalculator, ResponseParser, PdfExporter
- di: Hilt modules (App, Workflow, Network, Database)

## BioMedLit Swift Package (`Packages/BioMedLit/`)

Shared iOS/macOS components:
- `JATS/`: XML parsing → HTML/Markdown (JATSXMLParser, JATSModels)
- `Services/`: EuropePMCService, PubMedService, FullTextService
- `Transparency/`: Study transparency analysis
  - `Analysis/`: TransparencyScorer, FundingAnalyzer, COIAnalyzer, DataAvailabilityAnalyzer, TrialComplianceAnalyzer
  - `Models/`: TransparencyModels, TransparencyConstants
  - `Services/`: TransparencyAnalysisService, ClinicalTrialsService, CrossRefService
- `Sync/`: iCloud/local folder sync
  - SyncEngine, SyncCoordinator, SelectiveSyncCoordinator, SyncStateManager, SyncScopeManager
  - iCloudSyncStorage, LocalFolderSyncStorage, OnDemandFetcher
  - SessionEvictionManager, WorkspaceInitializer, StorageMonitor
  - ChangeLogReader/Writer, LWWMergeStrategy, IntegrityFunctions
- `Utilities/`: RetryHelper, CostCalculator, BudgetChecker, QueryTranslator, ResponseParser, SearchResultMerger, ParallelProcessingConstants, ConcurrencyDetector

## Code Style

- Google-style docstrings, type hints mandatory
- No magic numbers → use `constants.py`
- DPI scaling → use `scaled()` for pixels
- No inline stylesheets
- Pure functions in focused modules

## Environment

- `ANTHROPIC_API_KEY` - Claude API
- `OLLAMA_HOST` - Ollama (default: localhost:11434)
- `NCBI_EMAIL` - PubMed API (recommended)

## Key Docs

- `doc/llm/golden_rules.md` - Python/PySide standards
- `doc/llm/general_golden_rules.md` - Swift/Kotlin standards
- `doc/cross_platform/` - Platform-agnostic algorithms (parallel processing, full-text retrieval, hybrid search, JATS parsing, sync protocol)
- `doc/developer/europepmc_and_pubmed.md` - API guide
- `doc/developer/guide.md` - Developer guide with architecture, code style, release process

Always use Context7 MCP when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.
