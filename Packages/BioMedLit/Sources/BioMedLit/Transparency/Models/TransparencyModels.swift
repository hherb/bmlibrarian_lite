// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
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

// MARK: - Enums

/// Classification of study sponsor types.
///
/// Used to categorize the primary funding source of a study, which is important
/// for assessing potential bias and conflicts of interest in research.
public enum SponsorType: String, Sendable, Codable, CaseIterable {
    /// Industry-funded (pharmaceutical, biotech, medical device companies).
    case industry
    /// Government-funded (NIH, NSF, CDC, etc.).
    case government
    /// Academic institution-funded.
    case academic
    /// Non-profit organization-funded.
    case nonprofit
    /// Multiple funding source types.
    case mixed
    /// Funding source could not be determined.
    case unknown

    /// Human-readable display name for UI presentation.
    public var displayName: String {
        switch self {
        case .industry: return "Industry"
        case .government: return "Government"
        case .academic: return "Academic"
        case .nonprofit: return "Non-Profit"
        case .mixed: return "Mixed"
        case .unknown: return "Unknown"
        }
    }
}

/// Classification of data disclosure levels.
///
/// Categorizes how openly research data is made available, from fully open
/// access to completely unavailable.
public enum DataDisclosureLevel: String, Sendable, Codable, CaseIterable {
    /// Data fully available in public repository.
    case fullOpen = "full_open"
    /// Data available upon reasonable request.
    ///
    /// Note: `DataAvailabilityAnalyzer.analyze` never emits this case —
    /// on-request statements classify as `.restricted` to match the canonical
    /// Python reference (`analyze_data_availability`). It is retained for
    /// externally-constructed results (e.g. an LLM analyzer) and is still
    /// scored (`TransparencyConstants.onRequestDataPoints`).
    case availableOnRequest = "on_request"
    /// Data available with restrictions (e.g., IRB approval required).
    case restricted
    /// Data explicitly not available.
    case notAvailable = "not_available"
    /// No data availability statement found.
    case notStated = "not_stated"
    /// Could not determine data availability.
    case unknown

    /// Human-readable display name for UI presentation.
    public var displayName: String {
        switch self {
        case .fullOpen: return "Fully Open"
        case .availableOnRequest: return "Available on Request"
        case .restricted: return "Restricted"
        case .notAvailable: return "Not Available"
        case .notStated: return "Not Stated"
        case .unknown: return "Unknown"
        }
    }
}

/// ClinicalTrials.gov results posting compliance status.
///
/// Indicates whether a clinical trial has posted results within the required
/// timeframe per FDAAA regulations (typically 12 months after completion).
public enum ResultsComplianceStatus: String, Sendable, Codable, CaseIterable {
    /// Results posted within compliance deadline.
    case compliant
    /// Results posted, but after the deadline.
    case late
    /// Results not posted despite being required.
    case missing
    /// Results posting not required (e.g., not an applicable trial).
    case notRequired = "not_required"
    /// Compliance status could not be determined.
    case unknown

    /// Human-readable display name for UI presentation.
    public var displayName: String {
        switch self {
        case .compliant: return "Compliant"
        case .late: return "Late"
        case .missing: return "Missing"
        case .notRequired: return "Not Required"
        case .unknown: return "Unknown"
        }
    }
}

/// Transparency risk level for UI display.
///
/// A simplified risk classification based on the transparency score and
/// other factors, suitable for badge displays and quick assessments.
public enum TransparencyRiskLevel: String, Sendable, Codable, CaseIterable {
    /// Low risk - good transparency practices.
    case low
    /// Medium risk - some transparency concerns.
    case medium
    /// High risk - significant transparency issues.
    case high
    /// Risk level could not be determined.
    case unknown

    /// SwiftUI color name for the risk level badge.
    public var colorName: String {
        switch self {
        case .low: return "green"
        case .medium: return "orange"
        case .high: return "red"
        case .unknown: return "gray"
        }
    }

