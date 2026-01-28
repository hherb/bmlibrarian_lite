# macOS Feature Parity TODO

This document tracks the features and components present in the iOS version that are missing or incomplete in the native macOS version of Medical Fact Checker.

**Last Updated:** 2026-01-28
**Comparison Base:** iOS app at `ios/MedicalFactChecker/` vs macOS app at `macos/MedicalFactCheckerMac/`

---

## High Priority - Core Feature Gaps

### 1. Phase 2: Per-Document Checkpointing (Resumable Processing)

**Status:** NOT IMPLEMENTED on macOS

The iOS version has comprehensive checkpoint support that allows scoring to resume from where it left off if the app is terminated mid-workflow.

**Missing Files:**
- [ ] `Sources/Models/ProcessingCheckpoint.swift` - SwiftData model for checkpoint persistence
- [ ] `Sources/Services/CheckpointManager.swift` - Actor for checkpoint persistence operations
- [ ] `Sources/Services/CheckpointedScoringService.swift` - Scoring service with checkpoint support

**Missing in FactCheckWorkflow:**
- [ ] `checkpointManager` property initialization
- [ ] Checkpoint save/load logic during scoring phase
- [ ] Resume from checkpoint on session restore

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

---

### 2. Phase 3: Cancellation Support

**Status:** NOT IMPLEMENTED on macOS

iOS allows users to cancel a running fact-check workflow gracefully, completing in-flight requests but starting no new ones.

**Missing in FactCheckWorkflow.swift:**
- [ ] `isCancelling` property (tracks cancellation request)
- [ ] `workflowTask: Task<Void, Never>?` property (holds active task for cancellation)
- [ ] `cancelFactCheck()` method
- [ ] Cancellation checks in scoring/citation loops
- [ ] UI button to trigger cancellation

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift:64-71`

---

### 3. Parallel Scoring Service

**Status:** NOT IMPLEMENTED on macOS

iOS uses `ParallelScoringService` to score multiple documents concurrently using Swift's TaskGroup, significantly improving performance.

**Missing Files:**
- [ ] `Sources/Services/ParallelScoringService.swift` - Actor for parallel document scoring

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

**Status:** MISSING on macOS

Visual indicator showing which search provider found a document (PubMed, Europe PMC, or Both).

**Missing File:**
- [ ] `Sources/Views/Components/DocumentSourceBadge.swift`

**Features:**
- Color-coded badges (pale blue for PubMed, darker blue for Europe PMC, cyan for both)
- Icon and text display
- Used in document list rows

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Components/DocumentSourceBadge.swift`

---

### 5. ProcessingProgressView Component

**Status:** MISSING on macOS

Detailed workflow progress indicator showing current step, spinner, and status messages.

**Missing File:**
- [ ] `Sources/Views/Components/ProcessingProgressView.swift`

**Features:**
- Spinner with current operation text
- Step-by-step progress tracking
- Token usage display during processing

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

**Status:** MISSING on macOS

iOS has a dedicated view optimized for PDF rendering with proper page breaks and formatting.

**Missing File:**
- [ ] `Sources/Views/Report/PrintableReportView.swift` (or macOS equivalent)

**Features:**
- A4/Letter paper size support
- Proper margin handling
- Searchable text-based PDF output
- Page break optimization

**Note:** macOS has `PDFExporter.swift` but may need a dedicated printable view for complex reports.

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Views/Report/PrintableReportView.swift`

---

## Lower Priority - Service & Utility Gaps

### 8. ProgressReporting Protocol

**Status:** MISSING on macOS

Protocol/callbacks for standardized progress reporting across services.

**Missing File:**
- [ ] `Sources/Services/ProgressReporting.swift`

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Services/ProgressReporting.swift`

---

### 9. WorkflowConstants

**Status:** MISSING on macOS

Centralized constants for workflow configuration (timeouts, retry limits, batch sizes).

**Missing File:**
- [ ] `Sources/Services/WorkflowConstants.swift`

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

**Status:** MISSING on macOS

Configuration constants for full-text retrieval (timeouts, retry limits, cache settings).

**Missing File:**
- [ ] `Sources/Utilities/FullTextConstants.swift`

**Reference Implementation:** `ios/MedicalFactChecker/Sources/Utilities/FullTextConstants.swift`

---

### 12. PlatformHelper

**Status:** MISSING on macOS

Platform-specific utility functions.

**Missing File:**
- [ ] `Sources/Utilities/PlatformHelper.swift`

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

The macOS version has more tests than iOS (7 vs 1), but specific tests for the missing features would be needed:

- [ ] `CheckpointManagerTests.swift` - Test checkpoint save/load/delete
- [ ] `ParallelScoringServiceTests.swift` - Test concurrent scoring
- [ ] `CancellationTests.swift` - Test workflow cancellation

---

## Recommended Implementation Order

1. **ParallelScoringService** - Biggest performance impact
2. **Cancellation Support** - Important UX feature
3. **Per-Document Checkpointing** - Reliability for long-running workflows
4. **DocumentSourceBadge** - Visual feedback for multi-provider search
5. **ProcessingProgressView** - Better progress indication
6. **Remaining utilities and constants**

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
