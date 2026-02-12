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
import BioMedLit

// MARK: - Constants

/// Constants for transparency risk badge UI.
private enum TransparencyBadgeConstants {
    static let iconFontSize: CGFloat = 8
    static let labelFontSize: CGFloat = 9
    static let horizontalPadding: CGFloat = 6
    static let verticalPadding: CGFloat = 3
    static let cornerRadius: CGFloat = 4
    static let backgroundOpacity: CGFloat = 0.12
}

/// Small badge showing the transparency risk level for a document.
///
/// Displays a colored indicator (green/orange/red/gray) with a shield icon
/// and short risk label, providing at-a-glance transparency assessment.
struct TransparencyRiskBadge: View {
    let riskLevel: TransparencyRiskLevel

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: iconName)
                .font(.system(size: TransparencyBadgeConstants.iconFontSize))
            Text(riskLevel.shortLabel)
                .font(.system(size: TransparencyBadgeConstants.labelFontSize, weight: .medium))
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, TransparencyBadgeConstants.horizontalPadding)
        .padding(.vertical, TransparencyBadgeConstants.verticalPadding)
        .background(badgeColor.opacity(TransparencyBadgeConstants.backgroundOpacity))
        .cornerRadius(TransparencyBadgeConstants.cornerRadius)
        .accessibilityLabel("Transparency risk: \(riskLevel.fullLabel)")
    }

    private var badgeColor: Color {
        switch riskLevel {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .unknown: return .gray
        }
    }

    private var iconName: String {
        switch riskLevel {
        case .low: return "checkmark.shield"
        case .medium: return "exclamationmark.triangle"
        case .high: return "xmark.shield"
        case .unknown: return "questionmark.circle"
        }
    }
}

// MARK: - Preview

#Preview {
    VStack(spacing: 12) {
        TransparencyRiskBadge(riskLevel: .low)
        TransparencyRiskBadge(riskLevel: .medium)
        TransparencyRiskBadge(riskLevel: .high)
        TransparencyRiskBadge(riskLevel: .unknown)
    }
    .padding()
}

#endif // os(iOS)