    /// Short label for compact UI displays (e.g., badges).
    public var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .unknown: return "?"
        }
    }

    /// Full label for tooltips and detailed displays.
    public var fullLabel: String {
        switch self {
        case .low: return "Low Risk"
        case .medium: return "Medium Risk"
        case .high: return "High Risk"
        case .unknown: return "Unknown"
        }
    }
}

// MARK: - Data Structures

/// Information about a study funder.
///
/// Contains details about an organization that funded the research, including
/// whether it is an industry funder and the confidence level of this classification.
public struct FunderInfo: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this funder entry.
    public let id: UUID

    /// Name of the funding organization.
    public let name: String

    /// CrossRef Funder Registry DOI, if known (e.g., "10.13039/100004319" for Pfizer).
    public let funderDOI: String?

    /// Grant or award numbers associated with this funder.
    public let awardNumbers: [String]

    /// Whether this funder is classified as an industry entity.
    public let isIndustry: Bool

    /// Confidence score (0.0-1.0) for the industry classification.
    public let confidence: Double

    /// Creates a new FunderInfo instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID).
    ///   - name: Name of the funding organization.
    ///   - funderDOI: CrossRef Funder Registry DOI, if known.
    ///   - awardNumbers: Grant or award numbers.
    ///   - isIndustry: Whether this is an industry funder.
    ///   - confidence: Confidence score for the classification.
    public init(
        id: UUID = UUID(),
        name: String,
        funderDOI: String? = nil,
        awardNumbers: [String] = [],
        isIndustry: Bool = false,
        confidence: Double = 0.0
    ) {
        self.id = id
        self.name = name
        self.funderDOI = funderDOI
        self.awardNumbers = awardNumbers
        self.isIndustry = isIndustry
        self.confidence = confidence
    }
}

/// Clinical trial registration information.
///
/// Contains details about a clinical trial registration from ClinicalTrials.gov
/// or another registry, including registration ID, sponsor information, and
/// outcome measures.
public struct TrialRegistration: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this registration entry.
    public let id: UUID

    /// Name of the trial registry (e.g., "ClinicalTrials.gov").
    public let registry: String

    /// Registration identifier (e.g., "NCT01234567").
    public let registrationId: String

    /// Official title of the registered trial.
    public let title: String?

    /// Sponsor classification from the registry (e.g., "INDUSTRY", "NIH").
    public let sponsorClass: String?

    /// Name of the lead sponsor organization.
    public let leadSponsor: String?

    /// Whether results have been posted to the registry.
    public let resultsPosted: Bool

    /// Primary completion date of the trial.
    public let completionDate: Date?

    /// Primary outcome measures as registered.
    public let primaryOutcomesRegistered: [String]

    /// Secondary outcome measures as registered.
    public let secondaryOutcomesRegistered: [String]

    /// Creates a new TrialRegistration instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID).
    ///   - registry: Name of the trial registry.
    ///   - registrationId: Registration identifier.
    ///   - title: Official title of the trial.
    ///   - sponsorClass: Sponsor classification from registry.
    ///   - leadSponsor: Name of the lead sponsor.
    ///   - resultsPosted: Whether results have been posted.
    ///   - completionDate: Primary completion date.
    ///   - primaryOutcomesRegistered: Primary outcome measures.
    ///   - secondaryOutcomesRegistered: Secondary outcome measures.
    public init(
        id: UUID = UUID(),
        registry: String,
        registrationId: String,
        title: String? = nil,
        sponsorClass: String? = nil,
        leadSponsor: String? = nil,
        resultsPosted: Bool = false,
        completionDate: Date? = nil,
        primaryOutcomesRegistered: [String] = [],
        secondaryOutcomesRegistered: [String] = []
    ) {
        self.id = id
        self.registry = registry
        self.registrationId = registrationId
        self.title = title
        self.sponsorClass = sponsorClass
        self.leadSponsor = leadSponsor
        self.resultsPosted = resultsPosted
        self.completionDate = completionDate
        self.primaryOutcomesRegistered = primaryOutcomesRegistered
        self.secondaryOutcomesRegistered = secondaryOutcomesRegistered
    }
}

