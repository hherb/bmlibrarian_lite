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

#endif // os(macOS)
