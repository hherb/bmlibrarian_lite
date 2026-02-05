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

    /// URLSession used for network requests.
    private let session: URLSession

    /// Timestamp of last request for rate limiting.
    private var lastRequestTime: Date = .distantPast

    // MARK: - Initialization

    /// Initialize the ClinicalTrials.gov service.
    ///
    /// - Parameter session: URLSession to use for requests. If nil, creates a new
    ///   session with default timeout configuration.
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
    /// Fetches clinical trial metadata from ClinicalTrials.gov API v2.
    ///
    /// - Parameter nctId: NCT identifier (e.g., "NCT01234567"). The ID is normalized
    ///   to uppercase and prefixed with "NCT" if missing.
    /// - Returns: Study JSON dictionary from API, or nil if not found.
    /// - Throws: ClinicalTrialsError on network failure, invalid ID, or parse error.
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
            BioMedLitLib.logger?.debug("ClinicalTrials.gov returned 404 for: \(normalizedId)", category: .network)
            return nil
        }

        // Parse JSON
        guard let json = try JSONSerialization.jsonObject(with: responseData) as? [String: Any] else {
            throw ClinicalTrialsError.parseError("Invalid JSON")
        }

        BioMedLitLib.logger?.info("ClinicalTrials.gov returned study: \(normalizedId)", category: .network)

        return json
    }

    /// Search for studies by multiple NCT IDs.
    ///
    /// Fetches multiple clinical trials in parallel with rate limiting.
    ///
    /// - Parameter nctIds: Array of NCT identifiers to fetch.
    /// - Returns: Dictionary mapping NCT IDs to their study data (nil if not found).
    public func getStudies(nctIds: [String]) async throws -> [String: [String: Any]?] {
        var results: [String: [String: Any]?] = [:]

        for nctId in nctIds {
            let normalizedId = normalizeNCTId(nctId)
            do {
                let study = try await getStudy(nctId: normalizedId)
                results[normalizedId] = study
            } catch {
                BioMedLitLib.logger?.warning(
                    "Failed to fetch study \(normalizedId): \(error.localizedDescription)",
                    category: .network
                )
                results[normalizedId] = nil
            }
        }

        return results
    }

    // MARK: - Trial Info Extraction

    /// Extract structured trial information from API response.
    ///
    /// Parses the ClinicalTrials.gov API v2 JSON structure to extract
    /// registration details, sponsor information, outcomes, and results status.
    ///
    /// This is a pure function that doesn't access actor state.
    ///
    /// - Parameter study: Study dictionary from API response.
    /// - Returns: TrialRegistration with extracted information, or nil if parsing fails.
    public nonisolated func extractTrialInfo(from study: [String: Any]?) -> TrialRegistration? {
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
            registry: TransparencyConstants.clinicalTrialsRegistryName,
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

    /// Extract multiple trial registrations from study responses.
    ///
    /// This is a pure function that doesn't access actor state.
    ///
    /// - Parameter studies: Dictionary mapping NCT IDs to study data.
    /// - Returns: Array of successfully parsed TrialRegistration objects.
    public nonisolated func extractTrialInfos(from studies: [String: [String: Any]?]) -> [TrialRegistration] {
        return studies.values.compactMap { study in
            extractTrialInfo(from: study)
        }
    }

    // MARK: - Private Helpers

    /// Normalize NCT ID to standard format.
    ///
    /// Converts to uppercase and adds NCT prefix if missing.
    ///
    /// - Parameter id: Raw NCT ID string.
    /// - Returns: Normalized NCT ID (e.g., "NCT01234567").
    private func normalizeNCTId(_ id: String) -> String {
        var normalized = id.uppercased().trimmingCharacters(in: .whitespaces)

        // Add NCT prefix if missing
        if !normalized.hasPrefix("NCT") {
            normalized = "NCT\(normalized)"
        }

        return normalized
    }

    /// Enforce rate limiting between requests.
    ///
    /// Ensures minimum interval between requests to comply with ClinicalTrials.gov limits.
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
    ///
    /// - Parameter outcomes: Outcomes array from API response.
    /// - Returns: Array of outcome measure strings.
    private nonisolated func extractOutcomes(from outcomes: Any?) -> [String] {
        guard let outcomesArray = outcomes as? [[String: Any]] else {
            return []
        }

        return outcomesArray.compactMap { outcome in
            outcome["measure"] as? String
        }
    }

    /// Extract date from date struct.
    ///
    /// Handles multiple date formats from the API:
    /// - Full date: "YYYY-MM-DD"
    /// - Month-year: "YYYY-MM"
    /// - Year only: "YYYY"
    ///
    /// - Parameter dateStruct: Date structure from API response.
    /// - Returns: Date if successfully parsed, nil otherwise.
    private nonisolated func extractDate(from dateStruct: Any?) -> Date? {
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
    /// The NCT ID format is invalid.
    case invalidNCTId(String)
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
