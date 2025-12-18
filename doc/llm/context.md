# BMLibrarian Lite - LLM Context Document

This document provides essential context for LLMs (Claude, GPT, etc.) working with the BMLibrarian Lite codebase.

## Project Purpose

BMLibrarian Lite is a biomedical literature research tool that:
- Searches PubMed for scientific articles
- Scores document relevance using AI
- Extracts citations and generates synthesis reports
- Provides document Q&A capabilities
- Displays audit trail with LLM reasoning transparency

It is a "lite" version requiring no PostgreSQL - uses ChromaDB + SQLite instead.

## Key Files and Their Purposes

| File | Purpose |
|------|---------|
| `bmlibrarian_lite.py` | CLI entry point with subcommands |
| `src/bmlibrarian_lite/config.py` | Configuration management with dataclasses |
| `src/bmlibrarian_lite/storage.py` | ChromaDB + SQLite storage layer |
| `src/bmlibrarian_lite/llm/client.py` | Unified LLM client (Anthropic/Ollama) |
| `src/bmlibrarian_lite/agents/base.py` | Base agent class with `_chat()` method |
| `src/bmlibrarian_lite/gui/app.py` | Main PySide6 window |
| `src/bmlibrarian_lite/gui/audit_trail_tab.py` | Audit trail container (NEW) |
| `src/bmlibrarian_lite/gui/document_card.py` | Collapsible document cards (NEW) |
| `src/bmlibrarian_lite/constants.py` | Application-wide constants |

## Code Style Rules (MUST FOLLOW)

### 1. Docstrings Are Mandatory

Every public function, class, and method needs a Google-style docstring:

```python
def fetch_article(pmid: str, timeout: int = 30) -> Article | None:
    """Fetch article metadata from PubMed.

    Args:
        pmid: The PubMed ID to fetch.
        timeout: Request timeout in seconds.

    Returns:
        Article object if found, None otherwise.

    Raises:
        NetworkError: If the request fails.
    """
```

### 2. Type Hints Are Mandatory

All function signatures require complete type annotations:

```python
# Correct
def process_chunks(
    chunks: list[LiteChunk],
    embedder: LiteEmbedder,
    batch_size: int = 32,
) -> dict[str, list[float]]:

# Incorrect - missing types
def process_chunks(chunks, embedder, batch_size=32):
```

### 3. No Magic Numbers

Never hardcode numeric values. Use constants:

```python
# Wrong
if len(text) > 512:
    chunks = split_text(text, 512, 50)

# Correct
from bmlibrarian_lite.constants import (
    CHUNK_SIZE_DEFAULT,
    CHUNK_OVERLAP_DEFAULT,
)

if len(text) > CHUNK_SIZE_DEFAULT:
    chunks = split_text(text, CHUNK_SIZE_DEFAULT, CHUNK_OVERLAP_DEFAULT)
```

### 4. DPI Scaling Required

All pixel dimensions must use the `scaled()` function:

```python
from bmlibrarian_lite.resources.styles.dpi_scale import scaled

widget.setMinimumHeight(scaled(50))
layout.setContentsMargins(scaled(8), scaled(8), scaled(8), scaled(8))
```

### 5. Thread Safety for Shared State

Use locks for concurrent access:

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

### 6. Use Constants Module

All numeric and string constants go in `constants.py`:

```python
# In constants.py
CHUNK_SIZE_DEFAULT: int = 512
CHUNK_OVERLAP_DEFAULT: int = 50
SIMILARITY_THRESHOLD_DEFAULT: float = 0.7
MAX_RESULTS_DEFAULT: int = 100
PUBMED_BASE_URL: str = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

# Audit trail constants
AUDIT_CARD_PADDING: int = 12
AUDIT_CARD_HEADER_COLOR: str = "#E3F2FD"
AUDIT_ABSTRACT_MAX_LINES: int = 15
```

## Common Patterns

### Creating an Agent

```python
from bmlibrarian_lite.agents.base import LiteBaseAgent
from bmlibrarian_lite.llm import LLMMessage

class MyAgent(LiteBaseAgent):
    """Agent for specific task.

    Attributes:
        config: Lite configuration instance.
    """

    SYSTEM_PROMPT: str = "You are a specialized assistant for..."

    def execute(self, input_data: str) -> str:
        """Execute the agent's task.

        Args:
            input_data: Input to process.

        Returns:
            Processed result.
        """
        messages = [
            self._create_system_message(self.SYSTEM_PROMPT),
            self._create_user_message(input_data),
        ]
        return self._chat(messages)
```

