# BMLibrarian Lite User Guide

A lightweight biomedical literature research tool for systematic reviews and document interrogation.

## Getting Started

### Installation from PyPI

```bash
# Recommended: install with uv
uv pip install bmlibrarian-lite

# Alternative: install with pip
pip install bmlibrarian-lite
```

### Installation from Source

```bash
# Clone the repository
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite

# Recommended: using uv
uv venv && source .venv/bin/activate  # On Windows: .venv\Scripts\activate
uv pip install -e .

# Alternative: using pip
python -m venv .venv && source .venv/bin/activate
pip install -e .
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
# GUI (recommended)
bmlibrarian-lite-gui

# CLI
bmll
```

## Features

### Systematic Literature Review

The Systematic Review tab provides a complete workflow for conducting literature reviews:

1. **Enter Research Question**: Type your research question in natural language
2. **Search**: The system searches PubMed and/or Europe PMC, deduplicating results across providers
3. **Review Articles**: Browse the retrieved articles with metadata
4. **Score Relevance**: AI scores articles on a 1-5 scale for relevance to your question (with parallel processing for cloud providers)
5. **Transparency Analysis**: Studies are analyzed for funding disclosure, conflict of interest, data availability, and trial registration
6. **Extract Citations**: Key passages are automatically extracted from high-scoring articles (with parallel processing)
7. **Generate Report**: A synthesized report is created summarizing the evidence, including risk warnings based on transparency analysis

#### Search Providers

- **PubMed**: NCBI's biomedical literature database (default)
- **Europe PMC**: Alternative provider with cursor-based pagination and full-text access
- Results from multiple providers are automatically deduplicated by PMID, DOI, PMC ID, or title similarity

#### When a Search Is Incomplete

A database that cannot be reached is never reported as one with no articles.

- **The search failed outright** (for example PubMed rate-limited the request, or the connection failed): the review stops with an error dialog naming the database and the reason, and saying what to do next: for example wait a minute, add or check the NCBI API key in Settings, or check the internet connection.
- **Part of the search failed** (one of two providers, or a batch of records): the review continues on what was retrieved. A warning appears under Progress, the report opens with an **Incomplete search** notice, and its Methodology section lists what is missing and why.
- **Research Questions → search for more documents** keeps going past a batch of records it could not fetch, and stops at a page of results it could not retrieve. It hands the documents it found to the review with what is missing, so that review's report opens with the same notice. If the failures leave it with no new document, it shows an error with what to do next.

#### When the AI Cannot Read What Was Found

A model that could not answer is never reported as a literature with nothing
relevant in it.

- **No document could be scored** (the model provider is unreachable, refuses
  the API key, or rate-limits every request): the review stops with an error
  naming what failed and what to do next. It does not say "No documents scored
  3 or higher": nobody knows what those documents would have scored.
- **Some documents could not be scored, or could not be read for citations**:
  the review continues on the rest. A warning appears under Progress, the
  report opens with an **Incomplete analysis** notice, and its Methodology
  section records it under Analysis Completeness. Those documents are not
  counted as rejected.
- **The audit trail names them.** Its dialog lists the documents that could
  not be scored, and the relevant documents whose citations could not be
  extracted, each with the reason. For every relevant document it says whether
  it was cited, held nothing quotable, or could not be read — three different
  things. A report restored from an older run that never recorded this says
  so rather than guessing.
- **A report that could not be generated is not saved.** The review ends with
  an error in the report step, and nothing is added to the report folder or
  offered under Load Report.

#### Search Tips

- Be specific in your research question
- Include key terms, populations, and outcomes of interest
- The AI converts natural language to optimized search queries

#### Scoring Guidelines

| Score | Meaning |
|-------|---------|
| 5 | Highly relevant, directly addresses the question |
| 4 | Relevant, provides useful supporting evidence |
| 3 | Moderately relevant, tangentially related |
| 2 | Low relevance, limited applicability |
| 1 | Not relevant |

### Research Questions

The Research Questions tab lets you manage and revisit past searches:

- View all previous research questions. The **Scored** column counts the documents a model scored; documents whose every scoring failed are shown beside it, for example **12 (+3 failed)**
- Re-run searches with incremental pagination (fetch more results)
- Automatic deduplication of already-scored documents. A document whose every
  scoring failed is not counted as scored: a re-run hands it back to be scored
  again, and says how many it is retrying (for example **Found 5 new
  documents, and 3 whose scoring failed before**)
