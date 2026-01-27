// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.

import SwiftUI

// MARK: - Constants

/// Constants for error queue view layout and animation.
private enum ErrorQueueConstants {
    /// Maximum height for the scrollable error list.
    static let maxListHeight: CGFloat = 200

    /// Duration for expand/collapse animation.
    static let animationDuration: Double = 0.2

    /// Opacity for error card backgrounds.
    static let cardBackgroundOpacity: Double = 0.05

    /// Opacity for error card borders.
    static let cardBorderOpacity: Double = 0.2

    /// Corner radius for cards and buttons.
    static let cornerRadius: CGFloat = 8

    /// Corner radius for the error queue container.
    static let containerCornerRadius: CGFloat = 12

    /// Opacity for header background.
    static let headerBackgroundOpacity: Double = 0.1
}

// MARK: - Error Queue View

/// Displays a collapsible list of processing errors with filtering and retry support.
///
/// Features:
/// - Collapsible header showing error count
/// - Category filter chips for filtering by error type
/// - Individual error cards with PMID, step, and message
/// - "Retry All" and "Clear" actions
/// - Full accessibility support
///
/// ## Usage
///
/// ```swift
/// @State var errors: [TransientErrorEntry] = []
///
/// ErrorQueueView(errors: $errors) { pmids in
///     // Retry failed documents
///     await workflow.retryDocuments(pmids: pmids)
/// }
/// ```
struct ErrorQueueView: View {
    /// Binding to the array of errors to display.
    @Binding var errors: [TransientErrorEntry]

    /// Whether the error list is expanded.
    @State private var isExpanded = false

    /// Currently selected category filter (nil = show all).
    @State private var selectedCategory: ErrorCategory?

    /// Callback invoked when user requests retry for PMIDs.
    var onRetry: ([String]) -> Void

    // MARK: - Computed Properties

    /// Errors filtered by the selected category.
    private var filteredErrors: [TransientErrorEntry] {
        guard let category = selectedCategory else { return errors }
        return errors.filter { $0.category == category }
    }

    /// Error counts grouped by category for filter chips.
    private var errorCountsByCategory: [ErrorCategory: Int] {
        Dictionary(grouping: errors, by: \.category)
            .mapValues { $0.count }
    }

    // MARK: - Body

    var body: some View {
        if !errors.isEmpty {
            VStack(spacing: 0) {
                // Header with expand/collapse and actions
                headerView

                // Category filter chips
                if isExpanded {
                    categoryFilterView
                }

                // Scrollable error list
                if isExpanded {
                    errorListView
                }
            }
            .background(Color(.systemBackground))
            .cornerRadius(ErrorQueueConstants.containerCornerRadius)
            .shadow(radius: 2)
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error queue with \(errors.count) errors")
        }
    }

    // MARK: - Header View

