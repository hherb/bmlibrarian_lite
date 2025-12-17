# BMLibrarian Lite Developer Guide

This guide covers the architecture, development setup, and contribution guidelines for BMLibrarian Lite.

## Development Setup

### Prerequisites

- Python 3.12 or higher
- uv package manager
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian-lite.git
cd bmlibrarian-lite

# Create virtual environment and install with dev dependencies
uv venv
source .venv/bin/activate
uv pip install -e ".[dev]"
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
├── bmlibrarian_lite.py      # CLI entry point
├── pyproject.toml           # Project configuration
├── src/bmlibrarian_lite/
│   ├── __init__.py          # Package exports
│   ├── config.py            # Configuration management
│   ├── storage.py           # ChromaDB + SQLite storage
│   ├── embeddings.py        # FastEmbed wrapper
│   ├── constants.py         # Application constants
│   ├── exceptions.py        # Custom exceptions
│   ├── data_models.py       # Core data structures
│   ├── chunking.py          # Text chunking utilities
│   ├── pdf_utils.py         # PDF text extraction
│   ├── pdf_discovery.py     # PDF source discovery
│   ├── query_converter.py   # Natural language to PubMed
│   ├── utils.py             # Shared utilities
│   ├── agents/              # LLM-powered agents
│   ├── gui/                 # PySide6 interface
│   ├── llm/                 # LLM client abstraction
│   ├── pubmed/              # PubMed API integration
│   ├── quality/             # Study quality assessment
│   └── resources/           # Styles and assets
└── tests/                   # Test suite
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

`LiteStorage` manages ChromaDB collections and SQLite metadata:

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
- `SearchAgent`: Converts natural language to PubMed queries
- `ScoringAgent`: Scores document relevance
- `CitationAgent`: Extracts citations from documents
- `ReportingAgent`: Generates synthesis reports
- `InterrogationAgent`: Handles document Q&A

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

### Data Models

Core data structures in `data_models.py`:

- `LiteDocument`: Represents a document with metadata
- `LiteChunk`: A chunk of text with embedding
- `SearchSession`: Tracks a search workflow
- `ReviewCheckpoint`: Saves review progress
- `ScoredDocument`: Document with relevance score
- `Citation`: Extracted citation information
- `InterrogationSession`: Q&A session state

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

4. **Pure Functions**: Prefer small, reusable pure functions:

```python
# Prefer this
def extract_pmid(url: str) -> str | None:
    """Extract PMID from PubMed URL."""
    match = PMID_PATTERN.search(url)
    return match.group(1) if match else None

# Over this (stateful, complex)
class URLProcessor:
    def __init__(self):
        self.cache = {}

    def process(self, url):
        # Complex stateful logic...
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
