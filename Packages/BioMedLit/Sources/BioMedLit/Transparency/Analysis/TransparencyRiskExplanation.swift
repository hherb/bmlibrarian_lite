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

import Foundation

// MARK: - Certainty

/// How far a transparency rating can be relied on, given what was read.
///
/// Conflict-of-interest and data-availability statements appear only in an
/// article's full text. A rating made without it rests on metadata alone and
/// counts statements it could not look for as missing, so full-text analysis is
/// the standard every other rating is measured against, and any rating short of
/// it must say so wherever it is shown.
public enum TransparencyCertainty: Sendable, Equatable {
    /// The full text was analysed.
    case fullText
    /// The rating was made without the full text.
    case limitedNoFullText
    /// Whether the full text was analysed was not recorded.
    case unrecorded

    /// The certainty a result's record of full-text access implies.
    ///
    /// - Parameter fullTextSearched: ``TransparencyResult/fullTextSearched``.
    public init(fullTextSearched: Bool?) {
        switch fullTextSearched {
        case true?: self = .fullText
        case false?: self = .limitedNoFullText
        case nil: self = .unrecorded
        }
    }

    /// Whether the rating falls short of full-text analysis, or may.
    public var isLimited: Bool {
        self != .fullText
    }

    /// What a reader must be told alongside the rating; `nil` for full text.
    public var note: String? {
        switch self {
        case .fullText:
            return nil
        case .limitedNoFullText:
            return TransparencyConstants.limitedCertaintyNote
        case .unrecorded:
            return TransparencyConstants.unrecordedCertaintyNote
        }
    }
}

// MARK: - Rating Rules

/// A rule that, on its own, rates a study high transparency risk.
///
/// Produced by ``TransparencyScorer/highRiskTriggers(score:industryFunding:dataAvailability:coiDisclosed:scoreThreshold:industryDataTriggersHighRisk:missingCoiTriggersHighRisk:)``,
/// which is also what ``TransparencyScorer/calculateRiskLevel(score:industryFunding:dataAvailability:coiDisclosed:scoreThreshold:industryDataTriggersHighRisk:missingCoiTriggersHighRisk:)``
/// rates by, so the rules a report names are the rules that were applied.
public enum HighRiskTrigger: Sendable, Equatable {
    /// The transparency score fell below the high-risk cut-off.
    case scoreBelowThreshold(score: Int, threshold: Int)
    /// Industry funding was detected and the data are restricted, unavailable
    /// or covered by no statement.
    case industryFundingWithWithheldData(DataDisclosureLevel)
    /// No conflict-of-interest statement was found.
    case missingCOIStatement
}

/// One addition or penalty in a transparency score.
///
/// ``TransparencyScorer/calculateScore(dataAvailability:coiAnalysis:trialRegistrations:resultsCompliance:industryFundingDetected:outcomeSwitchingDetected:)``
/// is the clamped sum of a result's components.
public struct ScoreComponent: Sendable, Equatable {
    /// What the term is for, e.g. "Trial results not posted".
    public let label: String
    /// Points added (positive) or subtracted (negative).
    public let points: Int

    /// Creates a score component.
    ///
    /// - Parameters:
    ///   - label: What the term is for.
    ///   - points: Points added or subtracted.
    public init(label: String, points: Int) {
        self.label = label
        self.points = points
    }

    /// The points with an explicit sign, e.g. "+5" or "-10".
    public var signedPoints: String {
        points > 0 ? "+\(points)" : "\(points)"
    }
}

// MARK: - Explanation

/// Why one study was rated high transparency risk, in words a report can show.
///
/// A badge saying "High" tells a reader to distrust a study without telling
/// them what to distrust it for, and the rule most often responsible — no
/// conflict-of-interest statement found — is also the one most often met
/// because there was no full text to look in. This states the rules that
/// produced the rating, the score terms when the score was one of them, and
/// every reason the rating may not mean what it appears to.
public struct TransparencyRiskExplanation: Sendable, Equatable {
    /// The study's transparency score (0-100).
    public let score: Int

    /// Each rule that rated the study high, as a sentence. Empty only when the
    /// stored rating is one no current rule explains; ``caveats`` then says so.
    public let reasons: [String]

    /// The score's terms, given only when a low score is among ``reasons``.
    public let scoreBreakdown: [ScoreComponent]

    /// Concerns the analysis recorded that did not by themselves decide the
    /// rating, e.g. disclosed industry ties or unposted trial results.
    public let otherConcerns: [String]

    /// Reasons the rating may rest on less than it appears to.
    public let caveats: [String]

    /// How far the rating can be relied on; limited without the full text.
    /// Its ``TransparencyCertainty/note`` belongs beside the score, not among
    /// the caveats: it qualifies the whole rating.
    public let certainty: TransparencyCertainty