### Creating a Document Card

```python
from bmlibrarian_lite.gui.document_card import DocumentCard
from bmlibrarian_lite.data_models import LiteDocument
from bmlibrarian_lite.quality.data_models import QualityAssessment

# Create card with all optional parameters
card = DocumentCard(
    document=document,
    score=4,
    score_rationale="Highly relevant because...",
    quality_assessment=assessment,
    citation_rationale="Selected this passage because...",
    show_abstract=False,  # Start collapsed
)

# Connect signals
card.clicked.connect(self._on_card_clicked)
card.send_to_interrogator.connect(self._on_send_to_interrogator)

# Update dynamically
card.set_score(5, "Updated rationale")
card.set_quality_assessment(new_assessment)
```

### GUI Signal Patterns

```python
from PySide6.QtCore import Signal

class MyTab(QWidget):
    # Define signals
    document_scored = Signal(object)  # ScoredDocument
    quality_assessed = Signal(str, object)  # (doc_id, QualityAssessment)

    def _on_scoring_complete(self, scored_doc: ScoredDocument) -> None:
        """Handle scoring completion."""
        self.document_scored.emit(scored_doc)

# Connect in parent
self.review_tab.document_scored.connect(self.audit_tab.on_document_scored)
```

### Using Storage

```python
from bmlibrarian_lite import LiteConfig, LiteStorage, LiteDocument

def store_document(
    storage: LiteStorage,
    title: str,
    content: str,
    metadata: dict[str, Any],
) -> str:
    """Store a document and return its ID.

    Args:
        storage: Storage instance.
        title: Document title.
        content: Document content.
        metadata: Additional metadata.

    Returns:
        The generated document ID.
    """
    doc = LiteDocument(
        id=generate_id(),
        title=title,
        content=content,
        metadata=metadata,
    )
    storage.add_document(doc)
    return doc.id
```

## Environment Variables

| Variable | Purpose | Required |
|----------|---------|----------|
| `ANTHROPIC_API_KEY` | Anthropic Claude API key | Yes (if using Claude) |
| `OLLAMA_HOST` | Ollama server URL | No (defaults to localhost:11434) |
| `NCBI_EMAIL` | Email for PubMed API | Recommended |
| `TOKENIZERS_PARALLELISM` | Set to "false" automatically | No |

## Common Tasks

### Adding a New Configuration Option

1. Add field to appropriate dataclass in `config.py`
2. Add default value as constant in `constants.py`
3. Update `to_dict()` and `from_dict()` methods
4. Add to `validate()` if validation needed

### Adding a New Agent

1. Create new file in `agents/` directory
2. Inherit from `LiteBaseAgent`
3. Define `SYSTEM_PROMPT` as class constant
4. Implement main method with docstring and type hints
5. Export in `agents/__init__.py`

### Adding a New GUI Tab

1. Create new file in `gui/` directory
2. Inherit from `QWidget`
3. Use signals for async communication
4. Create workers for long operations
5. Add tab in `app.py`

### Adding Audit Trail Support

1. Define signals in the source component (e.g., SystematicReviewTab)
2. Emit signals at appropriate workflow points
3. Connect signals in `app.py` to AuditTrailTab methods
4. Implement handler methods in AuditTrailTab

## File Organization Principles

- Keep modules focused and small
- Group related functionality in subpackages
- Put shared utilities in `utils.py`
- Put all constants in `constants.py`
- Put all exceptions in `exceptions.py`
- Put all data models in `data_models.py`

## Testing Expectations

- Tests go in `tests/` directory
- Use pytest fixtures for setup
- Test file names: `test_<module>.py`
- Test function names: `test_<behavior>`
- Mock external services (PubMed, LLM APIs)
- For GUI tests, use the `qapp` fixture

## Related Documentation

- `golden_rules.md` - Complete coding standards (MUST READ)
- `database-schema.md` - Database schema reference
- `../developer/guide.md` - Full developer guide
