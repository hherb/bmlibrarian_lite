# BMLibrarian Lite User Guide

A lightweight biomedical literature research tool for systematic reviews and document interrogation.

## Getting Started

### Installation

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian-lite.git
cd bmlibrarian-lite

# Create virtual environment and install with uv
uv venv
source .venv/bin/activate  # On Windows: .venv\Scripts\activate
uv pip install -e .
```

### Configuration

BMLibrarian Lite requires an LLM provider. Choose one of the following:

#### Option A: Anthropic Claude (Recommended)

1. Get an API key from [Anthropic Console](https://console.anthropic.com/)
2. Set the environment variable:
   ```bash
   export ANTHROPIC_API_KEY="your-api-key-here"
   ```
   Or configure it in the Settings dialog after launching the application.

#### Option B: Ollama (Local)

1. Install Ollama from [ollama.ai](https://ollama.ai)
2. Pull a model:
   ```bash
   ollama pull llama3.2
   ```
3. Set the host (optional, defaults to localhost):
   ```bash
   export OLLAMA_HOST="http://localhost:11434"
   ```

#### PubMed Email (Recommended)

Set your email for PubMed API access to avoid rate limiting:
```bash
export NCBI_EMAIL="your@email.com"
```

### Launching the Application

```bash
python bmlibrarian_lite.py
```

## Features

### Systematic Literature Review

The Systematic Review tab provides a complete workflow for conducting literature reviews:

1. **Enter Research Question**: Type your research question in natural language
2. **Search PubMed**: The system converts your question to a PubMed query and fetches articles
3. **Review Articles**: Browse the retrieved articles with metadata
4. **Score Relevance**: Rate articles on a 1-5 scale for relevance to your question
5. **Extract Citations**: Automatically extract key citations from high-scoring articles
6. **Generate Report**: Create a synthesized report summarizing the evidence

#### Search Tips

- Be specific in your research question
- Include key terms, populations, and outcomes of interest
- The AI converts natural language to optimized PubMed queries

#### Scoring Guidelines

| Score | Meaning |
|-------|---------|
| 5 | Highly relevant, directly addresses the question |
| 4 | Relevant, provides useful supporting evidence |
| 3 | Moderately relevant, tangentially related |
| 2 | Low relevance, limited applicability |
| 1 | Not relevant |

### Document Interrogation

The Document Interrogation tab allows interactive Q&A with loaded documents:

1. **Load Document**: Open a PDF, TXT, or Markdown file
2. **Ask Questions**: Type questions about the document content
3. **Get Answers**: Receive AI-generated answers with source references

#### Supported File Types

- PDF documents (`.pdf`)
- Plain text files (`.txt`)
- Markdown files (`.md`)

### PDF Discovery and Download

BMLibrarian Lite can automatically find and download PDFs from multiple sources:

- **PubMed Central**: Free full-text articles
- **Unpaywall**: Open access versions of paywalled articles
- **DOI Resolution**: Direct publisher links

Configure your email in Settings to enable Unpaywall access.

## Configuration

### Settings Dialog

Access Settings from the main window to configure:

- **LLM Provider**: Choose between Anthropic Claude and Ollama
- **Model Selection**: Select from available models
- **Temperature**: Control response creativity (lower = more focused)
- **Email**: Set for PubMed and Unpaywall API access
- **API Keys**: Configure provider credentials

### Configuration File

Settings are stored in `~/.bmlibrarian_lite/config.json`:

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

## CLI Commands

BMLibrarian Lite provides command-line utilities:

```bash
# Show storage statistics
python bmlibrarian_lite.py stats

# Validate configuration
python bmlibrarian_lite.py validate --verbose

# Show current configuration
python bmlibrarian_lite.py config --json

# Clear all stored data
python bmlibrarian_lite.py clear
```

## Data Storage

All data is stored locally in `~/.bmlibrarian_lite/`:

- **ChromaDB**: Vector embeddings for semantic search
- **SQLite**: Document metadata and session data

No external database server is required.

## Troubleshooting

### Common Issues

**"API key not set" error**
- Ensure `ANTHROPIC_API_KEY` is set in your environment
- Or configure it in Settings

**"Connection refused" with Ollama**
- Verify Ollama is running: `ollama list`
- Check the host URL in settings

**Slow embedding generation**
- First run downloads the embedding model (~100MB)
- Subsequent runs use the cached model

**PubMed rate limiting**
- Set `NCBI_EMAIL` to increase rate limits
- Consider getting a PubMed API key for heavy usage

### Getting Help

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian-lite/issues)
- **Documentation**: See other files in this `doc/` directory
