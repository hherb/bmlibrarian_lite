# BMLibrarian Lite Developer Guide

This guide covers the architecture, development setup, and contribution guidelines for BMLibrarian Lite.

## Development Setup

### Prerequisites

- Python 3.12 or higher
- [uv](https://docs.astral.sh/uv/) package manager (recommended) or pip
- Git
- For the mobile apps only: Xcode (iOS/macOS) or the Android SDK, and a
  checkout of bmlib with a Rust toolchain for Android's FFI tests

### Installation

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite

# Create virtual environment and install with dev dependencies (recommended)
uv venv && source .venv/bin/activate
uv pip install -e ".[dev]"

# Alternative: using pip
python -m venv .venv && source .venv/bin/activate
pip install -e ".[dev]"
```

### Running the Application

```bash
# CLI
bmll

# GUI
bmlibrarian-lite-gui
```

### Running Tests

```bash
# Run all tests
pytest

# Run a single test file
pytest tests/test_storage.py

# Run a specific test function
pytest tests/test_storage.py::test_add_document

# Run with coverage
pytest --cov=src/bmlibrarian_lite

# Integration tests (live PubMed / Europe PMC; deselected by default)
pytest -m integration
```

`pyproject.toml` deselects integration tests by default
(`addopts = "-m 'not integration'"`). A widget test needs PySide6 and a
working Qt; on a headless machine set `QT_QPA_PLATFORM=offscreen`.

### Code Quality

```bash
# Linting
ruff check .

# Auto-fix lint errors
ruff check --fix .

# Type checking
mypy src/
```

## Architecture Overview

### Directory Structure

```
bmlibrarian_lite/
├── bmll.py                  # CLI entry point (development)
├── pyproject.toml           # Project configuration (hatchling build); bmlib's floor
├── uv.lock                  # Locked dependency set, bmlib's version included
├── HOWTO_MCP_SERVER.md      # Setting up the MCP server in a client
├── scripts/
│   ├── set_version.py       # Version management across all files
│   ├── run_gui.py           # GUI entry point for PyInstaller
│   ├── build_macos.sh       # macOS app bundle (see macos-signing.md)
│   ├── check_bmlib_ledger.py # Every bmlib change has a ledger entry (CI)
│   ├── run_benchmark.py     # Benchmark scoring script
│   ├── jats_survey.py, europepmc_xml_survey.py, unpaywall_pdf_survey.py
│   │                        # Re-runnable surveys of real articles and sources
│   └── browser_rescue_acceptance.py, core_acceptance_replay.py, elsevier_probe.py
│                            # Acceptance runs and probes against live services
├── src/bmlibrarian_lite/
│   ├── __init__.py          # Package exports, __version__
│   ├── cli.py               # bmll: gui, stats, validate, config, clear, keep-pdf, retractions-update
│   ├── mcp_server.py        # bmlibrarian-lite-mcp: the MCP server's four tools
│   ├── config.py            # LiteConfig (~/.bmlibrarian_lite/)
│   ├── storage.py           # LiteStorage: SQLite + sqlite-vec
│   ├── embeddings.py        # LiteEmbedder (FastEmbed)
│   ├── constants.py         # Application constants
│   ├── exceptions.py        # Custom exception hierarchy
│   ├── data_models.py       # Core data structures
│   ├── utils.py             # Shared utilities (incl. failure classification)
│   │
│   │   # Search
│   ├── search_service.py    # Unified search across PubMed + Europe PMC
│   ├── europepmc.py         # Europe PMC client (cursor pagination)
│   ├── search_merger.py     # Deduplication (PMID/DOI/PMC/title)
│   ├── query_translator.py  # Natural language → structured query
│   ├── query_converter.py   # Concepts → a PubMed query string
│   ├── identifiers.py       # PMID canonicalisation (bmlib#470, bmlib#472, bmlib#478)
│   ├── smart_search.py      # Alternative queries when a question's own finds too little
│   ├── smart_search_store.py # smart_search_run_queries table (the queries run per run)
│   ├── search_failures.py   # Failed requests → shortfalls → reader-facing notice
│   ├── analysis_failures.py # Analysis shortfalls → notice and advice
│   ├── audit_records.py     # What became of each document, classified not inferred
│   │
│   │   # Reviewed runs, extended later
│   ├── more_evidence.py     # Find More Evidence: more documents scored into a run, report rewritten
│   ├── full_text_retry.py   # Retry Full Text: a run's unread full texts and uploads
│   ├── full_text_upload.py  # Upload Full Text: a reader's file read into text, or refused
│   ├── uploaded_full_texts_store.py # uploaded_full_texts table
│   ├── citation_text.py     # Pure: full-text score, the methodology's full-text sentence
│   ├── citation_full_texts.py # Fetching the full texts citations read
│   ├── citation_reads_store.py # citation_reads table: which text each paper's citations came from
│   ├── conversation_export.py # Interrogation chat → JSON / Markdown
│   │
│   │   # Full text
│   ├── fulltext_discovery.py # The discovery chain (see Full-Text Discovery)
│   ├── pdf_discovery.py     # PDF source discovery and download
│   ├── pmc_open_data.py     # PMC's open-data S3 bucket (JATS by PMC ID)
│   ├── openalex.py          # The PDFs OpenAlex's locations name (by DOI)
│   ├── elsevier_api.py      # Elsevier's article API, keyed PDF by DOI (10.1016/ only)
│   ├── core_api.py          # CORE's extracted text by DOI (user's key)
│   ├── keyed_service_session.py # A keyed service's 429 pause, refused key, refused network
│   ├── oa_landing_page.py   # Which URL an Unpaywall answer offers; a landing page's PDF
│   ├── jats_markdown.py     # JATS XML → markdown; front/back-matter statements
│   ├── pdf_download.py      # Download helpers: .part, .unchecked and .held files
│   ├── pdf_title_check.py   # Is a PDF the article? (its first page vs the title)
│   ├── pdf_library_check.py # .mismatch set-aside, .kept marker, bmll keep-pdf
│   ├── pdf_utils.py         # PDF text extraction; full-text and PDF paths
│   ├── bot_walls.py         # Bot-wall challenge pages recognised from an answer
│   ├── browser_rescue.py    # Walled PDFs queued for the embedded browser: states, verdicts
│   ├── browser_rescue_text.py # What the reader reads about the rescue queue
│   ├── rescue_queue_store.py # The browser rescue queue's table
│   ├── rate_limit.py        # Host-keyed, thread-safe pacing for outbound requests
│   ├── polite_session.py    # PoliteAdapter + mount_politely for requests.Session
│   ├── chunking.py          # Text chunking; analysis_windows for every LLM text path
│   │
│   │   # Retraction checking (the rule is bmlib's)
│   ├── retraction_export.py # Local Retraction Watch copy: state, evidence, refresh
│   ├── retraction_crossref.py # Crossref lookups over the polite session
│   ├── retraction_store.py  # retraction_checks table, PaperCheck
│   ├── retraction_checks.py # RetractionChecker: reuse or replace stored verdicts
│   ├── retraction_screen.py # Pure: RetractionScreen, screen_with_fallback, RetractionSnapshot
│   ├── retraction_text.py   # Reader-facing retraction sentences
│   ├── transparency_terms.py # The words a transparency rating is qualified in
│   │
│   ├── agents/              # LLM-powered agents
│   │   ├── base.py          # LiteBaseAgent
│   │   ├── search_agent.py
│   │   ├── scoring_agent.py
│   │   ├── citation_agent.py
│   │   ├── reporting_agent.py
│   │   ├── report_risk_helpers.py  # Risk warning integration
│   │   └── interrogation_agent.py
│   ├── gui/                 # PySide6 interface
│   │   ├── app.py           # Main window, Tools menu, status bar
│   │   ├── systematic_review_tab.py  # WorkflowWorker: the review
│   │   ├── research_questions_tab.py
│   │   ├── document_interrogation_tab.py
│   │   ├── report_tab.py    # Report display, auto-save, Check again
│   │   ├── audit_trail_tab.py, audit_queries_tab.py, audit_literature_tab.py, audit_citations_tab.py
│   │   ├── document_card.py, card_utils.py
│   │   ├── document_viewer.py, citation_loader.py, text_highlighting.py, chat_widgets.py
│   │   ├── quality_badge.py, quality_filter_panel.py, quality_summary.py
│   │   ├── transparency_badge.py          # Risk badges
│   │   ├── transparency_settings_dialog.py
│   │   ├── retraction_badge.py            # RETRACTED / CONCERN / NOT CHECKED
│   │   ├── settings_dialog.py, dialogs.py
│   │   ├── benchmark_dialog.py, benchmark_results_dialog.py
│   │   ├── quality_benchmark_dialog.py, quality_benchmark_results_dialog.py
│   │   ├── thread_keeper.py   # Holds a thread its owner let go of until it ends
│   │   ├── rescue_attempt.py  # One hidden browser visit of a walled PDF
│   │   ├── browser_rescue_service.py # The hidden browser pass over the queue
│   │   ├── review_queue_dialog.py    # Walled PDFs' review queue
│   │   ├── rescue_queue_indicator.py # "Walled PDFs: N" in the status bar
│   │   ├── rescue_view.py     # The only runtime QtWebEngineWidgets import
│   │   ├── web_engine.py      # QtWebEngine start-up (prepare_web_engine)
│   │   └── workers.py
│   ├── llm/                 # LLM client abstraction
│   │   ├── client.py, data_types.py, token_tracker.py
│   │   └── providers/       # anthropic.py, ollama.py
│   ├── pubmed/              # PubMedSearchClient; record_ids (a record's own ids)
│   ├── quality/             # Study quality assessment
│   │   ├── quality_manager.py, quality_agent.py, study_classifier.py
│   │   ├── evidence_summary.py, metadata_filter.py, report_formatter.py
│   │   ├── window_reduce.py  # Reduces one paper's per-window answers to one
│   │   ├── json_fields.py    # Ported from bmlib.quality._json_fields
│   │   └── data_models.py
│   ├── benchmarking/        # Multi-model benchmarking; display.py states results
│   ├── transparency/        # Transparency infrastructure
│   │   ├── transparency_manager.py, assessment.py
│   │   ├── transparency_models.py, transparency_settings.py
│   │   └── risk_explanation.py  # Why a study was rated high risk
│   ├── study_transparency_analyzer/  # LLM-based transparency scoring
│   │   ├── study_transparency_analyzer.py, batch_analyzer.py
│   │   └── statement_headings.py
│   └── resources/           # Styles and assets
│       └── styles/          # dpi_scale.py (scaled()), stylesheet and theme generators
├── tests/                   # Test suite (pytest)
├── doc/
│   ├── user/guide.md        # User guide
│   ├── developer/           # This guide; retraction_checking, browser_rescue,
│   │                        # europepmc_and_pubmed, macos-signing
│   ├── cross_platform/      # Platform-agnostic specs and the parity contracts
│   │   └── bmlib_sync/      # The bmlib ledger
│   └── llm/                 # Golden rules (coding standards)
├── ios/                     # iOS + macOS multiplatform app (Swift/SwiftUI)
├── android/                 # Android app (Kotlin/Compose)
└── Packages/BioMedLit/      # Shared Swift package (iOS/macOS), incl. BmlibFFI.xcframework
```

### Core Components

#### Configuration (`config.py`)

`LiteConfig` is a dataclass-based configuration system:

```python
from bmlibrarian_lite import LiteConfig

# Load from default location (~/.bmlibrarian_lite/config.json)
config = LiteConfig.load()

# Access configuration sections
print(config.models.default_provider)    # "anthropic" or "ollama"
print(config.models.default_model)       # Model name
print(config.models.get_model_string("document_scoring"))  # "provider:model" for one task
print(config.storage.data_dir)           # Path to data directory

# Validate configuration
errors = config.validate()
if errors:
    for error in errors:
        print(f"Config error: {error}")
```

#### Storage (`storage.py`)

`LiteStorage` manages SQLite with sqlite-vec for vector similarity search:

```python
from bmlibrarian_lite import LiteConfig, LiteDocument, LiteEmbedder, LiteStorage

config = LiteConfig.load()
storage = LiteStorage(config)
embedder = LiteEmbedder()

# Add a document
doc = LiteDocument(
    id="pmid-12345",
    title="Example Document",
    abstract="Abstract text...",
    pmid="12345",
)
storage.add_document(doc, embedding_function=embedder)

# Search by semantic similarity (sqlite-vec)
results = storage.search_documents("research question", n_results=10, embedding_function=embedder)

# Get statistics
stats = storage.get_statistics()
```

Every table lives in the one SQLite file (`metadata.db`). Focused modules
own their table's schema and queries as functions over an open connection
(`retraction_store`, `rescue_queue_store`, `citation_reads_store`,
`uploaded_full_texts_store`, `smart_search_store`); `LiteStorage` creates
their tables, opens the connection and commits.

#### LLM Client (`llm/client.py`)

Unified interface for Anthropic and Ollama:

```python
from bmlibrarian_lite.llm import LLMClient, LLMMessage

client = LLMClient()

# Chat completion
messages = [
    LLMMessage(role="system", content="You are a helpful assistant."),
    LLMMessage(role="user", content="Hello!")
]

response = client.chat(
    messages=messages,
    model="anthropic:claude-sonnet-4-20250514",
    temperature=0.7,
    max_tokens=1024
)

print(response.content)
```

For Ollama, `client.chat(..., context_window=32768)` passes the fixed token
budget as `options.num_ctx`. `LiteBaseAgent._chat` supplies the effective
`TaskModelConfig.context_window`, including task overrides, through this same
client path. The provider rejects booleans, non-integers and non-positive values
before making a request. `None` omits the option and keeps the server/model
default; Anthropic does not receive an Ollama context option. Prompt contents,
output-token limits and token-usage accounting remain unchanged. No character
count is used to guess a token limit or to claim that the server read a prompt
in full.

#### Agent System (`agents/`)

All agents inherit from `LiteBaseAgent`:

```python
from bmlibrarian_lite.agents import LiteBaseAgent
from bmlibrarian_lite.llm import LLMMessage

class CustomAgent(LiteBaseAgent):
    """Custom agent for specific task."""

    def process(self, input_text: str) -> str:
        """Process input and return result.

        Args:
            input_text: The input to process.

        Returns:
            Processed result string.
        """
        messages = [
            self._create_system_message("You are a specialized assistant."),
            self._create_user_message(input_text)
        ]
        return self._chat(messages)
```

`_chat` raises `TruncatedResponseError` when the answer reaches its token
limit: use it for answers code parses. Text the reader reads as written goes
through `_chat_prose`, which keeps a cut-off answer and notes that it stopped.
Both raise `RefusedResponseError` when the model declines (`MODEL_REFUSED`,
never retried); a declined answer is never kept as prose.

Available agents:
Each agent sets `TASK_ID` (for example `"document_scoring"`), which selects
its provider and model from `config.models.tasks` (see `LLM_TASK_TYPES` in
`constants.py`).

- `SearchAgent`: Converts natural language to PubMed/Europe PMC queries
- `ScoringAgent`: Scores document relevance
- `CitationAgent`: Extracts citations from documents
- `ReportingAgent`: Generates synthesis reports with risk warnings (via `report_risk_helpers`)
- `InterrogationAgent`: Handles document Q&A

#### Search Service (`search_service.py`)

Unified search across PubMed and Europe PMC, with automatic deduplication via
`search_merger.py` (matching by PMID, DOI, PMC ID, or title similarity):

```python
from bmlibrarian_lite.exceptions import SearchFailedError
from bmlibrarian_lite.search_failures import describe_search_shortfalls
from bmlibrarian_lite.search_service import SearchService

service = SearchService(config)
try:
    result = service.search("cardiovascular risk factors", max_results=50)
except SearchFailedError as e:
    # Failures left nothing retrieved: report e, never "no documents found"
    raise

for document in result.documents:
    print(document.title)
if result.shortfalls:
    # The search proceeded without part of its sources: the user must be told
    print("Incomplete search:", describe_search_shortfalls(result.shortfalls))
```

**A failed source is not an empty one** (#247). The clients raise
`SourceRequestError` for a failed search, including an E-utilities `ERROR`
inside an HTTP 200; the service proceeds on what was retrieved and records a
`RetrievalShortfall`, or raises `SearchFailedError` when nothing is left. The
contract the Swift and Android ports follow is
`doc/cross_platform/search_failure_reporting.md`.

#### Analysis Failures (`analysis_failures.py`)

The companion of `search_failures.py` for the stages after the search:

```python
from bmlibrarian_lite.exceptions import AnalysisFailedError

try:
    scoring = scoring_agent.score_documents(question, documents, min_score=3)
except AnalysisFailedError as e:
    # No document could be scored: report e.shortfall, never "none scored
    # above the threshold"
    raise

extraction = citation_agent.extract_all_citations(question, scoring.accepted)
report = reporting_agent.generate_report(
    question,
    extraction.citations,
    analysis_shortfalls=[
        s for s in (scoring.shortfall, extraction.shortfall) if s is not None
    ],
)
```

**A failed analysis is not an empty one** (#261, #262). Scoring and citation
extraction answer with an outcome carrying an `AnalysisShortfall`; scoring
raises when it could score nothing at all; report generation raises rather
than returning its error as the report (#263). A report that rests on part of
what was found opens with an **Incomplete analysis** notice, and a check that
decides *what a text is* reads the body behind both notices. The contract is
`doc/cross_platform/analysis_failure_reporting.md`.

**Classify the failure, not the wrapper.** `llm_retry` retries every provider
failure, so an agent sees `RetryExhaustedError` rather than the refused key or
the unreachable host underneath it. Recording the wrapper leaves every outage
advising "try again later", so both agents pass it through
`classify_exhausted_retries()` (`utils.py`), which reads `last_error`.

**An answer with nothing in it is an answer** (#303). Citation extraction's
`{"passages": []}` is the model saying this text holds nothing quotable for
the question. `readable_passages()` (`agents/citation_agent.py`) tells that
from a response it could not read — returning `None` only for the latter — so
a silent document costs one model call instead of four and is not counted as
unreadable. A passage counts only if its `text` is a non-blank string. The
report on no citations then says which of three things happened: the
extraction failed (a recorded shortfall, the only evidence of that), the
relevant documents held nothing quotable, or nothing was relevant. MCP passes
`documents_accepted` for the second, since it builds no metadata.

#### Audit Records (`audit_records.py`)

What became of each document, classified from the score it received rather
than inferred from its absence:

```python
from bmlibrarian_lite.audit_records import classify_document_outcomes

outcomes = classify_document_outcomes(documents_found, all_scored, min_score)
outcomes.accepted    # met the threshold
outcomes.rejected    # read and scored below it, carrying the model's reason
outcomes.failed      # could not be scored, carrying the error code
outcomes.not_scored  # never reached scoring: the quality filter, or a stop
```

**The record says what happened, not what absence suggests** (#302). The
audit trail used to list every found document that was not accepted as
rejected, with the invented reason "Score below minimum threshold" — so a run
with a flaky provider produced a report saying "3 of 20 documents could not be
scored" beside an audit file asserting those 3 were read and found wanting.
`DocumentOutcomes` refuses a record that counts one document twice or files
one where its score says it does not belong, and `scoring_failure_reason()`
degrades a code this build cannot name without ever dropping the failure.
`outcome_summary()` and `outcome_entries()` build the part of the record the
saved file and the dialog share, so the two cannot drift. The Report tab is
given every scored document, not only the accepted ones, so it can tell them
apart.

A report restored from the Research Questions tab reads the scores of its own
checkpoint and the threshold that checkpoint recorded (`recorded_min_score()`;
the worker writes it as the run starts), and is not saved again — the run
saved its own record when it ran. A record an older build wrote is detected by
`predates_outcome_split()` and shown with a note, and without the stock reason
it gave every non-accepted document (`without_invented_reason()`).

**Silent or unread** (#310). `CitationOutcome.failed` names each relevant
document whose extraction failed as an `ExtractionFailure(document, cause)`;
`documents_failed` and `causes` are read from it, so a count and a list cannot
disagree. Once extraction has run to the end — never for a cancelled run — the
worker emits `citation_extraction_recorded` with the whole list and writes it
into the checkpoint (`checkpoint_metadata_with_extraction_failures()`, read
back by `recorded_extraction_failures()`), and the audit record lists them
under `citation_extraction_failed` (`extraction_failure_record()`, read back by
`readable_extraction_failures()`). An uncited relevant document absent from
that list held nothing quotable. **`None` means not recorded, never "none
failed"**: a cancelled run, a restore from an older checkpoint, and a list that
cannot be read whole all say they cannot tell. A restore reads its own run's
citations (`get_citations_for_question(..., checkpoint_id=...)`). MCP sources
carry `citation_extraction_error`.

**A stored failure is recognised in both forms** (#306). `is_scoring_failure()`
is true for a negative score, and for the score of 1 older builds wrote with
`"Scoring failed: …"` or `"Could not parse response"` (the benchmark runner
until #306, the review scorer until 2025-12-23); `scoring_failure_sql()` states
it for a query, and `classify_document_outcomes()` passes each score through
`as_recorded_failure()` itself (#315), so no load path has to. One older form
cannot be recognised: the pre-#306 runner also stored an answer with no
`score` as a 1 with the model's own explanation, which is why an older result
says its 1s may include failures. The benchmark runner never reuses a
failure, and reuses only the same question's scores; `benchmarking/display.py`
states every figure the benchmark could not compute as `n/a`, including the
cost per judgement and the distribution of a model that judged nothing. A
stored result that cannot be read raises `StoredResultUnreadableError`, which
the Benchmark tab shows as "could not be loaded" (`show_unreadable()`), never as
no results.

**An answer holding no score on the scale is a failure.**
`parse_score_response()` (shared by the review and the benchmark) returns
`None` — retried, then recorded as `JSON_PARSE_ERROR` — for a `score` that is
missing, null, not a whole number or off 1–5, and for prose whose number is on
another scale or is a range; a JSON answer is read as that object alone. `outcome_sort_key()` orders a
listing judged-then-failed-then-unscored, which the Audit Trail's literature
cards follow (#307).

**The quality benchmark follows the same rule** (#314). A `QualityEvaluation`
holds an `assessment` or a `failure` (an `EvaluationErrorCode`), exactly one,
checked in `__post_init__` (the dataclass is frozen, and an `"unknown"` design
is refused); the runner classifies a raised call as the review does. A
cut-off answer is `RESPONSE_TOO_LARGE` and a declined one `MODEL_REFUSED`,
neither parsed. Otherwise an answer is `EMPTY_RESPONSE` when blank, `JSON_PARSE_ERROR` when it holds no
JSON, and `INVALID_RESPONSE_FORMAT` when it is JSON naming no design the
classifier's mapping recognises -- `"unknown"` included
(`parse_study_design()`) -- or has a malformed field. Anything else a parser
raises is caught in `_evaluate()` as that document's `INVALID_RESPONSE_FORMAT`,
so one answer cannot end the run. Statistics count failures apart and state
what nothing assessed as `None`; the tab's cells come from
`benchmarking/quality_display.py`. The review's assessments are reused only
through `is_reusable_assessment()`: the task's tier, a known design, no
transparency downgrade, and an `extraction_method` naming the evaluator's own
model (`llm_extraction_method()`, which the review's classifier and assessor
both record). The review's classifier and assessor still record a failure as
"unknown"/"unclassified". A reused evaluation is marked `reused`, and its $0
and 0 ms are left out of cost per assessment and latency. The baseline shown
is the model configured for the benchmark's task.

**A rerun retries a failure** (#316). `get_rerun_document_ids_for_question()`
splits a question's scored documents into judged (any judgement) and failed
(every scoring a failure, in either form); the Research Questions rerun skips
both in the search and hands the failed ones to `IncrementalSearchWorker` as
`retry_documents`, which lead what it emits and survive a search that ended
in recorded failures (an unexpected error says they were not rescored). A
failed document whose record is gone is not skipped, so the search can find
it again.
`get_scored_document_ids_for_question()` still counts every row, which is what
the benchmark launchers want.

#### Study Transparency (`transparency/` and `study_transparency_analyzer/`)

The transparency system has two components:

**Infrastructure** (`transparency/`):
- `transparency_manager.py` - Queues and paces the analyses a running review asks for
- `assessment.py` - The one analysis body (analyse, build the result, store it),
  shared by the manager and the Research Questions tab's re-analysis pass
  (`TransparencyReanalysisWorker`), so the two cannot store different results
- `transparency_models.py` - Data models for transparency results, and the pure
  functions every surface asks: `pending_transparency_ids` (what still needs
  analysing), `stored_transparency_outcomes` (what a reloaded question may
  show), `count_transparency_over` (the report's counts over a named population)
- `transparency_settings.py` - User-configurable thresholds and settings

**LLM-Based Analyzer** (`study_transparency_analyzer/`):
- `study_transparency_analyzer.py` - Main analyzer using LLM for deep analysis
- `batch_analyzer.py` - Batch processing of multiple studies
- Analyzes: funding disclosure, conflict of interest, data availability, trial registration
- Results feed into risk warnings in generated reports via `agents/report_risk_helpers.py`

**GUI Components:**
- `transparency_badge.py` - Risk badges on document cards
- `transparency_settings_dialog.py` - Configuration dialog for thresholds

#### Parallel Processing

The desktop app supports parallel scoring and citation extraction for cloud LLM providers. See `doc/cross_platform/parallel_processing.md` for the platform-agnostic algorithm specification.

#### Europe PMC Integration (`europepmc.py`)

Full Europe PMC REST API client with:
- Cursor-based pagination for efficient result traversal
- Preprint filtering
- Full-text XML retrieval
- Query translation from PubMed syntax

#### JATS to Markdown (`jats_markdown.py`)

The markdown the document view shows, interrogation embeds and the
transparency analyser segments. The analyser finds a statement only by its
heading, so the converter carries every `<back>` element but the reference
list, and the statements PLOS keeps in `<front>` (the competing interests
footnote, a titled `<notes>`, `<funding-statement>`), each under its own
heading, after the body and before the references (#420). A heading comes
from the element's stated statement type (`fn-type`, `notes-type`,
`sec-type`) when it holds no sections of its own, with the printed heading
kept in bold beneath; else from a title, a label holding a word, or a bold
(or italic, with a colon) run-in. In the end matter every paragraph opening
"**X:**" is a heading of its own; in the body only when no plain paragraph
follows it, since markdown cannot close a heading. A bare footnote that
declares or denies conflicts of interest is headed "Competing Interests".

Rules from the review of PR #426, each a real misreading:

- **In the end matter nothing goes without a heading once a sibling has
  one** (`DEFAULT_HEADING_BY_OWNER`: "Footnotes", "Notes", ...). Otherwise an
  untitled abbreviation list or disclaimer ran on into the competing
  interests statement, and a company it named became an industry tie.
  A list's own `<title>` heads it.
- **A heading the same as the one in force is not repeated**, so eLife's
  one-footnote-per-author COI group is read whole rather than its first
  footnote alone.
- **End matter is decided per element**: `<fn>`, `<fn-group>`, `<notes>`,
  `<ack>` and `<glossary>` are end matter wherever they stand, because some
  Europe PMC articles have no `<back>`.
- Only the article's own `<front>`, `<body>` and `<back>` are read, never a
  `<sub-article>`'s.

**Recognising more end matter makes a missed statement cost the study
points** (a recognised funding section enables the COI `NOT_STATED` charge).
So the analyser charges a missing COI or data statement only when the text
does not use its wording outside its reference list (`_mentions`), **and**
every heading of the end matter is classified (#428,
`study_transparency_analyzer/statement_headings.py`); otherwise it is not
assessed. The converter opens the end matter with `END_MATTER_MARKER`, where
end matter first appears (one journal keeps its footnotes, and its
competing interests statement, in the body); a text without it (including
all PDF text) is never charged. A new end-matter element or default heading
needs a place in that module's lists, or its articles stop being charged.
The classification fails safe only where it asks: a section it vouches for
by name (a known neighbour, a statement heading other than the one sought)
or by vocabulary (a catch-all whose text avoids the statement's words) is
never read further, so a disclosure hiding there is still charged. Any
change to the neighbour lists, the vocabularies or the heading words
(`HEADING_WORDS_BY_STATEMENT`) is measured on the local PMC corpus and a
held-out fetch, both ways. Measure outcomes, not just recognised sections, before
and after any change here -- in both directions: new charges, and industry
ties that appear *or disappear*. A check that uses the guard's own wording
cannot find the guard's blind spots; read the end-matter headings of every
newly charged article.

Converted markdown is cached with a first-line stamp naming the converter
version (`pdf_utils.save_fulltext_markdown`). **Bump
`JATS_MARKDOWN_CONVERTER_VERSION` whenever the same XML would convert
differently**: the cache is read before Europe PMC is asked, and a file with
any other stamp is converted again. A change that moves what the analyser
finds also bumps `TRANSPARENCY_ANALYZER_VERSION`.

#### Full-Text Discovery (`fulltext_discovery.py`)

Automatic full-text retrieval with fallback chain:
0. Cached markdown, only when stamped by the current converter
   (`read_cached_fulltext`); a stale file is converted again and never
   served here, since its statements may be missing. The interrogation tab
   alone falls back to it, labelled, when the refresh fails.
1. Europe PMC XML (converted via JATS parser)
   1a. PMC's open-data bucket, by PMC ID (the same JATS; `pmc_open_data.py`)
   1b. Europe PMC's PDF render
2. A cached PDF, title-checked (see below)
3. PDF download (`pdf_discovery.py`): Elsevier's Article API first, for a
   `10.1016/` DOI with a key (`elsevier_api.py`); then PMC links, every
   Unpaywall PDF, the open-access PDFs OpenAlex's locations name that
   Unpaywall did not (`openalex.py`), publisher patterns and the DOI
   download
   3a. CORE's extracted text (`core_api.py`), with a key and a DOI: at each
       exit of the download that obtained no PDF, and after a PDF that yields
       no text (a scan)

The Europe PMC and PubMed side of this, the per-host pacing and the URL each
source is asked at are in `doc/developer/europepmc_and_pubmed.md`; the
platform-agnostic chain is `doc/cross_platform/fulltext_retrieval.md`. CORE
and Elsevier share `keyed_service_session.py`: one process-wide record of a
429 pause, a refused key and a refused network, so a key refused once is not
sent again until the reader changes it. A host answering with a robot check
(`bot_walls.py`) is a copy *not obtained*, never one that is absent; it is
queued for the embedded browser (`doc/developer/browser_rescue.md`).

**A PDF whose first page with text is found not to carry the title is not read
as the article's** (#541; `pdf_title_check.check_pdf_title`, the share of the title's
adjacent word pairs). Every PDF is checked where it enters: each download
(`PDFDiscoverer._try_download`, Elsevier's API, Europe PMC's render) and each
PDF the cache finds (`fulltext_discovery` step 3, and the interrogation tab's
two cached loads, through `pdf_library_check.check_cached_pdf`). **A download
is checked where it waits** (`<pdf>.part`, or `<pdf>.unchecked` for
Elsevier's and Europe PMC's) and replaces the cached PDF only once it passes,
so another article's PDF never overwrites the library's. A PDF that does not
carry the title is **set aside**, not deleted: renamed to `<pdf>.mismatch`
(`-2`, `-3` … for different bytes; the same bytes are kept once, so a wrong
download repeated each run does not accumulate). A refused download is
recorded as a `WRONG_ARTICLE` skip with its address (never an absence: the
right PDF may exist elsewhere), held with the copies not obtained and dropped
when a later source serves the article. **Every PDF set aside is told to the
reader**: `DiscoveryResult.set_aside` and `FulltextResult.set_aside_downloads`
/ `refused_library_pdf` carry them on every outcome, and
`FulltextResult.set_aside_pdf_note` (each file and how to keep it) ends a
failure's `error`, becomes a transparency report warning, MCP's
`set_aside_pdf_note`, and the tab's chat (both workers' `pdf_set_aside`
signal). A refused library PDF also keeps `absence_established` false: the
check can be wrong. Only a mismatch is refused: a check that judged nothing
(no title, a scan, a PubMed-translated title, an unreadable file) leaves the
PDF be.

**A person's word overrides the check.** A PDF a person kept carries a marker
`<pdf>.kept` holding its SHA-256 (`mark_kept`), so it vouches for those bytes
alone, wherever they come from (a download of the bytes kept is kept too);
the review queue's *Keep this PDF* and `bmll keep-pdf <path>` (which renames
a set-aside PDF back) both write it before the rename. Deleting a PDF from the
interrogation tab removes its marker first (`forget_kept`), or the same bytes
downloaded again would be read unchecked.

**The check needs a title.** A caller that gives none (MCP's
`get_document_fulltext`, by identifier alone) gets Europe PMC's: step 2 writes
`ArticleInfo.title` into `doc_dict`, and steps 2b–4 check against it. With no
title from either, nothing is checked, as before. **Refusals are per call**:
each step returns what it set aside (`FulltextResult.set_aside_downloads`,
`DiscoveryResult.set_aside`) and `discover_fulltext` / `discover_and_download`
gather them in a collector of their own, never on the discoverer, since MCP
shares one `FulltextDiscoverer` between concurrent tool calls. A download set
aside onto the library PDF's own `.mismatch` (the same bytes, served again) is
told once, as the library's. Both workers emit `pdf_set_aside` before a cancel
too, and the tab shows a superseded run's note, naming its article.

**A degraded source is named where the source is named** (#304). The
interrogation tab's fall back from full text to the abstract states its cause
in the source label and the chat — `abstract_source_label()`
(`gui/citation_loader.py`) — with a fixed phrase per cause. The provider's
error text never reaches the screen: it prints the request URL, and the
Unpaywall URL carries the user's email address. Close the progress dialog
with `_close_progress_dialog()`, never `close()` directly: Qt's
`QProgressDialog.close()` emits `canceled`, which is wired to "the user
stopped it".

#### Retraction Checking (`retraction_*.py`)

Every paper a review, an MCP tool, the interrogation tab or a Research
Questions pass holds is checked against Retraction Watch's export (a local
SQLite copy, `retraction_watch.db`), Crossref, and the record's PubMed
"Retracted Publication" label. **The rule that turns that evidence into a
verdict is bmlib's** (`bmlib.publications.retraction_status.retraction_status`),
as are the Crossref request batching and answer parsing and the export's
import and lookup; lite owns the I/O, the storage of each paper's verdict,
the screen and every sentence the reader reads. The review leaves retracted
papers out at one choke point (`WorkflowWorker.run`) before anything is
filtered or scored.

```python
from bmlibrarian_lite.retraction_checks import build_retraction_checker
from bmlibrarian_lite.retraction_screen import screen_with_fallback
```

The modules, the rules (an outage never erases a verdict; a failure is not
knowledge; the label survives everything) and *Check again* are in
`doc/developer/retraction_checking.md`.

#### Reviewed Runs: Smart Search, Find More Evidence, Retry Full Text

A review's checkpoint is its run. Three things extend a run after it was
reviewed, each written as pure orchestration that imports no Qt and is driven
by a worker in `gui/workers.py`:

- **Smart search** (`smart_search.py`): when fewer than
  `SMART_SEARCH_THRESHOLD` (3) documents are relevant and at least one was
  judged, the model is asked for two or three alternative queries, told of
  every query the run has already run (`smart_search_store`, keyed by
  checkpoint). A failed request, a declined answer or a cut-off one stops the
  round; none of these is a source's failure, so none records a shortfall.
- **Find More Evidence** (`more_evidence.py`): pages further through the
  question's own query, then runs a smart-search round once that finds
  nothing new; screens, scores and extracts the new documents into the same
  run and writes its report again from every citation of the run. What it
  learns is checkpointed as it is learnt and marked as owing a report.
- **Retry Full Text** (`full_text_retry.py`): reads the full texts a run's
  report was not written from (fetched with *Read citations from full text*
  on, and every upload, `full_text_upload.py`, whatever the setting) and
  writes the report again.

Which text each paper's citations were read from is recorded per run in
`citation_reads` (`citation_reads_store.py`); `citation_text.py` holds the
full-text score threshold and the methodology's sentence. Every LLM path over
a text uses `chunking.analysis_windows` (references dropped, overlapping
windows, never cut). These follow the apps' rules (iOS/macOS's
`executeSmartSearch` and `fetchMoreEvidence`), and the contract is
`doc/cross_platform/search_failure_reporting.md`.

#### MCP Server (`mcp_server.py`)

`bmlibrarian-lite-mcp` serves four tools over stdio: `fact_check_claim`,
`search_literature`, `get_document_fulltext` and `ask_document`. They share
the desktop's configuration, storage, retraction screen and full-text
discovery (one `FulltextDiscoverer` across concurrent tool calls, which is
why discovery keeps its refusals per call). Client setup is in
`HOWTO_MCP_SERVER.md`.

### GUI Architecture

The GUI uses PySide6 with a signal/slot pattern:

```python
from PySide6.QtCore import Signal, Slot
from PySide6.QtWidgets import QWidget

class MyWidget(QWidget):
    """Widget with signal/slot communication."""

    result_ready = Signal(str)  # Emitted when result is ready

    @Slot()
    def on_button_clicked(self) -> None:
        """Handle button click."""
        result = self._do_work()
        self.result_ready.emit(result)
```

#### Background Workers

Long-running operations use `QThread` workers:

```python
from PySide6.QtCore import QThread, Signal

class WorkerThread(QThread):
    """Background worker for long operations."""

    finished = Signal(object)
    error = Signal(str)

    def __init__(self, task_data: dict) -> None:
        """Initialize worker.

        Args:
            task_data: Data for the task.
        """
        super().__init__()
        self._task_data = task_data

    def run(self) -> None:
        """Execute the background task."""
        try:
            result = self._perform_task()
            self.finished.emit(result)
        except Exception as e:
            self.error.emit(str(e))
```

**Never drop a running thread.** Dropping the last reference to a running
`QThread` destroys it, and Qt aborts the process ("QThread: Destroyed while
thread is still running"); so does a thread still running at exit. An owner
that must not wait for its thread (a dialog the reader closed while a provider
is still answering) disconnects the thread's signals from itself and hands it
to `thread_keeper.keep_until_finished(thread)`. The keeper holds it until
`finished`, then deletes it, and at quit waits up to `KEPT_THREAD_EXIT_WAIT_MS`
for what it still holds; a thread it waits on must itself be bounded (each of
the settings dialog's probes is one request, waits
`PROVIDER_PROBE_TIMEOUT_SECONDS` to connect and again to read, and is not
retried). An owner's result handlers also check that it has let go: a result
the thread sent before the disconnect is still delivered, and a thread started
from it would belong to nobody.
Override `done()`, not just `closeEvent()`, to act on a dialog's every way
out: OK and Cancel never send a `closeEvent`. A dialog built per opening is
`deleteLater()`'d after `exec()`, or it lives as long as its parent.

**Testing a thread and the event loop.** Most tests never pump the shared
`QApplication`, so earlier tests' leftovers sit unprocessed: Qt objects in
collectable cycles, and `deleteLater()`'d widgets that crash when deleted
(see #516). Python's collector runs on whichever thread crosses its
allocation threshold, and a worker thread (a test's HTTP server, an executor)
that collects those Qt objects destroys them off their thread, leaving their
timers to fire into freed memory at the next `processEvents()`. So the suite
turns automatic collection off and collects on the main thread after each test
(`tests/conftest.py`, `tests/main_thread_gc.py`); never re-enable it in a test.
A test that pumps the event loop flushes deferred deletes only for its own
objects (`sendPostedEvents(obj, QEvent.Type.DeferredDelete)`, never `None`).

#### Audit Trail Components

The Audit Trail system provides real-time workflow visibility:

**AuditTrailTab** (`audit_trail_tab.py`):
- Main container with three sub-tabs
- Connects to workflow signals from SystematicReviewTab
- Coordinates data flow between sub-tabs

**DocumentCard** (`document_card.py`):
- Collapsible card widget for document display
- Supports quality badges, score badges, and transparency risk badges
- Shows LLM rationale for scoring/quality decisions
- Emits signals: `clicked(doc_id)`, `send_to_interrogator(doc_id)`
- A negative score is an error code, not a score: the badge text, colour and
  tooltip come from `card_utils.score_badge_text/_color/_tooltip()`, which say
  the scoring failed and why (#307)

Key signals for audit trail:
```python
# From SystematicReviewTab
workflow_started = Signal()
query_generated = Signal(str)
documents_found = Signal(list)  # list[LiteDocument]
document_scored = Signal(object)  # ScoredDocument
quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)
citation_extracted = Signal(object)  # Citation
# From WorkflowWorker once extraction has run to the end, kept by
# SystematicReviewTab for the Report tab (#310)
citation_extraction_recorded = Signal(list)  # list[ExtractionFailure]
```

`citation_extraction_recorded` is listed here for completeness: the Audit
Trail tab does not connect to it; `SystematicReviewTab` keeps its list for the
Report tab's audit record.

### Data Models

Core data structures in `data_models.py`:

- `LiteDocument`: Represents a document with metadata
- `LiteChunk`: A chunk of text with embedding
- `SearchSession`: Tracks a search workflow
- `ReviewCheckpoint`: Saves review progress
- `ScoredDocument`: Document with relevance score and explanation
- `Citation`: Extracted citation with passage and context
- `InterrogationSession`: Q&A session state
- `SearchProvider`: Enum for PubMed / Europe PMC
- `CursorPaginationState`: Europe PMC cursor-based pagination
- `OffsetPaginationState`: PubMed offset-based pagination
- `RequestFailure` / `RequestFailureKind`: one failed request, classified
- `RetrievalShortfall`: what a search could not retrieve, and why
- `AnalysisShortfall`: what scoring or citation extraction could not do
- `ScoringOutcome`, `CitationOutcome`, `ExtractionFailure`: the agents' answers,
  carrying their shortfalls
- `ReportMetadata`: the counts and notices a report is written with

Retraction verdicts are bmlib's `RetractionVerdict`; lite stores one per
paper as a `PaperCheck` (`retraction_store.py`).

Quality assessment models in `quality/data_models.py`:
- `QualityAssessment`: Study design, quality tier, extraction details
- `StudyDesign`: Enum of study types (RCT, SR, Cohort, etc.)
- `QualityTier`: Evidence quality level

## The bmlib Dependency

[bmlib](https://github.com/hherb/bmlib) is the maintainer's shared library
for biomedical literature tools (AGPL-3.0-or-later): LLM abstraction,
quality assessment, transparency analysis, full-text retrieval and JATS
parsing, publication ingestion and database utilities, in Python, with a Rust
port (`rust/` in bmlib). This repository relates to it in three ways.

### 1. The desktop imports it

The desktop's runtime dependency is declared in `pyproject.toml`:

```toml
"bmlib>=0.13.0",
```

`uv.lock` records the version resolved from PyPI. bmlib's core needs only `jinja2`, and
the modules lite imports need none of bmlib's extras. Today lite imports
only the retraction rule, what it rests on, and `find_passage`:

| bmlib module | What lite uses | Where |
|--------------|----------------|-------|
| `bmlib.publications.retraction_status` | `retraction_status()` (the verdict), `RetractionStatus`, `RetractionVerdict`, `RetractionEvidence`, `RetractionSource`, `RetractionLookup`, `evidence_from_notices`; Crossref: `crossref_key`, `crossref_retraction_requests`, `parse_crossref_retraction_response`, `CrossrefResult`, `CrossrefOutcome` | `retraction_checks.py`, `retraction_crossref.py`, `retraction_screen.py`, `retraction_store.py`, `retraction_text.py`, `retraction_export.py`; `RetractionStatus` also in `audit_records.py`, `mcp_server.py`, `agents/reporting_agent.py` and the GUI's cards, badge and report tab |
| `bmlib.publications.retractions` | `import_retraction_watch_export`, `lookup_retractions` | `retraction_export.py` |
| `bmlib.publications.schema` | `ensure_schema` (the export copy's tables) | `retraction_export.py` |
| `bmlib.db` | `connect_sqlite` | `retraction_export.py` |
| `bmlib.citations` | `find_passage`, `PassageMatch` (citation highlighting; its contradiction guard sets the 0.13.0 floor) | `gui/text_highlighting.py` |

Rules for this boundary:

- **bmlib decides; lite reports.** Lite never re-derives a verdict from the
  evidence: a new status, source or lookup comes from bmlib. A stored row
  naming a status, lookup or evidence this build's bmlib does not know is
  unreadable and never reused (bmlib's `RetractionEvidence.from_dict`, read in
  `retraction_store.py`; #705).
- **The contract is bmlib's fixture.** `doc/cross_platform/retraction_parity/retraction_status.json`
  is copied verbatim from bmlib's `tests/fixtures/` and never edited here.
  `tests/test_retraction_contract.py` runs every rule, Crossref-parse and
  request case through bmlib's API, as the Swift and Kotlin suites do through
  the Rust library.
- Keep bmlib imports to the retraction modules, `find_passage` and the places
  that only name a `RetractionStatus`. Anything else lite takes from bmlib is ported, not
  imported (below), until a decision to import it is made.

**Raising the floor.** Change the version in `pyproject.toml`, then refresh
the lock and the environment and run the suite:

```bash
uv lock
uv pip install -e ".[dev]"
pytest tests/test_retraction_contract.py tests/test_retraction_checks.py
pytest
```

Read bmlib's `CHANGELOG.md` between the two versions first: a renamed export
column, a new verdict or a changed fixture shows up here. The floor holds
nothing back: a new bmlib release reaches CI and fresh installs with no change
here (only `uv.lock` keeps the older one), so a changed fixture or export can
first show up as a red `test_retraction_contract.py` on an unrelated pull
request. Fix lite there, or raise the floor on purpose. If bmlib's fixture
changed, copy it over `retraction_parity/retraction_status.json` (and say so
in its README) in the same pull request. To work against a local bmlib
checkout, `uv pip install -e ~/src/bmlib` replaces the PyPI copy in your
environment until the next `uv pip install -e ".[dev]"`.

**Releasing to PyPI.** PyPI refuses a package with a direct (git) reference,
so never pin bmlib to a commit in a release: a fix lite needs waits for a
bmlib release on PyPI.

### 2. Lite ports bmlib's fixes: the sync ledger

Most of what bmlib and lite share is not imported but kept in step by hand:
JATS parsing (`jats_markdown.py`), transparency analysis, full-text
retrieval, quality-answer parsing (`quality/json_fields.py`, ported from
`bmlib.quality._json_fields`), PMID handling (`identifiers.py`). Code and
comments cite the bmlib issue a rule came from as `bmlib#N`; this
repository's issues are plain `#N`. They are different trackers.

