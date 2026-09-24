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

/// Aggregate transparency summary across all analyzed documents in a report.
///
/// Shows average score, industry funding percentage, risk distribution,
/// and a warning banner if high-risk documents are present.
struct TransparencySummarySection: View {
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

    /// Analysed documents rated without their full text.
    private var limitedCertaintyCount: Int {
        documents.filter { $0.transparencyCertainty == .limitedNoFullText }.count
    }

    private var hasHighRiskDocuments: Bool {
        riskCounts.high > 0
    }

    var body: some View {
        guard !analyzedResults.isEmpty else { return AnyView(EmptyView()) }

        return AnyView(
            VStack(alignment: .leading, spacing: 12) {
                Text("Transparency Analysis")
                    .font(.headline)

                // Warning banner for high-risk documents
                if hasHighRiskDocuments {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundColor(.red)
                        Text("\(riskCounts.high) document(s) flagged as high transparency risk")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(8)
                }

                // Ratings made without the full text
                if limitedCertaintyCount > 0 {
                    Text(
                        "\(limitedCertaintyCount) of \(analyzedResults.count) ratings made without "
                        + "the full text. \(TransparencyConstants.limitedCertaintyNote)."
                    )
                    .font(.caption)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }

                // Stats
                HStack(spacing: 20) {
                    TransparencyStatItem(
                        icon: "gauge.medium",
                        value: "\(averageScore)",
                        label: "Avg Score"
                    )
                    TransparencyStatItem(
                        icon: "building.2",
                        value: "\(industryFundedPercent)%",
                        label: "Industry"
                    )
                    TransparencyStatItem(
                        icon: "shield.checkered",
                        value: "\(analyzedResults.count)",
                        label: "Analyzed"
                    )
                }

                // Risk distribution
                HStack(spacing: 8) {
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
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(10)
        )
    }

    private func riskCountBadge(count: Int, label: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text("\(count)")
                .font(.caption)
                .fontWeight(.bold)
            Text(label)
                .font(.caption2)
        }
        .foregroundColor(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12))
        .cornerRadius(4)
    }
}

/// Single stat item for the transparency summary.
private struct TransparencyStatItem: View {
    let icon: String
    let value: String
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundColor(.accentColor)
            Text(value)
                .font(.headline)
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}

/// Why each document in a report was rated high transparency risk.
///
/// The summary above counts the high-risk documents; this names them and the
/// rules that produced each rating, so a reader can judge whether a flag is a
/// finding about the study or a gap in what the analysis could read. Laid out
/// with no disclosure controls, so the printable report shows it unchanged.
struct HighRiskTransparencyDetails: View {
    let documents: [Document]

    var body: some View {
        let entries = Document.highRiskTransparencyEntries(in: documents)
        if let introduction = HighRiskTransparencySection.introduction(count: entries.count) {
            VStack(alignment: .leading, spacing: 12) {
                Text(HighRiskTransparencySection.heading)
                    .font(.headline)
                Text(introduction)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    Divider()
                    HighRiskTransparencyEntryView(entry: entry)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.red.opacity(0.06))
            .cornerRadius(10)
        }
    }
}

/// One high-risk document: its reference, score, reasons, and caveats.
private struct HighRiskTransparencyEntryView: View {
    let entry: HighRiskTransparencyEntry

    var body: some View {
        let explanation = entry.explanation
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(entry.reference)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                Text("Score \(explanation.score)/100")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            if let note = explanation.certainty.note {
                Text(note)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(entry.citation)
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            bulletList(HighRiskTransparencySection.reasonsLabel, explanation.reasons)
            bulletList(
                HighRiskTransparencySection.scoreBreakdownLabel,
                explanation.scoreBreakdown.map { "\($0.label): \($0.signedPoints)" }
            )
            bulletList(HighRiskTransparencySection.otherConcernsLabel, explanation.otherConcerns)
            bulletList(HighRiskTransparencySection.caveatsLabel, explanation.caveats)
        }
    }

    @ViewBuilder
    private func bulletList(_ title: String, _ items: [String]) -> some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .fontWeight(.semibold)
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\u{2022}")
                        Text(item)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.caption)
                }
            }
        }
    }
}

#endif // os(iOS)
