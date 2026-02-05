# Study Transparency Analyzer - Swift Implementation Plan

## Overview

Port the study transparency analysis feature to the BioMedLit Swift package as **pure reusable functions** suitable for iOS and macOS integration.

## Design Philosophy

### Pure Functions First

The Swift implementation emphasizes:
- **Pure functions** for analysis logic (no side effects, fully testable)
- **Immutable data models** (`struct` with `Sendable` conformance)
- **Actor-based services** only for network operations (following existing patterns)
- **Protocol-oriented design** for extensibility

### Integration with Existing Infrastructure

Reuse existing BioMedLit components:
- `EuropePMCService` for article metadata
- `PubMedService` for PubMed data
- `RetryHelper` for network retry logic
- `BioMedLitConstants` for configuration
- `BioMedLitLogger` for logging

## Architecture

```
Packages/BioMedLit/Sources/BioMedLit/
├── Transparency/                    # NEW module
│   ├── Models/
│   │   ├── TransparencyModels.swift        # Data types
│   │   └── TransparencyConstants.swift     # Industry funder registry, patterns
│   ├── Analysis/
│   │   ├── FundingAnalyzer.swift           # Pure functions for funding analysis
│   │   ├── COIAnalyzer.swift               # Pure functions for COI detection
│   │   ├── DataAvailabilityAnalyzer.swift  # Pure functions for data availability
│   │   ├── TrialComplianceAnalyzer.swift   # Pure functions for trial compliance
│   │   └── TransparencyScorer.swift        # Pure scoring functions
│   └── Services/
│       ├── ClinicalTrialsService.swift     # ClinicalTrials.gov API client
│       ├── CrossRefService.swift           # CrossRef API client
│       └── TransparencyAnalysisService.swift # Orchestration service
```

## Implementation Steps

| Step | Description | Files | Scope |
|------|-------------|-------|-------|
| 01 | Data Models | TransparencyModels.swift | ~200 lines |
| 02 | Constants & Patterns | TransparencyConstants.swift | ~150 lines |
| 03 | Funding Analyzer | FundingAnalyzer.swift | ~180 lines |
| 04 | COI Analyzer | COIAnalyzer.swift | ~150 lines |
| 05 | Data Availability Analyzer | DataAvailabilityAnalyzer.swift | ~130 lines |
| 06 | Trial Compliance Analyzer | TrialComplianceAnalyzer.swift | ~100 lines |
| 07 | Transparency Scorer | TransparencyScorer.swift | ~100 lines |
| 08 | CrossRef Service | CrossRefService.swift | ~200 lines |
| 09 | ClinicalTrials Service | ClinicalTrialsService.swift | ~250 lines |
| 10 | Orchestration Service | TransparencyAnalysisService.swift | ~300 lines |
| 11 | Tests | Tests/TransparencyTests/ | ~400 lines |

**Total estimated scope: ~2,160 lines**

## Key Design Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Analysis functions | Pure `enum` functions | Testable, no state, thread-safe |
| Data models | `struct` with `Sendable` | Immutable, concurrent-safe |
| API clients | `actor` | Thread-safe network operations |
| Error handling | `RetryableError` protocol | Consistent with existing code |
| Pattern matching | `NSRegularExpression` | Foundation-based, no dependencies |
| Caching | Optional, via service | Pure functions don't cache |

## Integration with iOS/macOS Apps

### Usage Pattern

```swift
// Single article analysis
let service = TransparencyAnalysisService()
let result = try await service.analyze(pmid: "33301246")

// Access results
print("Score: \(result.transparencyScore)")
print("Risk: \(result.riskLevel)")

// Pure function usage (no network)
let score = TransparencyScorer.calculateScore(from: components)
let coiAnalysis = COIAnalyzer.analyze(statement: coiText)
```

### View Integration

```swift
// In SwiftUI view
@State private var transparency: TransparencyResult?

var body: some View {
    if let result = transparency {
        TransparencyBadge(result: result)
            .help(TransparencyScorer.formatTooltip(for: result))
    }
}
```

## Dependencies

- Foundation (only)
- No external packages required
- Uses existing BioMedLit services

## Implementation Order

1. **Steps 01-02**: Foundation (models, constants) - no dependencies
2. **Steps 03-07**: Pure analysis functions - can be unit tested
3. **Steps 08-09**: API services - integration tests
4. **Step 10**: Orchestration - end-to-end tests
5. **Step 11**: Full test suite

Each step produces working, testable code.
