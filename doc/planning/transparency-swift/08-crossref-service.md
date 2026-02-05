# Step 08: CrossRef Service

## Goal

Create an actor-based service for querying the CrossRef API to get funder information.

## File to Create

### `Sources/BioMedLit/Transparency/Services/CrossRefService.swift`

```swift
// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2025 Dr Horst Herb
// SPDX-License-Identifier: AGPL-3.0-or-later

import Foundation

/// Service for querying the CrossRef API.
///
/// CrossRef provides standardized funder information via the Funder Registry,
/// including funder DOIs that enable reliable industry classification.
///
/// Usage:
/// ```swift
/// let service = CrossRefService(email: "user@example.com")
/// let work = try await service.getWork(doi: "10.1000/example")
/// let funders = service.extractFunders(from: work)
/// ```
public actor CrossRefService {

    // MARK: - Properties

    private let session: URLSession
    private let email: String
    private var lastRequestTime: Date = .distantPast

    // MARK: - Initialization

    /// Initialize the CrossRef service.
    ///
    /// - Parameters:
    ///   - email: Contact email (required by CrossRef for polite pool)
    ///   - session: URLSession to use for requests
    public init(email: String, session: URLSession? = nil) {
        self.email = email

        if let session = session {
            self.session = session
        } else {
            let config = URLSessionConfiguration.default
            config.timeoutIntervalForRequest = BioMedLitConstants.defaultRequestTimeout
            self.session = URLSession(configuration: config)
        }
    }

    // MARK: - API Methods

    /// Get work metadata by DOI.
    ///
    /// - Parameter doi: Digital Object Identifier
    /// - Returns: Work metadata dictionary, or nil if not found
    /// - Throws: CrossRefError on failure
    public func getWork(doi: String) async throws -> [String: Any]? {
        // Clean DOI
        let cleanDOI = cleanDOI(doi)

        // Build URL
        let urlString = "\(TransparencyConstants.crossRefBaseURL)/works/\(cleanDOI)"
        guard let url = URL(string: urlString) else {
            throw CrossRefError.invalidDOI(doi)
        }

        // Create request with polite headers
        var request = URLRequest(url: url)
        request.setValue(
            "StudyTransparencyAnalyzer/1.0 (mailto:\(email))",
            forHTTPHeaderField: "User-Agent"
        )

        // Rate limit
        await enforceRateLimit()

        // Execute with retry
        let data = try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            let (data, response) = try await self.session.data(for: request)

            guard let httpResponse = response as? HTTPURLResponse else {
                throw CrossRefError.networkError("Invalid response")
            }

            if BioMedLitConstants.retryableStatusCodes.contains(httpResponse.statusCode) {
                throw CrossRefError.serverError(statusCode: httpResponse.statusCode)
            }

            guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
                if httpResponse.statusCode == BioMedLitConstants.httpStatusNotFound {
                    return nil
                }
                throw CrossRefError.httpError(statusCode: httpResponse.statusCode)
            }

            return data
        }

        guard let responseData = data else {
            return nil
        }

        // Parse JSON
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw CrossRefError.parseError("Invalid JSON structure")
        }

        BioMedLitLib.logger?.debug("CrossRef returned work for DOI: \(cleanDOI)", category: .network)

        return message
    }

    // MARK: - Funder Extraction

    /// Extract funder information from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API
    /// - Returns: List of FunderInfo objects
    public func extractFunders(from work: [String: Any]?) -> [FunderInfo] {
        guard let work = work,
              let funders = work["funder"] as? [[String: Any]] else {
            return []
        }

        return FundingAnalyzer.parseCrossRefFunders(funders)
    }

    /// Extract title from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API
    /// - Returns: Title string if available
    public func extractTitle(from work: [String: Any]?) -> String? {
        guard let work = work,
              let titles = work["title"] as? [String],
              let title = titles.first else {
            return nil
        }
        return title
    }

    /// Extract journal name from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API
    /// - Returns: Journal name if available
    public func extractJournal(from work: [String: Any]?) -> String? {
        guard let work = work,
              let containers = work["container-title"] as? [String],
              let journal = containers.first else {
            return nil
        }
        return journal
    }

    // MARK: - Private Helpers

    /// Clean DOI for URL usage.
    private func cleanDOI(_ doi: String) -> String {
        doi.replacingOccurrences(of: "https://doi.org/", with: "")
           .replacingOccurrences(of: "http://doi.org/", with: "")
           .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
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
}

