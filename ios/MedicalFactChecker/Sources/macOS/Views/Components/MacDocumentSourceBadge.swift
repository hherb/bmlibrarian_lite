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

// MARK: - Constants

/// Constants for document source badge UI.
private enum DocumentSourceBadgeConstants {
    /// Font size for provider icon.
    static let iconFontSize: CGFloat = 8

    /// Font size for provider abbreviation.
    static let abbreviationFontSize: CGFloat = 9

    /// Font size for preprint label.
    static let preprintFontSize: CGFloat = 7

    /// Horizontal padding for badge.
    static let badgeHorizontalPadding: CGFloat = 6

    /// Vertical padding for badge.
    static let badgeVerticalPadding: CGFloat = 3

    /// Corner radius for badge.
    static let badgeCornerRadius: CGFloat = 4

    /// Background opacity for badge.
    static let badgeBackgroundOpacity: CGFloat = 0.12
}

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
                .font(.system(size: DocumentSourceBadgeConstants.iconFontSize))

            // Provider abbreviation
            Text(abbreviation)
                .font(.system(size: DocumentSourceBadgeConstants.abbreviationFontSize, weight: .medium))

            // Preprint indicator
            if isPreprint {
                Text("PPR")
                    .font(.system(size: DocumentSourceBadgeConstants.preprintFontSize, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, DocumentSourceBadgeConstants.badgeVerticalPadding)
                    .padding(.vertical, 1)
                    .background(Color.orange)
                    .cornerRadius(DocumentSourceBadgeConstants.badgeVerticalPadding)
            }
        }
        .foregroundColor(themeColor)
        .padding(.horizontal, DocumentSourceBadgeConstants.badgeHorizontalPadding)
        .padding(.vertical, DocumentSourceBadgeConstants.badgeVerticalPadding)
        .background(themeColor.opacity(DocumentSourceBadgeConstants.badgeBackgroundOpacity))
        .cornerRadius(DocumentSourceBadgeConstants.badgeCornerRadius)
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

    /// Theme color for the provider.
    private var themeColor: Color {
        switch provider {
        case .pubmed:
            return Color(nsColor: .systemBlue).opacity(0.8)
        case .europePMC:
            return Color(nsColor: .systemIndigo)
        case .both:
            return Color(nsColor: .systemCyan)
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

#endif // os(macOS)