/// Conflict of interest analysis result.
///
/// Contains the parsed COI statement and analysis of disclosed industry ties
/// and relationships.
public struct COIAnalysisResult: Sendable, Codable, Equatable {
    /// The original COI statement text, if found.
    public let statement: String?

    /// Whether industry ties were detected in the statement.
    public let hasIndustryTies: Bool

    /// List of disclosed relationships (e.g., "grants from Pfizer").
    public let disclosedRelationships: [String]

    /// Confidence score (0.0-1.0) for the analysis.
    public let confidence: Double

    /// Creates a new COIAnalysisResult instance.
    ///
    /// - Parameters:
    ///   - statement: The original COI statement text.
    ///   - hasIndustryTies: Whether industry ties were detected.
    ///   - disclosedRelationships: List of disclosed relationships.
    ///   - confidence: Confidence score for the analysis.
    public init(
        statement: String? = nil,
        hasIndustryTies: Bool = false,
        disclosedRelationships: [String] = [],
        confidence: Double = 0.0
    ) {
        self.statement = statement
        self.hasIndustryTies = hasIndustryTies
        self.disclosedRelationships = disclosedRelationships
        self.confidence = confidence
    }

    /// Empty result when no COI statement is available.
    public static let notAvailable = COIAnalysisResult()

    /// Whether a non-empty COI statement is available.
    ///
    /// An empty statement counts as missing, matching the Python reference
    /// implementation (`if not coi_info.statement`).
    public var hasStatement: Bool {
        !(statement?.isEmpty ?? true)
    }
}

/// Data availability analysis result.
///
/// Contains information about how research data is made available, including
/// repository details and any access restrictions.
public struct DataAvailabilityResult: Sendable, Codable, Equatable {
    /// The original data availability statement text, if found.
    public let statement: String?

    /// Classified disclosure level.
    public let disclosureLevel: DataDisclosureLevel

    /// Name of the data repository, if specified.
    public let repositoryName: String?

    /// URL to the data repository or dataset.
    public let repositoryURL: URL?

    /// Accession number or dataset identifier, if provided.
    public let accessionNumber: String?

    /// List of access restrictions mentioned.
    public let restrictions: [String]

    /// Creates a new DataAvailabilityResult instance.
    ///
    /// - Parameters:
    ///   - statement: The original data availability statement text.
    ///   - disclosureLevel: Classified disclosure level.
    ///   - repositoryName: Name of the data repository.
    ///   - repositoryURL: URL to the repository or dataset.
    ///   - accessionNumber: Accession number or dataset identifier.
    ///   - restrictions: List of access restrictions.
    public init(
        statement: String? = nil,
        disclosureLevel: DataDisclosureLevel = .unknown,
        repositoryName: String? = nil,
        repositoryURL: URL? = nil,
        accessionNumber: String? = nil,
        restrictions: [String] = []
    ) {
        self.statement = statement
        self.disclosureLevel = disclosureLevel
        self.repositoryName = repositoryName
        self.repositoryURL = repositoryURL
        self.accessionNumber = accessionNumber
        self.restrictions = restrictions
    }

    /// Result when no data availability statement is found.
    public static let notStated = DataAvailabilityResult(disclosureLevel: .notStated)
}

/// Complete transparency analysis result.
///
/// Contains all transparency-related information for a single article, including
/// funding sources, trial registration, conflicts of interest, data availability,
/// and the calculated transparency score.
public struct TransparencyResult: Sendable, Codable, Equatable, Identifiable {
    /// Unique identifier for this result.
    public let id: UUID

    // MARK: - Article Identifiers

    /// Digital Object Identifier.
    public let doi: String?

    /// PubMed identifier.
    public let pmid: String?

    /// PubMed Central identifier.
    public let pmcid: String?

    /// Article title.
    public let title: String?

    // MARK: - Publication Info

    /// Journal name.
    public let journal: String?

    /// Publication date.
    public let publicationDate: Date?

    /// Author names.
    public let authors: [String]

    // MARK: - Sponsorship Analysis

    /// Primary sponsor type classification.
    public let sponsorType: SponsorType

    /// List of identified funders.
    public let funders: [FunderInfo]

    /// Whether industry funding was detected.
    public let industryFundingDetected: Bool

