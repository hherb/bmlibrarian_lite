# Step 01: Data Models

## Goal

Create immutable, Sendable data models for transparency analysis results.

## File to Create

### `Sources/BioMedLit/Transparency/Models/TransparencyModels.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

// MARK: - Enums

/// Classification of study sponsor types.
public enum SponsorType: String, Sendable, Codable, CaseIterable {
    case industry
    case government
    case academic
    case nonprofit
    case mixed
    case unknown

    /// Human-readable display name.
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
public enum DataDisclosureLevel: String, Sendable, Codable, CaseIterable {
    case fullOpen = "full_open"
    case availableOnRequest = "on_request"
    case restricted
    case notAvailable = "not_available"
    case notStated = "not_stated"
    case unknown

    /// Human-readable display name.
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
public enum ResultsComplianceStatus: String, Sendable, Codable, CaseIterable {
    case compliant
    case late
    case missing
    case notRequired = "not_required"
    case unknown

    /// Human-readable display name.
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
public enum TransparencyRiskLevel: String, Sendable, Codable, CaseIterable {
    case low
    case medium
    case high
    case unknown

    /// SwiftUI color name for the risk level.
    public var colorName: String {
        switch self {
        case .low: return "green"
        case .medium: return "orange"
        case .high: return "red"
        case .unknown: return "gray"
        }
    }

    /// Short label for compact UI.
    public var shortLabel: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Med"
        case .high: return "High"
        case .unknown: return "?"
        }
    }

    /// Full label for tooltips.
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
public struct FunderInfo: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let name: String
    public let funderDOI: String?
    public let awardNumbers: [String]
    public let isIndustry: Bool
    public let confidence: Double

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
public struct TrialRegistration: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID
    public let registry: String
    public let registrationId: String
    public let title: String?
    public let sponsorClass: String?
    public let leadSponsor: String?
    public let resultsPosted: Bool
    public let completionDate: Date?
    public let primaryOutcomesRegistered: [String]
    public let secondaryOutcomesRegistered: [String]

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
public struct COIAnalysisResult: Sendable, Codable, Equatable {
    public let statement: String?
    public let hasIndustryTies: Bool
    public let disclosedRelationships: [String]
    public let confidence: Double

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
}

/// Data availability analysis result.
public struct DataAvailabilityResult: Sendable, Codable, Equatable {
    public let statement: String?
    public let disclosureLevel: DataDisclosureLevel
    public let repositoryName: String?
    public let repositoryURL: URL?
    public let accessionNumber: String?
    public let restrictions: [String]

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
public struct TransparencyResult: Sendable, Codable, Equatable, Identifiable {
    public let id: UUID

    // Article identifiers
    public let doi: String?
    public let pmid: String?
    public let pmcid: String?
    public let title: String?

    // Publication info
    public let journal: String?
    public let publicationDate: Date?
    public let authors: [String]

    // Sponsorship analysis
    public let sponsorType: SponsorType
    public let funders: [FunderInfo]
    public let industryFundingDetected: Bool
    public let industryFundingConfidence: Double

    // Trial registration
    public let trialRegistrations: [TrialRegistration]
    public let resultsCompliance: ResultsComplianceStatus

    // Conflicts of interest
    public let coiAnalysis: COIAnalysisResult

    // Data availability
    public let dataAvailability: DataAvailabilityResult

    // Outcome reporting
    public let outcomeSwitchingDetected: Bool
    public let outcomeSwitchingDetails: [String]

    // Scores and indicators
    public let transparencyScore: Int
    public let riskLevel: TransparencyRiskLevel
    public let riskIndicators: [String]

    // Metadata
    public let analysisTimestamp: Date
    public let dataSourcesUsed: [String]
    public let warnings: [String]
    public let errors: [String]

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
        errors: [String] = []
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
    }
}

// MARK: - Builder Pattern for TransparencyResult

/// Builder for constructing TransparencyResult incrementally during analysis.
public struct TransparencyResultBuilder: Sendable {
    public var doi: String?
    public var pmid: String?
    public var pmcid: String?
    public var title: String?
    public var journal: String?
    public var publicationDate: Date?
    public var authors: [String] = []
    public var sponsorType: SponsorType = .unknown
    public var funders: [FunderInfo] = []
    public var industryFundingDetected: Bool = false
    public var industryFundingConfidence: Double = 0.0
    public var trialRegistrations: [TrialRegistration] = []
    public var resultsCompliance: ResultsComplianceStatus = .unknown
    public var coiAnalysis: COIAnalysisResult = .notAvailable
    public var dataAvailability: DataAvailabilityResult = .notStated
    public var outcomeSwitchingDetected: Bool = false
    public var outcomeSwitchingDetails: [String] = []
    public var dataSourcesUsed: [String] = []
    public var warnings: [String] = []
    public var errors: [String] = []

