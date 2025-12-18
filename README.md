<p align="center">
  <img src="src/bmlibrarian_lite/resources/images/BML_icon_large.png" alt="BMLibrarian Lite" width="200">
</p>

# BMLibrarian Lite

A lightweight biomedical literature research tool - no PostgreSQL required.

BMLibrarian Lite is a simplified version of BMLibrarian that provides AI-powered literature search and analysis capabilities without requiring a PostgreSQL database nor a powerful GPU and fast memory for local AI. It uses only the PubMed E-utilities API for searching and fetching article metadata instead of a local database. It uses ChromaDB for vector storage and SQLite for metadata, making it easy to install and use on any machine. Also, in order to allow it to run on computers with limited resources, it uses FastEmbed for local embeddings and allows to use cloud LLM providers like Anthropic Claude instead of relying exclusively on local inference. Using local models with ollama is optional.


## Features

- **Systematic Literature Review**: Search PubMed, score documents, extract citations, and generate reports
- **Document Interrogation**: Interactive Q&A with loaded documents
- **PDF Discovery & Download**: Automatic PDF retrieval from PubMed Central, Unpaywall, and DOI resolution
- **Quality Assessment**: Automated study quality evaluation with evidence grading
- **Audit Trail**: Real-time visibility into the review workflow with LLM reasoning transparency
- **Multiple LLM Providers**: Support for both Anthropic Claude (online) and Ollama (local)
- **Embedded Storage**: ChromaDB + SQLite - no external database needed
- **Cross-Platform GUI**: PySide6-based desktop application

## Quick Start

### Installation

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

## Usage

### Systematic Review Workflow

1. **Enter your research question** in the main text area
2. **Click "Search"** to query PubMed
3. **Review found articles** and adjust filters as needed
4. **Score documents** for relevance (1-5 scale)
5. **Extract citations** from high-scoring documents
6. **Generate a report** synthesizing the evidence

### Audit Trail

The Audit Trail tab provides real-time visibility into the systematic review workflow:

- **Queries Tab**: View generated PubMed queries and search statistics
- **Literature Tab**: Browse document cards with relevance scores and quality badges
  - Click cards to expand and view abstracts
  - See LLM rationales for scoring and quality decisions
  - Quality badges show study design (RCT, Systematic Review, etc.)
- **Citations Tab**: View extracted citation passages with highlighting

Right-click any document card to send it to the Document Interrogator for deeper analysis.

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

- **chromadb**: Vector storage
- **fastembed**: CPU-optimized embeddings
- **anthropic**: Claude API client
- **ollama**: Ollama API client
- **PySide6**: GUI framework
- **PyMuPDF**: PDF processing

## Differences from Full BMLibrarian

BMLibrarian Lite is designed for ease of use and portability:

| Feature | BMLibrarian | BMLibrarian Lite |
|---------|-------------|------------------|
| Database | PostgreSQL + pgvector | ChromaDB + SQLite |
| Embeddings | Ollama (local) | FastEmbed (CPU) |
| PDF Discovery | Full (Unpaywall, PMC, OpenAthens) | Included (PMC, Unpaywall, DOI) |
| Multi-Agent Workflow | Full orchestration | Simplified workflow |
| Audit Trail | N/A | Real-time workflow visibility |
| Installation | Complex | Simple `pip install` |

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
