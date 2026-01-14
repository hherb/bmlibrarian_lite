//
//  SearchOptionsView.swift
//  MedicalFactChecker
//
//  Collapsible search options panel for provider selection.
//

import SwiftUI

// MARK: - Constants

/// Constants for search options UI.
private enum SearchOptionsConstants {
    /// Default expansion state.
    static let defaultExpanded = false

    /// Animation duration for expansion toggle.
    static let animationDuration: Double = 0.2
}

/// Collapsible panel for configuring search options before running a fact-check.
///
/// Allows users to select the search provider (PubMed, Europe PMC, or both)
/// and configure provider-specific options like preprint inclusion.
struct SearchOptionsView: View {
    /// Current search options being configured.
    @Binding var options: SearchOptions

    /// Whether the panel is expanded.
    @State private var isExpanded = SearchOptionsConstants.defaultExpanded

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
            // Header with toggle
            headerButton

            // Expanded content
            if isExpanded {
                expandedContent
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.05))
        .cornerRadius(10)
    }

    // MARK: - Subviews

    /// Header button that toggles expansion.
    private var headerButton: some View {
        Button(action: toggleExpanded) {
            HStack {
                Image(systemName: "slider.horizontal.3")
                    .foregroundColor(.accentColor)

                Text("Search Options")
                    .font(.subheadline)
                    .fontWeight(.medium)

                Spacer()

                // Show current provider as badge when collapsed
                if !isExpanded {
                    providerBadge(for: options.provider)
                }

                Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }

    /// Expanded content showing all options.
    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: 16) {
            Divider()

            // Provider selection
            providerSection

            // Provider-specific options
            if options.provider == .europePMC || options.provider == .both {
                preprintToggle
            }

            // Help text
            providerHelpText
        }
    }

    /// Provider selection picker.
    private var providerSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Search Provider")
                .font(.caption)
                .foregroundColor(.secondary)

            Picker("Provider", selection: $options.provider) {
                ForEach(SearchProvider.allCases) { provider in
                    HStack {
                        providerIcon(for: provider)
                        Text(provider.displayName)
                    }
                    .tag(provider)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isDisabled)
        }
    }

    /// Toggle for including preprints (Europe PMC only).
    private var preprintToggle: some View {
        Toggle(isOn: $options.includePreprints) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Include Preprints")
                    .font(.subheadline)
                Text("Show non-peer-reviewed articles from Europe PMC")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .disabled(isDisabled)
    }

    /// Help text explaining the selected provider.
    private var providerHelpText: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "info.circle")
                .foregroundColor(.secondary)
                .font(.caption)

            Text(options.provider.description)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    // MARK: - Helper Views

    /// Badge showing the provider name.
    ///
    /// - Parameter provider: The search provider.
    /// - Returns: A styled badge view.
    private func providerBadge(for provider: SearchProvider) -> some View {
        HStack(spacing: 4) {
            Image(systemName: provider.iconName)
                .font(.caption)
            Text(provider.displayName)
                .font(.caption)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(provider.themeColor.opacity(0.15))
        .foregroundColor(provider.themeColor)
        .cornerRadius(6)
    }

    // MARK: - Actions

    /// Toggle the expanded state with animation.
    private func toggleExpanded() {
        withAnimation(.easeInOut(duration: SearchOptionsConstants.animationDuration)) {
            isExpanded.toggle()
        }
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