    public init(doi: String? = nil, pmid: String? = nil) {
        self.doi = doi
        self.pmid = pmid
    }

    /// Build the final TransparencyResult with calculated score and risk level.
    public func build() -> TransparencyResult {
        // Calculate score using pure function
        let score = TransparencyScorer.calculateScore(
            dataAvailability: dataAvailability,
            coiAnalysis: coiAnalysis,
            trialRegistrations: trialRegistrations,
            resultsCompliance: resultsCompliance,
            industryFundingDetected: industryFundingDetected,
            outcomeSwitchingDetected: outcomeSwitchingDetected
        )

        // Calculate risk level using pure function
        let riskLevel = TransparencyScorer.calculateRiskLevel(
            score: score,
            industryFunding: industryFundingDetected,
            dataAvailability: dataAvailability.disclosureLevel,
            coiDisclosed: coiAnalysis.statement != nil
        )

        // Identify risk indicators using pure function
        let riskIndicators = TransparencyScorer.identifyRiskIndicators(
            industryFundingDetected: industryFundingDetected,
            dataAvailability: dataAvailability,
            resultsCompliance: resultsCompliance,
            coiAnalysis: coiAnalysis,
            trialRegistrations: trialRegistrations,
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
}
```

## Testing

### `Tests/BioMedLitTests/Transparency/TransparencyModelsTests.swift`

```swift
import XCTest
@testable import BioMedLit

final class TransparencyModelsTests: XCTestCase {

    func testSponsorTypeDisplayNames() {
        XCTAssertEqual(SponsorType.industry.displayName, "Industry")
        XCTAssertEqual(SponsorType.government.displayName, "Government")
        XCTAssertEqual(SponsorType.academic.displayName, "Academic")
    }

    func testDataDisclosureLevelDisplayNames() {
        XCTAssertEqual(DataDisclosureLevel.fullOpen.displayName, "Fully Open")
        XCTAssertEqual(DataDisclosureLevel.availableOnRequest.displayName, "Available on Request")
    }

    func testFunderInfoEquality() {
        let funder1 = FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0)
        let funder2 = FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0)
        // Note: UUIDs differ, so they are not equal
        XCTAssertNotEqual(funder1, funder2)

        // Same ID should be equal
        let id = UUID()
        let funder3 = FunderInfo(id: id, name: "Pfizer", isIndustry: true, confidence: 1.0)
        let funder4 = FunderInfo(id: id, name: "Pfizer", isIndustry: true, confidence: 1.0)
        XCTAssertEqual(funder3, funder4)
    }

    func testTransparencyResultCodable() throws {
        let result = TransparencyResult(
            doi: "10.1000/test",
            pmid: "12345678",
            title: "Test Study",
            sponsorType: .industry,
            industryFundingDetected: true,
            transparencyScore: 65,
            riskLevel: .medium
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TransparencyResult.self, from: data)

        XCTAssertEqual(decoded.doi, result.doi)
        XCTAssertEqual(decoded.pmid, result.pmid)
        XCTAssertEqual(decoded.sponsorType, result.sponsorType)
        XCTAssertEqual(decoded.transparencyScore, result.transparencyScore)
    }

    func testRiskLevelColors() {
        XCTAssertEqual(TransparencyRiskLevel.low.colorName, "green")
        XCTAssertEqual(TransparencyRiskLevel.medium.colorName, "orange")
        XCTAssertEqual(TransparencyRiskLevel.high.colorName, "red")
    }
}
```

## Dependencies

None - uses only Foundation.

## Notes

- All types conform to `Sendable` for safe concurrent usage
- All types conform to `Codable` for persistence/serialization
- `TransparencyResultBuilder` allows incremental construction during analysis
- Enums provide display names for UI integration
- `TransparencyRiskLevel` provides color names for SwiftUI
