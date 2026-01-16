//
//  MacSearchProgressView.swift
//  MedicalFactChecker
//
//  Progress indicator for multi-provider search on macOS.
//  Shows search status and document counts from each active provider.
//

import SwiftUI

/// Progress view showing search status across providers.
///
/// Displays a spinner with the current step description and, when using
/// multiple providers, shows document counts from each provider.
struct MacSearchProgressView: View {
    /// The search provider being used.
    let provider: SearchProvider

    /// Description of the current search step.
    let currentStep: String

    /// Number of documents found from PubMed.
    let pubmedCount: Int

    /// Number of documents found from Europe PMC.
    let europePMCCount: Int

    var body: some View {
        VStack(spacing: MacSpacing.large) {
            ProgressView()
                .scaleEffect(MacScale.progressViewMedium)

            Text(currentStep)
                .font(.headline)

            if provider == .both {
                providerCountsView
            }
        }
        .padding(MacSpacing.xxLarge)
        .frame(maxWidth: .infinity)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.large)
    }

    /// View showing document counts from each provider.
    private var providerCountsView: some View {
        HStack(spacing: MacSpacing.xLarge) {
            providerStatus(
                name: "PubMed",
                count: pubmedCount,
                icon: SearchProvider.pubmed.iconName,
                color: MacProviderColors.pubmed
            )
            providerStatus(
                name: "Europe PMC",
                count: europePMCCount,
                icon: SearchProvider.europePMC.iconName,
                color: MacProviderColors.europePMC
            )
        }
    }

    /// Individual provider status badge.
    ///
    /// - Parameters:
    ///   - name: The provider display name.
    ///   - count: Number of documents found.
    ///   - icon: SF Symbol name for the provider.
    ///   - color: Color for the badge.
    /// - Returns: A view displaying the provider status.
    private func providerStatus(
        name: String,
        count: Int,
        icon: String,
        color: Color
    ) -> some View {
        HStack(spacing: MacSpacing.small) {
            Image(systemName: icon)
                .foregroundColor(color)

            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("\(count) found")
                    .font(.caption)
                    .fontWeight(.medium)
            }
        }
        .padding(.horizontal, MacSpacing.standard)
        .padding(.vertical, MacSpacing.small)
        .background(color.opacity(MacOpacity.veryLight))
        .cornerRadius(MacCornerRadius.medium)
    }
}

// MARK: - Preview

#Preview("Single Provider") {
    MacSearchProgressView(
        provider: .pubmed,
        currentStep: "Searching PubMed...",
        pubmedCount: 15,
        europePMCCount: 0
    )
    .padding()
    .frame(width: 500)
}

#Preview("Both Providers") {
    MacSearchProgressView(
        provider: .both,
        currentStep: "Merging results...",
        pubmedCount: 15,
        europePMCCount: 23
    )
    .padding()
    .frame(width: 500)
}

#Preview("Europe PMC Only") {
    MacSearchProgressView(
        provider: .europePMC,
        currentStep: "Searching Europe PMC...",
        pubmedCount: 0,
        europePMCCount: 42
    )
    .padding()
    .frame(width: 500)
}
