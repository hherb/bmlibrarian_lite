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

/// Constants for search progress view UI.
private enum SearchProgressConstants {
    /// Scale for overall progress spinner.
    static let overallProgressScale: CGFloat = 0.8

    /// Scale for inline provider progress spinner.
    static let inlineProgressScale: CGFloat = 0.6

    /// Width for provider icon frame.
    static let providerIconWidth: CGFloat = 20
}

// MARK: - Search Progress State

/// State of a search operation for progress tracking.
struct SearchProgressState: Sendable {
    /// Overall status of the search.
    enum Status: Sendable {
        case idle
        case searching
        case completed
        case failed(String)
    }

    /// Progress for an individual provider.
    struct ProviderProgress: Sendable {
        /// The search provider.
        let provider: SearchProvider

        /// Current status.
        var status: Status = .idle

        /// Number of results found.
        var resultsFound: Int = 0

        /// Progress message.
        var message: String = ""
    }

    /// Overall status.
    var status: Status = .idle

    /// Progress for each active provider.
    var providers: [ProviderProgress] = []

    /// Overall progress message.
    var message: String = ""

    /// Total results found across all providers.
    var totalResults: Int {
        providers.reduce(0) { $0 + $1.resultsFound }
    }

    /// Check if all providers have completed.
    var allCompleted: Bool {
        providers.allSatisfy { progress in
            if case .completed = progress.status { return true }
            if case .failed = progress.status { return true }
            return false
        }
    }

    /// Create initial progress state for given providers.
    ///
    /// - Parameter provider: The search provider configuration.
    /// - Returns: Initial progress state.
    static func initial(for provider: SearchProvider) -> SearchProgressState {
        var state = SearchProgressState()

        switch provider {
        case .pubmed:
            state.providers = [ProviderProgress(provider: .pubmed)]
        case .europePMC:
            state.providers = [ProviderProgress(provider: .europePMC)]
        case .both:
            state.providers = [
                ProviderProgress(provider: .pubmed),
                ProviderProgress(provider: .europePMC)
            ]
        }

        return state
    }
}

// MARK: - Search Progress View

/// Progress indicator for multi-provider search operations.
///
/// Shows individual progress for each search provider when searching
/// multiple sources simultaneously.
struct SearchProgressView: View {
    /// Current progress state.
    let progress: SearchProgressState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Overall status
            overallStatus

            // Individual provider progress
            if progress.providers.count > 1 {
                ForEach(progress.providers, id: \.provider) { providerProgress in
                    providerProgressRow(providerProgress)
                }
            }

            // Results summary
            if progress.totalResults > 0 {
                resultsSummary
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(10)
    }

    // MARK: - Subviews

    /// Overall search status header.
    private var overallStatus: some View {
        HStack(spacing: 12) {
            // Status indicator
            statusIndicator(for: progress.status)

            VStack(alignment: .leading, spacing: 4) {
                Text(statusTitle)
                    .font(.subheadline)
                    .fontWeight(.medium)

                if !progress.message.isEmpty {
                    Text(progress.message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }

            Spacer()
        }
    }

    /// Progress row for a single provider.
    ///
    /// - Parameter providerProgress: Progress state for the provider.
    /// - Returns: A row showing the provider's progress.
    private func providerProgressRow(_ providerProgress: SearchProgressState.ProviderProgress) -> some View {
        HStack(spacing: 8) {
            // Provider icon
            Image(systemName: providerProgress.provider.iconName)
                .font(.caption)
                .foregroundColor(providerColor(providerProgress))
                .frame(width: SearchProgressConstants.providerIconWidth)

            // Provider name
            Text(providerProgress.provider.displayName)
                .font(.caption)
                .foregroundColor(.secondary)

            Spacer()

            // Status
            statusBadge(for: providerProgress)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(6)
    }

    /// Summary of total results found.
    private var resultsSummary: some View {
        HStack {
            Image(systemName: "doc.text")
                .foregroundColor(.accentColor)

            Text("\(progress.totalResults) documents found")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Helper Views

    /// Status indicator (spinner, checkmark, or error).
    ///
    /// - Parameter status: The status to indicate.
    /// - Returns: An appropriate indicator view.
    @ViewBuilder
    private func statusIndicator(for status: SearchProgressState.Status) -> some View {
        switch status {
        case .idle:
            Image(systemName: "circle.dotted")
                .foregroundColor(.secondary)
        case .searching:
            ProgressView()
                .scaleEffect(SearchProgressConstants.overallProgressScale)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed:
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundColor(.red)
        }
    }

    /// Badge showing status for a provider.
    ///
    /// - Parameter providerProgress: The provider's progress.
    /// - Returns: A status badge view.
    @ViewBuilder
    private func statusBadge(for providerProgress: SearchProgressState.ProviderProgress) -> some View {
        switch providerProgress.status {
        case .idle:
            Text("Waiting")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .searching:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(SearchProgressConstants.inlineProgressScale)
                Text("Searching...")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        case .completed:
            Text("\(providerProgress.resultsFound) found")
                .font(.caption2)
                .foregroundColor(.green)
        case .failed(let error):
            Text(error)
                .font(.caption2)
                .foregroundColor(.red)
                .lineLimit(1)
        }
    }

    // MARK: - Computed Properties

    /// Title for the overall status.
    private var statusTitle: String {
        switch progress.status {
        case .idle:
            return "Ready to search"
        case .searching:
            if progress.providers.count > 1 {
                return "Searching multiple providers..."
            } else {
                return "Searching..."
            }
        case .completed:
            return "Search complete"
        case .failed(let error):
            return "Search failed: \(error)"
        }
    }

    /// Color for a provider based on its status.
    ///
    /// - Parameter providerProgress: The provider's progress.
    /// - Returns: Appropriate color for the status.
    private func providerColor(_ providerProgress: SearchProgressState.ProviderProgress) -> Color {
        switch providerProgress.status {
        case .idle:
            return .secondary
        case .searching:
            return providerProgress.provider.themeColor
        case .completed:
            return .green
        case .failed:
            return .red
        }
    }
}

// MARK: - Preview

#Preview("Searching Both") {
    var progress = SearchProgressState.initial(for: .both)
    progress.status = .searching
    progress.message = "Fetching results..."
    progress.providers[0].status = .completed
    progress.providers[0].resultsFound = 45
    progress.providers[1].status = .searching
    progress.providers[1].message = "Querying Europe PMC..."

    return SearchProgressView(progress: progress)
        .padding()
}

#Preview("Completed") {
    var progress = SearchProgressState.initial(for: .both)
    progress.status = .completed
    progress.providers[0].status = .completed
    progress.providers[0].resultsFound = 45
    progress.providers[1].status = .completed
    progress.providers[1].resultsFound = 32

    return SearchProgressView(progress: progress)
        .padding()
}