`doc/cross_platform/bmlib_sync/ledger.json` records what became of every
bmlib change since 0.10.0 on each of the three platforms (`owed`, `ported`,
`equivalent`, `n/a`, `declined`), and the reverse: what lite has that bmlib
lacks. Its `bmlib_commit` is the bmlib commit the ledger has been triaged
against. `scripts/check_bmlib_ledger.py --bmlib <checkout>` lists every
bmlib changelog entry with no ledger row:

- the `bmlib-ledger` job (`python-tests.yml`) checks the pinned commit on
  every pull request and push;
- the weekly `bmlib drift` workflow checks bmlib's `main` and fails until the
  pin is bumped and the new entries are triaged. It never runs on a pull
  request, so bmlib moving never blocks a merge here.

The ledger's shape, the check's exit codes and how to start a sync are in
`doc/cross_platform/bmlib_sync/README.md`. The plan behind it is
`doc/plans/2026-10-17-port-bmlib-advances.md`.

### 3. The apps link bmlib's Rust library (UniFFI)

The iOS/macOS and Android apps call bmlib's Rust crate through UniFFI
(decision record: `doc/cross_platform/bmlib_sync/uniffi_spike.md`). They use
it for the retraction rule, Crossref request and parse, and the Retraction
Watch index, so all three platforms decide a verdict by the same code;
`BmlibJATSAdapter` (Swift) and the Android FFI tests also exercise its JATS
parser.

