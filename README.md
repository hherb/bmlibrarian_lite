<p align="center">
  <img src="src/bmlibrarian_lite/resources/images/BML_icon_large.png" alt="BMLibrarian Lite" width="200">
</p>

# BMLibrarian Lite

A lightweight biomedical literature research tool - no PostgreSQL required.

BMLibrarian Lite is a simplified version of BMLibrarian that provides AI-powered literature search and analysis capabilities without requiring a PostgreSQL database nor a powerful GPU and fast memory for local AI. It uses PubMed E-utilities and Europe PMC APIs for searching and fetching article metadata. It uses SQLite with sqlite-vec for vector storage and metadata, making it easy to install and use on any machine. In order to allow it to run on computers with limited resources, it uses FastEmbed for local embeddings and allows use of cloud LLM providers like Anthropic Claude instead of relying exclusively on local inference. Using local models with Ollama is optional.

## Platform Support

BMLibrarian Lite is available on multiple platforms:

| Platform | Technology | Status |
|----------|------------|--------|
| **Desktop** | Python/PySide6 | Production |
| **iOS** | Swift/SwiftUI | Production |
| **macOS** | Swift/SwiftUI | Production |
| **Android** | Kotlin/Jetpack Compose | Production |

## Features

### Desktop Application (Python/PySide6)

Cross-platform desktop application for comprehensive systematic literature review.

