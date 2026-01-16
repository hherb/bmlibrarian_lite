//
//  FullTextSourceBadge.swift
//  MedicalFactChecker
//
//  Badge displaying the source of full text.
//

import SwiftUI

// MARK: - Constants

/// Constants for the source badge UI.
private enum SourceBadgeConstants {
    /// Horizontal padding inside the badge.
    static let horizontalPadding: CGFloat = 6

    /// Vertical padding inside the badge.
    static let verticalPadding: CGFloat = 2

    /// Corner radius for the badge background.
    static let cornerRadius: CGFloat = 4

    /// Opacity for the background color.
    static let backgroundOpacity: Double = 0.15
}

// MARK: - Full Text Source Badge

/// Small badge showing where full text came from.
///
/// Displays an icon and text label indicating the source of the full text
/// (Europe PMC, Unpaywall, Publisher, or Cached).
struct FullTextSourceBadge: View {
    /// The source to display.
    let source: FullTextSource

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.iconName)
                .font(.caption2)
            Text(source.displayName)
                .font(.caption2)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, SourceBadgeConstants.horizontalPadding)
        .padding(.vertical, SourceBadgeConstants.verticalPadding)
        .background(badgeColor.opacity(SourceBadgeConstants.backgroundOpacity))
        .cornerRadius(SourceBadgeConstants.cornerRadius)
        .accessibilityLabel("Full text from \(source.displayName)")
    }

    /// Color for the badge based on the source.
    private var badgeColor: Color {
        switch source {
        case .europePMC: return .blue
        case .unpaywall: return .green
        case .doi: return .orange
        case .cached: return .gray
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 8) {
        FullTextSourceBadge(source: .europePMC)
        FullTextSourceBadge(source: .unpaywall)
        FullTextSourceBadge(source: .doi)
        FullTextSourceBadge(source: .cached)
    }
    .padding()
}
