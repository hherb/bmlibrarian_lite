<p align="center">
  <img src="src/bmlibrarian_lite/resources/images/BML_icon_large.png" alt="BMLibrarian Lite" width="200">
</p>

# BMLibrarian Lite

A lightweight biomedical literature research tool - no PostgreSQL required.

BMLibrarian Lite is a simplified version of BMLibrarian that provides AI-powered literature search and analysis capabilities without requiring a PostgreSQL database nor a powerful GPU and fast memory for local AI. It uses only the PubMed E-utilities API for searching and fetching article metadata instead of a local database. It uses SQLite with sqlite-vec for vector storage and metadata, making it easy to install and use on any machine. Also, in order to allow it to run on computers with limited resources, it uses FastEmbed for local embeddings and allows to use cloud LLM providers like Anthropic Claude instead of relying exclusively on local inference. Using local models with ollama is optional.

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

- **Systematic Literature Review**: Search PubMed, score documents, extract citations, and generate reports
- **Document Interrogation**: Interactive Q&A with loaded documents
- **PDF Discovery & Download**: Automatic PDF retrieval from PubMed Central, Unpaywall, and DOI resolution
- **Quality Assessment**: Automated study quality evaluation with evidence grading
- **Multi-Model Benchmarking**: Compare LLM models on relevance scoring and quality classification
- **Research Questions Management**: Save, re-run, and manage past research questions
- **Audit Trail**: Real-time visibility into the review workflow with LLM reasoning transparency
- **Multiple LLM Providers**: Support for both Anthropic Claude (online) and Ollama (local)
- **Unified SQLite Storage**: Single database for metadata and vector embeddings - no external database needed

### iOS App (Swift/SwiftUI)

Native iOS app for medical fact-checking on-the-go.

- **Medical Fact Checker**: Verify medical claims against peer-reviewed literature
- **Dual Scoring System**: LLM-based relevance scoring plus on-device NLEmbedding semantic similarity
- **HyDE Enhancement**: Hypothetical Document Embedding for improved semantic matching
- **Budget Controls**: Per-run and monthly spending limits with real-time cost tracking
- **SwiftData Persistence**: Local storage of sessions, documents, citations, and reports
- **Clickable Citations**: Tap references in reports to view source document details
- **Smart Search**: Automatic alternative query generation when initial results are insufficient
- **iCloud Sync**: CloudKit integration for syncing data across devices

### macOS App (Swift/SwiftUI)

Native macOS app optimized for desktop workflows.

- **Native macOS UI**: Optimized layouts for larger screens with keyboard navigation
- **PDF Export**: Native AppKit-based PDF generation with A4/Letter paper sizes
- **Full-Text Viewer**: View retrieved full-text articles with JATS XML rendering
- **Hybrid Search**: Search both PubMed and Europe PMC simultaneously
- **iCloud Sync**: CloudKit integration for syncing with iOS devices
- **Future-Ready**: Architecture prepared for local LLM processing and PostgreSQL backend

### Android App (Kotlin/Jetpack Compose)

Native Android app with Material 3 design.

- **Material 3 Design**: Modern UI following Google's Material You guidelines
- **Medical Fact Checker**: Same fact-checking workflow as iOS/macOS
- **Jetpack Compose UI**: Declarative, modern Android UI toolkit
- **Room Database**: Local persistence with SQLite via Room
- **Hilt Dependency Injection**: Clean architecture with Dagger Hilt
- **Budget Controls**: Per-run and monthly spending limits
- **Multiple Search Providers**: Support for PubMed and Europe PMC
- **PDF Export**: Generate evidence reports as PDF documents
- **Session History**: Browse and revisit past fact-check sessions

## Quick Start

### Desktop Installation

**From PyPI (recommended):**

```bash
pip install bmlibrarian-lite
```

**From source:**

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian-lite.git
cd bmlibrarian-lite

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

### iOS App

The iOS app is located in `ios/MedicalFactChecker/`. To build:

1. **Open in Xcode**: Open `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj`
2. **Configure signing**: Set your development team in project settings
3. **Build and run**: Select your target device/simulator and build

**Configuration in iOS:**
- Open Settings tab to configure:
  - LLM API endpoint and key (OpenAI-compatible APIs)
  - NCBI email for PubMed API
  - Per-run and monthly budget limits
  - Enable/disable embedding scoring

### macOS App

The macOS app is a separate project located in `macos/MedicalFactCheckerMac/`. To build:

