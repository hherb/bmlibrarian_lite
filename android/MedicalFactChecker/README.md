# Medical Fact Checker - Android

An Android application for evidence-based medical claim verification using peer-reviewed literature from PubMed and Europe PMC.

## Overview

Medical Fact Checker helps users verify medical claims by:

1. Converting natural language claims into PubMed search queries
2. Searching medical literature databases (PubMed, Europe PMC)
3. Scoring document relevance using LLM-powered analysis
4. Extracting key citation passages
5. Generating evidence reports with verdicts

The app supports multiple LLM providers including Anthropic Claude, OpenAI, DeepSeek, Groq, Mistral, and local Ollama instances.

## Features

- **Multi-Provider LLM Support**: Choose from Anthropic, OpenAI, DeepSeek, Groq, Mistral, or run locally with Ollama
- **Dual Search Providers**: Search PubMed, Europe PMC, or both simultaneously
- **Smart Document Scoring**: LLM-powered relevance scoring with rationale
- **Study Transparency Analysis**: Automatic analysis of funding disclosure, conflict of interest, data availability, and trial registration with risk badges on document cards
- **Full-Text Access**: Multi-source retrieval (Europe PMC XML, Unpaywall PDF, DOI) with JATS XML rendering
- **Parallel Processing**: Concurrent document scoring and citation extraction
- **Evidence Reports**: Generated markdown reports with verdicts, citations, and risk warnings
- **Budget Management**: Per-run and monthly spending limits to control API costs
- **Session History**: Browse and revisit past fact-check sessions
- **PDF Export**: Export evidence reports as PDF documents
- **Offline Storage**: All sessions stored locally using Room database
- **Secure Credentials**: API keys stored in Android's Encrypted SharedPreferences

## Requirements

- **Android**: API 26+ (Android 8.0 Oreo or later)
- **Build Tools**: Android Studio Hedgehog (2023.1.1) or later
- **JDK**: Java 17
- **Gradle**: 8.x (wrapper included)

## Installation

### From Source

1. Clone the repository:
   ```bash
   git clone https://github.com/hherb/bmlibrarian_lite.git
   cd bmlibrarian_lite/android/MedicalFactChecker
   ```

2. Open in Android Studio:
   - File → Open → Select the `MedicalFactChecker` directory
   - Wait for Gradle sync to complete

3. Build and run:
   - Select a device/emulator
   - Click Run (▶) or press `Shift+F10`

### APK Installation

1. Download the latest release APK
2. Enable "Install from unknown sources" in device settings
3. Open the APK file to install

## Configuration

### API Keys

The app requires an API key for your chosen LLM provider:

| Provider | Get API Key |
|----------|-------------|
| Anthropic | https://console.anthropic.com/ |
| OpenAI | https://platform.openai.com/api-keys |
| DeepSeek | https://platform.deepseek.com/ |
| Groq | https://console.groq.com/ |
| Mistral | https://console.mistral.ai/ |
| Ollama | No API key needed (local) |

Enter your API key in **Settings → LLM Provider → API Key**.

### Budget Limits

Configure spending limits to control API costs:

- **Max per run**: Maximum cost for a single fact-check (default: $0.50)
- **Monthly limit**: Maximum monthly spending (default: $10.00)

### PubMed Settings

For higher rate limits with PubMed, optionally provide your email in **Settings → PubMed Settings**.

## Usage

### Checking a Claim

1. Navigate to the **Check** tab
2. Enter a medical claim (e.g., "Aspirin reduces heart attack risk")
3. Tap **Check Claim**
4. Wait for the analysis to complete
5. Review the verdict and evidence report

### Understanding Verdicts

| Verdict | Meaning |
|---------|---------|
| **Supported** | Strong evidence supports the claim |
| **Likely Supported** | Evidence tends to support the claim |
| **Unclear** | Evidence is mixed or insufficient |
| **Likely Refuted** | Evidence tends to refute the claim |
| **Refuted** | Strong evidence refutes the claim |

### Exporting Reports

1. Navigate to the **Report** tab after completing a fact-check
2. Tap **Export PDF** or **Share**
3. Select paper size (A4 or Letter) for PDF export

## Architecture

The app follows a clean architecture pattern with MVVM presentation layer:

