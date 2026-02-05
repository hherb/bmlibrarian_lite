# Step 09: ClinicalTrials.gov Service

## Goal

Create an actor-based service for querying the ClinicalTrials.gov API v2.

## File to Create

### `Sources/BioMedLit/Transparency/Services/ClinicalTrialsService.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Service for querying the ClinicalTrials.gov API v2.
///
/// Provides trial registration information including sponsor classification,
/// registered outcomes, and results posting status.
///
/// Usage:
/// ```swift
/// let service = ClinicalTrialsService()
/// let study = try await service.getStudy(nctId: "NCT01234567")
/// let registration = service.extractTrialInfo(from: study)
/// ```
public actor ClinicalTrialsService {

    // MARK: - Properties

    private let session: URLSession
    private var lastRequestTime: Date = .distantPast

    // MARK: - Initialization

    /// Initialize the ClinicalTrials.gov service.
    ///
    /// - Parameter session: URLSession to use for requests
    public init(session: URLSession? = nil) {
        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.defaultRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - API Methods

    /// Get study by NCT ID.
    ///
    /// - Parameter nctId: NCT identifier (e.g., "NCT01234567")
    /// - Returns: Study JSON dictionary, or nil if not found
    /// - Throws: ClinicalTrialsError on failure
    public func getStudy(nctId: String) async throws -> [String: Any]? {
        // Normalize NCT ID
        let normalizedId = normalizeNCTId(nctId)

        // Build URL
        let urlString = "\(TransparencyConstants.clinicalTrialsBaseURL)/studies/\(normalizedId)"
        guard let url = URL(string: urlString) else {
            throw ClinicalTrialsError.invalidNCTId(nctId)
        }

        // Rate limit
        await enforceRateLimit()

        BioMedLitLib.logger?.debug("Fetching ClinicalTrials.gov study: \(normalizedId)", category: .network)

        // Execute with retry
        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await self.session.data(from: url)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw ClinicalTrialsError.networkError("Invalid response")
            }

            if BioMedLitConstants.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw ClinicalTrialsError.serverError(statusCode: httpResponse.statusCode)
            }

            guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                if httpResponse.statusCode == BioMedLitConstants.httpStatusNotFound {
                    return nil
                }
                throw ClinicalTrialsError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        guard let responseData = data else {
            return nil
        }

        // Parse JSON
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ClinicalTrialsError.parseError("Invalid JSON")
        }

        BioMedLitLib.logger?.info("ClinicalTrials.gov returned study: \(normalizedId)", category: .network)

        return json
    }

    // MARK: - Trial Info Extraction

    /// Extract structured trial information from API response.
    ///
    /// - Parameter study: Study dictionary from API
    /// - Returns: TrialRegistration with extracted information
    public func extractTrialInfo(from study: [String: Any]?) -> TrialRegistration? {
        guard let study = study,
              let protocolSection = study["protocolSection"] as? [String: Any] else {
            return nil
        }

        // Identification module
        let idModule = protocolSection["identificationModule"] as? [String: Any] ?? [:]
        let nctId = idModule["nctId"] as? String ?? ""
        let title = idModule["officialTitle"] as? String ?? idModule["briefTitle"] as? String

        // Sponsor module
        let sponsorModule = protocolSection["sponsorCollaboratorsModule"] as? [String: Any] ?? [:]
        let leadSponsor = sponsorModule["leadSponsor"] as? [String: Any] ?? [:]
        let sponsorName = leadSponsor["name"] as? String
        let sponsorClass = leadSponsor["class"] as? String

        // Outcomes module
        let outcomesModule = protocolSection["outcomesModule"] as? [String: Any] ?? [:]
        let primaryOutcomes = extractOutcomes(from: outcomesModule["primaryOutcomes"])
        let secondaryOutcomes = extractOutcomes(from: outcomesModule["secondaryOutcomes"])

        // Status module
        let statusModule = protocolSection["statusModule"] as? [String: Any] ?? [:]
        let completionDate = extractDate(from: statusModule["completionDateStruct"])

        // Results status
        let hasResults = study["hasResults"] as? Bool ?? false

        return TrialRegistration(
            registry: "ClinicalTrials.gov",
            registrationId: nctId,
            title: title,
            sponsorClass: sponsorClass,
            leadSponsor: sponsorName,
            resultsPosted: hasResults,
            completionDate: completionDate,
            primaryOutcomesRegistered: primaryOutcomes,
            secondaryOutcomesRegistered: secondaryOutcomes
        )
    }

    // MARK: - Private Helpers

    /// Normalize NCT ID to standard format.
    private func normalizeNCTId(_ id: String) -> String {
        var normalized = id.uppercased().trimmingCharacters(in: .whitespaces)

        // Add NCT prefix if missing
        if !normalized.hasPrefix("NCT") {
            normalized = "NCT\(normalized)"
        }

        return normalized
    }

    /// Enforce rate limiting.
    private func enforceRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let minInterval = TransparencyConstants.minimumRequestInterval

        if elapsed < minInterval {
            let delay = minInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        }

        lastRequestTime = Date()
    }

    /// Extract outcome measures from outcomes array.
    private func extractOutcomes(from outcomes: Any?) -> [String] {
        guard let outcomesArray = outcomes as? [[String: Any]] else {
            return []
        }

        return outcomesArray.compactMap { outcome in
            outcome["measure"] as? String
        }
    }

    /// Extract date from date struct.
    private func extractDate(from dateStruct: Any?) -> Date? {
        guard let dateDict = dateStruct as? [String: Any],
              let dateString = dateDict["date"] as? String else {
            return nil
        }

        // Try full date format (YYYY-MM-DD)
        let fullFormatter = DateFormatter()
        fullFormatter.dateFormat = "yyyy-MM-dd"
        if let date = fullFormatter.date(from: dateString) {
            return date
        }

        // Try month-year format (YYYY-MM)
        let monthFormatter = DateFormatter()
        monthFormatter.dateFormat = "yyyy-MM"
        if let date = monthFormatter.date(from: dateString) {
            return date
        }

        // Try year only (YYYY)
        let yearFormatter = DateFormatter()
        yearFormatter.dateFormat = "yyyy"
        return yearFormatter.date(from: dateString)
    }
}