    /// Explain a stored result's high rating.
    ///
    /// - Parameters:
    ///   - result: A transparency result, normally one rated high.
    ///   - certainty: What is known of the rating's full-text access. Defaults
    ///     to the result's own record; a caller holding better evidence for a
    ///     result that predates the record may pass it.
    public init(result: TransparencyResult, certainty: TransparencyCertainty? = nil) {
        let certainty = certainty ?? TransparencyCertainty(fullTextSearched: result.fullTextSearched)
        let triggers = TransparencyScorer.highRiskTriggers(for: result)

        self.certainty = certainty
        score = result.transparencyScore
        reasons = triggers.map { Self.sentence(for: $0, result: result, certainty: certainty) }

        let scoredLow = triggers.contains {
            if case .scoreBelowThreshold = $0 { return true }
            return false
        }
        scoreBreakdown = scoredLow ? TransparencyScorer.scoreComponents(for: result) : []

        otherConcerns = Self.concerns(in: result, besides: triggers)

        var caveats: [String] = []
        if triggers.isEmpty && result.riskLevel == .high {
            caveats.append(
                "None of the current high-risk rules matches this study's recorded findings, "
                + "so the rating probably comes from an earlier version of the analysis. "
                + "Re-analyse the study before relying on it."
            )
        } else if certainty.isLimited && !triggers.isEmpty
                    && triggers.allSatisfy({ Self.dependsOnFullText($0, result: result) }) {
            caveats.append(
                "Every reason for this rating depends on statements that appear only in the "
                + "full text. Treat the rating as unassessed rather than as evidence of poor "
                + "transparency."
            )
        }
        if result.isStale {
            caveats.append(
                "This analysis was produced by an older version of the analyser; "
                + "re-analysing may change the rating."
            )
        }
        let metadataSources = [
            TransparencyConstants.pubMedSourceName,
            TransparencyConstants.crossRefSourceName,
        ]
        if !result.dataSourcesUsed.contains(where: metadataSources.contains) {
            caveats.append(
                "Neither PubMed nor CrossRef returned a record for this study, "
                + "so its funders could not be checked."
            )
        }
        if !result.errors.isEmpty {
            caveats.append("The analysis reported errors: \(result.errors.joined(separator: "; ")).")
        }
        self.caveats = caveats
    }

    /// The explanation as indented plain-text lines, for exported reports.
    public var plainTextLines: [String] {
        var lines = ["  Transparency score: \(score)/100"]
        if let note = certainty.note {
            lines.append("  \(note)")
        }
        if !reasons.isEmpty {
            lines.append("  \(HighRiskTransparencySection.reasonsLabel):")
            lines += reasons.map { "  - \($0)" }
        }
        if !scoreBreakdown.isEmpty {
            lines.append("  \(HighRiskTransparencySection.scoreBreakdownLabel):")
            lines += scoreBreakdown.map { "  - \($0.label): \($0.signedPoints)" }
        }
        if !otherConcerns.isEmpty {
            lines.append("  \(HighRiskTransparencySection.otherConcernsLabel):")
            lines += otherConcerns.map { "  - \($0)" }
        }
        if !caveats.isEmpty {
            lines.append("  \(HighRiskTransparencySection.caveatsLabel):")
            lines += caveats.map { "  - \($0)" }
        }
        return lines
    }

    // MARK: - Private

    /// A rule as a sentence about this study.
    private static func sentence(
        for trigger: HighRiskTrigger,
        result: TransparencyResult,
        certainty: TransparencyCertainty
    ) -> String {
        switch trigger {
        case let .scoreBelowThreshold(score, threshold):
            return "Its transparency score of \(score)/100 is below the high-risk cut-off of \(threshold)."

        case let .industryFundingWithWithheldData(level):
            let percent = Int((result.industryFundingConfidence * 100).rounded())
            let funders = result.funders.filter(\.isIndustry).map(\.name)
            let funderText = funders.isEmpty ? "" : " (\(funders.joined(separator: ", ")))"
            return "Industry funding was detected\(funderText), with \(percent)% confidence, "
                + "and \(dataPhrase(for: level, certainty: certainty))."

        case .missingCOIStatement:
            let found = certainty == .fullText
                ? "No conflict of interest statement was found in the full text."
                : "No conflict of interest statement was found; the full text, where one "
                    + "would appear, was not searched."
            return found + " A missing statement is enough on its own for a high rating."
        }
    }

    /// What a data disclosure level says about the study's data.
    private static func dataPhrase(for level: DataDisclosureLevel, certainty: TransparencyCertainty) -> String {
        switch level {
        case .restricted:
            return "its data are available only with restrictions"
        case .notAvailable:
            return "its data are not available"
        case .notStated where certainty == .fullText:
            return "no data availability statement was found in the full text"
        case .notStated:
            return "no data availability statement was found (the full text, where it would "
                + "appear, was not searched)"
        case .fullOpen, .availableOnRequest, .unknown:
            return "its data availability is \(level.displayName.lowercased())"
        }
    }