    /// Confidence score (0.0-1.0) for industry funding detection.
    public let industryFundingConfidence: Double

    // MARK: - Trial Registration

    /// List of clinical trial registrations found.
    public let trialRegistrations: [TrialRegistration]

    /// Results posting compliance status.
    public let resultsCompliance: ResultsComplianceStatus

    // MARK: - Conflicts of Interest

    /// COI analysis result.
    public let coiAnalysis: COIAnalysisResult

    // MARK: - Data Availability

    /// Data availability analysis result.
    public let dataAvailability: DataAvailabilityResult

    // MARK: - Outcome Reporting

    /// Whether outcome switching was detected between registration and publication.
    public let outcomeSwitchingDetected: Bool

    /// Details about detected outcome discrepancies.
    public let outcomeSwitchingDetails: [String]

    // MARK: - Scores and Indicators

    /// Overall transparency score (0-100).
    public let transparencyScore: Int

    /// Risk level classification based on score and factors.
    public let riskLevel: TransparencyRiskLevel

    /// List of identified risk indicators.
    public let riskIndicators: [String]

    // MARK: - Metadata

    /// Timestamp when the analysis was performed.
    public let analysisTimestamp: Date

    /// List of data sources used in the analysis.
    public let dataSourcesUsed: [String]

    /// Non-fatal warnings encountered during analysis.
    public let warnings: [String]

    /// Errors encountered during analysis (partial results may still be valid).
    public let errors: [String]

    /// Version of the analyzer that produced this result.
    ///
    /// `nil` for results stored before versioning existed — those predate the
    /// scoring-relevant fixes by definition, so ``isStale`` reads them as stale.
    /// Optional rather than required so pre-existing stored JSON still decodes:
    /// the persisted column is free-form JSON, and a required field would strand
    /// every earlier analysis behind a decode failure that reads as "never analysed".
    ///
    /// See ``TransparencyConstants/analyzerVersion``.
    public let analyzerVersion: Int?

    /// Whether this result was produced by an older analyzer than the current one.
    ///
    /// A stale result is not wrong so much as incomparable: the evidence reaching
    /// the scorer changed, so its score cannot be read beside a freshly computed
    /// one. Callers should offer a re-run rather than silently trusting it.
    public var isStale: Bool {
        analyzerVersion != TransparencyConstants.analyzerVersion
    }

