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