- Context menu: re-classify, re-score, re-analyse transparency, delete, or run benchmarks
- **Load** shows the question's saved report and audit trail, including each
  study's stored transparency badge. Nothing is fetched: a study whose stored
  assessment is out of date, or that has none, reads **Not assessed** with the
  reason on hover
- **Re-analyse Transparency** (context menu, when transparency analysis is on)
  re-analyses only the question's studies whose assessment is missing, out of
  date, or provisional. It says how many that is, and how many carry no
  PubMed ID or DOI to look one up by, before it starts; it can be cancelled,
  and the badges of a loaded question update as each study comes back. A
  study whose sources could not all be read is reported as **provisional**:
  its result is shown with that caveat, and it stays pending

### Audit Trail

The Audit Trail tab provides real-time visibility into the systematic review workflow. It has three sub-tabs:

#### Queries Tab

Shows all generated search queries during the workflow:
- The natural language question and resulting search query
- Statistics: documents found, scored, citations extracted — and, when any
  failed, the documents the model could not score, counted apart from those
  it scored
- Query history for the current session

#### Literature Tab

Displays document cards for all retrieved articles:

**Document Cards:**
- **Header**: Shows quality badge (RCT, SR, etc.), relevance score (1-5), transparency risk badge, and title. A document the model could not score shows a grey **Scoring failed** badge instead of a score; hover over it for the reason. After the review finishes, cards are ordered by score, then the documents that could not be scored, then those never scored
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

### Study Transparency Analysis

Each study is automatically analyzed for transparency indicators:

- **Funding Disclosure**: Whether funding sources are declared
- **Conflict of Interest**: Whether COI statements are present
- **Data Availability**: Whether underlying data is shared
- **Trial Registration**: Whether the study is registered (e.g., ClinicalTrials.gov)
- **Transparency Score**: Overall transparency rating

Transparency results feed into risk warnings that appear in generated reports, flagging studies with potential concerns.

A study can also show a grey **Not assessed** badge. That is not a finding
against the study — it means BMLibrarian has nothing to report about it, and
hovering over the badge says why:

- **The analysis could not be completed**: a source was unreachable, refused
  the request, or limited how often it can be called. The badge says which,
  and what you can do about it.
- **The record carries neither a PubMed ID nor a DOI**, so there was nothing
  to look the study up by.
- **The stored assessment was made by an earlier version of the analyser.**
  When a correction changes what the analyser would find, studies assessed
  before it are re-analysed the next time they come up in a review, or when
  you choose **Re-analyse Transparency** for their question on the Research
  Questions tab. Until that happens their old score and risk level are
  withheld rather than shown.
  A report counts those studies separately and says how many are waiting, and
  annotates each affected reference rather than leaving it bare.

> **After upgrading to analyser version 2.0, expect this once, for
> everything.** That release corrected what the analyser accepts as evidence,
> so *every* assessment stored before it is superseded. Transparency badges
> will read **Not assessed** across the board until each study has been
> looked at again, which happens the next time it appears in a review, or
> when you re-analyse its question from the Research Questions tab. This is
> the correction working, not the feature breaking. Re-analysis is paced
> against rate-limited sources, so it is deliberately not done all at once
> when you open the application.

A report's **Transparency Analysis** section accounts for every study it was
asked about. Alongside the risk distribution it names how many are awaiting
re-analysis, and how many came back with no finding at all — because an
analysis that could not be made is not a study with nothing to declare. Each
of those counts says what it is a share of, for example **12 of the 40
studies reviewed; 3 of them are cited in this report**, since only the cited
studies are annotated in the reference list. If
transparency analysis was switched on, the report says so even when every
analysis failed.

### Full-Text Discovery

BMLibrarian Lite can automatically find and retrieve full-text content through a fallback chain:

1. **Europe PMC XML**: Free full-text articles in structured JATS format
2. **Europe PMC PDF**: PDF versions from Europe PMC
3. **Unpaywall**: Open access versions of paywalled articles
4. **DOI Resolution**: Direct publisher links
5. **Manual Upload**: Upload PDFs for documents not found automatically

JATS XML articles are rendered with full support for tables, figures, references, and anchor navigation.

Configure your email in Settings to enable Unpaywall access.

### Document Interrogation

The Document Interrogation tab allows interactive Q&A with loaded documents:

