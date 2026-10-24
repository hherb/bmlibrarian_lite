# CLAUDE.md

## Project Overview

BMLibrarian Lite: Cross-platform biomedical literature research with AI-powered systematic review and fact-checking.

**Platforms:**
- **Desktop** (Python/PySide6): SQLite + sqlite-vec, FastEmbed, Anthropic/Ollama
- **iOS/macOS** (Swift/SwiftUI): SwiftData, NLEmbedding, OpenAI-compatible API
- **Android** (Kotlin/Compose): Room, Hilt, MVVM

**Current version:** 0.5.0

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
                      #   thread_keeper (holds a thread its owner let go of until it ends)
                      #   rescue_attempt / browser_rescue_service (the hidden and shown browser visits), web_engine (QtWebEngine start-up)
                      #   review_queue_dialog (walled PDFs' review queue), rescue_queue_indicator, rescue_view (the only runtime QtWebEngineWidgets import)
                      #   retraction_badge (RETRACTED / CONCERN / NOT CHECKED)
llm/                  # LLMClient (Anthropic/Ollama providers), token_tracker
pubmed/               # PubMedSearchClient; record_ids (a record's own ids, the record for a PMID)
quality/              # QualityManager, study classification, evidence_summary, metadata_filter
transparency/         # TransparencyManager, transparency_models, transparency_settings, assessment (shared analysis body)
study_transparency_analyzer/  # Full LLM-based transparency analysis (funding, COI, data availability, trial registration)
config.py             # LiteConfig (~/.bmlibrarian_lite/)
storage.py            # LiteStorage (SQLite + sqlite-vec)
data_models.py        # LiteDocument, ScoredDocument, Citation, SearchProvider, RequestFailure, RetrievalShortfall, pagination models
europepmc.py          # EuropePMCClient (cursor pagination)
jats_markdown.py      # JATS XML → markdown; front/back-matter statements; cache version
search_service.py     # Unified search across PubMed + Europe PMC
search_failures.py    # RequestFailure from requests errors; shortfall clauses, notice, advice, session metadata
analysis_failures.py  # AnalysisShortfall → notice, advice (the stages after the search); also_failed_text
audit_records.py      # What became of each document: accepted/rejected/failed/not scored
search_merger.py      # Deduplication (PMID/DOI/PMC/title)
citation_text.py      # Pure: full-text score, the methodology's full-text sentence
citation_full_texts.py # Fetching the full texts citations read (discovery chain, one at a time)
citation_reads_store.py # citation_reads table: which text each paper's citations were read from
full_text_retry.py    # Retry Full Text: read a reviewed run's unread full texts (and uploads), write its report again
full_text_upload.py   # Upload Full Text: a reader's PDF/HTML/Markdown/text file read into text, or refused
uploaded_full_texts_store.py # uploaded_full_texts table: each paper's last uploaded full text
smart_search.py       # Alternative queries when a question's own finds too little (prompt, parse, a round); shortfalls marked alternative
smart_search_store.py # smart_search_run_queries table: the alternative queries run per run (checkpoint)
more_evidence.py      # Find More Evidence: more documents scored into a reviewed run, its report written again
query_translator.py   # Natural language → structured query
fulltext_discovery.py # Europe PMC XML → PMC open-data bucket → Europe PMC PDF → Elsevier's API (10.1016/, with a key) → Unpaywall PDFs → OpenAlex PDFs → DOI download → CORE text (with a key)
pmc_open_data.py      # PmcOpenDataClient: PMC's open-data S3 bucket (JATS by PMC ID)
openalex.py           # OpenAlexLocationsClient: the PDFs OpenAlex's locations name (by DOI)
core_api.py           # CoreTextClient: CORE's extracted text by DOI (user's key); CoreThrottle (429 pause, refused key)
elsevier_api.py       # ElsevierArticleClient: Elsevier's article API, keyed PDF by DOI (10.1016/ only); ElsevierFetch, ElsevierSession
retraction_export.py  # Local Retraction Watch copy: ExportCopy state, export_evidence, refresh_export (atomic swap)
retraction_crossref.py # Crossref retraction lookups over the polite session (not asked ≠ unreachable)
retraction_store.py   # retraction_checks table, PaperCheck
retraction_checks.py  # RetractionChecker: reuse/replace stored verdicts; an outage never erases one
retraction_screen.py  # Pure: RetractionScreen (kept/excluded), screen_with_fallback, RetractionSnapshot
retraction_text.py    # Reader-facing retraction sentences (notice, causes, status lines)
keyed_service_session.py # KeyedServiceSession: a keyed service's 429 pause, refused key, refused network (process-wide)
bot_walls.py          # Bot-wall challenge pages recognised from an answer (#480): WALL_MARKERS, challenge_markers
pdf_download.py       # PDF download helpers: body prefix, .part, .unchecked and .held files, MAX_PDF_SIZE
pdf_discovery.py      # PDF source discovery
pdf_title_check.py    # Is a PDF the article? Its first page's share of the title's word pairs, or the whole title (#532, #546)
pdf_library_check.py  # A cached PDF found not to carry the title is not read: .mismatch set-aside, .kept marker, bmll keep-pdf (#541)
browser_rescue.py     # Walled PDFs queued for the embedded browser: states, verdicts, what is queued
browser_rescue_text.py # What the reader reads about the rescue queue: labels, sentences
rescue_queue_store.py # The browser rescue queue's table
rate_limit.py         # Host-keyed, thread-safe pacing for outbound requests
polite_session.py     # PoliteAdapter + mount_politely for requests.Session
embeddings.py         # LiteEmbedder (FastEmbed)
chunking.py           # Text chunking; analysis_windows (every LLM text path: no references, 16k windows, 250 overlap)
pdf_utils.py          # PDF text extraction
constants.py          # Application constants
exceptions.py         # Custom exception hierarchy
```

## Mobile Apps

**iOS + macOS** (`ios/MedicalFactChecker/`, multiplatform project; macOS-specific views under `Sources/macOS/`):
- SwiftUI + SwiftData models (Document, FactCheckSession, SearchProvider, FullTextSource, SchemaVersions)
- Services: FactCheckWorkflow, LLMService, EmbeddingService, ParallelScoringService, ParallelCitationService, CheckpointedScoringService, CheckpointManager, ModelFetchService, CloudKitConfiguration, BackgroundTaskManager
- Views: FactCheck, FullText, History, Report, Settings, Onboarding
- Components: TransparencyDetailView, TransparencyRiskBadge, TransparencySummarySection, ErrorQueueView, ProcessingProgressView

**Android** (`android/MedicalFactChecker/`):
- data/local: Room DB + DAOs
- data/remote: PubMed, Europe PMC, LLM, Unpaywall, FullText APIs (incl. PmcOpenData, PMC's open-data bucket; OpenAlex; Core, CORE's extracted text; Elsevier, Elsevier's API PDFs with a key; KeyedServiceSession, CORE's and Elsevier's session state; BotWalls, bot-wall challenge pages; PdfTitleCheck, another article's PDF)
- domain: Models, WorkflowState, workflow/ (scoring, searching, reporting)
- ui: Compose screens + ViewModels (factcheck, report, history, settings, fulltext, onboarding)
- ui/components: DocumentCard (with transparency), FullTextSourceBadge, SortingControls
- util: JATSXMLParser, JATSModels, CostCalculator, ResponseParser, PdfExporter
- di: Hilt modules (App, Workflow, Network, Database)

## BioMedLit Swift Package (`Packages/BioMedLit/`)

Shared iOS/macOS components:
- `JATS/`: XML parsing → HTML/Markdown (JATSXMLParser, JATSModels)
- `Services/`: EuropePMCService, PubMedService, FullTextService, PMCOpenData (PMC's open-data bucket), OpenAlex, CORE (extracted text), Elsevier (PDFs, with a key), KeyedServiceSession (CORE's and Elsevier's session state), BotWalls (bot-wall challenge pages), PDFTitleCheck (another article's PDF)
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
- `doc/developer/retraction_checking.md` - Retraction checking: sources, rules, modules
- `doc/developer/guide.md` - Developer guide with architecture, code style, release process

Always use Context7 MCP when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.