// MARK: - Errors

/// Errors that can occur during ClinicalTrials.gov operations.
public enum ClinicalTrialsError: LocalizedError, RetryableError, Sendable {
    case invalidNCTId(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidNCTId(let id):
            return "Invalid NCT ID: \(id)"
        case .networkError(let message):
            return "Network error: \(message)"
        case .httpError(let statusCode):
            return "HTTP error: \(statusCode)"
        case .serverError(let statusCode):
            return "Server error (HTTP \(statusCode)). Retrying..."
        case .parseError(let message):
            return "Failed to parse response: \(message)"
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .serverError, .networkError:
            return true
        case .invalidNCTId, .httpError, .parseError:
            return false
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class ClinicalTrialsServiceTests: XCTestCase {

    // MARK: - Trial Info Extraction Tests

    func testExtractTrialInfoBasic() async {
        let service = ClinicalTrialsService()

        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT01234567",
                    "officialTitle": "Test Study Title"
                ],
                "sponsorCollaboratorsModule": [
                    "leadSponsor": [
                        "name": "Pfizer",
                        "class": "INDUSTRY"
                    ]
                ],
                "outcomesModule": [
                    "primaryOutcomes": [
                        ["measure": "Overall Survival"]
                    ]
                ],
                "statusModule": [
                    "completionDateStruct": [
                        "date": "2023-06-15"
                    ]
                ]
            ],
            "hasResults": true
        ]

        let registration = service.extractTrialInfo(from: study)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.registrationId, "NCT01234567")
        XCTAssertEqual(registration?.title, "Test Study Title")
        XCTAssertEqual(registration?.sponsorClass, "INDUSTRY")
        XCTAssertEqual(registration?.leadSponsor, "Pfizer")
        XCTAssertTrue(registration?.resultsPosted == true)
        XCTAssertEqual(registration?.primaryOutcomesRegistered, ["Overall Survival"])
        XCTAssertNotNil(registration?.completionDate)
    }

    func testExtractTrialInfoNil() async {
        let service = ClinicalTrialsService()
        let registration = service.extractTrialInfo(from: nil)
        XCTAssertNil(registration)
    }

    func testExtractTrialInfoMinimal() async {
        let service = ClinicalTrialsService()

        let study: [String: Any] = [
            "protocolSection": [
                "identificationModule": [
                    "nctId": "NCT99999999"
                ]
            ]
        ]

        let registration = service.extractTrialInfo(from: study)

        XCTAssertNotNil(registration)
        XCTAssertEqual(registration?.registrationId, "NCT99999999")
        XCTAssertFalse(registration?.resultsPosted == true)
    }

    // MARK: - Industry Sponsor Detection Tests

    func testIndustrySponsorDetection() async {
        let service = ClinicalTrialsService()

        let industryStudy: [String: Any] = [
            "protocolSection": [
                "identificationModule": ["nctId": "NCT123"],
                "sponsorCollaboratorsModule": [
                    "leadSponsor": ["class": "INDUSTRY"]
                ]
            ]
        ]

        let registration = service.extractTrialInfo(from: industryStudy)
        XCTAssertEqual(registration?.sponsorClass, "INDUSTRY")
        XCTAssertTrue(TrialComplianceAnalyzer.isIndustrySponsor(registration?.sponsorClass))
    }

    func testNonIndustrySponsorDetection() async {
        let service = ClinicalTrialsService()

        let nihStudy: [String: Any] = [
            "protocolSection": [
                "identificationModule": ["nctId": "NCT123"],
                "sponsorCollaboratorsModule": [
                    "leadSponsor": ["class": "NIH"]
                ]
            ]
        ]

        let registration = service.extractTrialInfo(from: nihStudy)
        XCTAssertEqual(registration?.sponsorClass, "NIH")
        XCTAssertFalse(TrialComplianceAnalyzer.isIndustrySponsor(registration?.sponsorClass))
    }

    // MARK: - Error Tests

    func testClinicalTrialsErrorDescriptions() {
        XCTAssertNotNil(ClinicalTrialsError.invalidNCTId("test").errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.networkError("test").errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.httpError(statusCode: 400).errorDescription)
        XCTAssertNotNil(ClinicalTrialsError.serverError(statusCode: 500).errorDescription)
    }

    func testClinicalTrialsErrorRetryable() {
        XCTAssertTrue(ClinicalTrialsError.serverError(statusCode: 500).isRetryable)
        XCTAssertTrue(ClinicalTrialsError.networkError("timeout").isRetryable)
        XCTAssertFalse(ClinicalTrialsError.invalidNCTId("test").isRetryable)
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)
- `TrialComplianceAnalyzer.swift` (Step 06)
- `RetryHelper.swift` (existing)

## Notes

- Uses ClinicalTrials.gov API v2 (JSON format)
- Handles multiple date formats from the API
- Extracts both primary and secondary outcomes
- Normalizes NCT IDs to standard format
