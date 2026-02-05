# Step 10: Transparency Analysis Service

## Goal

Create the main orchestration service that combines all analysis components.

## File to Create

### `Sources/BioMedLit/Transparency/Services/TransparencyAnalysisService.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Main service for analyzing study transparency.
///
/// Orchestrates data fetching from multiple APIs and applies pure analysis functions.
///
/// Usage:
/// ```swift
/// let service = TransparencyAnalysisService(email: "user@example.com")
/// let result = try await service.analyze(pmid: "33301246")
/// // or
/// let result = try await service.analyze(doi: "10.1056/NEJMoa2034577")
/// ```
public actor TransparencyAnalysisService {

    // MARK: - Properties

    private let email: String
    private let pubmedApiKey: String?

    // Services (lazily initialized)
    private var crossRefService: CrossRefService?
    private var clinicalTrialsService: ClinicalTrialsService?
    private var pubmedService: PubMedService?
    private var europePMCService: EuropePMCService?

    // MARK: - Initialization

    /// Initialize the transparency analysis service.
    ///
    /// - Parameters:
    ///   - email: Contact email (required for API access)
    ///   - pubmedApiKey: Optional NCBI API key for higher rate limits
    public init(email: String, pubmedApiKey: String? = nil) {
        self.email = email
        self.pubmedApiKey = pubmedApiKey
    }

    // MARK: - Main Analysis

    /// Analyze a study for transparency indicators.
    ///
    /// - Parameters:
    ///   - doi: Digital Object Identifier (optional if PMID provided)
    ///   - pmid: PubMed ID (optional if DOI provided)
    ///   - fullText: Optional full text for enhanced analysis
    /// - Returns: TransparencyResult with complete analysis
    /// - Throws: TransparencyAnalysisError if analysis fails
    public func analyze(
        doi: String? = nil,
        pmid: String? = nil,
        fullText: String? = nil
    ) async throws -> TransparencyResult {
        guard doi != nil || pmid != nil else {
            throw TransparencyAnalysisError.noIdentifiers
        }

        var builder = TransparencyResultBuilder(doi: doi, pmid: pmid)

        // Step 1: Fetch basic metadata
        await fetchBasicMetadata(builder: &builder)

        // Step 2: Fetch funder information
        await fetchFunderInfo(builder: &builder)

        // Step 3: Fetch trial registration info
        await fetchTrialInfo(builder: &builder)

        // Step 4: Analyze COI
        analyzeCOI(builder: &builder)

        // Step 5: Analyze data availability
        await analyzeDataAvailability(builder: &builder, fullText: fullText)

        // Step 6: Check for discrepancies
        checkDiscrepancies(builder: &builder)

        BioMedLitLib.logger?.info(
            "Transparency analysis complete: score=\(builder.build().transparencyScore)",
            category: .analysis
        )

        return builder.build()
    }

    // MARK: - Analysis Steps

    /// Fetch basic article metadata from PubMed and CrossRef.
    private func fetchBasicMetadata(builder: inout TransparencyResultBuilder) async {
        // Try PubMed first
        if let pmid = builder.pmid {
            do {
                let pubmed = getPubMedService()
                let results = try await pubmed.search(query: pmid, maxResults: 1)
                if let article = results.articles.first {
                    builder.title = article.title
                    builder.journal = article.journal
                    builder.authors = article.authors.components(separatedBy: ", ")
                    builder.pmcid = article.pmcId

                    // Get DOI if not provided
                    if builder.doi == nil {
                        builder.doi = article.doi
                    }

                    builder.dataSourcesUsed.append("PubMed")
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "PubMed fetch failed: \(error.localizedDescription)",
                    category: .network
                )
            }
        }

        // Try CrossRef if we have DOI
        if let doi = builder.doi {
            do {
                let crossRef = getCrossRefService()
                let work = try await crossRef.getWork(doi: doi)

                if let work = work {
                    builder.dataSourcesUsed.append("CrossRef")

                    // Fill in missing data
                    if builder.title == nil {
                        builder.title = crossRef.extractTitle(from: work)
                    }
                    if builder.journal == nil {
                        builder.journal = crossRef.extractJournal(from: work)
                    }

                    // Store CrossRef funders for later
                    let crossRefFunders = crossRef.extractFunders(from: work)
                    builder.funders = FundingAnalyzer.mergeFunders(builder.funders, crossRefFunders)
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "CrossRef fetch failed: \(error.localizedDescription)",
                    category: .network
                )
            }
        }
    }

    /// Fetch and analyze funder information.
    private func fetchFunderInfo(builder: inout TransparencyResultBuilder) async {
        // Funders may already be populated from CrossRef in fetchBasicMetadata

        // Determine sponsor type
        builder.sponsorType = FundingAnalyzer.determineSponsorType(from: builder.funders)

        // Determine industry funding status
        let (detected, confidence) = FundingAnalyzer.industryFundingStatus(from: builder.funders)
        builder.industryFundingDetected = detected
        builder.industryFundingConfidence = confidence
    }

    /// Fetch clinical trial registration information.
    private func fetchTrialInfo(builder: inout TransparencyResultBuilder) async {
        // Look for NCT IDs in title or abstract
        var nctIds: [String] = []

        if let title = builder.title {
            nctIds.append(contentsOf: TrialComplianceAnalyzer.extractNCTIds(from: title))
        }

        // TODO: Extract from PubMed DataBank links when available

        // Fetch each trial
        let clinicalTrials = getClinicalTrialsService()

        for nctId in nctIds {
            do {
                if let study = try await clinicalTrials.getStudy(nctId: nctId),
                   let registration = clinicalTrials.extractTrialInfo(from: study) {

                    builder.trialRegistrations.append(registration)
                    builder.dataSourcesUsed.append("ClinicalTrials.gov")

                    // Update sponsor type based on trial sponsor
                    if TrialComplianceAnalyzer.isIndustrySponsor(registration.sponsorClass) {
                        builder.industryFundingDetected = true
                        builder.sponsorType = FundingAnalyzer.updateSponsorType(
                            builder.sponsorType,
                            withTrialSponsorClass: registration.sponsorClass
                        )
                    }
                }
            } catch {
                BioMedLitLib.logger?.warning(
                    "ClinicalTrials.gov fetch failed for \(nctId): \(error.localizedDescription)",
                    category: .network
                )
            }
        }

        // Check results compliance for first trial
        if let firstTrial = builder.trialRegistrations.first {
            builder.resultsCompliance = TrialComplianceAnalyzer.checkResultsCompliance(
                trial: firstTrial,
                publicationDate: builder.publicationDate
            )
        }
    }

    /// Analyze conflict of interest statement.
    private func analyzeCOI(builder: inout TransparencyResultBuilder) {
        // COI statement would come from PubMed XML or full text
        // For now, mark as not available
        // TODO: Extract from PubMed MedlineCitation/CoiStatement

        builder.coiAnalysis = COIAnalyzer.analyze(statement: nil)
    }

    /// Analyze data availability statement.
    private func analyzeDataAvailability(
        builder: inout TransparencyResultBuilder,
        fullText: String?
    ) async {
        var dataStatement: String?

        // Try to get from full text if provided
        if let fullText = fullText {
            dataStatement = extractDataAvailabilitySection(from: fullText)
        }

        // Try Europe PMC if we have PMC ID
        if dataStatement == nil, let pmcId = builder.pmcid {
            do {
                let europePMC = getEuropePMCService()
                // Note: Would need to add full text XML fetch to Europe PMC service
                // and extract data availability section
                _ = europePMC
            } catch {
                // Ignore - data availability will be marked as not stated
            }
        }

        builder.dataAvailability = DataAvailabilityAnalyzer.analyze(statement: dataStatement)
    }

    /// Check for discrepancies between funding and disclosure.
    private func checkDiscrepancies(builder: inout TransparencyResultBuilder) {
        // Check COI vs funding discrepancy
        if let warning = COIAnalyzer.checkFundingCOIDiscrepancy(
            coiResult: builder.coiAnalysis,
            industryFundingDetected: builder.industryFundingDetected
        ) {
            builder.warnings.append(warning)
        }

        // Check for missing trial registration
        if let warning = TrialComplianceAnalyzer.checkMissingRegistration(
            title: builder.title,
            registrations: builder.trialRegistrations
        ) {
            builder.warnings.append(warning)
        }
    }

    // MARK: - Full Text Helpers

    /// Extract data availability section from full text.
    private func extractDataAvailabilitySection(from fullText: String) -> String? {
        // Simple extraction - look for common section headers
        let patterns = [
            #"(?i)data\s+availability[:\s]+([^§\n]+(?:\n[^§\n]+){0,3})"#,
            #"(?i)availability\s+of\s+data[:\s]+([^§\n]+(?:\n[^§\n]+){0,3})"#,
            #"(?i)data\s+sharing[:\s]+([^§\n]+(?:\n[^§\n]+){0,3})"#,
        ]

        for pattern in patterns {
            if let extracted = RegexHelper.extractFirst(pattern: pattern, from: fullText) {
                return extracted.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        return nil
    }

    // MARK: - Service Accessors

    private func getCrossRefService() -> CrossRefService {
        if crossRefService == nil {
            crossRefService = CrossRefService(email: email)
        }
        return crossRefService!
    }

    private func getClinicalTrialsService() -> ClinicalTrialsService {
        if clinicalTrialsService == nil {
            clinicalTrialsService = ClinicalTrialsService()
        }
        return clinicalTrialsService!
    }

    private func getPubMedService() -> PubMedService {
        if pubmedService == nil {
            pubmedService = PubMedService(email: email, apiKey: pubmedApiKey)
        }
        return pubmedService!
    }

    private func getEuropePMCService() -> EuropePMCService {
        if europePMCService == nil {
            europePMCService = EuropePMCService()
        }
        return europePMCService!
    }
}

// MARK: - Errors

/// Errors that can occur during transparency analysis.
public enum TransparencyAnalysisError: LocalizedError, Sendable {
    case noIdentifiers
    case analysisFailure(String)

    public var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Must provide either DOI or PMID for analysis"
        case .analysisFailure(let message):
            return "Analysis failed: \(message)"
        }
    }
}

