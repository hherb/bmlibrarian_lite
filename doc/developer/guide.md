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
│   ├── benchmarking/        # Multi-model benchmarking
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

Unified search across PubMed and Europe PMC:

```python
from bmlibrarian_lite.search_service import SearchService

service = SearchService(config)
results = service.search("cardiovascular risk factors", max_results=50)

# Results are automatically deduplicated across providers
for result in results:
    print(f"{result.title} (source: {result.provider})")
```

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

#### Search Service (`search_service.py`)

Unified search across PubMed and Europe PMC with automatic deduplication via `search_merger.py` (matching by PMID, DOI, PMC ID, or title similarity).

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

Key signals for audit trail:
```python
# From SystematicReviewTab
workflow_started = Signal()
query_generated = Signal(str)
documents_found = Signal(list)  # list[LiteDocument]
document_scored = Signal(object)  # ScoredDocument
quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)
citation_extracted = Signal(object)  # Citation
```

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

## Contributing

### Pull Request Process

1. Create a feature branch from `master`
2. Implement changes with tests
3. Ensure all tests pass: `pytest`
4. Ensure code quality: `ruff check . && mypy src/`
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
