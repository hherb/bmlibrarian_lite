# macOS Feature Parity TODO

This document tracks the features and components present in the iOS version that are missing or incomplete in the native macOS version of Medical Fact Checker.

**Last Updated:** 2026-01-28
**Comparison Base:** iOS app at `ios/MedicalFactChecker/` vs macOS app at `macos/MedicalFactCheckerMac/`

---

## High Priority - Core Feature Gaps

### 1. Phase 2: Per-Document Checkpointing (Resumable Processing)

**Status:** IMPLEMENTED

The macOS version now has comprehensive checkpoint support that allows scoring to resume from where it left off if the app is terminated mid-workflow.

**Implemented Files:**
- [x] `Sources/Models/ProcessingCheckpoint.swift` - SwiftData model for checkpoint persistence
- [x] `Sources/Services/CheckpointManager.swift` - Actor for checkpoint persistence operations
- [x] `Sources/Services/CheckpointedScoringService.swift` - Scoring service with checkpoint support

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

---

### 2. Phase 3: Cancellation Support

**Status:** IMPLEMENTED

macOS now allows users to cancel a running fact-check workflow gracefully, completing in-flight requests but starting no new ones.

**Implemented in FactCheckWorkflow.swift:**
- [x] `isCancelling` property (tracks cancellation request)
- [x] `workflowTask: Task<Void, Never>?` property (holds active task for cancellation)
- [x] `canCancel` computed property
- [x] `cancelFactCheck()` method
- [x] Cancellation checks in scoring/citation loops via `try Task.checkCancellation()`
- [x] `onCancelled` callback for UI notification
- [ ] UI button to trigger cancellation (optional - can use existing cancel() method)

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift:64-71`

---

### 3. Parallel Scoring Service

**Status:** IMPLEMENTED

macOS now uses `ParallelScoringService` to score multiple documents concurrently using Swift's TaskGroup, significantly improving performance.

**Implemented Files:**
- [x] `Sources/Services/ParallelScoringService.swift` - Actor for parallel document scoring

**Key Components:**
- `ScoringInput` struct (thread-safe, Sendable)
- `ScoringResult` struct with score/explanation/error info
- `ScoringError` enum
- `scoreDocuments()` method using TaskGroup with sliding window
- `aggregateUsage()` for total token counting

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/ParallelScoringService.swift`

---

## Medium Priority - UI Components

### 4. DocumentSourceBadge Component

**Status:** IMPLEMENTED

Visual indicator showing which search provider found a document (PubMed, Europe PMC, or Both).

**Implemented File:**
- [x] `Sources/Views/Components/DocumentSourceBadge.swift`

**Features:**
- Color-coded badges (pale blue for PubMed, darker blue for Europe PMC, cyan for both)
- Icon and text display
- Preprint indicator support
- Used in document list rows

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Components/DocumentSourceBadge.swift`

---

### 5. ProcessingProgressView Component

**Status:** IMPLEMENTED

Detailed workflow progress indicator showing current step, spinner, and status messages.

**Implemented File:**
- [x] `Sources/Views/Components/ProcessingProgressView.swift`

**Features:**
- Linear progress bar with smooth animations
- Displays current/total count
- Shows skipped count (resumed from checkpoint)
- Shows failed count with error styling
- `CompactProgressView` for inline use
- `DualPhaseProgressView` for combined scoring/citation progress

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Components/ProcessingProgressView.swift`

---

### 6. SearchOptionsView Component

**Status:** PARTIAL - macOS has MacSearchOptionsToolbar but lacks standalone view

iOS has a dedicated `SearchOptionsView` component for search configuration. macOS integrates this into the toolbar but may benefit from a standalone component for consistency.

**Existing:** `Sources/Views/FactCheck/MacSearchOptionsToolbar.swift`

**Consider:**
- [ ] Extracting shared logic into reusable component
- [ ] Ensuring feature parity with iOS SearchOptionsView

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Components/SearchOptionsView.swift`

---

### 7. PrintableReportView for PDF Export

**Status:** IMPLEMENTED

macOS now has a dedicated view optimized for PDF rendering with proper page breaks and formatting.

**Implemented File:**
- [x] `Sources/Views/Report/PrintableReportView.swift`

**Features:**
- A4/Letter paper size support via PaperSize enum
- Proper margin handling
- Reference conversion to plain text with PMIDs
- Markdown parsing and rendering
- PrintableMarkdownView for structured content
- Integrates with existing PDFExporter for text-based PDF generation

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Report/PrintableReportView.swift`

---

## Lower Priority - Service & Utility Gaps

### 8. ProgressReporting Protocol

**Status:** IMPLEMENTED

Protocol/callbacks for standardized progress reporting across services.

**Implemented File:**
- [x] `Sources/Services/ProgressReporting.swift`

