# Medical Fact Checker - iOS App

A native iOS app (iPhone/iPad) for medical fact-checking using biomedical literature and AI-powered evidence synthesis.

## Features

### Literature Search
- **Multi-provider search**: Search PubMed, Europe PMC, or both simultaneously with intelligent deduplication
- **Europe PMC integration**: Access to full-text articles, preprints from 34+ servers (bioRxiv, medRxiv, etc.)
- **PubMed integration**: NCBI E-utilities API for comprehensive biomedical literature
- **Query translation**: Automatic syntax translation between search providers
- **Preprint filtering**: Optional exclusion of preprints when using Europe PMC

### Full-Text Access
- **Multi-source retrieval**: Automatic fallback chain for full-text content:
  1. Europe PMC XML (converted to readable markdown)
  2. Unpaywall PDF (open access)
  3. DOI resolution (publisher website)
- **JATS XML parsing**: Converts PubMed Central/Europe PMC XML to formatted markdown
- **PDF viewer**: Built-in PDF display with download and caching
- **Source badges**: Visual indicators showing content source

### AI-Powered Analysis
- **Multiple LLM providers**: Anthropic (Claude), OpenAI, DeepSeek, Groq, Mistral, Ollama, and custom endpoints
- **Dynamic model fetching**: Automatically fetches available models from provider APIs
- **Dual scoring system**: LLM relevance scoring plus optional on-device NLEmbedding semantic similarity
- **HyDE scoring**: Hypothetical Document Embedding for improved semantic matching
- **Parallel processing**: Concurrent document scoring and citation extraction with automatic concurrency detection
- **Checkpointing**: Resumable workflows that save progress per-document, surviving interruptions
- **Citation extraction**: Extracts key passages with clickable references
- **Evidence synthesis**: Generates verdicts with supporting citations

### Study Transparency Analysis
- **Funding disclosure**: Automatic detection of funding source declarations
- **Conflict of interest**: COI statement analysis
- **Data availability**: Assessment of data sharing practices
- **Trial registration**: Verification against ClinicalTrials.gov
- **Risk badges**: Visual indicators on document cards for transparency concerns
- **Report integration**: Transparency findings feed into risk warnings in generated reports

### Cloud Sync
- **iCloud integration**: Optional CloudKit sync across devices (opt-in, disabled by default)
- **Privacy-first**: Data stays local unless you explicitly enable sync
- **SwiftData persistence**: All sessions, documents, and reports stored locally

### Export & Sharing
- **PDF export**: Generate PDF reports with configurable paper size (A4/Letter)
- **Share sheet**: Native sharing of reports and evidence
- **History browser**: Browse, search, and revisit past fact-check sessions

### Cost Management
- **Per-run budget**: Set maximum cost per fact-check
- **Monthly budget**: Cap monthly spending across all sessions
- **Real-time tracking**: View token usage and costs during workflow
- **Model pricing**: Built-in pricing data for all supported models

## Requirements

- iOS 17.0+ / macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- An LLM API key (or local Ollama server)

## Supported LLM Providers

| Provider | Models (January 2026) | API Key Required |
|----------|----------------------|------------------|
| Anthropic | Claude Sonnet 4.5, Haiku 4.5, Opus 4.5 | Yes |
| OpenAI | GPT-5.2, o4-mini, o3, GPT-4o | Yes |
| DeepSeek | DeepSeek V3.2 (Chat/Reasoner) | Yes |
| Groq | Llama 4 Maverick/Scout, Llama 3.3 | Yes |
| Mistral | Mistral Large 3, Medium 3.1, Codestral | Yes |
| Ollama | Any locally installed model | No |
| Custom | Any OpenAI-compatible endpoint | Configurable |

Models are fetched dynamically from provider APIs when an API key is configured. Fallback models are used when API fetching fails.

## Setup

1. Open the project in Xcode
2. Build and run on your device or simulator
3. Accept the disclaimer on first launch
4. Go to Settings and configure:
   - **Provider**: Select your LLM provider (default: Anthropic)
   - **Model**: Select from available models (fetched from API or fallback list)
   - **API Key**: Your API key (stored securely in Keychain)
5. Optionally configure budget limits and search settings

## Usage

1. Enter a medical claim or question in the main view
2. Tap "Check Evidence"
3. The app will:
   - Convert your claim to an optimized search query
   - Fetch documents from PubMed and/or Europe PMC (based on settings)
   - Score each document for relevance (LLM + optional embedding)
   - Ask to fetch more if not enough relevant docs found
   - Extract citations from relevant documents
   - Generate an evidence report with verdict
