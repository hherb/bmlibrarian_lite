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

/// View for fetching more documents with provider selection.
///
/// Displays information about remaining documents available from each provider
/// and provides buttons to fetch additional results. When using "Both" provider
/// mode, allows fetching from specific providers individually.
struct MacFetchMoreView: View {
    /// The current fact-check session.
    let session: FactCheckSession

    /// Callback when user requests more documents.
    ///
    /// - Parameter provider: The specific provider to fetch from, or nil for all active providers.
    let onFetchMore: (SearchProvider?) -> Void

    var body: some View {
        VStack(spacing: MacSpacing.medium) {
            HStack(spacing: MacSpacing.large) {
                // Status text
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text("Need more evidence?")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    Text(statusText)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Spacer()

                // Fetch buttons
                fetchButtons
            }
        }
        .padding(MacSpacing.standard)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Fetch more documents")
    }

    // MARK: - Computed Properties

    /// Whether the session used both providers (merged mode).
    private var usedBothProviders: Bool {
        session.searchProvider == SearchProvider.both.rawValue
    }

    /// Status text describing available documents from each provider.
    private var statusText: String {
        if !session.canFetchMoreFromAnyProvider {
            return "All available documents have been retrieved"
        }

        var parts: [String] = []
        if session.pubmedHasMore && (usedBothProviders || session.searchProvider == SearchProvider.pubmed.rawValue) {
            parts.append("PubMed has more")
        }
        if session.europePMCHasMore && (usedBothProviders || session.searchProvider == SearchProvider.europePMC.rawValue) {
            parts.append("Europe PMC has more")
        }

        return parts.isEmpty ? "No additional documents available" : parts.joined(separator: ", ")
    }

    // MARK: - Subviews

    /// Fetch buttons appropriate for the current provider mode.
    @ViewBuilder
    private var fetchButtons: some View {
        if usedBothProviders {
            providerPickerButtons
        } else {
            Button(action: { onFetchMore(nil) }) {
                Label("Fetch More", systemImage: "arrow.down.circle")
            }
            .buttonStyle(.bordered)
            .disabled(!session.canFetchMoreFromAnyProvider)
        }
    }

    /// Buttons for fetching from specific providers when in merged mode.
    private var providerPickerButtons: some View {
        HStack(spacing: MacSpacing.small) {
            if session.pubmedHasMore {
                Button(action: { onFetchMore(.pubmed) }) {
                    Label("PubMed", systemImage: SearchProvider.pubmed.iconName)
                }
                .buttonStyle(.bordered)
                .tint(MacProviderColors.pubmed)
            }

            if session.europePMCHasMore {
                Button(action: { onFetchMore(.europePMC) }) {
                    Label("Europe PMC", systemImage: SearchProvider.europePMC.iconName)
                }
                .buttonStyle(.bordered)
                .tint(MacProviderColors.europePMC)
            }

            Button(action: { onFetchMore(nil) }) {
                Label("Both", systemImage: SearchProvider.both.iconName)
            }
            .buttonStyle(.borderedProminent)
            .tint(MacProviderColors.both)
            .disabled(!session.pubmedHasMore && !session.europePMCHasMore)
        }
    }
}

// MARK: - Preview

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    session.searchProvider = SearchProvider.both.rawValue
    session.pubmedHasMore = true
    session.europePMCHasMore = true

    return MacFetchMoreView(session: session) { provider in
        print("Fetch from: \(provider?.displayName ?? "all")")
    }
    .frame(width: 500)
    .padding()
}

#Preview("PubMed Only") {
    let session = FactCheckSession(claim: "Test claim")
    session.searchProvider = SearchProvider.pubmed.rawValue
    session.pubmedHasMore = true

    return MacFetchMoreView(session: session) { provider in
        print("Fetch from: \(provider?.displayName ?? "all")")
    }
    .frame(width: 500)
    .padding()
}

#Preview("No More Available") {
    let session = FactCheckSession(claim: "Test claim")
    session.searchProvider = SearchProvider.both.rawValue
    session.pubmedHasMore = false
    session.europePMCHasMore = false

    return MacFetchMoreView(session: session) { _ in }
    .frame(width: 500)
    .padding()
}
