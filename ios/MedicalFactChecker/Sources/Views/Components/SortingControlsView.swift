#if os(iOS)
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

// MARK: - Sort Option

/// Available sort options for document lists.
///
/// Each option defines both the display name and an accessibility
/// description for VoiceOver users.
enum SortOption: String, CaseIterable, Codable {
    case scoreHighToLow = "Score (High to Low)"
    case scoreLowToHigh = "Score (Low to High)"
    case titleAZ = "Title (A-Z)"
    case titleZA = "Title (Z-A)"
    case yearNewest = "Year (Newest First)"
    case yearOldest = "Year (Oldest First)"

    /// Detailed description for accessibility.
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

    /// SF Symbol icon for this sort option.
    var icon: String {
        switch self {
        case .scoreHighToLow: return "arrow.down.circle"
        case .scoreLowToHigh: return "arrow.up.circle"
        case .titleAZ: return "textformat.abc"
        case .titleZA: return "textformat.abc"
        case .yearNewest: return "calendar"
        case .yearOldest: return "calendar"
        }
    }
}

// MARK: - Sorting Controls View

/// A picker control for selecting document sort order.
///
/// Displays a dropdown menu with all available sort options and
/// persists the selection using `@AppStorage`.
///
/// ## Accessibility
///
/// The control provides accessibility labels for both the picker
/// and individual options, ensuring VoiceOver users can understand
/// the current sort state.
///
/// ## Usage
///
/// ```swift
/// @State var sortOption: SortOption = .scoreHighToLow
///
/// SortingControlsView(selectedSort: $sortOption)
/// ```
struct SortingControlsView: View {
    /// Binding to the currently selected sort option.
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

// MARK: - Compact Sorting Controls

/// A compact sorting control for toolbar or header use.
///
/// Shows the current sort option with an icon, tapping reveals
/// the full picker menu.
struct CompactSortingControlsView: View {
    /// Binding to the currently selected sort option.
    @Binding var selectedSort: SortOption

    var body: some View {
        Menu {
            ForEach(SortOption.allCases, id: \.self) { option in
                Button {
                    selectedSort = option
                } label: {
                    Label(option.rawValue, systemImage: option.icon)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "arrow.up.arrow.down")
                Text("Sort")
                    .font(.caption)
            }
        }
        .accessibilityLabel("Sort order: \(selectedSort.accessibilityDescription)")
        .accessibilityHint("Tap to change sort order")
    }
}

// MARK: - Sortable Document Protocol

/// Protocol for documents that can be sorted by score, title, or year.
///
/// Implement this protocol on document models to enable sorting
/// using the `sorted(by:)` array extension.
protocol SortableDocument {
    /// Relevance score (1-5 scale), or nil if not scored.
    var score: Int? { get }

    /// Document title for alphabetical sorting.
    var sortableTitle: String? { get }

    /// Publication year for chronological sorting.
    var year: Int? { get }
}

// MARK: - Array Sorting Extension

extension Array where Element: SortableDocument {
    /// Sort documents by the specified option.
    ///
    /// Documents with nil values for the sort key are placed at the end
    /// of the result.
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
            return sorted {
                ($0.sortableTitle ?? "").localizedCaseInsensitiveCompare($1.sortableTitle ?? "") == .orderedAscending
            }
        case .titleZA:
            return sorted {
                ($0.sortableTitle ?? "").localizedCaseInsensitiveCompare($1.sortableTitle ?? "") == .orderedDescending
            }
        case .yearNewest:
            return sorted { ($0.year ?? 0) > ($1.year ?? 0) }
        case .yearOldest:
            return sorted { ($0.year ?? 0) < ($1.year ?? 0) }
        }
    }
}

// MARK: - Document Conformance

/// Extension to make Document conform to SortableDocument.
///
/// This enables using the `sorted(by:)` extension on arrays of Document.
extension Document: SortableDocument {
    /// Returns the LLM relevance score.
    var score: Int? { relevanceScore }

    /// Returns the document title as optional for protocol conformance.
    ///
    /// The Document model has a non-optional `title: String` property,
    /// but the protocol requires `String?` for generic sorting support.
    var sortableTitle: String? { title }
}

// MARK: - Preview

#Preview("Sorting Controls") {
    struct PreviewWrapper: View {
        @State var sortOption: SortOption = .scoreHighToLow

        var body: some View {
            VStack(spacing: 20) {
                SortingControlsView(selectedSort: $sortOption)

                Divider()

                HStack {
                    Text("Compact:")
                    CompactSortingControlsView(selectedSort: $sortOption)
                }
                .padding()

                Divider()

                Text("Selected: \(sortOption.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
        }
    }

    return PreviewWrapper()
}

#endif // os(iOS)
