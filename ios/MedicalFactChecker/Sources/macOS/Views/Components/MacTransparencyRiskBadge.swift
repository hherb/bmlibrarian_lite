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

    /// How far the rating can be relied on. A limited one says so on the badge
    /// itself: full-text analysis is the standard, and a rating short of it
    /// must not look like one that met it. `nil` shows the rating alone.
    var certainty: TransparencyCertainty? = nil

    /// Whether the rating is shown as unassessed rather than high: every reason
    /// for it rests on statements in full text that was not searched.
    var unassessed: Bool = false

    /// The level as the badge names it.
    private var levelLabel: String {
        unassessed ? TransparencyConstants.unassessedLabel : riskLevel.shortLabel
    }

    /// The badge's label, qualified when its certainty is limited.
    private var label: String {
        guard certainty?.isLimited == true else { return levelLabel }
        return "\(levelLabel) \(TransparencyConstants.limitedCertaintyBadgeSuffix)"
    }

    /// What assistive technology reads, including any certainty note.
    private var spokenLabel: String {
        let level = unassessed ? TransparencyConstants.unassessedLabel : riskLevel.fullLabel
        let rating = "Transparency risk: \(level)"
        guard let note = certainty?.note else { return rating }
        return "\(rating). \(note)"
    }

    var body: some View {
        HStack(spacing: MacSpacing.xSmall) {
            Image(systemName: iconName)
                .font(.caption2)
            Text(label)
                .font(.caption2)
                .fontWeight(.medium)
        }
        .foregroundColor(badgeColor)
        .padding(.horizontal, MacSpacing.small)
        .padding(.vertical, MacSpacing.xxSmall)
        .background(badgeColor.opacity(MacOpacity.badgeBackground))
        .cornerRadius(MacCornerRadius.small)
        .help(certainty?.note ?? riskLevel.fullLabel)
        .accessibilityLabel(spokenLabel)
    }

    private var badgeColor: Color {
        if unassessed { return .gray }
        switch riskLevel {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .unknown: return .gray
        }
    }

    private var iconName: String {
        if unassessed { return "questionmark.circle" }
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
        MacTransparencyRiskBadge(riskLevel: .high, certainty: .limitedNoFullText)
        MacTransparencyRiskBadge(riskLevel: .unknown)
    }
    .padding()
}

#endif // os(macOS)