- **The one pin for both apps** is
  `Packages/BioMedLit/Frameworks/BmlibFFI.pin.json` (`bmlibCommit`, the
  rustc, UniFFI and Xcode versions, and the xcframework's tree hash). The
  generated bindings, `Packages/BioMedLit/Sources/BmlibCore/bmlib_ffi.swift`
  and `android/…/org/bmlib/ffi/bmlib_ffi.kt`, and the committed
  `BmlibFFI.xcframework` must all come from that commit; a binding from
  another fails UniFFI's checksum check at its first call.
- **Swift**: the `BmlibCore` target wraps the committed xcframework. The
  `bmlib xcframework` workflow rebuilds it from the pin on every pull request
  and fails unless it matches; its header says how to re-pin (the committed
  copy is that workflow's own build).
- **Android**: Gradle builds the `.so` files with cargo-ndk from a bmlib
  checkout named by `bmlib.dir` in `local.properties` or `BMLIB_DIR`, and
  `checkBmlibPin` refuses a checkout at any other commit
  (`-Pbmlib.allowUnpinnedCommit=true` builds anyway, with a warning). The FFI
  suites skip without a checkout locally; `android-tests.yml` checks bmlib
  out at the pin and fails a skipped run. To get a checkout at the pin:
  `git -C ~/src/bmlib worktree add --detach <dir> <bmlibCommit>`.

### A version floor and two pins

| Entry | Where | What it fixes |
|-----|-------|---------------|
| Python dependency | `pyproject.toml` floor (`uv.lock` records one resolution) | The oldest bmlib the desktop accepts; CI and PyPI installs take the newest release |
| Ledger commit | `ledger.json` `bmlib_commit` | The bmlib changelog the ledger is triaged against |
| FFI commit | `BmlibFFI.pin.json` `bmlibCommit` | The Rust library both apps link |

They move independently. The ledger and FFI entries name commits; the Python
entry names a version. Bump each on its
own pull request, with the checks above.

## Code Style Requirements

### Mandatory Elements

1. **Docstrings**: All public functions, classes, and methods require Google-style docstrings:

```python
def calculate_score(text: str, query: str) -> float:
    """Calculate relevance score between text and query.

    Args:
        text: The document text to score.
        query: The search query.

    Returns:
        Relevance score between 0.0 and 1.0.

    Raises:
        ValueError: If text or query is empty.
    """
```

2. **Type Hints**: All function parameters and return types must be annotated:

```python
def process_documents(
    documents: list[LiteDocument],
    config: LiteConfig,
    max_results: int = 100,
) -> dict[str, Any]:
```

3. **No Magic Numbers**: Use named constants:

```python
# Bad
if score > 0.7:
    pass

# Good
from bmlibrarian_lite.constants import SIMILARITY_THRESHOLD_DEFAULT

if score > SIMILARITY_THRESHOLD_DEFAULT:
    pass
```

4. **DPI Scaling**: Use `scaled()` for all pixel dimensions:

```python
from bmlibrarian_lite.resources.styles.dpi_scale import scaled

widget.setMinimumHeight(scaled(50))
layout.setSpacing(scaled(8))
```

5. **Thread Safety**: Use locks for shared state:

```python
import threading

class SharedState:
    def __init__(self):
        self._lock = threading.RLock()
        self._data = {}

    def update(self, key: str, value: Any) -> None:
        with self._lock:
            self._data[key] = value
```

### Ruff Configuration

The project uses ruff with these rules (from `pyproject.toml`):

- `E`, `W`: pycodestyle errors and warnings
- `F`: pyflakes
- `I`: isort
- `B`: flake8-bugbear
- `C4`: flake8-comprehensions
- `UP`: pyupgrade
- `D`: pydocstyle (Google convention)

### Type Checking

mypy is configured with strict mode:

```toml
[tool.mypy]
python_version = "3.12"
strict = true
warn_return_any = true
disallow_untyped_defs = true
```

## Release Process

### Version Management

Use the version script to update all version locations at once:

```bash
# Show current versions
python scripts/set_version.py --show

# Preview changes
python scripts/set_version.py 0.4.0 --dry-run

# Apply version bump
python scripts/set_version.py 0.4.0
```

This updates:
- `src/bmlibrarian_lite/__init__.py` (`__version__`)
- `bmll.py` (`__version__`)
- `bmlibrarian_lite.spec` (3 locations: BUNDLE version, CFBundleShortVersionString, CFBundleVersion)
- `CLAUDE.md` (`**Current version:**`)
- `CHANGELOG.md` (promotes `[Unreleased]` — see below)

### Changelog

`CHANGELOG.md` is the canonical release history ([Keep a Changelog](https://keepachangelog.com/en/1.1.0/)
format). Add entries under `## [Unreleased]` as you merge work, grouped under
Added / Changed / Deprecated / Removed / Fixed / Security.

At release time `set_version.py` promotes that section for you: it inserts a
dated `## [X.Y.Z] - YYYY-MM-DD` heading, moves the accumulated entries beneath
it, leaves `[Unreleased]` empty for the next cycle, and rewrites the compare
links at the bottom of the file. It warns (but still stamps) if `[Unreleased]`
is empty, and is a no-op if the version already has a section. Pass
`--skip-changelog` to bump versions without touching it.

Reuse the new section verbatim as the GitHub release body:

```bash
awk '/^## \[X.Y.Z\]/{f=1;next} /^## \[/{f=0} f' CHANGELOG.md > /tmp/notes.md
gh release create X.Y.Z --title "vX.Y.Z" --notes-file /tmp/notes.md dist/bmlibrarian_lite-X.Y.Z*
```

Releases 0.2.0 and 0.3.0 also have standalone `RELEASE_NOTES_X.Y.Z.md` files,
linked from their changelog sections. That per-version file pattern is retired —
new releases go in `CHANGELOG.md` only.

### Publishing to PyPI

```bash
# Build sdist and wheel
python -m build

# Validate artifacts
twine check dist/bmlibrarian_lite-X.Y.Z*

# Upload (uses ~/.pypirc for authentication)
twine upload dist/bmlibrarian_lite-X.Y.Z*

# Tag and push
git tag -a X.Y.Z -m "Release vX.Y.Z"
git push && git push --tags
```

### Build Dependencies

```bash
uv pip install -U build twine "packaging>=26"
```

hatchling writes Metadata-Version 2.5, which `twine check` refuses as
invalid under `packaging` 25.

## Testing Guidelines

### Test Structure

```python
from pathlib import Path

import pytest
from bmlibrarian_lite import LiteConfig, LiteDocument, LiteStorage
from bmlibrarian_lite.config import StorageConfig

class TestStorage:
    """Tests for LiteStorage class."""

    @pytest.fixture
    def config(self, tmp_path: Path) -> LiteConfig:
        """Create test configuration."""
        return LiteConfig(
            storage=StorageConfig(data_dir=tmp_path)
        )

    @pytest.fixture
    def storage(self, config: LiteConfig) -> LiteStorage:
        """Create test storage instance."""
        return LiteStorage(config)

    def test_add_document(self, storage: LiteStorage) -> None:
        """Test adding a document to storage."""
        doc = LiteDocument(id="test", title="Test", abstract="Abstract")
        storage.add_document(doc)

        retrieved = storage.get_document("test")
        assert retrieved is not None
        assert retrieved.title == "Test"
```

### GUI Testing

For PySide6 widgets, use the `qapp` fixture:

```python
import pytest
from PySide6.QtWidgets import QApplication

@pytest.fixture
def qapp():
    """Create QApplication for GUI tests."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    return app

def test_document_card(qapp, sample_document):
    """Test DocumentCard widget."""
    from bmlibrarian_lite.gui.document_card import DocumentCard

    card = DocumentCard(document=sample_document, score=4)
    assert card.score == 4
    assert not card.expanded
```

Many suites define their own `qapp` fixture as above. A test that exercises
the network goes through a local HTTP server or a stub client, never the
real service: `tests/conftest.py` stubs the OpenAlex, CORE and Elsevier
clients and the settings dialog's model probes unless a test asks for the
real one with a marker (`real_openalex_client`, `real_core_client`,
`real_elsevier_client`, `real_model_fetch`).

QtWebEngine is the exception to the `qapp` fixture: never pump it in the
suite's shared `QApplication` (#516, #517). Its tests drive
`tests/browser_rescue_harness.py` in a subprocess with its own application, and
fail rather than skip when the engine cannot start. Run it alone with
`QT_QPA_PLATFORM=offscreen python tests/browser_rescue_harness.py`.

### Test Commands

```bash
# Run all tests
pytest

# Run with verbose output
pytest -v

# Run specific test class
pytest tests/test_storage.py::TestStorage

# Run with coverage report
pytest --cov=src/bmlibrarian_lite --cov-report=html
```

## Continuous Integration

| Workflow | Runs | Checks |
|----------|------|--------|
| `python-tests.yml` | every PR and push to `master` | `pytest`, the bmlib ledger at its pin, the lint delta |
| `bmlib-drift.yml` | Mondays, and by hand | the bmlib ledger against bmlib's `main` |
| `bmlib-xcframework.yml` | every PR and push to `master` | `BmlibFFI.xcframework` and both bindings rebuilt from the pin, compared |
| `swift-tests.yml` | every PR and push to `master` | BioMedLit and the app's Swift tests |
| `swift-integration-tests.yml` | daily | Swift tests against live PMC |
| `android-tests.yml` | every PR and push to `master` | Gradle unit tests, the bmlib FFI tests included |
| `xcode-project-guards.yml` | PRs touching a `.pbxproj` | the Xcode project's guards |
| `claude-code-review.yml`, `claude.yml` | PRs, mentions | automated review |

`.github/workflows/python-tests.yml` runs on every pull request and on every
push to `master`.

### `pytest` job

Runs `pytest tests/ -m "not integration" --strict-markers` on Ubuntu against
Python 3.12. Integration tests are deselected because they call Europe PMC and
PubMed over the network, where they measure those services' availability rather
than this repository; run them locally with `pytest -m integration`.

Two things about this job are deliberate and should not be "optimised" away:

- **There is no `paths:` filter.** The transparency parity fixtures live in
  `doc/cross_platform/transparency_parity/`, outside `src/` and `tests/`, and
  they exist to fail when a pattern change is not mirrored across all three
  platforms. Any plausible paths filter would skip the run for a contract-only
  edit — the same silent pass that the `inputs.dir` declaration in the Android
  `app/build.gradle.kts` exists to prevent.
- **A Qt preflight step constructs a `QApplication` before the tests run.** The
  widget suites open with `pytest.importorskip("PySide6")`, so a broken Qt
  install would skip roughly a hundred tests and leave the job green. The
  preflight turns that into a loud failure, and it exercises what the tests
  actually need rather than merely that the package imports.
  The preflight is `.github/scripts/qt_preflight.py`; it also checks
  QtWebEngine (the browser rescue), and the job sets
  `QTWEBENGINE_DISABLE_SANDBOX`. See `doc/developer/browser_rescue.md`.

### `bmlib-ledger` job

Checks out bmlib's `CHANGELOG.md` at the ledger's `bmlib_commit` and runs
`scripts/check_bmlib_ledger.py` against it: every bmlib change must have a
ledger entry. It can only fail when the ledger is edited, because the pin
does not move; `bmlib-drift.yml` is what sees bmlib move. See
[The bmlib Dependency](#the-bmlib-dependency).

### `lint-delta` job

`ruff check .` and `mypy src/` both carry large pre-existing baselines (2081 and
~680 findings respectively when this was written), so requiring a clean run is
not reachable. Instead `.github/scripts/lint_delta.py` measures both tools on the
pull request and again in a throwaway worktree at the merge base, and fails only
on findings the change introduces.

Note that the mypy total is platform-dependent — 677 on macOS against 688 on the
Linux runner, from differences in the platform-specific branches it analyses.
This is why the gate compares two measurements taken on the *same* machine in the
same run rather than checking against a recorded baseline number; a committed
baseline would be wrong by roughly a dozen findings the moment it moved hosts.

A finding is identified by `(tool, path, code, message)` — without its line and
column — so inserting code above a pre-existing finding does not re-report it.
Counts still matter: a file going from two to three identical findings reports
one new finding.

```bash
# Reproduce the gate locally before pushing
python .github/scripts/lint_delta.py --base-ref origin/master

# Check a single tool
python .github/scripts/lint_delta.py --tool ruff
```

Exit codes are 0 (no new findings), 1 (new findings, listed as GitHub
annotations) and 2 (the gate could not run — never treated as a pass). Renaming
a file makes every finding it carries look new, because the path is part of the
identity; fix or split such changes rather than weakening the identity.

Each side runs with its own checkout's `pyproject.toml`, so a pull request that
*enables* a ruff rule surfaces every pre-existing finding that rule flags as
new — and fails. That asymmetry is policy, not accident: enabling a rule means
cleaning up what it catches, in the same pull request. Rule-set expansions
therefore cannot land incrementally; scope them to a rule whose cleanup fits in
one review.

The job runs on pull requests only: on a push to `master` the merge base is the
commit itself, so the comparison would be vacuously empty.

## Contributing

### Pull Request Process

1. Create a feature branch from `master`
2. Implement changes with tests
3. Ensure all tests pass: `pytest`
4. Ensure the change adds no new lint or type findings:
   `python .github/scripts/lint_delta.py --base-ref origin/master`
   (a bare `ruff check . && mypy src/` cannot pass — see Continuous Integration)
5. Submit pull request with clear description

### Commit Messages

Use conventional commit format:
- `feat:` New feature
- `fix:` Bug fix
- `docs:` Documentation changes
- `refactor:` Code refactoring
- `test:` Test additions or changes
- `chore:` Maintenance tasks

### Golden Rules

See `doc/llm/golden_rules.md` for the complete coding standards. Key rules:

1. Never trust input from users or external sources
2. No magic numbers - use constants
3. No hardcoded paths - use configuration
4. All LLM communication through the abstraction layer
5. All parameters must have type hints
6. All functions must have docstrings
7. All errors must be handled and logged
8. No inline stylesheets - use the styling system
9. No hardcoded pixel values - use DPI scaling
10. Write tests for all features
