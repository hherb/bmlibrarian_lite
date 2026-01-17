// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

/// Compact search options view for configuring search provider.
///
/// Displays a simple dropdown picker for selecting the search provider
/// (PubMed, Europe PMC, or both) and a preprint toggle when applicable.
/// Designed for minimal screen real estate usage on mobile devices.
struct SearchOptionsView: View {
    /// Current search options being configured.
    @Binding var options: SearchOptions

    /// Whether search is currently running (disables editing).
    let isDisabled: Bool

    /// Initialize with options binding and optional disabled state.
    ///
    /// - Parameters:
    ///   - options: Binding to the search options.
    ///   - isDisabled: Whether editing is disabled (e.g., during search).
    init(options: Binding<SearchOptions>, isDisabled: Bool = false) {
        self._options = options
        self.isDisabled = isDisabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Provider dropdown
            HStack {
                Text("Search")
                    .font(.subheadline)
                    .foregroundColor(.secondary)

                Spacer()

                Picker("Provider", selection: $options.provider) {
                    ForEach(SearchProvider.allCases) { provider in
                        Text(provider.displayName).tag(provider)
                    }
                }
                .pickerStyle(.menu)
                .disabled(isDisabled)
                .accessibilityLabel("Search Provider")
                .accessibilityHint("Select which database to search for medical literature")
            }

            // Preprint toggle (only for Europe PMC or Both)
            if options.provider.supportsPreprints {
                Toggle("Include Preprints", isOn: $options.includePreprints)
                    .font(.subheadline)
                    .disabled(isDisabled)
                    .accessibilityHint("Include non-peer-reviewed articles from Europe PMC")
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }
}

// MARK: - Preview

#Preview {
    @Previewable @State var options = SearchOptions.defaults(for: .pubmed)

    VStack(spacing: 20) {
        SearchOptionsView(options: $options)

        // Show current state
        VStack(alignment: .leading) {
            Text("Current Options:")
                .font(.headline)
            Text("Provider: \(options.provider.displayName)")
            Text("Include Preprints: \(options.includePreprints ? "Yes" : "No")")
        }
        .padding()
    }
    .padding()
}
