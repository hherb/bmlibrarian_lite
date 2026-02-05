# CLAUDE.md

## Project Overview

BMLibrarian Lite: Cross-platform biomedical literature research with AI-powered systematic review and fact-checking.

**Platforms:**
- **Desktop** (Python/PySide6): SQLite + sqlite-vec, FastEmbed, Anthropic/Ollama
- **iOS/macOS** (Swift/SwiftUI): SwiftData, NLEmbedding, OpenAI-compatible API
- **Android** (Kotlin/Compose): Room, Hilt, MVVM

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
agents/           # SearchAgent, ScoringAgent, CitationAgent, ReportingAgent, InterrogationAgent
benchmarking/     # Model comparison, statistics
gui/              # PySide6: SystematicReview, ResearchQuestions, AuditTrail, Report, DocumentInterrogation tabs
llm/              # LLMClient (Anthropic/Ollama providers)
pubmed/           # PubMedSearchClient
quality/          # QualityManager, study classification
config.py         # LiteConfig (~/.bmlibrarian_lite/)
storage.py        # LiteStorage (ChromaDB + SQLite)
europepmc.py      # EuropePMCClient (cursor pagination)
search_merger.py  # Deduplication (PMID/DOI/PMC/title)
fulltext_discovery.py  # Europe PMC XML → Unpaywall → DOI
embeddings.py     # LiteEmbedder (FastEmbed)
```

## Mobile Apps

**iOS** (`ios/MedicalFactChecker/`), **macOS** (`macos/MedicalFactCheckerMac/`):
- SwiftUI + SwiftData models (Document, FactCheckSession, SearchProvider)
- Services: FactCheckWorkflow, LLMService, EmbeddingService
- Views: FactCheck, History, Report, Settings

**Android** (`android/MedicalFactChecker/`):
- data/local: Room DB + DAOs
- data/remote: PubMed, Europe PMC, LLM, Unpaywall APIs
- domain: Models, WorkflowState
- ui: Compose screens + ViewModels
- di: Hilt modules

## BioMedLit Swift Package (`Packages/BioMedLit/`)

Shared iOS/macOS components:
- `JATS/`: XML parsing → HTML/Markdown
- `Services/`: EuropePMCService, PubMedService, FullTextService
- `Sync/`: iCloud/local folder sync (SyncEngine, SelectiveSyncCoordinator, SessionEvictionManager)
- `Utilities/`: RetryHelper (exponential backoff)

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
- `doc/cross_platform/` - Platform-agnostic algorithms
- `doc/developer/europepmc_and_pubmed.md` - API guide

Always use Context7 MCP when I need library/API documentation, code generation, setup or configuration steps without me having to explicitly ask.

