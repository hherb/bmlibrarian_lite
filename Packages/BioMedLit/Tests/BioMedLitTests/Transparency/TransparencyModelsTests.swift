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

final class TransparencyModelsTests: XCTestCase {

    // MARK: - SponsorType Tests

    func testSponsorTypeDisplayNames() {
        XCTAssertEqual(SponsorType.industry.displayName, "Industry")
        XCTAssertEqual(SponsorType.government.displayName, "Government")
        XCTAssertEqual(SponsorType.academic.displayName, "Academic")
        XCTAssertEqual(SponsorType.nonprofit.displayName, "Non-Profit")
        XCTAssertEqual(SponsorType.mixed.displayName, "Mixed")
        XCTAssertEqual(SponsorType.unknown.displayName, "Unknown")
    }

    func testSponsorTypeCaseIterable() {
        XCTAssertEqual(SponsorType.allCases.count, 6)
    }

    // MARK: - DataDisclosureLevel Tests

    func testDataDisclosureLevelDisplayNames() {
        XCTAssertEqual(DataDisclosureLevel.fullOpen.displayName, "Fully Open")
        XCTAssertEqual(DataDisclosureLevel.availableOnRequest.displayName, "Available on Request")
        XCTAssertEqual(DataDisclosureLevel.restricted.displayName, "Restricted")
        XCTAssertEqual(DataDisclosureLevel.notAvailable.displayName, "Not Available")
        XCTAssertEqual(DataDisclosureLevel.notStated.displayName, "Not Stated")
        XCTAssertEqual(DataDisclosureLevel.unknown.displayName, "Unknown")
    }

    func testDataDisclosureLevelRawValues() {
        XCTAssertEqual(DataDisclosureLevel.fullOpen.rawValue, "full_open")
        XCTAssertEqual(DataDisclosureLevel.availableOnRequest.rawValue, "on_request")
        XCTAssertEqual(DataDisclosureLevel.notAvailable.rawValue, "not_available")
        XCTAssertEqual(DataDisclosureLevel.notStated.rawValue, "not_stated")
    }

    // MARK: - ResultsComplianceStatus Tests

    func testResultsComplianceStatusDisplayNames() {
        XCTAssertEqual(ResultsComplianceStatus.compliant.displayName, "Compliant")
        XCTAssertEqual(ResultsComplianceStatus.late.displayName, "Late")
        XCTAssertEqual(ResultsComplianceStatus.missing.displayName, "Missing")
        XCTAssertEqual(ResultsComplianceStatus.notRequired.displayName, "Not Required")
        XCTAssertEqual(ResultsComplianceStatus.unknown.displayName, "Unknown")
    }

    // MARK: - TransparencyRiskLevel Tests

    func testRiskLevelColors() {
        XCTAssertEqual(TransparencyRiskLevel.low.colorName, "green")
        XCTAssertEqual(TransparencyRiskLevel.medium.colorName, "orange")
        XCTAssertEqual(TransparencyRiskLevel.high.colorName, "red")
        XCTAssertEqual(TransparencyRiskLevel.unknown.colorName, "gray")
    }

    func testRiskLevelShortLabels() {
        XCTAssertEqual(TransparencyRiskLevel.low.shortLabel, "Low")
        XCTAssertEqual(TransparencyRiskLevel.medium.shortLabel, "Med")
        XCTAssertEqual(TransparencyRiskLevel.high.shortLabel, "High")
        XCTAssertEqual(TransparencyRiskLevel.unknown.shortLabel, "?")
    }

    func testRiskLevelFullLabels() {
        XCTAssertEqual(TransparencyRiskLevel.low.fullLabel, "Low Risk")
        XCTAssertEqual(TransparencyRiskLevel.medium.fullLabel, "Medium Risk")
        XCTAssertEqual(TransparencyRiskLevel.high.fullLabel, "High Risk")
        XCTAssertEqual(TransparencyRiskLevel.unknown.fullLabel, "Unknown")
    }

