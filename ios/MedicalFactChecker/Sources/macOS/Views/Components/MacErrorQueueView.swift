#if os(macOS)
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

/// Constants for macOS error queue view layout.
private enum MacErrorQueueConstants {
    /// Maximum height for the scrollable error list.
    static let maxListHeight: CGFloat = 250

    /// Animation duration for expand/collapse.
    static let animationDuration: Double = 0.2

    /// Opacity for error card backgrounds.
    static let cardBackgroundOpacity: Double = 0.05

    /// Corner radius for cards and buttons.
    static let cornerRadius: CGFloat = 6
}

// MARK: - Mac Error Queue View

/// macOS-styled error queue view showing processing errors.
///
/// Displays a collapsible list of errors with category filtering
/// and retry functionality.
struct MacErrorQueueView: View {
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
            GroupBox {
                VStack(spacing: 8) {
                    // Header
                    headerView

                    if isExpanded {
                        Divider()

                        // Category filters
                        categoryFilterView

                        // Error list
                        errorListView
                    }
                }
            } label: {
                Label("Errors (\(errors.count))", systemImage: "exclamationmark.triangle")
                    .foregroundColor(.red)
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Error queue with \(errors.count) errors")
        }
    }

    // MARK: - Header View

    private var headerView: some View {
        HStack {
            Spacer()

            // Retry All button
            Button("Retry All") {
                let pmids = errors.map { $0.pmid }
                onRetry(pmids)
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Retry processing all failed documents")

            // Clear button
            Button("Clear") {
                errors.removeAll()
            }
            .buttonStyle(.bordered)
            .accessibilityHint("Dismiss all errors without retrying")

            // Expand/collapse toggle
            Button {
                withAnimation(.easeInOut(duration: MacErrorQueueConstants.animationDuration)) {
                    isExpanded.toggle()
                }
            } label: {
                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(isExpanded ? "Collapse error list" : "Expand error list")
        }
    }

    // MARK: - Category Filter View

    private var categoryFilterView: some View {
        HStack(spacing: 8) {
            // "All" filter
            MacCategoryFilterChip(
                title: "All",
                count: errors.count,
                isSelected: selectedCategory == nil,
                color: .gray
            ) {
                selectedCategory = nil
            }

            // Category-specific filters
            ForEach(ErrorCategory.allCases, id: \.self) { category in
                if let count = errorCountsByCategory[category], count > 0 {
                    MacCategoryFilterChip(
                        title: category.rawValue,
                        count: count,
                        isSelected: selectedCategory == category,
                        color: category.color
                    ) {
                        selectedCategory = category
                    }
                }
            }

            Spacer()
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Error category filters")
    }

    // MARK: - Error List View

    private var errorListView: some View {
        ScrollView {
            LazyVStack(spacing: 6) {
                ForEach(filteredErrors) { error in
                    MacErrorCardView(error: error)
                }
            }
        }
        .frame(maxHeight: MacErrorQueueConstants.maxListHeight)
    }
}

// MARK: - Mac Category Filter Chip

/// A macOS-styled filter chip for error categories.
struct MacCategoryFilterChip: View {
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
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(isSelected ? color.opacity(0.2) : Color.gray.opacity(0.1))
            .foregroundColor(isSelected ? color : .secondary)
            .cornerRadius(12)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title) errors: \(count)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Mac Error Card View

/// A macOS-styled card showing a single error.
struct MacErrorCardView: View {
    let error: TransientErrorEntry

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Category icon
            Image(systemName: error.category.icon)
                .foregroundColor(error.category.color)
                .frame(width: 20)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                // Header row
                HStack {
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
                        .background(error.category.color.opacity(0.2))
                        .cornerRadius(4)
                }

                // Error message
                Text(error.message)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(Color.red.opacity(MacErrorQueueConstants.cardBackgroundOpacity))
        .cornerRadius(MacErrorQueueConstants.cornerRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Error for PMID \(error.pmid), \(error.category.rawValue) error during \(error.step): \(error.message)"
        )
    }
}

// MARK: - Preview

#Preview("Mac Error Queue") {
    struct PreviewWrapper: View {
        @State var errors: [TransientErrorEntry] = [
            TransientErrorEntry(pmid: "12345678", step: "scoring", message: "Network connection failed"),
            TransientErrorEntry(pmid: "23456789", step: "scoring", message: "LLM rate limit exceeded"),
            TransientErrorEntry(pmid: "34567890", step: "citation", message: "JSON parsing error"),
        ]

        var body: some View {
            MacErrorQueueView(errors: $errors) { pmids in
                print("Retry: \(pmids)")
            }
            .padding()
            .frame(width: 500)
        }
    }

    return PreviewWrapper()
}

#endif // os(macOS)
