# BioMedLit

A Swift library for biomedical literature retrieval, parsing, transparency analysis, and cross-device synchronization, designed to be shared between iOS and macOS applications.

## Features

- **JATS XML Parsing**: Full-featured parser for Journal Article Tag Suite (JATS) XML
  - Converts to HTML and Markdown
  - Extracts figures, tables, and references
  - Handles cross-references and anchor links
  - Builds Europe PMC figure URLs

- **Europe PMC Service**: Search and retrieve articles from Europe PMC
  - Cursor-based pagination
  - Query filters (preprints, abstracts)
  - Full-text XML retrieval

- **PubMed Service**: Search PubMed via NCBI E-utilities
  - Rate limiting support
  - Batch article fetching
  - XML response parsing

- **Full-Text Service**: Unified full-text retrieval with fallback chain
  - Europe PMC XML (preferred)
  - Europe PMC PDF
  - Unpaywall PDF (open access)
  - DOI resolution (publisher website)
  - PDF caching

- **Study Transparency Analysis**: Automated analysis of research transparency indicators
  - Funding disclosure analysis (FundingAnalyzer)
  - Conflict of interest detection (COIAnalyzer)
  - Data availability assessment (DataAvailabilityAnalyzer)
  - Clinical trial compliance verification (TrialComplianceAnalyzer)
  - Overall transparency scoring (TransparencyScorer)
  - External validation via CrossRef metadata API and ClinicalTrials.gov

- **Sync Engine**: Cross-device synchronization for iOS/macOS
  - iCloud (CloudKit) and local folder storage backends
  - Selective sync with SyncScopeManager
  - Change tracking with ChangeLog reader/writer
  - Last-Write-Wins merge strategy for conflict resolution
  - Session eviction management for storage optimization
  - Workspace initialization and storage monitoring
  - Data integrity checking and validation
  - On-demand document fetching

- **Utilities**: Shared helpers for all platforms
  - RetryHelper with exponential backoff
  - CostCalculator for token cost estimation
  - BudgetChecker for spending limits
  - QueryTranslator for search syntax translation
  - ResponseParser for LLM response handling
  - SearchResultMerger for multi-provider deduplication
  - ConcurrencyDetector and ParallelProcessingConstants for parallel processing

## Requirements

- iOS 17.0+ / macOS 14.0+
- Swift 5.9+
- Xcode 15.0+

## Installation

### Swift Package Manager

Add BioMedLit to your package dependencies:

```swift
dependencies: [
    .package(path: "../Packages/BioMedLit"),  // Local path
    // Or use a git URL when published:
    // .package(url: "https://github.com/org/BioMedLit.git", from: "1.0.0"),
]
```

Add it to your target:

```swift
.target(
    name: "YourApp",
    dependencies: [
        .product(name: "BioMedLit", package: "BioMedLit"),
    ]
)
```

## Usage

### Configuration

Configure BioMedLit at app startup:

```swift
import BioMedLit

// Configure with email and optional logger
let config = BioMedLitConfiguration(
    ncbiEmail: "your@email.com",
    logger: BioMedLitConsoleLogger()  // Or your custom logger
)
BioMedLit.configure(with: config)
```

### JATS XML Parsing

```swift
import BioMedLit

// Parse JATS XML to markdown
let parser = JATSXMLParser(data: xmlData, knownPMCId: "PMC1234567")
let markdown = try parser.parseToMarkdown()

// Or parse to HTML for better table rendering
let html = try parser.parseToHTML()

// Or get structured article data
let article = try parser.parseToArticle()
print("Title: \(article.title)")
print("Authors: \(article.authors.map(\.fullName))")
print("Figures: \(article.figures.count)")
```

### Searching Europe PMC

```swift
import BioMedLit

let service = EuropePMCService()

// Basic search
let results = try await service.search(query: "COVID-19 treatment")

// With options
let filteredResults = try await service.search(
    query: "cancer immunotherapy",
    pageSize: 50,
    includePreprints: false,
    requireAbstract: true
)

// Pagination
let nextPage = try await service.search(
    query: "COVID-19",
    cursor: results.nextCursor ?? "*"
)
```

