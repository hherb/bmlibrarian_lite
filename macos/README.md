# MedicalFactCheckerMac

A native macOS application for medical fact-checking using biomedical literature and AI-powered evidence synthesis.

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
- **Dual scoring system**: LLM relevance scoring plus on-device NLEmbedding semantic similarity
- **HyDE scoring**: Hypothetical Document Embedding for improved semantic matching
- **Citation extraction**: Extracts key passages with clickable references
- **Evidence synthesis**: Generates verdicts with supporting citations

### Cloud Sync
- **iCloud integration**: Optional CloudKit sync across devices (opt-in, disabled by default)
- **Privacy-first**: Data stays local unless you explicitly enable sync
- **SwiftData persistence**: All sessions, documents, and reports stored locally
- **Requires restart**: App restart needed after changing sync settings

### Export & Sharing
- **PDF export**: Generate PDF reports
- **Native sharing**: macOS share sheet integration
- **History browser**: Browse, search, and revisit past fact-check sessions

### Cost Management
- **Per-run budget**: Set maximum cost per fact-check
- **Monthly budget**: Cap monthly spending across all sessions
- **Real-time tracking**: View token usage and costs during workflow
- **Model pricing**: Built-in pricing data for all supported models

## Requirements

- macOS 14.0+
- Xcode 15.0+
- Swift 5.9+

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

## Building

1. Open `MedicalFactCheckerMac.xcodeproj` in Xcode
2. Select the `MedicalFactCheckerMac` scheme
3. Build and run (Cmd+R)

Alternatively, build from the command line:

```bash
cd macos/MedicalFactCheckerMac
xcodebuild -project MedicalFactCheckerMac.xcodeproj \
           -scheme MedicalFactCheckerMac \
           -configuration Debug \
           build
```

## Setup

1. Build and run the app
2. Complete the onboarding wizard
3. Go to Settings and configure:
   - **Provider**: Select your LLM provider (default: Anthropic)
   - **Model**: Select from available models
   - **API Key**: Your API key (stored securely in Keychain)
4. Optionally configure:
   - Search provider (PubMed, Europe PMC, or Both)
   - Budget limits
   - iCloud sync

## Usage

1. Enter a medical claim or question in the Fact Check tab
2. Click "Check Evidence"
3. The app will:
   - Convert your claim to an optimized search query
   - Fetch documents from PubMed and/or Europe PMC
   - Score each document for relevance
   - Extract citations from relevant documents
   - Generate an evidence report with verdict
4. View the report with clickable document references
5. Click any document to view full text (when available)
6. Export to PDF or share

## Architecture

```
macos/MedicalFactCheckerMac/
├── MedicalFactCheckerMac.xcodeproj/
├── MedicalFactCheckerMac.entitlements   # CloudKit capability
└── Sources/
    ├── App/
    │   ├── MedicalFactCheckerMacApp.swift   # App entry, CloudKit init
    │   └── MacContentView.swift              # Tab-based navigation
    ├── Models/                               # SwiftData models
    │   ├── FactCheckSession.swift           # Workflow session (CloudKit-ready)
    │   ├── Document.swift                   # Article with dual scoring
    │   ├── Citation.swift                   # Extracted passage
    │   ├── EvidenceReport.swift             # Generated report
    │   ├── UsageRecord.swift                # Token/cost tracking
    │   ├── AppSettings.swift                # User configuration
    │   ├── LLMProvider.swift                # Provider presets
    │   ├── SearchProvider.swift             # PubMed/Europe PMC/Both
    │   └── FullTextSource.swift             # Content source tracking
    ├── Services/
    │   ├── LLMService.swift                 # OpenAI-compatible API client
    │   ├── PubMedService.swift              # NCBI E-utilities client
    │   ├── EuropePMCService.swift           # Europe PMC REST API
    │   ├── FullTextService.swift            # Multi-source full-text retrieval
    │   ├── EmbeddingService.swift           # NLEmbedding with HyDE
    │   ├── ModelFetchService.swift          # Dynamic model fetching
    │   ├── CloudKitConfiguration.swift      # iCloud sync management
    │   ├── SearchServiceFactory.swift       # Multi-provider routing
    │   └── FactCheckWorkflow.swift          # Workflow orchestrator
    ├── Views/
    │   ├── FactCheck/                       # Main workflow interface
    │   ├── FullText/                        # Document viewer
    │   ├── Report/                          # Evidence report display
    │   ├── History/                         # Past sessions
    │   ├── Settings/                        # Configuration
    │   ├── Onboarding/                      # Setup wizard
    │   └── Help/                            # Documentation
    └── Utilities/
        ├── KeychainHelper.swift             # Secure credential storage
        ├── CostCalculator.swift             # Token cost estimation
        ├── JATSXMLParser.swift              # Europe PMC XML parsing
        ├── SearchResultMerger.swift         # Multi-provider deduplication
        └── Logger.swift                     # Structured logging
```

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| Provider | Anthropic | LLM API provider |
| Model | Claude Sonnet 4.5 | Model for inference |
| Search Provider | PubMed | PubMed, Europe PMC, or Both |
| Include Preprints | Off | Include preprints (Europe PMC only) |
| Embedding Scoring | On | Enable NLEmbedding scoring |
| Batch Size | 20 | Documents to fetch per batch |
| Min Relevant Docs | 5 | Minimum relevant docs before prompting |
| Min Score Threshold | 3 | Score threshold for "relevant" (1-5) |
| Per-Run Budget | $1.00 | Maximum cost per fact-check |
| Monthly Budget | $10.00 | Maximum monthly spending |
| iCloud Sync | Off | Sync data across devices via CloudKit |

## Related

- [iOS App](../ios/MedicalFactChecker/) - Mobile version for iPhone/iPad
- [Python Desktop](../) - Cross-platform Python/Qt version