// MARK: - Errors

/// Errors that can occur during CrossRef operations.
public enum CrossRefError: LocalizedError, RetryableError, Sendable {
    case invalidDOI(String)
    case networkError(String)
    case httpError(statusCode: Int)
    case serverError(statusCode: Int)
    case parseError(String)

    public var errorDescription: String? {
        switch self {
        case .invalidDOI(let doi):
            return "Invalid DOI: \(doi)"
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
        case .invalidDOI, .httpError, .parseError:
            return false
        }
    }
}
```

## Testing

```swift
import XCTest
@testable import BioMedLit

final class CrossRefServiceTests: XCTestCase {

    // MARK: - Funder Extraction Tests

    func testExtractFundersFromWork() async {
        let service = CrossRefService(email: "test@example.com")

        let work: [String: Any] = [
            "funder": [
                [
                    "name": "Pfizer",
                    "DOI": "10.13039/100004319",
                    "award": ["GRANT123"]
                ],
                [
                    "name": "National Institutes of Health",
                    "award": ["R01-12345"]
                ]
            ]
        ]

        let funders = service.extractFunders(from: work)

        XCTAssertEqual(funders.count, 2)
        XCTAssertTrue(funders.contains { $0.name == "Pfizer" && $0.isIndustry })
        XCTAssertTrue(funders.contains { $0.name == "National Institutes of Health" && !$0.isIndustry })
    }

    func testExtractFundersNil() async {
        let service = CrossRefService(email: "test@example.com")
        let funders = service.extractFunders(from: nil)
        XCTAssertTrue(funders.isEmpty)
    }

    func testExtractFundersNoFunders() async {
        let service = CrossRefService(email: "test@example.com")
        let work: [String: Any] = ["title": ["Test"]]
        let funders = service.extractFunders(from: work)
        XCTAssertTrue(funders.isEmpty)
    }

    // MARK: - Metadata Extraction Tests

    func testExtractTitle() async {
        let service = CrossRefService(email: "test@example.com")
        let work: [String: Any] = ["title": ["Test Study Title"]]
        let title = service.extractTitle(from: work)
        XCTAssertEqual(title, "Test Study Title")
    }

    func testExtractJournal() async {
        let service = CrossRefService(email: "test@example.com")
        let work: [String: Any] = ["container-title": ["Nature Medicine"]]
        let journal = service.extractJournal(from: work)
        XCTAssertEqual(journal, "Nature Medicine")
    }

    // MARK: - Error Tests

    func testCrossRefErrorDescriptions() {
        XCTAssertNotNil(CrossRefError.invalidDOI("test").errorDescription)
        XCTAssertNotNil(CrossRefError.networkError("test").errorDescription)
        XCTAssertNotNil(CrossRefError.httpError(statusCode: 400).errorDescription)
        XCTAssertNotNil(CrossRefError.serverError(statusCode: 500).errorDescription)
        XCTAssertNotNil(CrossRefError.parseError("test").errorDescription)
    }

    func testCrossRefErrorRetryable() {
        XCTAssertTrue(CrossRefError.serverError(statusCode: 500).isRetryable)
        XCTAssertTrue(CrossRefError.networkError("timeout").isRetryable)
        XCTAssertFalse(CrossRefError.invalidDOI("test").isRetryable)
        XCTAssertFalse(CrossRefError.httpError(statusCode: 400).isRetryable)
    }
}
```

## Dependencies

- `TransparencyModels.swift` (Step 01)
- `TransparencyConstants.swift` (Step 02)
- `FundingAnalyzer.swift` (Step 03)
- `RetryHelper.swift` (existing)

## Notes

- Actor ensures thread-safe rate limiting
- Uses polite User-Agent header as required by CrossRef
- Reuses existing RetryHelper for network resilience
- Returns nil for 404 (not found) instead of throwing
