# BioMedLit

A Swift library for biomedical literature retrieval and parsing, designed to be shared between iOS and macOS applications.

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
  - Unpaywall PDF (open access)
  - DOI resolution (publisher website)
  - PDF caching

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

// Fetch full text (tries Europe PMC, then Unpaywall, then DOI)
let result = try await service.fetchFullText(
    pmcId: "PMC1234567",
    doi: "10.1234/example",
    pmid: "12345678"
)

switch result {
case .europePMC(let html, let markdown):
    // Display HTML or markdown
    print("Got Europe PMC content")
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

## Migration Guide

### Migrating from App-Specific Implementations

If your iOS or macOS app has its own JATS parsing or search services, follow these steps to migrate to BioMedLit:

#### 1. Update Package Dependencies

Add BioMedLit to your Package.swift or Xcode project.

#### 2. Update Imports

Replace:
```swift
// Old
import Foundation

// New
import BioMedLit
```

#### 3. Update JATS Parser Usage

Replace:
```swift
// Old (iOS)
let parser = JATSXMLParser(data: data)
let markdown = try parser.parseToMarkdown()

// New
let parser = JATSXMLParser(data: data, knownPMCId: pmcId)
let markdown = try parser.parseToMarkdown()
// Or get HTML for better rendering:
let html = try parser.parseToHTML()
```

#### 4. Update Service Usage

Replace:
```swift
// Old
let service = FullTextService.create(from: settings)

// New
let service = FullTextService(email: settings.ncbiEmail)
```

#### 5. Update Result Handling

The new `FullTextResult` enum provides more detailed information:

```swift
// Old
switch result.content {
case .markdown(let text):
    // Handle markdown
case .pdfURL(let url):
    // Handle PDF
case .webURL(let url):
    // Handle web
}

// New
switch result {
case .europePMC(let html, let markdown):
    // Now have both HTML and markdown!
case .unpaywall(let pdfURL):
    // Handle PDF
case .doi(let webURL):
    // Handle web
case .cached(let filePath):
    // Handle cached content
}
```

#### 6. Remove Duplicate Code

After migration, you can remove these files from your app:
- `JATSXMLParser.swift` (use BioMedLit version)
- `EuropePMCService.swift` (use BioMedLit version)
- `PubMedService.swift` (use BioMedLit version)
- `FullTextService.swift` (use BioMedLit version)
- `RetryHelper.swift` (use BioMedLit version)

Keep app-specific files:
- `Document.swift` (SwiftData model)
- `AppSettings.swift` (app configuration)
- View files (UI is platform-specific)

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

## License

This project is licensed under the GNU Affero General Public License v3.0 - see the LICENSE file for details.
