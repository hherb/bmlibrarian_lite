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

/// Detailed transparency analysis view for a single document on macOS.
///
/// Displays the full breakdown of transparency analysis including score,
/// funding sources, conflicts of interest, data availability, and
/// trial registration compliance.
struct MacTransparencyDetailView: View {
    let result: TransparencyResult

    var body: some View {
        VStack(alignment: .leading, spacing: MacSpacing.standard) {
            if result.isStale {
                staleNotice
            }

            scoreHeader
            fundingSection
            coiSection
            dataAvailabilitySection

            if !result.trialRegistrations.isEmpty {
                trialSection
            }

            if !result.riskIndicators.isEmpty {
                riskIndicatorsSection
            }

            if !result.warnings.isEmpty {
                warningsSection
            }

            metadataSection
        }
    }

    // MARK: - Score Header

    private var scoreHeader: some View {
        HStack(spacing: MacSpacing.standard) {
            ZStack {
                Circle()
                    .stroke(scoreColor.opacity(MacOpacity.muted), lineWidth: 4)
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

            VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                Text("Transparency Score")
                    .font(.subheadline)
                    .fontWeight(.medium)
                MacTransparencyRiskBadge(riskLevel: result.riskLevel)
            }

            Spacer()
        }
        .padding(MacSpacing.large)
        .background(scoreColor.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.large)
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
        VStack(alignment: .leading, spacing: MacSpacing.small) {
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
                HStack(spacing: MacSpacing.xSmall) {
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
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    ForEach(result.funders) { funder in
                        HStack(spacing: MacSpacing.xSmall) {
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
        .padding(MacSpacing.large)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
    }

    // MARK: - COI Section

    private var coiSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.small) {
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
                HStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange)
                        .font(.caption)
                    Text("Industry ties disclosed")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            if !result.coiAnalysis.disclosedRelationships.isEmpty {
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    ForEach(result.coiAnalysis.disclosedRelationships, id: \.self) { relationship in
                        Text("- \(relationship)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
    }

    // MARK: - Data Availability Section

    private var dataAvailabilitySection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.small) {
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
        .padding(MacSpacing.large)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
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
        VStack(alignment: .leading, spacing: MacSpacing.small) {
            Label("Trial Registration", systemImage: "list.clipboard")
                .font(.subheadline)
                .fontWeight(.medium)

            ForEach(result.trialRegistrations) { trial in
                VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
                    Text(trial.registrationId)
                        .font(.caption)
                        .fontWeight(.medium)
                    if let sponsor = trial.leadSponsor {
                        Text("Sponsor: \(sponsor)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    HStack(spacing: MacSpacing.xSmall) {
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
                HStack(spacing: MacSpacing.xSmall) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                    Text("Outcome switching detected")
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(MacCornerRadius.standard)
    }

    // MARK: - Risk Indicators Section

    private var riskIndicatorsSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.small) {
            Label("Risk Indicators", systemImage: "exclamationmark.shield")
                .font(.subheadline)
                .fontWeight(.medium)
                .foregroundColor(.orange)

            ForEach(result.riskIndicators, id: \.self) { indicator in
                HStack(alignment: .top, spacing: MacSpacing.small) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.caption2)
                        .foregroundColor(.orange)
                    Text(indicator)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(MacSpacing.large)
        .background(Color.orange.opacity(MacOpacity.light))
        .cornerRadius(MacCornerRadius.standard)
    }

    // MARK: - Warnings Section

    private var warningsSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.xSmall) {
            ForEach(result.warnings, id: \.self) { warning in
                HStack(alignment: .top, spacing: MacSpacing.xSmall) {
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

    /// Banner shown when this result predates the current analyzer.
    ///
    /// The score is left visible rather than hidden — it is the last thing that
    /// was actually measured — but it is marked so it is not read beside a
    /// freshly computed one as if the two were comparable.
    private var staleNotice: some View {
        HStack(alignment: .top, spacing: MacSpacing.xSmall) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.caption)
                .foregroundColor(.orange)
            Text("Analyzed by an earlier version. Re-analyze for a comparable score.")
                .font(.caption2)
                .foregroundColor(.secondary)
        }
        .padding(MacSpacing.small)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(MacOpacity.subtle))
        .cornerRadius(MacCornerRadius.medium)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: MacSpacing.xxSmall) {
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

#endif // os(macOS)
