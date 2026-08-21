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

/// Detailed transparency analysis view for a single document.
///
/// Displays the full breakdown of transparency analysis including score,
/// funding sources, conflicts of interest, data availability, and
/// trial registration compliance.
struct TransparencyDetailView: View {
    let result: TransparencyResult

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Stale-analysis notice
            if result.isStale {
                staleNotice
            }

            // Score Header
            scoreHeader

            // Funding
            fundingSection

            // Conflicts of Interest
            coiSection

            // Data Availability
            dataAvailabilitySection

            // Trial Registration
            if !result.trialRegistrations.isEmpty {
                trialSection
            }

            // Risk Indicators
            if !result.riskIndicators.isEmpty {
                riskIndicatorsSection
            }

            // Warnings
            if !result.warnings.isEmpty {
                warningsSection
            }

            // Metadata
            metadataSection
        }
    }

    // MARK: - Stale Notice

    /// Banner shown when this result predates the current analyzer.
    ///
    /// The score is left visible rather than hidden — it is the last thing that
    /// was actually measured — but it is marked so it is not read beside a
    /// freshly computed one as if the two were comparable.
    private var staleNotice: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundColor(.orange)
            Text("Analyzed by an earlier version. Re-analyze for a comparable score.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(6)
    }

    // MARK: - Score Header

    private var scoreHeader: some View {
        HStack(spacing: 12) {
            // Score circle
            ZStack {
                Circle()
                    .stroke(scoreColor.opacity(0.3), lineWidth: 4)
                    .frame(width: 48, height: 48)
                Circle()
                    .trim(from: 0, to: Double(result.transparencyScore) / 100.0)
                    .stroke(scoreColor, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .frame(width: 48, height: 48)
                    .rotationEffect(.degrees(-90))
                Text("\(result.transparencyScore)")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(scoreColor)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Transparency Score")
                    .font(.subheadline)
                    .fontWeight(.medium)
                TransparencyRiskBadge(riskLevel: result.riskLevel)
            }

            Spacer()
        }
        .padding()
        .background(scoreColor.opacity(0.08))
        .cornerRadius(10)
    }

    private var scoreColor: Color {
        switch result.riskLevel {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        case .unknown: return .gray
        }
    }

    // MARK: - Funding Section

    private var fundingSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Funding", systemImage: "banknote")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Text("Sponsor Type:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(result.sponsorType.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            if result.industryFundingDetected {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Industry funding detected")
                        .font(.caption)
                        .foregroundColor(.orange)
                    Text("(\(Int(result.industryFundingConfidence * 100))% confidence)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }

            if !result.funders.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result.funders) { funder in
                        HStack(spacing: 4) {
                            Image(systemName: funder.isIndustry ? "building.2" : "building.columns")
                                .font(.caption2)
                                .foregroundColor(funder.isIndustry ? .orange : .secondary)
                            Text(funder.name)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - COI Section

    private var coiSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Conflicts of Interest", systemImage: "person.2.badge.gearshape")
                .font(.subheadline)
                .fontWeight(.medium)

            if let statement = result.coiAnalysis.statement {
                Text(statement)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .lineLimit(4)
            } else {
                Text("No COI statement found")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .italic()
            }

            if result.coiAnalysis.hasIndustryTies {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Industry ties disclosed")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !result.coiAnalysis.disclosedRelationships.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(result.coiAnalysis.disclosedRelationships, id: \.self) { relationship in
                        Text("- \(relationship)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Data Availability Section

    private var dataAvailabilitySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Data Availability", systemImage: "externaldrive")
                .font(.subheadline)
                .fontWeight(.medium)

            HStack {
                Text("Disclosure Level:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(result.dataAvailability.disclosureLevel.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundColor(dataAvailabilityColor)
            }

            if let repo = result.dataAvailability.repositoryName {
                HStack {
                    Text("Repository:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(repo)
                        .font(.caption)
                }
            }

            if let statement = result.dataAvailability.statement {
                Text(statement)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(3)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    private var dataAvailabilityColor: Color {
        switch result.dataAvailability.disclosureLevel {
        case .fullOpen: return .green
        case .availableOnRequest: return .blue
        case .restricted: return .orange
        case .notAvailable: return .red
        case .notStated, .unknown: return .gray
        }
    }

    // MARK: - Trial Registration Section

    private var trialSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Trial Registration", systemImage: "list.clipboard")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(result.trialRegistrations) { trial in
                VStack(alignment: .leading, spacing: 2) {
                    Text(trial.registrationId)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let sponsor = trial.leadSponsor {
                        Text("Sponsor: \(sponsor)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: 4) {
                        Image(systemName: trial.resultsPosted ? "checkmark.circle" : "xmark.circle")
                            .foregroundColor(trial.resultsPosted ? .green : .red)
                            .font(.caption2)
                        Text(trial.resultsPosted ? "Results posted" : "Results not posted")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }

            HStack {
                Text("Compliance:")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text(result.resultsCompliance.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
            }

            if result.outcomeSwitchingDetected {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text("Outcome switching detected")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Risk Indicators Section

    private var riskIndicatorsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Risk Indicators", systemImage: "exclamationmark.shield")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.orange)

            ForEach(result.riskIndicators, id: \.self) { indicator in
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(indicator)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding()
        .background(Color.orange.opacity(0.08))
        .cornerRadius(8)
    }

    // MARK: - Warnings Section

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(result.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "info.circle")
                        .font(.caption2)
                        .foregroundColor(.blue)
                    Text(warning)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    // MARK: - Metadata Section

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Analyzed \(result.analysisTimestamp.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2)
                .foregroundColor(.secondary)
            if !result.dataSourcesUsed.isEmpty {
                Text("Sources: \(result.dataSourcesUsed.joined(separator: ", "))")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - Previews

/// A result stamped with the current analyzer — no stale notice.
#Preview("Current analysis") {
    var builder = TransparencyResultBuilder(pmid: "12345678")
    builder.title = "A Randomised Trial"
    builder.dataSourcesUsed = ["pubmed", "crossref"]
    return ScrollView { TransparencyDetailView(result: builder.build()).padding() }
}

/// A result stored before the analyzer was versioned — the notice this preview exists for.
#Preview("Stale analysis") {
    var builder = TransparencyResultBuilder(pmid: "12345678")
    builder.title = "A Randomised Trial"
    builder.dataSourcesUsed = ["pubmed", "crossref"]
    let current = builder.build()
    let stale = TransparencyResult(
        pmid: current.pmid,
        title: current.title,
        transparencyScore: current.transparencyScore,
        riskLevel: current.riskLevel,
        dataSourcesUsed: current.dataSourcesUsed,
        analyzerVersion: nil
    )
    return ScrollView { TransparencyDetailView(result: stale).padding() }
}

#endif // os(iOS)
