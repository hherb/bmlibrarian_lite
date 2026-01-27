# Phase 4: Error Queue UI and Result Re-ordering (iOS/macOS)

## Objective

Provide a polished error display with persistence, categorization, and accessibility support. Allow users to re-order results after processing completes.

## Phase Integration Notes

Phase 4 builds on all previous phases:

### Dependencies from Phase 1 (Parallel Requests)

- **`ScoringResult`**: Contains `errorMessage` field populated when scoring fails. Phase 4 displays these errors in the queue.
- **`ParallelScoringService`**: Errors from concurrent requests feed into the error queue.

### Dependencies from Phase 2 (Checkpointing)

- **`CheckpointManager`**: Used for error persistence. Errors can be saved as failed checkpoints.
- **`ScoringCheckpoint`**: Extended to include error information (`isError`, `errorMessage`).
- **`ProgressDelegate`**: Error events flow through the progress system.

### Dependencies from Phase 3 (Cancellation)

- **`CancellableScoringService`**: Cancellation may leave documents in an error state that should be displayed.
- When processing is cancelled, any in-flight errors should still be captured and displayed.

### Key Integration Points

| Component | Phase | Integration |
|-----------|-------|-------------|
| `ScoringResult.errorMessage` | 1 | Source of error messages |
| `CheckpointManager` | 2 | Persistence for errors |
| `ProgressMessage.error` | 2 | Error propagation |
| `CancellableScoringService` | 3 | Errors during cancellation |

## 4.1 Error Types and Categorization

**File**: `ios/MedicalFactChecker/Sources/Models/ErrorTypes.swift`

```swift
import Foundation

/// Categories of errors that can occur during document processing.
enum ErrorCategory: String, Codable, CaseIterable {
    case network = "Network"
    case llm = "LLM"
    case parsing = "Parsing"
    case timeout = "Timeout"
    case unknown = "Unknown"

    var icon: String {
        switch self {
        case .network: return "wifi.slash"
        case .llm: return "brain"
        case .parsing: return "doc.text.magnifyingglass"
        case .timeout: return "clock.badge.exclamationmark"
        case .unknown: return "questionmark.circle"
        }
    }

    var color: Color {
        switch self {
        case .network: return Color.orange
        case .llm: return Color.purple
        case .parsing: return Color.blue
        case .timeout: return Color.yellow
        case .unknown: return Color.gray
        }
    }
}

// MARK: - Constants

private enum ErrorCategoryConstants {
    static let networkKeywords = ["network", "connection", "offline", "internet", "unreachable"]
    static let timeoutKeywords = ["timeout", "timed out"]
    static let parsingKeywords = ["parse", "decode", "json", "xml", "invalid format", "malformed"]
    static let llmKeywords = ["llm", "model", "api key", "rate limit", "token", "openai", "anthropic", "claude"]
}

/// Categorize an error based on its message or type.
func categorizeError(_ error: Error) -> ErrorCategory {
    let message = error.localizedDescription.lowercased()

    if error is URLError || message.contains("network") || message.contains("connection") ||
       message.contains("offline") || message.contains("internet") {
        return .network
    }

    if message.contains("timeout") || message.contains("timed out") {
        return .timeout
    }

    if message.contains("parse") || message.contains("decode") || message.contains("json") ||
       message.contains("xml") || message.contains("invalid format") {
        return .parsing
    }

    if message.contains("llm") || message.contains("model") || message.contains("api key") ||
       message.contains("rate limit") || message.contains("token") || message.contains("openai") ||
       message.contains("anthropic") {
        return .llm
    }

    return .unknown
}

/// Categorize an error from a string message.
func categorizeErrorMessage(_ message: String) -> ErrorCategory {
    let lowercased = message.lowercased()

    if lowercased.contains("network") || lowercased.contains("connection") ||
       lowercased.contains("offline") || lowercased.contains("internet") ||
       lowercased.contains("unreachable") {
        return .network
    }

    if lowercased.contains("timeout") || lowercased.contains("timed out") {
        return .timeout
    }

    if lowercased.contains("parse") || lowercased.contains("decode") ||
       lowercased.contains("json") || lowercased.contains("xml") ||
       lowercased.contains("invalid format") || lowercased.contains("malformed") {
        return .parsing
    }

    if lowercased.contains("llm") || lowercased.contains("model") ||
       lowercased.contains("api key") || lowercased.contains("rate limit") ||
       lowercased.contains("token") || lowercased.contains("openai") ||
       lowercased.contains("anthropic") || lowercased.contains("claude") {
        return .llm
    }

    return .unknown
}
```

