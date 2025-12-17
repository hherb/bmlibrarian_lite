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

**PDF Discovery** (`pdf_discovery.py`)
- `PDFDiscoverer` - Finds and downloads PDFs from PubMed Central, Unpaywall, and DOI resolution

**Quality Assessment** (`quality/`)
- Study classification, evidence grading, and quality scoring
- `QualityManager` orchestrates the assessment workflow

### GUI Structure (`gui/`)

The PySide6 GUI uses a two-tab design:
- `SystematicReviewTab` - Search PubMed, score documents, extract citations, generate reports
- `DocumentInterrogationTab` - Load documents and perform Q&A

Background operations use `QThread` workers in `workers.py` to keep the UI responsive.

### Data Flow

1. User enters research question → `SearchAgent` converts to PubMed query
2. `PubMedSearchClient` fetches articles → stored in `LiteStorage`
3. `LiteEmbedder` (FastEmbed) creates embeddings → stored in ChromaDB
4. `ScoringAgent` scores relevance → `CitationAgent` extracts citations
5. `ReportingAgent` generates final report

## Key Patterns

- **Lazy initialization**: LLM clients and embedders are created on first use
- **Qt signals/slots**: GUI components communicate via Qt signal system
- **Dataclasses throughout**: `LiteDocument`, `LiteChunk`, `SearchSession`, etc.

## Environment Variables

- `ANTHROPIC_API_KEY` - Required for Claude API
- `OLLAMA_HOST` - Ollama server URL (default: http://localhost:11434)
- `NCBI_EMAIL` - Recommended for PubMed API
- `TOKENIZERS_PARALLELISM=false` - Set automatically to avoid HuggingFace warnings
