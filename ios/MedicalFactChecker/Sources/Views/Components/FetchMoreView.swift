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

// MARK: - Constants

/// Constants for fetch more view UI.
private enum FetchMoreConstants {
    /// Default batch size for fetching.
    static let defaultBatchSize = 20

    /// Minimum documents to fetch.
    static let minBatchSize = 5

    /// Maximum documents to fetch.
    static let maxBatchSize = 50

    /// Step size for batch stepper.
    static let batchStepSize = 5

    /// Scale for button progress spinner.
    static let buttonProgressScale: CGFloat = 0.8

    /// Corner radius for the main container.
    static let containerCornerRadius: CGFloat = 12

    /// Corner radius for the button.
    static let buttonCornerRadius: CGFloat = 10
}

/// View for fetching additional documents from search providers.
///
/// Displayed after an initial search completes, allowing users to
/// fetch more results from the same or different providers.
struct FetchMoreView: View {
    /// The current fact-check session.
    let session: FactCheckSession

    /// Callback when user requests more documents.
    let onFetchMore: (SearchOptions) -> Void

    /// Whether fetching is currently in progress.
    let isFetching: Bool

    /// Search options for the additional fetch.
    @State private var fetchOptions: SearchOptions

    /// Whether the options panel is expanded.
    @State private var showOptions = false

    /// Initialize with session and callbacks.
    ///
    /// - Parameters:
    ///   - session: The current fact-check session.
    ///   - onFetchMore: Callback when fetch is requested.
    ///   - isFetching: Whether fetching is in progress.
    ///   - defaultOptions: Default search options to use.
    init(
        session: FactCheckSession,
        onFetchMore: @escaping (SearchOptions) -> Void,
        isFetching: Bool,
        defaultOptions: SearchOptions = .defaults(for: .pubmed)
    ) {
        self.session = session
        self.onFetchMore = onFetchMore
        self.isFetching = isFetching
        self._fetchOptions = State(initialValue: defaultOptions)
    }

    var body: some View {
        VStack(spacing: 16) {
            // Status header
            statusHeader

            // Provider options
            if showOptions {
                providerOptionsSection
            }

            // Fetch button
            fetchButton
        }
        .padding()
        .background(backgroundGradient)
        .cornerRadius(FetchMoreConstants.containerCornerRadius)
    }

    // MARK: - Subviews

    /// Header showing current search status.
    private var statusHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: "doc.text.magnifyingglass")
                    .foregroundColor(.accentColor)

                Text("Need More Evidence?")
                    .font(.headline)

                Spacer()

                Button(action: { withAnimation { showOptions.toggle() } }) {
                    Image(systemName: showOptions ? "chevron.up" : "gearshape")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(isFetching)
            }

            // Current results summary
            resultsSummary
        }
    }

    /// Summary of current search results.
    private var resultsSummary: some View {
        HStack(spacing: 16) {
            statItem(
                value: "\(session.documentsFound)",
                label: "Found"
            )

            statItem(
                value: "\(session.relevantDocumentsFound)",
                label: "Relevant"
            )

            if session.remainingPubMedResults > 0 {
                statItem(
                    value: "\(session.remainingPubMedResults)",
                    label: "More Available"
                )
            }
        }
        .font(.caption)
        .foregroundColor(.secondary)
    }

    /// Provider and batch size options.
    private var providerOptionsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Divider()

            // Provider selection
            Text("Search Provider")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Provider", selection: $fetchOptions.provider) {
                ForEach(SearchProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isFetching)

            // Batch size
            HStack {
                Text("Documents to fetch:")
                    .font(.caption)

                Spacer()

                Stepper(
                    "\(fetchOptions.maxResults)",
                    value: $fetchOptions.maxResults,
                    in: FetchMoreConstants.minBatchSize...FetchMoreConstants.maxBatchSize,
                    step: FetchMoreConstants.batchStepSize
                )
                .disabled(isFetching)
            }

            // Preprints toggle (Europe PMC only)
            if fetchOptions.provider == .europePMC || fetchOptions.provider == .both {
                Toggle("Include preprints", isOn: $fetchOptions.includePreprints)
                    .font(.caption)
                    .disabled(isFetching)
            }
        }
    }

    /// Main fetch button.
    private var fetchButton: some View {
        Button(action: { onFetchMore(fetchOptions) }) {
            HStack {
                if isFetching {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .scaleEffect(FetchMoreConstants.buttonProgressScale)
                } else {
                    Image(systemName: "arrow.down.doc")
                }

                Text(isFetching ? "Fetching..." : "Fetch More Documents")
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(isFetching ? Color.gray : Color.accentColor)
            .foregroundColor(.white)
            .cornerRadius(FetchMoreConstants.buttonCornerRadius)
        }
        .disabled(isFetching)
    }

    /// Background gradient for the view.
    private var backgroundGradient: some View {
        LinearGradient(
            colors: [
                Color.accentColor.opacity(0.05),
                Color.accentColor.opacity(0.1)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    // MARK: - Helpers

    /// Create a stat item with value and label.
    ///
    /// - Parameters:
    ///   - value: The numeric value to display.
    ///   - label: The label below the value.
    /// - Returns: A styled stat item view.
    private func statItem(value: String, label: String) -> some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.headline)
                .fontWeight(.semibold)
            Text(label)
                .font(.caption2)
        }
    }
}

// MARK: - Preview

#Preview {
    let session = FactCheckSession(claim: "Test claim")
    session.documentsFound = 25
    session.relevantDocumentsFound = 8
    session.totalPubMedResults = 150

    return FetchMoreView(
        session: session,
        onFetchMore: { options in
            print("Fetching with options: \(options)")
        },
        isFetching: false
    )
    .padding()
}