## 4.2 Error Entry Model with Persistence

**File**: `ios/MedicalFactChecker/Sources/Models/ErrorEntry.swift`

```swift
import Foundation
import SwiftData

/// Single error entry for display and persistence.
@Model
final class ErrorEntry {
    var id: UUID
    var pmid: String
    var step: String
    var message: String
    var category: String  // ErrorCategory.rawValue
    var timestamp: Date
    var sessionId: String
    var retryCount: Int

    init(
        pmid: String,
        step: String,
        message: String,
        category: ErrorCategory = .unknown,
        sessionId: String,
        retryCount: Int = 0
    ) {
        self.id = UUID()
        self.pmid = pmid
        self.step = step
        self.message = message
        self.category = category.rawValue
        self.timestamp = Date()
        self.sessionId = sessionId
        self.retryCount = retryCount
    }

    var errorCategory: ErrorCategory {
        ErrorCategory(rawValue: category) ?? .unknown
    }
}

/// Non-persistent error entry for in-memory use.
struct TransientErrorEntry: Identifiable, Sendable {
    let id = UUID()
    let pmid: String
    let step: String
    let message: String
    let category: ErrorCategory
    let timestamp: Date

    init(pmid: String, step: String, message: String, timestamp: Date = Date()) {
        self.pmid = pmid
        self.step = step
        self.message = message
        self.category = categorizeErrorMessage(message)
        self.timestamp = timestamp
    }
}
```

## 4.3 Error Persistence Manager

**File**: `ios/MedicalFactChecker/Sources/Services/ErrorPersistenceManager.swift`

```swift
import Foundation
import SwiftData

/// Manages persistence of processing errors.
actor ErrorPersistenceManager {
    private let modelContainer: ModelContainer

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
    }

    /// Save an error to persistent storage.
    @MainActor
    func saveError(
        pmid: String,
        step: String,
        message: String,
        sessionId: String
    ) throws {
        let context = modelContainer.mainContext
        let category = categorizeErrorMessage(message)

        let entry = ErrorEntry(
            pmid: pmid,
            step: step,
            message: message,
            category: category,
            sessionId: sessionId
        )

        context.insert(entry)
        try context.save()
    }

    /// Load all errors for a session.
    @MainActor
    func loadErrors(sessionId: String) throws -> [ErrorEntry] {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(
            predicate: predicate,
            sortBy: [SortDescriptor(\.timestamp, order: .reverse)]
        )
        return try context.fetch(descriptor)
    }

    /// Clear all errors for a session.
    @MainActor
    func clearErrors(sessionId: String) throws {
        let context = modelContainer.mainContext
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let errors = try context.fetch(descriptor)

        for error in errors {
            context.delete(error)
        }
        try context.save()
    }

    /// Increment retry count for specific PMIDs.
    ///
    /// - Parameters:
    ///   - pmids: List of PMIDs to update.
    ///   - sessionId: Session identifier.
    @MainActor
    func incrementRetryCount(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

        // Fetch all errors for session, then filter in memory
        // (SwiftData predicates don't support Set.contains)
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let allErrors = try context.fetch(descriptor)

        let matchingErrors = allErrors.filter { pmidSet.contains($0.pmid) }
        for error in matchingErrors {
            error.retryCount += 1
        }
        try context.save()
    }

    /// Remove errors for successfully retried PMIDs.
    ///
    /// - Parameters:
    ///   - pmids: List of PMIDs to remove.
    ///   - sessionId: Session identifier.
    @MainActor
    func removeErrors(pmids: [String], sessionId: String) throws {
        let context = modelContainer.mainContext
        let pmidSet = Set(pmids)

        // Fetch all errors for session, then filter in memory
        let predicate = #Predicate<ErrorEntry> { $0.sessionId == sessionId }
        let descriptor = FetchDescriptor<ErrorEntry>(predicate: predicate)
        let allErrors = try context.fetch(descriptor)

        let matchingErrors = allErrors.filter { pmidSet.contains($0.pmid) }
        for error in matchingErrors {
            context.delete(error)
        }
        try context.save()
    }
}
```