    /// Creates a new TransparencyResult instance.
    ///
    /// - Parameters:
    ///   - id: Unique identifier (defaults to new UUID).
    ///   - doi: Digital Object Identifier.
    ///   - pmid: PubMed identifier.
    ///   - pmcid: PubMed Central identifier.
    ///   - title: Article title.
    ///   - journal: Journal name.
    ///   - publicationDate: Publication date.
    ///   - authors: Author names.
    ///   - sponsorType: Primary sponsor type classification.
    ///   - funders: List of identified funders.
    ///   - industryFundingDetected: Whether industry funding was detected.
    ///   - industryFundingConfidence: Confidence for industry funding detection.
    ///   - trialRegistrations: List of clinical trial registrations.
    ///   - resultsCompliance: Results posting compliance status.
    ///   - coiAnalysis: COI analysis result.
    ///   - dataAvailability: Data availability analysis result.
    ///   - outcomeSwitchingDetected: Whether outcome switching was detected.
    ///   - outcomeSwitchingDetails: Details about outcome discrepancies.
    ///   - transparencyScore: Overall transparency score (0-100).
    ///   - riskLevel: Risk level classification.
    ///   - riskIndicators: List of identified risk indicators.
    ///   - analysisTimestamp: When analysis was performed (defaults to now).
    ///   - dataSourcesUsed: Data sources used in analysis.
    ///   - warnings: Non-fatal warnings encountered.
    ///   - errors: Errors encountered during analysis.
    ///   - analyzerVersion: Analyzer version that produced this result (defaults
    ///     to the current one; pass `nil` only to represent a pre-versioning result).
    public init(
        id: UUID = UUID(),
        doi: String? = nil,
        pmid: String? = nil,
        pmcid: String? = nil,
        title: String? = nil,
        journal: String? = nil,
        publicationDate: Date? = nil,
        authors: [String] = [],
        sponsorType: SponsorType = .unknown,
        funders: [FunderInfo] = [],
        industryFundingDetected: Bool = false,
        industryFundingConfidence: Double = 0.0,
        trialRegistrations: [TrialRegistration] = [],
        resultsCompliance: ResultsComplianceStatus = .unknown,
        coiAnalysis: COIAnalysisResult = .notAvailable,
        dataAvailability: DataAvailabilityResult = .notStated,
        outcomeSwitchingDetected: Bool = false,
        outcomeSwitchingDetails: [String] = [],
        transparencyScore: Int = 0,
        riskLevel: TransparencyRiskLevel = .unknown,
        riskIndicators: [String] = [],
        analysisTimestamp: Date = Date(),
        dataSourcesUsed: [String] = [],
        warnings: [String] = [],
        errors: [String] = [],
        analyzerVersion: Int? = TransparencyConstants.analyzerVersion
    ) {
        self.id = id
        self.doi = doi
        self.pmid = pmid
        self.pmcid = pmcid
        self.title = title
        self.journal = journal
        self.publicationDate = publicationDate
        self.authors = authors
        self.sponsorType = sponsorType
        self.funders = funders
        self.industryFundingDetected = industryFundingDetected
        self.industryFundingConfidence = industryFundingConfidence
        self.trialRegistrations = trialRegistrations
        self.resultsCompliance = resultsCompliance
        self.coiAnalysis = coiAnalysis
        self.dataAvailability = dataAvailability
        self.outcomeSwitchingDetected = outcomeSwitchingDetected
        self.outcomeSwitchingDetails = outcomeSwitchingDetails
        self.transparencyScore = transparencyScore
        self.riskLevel = riskLevel
        self.riskIndicators = riskIndicators
        self.analysisTimestamp = analysisTimestamp
        self.dataSourcesUsed = dataSourcesUsed
        self.warnings = warnings
        self.errors = errors
        self.analyzerVersion = analyzerVersion
    }
}

// MARK: - Builder Pattern for TransparencyResult

/// Builder for constructing TransparencyResult incrementally during analysis.
///
/// Allows analysis components to populate their respective fields, then builds
/// the final immutable result with calculated score and risk level.
///
/// Example usage:
/// ```swift
/// var builder = TransparencyResultBuilder(pmid: "12345678")
/// builder.title = "Study Title"
/// builder.industryFundingDetected = true
/// builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .fullOpen)
/// let result = builder.build()
/// ```
public struct TransparencyResultBuilder: Sendable {
    /// Digital Object Identifier.
    public var doi: String?

    /// PubMed identifier.
    public var pmid: String?

    /// PubMed Central identifier.
    public var pmcid: String?

    /// Article title.
    public var title: String?

    /// Journal name.
    public var journal: String?

    /// Publication date.
    public var publicationDate: Date?

    /// Author names.
    public var authors: [String] = []

    /// Primary sponsor type classification.
    public var sponsorType: SponsorType = .unknown

    /// List of identified funders.
    public var funders: [FunderInfo] = []

    /// Whether industry funding was detected.
    public var industryFundingDetected: Bool = false

    /// Confidence score (0.0-1.0) for industry funding detection.
    public var industryFundingConfidence: Double = 0.0

    /// List of clinical trial registrations found.
    public var trialRegistrations: [TrialRegistration] = []

    /// Results posting compliance status.
    public var resultsCompliance: ResultsComplianceStatus = .unknown

    /// COI analysis result.
    public var coiAnalysis: COIAnalysisResult = .notAvailable

    /// Data availability analysis result.
    public var dataAvailability: DataAvailabilityResult = .notStated

    /// Whether outcome switching was detected.
    public var outcomeSwitchingDetected: Bool = false

    /// Details about detected outcome discrepancies.
    public var outcomeSwitchingDetails: [String] = []

    /// List of data sources used in the analysis.
    public var dataSourcesUsed: [String] = []

    /// Non-fatal warnings encountered during analysis.
    public var warnings: [String] = []

