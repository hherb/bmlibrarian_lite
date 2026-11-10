<p align="center">
  <img src="src/bmlibrarian_lite/resources/images/BML_icon_large.png" alt="BMLibrarian Lite" width="200">
</p>

# BMLibrarian Lite

Biomedical literature research and fact-checking with AI, without a database server.

Ask a clinical question or state a medical claim. BMLibrarian Lite searches PubMed and Europe PMC, leaves out retracted papers, scores every paper's relevance with an LLM, checks each study's transparency about funding, conflicts of interest, data and trial registration, extracts citable passages (from the full text when it can get one) and writes a referenced report. Everything it learns is kept on your own machine in SQLite.

It is the lightweight sibling of [BMLibrarian](https://github.com/hherb/bmlibrarian): no PostgreSQL, no local copy of PubMed, no GPU. It runs on an ordinary laptop with a cloud LLM (Anthropic Claude), or fully locally with [Ollama](https://ollama.com), and it also ships as native iOS, macOS and Android apps.

**One rule runs through all of it: a failure is never reported as an absence.** A database that could not be reached is not "no articles", a paper that could not be scored is not "irrelevant", a retraction source that did not answer is not "not retracted", and a statement the parser could not read is not "no conflict of interest". Every report opens with a notice when it rests on less than was asked for, and its methodology says what was missing and why.

## Platforms

| Platform | Technology | Storage | Location |
|----------|------------|---------|----------|
| **Desktop** (Windows, macOS, Linux) | Python 3.12+, PySide6 | SQLite + sqlite-vec | `src/bmlibrarian_lite/` |
| **iOS** and **macOS** | Swift, SwiftUI (one multiplatform project) | SwiftData | `ios/MedicalFactChecker/`, `Packages/BioMedLit/` |
| **Android** | Kotlin, Jetpack Compose | Room | `android/MedicalFactChecker/` |

The three platforms implement the same algorithms, pinned to shared contract files and corpora under [`doc/cross_platform/`](doc/cross_platform/) and checked in CI, so the same evidence gets the same verdict everywhere. The retraction rule comes from [bmlib](https://github.com/hherb/bmlib), the maintainer's shared biomedical-literature library.

## Features

### Desktop application

- **Systematic review** from a question to a report: query conversion, search, retraction screen, optional quality filter, relevance scoring (1–5, in parallel for cloud providers), transparency analysis, citation extraction and a referenced report with risk warnings.
- **Retraction checking** against a local copy of Retraction Watch's database, Crossref and PubMed's "Retracted Publication" label. Retracted papers are left out before scoring and listed in the report; papers under an expression of concern are kept with a caveat; a paper that could not be checked is marked **NOT CHECKED**, never "clear". Saved reports can be checked again later.
- **Smart search**: when fewer than three papers are relevant, the model proposes alternative queries, which are searched, screened and scored the same way.
- **Research Questions**: every past question can be loaded, re-run, re-scored, re-classified, re-analysed for transparency, or taken further with **Find More Evidence** (more of its own query, then a fresh smart-search round, scored into the same run and the report written again) and **Retry Full Text**.
- **Full-text discovery** through a ten-step chain: your library → Europe PMC XML → PMC's open-access bucket → Europe PMC PDF → Elsevier's Article API (with your key) → Unpaywall → OpenAlex → the publisher's DOI link → CORE's extracted text (with your key) → your own upload. Every PDF is checked against the article's title before it is used.
- **Bot-walled PDFs**: an open-access PDF behind a robot check is fetched later by a hidden built-in browser, or queued for you to open in a review window. A rescued PDF re-analyses its paper.
- **Upload Full Text** for any paper no source has (PDF, HTML, Markdown or text).
- **Citations from full text**, optionally, for papers scored 4 or higher. Long texts are read in overlapping windows and never cut.
- **Study transparency analysis**: funding disclosure (with funder classification), conflicts of interest (including industry intermediaries), data availability (including effective refusals) and trial registration, with ClinicalTrials.gov and Crossref lookups. Each High rating is explained by the rules that produced it; a rating made without the full text is marked as such and re-run once the full text arrives.
- **Quality assessment**: study-design classification and quality tiers, with a minimum-tier filter.
- **Audit trail**: what became of every document (accepted, rejected with the model's reason, not scored, could not be scored, left out as retracted), the queries and the citations, live during a run.
- **Document interrogation**: chat with a paper, a PDF or a text file, answered from its text.
- **Multi-model benchmarking** of relevance scoring and study classification: agreement matrices, score distributions, cost and latency.
- **MCP server** exposing the fact-checker to Claude Desktop, Claude Code or any [MCP](https://modelcontextprotocol.io/) client.
- **LLM providers**: Anthropic Claude or Ollama, chosen per task (query conversion, scoring, citations, report, Q&A and the rest).
- **Polite networking**: every request to PubMed, Europe PMC and the full-text services is paced per host and honours `Retry-After`.

### iOS, macOS and Android apps

A medical fact-checker built on the same workflow: enter a claim, get scored papers with transparency and retraction badges, and an evidence report with a verdict and clickable citations.

- **LLM providers**: Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama and any OpenAI-compatible endpoint, with live model lists. (On Android the Ollama preset reaches a server on the device; use Custom for one elsewhere.)
- **Retraction checking** with the same sources as the desktop, decided by bmlib's Rust core (through UniFFI); retracted papers are left out before scoring.
- **Study transparency analysis** with risk badges, detail views and explained ratings.
- **Smart search**, **Find More Evidence**, **New Question**, **Retry Full Text** and **Upload Full Text** on each paper card.
- **Full-text chain**: Europe PMC XML → PMC's open-access bucket → Europe PMC PDF → Elsevier (with your key) → Unpaywall → OpenAlex → CORE (with your key) → the DOI link, with title-checked PDFs, JATS rendering and optional full-text citations for papers scored 4–5.
- **Dual scoring**: on-device embedding similarity (Apple NLEmbedding; a Universal Sentence Encoder model on Android) alongside the LLM score, with HyDE.
- **Parallel scoring and citation extraction** with checkpointing, so an interrupted run resumes.
- **Hybrid search**: PubMed, Europe PMC, or both with deduplication.
- **Budget controls**: per-run and monthly spending limits with live cost tracking.
- **PDF export** of reports, and a **history** of past sessions.
- **iOS/macOS** (iOS 17, macOS 14 or later): optional iCloud sync, background processing on iOS, and a macOS layout for large screens. **Android**: 8.0 (API 26) or later, 64-bit devices.

## Quick start (desktop)

### Install

From source (recommended):

```bash
git clone https://github.com/hherb/bmlibrarian_lite.git
cd bmlibrarian_lite
uv venv && source .venv/bin/activate   # Windows: .venv\Scripts\activate
uv pip install -e .
```

From PyPI:

```bash
pip install bmlibrarian-lite
```

### Configure

Pick an LLM:

```bash
export ANTHROPIC_API_KEY="your-api-key"          # Anthropic Claude (recommended)
# or run locally:
ollama pull llama3.2 && export OLLAMA_HOST="http://localhost:11434"
```

Tell NCBI who you are (recommended):

```bash
export NCBI_EMAIL="your@email.com"
export NCBI_API_KEY="your-ncbi-key"   # optional, raises PubMed's rate limit
```

All of these can also be set in the GUI under **Settings**, or written as `NAME=value` lines in `~/.bmlibrarian_lite/.env`. Optional keys for more full-text sources (Unpaywall email, CORE, Elsevier, OpenAthens) are under **Settings → Full Text**.

### Run

```bash
bmlibrarian-lite-gui     # the GUI
bmll                     # the same GUI: bmll with no command launches it
```

The main window's tabs are **Research Questions**, **Systematic Review**, **Audit Trail**, **Report**, **Document Interrogation**, **Benchmark Results** and **Quality Benchmark**. Reports are saved automatically to `~/bmlibrarian_reports/LITE/`, with an audit record beside each one.

### CLI

```bash
bmll stats [--json]          # storage statistics
bmll validate                # check the configuration (bmll -v validate for detail)
bmll config [--json]         # show the configuration
bmll retractions-update      # refresh the local Retraction Watch copy
bmll keep-pdf <file>         # keep a PDF the title check set aside
bmll clear [-f]              # delete all stored data
bmll --version
```

### MCP server

```bash
bmlibrarian-lite-mcp
```

It offers four tools, using the desktop's configuration, library and retraction checking:

- `fact_check_claim`: search, score, cite and report on a claim, with progress notifications
- `search_literature`: search PubMed and/or Europe PMC
- `get_document_fulltext`: a paper's full text as Markdown, by PMID, DOI or PMC ID
- `ask_document`: a question about the paper loaded last

Client setup (Claude Desktop, Claude Code, `uv tool install`) is in [HOWTO_MCP_SERVER.md](HOWTO_MCP_SERVER.md).

## Building the apps

**iOS and macOS** (one multiplatform project): open `ios/MedicalFactChecker/MedicalFactChecker.xcodeproj` in Xcode, set your signing team, choose an iPhone, iPad or **My Mac** destination and run. From the command line:

```bash
xcodebuild -project ios/MedicalFactChecker/MedicalFactChecker.xcodeproj \
           -scheme MedicalFactChecker -destination 'platform=macOS' build
swift test --package-path ios/MedicalFactChecker     # app tests
swift test --package-path Packages/BioMedLit         # shared package tests
```

**Android**: open `android/MedicalFactChecker` in Android Studio and run, or:

```bash
cd android/MedicalFactChecker
./gradlew assembleDebug
./gradlew testDebugUnitTest
```

LLM provider, API keys, NCBI email and key, search provider, budgets and full-text keys are set in each app's Settings screen. API keys are kept in the Keychain (Apple) or EncryptedSharedPreferences (Android).

## Configuration

Desktop settings live in `~/.bmlibrarian_lite/config.json` and are easiest to change in the GUI. Each task can use its own provider and model:

```json
{
  "models": {
    "default_provider": "anthropic",
    "default_model": "claude-sonnet-4-6",
    "tasks": {
      "document_scoring": { "provider": "ollama", "model": "llama3.2" },
      "citation_extraction": { "provider": "ollama", "model": "llama3.2", "context_window": 32768 }
    }
  },
  "pubmed": { "email": "your@email.com" },
  "search": { "search_provider": "pubmed", "max_results": 100 }
}
```

Task IDs include `query_conversion`, `document_scoring`, `citation_extraction`, `report_generation`, `query_expansion`, `document_qa`, `document_summary`, `study_classification` and `quality_assessment`. For Ollama, set `context_window` for long documents (it is sent as `num_ctx`). The full reference is in the [user guide](doc/user/guide.md#settings).

### Where data is kept

| Path | Contents |
|------|----------|
| `~/.bmlibrarian_lite/metadata.db` | Documents, embeddings, runs, scores, citations, transparency and retraction checks, uploads |
| `~/.bmlibrarian_lite/retraction_watch.db` | Local copy of Retraction Watch's database (refreshed when over five weeks old) |
| `~/.bmlibrarian_lite/config.json`, `.env` | Settings and optional environment variables |
| `~/knowledgebase/pdf/`, `~/knowledgebase/fulltext/` | Downloaded PDFs and full texts as Markdown |
| `~/bmlibrarian_reports/LITE/` | Reports and their audit records |

The embedding model (BAAI/bge-small-en-v1.5, about 100 MB) is downloaded on first use.

## BMLibrarian and BMLibrarian Lite

[BMLibrarian](https://github.com/hherb/bmlibrarian) is a researcher's workbench built around a local PostgreSQL mirror of the literature: it works offline once the data is imported, and offers analyses Lite does not (peer-review-style paper assessment, PICO, PRISMA 2020, counterfactual search, a writing editor). Lite asks the literature databases live, so it needs an internet connection but no database server, no bulk download and no GPU, and it adds what a bedside or mobile fact-check needs: retraction screening, a full-text chain, native apps and an MCP server.

| | BMLibrarian | Lite desktop | Lite iOS / macOS | Lite Android |
|---|---|---|---|---|
| **Focus** | Research workbench: systematic review, paper review, fact-checking, writing | Systematic review and fact-checking | Fact-checking | Fact-checking |
| **Where the literature comes from** | Local mirror: PubMed, medRxiv, PMC/Europe PMC bulk, ClinicalTrials.gov, MeSH | Live: PubMed E-utilities, Europe PMC | Live: PubMed, Europe PMC | Live: PubMed, Europe PMC |
| **Works offline** | Yes, after import | No (searches are live; results are kept locally) | No | No |
| **Database** | PostgreSQL + pgvector | SQLite + sqlite-vec | SwiftData | Room (SQLite) |
| **Setup** | PostgreSQL and bulk imports (a one-click installer is in development) | `pip` / `uv` install | Xcode build | Android Studio build |
| **Hardware** | Local LLMs want a GPU or plenty of fast memory | Any laptop | iOS 17+, macOS 14+ | Android 8.0+, 64-bit |
| **LLMs** | Local Ollama first; cloud models via bmlib | Anthropic or Ollama, per task | Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, custom | Anthropic, OpenAI, DeepSeek, Groq, Mistral, Ollama, custom |
| **Embeddings** | Ollama (snowflake-arctic-embed2, nomic-embed-text) | FastEmbed on CPU (bge-small-en-v1.5) | Apple NLEmbedding, on device | Universal Sentence Encoder (MediaPipe), on device |
| **Search** | Semantic, keyword, hybrid, HyDE, MeSH expansion, counterfactual | LLM-built query; smart search (alternative queries) | LLM-built query, HyDE, smart search | LLM-built query, HyDE, smart search |
| **Retracted papers** | Retraction Watch imported for transparency; "retracted" titles filtered | Left out before scoring (Retraction Watch, Crossref, PubMed label; bmlib's rule) | Left out before scoring (Retraction Watch, Crossref; bmlib's Rust core) | Same as iOS / macOS |
| **Transparency analysis** | Funding, COI, data, registration, author contributions | Funding, COI, data, registration; explained ratings | Same, with detail views | Same |
| **Quality assessment** | Study assessment, paper weight, PICO, PRISMA 2020, GRADE | Study design and quality tiers | — | — |
| **Full text** | Bulk PMC/Europe PMC import, PDF discovery, OpenAthens | Ten-step chain, bot-wall browser, uploads, OpenAthens | Chain and uploads | Chain and uploads |
| **Citations from full text** | No (citations quote abstracts) | Optional (score ≥ 4), windowed, never cut | Optional | Optional |
| **Fact-checking** | Statement fact-checker, PaperChecker for abstracts | Systematic review; MCP `fact_check_claim` | Claim → verdict report | Claim → verdict report |
| **Document Q&A** | Yes | Yes | — | — |
| **Audit** | Audit trail and multi-reviewer validation GUI | Audit trail of every document | Per-session history | Per-session history |
| **Model benchmarking** | Yes | Yes (relevance and classification) | — | — |
| **MCP server** | — | Yes | — | — |
| **Report export** | Markdown, PDF, JSON | Markdown | PDF | PDF |
| **Budget limits** | — | Token and cost display | Per-run and monthly | Per-run and monthly |
| **Sync** | — | — | iCloud (optional) | — |
| **Extensibility** | Qt plugin tabs and labs | — | — | — |

## Documentation

- [User guide](doc/user/guide.md): the desktop application in full, from installation to troubleshooting
- [Transparency on iOS/macOS](doc/ios/user/transparency.md)
- [HOWTO_MCP_SERVER.md](HOWTO_MCP_SERVER.md): the MCP server in each client
- [CHANGELOG.md](CHANGELOG.md): release history
- [Developer guide](doc/developer/guide.md): architecture, code style, release process
- [Retraction checking](doc/developer/retraction_checking.md), [browser rescue](doc/developer/browser_rescue.md), [PubMed and Europe PMC](doc/developer/europepmc_and_pubmed.md)
- [Cross-platform specifications](doc/cross_platform/): full-text retrieval, hybrid search, JATS parsing, parallel processing, request pacing, failure reporting, and the parity contracts
- [ROADMAP.md](ROADMAP.md): planned work
- [`doc/llm/`](doc/llm/): coding standards (`golden_rules.md` for Python, `general_golden_rules.md` for Swift/Kotlin) and the database schema

## Development

```bash
uv venv && source .venv/bin/activate && uv pip install -e ".[dev]"
pytest tests/
ruff check .
mypy src/
```

CI runs the Python, Swift and Android suites and the cross-platform parity guards on every pull request.

## Related projects

- [BMLibrarian](https://github.com/hherb/bmlibrarian): the full workbench, with a local literature database
- [bmlib](https://github.com/hherb/bmlib): the shared library behind both (LLM providers, publication ingestion, transparency and retraction rules)
- [biasbuster](https://github.com/hherb/biasbuster): datasets and fine-tuning for detecting bias in biomedical abstracts
- [BioMedicalNews](https://github.com/hherb/BioMedicalNews): curated digests of new preprints and papers

## License

Copyright (C) 2024-2026 Dr Horst Herb

AGPL-3.0-or-later. See [LICENSE](LICENSE).

## Support

- [GitHub Issues](https://github.com/hherb/bmlibrarian_lite/issues)
- The [`doc/`](doc/) directory