    /// Header showing error count, retry/clear buttons, and expand toggle.
    private var headerView: some View {
        HStack {
            // Error count label
            Label("Errors (\(errors.count))", systemImage: "exclamationmark.triangle")
                .foregroundColor(.red)
                .font(.headline)
                .accessibilityLabel("\(errors.count) errors occurred during processing")

            Spacer()

            // Retry All button
            Button("Retry All") {
                let pmids = errors.map { $0.pmid }
                onRetry(pmids)
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .accessibilityHint("Retry processing all failed documents")

            // Clear button
            Button("Clear") {
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Dismiss all errors without retrying")

            // Expand/collapse toggle
            Button {
                withAnimation(.easeInOut(duration: ErrorQueueConstants.animationDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .accessibilityLabel(isExpanded ? "Collapse error list" : "Expand error list")
            .accessibilityHint(isExpanded ? "Hide error details" : "Show error details")
        }
        .padding()
        .background(Color.red.opacity(ErrorQueueConstants.headerBackgroundOpacity))
        .cornerRadius(ErrorQueueConstants.cornerRadius)
    }

    // MARK: - Category Filter View

    /// Horizontal scrolling row of category filter chips.
    private var categoryFilterView: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                // "All" filter chip
                CategoryFilterChip(
                    title: "All",
                    count: errors.count,
                    isSelected: selectedCategory == nil,
                    color: .gray
                ) {
                    selectedCategory = nil
                }

                // Category-specific filter chips
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

    // MARK: - Error List View

    /// Scrollable list of error cards.
    private var errorListView: some View {
        ScrollView {
            LazyVStack(spacing: 8) {
                ForEach(filteredErrors) { error in
                    ErrorCardView(error: error)
                }
            }
            .padding()
        }
        .frame(maxHeight: ErrorQueueConstants.maxListHeight)
        .background(Color(.systemBackground))
    }
}

// MARK: - Category Filter Chip

/// A selectable chip for filtering errors by category.
///
/// Displays the category name and count, with visual feedback for selection state.
struct CategoryFilterChip: View {
    /// Display title for the chip.
    let title: String

    /// Number of errors in this category.
    let count: Int

    /// Whether this chip is currently selected.
    let isSelected: Bool

    /// Color theme for the chip.
    let color: Color

    /// Action to perform when tapped.
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

// MARK: - Error Card View

/// A card displaying details for a single error.
///
/// Shows the PMID, processing step, error category, and message.
/// Designed for compact display in a scrollable list.
struct ErrorCardView: View {
    /// The error entry to display.
    let error: TransientErrorEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            // Header row with icon, PMID, step, and category badge
            HStack {
                Image(systemName: error.category.icon)
                    .foregroundColor(error.category.color)
                    .accessibilityHidden(true)

                Text("PMID: \(error.pmid)")
                    .font(.caption.bold())

                Text("(\(error.step))")
                    .font(.caption)
                    .foregroundColor(.secondary)

                Spacer()

                // Category badge
                Text(error.category.rawValue)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(error.category.color.opacity(0.2))
                    .cornerRadius(4)
            }

            // Error message
            Text(error.message)
                .font(.caption)
                .foregroundColor(.secondary)
                .lineLimit(2)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(ErrorQueueConstants.cardBackgroundOpacity))
        .cornerRadius(ErrorQueueConstants.cornerRadius)
        .overlay(
            RoundedRectangle(cornerRadius: ErrorQueueConstants.cornerRadius)
                .stroke(Color.red.opacity(ErrorQueueConstants.cardBorderOpacity), lineWidth: 1)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Error for PMID \(error.pmid), \(error.category.rawValue) error during \(error.step): \(error.message)"
        )
    }
}

// MARK: - Compact Error Queue View

/// A compact version of the error queue for inline display.
///
/// Shows only the error count and a retry button, suitable for
/// embedding in headers or toolbars.
struct CompactErrorQueueView: View {
    /// The errors to summarize.
    let errors: [TransientErrorEntry]

    /// Callback for retry action.
    var onRetry: ([String]) -> Void

    /// Callback when tapped to show full queue.
    var onShowDetails: () -> Void

    var body: some View {
        if !errors.isEmpty {
            Button(action: onShowDetails) {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                    Text("\(errors.count) failed")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            .accessibilityLabel("\(errors.count) documents failed processing. Tap to view details.")
        }
    }
}

// MARK: - Preview

#Preview("Error Queue") {
    struct PreviewWrapper: View {
        @State var errors: [TransientErrorEntry] = [
            TransientErrorEntry(
                pmid: "12345678",
                step: "scoring",
                message: "Network connection failed"
            ),
            TransientErrorEntry(
                pmid: "23456789",
                step: "scoring",
                message: "LLM rate limit exceeded"
            ),
            TransientErrorEntry(
                pmid: "34567890",
                step: "citation",
                message: "JSON parsing error: unexpected token"
            ),
            TransientErrorEntry(
                pmid: "45678901",
                step: "scoring",
                message: "Request timed out after 30 seconds"
            ),
            TransientErrorEntry(
                pmid: "56789012",
                step: "scoring",
                message: "Unknown error occurred"
            ),
        ]

        var body: some View {
            VStack {
                ErrorQueueView(errors: $errors) { pmids in
                    print("Retry requested for: \(pmids)")
                }
                .padding()

                Spacer()
            }
        }
    }

    return PreviewWrapper()
}

#Preview("Error Card") {
    let error = TransientErrorEntry(
        pmid: "12345678",
        step: "scoring",
        message: "Network connection failed after 3 retry attempts"
    )

    return ErrorCardView(error: error)
        .padding()
}
