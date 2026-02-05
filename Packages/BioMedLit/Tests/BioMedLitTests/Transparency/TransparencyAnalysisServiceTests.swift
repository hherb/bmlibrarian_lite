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

import XCTest
@testable import BioMedLit

/// Unit tests for TransparencyAnalysisService.
///
/// Tests cover:
/// - Input validation
/// - Error handling
/// - Error descriptions
///
/// Note: Integration tests with live API calls are in separate test files
/// and require the RUN_INTEGRATION_TESTS environment variable to be set.
final class TransparencyAnalysisServiceTests: XCTestCase {

    // MARK: - Input Validation Tests

    /// Test that analyze throws noIdentifiers when neither DOI nor PMID provided.
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

    /// Test that analyze accepts DOI only.
    func testAnalyzeAcceptsDOIOnly() async {
        let service = TransparencyAnalysisService(email: "test@example.com")

        // This will likely fail due to network, but should not throw noIdentifiers
        do {
            _ = try await service.analyze(doi: "10.1000/invalid-test-doi")
            // If it succeeds or fails for other reasons, that's fine
        } catch TransparencyAnalysisError.noIdentifiers {
            XCTFail("Should not throw noIdentifiers when DOI is provided")
        } catch {
            // Other errors are expected (network, not found, etc.)
        }
    }

    /// Test that analyze accepts PMID only.
    func testAnalyzeAcceptsPMIDOnly() async {
        let service = TransparencyAnalysisService(email: "test@example.com")

        // This will likely fail due to network, but should not throw noIdentifiers
        do {
            _ = try await service.analyze(pmid: "00000000")
            // If it succeeds or fails for other reasons, that's fine
        } catch TransparencyAnalysisError.noIdentifiers {
            XCTFail("Should not throw noIdentifiers when PMID is provided")
        } catch {
            // Other errors are expected (network, not found, etc.)
        }
    }

    /// Test that analyze accepts both DOI and PMID.
    func testAnalyzeAcceptsBothIdentifiers() async {
        let service = TransparencyAnalysisService(email: "test@example.com")

        do {
            _ = try await service.analyze(doi: "10.1000/test", pmid: "12345678")
        } catch TransparencyAnalysisError.noIdentifiers {
            XCTFail("Should not throw noIdentifiers when both identifiers provided")
        } catch {
            // Other errors are expected
        }
    }

    // MARK: - Error Description Tests

    /// Test TransparencyAnalysisError descriptions.
    func testTransparencyAnalysisErrorDescriptions() {
        let noIdentifiersError = TransparencyAnalysisError.noIdentifiers
        XCTAssertNotNil(noIdentifiersError.errorDescription)
        XCTAssertTrue(noIdentifiersError.errorDescription?.contains("DOI") ?? false)
        XCTAssertTrue(noIdentifiersError.errorDescription?.contains("PMID") ?? false)

        let analysisFailureError = TransparencyAnalysisError.analysisFailure("Test failure reason")
        XCTAssertNotNil(analysisFailureError.errorDescription)
        XCTAssertTrue(analysisFailureError.errorDescription?.contains("Test failure reason") ?? false)
    }

    // MARK: - Service Initialization Tests

    /// Test service can be initialized with minimal parameters.
    func testServiceInitMinimal() {
        let service = TransparencyAnalysisService(email: "test@example.com")
        XCTAssertNotNil(service)
    }

    /// Test service can be initialized with all parameters.
    func testServiceInitFull() {
        let session = URLSession(configuration: .default)
        let service = TransparencyAnalysisService(
            email: "test@example.com",
            pubmedApiKey: "test-api-key",
            session: session
        )
        XCTAssertNotNil(service)
    }

    // MARK: - TransparencyResultBuilder Tests

    /// Test builder creates result with default values.
    func testBuilderDefaultValues() {
        let builder = TransparencyResultBuilder()
        let result = builder.build()

        XCTAssertNil(result.doi)
        XCTAssertNil(result.pmid)
        XCTAssertNil(result.title)
        XCTAssertEqual(result.sponsorType, .unknown)
        XCTAssertFalse(result.industryFundingDetected)
        XCTAssertTrue(result.funders.isEmpty)
        XCTAssertTrue(result.trialRegistrations.isEmpty)
        XCTAssertEqual(result.resultsCompliance, .unknown)
        XCTAssertEqual(result.dataAvailability.disclosureLevel, .notStated)
    }

    /// Test builder with identifiers.
    func testBuilderWithIdentifiers() {
        var builder = TransparencyResultBuilder(doi: "10.1000/test", pmid: "12345678")
        builder.title = "Test Title"
        builder.journal = "Test Journal"

        let result = builder.build()

        XCTAssertEqual(result.doi, "10.1000/test")
        XCTAssertEqual(result.pmid, "12345678")
        XCTAssertEqual(result.title, "Test Title")
        XCTAssertEqual(result.journal, "Test Journal")
    }

    /// Test builder calculates score correctly.
    func testBuilderCalculatesScore() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.dataAvailability = DataAvailabilityResult(
            statement: "Data available in Zenodo",
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo"
        )
        builder.coiAnalysis = COIAnalysisResult(
            statement: "No conflicts declared",
            hasIndustryTies: false,
            confidence: 0.9
        )

