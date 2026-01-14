//
//  DocumentSourceBadge.swift
//  MedicalFactChecker
//
//  Badge indicating the source of a document (PubMed, Europe PMC).
//

import SwiftUI

/// Badge showing the search provider source of a document.
///
/// Displays a small colored badge with the provider name, helping users
/// identify which search provider returned each document.
struct DocumentSourceBadge: View {
    /// The source provider for the document.
    let provider: SearchProvider

    /// Whether the document is a preprint.
    let isPreprint: Bool

    /// Initialize with provider and preprint status.
    ///
    /// - Parameters:
    ///   - provider: The search provider.
    ///   - isPreprint: Whether the document is a preprint.
    init(provider: SearchProvider, isPreprint: Bool = false) {
        self.provider = provider
        self.isPreprint = isPreprint
    }

    var body: some View {
        HStack(spacing: 4) {
            // Provider icon
            Image(systemName: provider.iconName)
                .font(.system(size: 8))

            // Provider abbreviation
            Text(abbreviation)
                .font(.system(size: 9, weight: .medium))

            // Preprint indicator
            if isPreprint {
                Text("PPR")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Color.orange)
                    .cornerRadius(3)
            }
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(badgeColor.opacity(0.12))
        .cornerRadius(4)
    }

    // MARK: - Private Properties

    /// Abbreviated provider name for the badge.
    private var abbreviation: String {
        switch provider {
        case .pubmed:
            return "PM"
        case .europePMC:
            return "EPMC"
        case .both:
            return "Both"
        }
    }

    /// Color for the badge based on provider.
    private var badgeColor: Color {
        switch provider {
        case .pubmed:
            return .blue
        case .europePMC:
            return .green
        case .both:
            return .purple
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        DocumentSourceBadge(provider: .pubmed)
        DocumentSourceBadge(provider: .europePMC)
        DocumentSourceBadge(provider: .europePMC, isPreprint: true)
        DocumentSourceBadge(provider: .both)
    }
    .padding()
}