    /// Whether a rule could have been met only because the full text was missing.
    ///
    /// Statements are looked for only in the full text, so without it the
    /// analysis records "no COI statement" and "no data statement" whatever the
    /// article says. A low score counts when those two penalties alone carry it
    /// below the cut-off.
    private static func dependsOnFullText(_ trigger: HighRiskTrigger, result: TransparencyResult) -> Bool {
        switch trigger {
        case .missingCOIStatement:
            return true
        case let .industryFundingWithWithheldData(level):
            return level == .notStated
        case let .scoreBelowThreshold(score, threshold):
            var unsearchedPenalties = 0
            if !result.coiAnalysis.hasStatement {
                unsearchedPenalties += TransparencyConstants.missingCoiPenalty
            }
            if result.dataAvailability.disclosureLevel == .notStated {
                unsearchedPenalties += TransparencyConstants.noStatementPenalty
            }
            return score - unsearchedPenalties >= threshold
        }
    }

    /// The result's recorded concerns, less those a stated reason already says.
    private static func concerns(in result: TransparencyResult, besides triggers: [HighRiskTrigger]) -> [String] {
        var restated: Set<String> = []
        for trigger in triggers {
            switch trigger {
            case .missingCOIStatement:
                restated.insert(RiskIndicatorStrings.missingCoiStatement)
            case .industryFundingWithWithheldData:
                restated.insert(RiskIndicatorStrings.industryFunding)
                restated.insert(RiskIndicatorStrings.industryRestrictedData)
            case .scoreBelowThreshold:
                break
            }
        }
        var seen = restated
        var concerns: [String] = []
        for concern in result.riskIndicators + result.warnings + result.outcomeSwitchingDetails
        where seen.insert(concern).inserted {
            concerns.append(concern)
        }
        return concerns
    }
}

// MARK: - Report Section

/// A study rated high risk, as a report lists it.
public struct HighRiskTransparencyEntry: Sendable, Equatable {
    /// How the report refers to the study, e.g. "Smith et al., 2020".
    public let reference: String
    /// The study's full citation.
    public let citation: String
    /// Why it was rated high.
    public let explanation: TransparencyRiskExplanation

    /// Creates an entry.
    ///
    /// - Parameters:
    ///   - reference: How the report refers to the study.
    ///   - citation: The study's full citation.
    ///   - result: Its transparency result.
    ///   - certainty: What is known of the rating's full-text access, when the
    ///     caller knows better than the result's own record.
    public init(
        reference: String,
        citation: String,
        result: TransparencyResult,
        certainty: TransparencyCertainty? = nil
    ) {
        self.reference = reference
        self.citation = citation
        self.explanation = TransparencyRiskExplanation(result: result, certainty: certainty)
    }
}

/// The report section discussing every study rated high transparency risk.
public enum HighRiskTransparencySection {
    /// The section's heading.
    public static let heading = "Why Studies Were Rated High Transparency Risk"

    /// Heads the rules that produced a study's rating.
    public static let reasonsLabel = "Rated high risk because"

    /// Heads the terms of a study's score.
    public static let scoreBreakdownLabel = "How the score was reached"

    /// Heads the concerns that did not by themselves decide the rating.
    public static let otherConcernsLabel = "Other concerns recorded"

    /// Heads the reasons a rating may rest on less than it appears to.
    public static let caveatsLabel = "Caveats"

    /// The sentence introducing the section.
    ///
    /// - Parameter count: The number of studies rated high.
    /// - Returns: The introduction, or `nil` when there are none.
    public static func introduction(count: Int) -> String? {
        guard count > 0 else { return nil }
        let studies = count == 1 ? "1 study was" : "\(count) studies were"
        return "\(studies) rated high transparency risk. Each rule listed below is enough "
            + "on its own for that rating; the caveats say where a rating rests on less than "
            + "it appears to."
    }

    /// The section as plain text, for copied, shared and exported reports.
    ///
    /// - Parameter entries: The studies rated high, in the order to list them.
    /// - Returns: The section, or `nil` when no study was rated high.
    public static func plainText(for entries: [HighRiskTransparencyEntry]) -> String? {
        guard let introduction = introduction(count: entries.count) else { return nil }
        var lines = [heading.uppercased(), "", introduction]
        for entry in entries {
            lines.append("")
            lines.append("\(entry.reference): \(entry.citation)")
            lines += entry.explanation.plainTextLines
        }
        return lines.joined(separator: "\n")
    }
}
