#if os(iOS)
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
    let source: AppFullTextSource

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
        case .uploaded: return .purple
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
        FullTextSourceBadge(source: .uploaded)
    }
    .padding()
}

#endif // os(iOS)