## 4.4 Error Queue View with Accessibility

**File**: `ios/MedicalFactChecker/Sources/Views/Components/ErrorQueueView.swift`

```swift
import SwiftUI

struct ErrorQueueView: View {
    @Binding var errors: [TransientErrorEntry]
    @State private var isExpanded = false
    @State private var selectedCategory: ErrorCategory?
    var onRetry: ([String]) -> Void

    private var filteredErrors: [TransientErrorEntry] {
        guard let category = selectedCategory else { return errors }
        return errors.filter { $0.category == category }
    }

    private var errorCountsByCategory: [ErrorCategory: Int] {
        Dictionary(grouping: errors, by: \.category)
            .mapValues { $0.count }
    }

    var body: some View {
        if !errors.isEmpty {
            VStack(spacing: 0) {
                // Header
                headerView

                // Category filter
                if isExpanded {
                    categoryFilterView
                }

                // Error list
                if isExpanded {
                    errorListView
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(12)
            .shadow(radius: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error queue with \(errors.count) errors")
        }
    }

    // MARK: - Header

    private var headerView: some View {
        HStack {
            Label("Errors (\(errors.count))", systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
                .font(.headline)
                .accessibilityLabel("\(errors.count) errors occurred during processing")

            Spacer()

            Button("Retry All") {
                let pmids = errors.map { $0.pmid }
                onRetry(pmids)
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .accessibilityHint("Retry processing all failed documents")

            Button("Clear") {
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Dismiss all errors without retrying")

            Button {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .accessibilityLabel(isExpanded ? "Collapse error list" : "Expand error list")
            .accessibilityHint(isExpanded ? "Hide error details" : "Show error details")
        }
        .padding()
        .background(Color.red.opacity(0.1))
        .cornerRadius(8)
    }

    // MARK: - Category Filter

    private var categoryFilterView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" filter
                CategoryFilterChip(
                    title: "All",
                    count: errors.count,
                    isSelected: selectedCategory == nil,
                    color: .gray
                ) {
                    selectedCategory = nil
                }

                // Category filters
                ForEach(ErrorCategory.allCases, id: \.self) { category in
                    if let count = errorCountsByCategory[category], count > 0 {
                        CategoryFilterChip(
                            title: category.rawValue,
                            count: count,
                            isSelected: selectedCategory == category,
                            color: category.color
                        ) {
                            selectedCategory = category
                        }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.vertical, 8)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error category filters")
    }

    // MARK: - Error List

    private var errorListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredErrors) { error in
                    ErrorCardView(error: error)
                }
            }
            .padding()
        }
        .frame(maxHeight: 200)
        .background(Color(.systemBackground))
    }
}

// MARK: - Category Filter Chip

struct CategoryFilterChip: View {
    let title: String
    let count: Int
    let isSelected: Bool
    let color: Color
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text(title)
                    .font(.caption)
                Text("(\(count))")
                    .font(.caption2)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundColor(isSelected ? color : .secondary)
            .cornerRadius(16)
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .stroke(isSelected ? color : Color.clear, lineWidth: 1)
            )
        }
        .accessibilityLabel("\(title) errors: \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Error Card

struct ErrorCardView: View {
    let error: TransientErrorEntry

    private var categoryColor: Color {
        error.category.color
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: error.category.icon)
                    .foregroundColor(categoryColor)
                    .accessibilityHidden(true)

                Text("PMID: \(error.pmid)")
                    .font(.caption.bold())

                Text("(\(error.step))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                Text(error.category.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(categoryColor.opacity(0.2))
                    .cornerRadius(4)
            }

            Text(error.message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.05))
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.red.opacity(0.2), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Error for PMID \(error.pmid), \(error.category.rawValue) error during \(error.step): \(error.message)")
    }
}
```

