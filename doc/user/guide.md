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

### Audit Trail

The Audit Trail tab provides real-time visibility into the systematic review workflow. It has three sub-tabs:

#### Queries Tab

Shows all generated PubMed queries during the workflow:
- The natural language question and resulting PubMed query
- Statistics: documents found, scored, citations extracted
- Query history for the current session

#### Literature Tab

Displays document cards for all retrieved articles:

**Document Cards:**
- **Header**: Shows quality badge (RCT, SR, etc.), relevance score (1-5), and title
- **Metadata**: Authors, journal, year, PMID/DOI
- **Click to expand**: View the full abstract
- **LLM Rationale**: See why the document received its score

**Quality Badges:**
- **RCT**: Randomized Controlled Trial (gold standard)
- **SR**: Systematic Review / Meta-analysis
- **Cohort**: Cohort study
- **Case-Ctrl**: Case-control study
- **Cross-Sec**: Cross-sectional study
- **Case**: Case report/series

**Interactions:**
- **Left-click**: Expand/collapse the card to show abstract
- **Right-click**: Context menu with options:
  - Send to Interrogator (opens document for Q&A)
  - Copy PMID / Copy DOI
  - Expand / Collapse

#### Citations Tab

Shows extracted citation passages:
- Citation number and quality badge
- Document metadata
- Highlighted passage within the abstract context
- Relevance explanation from the LLM

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

### Quality Assessment

When enabled, the quality filter assesses each document for:

- **Study Design**: RCT, systematic review, cohort, case-control, etc.
- **Quality Tier**: High, Medium, Low based on methodology
- **Evidence Level**: Based on study design hierarchy

Quality badges appear on document cards showing the study type with color coding.

## Configuration

### Settings Dialog

Access Settings from the main window to configure:

- **LLM Provider**: Choose between Anthropic Claude and Ollama
- **Model Selection**: Select from available models
- **Temperature**: Control response creativity (lower = more focused)
- **Email**: Set for PubMed and Unpaywall API access
- **API Keys**: Configure provider credentials
- **Quality Filter**: Set minimum quality tier for filtering

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

- **ChromaDB** (`chroma/`): Vector embeddings for semantic search
- **SQLite** (`metadata.db`): Document metadata and session data
- **PDFs** (`pdfs/`): Downloaded PDF files
- **Fulltexts** (`fulltexts/`): Extracted full-text content

No external database server is required.

## Workflow Tips

### Best Practices for Systematic Reviews

1. **Start with a focused question**: Use PICO format (Population, Intervention, Comparison, Outcome)
2. **Review the generated query**: Check the Audit Trail to see the PubMed query
3. **Adjust scoring threshold**: Higher threshold = more selective results
4. **Check quality badges**: Prioritize RCTs and systematic reviews for treatment questions
5. **Read LLM rationales**: Understand why documents were scored as they were

### Using the Interrogator

1. **Start from Audit Trail**: Right-click a document card and select "Send to Interrogator"
2. **Ask specific questions**: "What were the primary outcomes?" rather than "Tell me about this study"
3. **Follow up**: Ask clarifying questions based on the AI's responses

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

**Quality badges not appearing**
- Ensure quality filtering is enabled in Settings
- Quality assessment only runs when minimum tier is set

### Getting Help

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian-lite/issues)
- **Documentation**: See other files in this `doc/` directory