        let result = builder.build()

        // Base score (50) + full open data (20) + COI statement (10) = 80
        XCTAssertEqual(result.transparencyScore, 80)
    }

    /// Test builder with industry funding and no data sharing.
    func testBuilderIndustryNoDataPenalty() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.industryFundingDetected = true
        builder.dataAvailability = DataAvailabilityResult(
            statement: "Data not available due to proprietary restrictions",
            disclosureLevel: .notAvailable
        )

        let result = builder.build()

        // Base (50) - no data (-10) - missing COI (-5) - industry+no data (-10) = 25
        XCTAssertEqual(result.transparencyScore, 25)
        XCTAssertEqual(result.riskLevel, .high)
    }

    /// Test builder with trial registration.
    func testBuilderWithTrialRegistration() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.trialRegistrations = [TransparencyTestFixtures.makeIndustryTrialRegistration()]
        builder.resultsCompliance = .compliant

        let result = builder.build()

        // Base (50) + trial reg (10) + results compliant (5) - no COI (-5) - no data statement (-5) = 55
        XCTAssertEqual(result.transparencyScore, 55)
        XCTAssertTrue(result.dataSourcesUsed.isEmpty) // Only builder sets this
    }

    /// Test builder with outcome switching detection.
    func testBuilderOutcomeSwitchingPenalty() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.outcomeSwitchingDetected = true
        builder.outcomeSwitchingDetails = ["Primary outcome changed"]

        let result = builder.build()

        // Base (50) - outcome switching (-15) - no COI (-5) - no data statement (-5) = 25
        XCTAssertEqual(result.transparencyScore, 25)
        XCTAssertTrue(result.outcomeSwitchingDetected)
        XCTAssertEqual(result.outcomeSwitchingDetails.count, 1)
    }

    /// Test builder adds warnings.
    func testBuilderWarnings() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.warnings = ["Warning 1", "Warning 2"]
        builder.errors = ["Error 1"]

        let result = builder.build()

        XCTAssertEqual(result.warnings.count, 2)
        XCTAssertEqual(result.errors.count, 1)
    }

    /// Test builder adds data sources.
    func testBuilderDataSources() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.dataSourcesUsed = ["PubMed", "CrossRef", "ClinicalTrials.gov"]

        let result = builder.build()

        XCTAssertEqual(result.dataSourcesUsed.count, 3)
        XCTAssertTrue(result.dataSourcesUsed.contains("PubMed"))
        XCTAssertTrue(result.dataSourcesUsed.contains("CrossRef"))
        XCTAssertTrue(result.dataSourcesUsed.contains("ClinicalTrials.gov"))
    }

    /// Test builder with explicit score.
    func testBuilderExplicitScore() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        let result = builder.build(
            score: 75,
            riskLevel: .medium,
            riskIndicators: ["Industry funding detected"]
        )

        XCTAssertEqual(result.transparencyScore, 75)
        XCTAssertEqual(result.riskLevel, .medium)
        XCTAssertEqual(result.riskIndicators.count, 1)
    }

    // MARK: - Risk Level Tests

    /// Test high risk for low score.
    func testRiskLevelHighForLowScore() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.industryFundingDetected = true
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        // Don't set COI to trigger missing COI penalty

        let result = builder.build()

        XCTAssertEqual(result.riskLevel, .high)
    }

    /// Test low risk for high score.
    func testRiskLevelLowForHighScore() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.dataAvailability = DataAvailabilityResult(
            statement: "Data available in Zenodo",
            disclosureLevel: .fullOpen
        )
        builder.coiAnalysis = COIAnalysisResult(
            statement: "No conflicts",
            hasIndustryTies: false,
            confidence: 0.9
        )
        builder.trialRegistrations = [TransparencyTestFixtures.makeNIHTrialRegistration()]
        builder.resultsCompliance = .compliant

        let result = builder.build()

        // Score should be high enough for low risk
        XCTAssertGreaterThan(result.transparencyScore, TransparencyConstants.mediumRiskScoreThreshold)
        XCTAssertEqual(result.riskLevel, .low)
    }

    // MARK: - Risk Indicators Tests

    /// Test risk indicators include industry funding.
    func testRiskIndicatorsIncludeIndustryFunding() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.industryFundingDetected = true
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)

        let result = builder.build()

        XCTAssertTrue(result.riskIndicators.contains { $0.contains("Industry funding") })
    }

    /// Test risk indicators include missing COI.
    func testRiskIndicatorsIncludeMissingCOI() {
        let builder = TransparencyResultBuilder(pmid: "12345678")
        let result = builder.build()

        XCTAssertTrue(result.riskIndicators.contains { $0.contains("conflict of interest") })
    }

    /// Test risk indicators for trial without registration.
    func testRiskIndicatorsMissingTrialRegistration() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "A Randomized Controlled Trial of Drug X"
        // No trial registrations

        let result = builder.build()

        XCTAssertTrue(result.riskIndicators.contains { $0.contains("without") && $0.contains("registration") })
    }
}
