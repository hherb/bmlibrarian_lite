# Medical Fact Checker - iOS App

A lightweight iOS app (iPhone/iPad) that fact-checks medical claims using PubMed literature and an OpenAI-compatible LLM API.

## Features

- **Medical claim fact-checking**: Enter a medical statement or question and get an evidence-based report
- **PubMed integration**: Searches medical literature via NCBI E-utilities API
- **Multiple LLM providers**: Pre-configured support for Anthropic (Claude), OpenAI, DeepSeek, Groq, Mistral, and Ollama
- **Dynamic model fetching**: Automatically fetches available models from provider APIs
- **Dual scoring system**: LLM relevance scoring plus optional on-device NLEmbedding semantic similarity
- **HyDE scoring**: Hypothetical Document Embedding for improved semantic matching
- **Citation extraction**: Extracts key passages from relevant documents with clickable references
- **Evidence synthesis**: Generates verdicts with supporting citations and model info footnote
- **PDF export**: Export reports to PDF with configurable paper size (A4/Letter)
- **Cost tracking**: Per-run and monthly budget limits with real-time cost display
- **History**: Browse, share, and export past fact-check reports
- **Disclaimer**: First-launch disclaimer explaining AI limitations

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
   - Convert your claim to a PubMed search query
   - Fetch documents from PubMed
   - Score each document for relevance (LLM + optional embedding)
   - Ask to fetch more if not enough relevant docs found
   - Extract citations from relevant documents
   - Generate an evidence report with verdict
4. View the report with clickable document references
5. Export to PDF or share

## Configuration Options

| Setting | Default | Description |
|---------|---------|-------------|
| Provider | Anthropic | LLM API provider |
| Model | Claude Sonnet 4.5 | Model for inference |
| Embedding Scoring | Off | Enable on-device NLEmbedding scoring |
| Batch Size | 20 | Documents to fetch per PubMed batch |
| Min Relevant Docs | 5 | Minimum relevant docs before prompting for more |
| Min Score Threshold | 3 | Score threshold for "relevant" (1-5) |
| Per-Run Budget | $1.00 | Maximum cost per fact-check |
| Monthly Budget | $10.00 | Maximum monthly spending |

## Architecture

```
Sources/
├── App/                    # App entry point and main views
│   ├── MedicalFactCheckerApp  # URL handling, disclaimer
│   └── ContentView            # Tab-based navigation
├── Models/                 # SwiftData models and enums
│   ├── FactCheckSession   # Main workflow session
│   ├── Document           # PubMed article with dual scoring
│   ├── Citation           # Extracted passage
│   ├── EvidenceReport     # Final report
│   ├── UsageRecord        # Token/cost tracking
│   ├── AppSettings        # User configuration
│   └── LLMProvider        # Provider presets with models
├── Services/              # Business logic
│   ├── LLMService         # OpenAI-compatible API client with retry
│   ├── PubMedService      # PubMed E-utilities client
│   ├── EmbeddingService   # NLEmbedding scoring with HyDE
│   ├── ModelFetchService  # Dynamic model fetching from APIs
│   └── FactCheckWorkflow  # Workflow orchestrator
├── Views/                 # SwiftUI views
│   ├── FactCheck/         # Main input view, scored documents
│   ├── Report/            # Report display with markdown rendering
│   ├── History/           # Past sessions
│   ├── Settings/          # Configuration with model pricing
│   └── Onboarding/        # Disclaimer view
└── Utilities/             # Helpers
    ├── KeychainHelper     # Secure storage
    ├── CostCalculator     # Token cost estimation
    ├── ResponseParser     # LLM response parsing
    └── PDFExporter        # PDF generation
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

See main project LICENSE file.