**Features:**
- `ProgressType` enum for different progress events
- `ProgressMessage` struct with full progress details
- `ProgressDelegate` protocol for receiving updates
- `ProcessingProgress` aggregate state
- `PhaseProgress` per-phase tracking

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/ProgressReporting.swift`

---

### 9. WorkflowConstants

**Status:** IMPLEMENTED

Centralized constants for workflow configuration (timeouts, retry limits, batch sizes).

**Implemented File:**
- [x] `Sources/Services/WorkflowConstants.swift`

**Constants:**
- `smartSearchThreshold` - Minimum relevant documents before triggering smart search
- `cloudConcurrencyDefault` - Default concurrent requests for cloud LLM providers
- `localConcurrencyDefault` - Concurrent requests for local inference (Ollama)

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/WorkflowConstants.swift`

---

### 10. SearchServiceProtocol

**Status:** DIFFERENT APPROACH

iOS uses `SearchServiceProtocol` interface; macOS uses `SearchServiceFactory`. Both approaches work, but consider aligning for code sharing.

**iOS File:** `ios/MedicalFactChecker/Sources/Services/SearchServiceProtocol.swift`
**macOS File:** `macos/MedicalFactCheckerMac/Sources/Services/SearchServiceFactory.swift`

**Consider:**
- [ ] Evaluate if protocol approach would enable code sharing
- [ ] Document architectural decision if intentionally different

---

### 11. FullTextConstants

**Status:** IMPLEMENTED

Configuration constants for full-text retrieval (timeouts, retry limits, cache settings).

**Implemented File:**
- [x] `Sources/Utilities/FullTextConstants.swift`

**Constants:**
- API URLs (Europe PMC, Unpaywall, DOI, PubMed)
- Timeout settings
- HTTP status codes
- Formatting constants
- File path constants
- PDF validation

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Utilities/FullTextConstants.swift`

---

### 12. PlatformHelper

**Status:** IMPLEMENTED

Platform-specific utility functions for macOS.

**Implemented File:**
- [x] `Sources/Utilities/PlatformHelper.swift`

**Features:**
- `openURL()` - Open URLs in default browser using NSWorkspace
- `copyToClipboard()` - Copy text using NSPasteboard
- `doiURL()` - Build DOI resolver URLs
- `pubmedURL()` - Build PubMed page URLs
- Bundle extension for app version info

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Utilities/PlatformHelper.swift`

---

## Architectural Differences (Not Bugs)

These are intentional differences between the platforms:

| Aspect | iOS | macOS | Notes |
|--------|-----|-------|-------|
| Disclaimer View | Separate file | Embedded in MacContentView | Could be extracted for consistency |
| History Constants | HistoryConstants.swift | MacHistoryConstants.swift | Platform-specific values |
| JATS XML Parser | Local copy in app | Uses BioMedLit package | macOS approach is better (shared code) |
| Logger | Uses os.log directly | Has Logger.swift wrapper | macOS approach is better (abstraction) |
| Query Builder | Uses QueryTranslator | Has separate QueryBuilder.swift | macOS has additional utility |

---

## Testing Gaps

The macOS version has more tests than iOS (7 vs 1), but specific tests for the new features would be beneficial:

- [ ] `CheckpointManagerTests.swift` - Test checkpoint save/load/delete
- [ ] `ParallelScoringServiceTests.swift` - Test concurrent scoring
- [ ] `CancellationTests.swift` - Test workflow cancellation

---

## Implementation Summary

All high-priority and most medium/lower priority items have been implemented:

1. **ParallelScoringService** - DONE
2. **Cancellation Support** - DONE
3. **Per-Document Checkpointing** - DONE
4. **DocumentSourceBadge** - DONE
5. **ProcessingProgressView** - DONE
6. **WorkflowConstants** - DONE
7. **ProgressReporting** - DONE
8. **FullTextConstants** - DONE
9. **PlatformHelper** - DONE
10. **PrintableReportView** - DONE

**Remaining Optional Items:**
- SearchOptionsView extraction (partial - toolbar exists)
- SearchServiceProtocol alignment (architectural decision)
- Test coverage for new features

---

## Code Sharing Opportunities

Consider moving these to the shared `BioMedLit` package:

- `ParallelScoringService` (with platform-agnostic interface)
- `CheckpointManager` (if using shared persistence layer)
- `ProgressReporting` protocol
- `WorkflowConstants`

This would enable feature parity by default for future changes.

---

## Notes

- The macOS app has some features iOS lacks (e.g., separate Full Text tab, multi-window support)
- Both apps share the `BioMedLit` package for core functionality
- The macOS app uses `MacConstants.swift` for design system constants, which iOS could adopt
- macOS has better test coverage for search and full-text features
