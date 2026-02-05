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

/// Unit tests for ClinicalTrialsService.
///
/// Tests cover:
/// - Trial information extraction from API responses
/// - Sponsor class detection
/// - Outcomes extraction
/// - Results status detection
/// - Error handling
final class ClinicalTrialsServiceTests: XCTestCase {

    // MARK: - Properties

    var service: ClinicalTrialsService!

    // MARK: - Setup

    override func setUp() {
        super.setUp()
        service = ClinicalTrialsService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Trial Info Extraction Tests

    /// Test extractTrialInfo with industry trial data.
    func testExtractTrialInfoIndustry() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.industryTrialStudyJSON)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.registrationId, "NCT01234567")
        XCTAssertEqual(registration?.registry, TransparencyConstants.clinicalTrialsRegistryName)
        XCTAssertEqual(registration?.title, "A Phase III Study of Drug X vs Placebo")
        XCTAssertEqual(registration?.sponsorClass, "INDUSTRY")
        XCTAssertEqual(registration?.leadSponsor, "Pfizer Inc.")
        XCTAssertTrue(registration?.resultsPosted ?? false)
    }

    /// Test extractTrialInfo with NIH trial data.
    func testExtractTrialInfoNIH() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.nihTrialStudyJSON)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.registrationId, "NCT87654321")
        XCTAssertEqual(registration?.sponsorClass, "NIH")
        XCTAssertEqual(registration?.leadSponsor, "National Heart, Lung, and Blood Institute")
        XCTAssertFalse(registration?.resultsPosted ?? true)
    }

    /// Test extractTrialInfo with trial without results.
    func testExtractTrialInfoWithoutResults() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.trialWithoutResultsJSON)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.registrationId, "NCT99999999")
        XCTAssertFalse(registration?.resultsPosted ?? true)
    }

    /// Test extractTrialInfo returns nil for invalid data.
    func testExtractTrialInfoInvalid() {
        let registration = service.extractTrialInfo(from: ["invalid": "data"])
        XCTAssertNil(registration)
    }

    /// Test extractTrialInfo returns nil for nil input.
    func testExtractTrialInfoNil() {
        let registration = service.extractTrialInfo(from: nil)
        XCTAssertNil(registration)
    }

    // MARK: - Outcomes Extraction Tests

    /// Test primary outcomes extraction.
    func testExtractPrimaryOutcomes() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.industryTrialStudyJSON)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.primaryOutcomesRegistered.count, 2)
        XCTAssertTrue(registration?.primaryOutcomesRegistered.contains("Change in blood pressure from baseline") ?? false)
        XCTAssertTrue(registration?.primaryOutcomesRegistered.contains("Time to first cardiovascular event") ?? false)
    }

    /// Test secondary outcomes extraction.
    func testExtractSecondaryOutcomes() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.industryTrialStudyJSON)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.secondaryOutcomesRegistered.count, 1)
        XCTAssertEqual(registration?.secondaryOutcomesRegistered.first, "Quality of life score")
    }

    /// Test empty outcomes when not present.
    func testExtractOutcomesEmpty() {
        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT00000000",
                ],
            ],
            "hasResults": false,
        ]

        let registration = service.extractTrialInfo(from: study)
        XCTAssertNotNil(registration)
        XCTAssertTrue(registration?.primaryOutcomesRegistered.isEmpty ?? false)
        XCTAssertTrue(registration?.secondaryOutcomesRegistered.isEmpty ?? false)
    }

    // MARK: - Completion Date Tests

    /// Test completion date extraction with full date.
    func testExtractCompletionDateFull() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.industryTrialStudyJSON)

        XCTAssertNotNil(registration?.completionDate)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: registration!.completionDate!), 2023)
        XCTAssertEqual(calendar.component(.month, from: registration!.completionDate!), 6)
        XCTAssertEqual(calendar.component(.day, from: registration!.completionDate!), 30)
    }

    /// Test completion date extraction with month-year only.
    func testExtractCompletionDateMonthYear() {
        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT00000001",
                ],
                "statusModule": [
                    "completionDateStruct": [
                        "date": "2024-03",
                    ],
                ],
            ],
            "hasResults": false,
        ]

        let registration = service.extractTrialInfo(from: study)
        XCTAssertNotNil(registration?.completionDate)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: registration!.completionDate!), 2024)
        XCTAssertEqual(calendar.component(.month, from: registration!.completionDate!), 3)
    }

    /// Test completion date extraction with year only.
    func testExtractCompletionDateYearOnly() {
        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT00000002",
                ],
                "statusModule": [
                    "completionDateStruct": [
                        "date": "2024",
                    ],
                ],
            ],
            "hasResults": false,
        ]

        let registration = service.extractTrialInfo(from: study)
        XCTAssertNotNil(registration?.completionDate)

        let calendar = Calendar.current
        XCTAssertEqual(calendar.component(.year, from: registration!.completionDate!), 2024)
    }

    /// Test completion date nil when not present.
    func testExtractCompletionDateMissing() {
        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT00000003",
                ],
            ],
            "hasResults": false,
        ]

        let registration = service.extractTrialInfo(from: study)
        XCTAssertNil(registration?.completionDate)
    }

    // MARK: - Multiple Trials Tests

    /// Test extractTrialInfos with multiple studies.
    func testExtractTrialInfosMultiple() {
        let studies: [String: [String: Any]?] = [
            "NCT01234567": TransparencyTestFixtures.industryTrialStudyJSON,
            "NCT87654321": TransparencyTestFixtures.nihTrialStudyJSON,
            "NCT00000000": nil,
        ]

        let registrations = service.extractTrialInfos(from: studies)

        // Should only include non-nil parseable studies
        XCTAssertEqual(registrations.count, 2)
    }

    /// Test extractTrialInfos with empty dictionary.
    func testExtractTrialInfosEmpty() {
        let registrations = service.extractTrialInfos(from: [:])
        XCTAssertTrue(registrations.isEmpty)
    }

    // MARK: - Error Tests

    /// Test ClinicalTrialsError descriptions.
    func testClinicalTrialsErrorDescriptions() {
        XCTAssertNotNil(ClinicalTrialsError.invalidNCTId("test").errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.networkError("test").errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.httpError(statusCode: 400).errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.serverError(statusCode: 500).errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.parseError("test").errorDescription)
    }

    /// Test ClinicalTrialsError retryable status.
    func testClinicalTrialsErrorRetryable() {
        XCTAssertFalse(ClinicalTrialsError.invalidNCTId("test").isRetryable)
        XCTAssertTrue(ClinicalTrialsError.networkError("test").isRetryable)
        XCTAssertFalse(ClinicalTrialsError.httpError(statusCode: 400).isRetryable)
        XCTAssertTrue(ClinicalTrialsError.serverError(statusCode: 500).isRetryable)
        XCTAssertFalse(ClinicalTrialsError.parseError("test").isRetryable)
    }

    // MARK: - Title Fallback Tests

    /// Test extractTrialInfo uses briefTitle when officialTitle missing.
    func testExtractTrialInfoBriefTitleFallback() {
        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT00000004",
                    "briefTitle": "Brief Title Only",
                ],
            ],
            "hasResults": false,
        ]

        let registration = service.extractTrialInfo(from: study)
        XCTAssertEqual(registration?.title, "Brief Title Only")
    }

    /// Test extractTrialInfo prefers officialTitle over briefTitle.
    func testExtractTrialInfoPreferOfficialTitle() {
        let registration = service.extractTrialInfo(from: TransparencyTestFixtures.industryTrialStudyJSON)

        // Should use officialTitle, not briefTitle
        XCTAssertEqual(registration?.title, "A Phase III Study of Drug X vs Placebo")
        XCTAssertNotEqual(registration?.title, "Drug X Study")
    }
}
