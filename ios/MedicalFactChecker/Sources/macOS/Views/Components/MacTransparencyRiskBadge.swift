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
import BioMedLit

/// Small badge showing the transparency risk level for a document on macOS.
///
/// Displays a colored indicator (green/orange/red/gray) with a shield icon
/// and short risk label, providing at-a-glance transparency assessment.
struct MacTransparencyRiskBadge: View {
    let riskLevel: TransparencyRiskLevel

    var body: some View {
        HStack(spacing: MacSpacing.xSmall) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(riskLevel.shortLabel)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, MacSpacing.small)
        .padding(.vertical, MacSpacing.xxSmall)
        .background(badgeColor.opacity(MacOpacity.badgeBackground))
        .cornerRadius(MacCornerRadius.small)
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
    VStack(spacing: MacSpacing.standard) {
        MacTransparencyRiskBadge(riskLevel: .low)
        MacTransparencyRiskBadge(riskLevel: .medium)
        MacTransparencyRiskBadge(riskLevel: .high)
        MacTransparencyRiskBadge(riskLevel: .unknown)
    }
    .padding()
}

#endif // os(macOS)
