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

/// Aggregate transparency summary across all analyzed documents in a macOS report.
///
/// Shows average score, industry funding percentage, risk distribution,
/// and a warning banner if high-risk documents are present.
struct MacTransparencySummarySection: View {
    let documents: [Document]

    private var analyzedResults: [TransparencyResult] {
        documents.compactMap { $0.transparencyResult }
    }

    private var averageScore: Int {
        guard !analyzedResults.isEmpty else { return 0 }
        let total = analyzedResults.reduce(0) { $0 + $1.transparencyScore }
        return total / analyzedResults.count
    }

    private var industryFundedCount: Int {
        analyzedResults.filter { $0.industryFundingDetected }.count
    }

    private var industryFundedPercent: Int {
        guard !analyzedResults.isEmpty else { return 0 }
        return (industryFundedCount * 100) / analyzedResults.count
    }

    private var riskCounts: (low: Int, medium: Int, high: Int) {
        var low = 0, medium = 0, high = 0
        for result in analyzedResults {
            switch result.riskLevel {
            case .low: low += 1
            case .medium: medium += 1
            case .high: high += 1
            case .unknown: break
            }
        }
        return (low, medium, high)
    }

    private var hasHighRiskDocuments: Bool {
        riskCounts.high > 0
    }

    var body: some View {
        guard !analyzedResults.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: MacSpacing.standard) {
                Text("Transparency Analysis")
                    .font(.title3)
                    .fontWeight(.semibold)

                // Warning banner for high-risk documents
                if hasHighRiskDocuments {
                    HStack(spacing: MacSpacing.medium) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("\(riskCounts.high) document(s) flagged as high transparency risk")
                            .font(.body)
                            .foregroundColor(.red)
                    }
                    .padding(MacSpacing.standard)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(MacOpacity.light))
                    .cornerRadius(MacCornerRadius.standard)
                }

                // Stats
                HStack(spacing: MacSpacing.statItemSpacing) {
                    MacStatItem(
                        icon: "gauge.medium",
                        value: "\(averageScore)",
                        label: "Avg Score"
                    )
                    MacStatItem(
                        icon: "building.2",
                        value: "\(industryFundedPercent)%",
                        label: "Industry Funded"
                    )
                    MacStatItem(
                        icon: "shield.checkered",
                        value: "\(analyzedResults.count)",
                        label: "Analyzed"
                    )
                }

                // Risk distribution
                HStack(spacing: MacSpacing.medium) {
                    Text("Risk:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    if riskCounts.low > 0 {
                        riskCountBadge(count: riskCounts.low, label: "Low", color: .green)
                    }
                    if riskCounts.medium > 0 {
                        riskCountBadge(count: riskCounts.medium, label: "Med", color: .orange)
                    }
                    if riskCounts.high > 0 {
                        riskCountBadge(count: riskCounts.high, label: "High", color: .red)
                    }
                }
            }
            .padding(MacSpacing.xLarge)
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(MacCornerRadius.xLarge)
        )
    }

    private func riskCountBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: MacSpacing.xxSmall) {
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
        }
        .foregroundColor(color)
        .padding(.horizontal, MacSpacing.small)
        .padding(.vertical, MacSpacing.xxSmall)
        .background(color.opacity(MacOpacity.badgeBackground))
        .cornerRadius(MacCornerRadius.small)
    }
}

#endif // os(macOS)