## 4.5 Sorting Controls with Accessibility

**File**: `ios/MedicalFactChecker/Sources/Views/Components/SortingControlsView.swift`

```swift
import SwiftUI

enum SortOption: String, CaseIterable {
    case scoreHighToLow = "Score (High to Low)"
    case scoreLowToHigh = "Score (Low to High)"
    case titleAZ = "Title (A-Z)"
    case titleZA = "Title (Z-A)"
    case yearNewest = "Year (Newest First)"
    case yearOldest = "Year (Oldest First)"

    var accessibilityDescription: String {
        switch self {
        case .scoreHighToLow: return "Sort by score, highest first"
        case .scoreLowToHigh: return "Sort by score, lowest first"
        case .titleAZ: return "Sort by title, A to Z"
        case .titleZA: return "Sort by title, Z to A"
        case .yearNewest: return "Sort by year, newest first"
        case .yearOldest: return "Sort by year, oldest first"
        }
    }
}

struct SortingControlsView: View {
    @Binding var selectedSort: SortOption

    var body: some View {
        HStack {
            Text("Sort by:")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Picker("Sort", selection: $selectedSort) {
                ForEach(SortOption.allCases, id: \.self) { option in
                    Text(option.rawValue)
                        .tag(option)
                        .accessibilityLabel(option.accessibilityDescription)
                }
            }
            .pickerStyle(.menu)
            .accessibilityLabel("Sort order")
            .accessibilityValue(selectedSort.accessibilityDescription)

            Spacer()
        }
        .padding(.horizontal)
    }
}

// MARK: - Sortable Document Protocol

/// Protocol for documents that can be sorted by score, title, or year.
protocol SortableDocument {
    var score: Int? { get }
    var title: String? { get }
    var year: Int? { get }
}

// MARK: - Document Sorting Extension

extension Array where Element: SortableDocument {
    /// Sort documents by the specified option.
    ///
    /// - Parameter option: The sort option to apply.
    /// - Returns: Sorted array of documents.
    func sorted(by option: SortOption) -> [Element] {
        switch option {
        case .scoreHighToLow:
            return sorted { ($0.score ?? 0) > ($1.score ?? 0) }
        case .scoreLowToHigh:
            return sorted { ($0.score ?? 0) < ($1.score ?? 0) }
        case .titleAZ:
            return sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending }
        case .titleZA:
            return sorted { ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedDescending }
        case .yearNewest:
            return sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearOldest:
            return sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        }
    }
}
```

## 4.6 Integration in Scored Documents View

**File**: `ios/MedicalFactChecker/Sources/Views/FactCheck/ScoredDocumentsView.swift`