### Searching PubMed

```swift
import BioMedLit

let service = PubMedService(
    email: "your@email.com",
    apiKey: "optional-api-key"  // For higher rate limits
)

let results = try await service.search(query: "diabetes treatment")
```

### Full-Text Retrieval

```swift
import BioMedLit

let service = FullTextService(email: "your@email.com")

// Fetch full text (tries Europe PMC XML, Europe PMC PDF, Unpaywall, then DOI)
let result = try await service.fetchFullText(
    pmcId: "PMC1234567",
    doi: "10.1234/example",
    pmid: "12345678"
)

switch result {
case .europePMC(let html, let markdown):
    // Display HTML or markdown
    print("Got Europe PMC content")
case .europePMCPDF(let pdfURL):
    // Download or display PDF from Europe PMC
    print("PDF available at: \(pdfURL)")
case .unpaywall(let pdfURL):
    // Download or display PDF
    print("PDF available at: \(pdfURL)")
case .doi(let webURL):
    // Open in browser
    print("Open publisher site: \(webURL)")
case .cached(let filePath):
    // Load cached PDF
    print("Cached at: \(filePath)")
}
```

### Transparency Analysis

```swift
import BioMedLit

let service = TransparencyAnalysisService()

// Analyze a document for transparency indicators
let result = try await service.analyze(
    abstract: document.abstract,
    doi: document.doi,
    pmid: document.pmid
)

print("Overall score: \(result.overallScore)")
print("Funding disclosed: \(result.funding.isDisclosed)")
print("COI declared: \(result.conflictOfInterest.isDeclared)")
print("Data available: \(result.dataAvailability.isAvailable)")
print("Trial registered: \(result.trialCompliance.isRegistered)")
```

### Custom Logging

Implement `BioMedLitLogger` to integrate with your app's logging:

```swift
import BioMedLit
import os.log

struct OSLogger: BioMedLitLogger {
    private let logger = Logger(subsystem: "com.yourapp", category: "BioMedLit")

    func debug(_ message: String, category: BioMedLitLogCategory) {
        logger.debug("[\(category.rawValue)] \(message)")
    }

    func info(_ message: String, category: BioMedLitLogCategory) {
        logger.info("[\(category.rawValue)] \(message)")
    }

    func warning(_ message: String, category: BioMedLitLogCategory) {
        logger.warning("[\(category.rawValue)] \(message)")
    }

    func error(_ message: String, category: BioMedLitLogCategory) {
        logger.error("[\(category.rawValue)] \(message)")
    }
}
```

## Architecture