4. View the report with clickable document references
5. Tap any document to view full text (when available)
6. Export to PDF or share

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| Provider | Anthropic | LLM API provider |
| Model | Claude Sonnet 4.5 | Model for inference |
| Search Provider | PubMed | PubMed, Europe PMC, or Both |
| Include Preprints | Off | Include preprints (Europe PMC only) |
| Embedding Scoring | Off | Enable on-device NLEmbedding scoring |
| Batch Size | 20 | Documents to fetch per batch |
| Min Relevant Docs | 5 | Minimum relevant docs before prompting for more |
| Min Score Threshold | 3 | Score threshold for "relevant" (1-5) |
| Per-Run Budget | $1.00 | Maximum cost per fact-check |
| Monthly Budget | $10.00 | Maximum monthly spending |
| iCloud Sync | Off | Sync data across devices via CloudKit |

## Architecture

```
Sources/
├── App/                       # App entry point and main views
│   ├── MedicalFactCheckerApp  # URL handling, CloudKit init, disclaimer
│   └── ContentView            # Tab-based navigation
├── Models/                    # SwiftData models and enums
│   ├── FactCheckSession       # Main workflow session (CloudKit-ready)
│   ├── Document               # Article with dual scoring, full-text state
│   ├── Citation               # Extracted passage
│   ├── EvidenceReport         # Final report
│   ├── UsageRecord            # Token/cost tracking
│   ├── AppSettings            # User configuration
│   ├── LLMProvider            # Provider presets with models
│   ├── SearchProvider         # PubMed, Europe PMC, or Both
│   └── FullTextSource         # Source tracking for full-text content
├── Services/                  # Business logic
│   ├── LLMService             # OpenAI-compatible API client with retry
│   ├── PubMedService          # PubMed E-utilities client (via BioMedLit)
│   ├── EuropePMCService       # Europe PMC REST API client (via BioMedLit)
│   ├── FullTextService        # Multi-source full-text retrieval (via BioMedLit)
│   ├── EmbeddingService       # NLEmbedding scoring with HyDE
│   ├── ParallelScoringService # Concurrent document scoring
│   ├── ParallelCitationService # Concurrent citation extraction
│   ├── CheckpointedScoringService # Resumable scoring with checkpoints
│   ├── CheckpointManager      # Per-document checkpoint persistence
│   ├── ErrorPersistenceManager # Error queue persistence
│   ├── ModelFetchService      # Dynamic model fetching from APIs
│   ├── BackgroundTaskManager  # Background task support
│   ├── CloudKitConfiguration  # iCloud sync management
│   └── FactCheckWorkflow      # Workflow orchestrator
├── Views/                     # SwiftUI views
│   ├── FactCheck/             # Main input view, scored documents
│   ├── FullText/              # Full-text viewer with source badges
│   ├── Report/                # Report display with markdown rendering
│   ├── History/               # Past sessions
│   ├── Settings/              # Configuration with model pricing
│   ├── Onboarding/            # Disclaimer view
│   └── Components/            # Shared components
│       ├── TransparencyDetailView    # Transparency analysis details
│       ├── TransparencyRiskBadge     # Risk indicator badges
│       ├── TransparencySummarySection # Transparency summary
│       ├── ErrorQueueView            # Collapsible error display
│       ├── ProcessingProgressView    # Per-document progress
│       └── SortingControlsView       # Document sort options
└── Utilities/                 # Helpers
    ├── KeychainHelper         # Secure credential storage
    ├── CostCalculator         # Token cost estimation
    ├── ResponseParser         # LLM response parsing
    ├── JATSXMLParser          # Europe PMC XML to markdown
    ├── SearchResultMerger     # Multi-provider deduplication
    └── PDFExporter            # PDF generation
```

## Scoring Methods

### LLM Scoring
The primary scoring method uses your configured LLM to evaluate document relevance on a 1-5 scale based on the abstract and medical claim.

### Embedding Scoring (Optional)
When enabled, documents are also scored using Apple's NLEmbedding for on-device semantic similarity:
- Uses HyDE (Hypothetical Document Embedding) to generate a synthetic ideal abstract
- Computes cosine similarity between the HyDE abstract and actual document abstracts
- Normalizes scores to 1-5 scale for comparison with LLM scores
- No API cost - runs entirely on device

## Background Processing

iOS has strict background execution limits. The app handles this by:

1. **Chunked operations**: Saves progress after each document
2. **Resumable workflow**: Can resume from any step if interrupted
3. **User decision points**: Pauses to ask before fetching more documents
4. **Clear progress UI**: Keeps user engaged (foreground) during long operations
5. **Retry logic**: Automatic retry with exponential backoff for transient API failures

## Cost Estimation

Typical fact-check costs (January 2026 pricing):

| Model | Estimated Cost |
|-------|---------------|
| Claude Sonnet 4.5 | $0.01 - $0.03 |
| GPT-4o Mini | $0.001 - $0.003 |
| DeepSeek V3.2 | $0.002 - $0.005 |
| Llama 4 Scout (Groq) | $0.001 - $0.003 |

View current pricing for all models in Settings > View Model Pricing.

## License

Copyright (C) 2024-2026 Dr Horst Herb

AGPL-3.0 License - see main project LICENSE file for details.