- **Systematic Literature Review**: Search PubMed and Europe PMC, score documents, extract citations, and generate reports
- **Study Transparency Analysis**: Multi-pass analysis of funding disclosure, conflict of interest (with industry intermediary detection), data availability (with effective refusal detection), and trial registration — with risk warnings in reports
- **MCP Server**: Expose bmlibrarian_lite as an expert medical fact-checker via [Model Context Protocol](https://modelcontextprotocol.io/) for use with Claude Desktop, Claude Code, or any MCP-compatible client
- **Document Interrogation**: Interactive RAG-based Q&A with loaded documents
- **Full-Text Discovery**: Automatic full-text retrieval via Europe PMC XML, Europe PMC PDF, Unpaywall PDF, and DOI resolution
- **Quality Assessment**: Automated study quality evaluation with evidence grading
- **Multi-Model Benchmarking**: Compare LLM models on relevance scoring and quality classification
- **Parallel Processing**: Concurrent scoring and citation extraction with checkpointing and cancellation support
- **Smart Search**: Automatic alternative query generation when initial results are insufficient
- **Research Questions Management**: Save, re-run, and manage past research questions
- **Audit Trail**: Real-time visibility into the review workflow with LLM reasoning transparency
- **Multiple LLM Providers**: Support for both Anthropic Claude (online) and Ollama (local)
- **Unified SQLite Storage**: Single database for metadata and vector embeddings - no external database needed

### iOS App (Swift/SwiftUI)

Native iOS app for medical fact-checking on-the-go.

- **Medical Fact Checker**: Verify medical claims against peer-reviewed literature
- **Multiple LLM Providers**: Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, and custom endpoints
- **Dual Scoring System**: LLM-based relevance scoring plus on-device NLEmbedding semantic similarity
- **HyDE Enhancement**: Hypothetical Document Embedding for improved semantic matching
- **Study Transparency Analysis**: Funding, COI, data availability, and trial registration analysis with risk badges and detailed breakdown views
- **Smart Search**: Automatic alternative query generation when initial results are insufficient
- **Parallel Processing**: Concurrent document scoring and citation extraction with checkpointing
- **Full-Text Access**: Multi-source retrieval (Europe PMC XML, Europe PMC PDF, Unpaywall PDF, DOI) with JATS XML rendering
- **Hybrid Search**: Search PubMed, Europe PMC, or both simultaneously with deduplication
- **Budget Controls**: Per-run and monthly spending limits with real-time cost tracking
- **iCloud Sync**: Optional CloudKit integration for syncing data across devices
- **PDF Export**: Generate evidence reports as PDF documents
- **Session History**: Browse and revisit past fact-check sessions

### macOS App (Swift/SwiftUI)

Native macOS app optimized for desktop workflows.

- **Native macOS UI**: Optimized layouts for larger screens with keyboard navigation
- **Multiple LLM Providers**: Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, and custom endpoints
- **Study Transparency Analysis**: Funding, COI, data availability, and trial registration analysis with risk badges and detailed breakdown views
- **Smart Search**: Automatic alternative query generation when initial results are insufficient
- **Parallel Processing**: Concurrent document scoring and citation extraction with checkpointing
- **Full-Text Viewer**: View retrieved full-text articles with JATS XML rendering and Europe PMC PDF fallback
- **Hybrid Search**: Search both PubMed and Europe PMC simultaneously
- **PDF Export**: Native AppKit-based PDF generation with A4/Letter paper sizes
- **iCloud Sync**: CloudKit integration for syncing with iOS devices

### Android App (Kotlin/Jetpack Compose)

Native Android app with Material 3 design.

- **Material 3 Design**: Modern UI following Google's Material You guidelines
- **Medical Fact Checker**: Same fact-checking workflow as iOS/macOS
- **Multiple LLM Providers**: Anthropic, OpenAI, DeepSeek, Groq, Mistral, and custom endpoints
- **Study Transparency Analysis**: Funding, COI, data availability, and trial registration badges
- **Smart Search**: Automatic alternative query generation when initial results are insufficient
- **HyDE Enhancement**: Hypothetical Document Embedding for improved semantic matching
- **Full-Text Access**: Multi-source retrieval (Europe PMC XML, Europe PMC PDF, Unpaywall PDF, DOI) with JATS XML parsing
- **Hybrid Search**: PubMed, Europe PMC, or both simultaneously
- **Parallel Processing**: Concurrent document scoring and citation extraction
- **Budget Controls**: Per-run and monthly spending limits
- **PDF Export**: Generate evidence reports as PDF documents
- **Session History**: Browse and revisit past fact-check sessions
- **Room Database**: Local persistence with SQLite via Room
- **Hilt Dependency Injection**: Clean architecture with Dagger Hilt

### BioMedLit Swift Package

Shared iOS/macOS library (`Packages/BioMedLit/`) providing:

- **JATS XML Parsing**: Full-featured parser converting Journal Article Tag Suite XML to HTML/Markdown
- **Search Services**: PubMed and Europe PMC API clients with pagination
- **Full-Text Service**: Unified retrieval with fallback chain (Europe PMC XML → Europe PMC PDF → Unpaywall PDF → DOI)
- **Transparency Analysis**: Funding, COI, data availability, and trial compliance analyzers with CrossRef and ClinicalTrials.gov integration
- **Sync Engine**: iCloud/local folder synchronization with selective sync, change tracking, and conflict resolution
- **Utilities**: Retry helpers, cost calculator, query translator, response parser

## Quick Start

### Desktop Installation

**From PyPI (recommended):**

```bash
pip install bmlibrarian-lite
```

**From source:**

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite

# Create virtual environment and install
python -m venv .venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
pip install -e .
```

### Configuration

1. **Set your Anthropic API key** (for Claude):
   ```bash
   export ANTHROPIC_API_KEY="your-api-key-here"
   ```

2. **Or configure Ollama** (for local models):
   ```bash
   # Install Ollama: https://ollama.ai
   ollama pull llama3.2
   export OLLAMA_HOST="http://localhost:11434"
   ```

3. **Optional: Set your email for PubMed** (recommended):
   ```bash
   export NCBI_EMAIL="your@email.com"
   ```

4. **Optional: Configure PDF Discovery** (for Unpaywall API):
   - Go to Settings in the GUI
   - Enter your email address for Unpaywall API access
   - Configure OpenAthens if you have institutional access

### Running the Application

```bash
# Launch the GUI (short command)
bmll

# Or using the full name
bmlibrarian-lite

# Or using Python module
python -m bmlibrarian_lite
```

### CLI Commands

```bash
# Show storage statistics
bmll stats

# Validate configuration
bmll validate --verbose

# Show current configuration
bmll config

# Clear all data
bmll clear

# Show version
bmll --version
```

### MCP Server

BMLibrarian Lite can be used as an MCP server, allowing Claude Desktop, Claude Code, or any MCP-compatible client to use it as an expert medical fact-checker. See [HOWTO_MCP_SERVER.md](HOWTO_MCP_SERVER.md) for full setup instructions.

```bash
# Install as a uv tool (recommended)
uv tool install bmlibrarian-lite

# Or run from a local checkout
bmlibrarian-lite-mcp
```

The MCP server exposes four tools:
- **`fact_check_claim`**: Full evidence pipeline (search, score, cite, report) with progress notifications
- **`search_literature`**: Search PubMed and/or Europe PMC for articles
- **`get_document_fulltext`**: Retrieve full text by PMID, DOI, or PMC ID
- **`ask_document`**: RAG-based Q&A on loaded documents

### iOS App

The iOS app is located in `ios/MedicalFactChecker/`. To build:

1. **Open in Xcode**: Open `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`
2. **Configure signing**: Set your development team in project settings
3. **Build and run**: Select your target device/simulator and build

**Configuration in iOS:**
- Open Settings tab to configure:
  - LLM provider and API key (Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, or custom)
  - NCBI email for PubMed API
  - Search provider (PubMed, Europe PMC, or both)
  - Per-run and monthly budget limits
  - Enable/disable embedding scoring
  - iCloud sync (opt-in)

### macOS App

The macOS app is built from the same multiplatform project as the iOS app (`ios/MedicalFactChecker/`). To build:

1. **Open in Xcode**: Open `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`
2. **Configure signing**: Set your development team in project settings
3. **Build and run**: Select "My Mac" as the run destination and build

**Or build from command line:**
```bash
cd ios/MedicalFactChecker
xcodebuild -project MedicalFactChecker.xcodeproj \
           -scheme MedicalFactChecker \
           -destination 'platform=macOS' \
           -configuration Debug \
           build
```

### Android App

The Android app is located in `android/MedicalFactChecker/`. To build:

1. **Open in Android Studio**: Open the `android/MedicalFactChecker` directory
2. **Sync Gradle**: Android Studio will automatically sync dependencies
3. **Build and run**: Select your target device/emulator and click Run

**Or build from command line:**
```bash
cd android/MedicalFactChecker
./gradlew assembleDebug
```

**Configuration in Android:**
- Open Settings screen to configure:
  - LLM provider and API endpoint (Anthropic, OpenAI, DeepSeek, Groq, Mistral, or custom)
  - API key (stored securely in EncryptedSharedPreferences)
  - NCBI email for PubMed API
  - Per-run and monthly budget limits
  - Search provider preferences (PubMed, Europe PMC, or both)

**Requirements:**
- Android 8.0 (API 26) or higher
- Internet connection for API access

## Usage

### Systematic Review Workflow

1. **Enter your research question** in the main text area
2. **Click "Search"** to query PubMed and/or Europe PMC
3. **Review found articles** and adjust filters as needed
4. **Score documents** for relevance (1-5 scale) with parallel processing
5. **Review transparency analysis** for funding, COI, and data availability concerns
6. **Extract citations** from high-scoring documents
7. **Generate a report** synthesizing the evidence with risk warnings

### Research Questions Tab

The Research Questions tab helps you manage and revisit past research:

- **View past questions**: See all research questions with document counts and scores
- **Re-run searches**: Incrementally search for new documents with automatic deduplication
- **Context menu actions**: Re-classify study designs, re-score relevance, or delete questions
- **Run benchmarks**: Compare model performance directly from saved questions

### Multi-Model Benchmarking

Compare how different LLM models perform on your documents:

- **Relevance Score Benchmarking**: Compare scoring consistency across models
  - Agreement matrices showing model-to-model consistency
  - Score distribution analysis
  - Cost and latency tracking per model

- **Quality Assessment Benchmarking**: Compare study design classification
  - Design agreement matrix
  - Tier agreement for quality levels
  - Document-level disagreement highlighting

Access benchmarking from the Systematic Review tab after scoring documents.

### Audit Trail

The Audit Trail tab provides real-time visibility into the systematic review workflow:

- **Queries Tab**: View generated search queries and statistics
- **Literature Tab**: Browse document cards with relevance scores, quality badges, and transparency risk badges
  - Click cards to expand and view abstracts
  - See LLM rationales for scoring and quality decisions
  - Quality badges show study design (RCT, Systematic Review, etc.)
  - Transparency risk badges flag funding, COI, or data availability concerns
- **Citations Tab**: View extracted citation passages with highlighting

Right-click any document card to send it to the Document Interrogator for deeper analysis.

### iOS/macOS Medical Fact Checker

1. **Enter a medical claim or question** (e.g., "Vitamin D reduces COVID-19 severity")
2. **Tap "Check Evidence"** to start the workflow
3. **Review scored documents** with dual LLM/Embedding scores and transparency badges
4. **View the evidence report** with verdict and supporting citations
5. **Tap citations** to view source document details or full text
6. **Export to PDF** or share

### Android Medical Fact Checker

1. **Enter a medical claim** on the Fact Check screen
2. **Tap "Check"** to start the fact-checking workflow
3. **Review scored documents** as they are processed with transparency badges
4. **Optionally fetch more documents** if initial results are insufficient
5. **View the evidence report** with verdict badge and supporting citations
6. **Tap references** to view source document details or full text
7. **Export as PDF** to share or save the report

### Document Interrogation

1. **Switch to the "Document Interrogation" tab**
2. **Load a document** (PDF, TXT, or MD file)
3. **Ask questions** about the document content
4. **Get AI-powered answers** with source references

## Configuration

Configuration is stored in `~/.bmlibrarian_lite/config.json`:

```json
{
  "llm": {
    "provider": "anthropic",
    "model": "claude-sonnet-4-20250514",
    "temperature": 0.7,
    "max_tokens": 4096
  },
  "embeddings": {
    "model": "BAAI/bge-small-en-v1.5"
  },
  "pubmed": {
    "email": "your@email.com"
  },
  "search": {
    "chunk_size": 512,
    "chunk_overlap": 50,
    "similarity_threshold": 0.7,
    "max_results": 100
  }
}
```

### LLM Providers

**Anthropic Claude** (default):
```json
{
  "llm": {
    "provider": "anthropic",
    "model": "claude-sonnet-4-20250514"
  }
}
```

**Ollama** (local):
```json
{
  "llm": {
    "provider": "ollama",
    "model": "llama3.2"
  }
}
```

You can also use the model string format: `anthropic:claude-sonnet-4-20250514` or `ollama:llama3.2`

## Requirements

- Python 3.12+
- Internet connection (for PubMed/Europe PMC search and Claude API)
- ~500MB disk space for embeddings cache

### Dependencies

- **sqlite-vec**: Vector similarity search extension for SQLite
- **fastembed**: CPU-optimized embeddings
- **anthropic**: Claude API client
- **ollama**: Ollama API client
- **PySide6**: GUI framework
- **PyMuPDF**: PDF processing

## Differences from Full BMLibrarian

BMLibrarian Lite is designed for ease of use and portability:

| Feature | BMLibrarian | Desktop (Python) | iOS App | macOS App | Android App |
|---------|-------------|------------------|---------|-----------|-------------|
| Database | PostgreSQL + pgvector | SQLite + sqlite-vec | SwiftData | SwiftData | Room (SQLite) |
| Embeddings | Ollama (local) | FastEmbed (CPU) | Apple NLEmbedding | Apple NLEmbedding | N/A |
| Full-Text Discovery | Full | Europe PMC XML/PDF + Unpaywall + DOI | Europe PMC XML/PDF + Unpaywall + DOI | Europe PMC XML/PDF + Unpaywall + DOI | Europe PMC XML/PDF + Unpaywall + DOI |
| PDF Export | N/A | N/A | Included | Included | Included |
| Transparency Analysis | N/A | Included | Included | Included | Included |
| Parallel Processing | N/A | Included | Included | Included | Included |
| Multi-Agent Workflow | Full orchestration | Simplified | Streamlined | Streamlined | Streamlined |
| Plugin System | Lab plugins | N/A | N/A | N/A | N/A |
| MCP Server | N/A | Included | N/A | N/A | N/A |
| Multi-Model Benchmarking | N/A | Included | N/A | N/A | N/A |
| Smart Search | N/A | Included | Included | Included | Included |
| Research Questions | N/A | Save & re-run | History view | History view | History view |
| Budget Controls | N/A | N/A | Per-run & monthly | Per-run & monthly | Per-run & monthly |
| HyDE Embedding | N/A | N/A | Included | Included | Included |
| Local LLM Support | N/A | Ollama | Ollama | Ollama | N/A |
| Search Providers | N/A | PubMed + Europe PMC | PubMed + Europe PMC | PubMed + Europe PMC | PubMed + Europe PMC |
| iCloud Sync | N/A | N/A | Included | Included | N/A |
| Installation | Complex | `pip install` | Xcode build | Xcode build | Android Studio |

## Documentation

Documentation is organized into several categories:

- **User Documentation** (`doc/user/`): End-user guides and tutorials
- **Developer Documentation** (`doc/developer/`): Architecture, API, and contribution guides
- **Cross-Platform Algorithms** (`doc/cross_platform/`): Platform-agnostic algorithm specifications
  - `parallel_processing.md` - Parallel scoring and citation extraction
  - `fulltext_retrieval.md` - Full-text discovery chain
  - `hybrid_search.md` - Multi-provider search
  - `jats_parsing.md` - JATS XML parsing
  - `sync_protocol.md` - Sync protocol specification
- **LLM Context** (`doc/llm/`): Context for AI assistants working with the codebase
  - `golden_rules.md` - Python/PySide6 coding standards
  - `general_golden_rules.md` - Swift/Kotlin coding standards
  - `database-schema.md` - Database schema reference

## Development

```bash
# Install development dependencies
pip install -e ".[dev]"

# Run tests
pytest

# Run linting
ruff check .

# Run type checking
mypy src/
```

## License

Copyright (C) 2024-2026 Dr Horst Herb

AGPL-3.0 License - see LICENSE file for details.

## Acknowledgments

BMLibrarian Lite is derived from [BMLibrarian](https://github.com/hherb/bmlibrarian), a comprehensive biomedical literature research platform.

## Support

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian_lite/issues)
- **Documentation**: See the `doc/` directory for detailed guides
