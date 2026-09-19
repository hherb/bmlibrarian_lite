# BMLibrarian Lite Developer Guide

This guide covers the architecture, development setup, and contribution guidelines for BMLibrarian Lite.

## Development Setup

### Prerequisites

- Python 3.12 or higher
- [uv](https://docs.astral.sh/uv/) package manager (recommended) or pip
- Git

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
```

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
├── bmll.py                 # CLI entry point (development)
├── pyproject.toml           # Project configuration (hatchling build)
├── scripts/
│   ├── set_version.py       # Version management across all files
│   ├── run_gui.py           # GUI entry point for PyInstaller
│   └── run_benchmark.py     # Benchmark scoring script
├── src/bmlibrarian_lite/
│   ├── __init__.py          # Package exports, __version__
│   ├── config.py            # LiteConfig (~/.bmlibrarian_lite/)
│   ├── storage.py           # SQLite + sqlite-vec storage
│   ├── embeddings.py        # FastEmbed wrapper
│   ├── constants.py         # Application constants
│   ├── exceptions.py        # Custom exceptions
│   ├── data_models.py       # Core data structures
│   ├── europepmc.py         # Europe PMC client (cursor pagination)
│   ├── search_merger.py     # Deduplication (PMID/DOI/PMC/title)
│   ├── search_service.py    # Unified search across providers
│   ├── search_failures.py   # Failed requests → shortfalls → reader-facing notice
│   ├── analysis_failures.py # Analysis shortfalls → notice and advice
│   ├── audit_records.py     # What became of each document, classified not inferred
│   ├── query_translator.py  # Natural language → structured query
│   ├── fulltext_discovery.py # Europe PMC XML → Unpaywall → DOI
│   ├── pdf_discovery.py     # PDF source discovery
│   ├── chunking.py          # Text chunking utilities
│   ├── pdf_utils.py         # PDF text extraction
│   ├── utils.py             # Shared utilities
│   ├── agents/              # LLM-powered agents
│   │   ├── base.py
│   │   ├── search_agent.py
│   │   ├── scoring_agent.py
│   │   ├── citation_agent.py
│   │   ├── reporting_agent.py
│   │   ├── report_risk_helpers.py  # Risk warning integration
│   │   └── interrogation_agent.py
│   ├── gui/                 # PySide6 interface
│   │   ├── app.py           # Main window
│   │   ├── systematic_review_tab.py
│   │   ├── research_questions_tab.py
│   │   ├── document_interrogation_tab.py
│   │   ├── report_tab.py
│   │   ├── audit_trail_tab.py
│   │   ├── document_card.py
│   │   ├── document_viewer.py
│   │   ├── quality_badge.py
│   │   ├── quality_filter_panel.py
│   │   ├── quality_summary.py
│   │   ├── transparency_badge.py          # Risk badges
│   │   ├── transparency_settings_dialog.py
│   │   ├── citation_loader.py
│   │   ├── benchmark_dialog.py
│   │   ├── quality_benchmark_dialog.py
│   │   ├── chat_widgets.py
│   │   └── workers.py
│   ├── llm/                 # LLM client abstraction
│   │   ├── client.py
│   │   ├── token_tracker.py
│   │   └── providers/       # Anthropic, Ollama
│   ├── pubmed/              # PubMed API integration
│   ├── quality/             # Study quality assessment
│   │   ├── quality_manager.py
│   │   ├── quality_agent.py
│   │   ├── study_classifier.py
│   │   ├── evidence_summary.py
│   │   ├── metadata_filter.py
│   │   ├── report_formatter.py
│   │   └── data_models.py
│   ├── benchmarking/        # Multi-model benchmarking; display.py states results
│   ├── transparency/        # Transparency infrastructure
│   │   ├── transparency_manager.py
│   │   ├── transparency_models.py
│   │   └── transparency_settings.py
│   ├── study_transparency_analyzer/  # LLM-based transparency scoring
│   │   ├── study_transparency_analyzer.py
│   │   └── batch_analyzer.py
│   └── resources/           # Styles and assets
│       └── styles/
│           └── dpi_scale.py # DPI scaling utilities
├── tests/                   # Test suite
├── ios/                     # iOS + macOS multiplatform app (Swift/SwiftUI)
├── android/                 # Android app (Kotlin/Compose)
└── Packages/BioMedLit/      # Shared Swift package (iOS/macOS)
```

### Core Components

#### Configuration (`config.py`)

`LiteConfig` is a dataclass-based configuration system:

```python
from bmlibrarian_lite import LiteConfig

# Load from default location (~/.bmlibrarian_lite/config.json)
config = LiteConfig.load()

# Access configuration sections
print(config.llm.provider)      # "anthropic" or "ollama"
print(config.llm.model)         # Model name
print(config.storage.data_dir)  # Path to data directory

# Validate configuration
errors = config.validate()
if errors:
    for error in errors:
        print(f"Config error: {error}")
```

#### Storage (`storage.py`)

`LiteStorage` manages SQLite with sqlite-vec for vector similarity search:

```python
from bmlibrarian_lite import LiteConfig, LiteStorage, LiteDocument

config = LiteConfig.load()
storage = LiteStorage(config)

# Add a document
doc = LiteDocument(
    id="doc123",
    title="Example Document",
    content="Document text content...",
    source="manual"
)
storage.add_document(doc)

# Search with embeddings
results = storage.search("research question", top_k=10)

# Get statistics
stats = storage.get_statistics()
```

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

Available agents:
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
is refused); the runner classifies a raised call as the review does. An
answer is `EMPTY_RESPONSE` when blank, `JSON_PARSE_ERROR` when it holds no
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
- `transparency_manager.py` - Core transparency management and coordination
- `transparency_models.py` - Data models for transparency results
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

#### Full-Text Discovery (`fulltext_discovery.py`)

Automatic full-text retrieval with fallback chain:
1. Europe PMC XML (converted via JATS parser)
2. Europe PMC PDF
3. Unpaywall PDF (open access)
4. DOI resolution (publisher website)

**A degraded source is named where the source is named** (#304). The
interrogation tab's fall back from full text to the abstract states its cause
in the source label and the chat — `abstract_source_label()`
(`gui/citation_loader.py`) — with a fixed phrase per cause. The provider's
error text never reaches the screen: it prints the request URL, and the
Unpaywall URL carries the user's email address. Close the progress dialog
with `_close_progress_dialog()`, never `close()` directly: Qt's
`QProgressDialog.close()` emits `canceled`, which is wired to "the user
stopped it".

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

Quality assessment models in `quality/data_models.py`:
- `QualityAssessment`: Study design, quality tier, extraction details
- `StudyDesign`: Enum of study types (RCT, SR, Cohort, etc.)
- `QualityTier`: Evidence quality level

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
uv pip install build twine
```

## Testing Guidelines

### Test Structure

```python
import pytest
from bmlibrarian_lite import LiteConfig, LiteStorage

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
        doc = LiteDocument(id="test", title="Test", content="Content")
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