    /// Errors encountered during analysis.
    public var errors: [String] = []

    /// Creates a new TransparencyResultBuilder.
    ///
    /// - Parameters:
    ///   - doi: Digital Object Identifier.
    ///   - pmid: PubMed identifier.
    public init(doi: String? = nil, pmid: String? = nil) {
        self.doi = doi
        self.pmid = pmid
    }

    /// Build the final TransparencyResult with calculated score and risk level.
    ///
    /// Calculates the transparency score based on all populated fields using
    /// the TransparencyScorer functions.
    ///
    /// - Returns: An immutable TransparencyResult with all fields populated.
    public func build() -> TransparencyResult {
        // Calculate score using TransparencyScorer
        let score = TransparencyScorer.calculateScore(
            dataAvailability: dataAvailability,
            coiAnalysis: coiAnalysis,
            trialRegistrations: trialRegistrations,
            resultsCompliance: resultsCompliance,
            industryFundingDetected: industryFundingDetected,
            outcomeSwitchingDetected: outcomeSwitchingDetected
        )

        // Calculate risk level using TransparencyScorer
        let riskLevel = TransparencyScorer.calculateRiskLevel(
            score: score,
            industryFunding: industryFundingDetected,
            dataAvailability: dataAvailability.disclosureLevel,
            coiDisclosed: coiAnalysis.hasStatement
        )

        // Identify risk indicators using TransparencyScorer
        let riskIndicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: industryFundingDetected,
            dataAvailability: dataAvailability,
            resultsCompliance: resultsCompliance,
            coiAnalysis: coiAnalysis,
            trialRegistrations: trialRegistrations,
            outcomeSwitchingDetected: outcomeSwitchingDetected,
            title: title
        )

        return TransparencyResult(
            doi: doi,
            pmid: pmid,
            pmcid: pmcid,
            title: title,
            journal: journal,
            publicationDate: publicationDate,
            authors: authors,
            sponsorType: sponsorType,
            funders: funders,
            industryFundingDetected: industryFundingDetected,
            industryFundingConfidence: industryFundingConfidence,
            trialRegistrations: trialRegistrations,
            resultsCompliance: resultsCompliance,
            coiAnalysis: coiAnalysis,
            dataAvailability: dataAvailability,
            outcomeSwitchingDetected: outcomeSwitchingDetected,
            outcomeSwitchingDetails: outcomeSwitchingDetails,
            transparencyScore: score,
            riskLevel: riskLevel,
            riskIndicators: riskIndicators,
            dataSourcesUsed: dataSourcesUsed,
            warnings: warnings,
            errors: errors
        )
    }

    /// Build with explicit score and risk level (for use with TransparencyScorer).
    ///
    /// Use this method when you want to calculate the score externally using
    /// TransparencyScorer and pass the results in.
    ///
    /// - Parameters:
    ///   - score: Pre-calculated transparency score.
    ///   - riskLevel: Pre-calculated risk level.
    ///   - riskIndicators: Pre-calculated risk indicators.
    /// - Returns: An immutable TransparencyResult with specified scoring.
    public func build(
        score: Int,
        riskLevel: TransparencyRiskLevel,
        riskIndicators: [String]
    ) -> TransparencyResult {
        return TransparencyResult(
            doi: doi,
            pmid: pmid,
            pmcid: pmcid,
            title: title,
            journal: journal,
            publicationDate: publicationDate,
            authors: authors,
            sponsorType: sponsorType,
            funders: funders,
            industryFundingDetected: industryFundingDetected,
            industryFundingConfidence: industryFundingConfidence,
            trialRegistrations: trialRegistrations,
            resultsCompliance: resultsCompliance,
            coiAnalysis: coiAnalysis,
            dataAvailability: dataAvailability,
            outcomeSwitchingDetected: outcomeSwitchingDetected,
            outcomeSwitchingDetails: outcomeSwitchingDetails,
            transparencyScore: score,
            riskLevel: riskLevel,
            riskIndicators: riskIndicators,
            dataSourcesUsed: dataSourcesUsed,
            warnings: warnings,
            errors: errors
        )
    }

}