// MARK: - Log Category Extension

extension BioMedLitLogCategory {
    /// Transparency analysis logging category.
    public static let analysis = BioMedLitLogCategory(rawValue: "transparency")
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class TransparencyAnalysisServiceTests: XCTestCase {

    // MARK: - Input Validation Tests

    func testAnalyzeNoIdentifiersThrows() async {
        let service = TransparencyAnalysisService(email: "test@example.com")

        do {
            _ = try await service.analyze(doi: nil, pmid: nil)
            XCTFail("Should throw noIdentifiers error")
        } catch TransparencyAnalysisError.noIdentifiers {
            // Expected
        } catch {
            XCTFail("Wrong error type: \(error)")
        }
    }

    // MARK: - Integration Tests (require mocking or live API)

    // Note: Full integration tests would require mocking the underlying services
    // or using actual API calls (not recommended for unit tests)

    func testAnalyzeWithDOIOnly() async throws {
        // This test would need mocked services
        // Demonstrating the expected call pattern:
        /*
        let service = TransparencyAnalysisService(email: "test@example.com")
        let result = try await service.analyze(doi: "10.1000/test")
        XCTAssertNotNil(result)
        XCTAssertEqual(result.doi, "10.1000/test")
        */
    }

    func testAnalyzeWithPMIDOnly() async throws {
        // This test would need mocked services
    }

    // MARK: - Data Availability Extraction Tests

    func testExtractDataAvailabilitySection() async {
        let service = TransparencyAnalysisService(email: "test@example.com")

        let fullText = """
        Methods section here...

        Data Availability: All data are available in the Zenodo repository
        under accession number 12345.

        Author contributions...
        """

        // Note: extractDataAvailabilitySection is private, so we'd test via analyze()
        // or make it internal for testing
    }

    // MARK: - Error Handling Tests

    func testTransparencyAnalysisErrorDescriptions() {
        XCTAssertNotNil(TransparencyAnalysisError.noIdentifiers.errorDescription)
        XCTAssertNotNil(TransparencyAnalysisError.analysisFailure("test").errorDescription)
    }
}
```

## Dependencies

- All previous steps (01-09)
- Existing `PubMedService`
- Existing `EuropePMCService`

## Notes

- Actor ensures thread-safe service access
- Services are lazily initialized
- Uses builder pattern for incremental result construction
- Gracefully handles partial failures (logs warnings, continues analysis)
- Full text analysis is optional enhancement