```
app/
├── data/                    # Data layer
│   ├── local/               # Room database, DAOs, entities, converters
│   ├── remote/              # API clients
│   │   ├── pubmed/          # PubMed E-utilities client
│   │   ├── europepmc/       # Europe PMC REST API client
│   │   ├── fulltext/        # Full-text retrieval service
│   │   └── llm/             # Multi-provider LLM client
│   └── repository/          # Repository implementations
├── domain/                  # Domain layer
│   ├── model/               # Domain models
│   ├── workflow/            # Fact-check workflow engine (scoring, searching, reporting)
│   ├── usecase/             # Use cases
│   ├── embedding/           # Embedding service
│   └── sync/                # Sync operations
├── ui/                      # Presentation layer
│   ├── factcheck/           # Fact check screen with transparency badges
│   ├── fulltext/            # Full-text viewer with source badges
│   ├── report/              # Report screen with risk warnings
│   ├── history/             # History screen
│   ├── settings/            # Settings screen with model pricing
│   ├── onboarding/          # Onboarding screen
│   ├── components/          # Shared UI components
│   └── navigation/          # Navigation components
├── di/                      # Hilt dependency injection (App, Workflow, Network, Database)
└── util/                    # Utilities
    ├── JATSXMLParser        # JATS XML to markdown conversion
    ├── JATSModels           # JATS data structures
    ├── CostCalculator       # Token cost estimation
    ├── ResponseParser       # LLM response parsing
    └── PdfExporter          # PDF generation
```

### Key Components

| Component | Description |
|-----------|-------------|
| `FactCheckWorkflow` | State machine orchestrating the fact-check process |
| `LLMService` | Multi-provider LLM API client with retry logic |
| `PubMedService` | NCBI E-utilities client with XML parsing |
| `EuropePMCService` | Europe PMC REST API client |
| `FullTextService` | Multi-source full-text retrieval (Europe PMC XML, Unpaywall, DOI) |
| `JATSXMLParser` | JATS XML to markdown conversion for full-text display |
| `SettingsRepository` | Encrypted settings storage |
| `CostCalculator` | Token cost estimation and budget tracking |

### Database Schema

The app uses Room with the following entities:

- `SessionEntity` - Fact-check workflow sessions
- `DocumentEntity` - Scientific articles from search results
- `CitationEntity` - Extracted citation passages
- `ReportEntity` - Generated evidence reports
- `UsageRecordEntity` - API usage tracking for budget management

## Building

### Debug Build

```bash
./gradlew assembleDebug
```

Output: `app/build/outputs/apk/debug/app-debug.apk`

### Release Build

```bash
# Create a keystore first, then:
./gradlew assembleRelease
```

Output: `app/build/outputs/apk/release/app-release.apk`

### Running Tests

```bash
# Unit tests
./gradlew test

# Instrumented tests (requires device/emulator)
./gradlew connectedAndroidTest

# All tests
./gradlew check
```

## Dependencies

### Core Libraries

- **Jetpack Compose**: Modern declarative UI toolkit
- **Material 3**: Material Design 3 components
- **Room**: SQLite database with coroutines support
- **Hilt**: Dependency injection
- **Retrofit**: Type-safe HTTP client
- **Kotlin Serialization**: JSON serialization
- **Markwon**: Markdown rendering

### Testing Libraries

- **JUnit 4**: Unit testing framework
- **MockK**: Kotlin-first mocking library
- **Turbine**: Testing Kotlin Flows
- **Espresso**: UI testing

## Security Notes

- API keys are stored using Android's EncryptedSharedPreferences
- Network communication uses HTTPS (with cleartext allowed for local Ollama)
- No user data is transmitted to third parties except to configured LLM providers
- All fact-check data is stored locally on the device

## Medical Disclaimer

**This app is for informational purposes only.** It is not a substitute for professional medical advice, diagnosis, or treatment. Always consult with a qualified healthcare provider before making medical decisions.

The app synthesizes information from peer-reviewed literature but:
- May not reflect the latest research
- Cannot account for individual circumstances
- Should not be used for self-diagnosis or self-treatment

## License

Copyright (C) 2024-2026 Dr Horst Herb

AGPL-3.0 License - see the root LICENSE file for details.

## Contributing

See [DEVELOPER_QUICKSTART.md](DEVELOPER_QUICKSTART.md) for development setup and contribution guidelines.

## Support

- **Issues**: Report bugs at [GitHub Issues](https://github.com/hherb/bmlibrarian_lite/issues)
- **Discussions**: Ask questions in [GitHub Discussions](https://github.com/hherb/bmlibrarian_lite/discussions)