1. **Load Document**: Open a PDF, TXT, or Markdown file
2. **Ask Questions**: Type questions about the document content
3. **Get Answers**: Receive AI-generated answers with source references

#### Supported File Types

- PDF documents (`.pdf`)
- Plain text files (`.txt`)
- Markdown files (`.md`)

### Multi-Model Benchmarking

Compare how different LLM models score document relevance and classify study quality:

- Side-by-side model comparison with agreement matrices
- Score distribution analysis across models
- Per-document score comparison with disagreement highlighting
- Cost and latency tracking per model
- Export results to CSV/JSON

A document a model could not score — its provider unreachable, or an answer
that could not be read — is counted in that model's **Failed** column and
shown as **failed** in the document details (hover for why). It is never
counted as a score: not in the mean, the distribution, or the agreement
between models, which compares only documents both models scored (**n/a**
when they scored none in common). The next benchmark of the same question
scores it again rather than reusing the failure. A model that scored nothing
shows **n/a** for its cost per document and its score distribution, rather
than $0.00 or 0%. A result saved before this was recorded says so: its scores
of 1 may include failures. If a saved result cannot be read back, the
Benchmark tab says the results **could not be loaded**; that is not the same
as having none, and running the benchmark again would repeat its cost.

The quality benchmark follows the same rules. A document a model could not
classify is counted in its **Failed** column and shown as **failed** in the
document details (hover for why), never as an "Unknown" design: "Unknown" is
an answer, a failure is none. Design and tier agreement compare only
documents both models classified. An answer that names no recognised study
design is counted as a failure, and one bad answer fails only that document,
not the whole benchmark. When the benchmark reuses the review's own
classifications, it reuses only those the same model made for the same task,
as the model gave them: never one the review could not make, one read from
PubMed's publication types, one a transparency check downgraded, or one
another model made. Reused classifications cost nothing in this run, so they
are left out of the cost and speed per assessment.

A model's answer counts as a score only when it gives a whole number from 1
to 5. An answer that declines to score, gives 0, or scores on another scale
(such as "10/10") is retried, and if it never gives a score it is counted as
a failure, not as a score of 1.

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
- **Risk Warnings**: Configure transparency thresholds for report warnings

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
bmll stats

# Validate configuration
bmll validate --verbose

# Show current configuration
bmll config --json

# Clear all stored data
bmll clear
```

`bmll config` prints your NCBI API key as `<redacted>` in both its plain and
`--json` forms, so the output is safe to paste into a bug report. That also
makes it a lossy view: it is a diagnostic, not a backup. Saving it back over
`~/.bmlibrarian_lite/config.json` would replace your key with the placeholder,
which BMLibrarian detects on load and ignores, falling back to the
`NCBI_API_KEY` environment variable.

## Data Storage

All data is stored locally in `~/.bmlibrarian_lite/`:

- **SQLite** (`metadata.db`): Document metadata, embeddings (via sqlite-vec), and session data
- **PDFs** (`pdfs/`): Downloaded PDF files
- **Fulltexts** (`fulltexts/`): Extracted full-text content

No external database server is required.

## Cross-Platform Apps

BMLibrarian Lite is also available as native mobile and desktop apps:

- **iOS**: Native SwiftUI app with iCloud sync, transparency analysis, parallel processing, and full-text access
- **macOS**: Native SwiftUI app with iCloud sync, transparency analysis, parallel processing, and full-text access
- **Android**: Native Kotlin/Compose app with transparency analysis, parallel processing, and full-text access

These apps share the same core algorithms (documented in `doc/cross_platform/`) but use platform-native storage and ML capabilities. iOS and macOS share code via the BioMedLit Swift package.

## Workflow Tips

### Best Practices for Systematic Reviews

1. **Start with a focused question**: Use PICO format (Population, Intervention, Comparison, Outcome)
2. **Review the generated query**: Check the Audit Trail to see the search query
3. **Adjust scoring threshold**: Higher threshold = more selective results
4. **Check quality badges**: Prioritize RCTs and systematic reviews for treatment questions
5. **Review transparency**: Check risk badges for funding and COI concerns
6. **Read LLM rationales**: Understand why documents were scored as they were

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

- **Issues**: [GitHub Issues](https://github.com/hherb/bmlibrarian_lite/issues)
- **Documentation**: See other files in this `doc/` directory