```swift
import SwiftUI

/// View displaying scored documents with error queue and sorting.
///
/// Assumes `Document` conforms to `SortableDocument` and `Identifiable`.
struct ScoredDocumentsView<Document: SortableDocument & Identifiable>: View {
    @State var documents: [Document]
    @State private var sortOption: SortOption = .scoreHighToLow
    @State private var errors: [TransientErrorEntry] = []
    @AppStorage("lastSortOption") private var savedSortOption: String = SortOption.scoreHighToLow.rawValue

    let sessionId: String
    var onRetry: ([String]) -> Void

    private var sortedDocuments: [Document] {
        documents.sorted(by: sortOption)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Error queue at top
            ErrorQueueView(errors: $errors, onRetry: handleRetry)
                .padding()

            // Sort controls
            SortingControlsView(selectedSort: $sortOption)
                .onChange(of: sortOption) { _, newValue in
                    savedSortOption = newValue.rawValue
                }

            // Results summary
            resultsSummaryView

            // Document list
            ScrollView {
                LazyVStack(spacing: 12) {
                    ForEach(sortedDocuments) { document in
                        // DocumentCardView is defined in your existing codebase
                        // and should accept a Document conforming to SortableDocument
                        DocumentCardView(document: document)
                    }
                }
                .padding()
            }
        }
        .onAppear {
            if let saved = SortOption(rawValue: savedSortOption) {
                sortOption = saved
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Scored documents view")
    }

    // MARK: - Results Summary

    private var resultsSummaryView: some View {
        let successful = documents.filter { $0.score != nil }.count
        let failed = errors.count

        return HStack {
            Label("\(successful) scored", systemImage: "checkmark.circle")
                .foregroundColor(.green)

            if failed > 0 {
                Label("\(failed) failed", systemImage: "xmark.circle")
                    .foregroundColor(.red)
            }

            Spacer()
        }
        .font(.caption)
        .padding(.horizontal)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(successful) documents scored successfully, \(failed) failed")
    }

    // MARK: - Actions

    func addError(pmid: String, step: String, message: String) {
        let entry = TransientErrorEntry(
            pmid: pmid,
            step: step,
            message: message
        )
        errors.append(entry)
    }

    private func handleRetry(_ pmids: [String]) {
        // Remove errors for these PMIDs
        errors.removeAll { pmids.contains($0.pmid) }
        // Trigger retry
        onRetry(pmids)
    }
}
```

## 4.7 FactCheckWorkflow Integration

**File**: `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift`

Add error handling integration:

```swift
// Add to FactCheckWorkflow class:

/// Error persistence manager
private var errorManager: ErrorPersistenceManager?

/// Configure error persistence
func configureErrorPersistence(modelContainer: ModelContainer) {
    errorManager = ErrorPersistenceManager(modelContainer: modelContainer)
}

/// Handle scoring errors from Phase 1/2/3 processing.
///
/// Called when a document fails scoring. Persists the error and
/// notifies the UI via the progress delegate.
private func handleScoringError(
    pmid: String,
    step: String,
    error: Error,
    sessionId: String
) async {
    let message = error.localizedDescription
    let category = categorizeError(error)

    // Persist error (Phase 4)
    if let errorManager = errorManager {
        try? await errorManager.saveError(
            pmid: pmid,
            step: step,
            message: message,
            sessionId: sessionId
        )
    }

    // Notify progress delegate (Phase 2)
    await progressTracker?.didReceiveProgress(ProgressMessage(
        type: .documentFailed,
        pmid: pmid,
        step: step,
        current: processedCount,
        total: totalCount,
        error: message
    ))
}

/// Retry failed documents.
///
/// Re-queues documents that previously failed for another scoring attempt.
/// Uses Phase 2 checkpointing to track retry attempts.
func retryFailedDocuments(pmids: [String]) async throws {
    guard let session = session else { return }

    // Increment retry counts
    if let errorManager = errorManager {
        try await errorManager.incrementRetryCount(
            pmids: pmids,
            sessionId: session.id.uuidString
        )
    }

    // Get documents to retry
    let documentsToRetry = session.documents.filter { doc in
        pmids.contains(doc.pmid)
    }

    // Re-score using Phase 3 cancellable service
    // (existing scoring logic)
}

/// Handle successful retry.
///
/// Called when a previously-failed document is successfully scored.
/// Removes the error from persistence.
private func handleSuccessfulRetry(pmid: String, sessionId: String) async {
    if let errorManager = errorManager {
        try? await errorManager.removeErrors(
            pmids: [pmid],
            sessionId: sessionId
        )
    }
}
```

