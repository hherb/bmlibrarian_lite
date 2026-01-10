# Medical Fact Checker - iOS App

A lightweight iOS app (iPhone/iPad) that fact-checks medical claims using PubMed literature and an OpenAI-compatible LLM API.

## Features

- **Medical claim fact-checking**: Enter a medical statement or question and get an evidence-based report
- **PubMed integration**: Searches medical literature via NCBI E-utilities API
- **Batch pagination**: Fetches documents in configurable batches, with user prompts to fetch more if needed
- **Relevance scoring**: Uses LLM to score document relevance (1-5 scale)
- **Citation extraction**: Extracts key passages from relevant documents
- **Evidence synthesis**: Generates verdicts with supporting citations
- **Cost tracking**: Per-run and monthly budget limits to avoid surprise costs
- **History**: Browse and share past fact-check reports

## Requirements

- iOS 17.0+ / macOS 14.0+
- Xcode 15.0+
- Swift 5.9+
- An OpenAI-compatible API key (OpenAI, Anthropic, local LLM server, etc.)

## Setup

1. Open the project in Xcode
2. Build and run on your device or simulator
3. Go to Settings and configure:
   - **Base URL**: Your LLM API endpoint (default: `https://api.openai.com/v1`)
   - **Model**: Model name (default: `gpt-4o-mini`)
   - **API Key**: Your API key (stored securely in Keychain)
4. Optionally configure budget limits and search settings

## Usage

1. Enter a medical claim or question in the main view
2. Tap "Check Evidence"
3. The app will:
   - Convert your claim to a PubMed search query
   - Fetch documents from PubMed
   - Score each document for relevance
   - Ask to fetch more if not enough relevant docs found
   - Extract citations from relevant documents
   - Generate an evidence report with verdict
4. View and share the report

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| Batch Size | 20 | Documents to fetch per PubMed batch |
| Min Relevant Docs | 5 | Minimum relevant docs before prompting for more |
| Min Score Threshold | 3 | Score threshold for "relevant" (1-5) |
| Per-Run Budget | $1.00 | Maximum cost per fact-check |
| Monthly Budget | $10.00 | Maximum monthly spending |

## Architecture

```
Sources/
├── App/                    # App entry point and main views
├── Models/                 # SwiftData models and enums
│   ├── FactCheckSession   # Main workflow session
│   ├── Document           # PubMed article with scoring
│   ├── Citation           # Extracted passage
│   ├── EvidenceReport     # Final report
│   ├── UsageRecord        # Token/cost tracking
│   └── AppSettings        # User configuration
├── Services/              # Business logic
│   ├── LLMService         # OpenAI-compatible API client
│   ├── PubMedService      # PubMed E-utilities client
│   └── FactCheckWorkflow  # Workflow orchestrator
├── Views/                 # SwiftUI views
│   ├── FactCheck/         # Main input view
│   ├── Report/            # Report display
│   ├── History/           # Past sessions
│   └── Settings/          # Configuration
└── Utilities/             # Helpers
    ├── KeychainHelper     # Secure storage
    └── CostCalculator     # Token cost estimation
```

## Background Processing

iOS has strict background execution limits. The app handles this by:

1. **Chunked operations**: Saves progress after each document
2. **Resumable workflow**: Can resume from any step if interrupted
3. **User decision points**: Pauses to ask before fetching more documents
4. **Clear progress UI**: Keeps user engaged (foreground) during long operations

## Cost Estimation

Typical fact-check costs (depends on model):

| Model | Estimated Cost |
|-------|---------------|
| gpt-4o-mini | $0.001 - $0.003 |
| gpt-4o | $0.02 - $0.05 |
| claude-3-haiku | $0.002 - $0.005 |

## License

See main project LICENSE file.
