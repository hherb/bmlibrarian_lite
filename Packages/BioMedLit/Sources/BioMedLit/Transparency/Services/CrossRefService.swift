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

    /// URLSession used for network requests.
    private let session: URLSession

    /// Contact email for CrossRef polite pool identification.
    private let email: String

    /// Timestamp of last request for rate limiting.
    private var lastRequestTime: Date = .distantPast

    // MARK: - Initialization

    /// Initialize the CrossRef service.
    ///
    /// - Parameters:
    ///   - email: Contact email (required by CrossRef for polite pool).
    ///   - session: URLSession to use for requests. If nil, creates a new session
    ///     with default timeout configuration.
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
    /// Fetches bibliographic metadata for a publication using its DOI, including
    /// funder information, title, journal, and other details.
    ///
    /// - Parameter doi: Digital Object Identifier (e.g., "10.1000/example" or
    ///   "https://doi.org/10.1000/example").
    /// - Returns: Work metadata dictionary from CrossRef API, or nil if not found.
    /// - Throws: CrossRefError on network failure, invalid DOI, or parse error.
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

        BioMedLitLib.logger?.debug("Fetching CrossRef work for DOI: \(cleanDOI)", category: .network)

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
            BioMedLitLib.logger?.debug("CrossRef returned 404 for DOI: \(cleanDOI)", category: .network)
            return nil
        }

        // Parse JSON
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let message = json["message"] as? [String: Any] else {
            throw CrossRefError.parseError("Invalid JSON structure")
        }

        BioMedLitLib.logger?.info("CrossRef returned work for DOI: \(cleanDOI)", category: .network)

        return message
    }

    // MARK: - Funder Extraction

    /// Extract funder information from CrossRef work.
    ///
    /// Parses the "funder" array from CrossRef work metadata and creates
    /// classified FunderInfo objects using FundingAnalyzer.
    ///
    /// - Parameter work: Work dictionary from CrossRef API.
    /// - Returns: List of FunderInfo objects with industry classifications.
    public func extractFunders(from work: [String: Any]?) -> [FunderInfo] {
        guard let work = work,
              let funders = work["funder"] as? [[String: Any]] else {
            return []
        }

        return FundingAnalyzer.parseCrossRefFunders(funders)
    }

    /// Extract title from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API.
    /// - Returns: Title string if available, nil otherwise.
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
    /// - Parameter work: Work dictionary from CrossRef API.
    /// - Returns: Journal name if available, nil otherwise.
    public func extractJournal(from work: [String: Any]?) -> String? {
        guard let work = work,
              let containers = work["container-title"] as? [String],
              let journal = containers.first else {
            return nil
        }
        return journal
    }

    /// Extract author names from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API.
    /// - Returns: List of author names in "Family, Given" format.
    public func extractAuthors(from work: [String: Any]?) -> [String] {
        guard let work = work,
              let authors = work["author"] as? [[String: Any]] else {
            return []
        }

        return authors.compactMap { author -> String? in
            let family = author["family"] as? String
            let given = author["given"] as? String

            if let family = family, let given = given {
                return "\(family), \(given)"
            } else if let family = family {
                return family
            }
            return nil
        }
    }

    /// Extract publication date from CrossRef work.
    ///
    /// - Parameter work: Work dictionary from CrossRef API.
    /// - Returns: Publication date if available, nil otherwise.
    public func extractPublicationDate(from work: [String: Any]?) -> Date? {
        guard let work = work else { return nil }

        // Try published-print first, then published-online
        let dateKeys = ["published-print", "published-online", "issued"]

        for key in dateKeys {
            if let dateStruct = work[key] as? [String: Any],
               let dateParts = dateStruct["date-parts"] as? [[Int]],
               let parts = dateParts.first {
                return dateFromParts(parts)
            }
        }

        return nil
    }

    // MARK: - Private Helpers

    /// Clean DOI for URL usage.
    ///
    /// Removes URL prefixes and encodes the DOI for safe use in a URL path.
    ///
    /// - Parameter doi: Raw DOI string.
    /// - Returns: Cleaned and URL-encoded DOI.
    private func cleanDOI(_ doi: String) -> String {
        doi.replacingOccurrences(of: "https://doi.org/", with: "")
           .replacingOccurrences(of: "http://doi.org/", with: "")
           .addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
    }

    /// Enforce rate limiting between requests.
    ///
    /// Ensures minimum interval between requests to comply with CrossRef polite pool.
    private func enforceRateLimit() async {
        let elapsed = Date().timeIntervalSince(lastRequestTime)
        let minInterval = TransparencyConstants.minimumRequestInterval

        if elapsed < minInterval {
            let delay = minInterval - elapsed
            try? await Task.sleep(nanoseconds: UInt64(delay * Double(BioMedLitConstants.nanosecondsPerSecond)))
        }

        lastRequestTime = Date()
    }

    /// Convert date parts array to Date.
    ///
    /// - Parameter parts: Array of [year, month, day] integers (month and day optional).
    /// - Returns: Date if valid parts provided, nil otherwise.
    private func dateFromParts(_ parts: [Int]) -> Date? {
        guard !parts.isEmpty else { return nil }

        var components = DateComponents()
        components.year = parts[0]

        if parts.count > 1 {
            components.month = parts[1]
        } else {
            components.month = 1
        }

        if parts.count > 2 {
            components.day = parts[2]
        } else {
            components.day = 1
        }

        return Calendar.current.date(from: components)
    }
}

// MARK: - Errors

/// Errors that can occur during CrossRef operations.
public enum CrossRefError: LocalizedError, RetryableError, Sendable {
    /// The DOI format is invalid or cannot be used to construct a URL.
    case invalidDOI(String)
    /// A network error occurred (e.g., no connection).
    case networkError(String)
    /// HTTP error response with non-retryable status code.
    case httpError(statusCode: Int)
    /// Server error with retryable status code (5xx, 429).
    case serverError(statusCode: Int)
    /// Failed to parse the API response.
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