1. **Open in Xcode**: Open `macos/MedicalFactCheckerMac/MedicalFactCheckerMac.xcodeproj`
2. **Configure signing**: Set your development team in project settings
3. **Build and run**: Select "My Mac" as the target and build

**Or build from command line:**
```bash
cd macos/MedicalFactCheckerMac
xcodebuild -project MedicalFactCheckerMac.xcodeproj \
           -scheme MedicalFactCheckerMac \
           -configuration Debug \
           build
```

The macOS app shares the same core functionality as iOS but is designed to evolve independently with features like local LLM support and PostgreSQL backend.

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
  - LLM provider and API endpoint (OpenAI, Anthropic, or custom)
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
2. **Click "Search"** to query PubMed
3. **Review found articles** and adjust filters as needed
4. **Score documents** for relevance (1-5 scale)
5. **Extract citations** from high-scoring documents
6. **Generate a report** synthesizing the evidence

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

- **Queries Tab**: View generated PubMed queries and search statistics
- **Literature Tab**: Browse document cards with relevance scores and quality badges
  - Click cards to expand and view abstracts
  - See LLM rationales for scoring and quality decisions
  - Quality badges show study design (RCT, Systematic Review, etc.)
- **Citations Tab**: View extracted citation passages with highlighting

Right-click any document card to send it to the Document Interrogator for deeper analysis.

### iOS Medical Fact Checker

1. **Enter a medical claim or question** (e.g., "Vitamin D reduces COVID-19 severity")
2. **Tap "Check Evidence"** to start the workflow
3. **Review scored documents** with dual LLM/Embedding scores
4. **View the evidence report** with verdict and supporting citations
5. **Tap citations** to view source document details

**Score Comparison:**
- LLM scores use AI reasoning about document relevance
- Embedding scores use on-device NLEmbedding with HyDE (Hypothetical Document Embedding)
- Agreement indicators show when scores align or differ

### Android Medical Fact Checker

1. **Enter a medical claim** on the Fact Check screen
2. **Tap "Check"** to start the fact-checking workflow
3. **Review scored documents** as they are processed
4. **Optionally fetch more documents** if initial results are insufficient
5. **View the evidence report** with verdict badge and supporting citations
6. **Tap references** to view source document details
7. **Export as PDF** to share or save the report

**Features:**
- Progress indicators show each workflow step
- Budget tracking displays estimated costs before and during runs
- History tab shows all past sessions for easy reference

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
- Internet connection (for PubMed search and Claude API)
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
| Database | PostgreSQL + pgvector | SQLite + sqlite-vec | SwiftData | SwiftData* | Room (SQLite) |
| Embeddings | Ollama (local) | FastEmbed (CPU) | Apple NLEmbedding | Apple NLEmbedding | N/A |
| PDF Discovery | Full | Included | N/A | N/A | N/A |
| PDF Export | N/A | N/A | Included | Included | Included |
| Multi-Agent Workflow | Full orchestration | Simplified | Streamlined | Streamlined | Streamlined |
| Plugin System | Lab plugins | N/A | N/A | N/A | N/A |
| Multi-Model Benchmarking | N/A | Included | N/A | N/A | N/A |
| Research Questions | N/A | Save & re-run | History view | History view | History view |
| Budget Controls | N/A | N/A | Per-run & monthly | Per-run & monthly | Per-run & monthly |
| HyDE Embedding | N/A | N/A | Included | Included | N/A |
| Local LLM Support | N/A | Ollama | N/A | Planned | N/A |
| Search Providers | N/A | PubMed | PubMed + Europe PMC | PubMed + Europe PMC | PubMed + Europe PMC |
| Installation | Complex | `pip install` | Xcode build | Xcode build | Android Studio |

*macOS app is designed to support PostgreSQL backend in future versions.

## Documentation

Documentation is organized into three categories:

- **User Documentation** (`doc/user/`): End-user guides and tutorials
- **Developer Documentation** (`doc/developer/`): Architecture, API, and contribution guides
- **LLM Context** (`doc/llm/`): Context for AI assistants working with the codebase
  - `golden_rules.md` - Coding standards
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

GPL-3.0 License - see LICENSE file for details.

## Acknowledgments

BMLibrarian Lite is derived from [BMLibrarian](https://github.com/hherb/bmlibrarian), a comprehensive biomedical literature research platform.

## Support

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian-lite/issues)
- **Documentation**: See the `doc/` directory for detailed guides
