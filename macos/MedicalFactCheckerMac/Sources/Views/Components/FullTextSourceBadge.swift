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

/// Small badge showing where full text was retrieved from.
///
/// Displays an icon and label with appropriate color coding based on the source.
/// Used in document cards and full-text viewer headers.
///
/// Usage:
/// ```swift
/// FullTextSourceBadge(sourceString: "europepmc")
/// // or
/// FullTextSourceBadge(source: .europePMC)
/// ```
struct FullTextSourceBadge: View {
    // MARK: - Properties

    /// The source to display, either from a string or enum.
    private let source: FullTextSource?

    // MARK: - Initialization

    /// Initialize with a source string (e.g., from Document.fullTextSource).
    ///
    /// - Parameter sourceString: The raw string value of the source.
    init(sourceString: String) {
        self.source = FullTextSource(rawValue: sourceString)
    }

    /// Initialize with a FullTextSource enum value.
    ///
    /// - Parameter source: The full-text source enum.
    init(source: FullTextSource) {
        self.source = source
    }

    // MARK: - Body

    var body: some View {
        HStack(spacing: MacSpacing.xSmall) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(displayName)
                .font(.caption2)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, MacSpacing.small)
        .padding(.vertical, MacSpacing.xxSmall)
        .background(badgeColor.opacity(MacOpacity.badgeBackground))
        .cornerRadius(MacCornerRadius.small)
        .accessibilityLabel("Full text from \(displayName)")
    }

    // MARK: - Computed Properties

    /// The SF Symbol icon name for the source.
    private var iconName: String {
        source?.iconName ?? "doc"
    }

    /// The human-readable display name for the source.
    private var displayName: String {
        source?.displayName ?? "Unknown"
    }

    /// The color for the badge based on source type.
    private var badgeColor: Color {
        guard let source = source else { return .gray }
        return MacFullTextColors.color(for: source)
    }
}

// MARK: - Preview

#Preview("All Sources") {
    VStack(spacing: MacSpacing.medium) {
        FullTextSourceBadge(sourceString: "europepmc")
        FullTextSourceBadge(sourceString: "unpaywall")
        FullTextSourceBadge(sourceString: "doi")
        FullTextSourceBadge(sourceString: "cached")
        FullTextSourceBadge(sourceString: "uploaded")
        FullTextSourceBadge(sourceString: "unknown")
    }
    .padding()
}

#Preview("Enum Init") {
    VStack(spacing: MacSpacing.medium) {
        FullTextSourceBadge(source: .europePMC)
        FullTextSourceBadge(source: .unpaywall)
        FullTextSourceBadge(source: .doi)
        FullTextSourceBadge(source: .cached)
        FullTextSourceBadge(source: .uploaded)
    }
    .padding()
}