## Key Swift Patterns

### SwiftUI Accessibility

SwiftUI provides built-in accessibility support:

- `.accessibilityLabel()` - Screen reader text
- `.accessibilityHint()` - Additional context for actions
- `.accessibilityValue()` - Current value for controls
- `.accessibilityElement(children:)` - Group elements
- `.accessibilityAddTraits()` - Add semantic traits

### SwiftData Persistence

SwiftData provides type-safe persistence:

- `@Model` - Mark classes for persistence
- `ModelContainer` - Manages the data store
- `FetchDescriptor` - Type-safe queries with predicates
- `#Predicate` - Compile-time checked predicates

### Animation

SwiftUI animations for smooth transitions:

- `withAnimation()` - Animate state changes
- `.animation()` modifier - Attach animations to views
- `AnimatedVisibility` pattern with `if` statements

### @AppStorage

Persist user preferences:

- `@AppStorage` - UserDefaults backed property wrapper
- Automatically syncs with UserDefaults
- Supports Codable types with custom keys

## Testing

```bash
# Unit tests
swift test --filter ErrorQueueTests
swift test --filter SortingTests
swift test --filter ErrorPersistenceTests

# UI tests
swift test --filter ErrorQueueUITests
swift test --filter AccessibilityTests
```

### Test Cases

```swift
// ErrorQueueTests.swift
func testErrorCategorization() {
    XCTAssertEqual(categorizeErrorMessage("Network connection failed"), .network)
    XCTAssertEqual(categorizeErrorMessage("LLM rate limit exceeded"), .llm)
    XCTAssertEqual(categorizeErrorMessage("JSON parsing error"), .parsing)
    XCTAssertEqual(categorizeErrorMessage("Request timed out"), .timeout)
    XCTAssertEqual(categorizeErrorMessage("Something went wrong"), .unknown)
}

func testErrorQueueFiltering() {
    var errors = [
        TransientErrorEntry(pmid: "1", step: "scoring", message: "Network error"),
        TransientErrorEntry(pmid: "2", step: "scoring", message: "LLM failed"),
        TransientErrorEntry(pmid: "3", step: "scoring", message: "Network timeout"),
    ]

    let networkErrors = errors.filter { $0.category == .network }
    XCTAssertEqual(networkErrors.count, 2)
}

// SortingTests.swift
func testSortByScore() {
    let docs = [
        createDocument(pmid: "1", score: 5),
        createDocument(pmid: "2", score: 10),
        createDocument(pmid: "3", score: 3),
    ]

    let sorted = docs.sorted(by: .scoreHighToLow)
    XCTAssertEqual(sorted.map { $0.pmid }, ["2", "1", "3"])
}

// AccessibilityTests.swift
func testErrorQueueAccessibility() throws {
    let app = XCUIApplication()
    app.launch()

    // Verify error queue is accessible
    let errorQueue = app.otherElements["Error queue with 3 errors"]
    XCTAssertTrue(errorQueue.exists)

    // Verify expand button has proper label
    let expandButton = errorQueue.buttons["Expand error list"]
    XCTAssertTrue(expandButton.exists)
}
```

## Acceptance Criteria

- [ ] Error queue hidden when empty
- [ ] Error queue appears when first error occurs
- [ ] Errors show PMID, step, message, and category
- [ ] Error categorization correctly identifies network/LLM/parsing/timeout errors
- [ ] Category filter chips allow filtering by error type
- [ ] "Retry All" button re-queues failed documents
- [ ] "Clear" button dismisses errors
- [ ] Errors persist across app restarts (SwiftData)
- [ ] Sort dropdown available after processing
- [ ] Sorting updates document card order immediately
- [ ] Sort preference persisted via @AppStorage
- [ ] All interactive elements have accessibility labels
- [ ] VoiceOver correctly reads error counts and categories
- [ ] Error cards announce full details when focused
