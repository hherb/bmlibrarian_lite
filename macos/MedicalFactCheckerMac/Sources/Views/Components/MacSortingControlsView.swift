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

// MARK: - Mac Sorting Controls View

/// macOS-styled picker control for selecting document sort order.
struct MacSortingControlsView: View {
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
            .frame(width: 180)
            .accessibilityLabel("Sort order")
            .accessibilityValue(selectedSort.accessibilityDescription)
        }
    }
}

// MARK: - Sortable Document Protocol

/// Protocol for documents that can be sorted by score, title, or year.
protocol SortableDocument {
    /// Relevance score (1-5 scale), or nil if not scored.
    var score: Int? { get }

    /// Document title for alphabetical sorting.
    var title: String? { get }

    /// Publication year for chronological sorting.
    var year: Int? { get }
}

// MARK: - Array Sorting Extension

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
            return sorted {
                ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedAscending
            }
        case .titleZA:
            return sorted {
                ($0.title ?? "").localizedCaseInsensitiveCompare($1.title ?? "") == .orderedDescending
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
extension Document: SortableDocument {
    /// Returns the LLM relevance score.
    var score: Int? { relevanceScore }
}

// MARK: - Preview

#Preview("Mac Sorting Controls") {
    struct PreviewWrapper: View {
        @State var sortOption: SortOption = .scoreHighToLow

        var body: some View {
            VStack(spacing: 20) {
                MacSortingControlsView(selectedSort: $sortOption)

                Text("Selected: \(sortOption.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .frame(width: 300)
        }
    }

    return PreviewWrapper()
}