```
Sources/BioMedLit/
├── BioMedLit.swift              # Package entry point and configuration
├── JATS/                        # JATS XML parsing
│   ├── JATSXMLParser.swift      # XML → HTML/Markdown converter
│   └── JATSModels.swift         # Article, section, figure, table models
├── Models/                      # Shared data models
│   ├── FullTextModels.swift     # Full-text document structures
│   ├── SearchProvider.swift     # Search provider enums
│   ├── StructuredQuery.swift    # Query representation
│   └── Verdict.swift            # Verdict data
├── Services/                    # API clients
│   ├── PubMedService.swift      # NCBI E-utilities client
│   ├── EuropePMCService.swift   # Europe PMC REST API
│   └── FullTextService.swift    # Multi-source full-text retrieval
├── Transparency/                # Study transparency analysis
│   ├── Analysis/                # Individual analyzers
│   │   ├── TransparencyScorer.swift
│   │   ├── FundingAnalyzer.swift
│   │   ├── COIAnalyzer.swift
│   │   ├── DataAvailabilityAnalyzer.swift
│   │   └── TrialComplianceAnalyzer.swift
│   ├── Models/                  # Transparency data models
│   │   ├── TransparencyModels.swift
│   │   └── TransparencyConstants.swift
│   └── Services/                # External validation services
│       ├── TransparencyAnalysisService.swift
│       ├── ClinicalTrialsService.swift
│       └── CrossRefService.swift
├── Sync/                        # Cross-device synchronization
│   ├── SyncEngine.swift         # Main orchestration
│   ├── SyncCoordinator.swift    # Coordination logic
│   ├── SelectiveSyncCoordinator.swift
│   ├── SyncStateManager.swift   # State persistence
│   ├── SyncScopeManager.swift   # Sync scope management
│   ├── iCloudSyncStorage.swift  # CloudKit backend
│   ├── LocalFolderSyncStorage.swift
│   ├── OnDemandFetcher.swift    # Lazy document fetching
│   ├── SessionEvictionManager.swift
│   ├── WorkspaceInitializer.swift
│   ├── StorageMonitor.swift     # Storage usage tracking
│   ├── ChangeLogReader.swift    # Change tracking
│   ├── ChangeLogWriter.swift
│   ├── LWWMergeStrategy.swift   # Conflict resolution
│   ├── IntegrityFunctions.swift # Data integrity
│   ├── IntegrityModels.swift
│   ├── IntegrityError.swift
│   ├── SyncConstants.swift
│   ├── SyncFileNaming.swift
│   ├── SyncStorageProtocol.swift
│   └── WorkspaceModels.swift
└── Utilities/                   # Shared helpers
    ├── RetryHelper.swift        # Exponential backoff
    ├── Constants.swift          # API URLs and constants
    ├── CostCalculator.swift     # Token cost estimation
    ├── BudgetChecker.swift      # Spending limits
    ├── QueryTranslator.swift    # Search syntax translation
    ├── ResponseParser.swift     # LLM response parsing
    ├── SearchResultMerger.swift # Multi-provider deduplication
    ├── ReportFormatter.swift    # Report formatting
    ├── PromptTemplates.swift    # LLM prompt templates
    ├── QueryConstants.swift     # Query-related constants
    ├── ConcurrencyDetector.swift
    └── ParallelProcessingConstants.swift
```

## API Reference

### Types

- `JATSXMLParser` - JATS XML parser
- `JATSArticle` - Parsed article data
- `JATSAuthorInfo` - Author information
- `JATSBodySection` - Article section
- `JATSFigureInfo` - Figure information
- `JATSTableInfo` - Table information
- `JATSReferenceInfo` - Reference information

### Services

- `EuropePMCService` - Europe PMC search
- `PubMedService` - PubMed search
- `FullTextService` - Full-text retrieval
- `TransparencyAnalysisService` - Study transparency analysis
- `ClinicalTrialsService` - ClinicalTrials.gov integration
- `CrossRefService` - CrossRef metadata API

### Transparency

- `TransparencyScorer` - Overall transparency scoring
- `FundingAnalyzer` - Funding disclosure analysis
- `COIAnalyzer` - Conflict of interest detection
- `DataAvailabilityAnalyzer` - Data availability assessment
- `TrialComplianceAnalyzer` - Clinical trial compliance

### Sync

- `SyncEngine` - Main sync orchestration
- `SelectiveSyncCoordinator` - Selective sync support
- `SessionEvictionManager` - Session lifecycle management
- `SyncStorageProtocol` - Storage backend abstraction

### Models

- `SearchProvider` - Search provider enum
- `SearchArticle` - Search result article
- `SearchResult` - Search results container
- `FullTextSource` - Full-text source enum
- `FullTextResult` - Full-text retrieval result

### Utilities

- `RetryHelper` - Retry with exponential backoff
- `RetryConfiguration` - Retry settings
- `BioMedLitConstants` - API URLs and constants
- `ConcurrencyDetector` - Auto-detect parallelism level
- `ParallelProcessingConstants` - Concurrency configuration

## License

Copyright (C) 2024-2026 Dr Horst Herb

This project is licensed under the GNU Affero General Public License v3.0 - see the LICENSE file for details.