    // MARK: - FunderInfo Tests

    func testFunderInfoCreation() {
        let funder = FunderInfo(
            name: "Pfizer",
            funderDOI: "10.13039/100004319",
            awardNumbers: ["R01-12345"],
            isIndustry: true,
            confidence: 1.0
        )

        XCTAssertEqual(funder.name, "Pfizer")
        XCTAssertEqual(funder.funderDOI, "10.13039/100004319")
        XCTAssertEqual(funder.awardNumbers, ["R01-12345"])
        XCTAssertTrue(funder.isIndustry)
        XCTAssertEqual(funder.confidence, 1.0)
    }

    func testFunderInfoEquality() {
        // Different UUIDs make funders not equal
        let funder1 = FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0)
        let funder2 = FunderInfo(name: "Pfizer", isIndustry: true, confidence: 1.0)
        XCTAssertNotEqual(funder1, funder2)

        // Same ID should be equal
        let id = UUID()
        let funder3 = FunderInfo(id: id, name: "Pfizer", isIndustry: true, confidence: 1.0)
        let funder4 = FunderInfo(id: id, name: "Pfizer", isIndustry: true, confidence: 1.0)
        XCTAssertEqual(funder3, funder4)
    }

    func testFunderInfoCodable() throws {
        let funder = FunderInfo(
            name: "NIH",
            funderDOI: "10.13039/100000002",
            awardNumbers: ["R01-67890"],
            isIndustry: false,
            confidence: 0.95
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(funder)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(FunderInfo.self, from: data)

        XCTAssertEqual(decoded.name, funder.name)
        XCTAssertEqual(decoded.funderDOI, funder.funderDOI)
        XCTAssertEqual(decoded.awardNumbers, funder.awardNumbers)
        XCTAssertEqual(decoded.isIndustry, funder.isIndustry)
        XCTAssertEqual(decoded.confidence, funder.confidence)
    }

    // MARK: - TrialRegistration Tests

    func testTrialRegistrationCreation() {
        let completionDate = Date()
        let trial = TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: "NCT01234567",
            title: "Test Trial",
            sponsorClass: "INDUSTRY",
            leadSponsor: "Pfizer",
            resultsPosted: true,
            completionDate: completionDate,
            primaryOutcomesRegistered: ["Overall Survival"],
            secondaryOutcomesRegistered: ["Quality of Life"]
        )

        XCTAssertEqual(trial.registry, "ClinicalTrials.gov")
        XCTAssertEqual(trial.registrationId, "NCT01234567")
        XCTAssertEqual(trial.title, "Test Trial")
        XCTAssertEqual(trial.sponsorClass, "INDUSTRY")
        XCTAssertEqual(trial.leadSponsor, "Pfizer")
        XCTAssertTrue(trial.resultsPosted)
        XCTAssertEqual(trial.completionDate, completionDate)
        XCTAssertEqual(trial.primaryOutcomesRegistered, ["Overall Survival"])
        XCTAssertEqual(trial.secondaryOutcomesRegistered, ["Quality of Life"])
    }

    // MARK: - COIAnalysisResult Tests

    func testCOIAnalysisResultCreation() {
        let coi = COIAnalysisResult(
            statement: "Author received grants from Pfizer.",
            hasIndustryTies: true,
            disclosedRelationships: ["grants from Pfizer"],
            confidence: 0.9
        )

        XCTAssertEqual(coi.statement, "Author received grants from Pfizer.")
        XCTAssertTrue(coi.hasIndustryTies)
        XCTAssertEqual(coi.disclosedRelationships, ["grants from Pfizer"])
        XCTAssertEqual(coi.confidence, 0.9)
    }

    func testCOIAnalysisResultNotAvailable() {
        let coi = COIAnalysisResult.notAvailable

        XCTAssertNil(coi.statement)
        XCTAssertFalse(coi.hasIndustryTies)
        XCTAssertTrue(coi.disclosedRelationships.isEmpty)
        XCTAssertEqual(coi.confidence, 0.0)
    }

    // MARK: - DataAvailabilityResult Tests

    func testDataAvailabilityResultCreation() {
        let url = URL(string: "https://zenodo.org/record/12345")!
        let data = DataAvailabilityResult(
            statement: "Data available at Zenodo.",
            disclosureLevel: .fullOpen,
            repositoryName: "Zenodo",
            repositoryURL: url,
            accessionNumber: "12345",
            restrictions: []
        )

        XCTAssertEqual(data.statement, "Data available at Zenodo.")
        XCTAssertEqual(data.disclosureLevel, .fullOpen)
        XCTAssertEqual(data.repositoryName, "Zenodo")
        XCTAssertEqual(data.repositoryURL, url)
        XCTAssertEqual(data.accessionNumber, "12345")
        XCTAssertTrue(data.restrictions.isEmpty)
    }

    func testDataAvailabilityResultNotStated() {
        let data = DataAvailabilityResult.notStated

        XCTAssertNil(data.statement)
        XCTAssertEqual(data.disclosureLevel, .notStated)
        XCTAssertNil(data.repositoryName)
        XCTAssertNil(data.repositoryURL)
        XCTAssertNil(data.accessionNumber)
        XCTAssertTrue(data.restrictions.isEmpty)
    }

    // MARK: - TransparencyResult Tests

    func testTransparencyResultCreation() {
        let result = TransparencyResult(
            doi: "10.1000/test",
            pmid: "12345678",
            title: "Test Study",
            sponsorType: .industry,
            industryFundingDetected: true,
            transparencyScore: 65,
            riskLevel: .medium
        )

        XCTAssertEqual(result.doi, "10.1000/test")
        XCTAssertEqual(result.pmid, "12345678")
        XCTAssertEqual(result.title, "Test Study")
        XCTAssertEqual(result.sponsorType, .industry)
        XCTAssertTrue(result.industryFundingDetected)
        XCTAssertEqual(result.transparencyScore, 65)
        XCTAssertEqual(result.riskLevel, .medium)
    }

    func testTransparencyResultCodable() throws {
        let result = TransparencyResult(
            doi: "10.1000/test",
            pmid: "12345678",
            title: "Test Study",
            sponsorType: .industry,
            industryFundingDetected: true,
            transparencyScore: 65,
            riskLevel: .medium,
            riskIndicators: ["Industry-funded study"]
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(result)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(TransparencyResult.self, from: data)

        XCTAssertEqual(decoded.doi, result.doi)
        XCTAssertEqual(decoded.pmid, result.pmid)
        XCTAssertEqual(decoded.title, result.title)
        XCTAssertEqual(decoded.sponsorType, result.sponsorType)
        XCTAssertEqual(decoded.industryFundingDetected, result.industryFundingDetected)
        XCTAssertEqual(decoded.transparencyScore, result.transparencyScore)
        XCTAssertEqual(decoded.riskLevel, result.riskLevel)
        XCTAssertEqual(decoded.riskIndicators, result.riskIndicators)
    }

    func testTransparencyResultIdentifiable() {
        let result1 = TransparencyResult(pmid: "12345678")
        let result2 = TransparencyResult(pmid: "12345678")

        // Each result has a unique ID
        XCTAssertNotEqual(result1.id, result2.id)
    }

    // MARK: - TransparencyResultBuilder Tests

    func testBuilderBasicUsage() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "Test Study"
        builder.doi = "10.1000/test"
        builder.journal = "Test Journal"
        builder.authors = ["Smith J", "Doe J"]
        builder.sponsorType = .academic

        let result = builder.build()

        XCTAssertEqual(result.pmid, "12345678")
        XCTAssertEqual(result.title, "Test Study")
        XCTAssertEqual(result.doi, "10.1000/test")
        XCTAssertEqual(result.journal, "Test Journal")
        XCTAssertEqual(result.authors, ["Smith J", "Doe J"])
        XCTAssertEqual(result.sponsorType, .academic)
    }

    func testBuilderScoreCalculation() {
        // Test high transparency (good practices)
        var goodBuilder = TransparencyResultBuilder(pmid: "1")
        goodBuilder.dataAvailability = DataAvailabilityResult(disclosureLevel: .fullOpen)
        goodBuilder.coiAnalysis = COIAnalysisResult(statement: "No conflicts declared")
        goodBuilder.trialRegistrations = [TrialRegistration(registry: "ClinicalTrials.gov", registrationId: "NCT12345678")]
        goodBuilder.resultsCompliance = .compliant

        let goodResult = goodBuilder.build()
        XCTAssertGreaterThanOrEqual(goodResult.transparencyScore, 70)
        XCTAssertEqual(goodResult.riskLevel, .low)

        // Test low transparency (poor practices)
        var poorBuilder = TransparencyResultBuilder(pmid: "2")
        poorBuilder.title = "A randomized controlled trial"
        poorBuilder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        poorBuilder.industryFundingDetected = true
        poorBuilder.resultsCompliance = .missing
        poorBuilder.outcomeSwitchingDetected = true

        let poorResult = poorBuilder.build()
        XCTAssertLessThan(poorResult.transparencyScore, 40)
        XCTAssertEqual(poorResult.riskLevel, .high)
    }

    func testBuilderRiskIndicatorIdentification() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.industryFundingDetected = true
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: .notAvailable)
        builder.resultsCompliance = .missing
        builder.outcomeSwitchingDetected = true

        let result = builder.build()

        XCTAssertTrue(result.riskIndicators.contains("Industry-funded study"))
        XCTAssertTrue(result.riskIndicators.contains("Data not available"))
        XCTAssertTrue(result.riskIndicators.contains("Trial results not posted"))
        XCTAssertTrue(result.riskIndicators.contains("Outcome switching detected"))
    }

    func testBuilderWithExplicitScoring() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.title = "Test Study"

        let result = builder.build(
            score: 85,
            riskLevel: .low,
            riskIndicators: ["Custom indicator"]
        )

        XCTAssertEqual(result.transparencyScore, 85)
        XCTAssertEqual(result.riskLevel, .low)
        XCTAssertEqual(result.riskIndicators, ["Custom indicator"])
    }

    func testBuilderPreservesWarningsAndErrors() {
        var builder = TransparencyResultBuilder(pmid: "12345678")
        builder.warnings = ["CrossRef timeout"]
        builder.errors = ["ClinicalTrials.gov unavailable"]
        builder.dataSourcesUsed = ["PubMed", "Europe PMC"]

        let result = builder.build()

        XCTAssertEqual(result.warnings, ["CrossRef timeout"])
        XCTAssertEqual(result.errors, ["ClinicalTrials.gov unavailable"])
        XCTAssertEqual(result.dataSourcesUsed, ["PubMed", "Europe PMC"])
    }

    // MARK: - Sendable Conformance Tests

    func testTypesSendable() async {
        // Verify types can be used across actor boundaries
        let funder = FunderInfo(name: "NIH", isIndustry: false, confidence: 0.9)
        let trial = TrialRegistration(registry: "ClinicalTrials.gov", registrationId: "NCT12345678")
        let coi = COIAnalysisResult(statement: "No conflicts", confidence: 1.0)
        let data = DataAvailabilityResult(disclosureLevel: .fullOpen)
        let result = TransparencyResult(pmid: "12345678", transparencyScore: 80, riskLevel: .low)

        await Task {
            // Access across task boundary to verify Sendable
            XCTAssertEqual(funder.name, "NIH")
            XCTAssertEqual(trial.registrationId, "NCT12345678")
            XCTAssertEqual(coi.statement, "No conflicts")
            XCTAssertEqual(data.disclosureLevel, .fullOpen)
            XCTAssertEqual(result.transparencyScore, 80)
        }.value
    }
}
