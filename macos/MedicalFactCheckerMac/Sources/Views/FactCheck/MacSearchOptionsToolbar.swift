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

// MARK: - Search Options Inline View

/// Inline search options view displayed next to the search button.
///
/// Provides a compact picker for search provider selection and a toggle
/// for including preprints (only enabled when Europe PMC is available).
struct MacSearchOptionsInline: View {
    /// The currently selected search provider.
    @Binding var selectedProvider: SearchProvider

    /// Whether to include preprints in the search.
    @Binding var includePreprints: Bool

    var body: some View {
        HStack(spacing: MacSpacing.medium) {
            // Provider picker
            Picker("Search", selection: $selectedProvider) {
                ForEach(SearchProvider.allCases) { provider in
                    Label(provider.displayName, systemImage: provider.iconName)
                        .tag(provider)
                }
            }
            .pickerStyle(.menu)
            .frame(width: MacLayout.filterPickerWideWidth)
            .help("Select search provider")
            .accessibilityLabel("Search provider")
            .accessibilityHint("Choose which database to search")

            // Preprint toggle
            Toggle(isOn: $includePreprints) {
                Label("Preprints", systemImage: "doc.badge.clock")
            }
            .toggleStyle(.checkbox)
            .disabled(!selectedProvider.supportsPreprints)
            .help(preprintToggleHelp)
            .accessibilityLabel("Include preprints")
            .accessibilityHint(preprintAccessibilityHint)
        }
    }

    /// Help text for the preprint toggle based on provider selection.
    private var preprintToggleHelp: String {
        if selectedProvider.supportsPreprints {
            return "Include preprints from bioRxiv, medRxiv, and other servers"
        } else {
            return "Preprints only available with Europe PMC"
        }
    }

    /// Accessibility hint for the preprint toggle.
    private var preprintAccessibilityHint: String {
        if selectedProvider.supportsPreprints {
            return "When enabled, search includes non-peer-reviewed preprints from bioRxiv, medRxiv, and other servers"
        } else {
            return "Select Europe PMC or Both providers to enable preprint search"
        }
    }
}

// MARK: - Provider Badge

/// Badge showing which provider a document came from.
///
/// Displays a compact badge with the provider's icon and short name,
/// styled with the provider's associated color.
struct MacProviderBadge: View {
    /// The search provider to display, or nil if unknown.
    let provider: SearchProvider?

    var body: some View {
        if let provider = provider {
            HStack(spacing: MacSpacing.xxSmall) {
                Image(systemName: provider.iconName)
                    .font(.caption2)
                Text(provider.shortName)
                    .font(.caption2)
            }
            .foregroundColor(badgeColor)
            .padding(.horizontal, MacSpacing.small)
            .padding(.vertical, MacSpacing.xxSmall)
            .background(badgeColor.opacity(MacOpacity.badgeBackground))
            .cornerRadius(MacCornerRadius.small)
            .accessibilityLabel("Document from \(provider.displayName)")
        }
    }

    /// The color for the badge based on the provider.
    private var badgeColor: Color {
        guard let provider = provider else { return .gray }
        return MacProviderColors.color(for: provider)
    }
}

// MARK: - SearchProvider Extension

extension SearchProvider {
    /// Short name for compact badge display.
    ///
    /// Returns abbreviated names suitable for UI badges:
    /// - PubMed → "PM"
    /// - Europe PMC → "EPMC"
    /// - Both → "Both"
    var shortName: String {
        switch self {
        case .pubmed: return "PM"
        case .europePMC: return "EPMC"
        case .both: return "Both"
        }
    }
}

// MARK: - Preview

#Preview("Search Options Inline") {
    @Previewable @State var provider: SearchProvider = .pubmed
    @Previewable @State var preprints = false

    VStack(spacing: MacSpacing.xLarge) {
        MacSearchOptionsInline(
            selectedProvider: $provider,
            includePreprints: $preprints
        )

        Divider()

        Text("Selected: \(provider.displayName)")
        Text("Preprints: \(preprints ? "Yes" : "No")")
    }
    .padding()
    .frame(width: 400)
}

#Preview("Provider Badges") {
    VStack(spacing: MacSpacing.large) {
        MacProviderBadge(provider: .pubmed)
        MacProviderBadge(provider: .europePMC)
        MacProviderBadge(provider: .both)
        MacProviderBadge(provider: nil)
    }
    .padding()
}
