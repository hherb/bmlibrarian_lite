//
//  FullTextService.swift
//  MedicalFactChecker
//
//  Service for retrieving full-text articles with fallback chain.
//  Supports Europe PMC XML, Unpaywall PDFs, and DOI resolution.
//

import Foundation

/// Errors that can occur during full-text retrieval.
enum FullTextError: LocalizedError, RetryableError {
    /// Document has no identifiers suitable for full-text lookup.
    case noIdentifiers

    /// Network error during retrieval.
    case networkError(Error)

    /// No full text available from any source.
    case noFullTextAvailable

    /// PDF download failed.
    case pdfDownloadFailed(String)

    /// XML parsing failed.
    case xmlParseError(String)

    /// PDF caching failed.
    case cachingFailed(String)

    /// Invalid response from API.
    case invalidResponse(String)

    /// Server error (5xx) - retryable.
    case serverError(statusCode: Int)

    var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
        case .noFullTextAvailable:
            return "No full text available from any source"
        case .pdfDownloadFailed(let reason):
            return "Failed to download PDF: \(reason)"
        case .xmlParseError(let reason):
            return "Failed to parse XML: \(reason)"
        case .cachingFailed(let reason):
            return "Failed to cache PDF: \(reason)"
        case .invalidResponse(let reason):
            return "Invalid API response: \(reason)"
        case .serverError(let statusCode):
            return "Server temporarily unavailable (HTTP \(statusCode)). Retrying..."
        }
    }

    /// Whether this error is transient and should be retried.
    var isRetryable: Bool {
        switch self {
        case .networkError:
            return true
        case .serverError:
            return true
        case .noIdentifiers, .noFullTextAvailable, .pdfDownloadFailed,
             .xmlParseError, .cachingFailed, .invalidResponse:
            return false
        }
    }
}

/// Service for retrieving full-text articles with fallback chain.
///
/// Attempts to retrieve full text from multiple sources in order:
/// 1. **Europe PMC XML** - Preferred source, machine-readable, converts to markdown
/// 2. **Unpaywall PDF** - Open access PDFs via Unpaywall API
/// 3. **DOI Resolution** - Falls back to opening publisher website
///
/// Thread-safe using Swift's actor model. Includes retry logic with
/// exponential backoff for network operations.
///
/// Usage:
/// ```swift
/// let service = FullTextService.create(from: settings)
/// let result = try await service.fetchFullText(
///     pmcId: "PMC7614751",
///     doi: "10.1234/example",
///     pmid: "12345678"
/// )
/// ```
actor FullTextService {
    // MARK: - Configuration Constants

    /// Europe PMC REST API base URL.
    private let europePMCBaseURL = FullTextConstants.europePMCBaseURL

    /// Unpaywall API base URL.
    private let unpaywallBaseURL = FullTextConstants.unpaywallBaseURL

    /// Email for API identification (required by Unpaywall).
    private let email: String

    /// URLSession for network requests.
    private let session: URLSession

    // MARK: - Initialization

    /// Initialize the full-text service.
    ///
    /// - Parameter email: Email address for API identification.
    init(email: String) {
        self.email = email

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = FullTextConstants.requestTimeoutSeconds
        config.timeoutIntervalForResource = FullTextConstants.downloadTimeoutSeconds
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
    }

    /// Create a full-text service from app settings.
    ///
    /// - Parameter settings: The app settings containing email configuration.
    /// - Returns: A configured FullTextService instance.
    static func create(from settings: AppSettings) -> FullTextService {
        let email = settings.ncbiEmail.isEmpty
            ? FullTextConstants.defaultEmail
            : settings.ncbiEmail
        return FullTextService(email: email)
    }

    // MARK: - Main Entry Point

    /// Attempt to retrieve full text for a document.
    ///
    /// Tries sources in order: Europe PMC XML → Unpaywall PDF → DOI website.
    /// Each source is tried with retry logic for transient network failures.
    ///
    /// - Parameters:
    ///   - pmcId: PubMed Central ID (e.g., "PMC1234567").
    ///   - doi: Digital Object Identifier.
    ///   - pmid: PubMed ID (for fallback URL).
    /// - Returns: Full text result with content and source.
    /// - Throws: `FullTextError` if all sources fail.
    func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String
    ) async throws -> FullTextResult {
        AppLogger.fullText.info("Fetching full text for PMID \(pmid) (PMC: \(pmcId ?? "none"), DOI: \(doi ?? "none"))")

        // Try Europe PMC first (best quality - machine readable XML)
        if let pmcId = pmcId, !pmcId.isEmpty {
            do {
                let markdown = try await fetchEuropePMCWithRetry(pmcId: pmcId)
                AppLogger.fullText.info("Successfully retrieved Europe PMC full text for \(pmcId)")
                return .europePMC(markdown: markdown)
            } catch {
                AppLogger.fullText.warning("Europe PMC failed for \(pmcId): \(error.localizedDescription)")
            }
        }

        // Try Unpaywall (open access PDFs)
        if let doi = doi, !doi.isEmpty {
            do {
                let pdfURL = try await fetchUnpaywallPDFWithRetry(doi: doi)
                AppLogger.fullText.info("Successfully found Unpaywall PDF for DOI \(doi)")
                return .unpaywall(pdfURL: pdfURL)
            } catch {
                AppLogger.fullText.warning("Unpaywall failed for DOI \(doi): \(error.localizedDescription)")
            }
        }

        // Fallback to DOI or PubMed URL
        if let doi = doi, !doi.isEmpty, let url = URL(string: "https://doi.org/\(doi)") {
            AppLogger.fullText.info("Falling back to DOI URL for \(doi)")
            return .doi(webURL: url)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/") {
            AppLogger.fullText.info("Falling back to PubMed URL for PMID \(pmid)")
            return .doi(webURL: url)
        }

        AppLogger.fullText.error("No full text available for PMID \(pmid)")
        throw FullTextError.noFullTextAvailable
    }

    // MARK: - Europe PMC

    /// Fetch full-text XML from Europe PMC with retry logic.
    ///
    /// Uses server error configuration for more aggressive retry on 5xx errors.
    private func fetchEuropePMCWithRetry(pmcId: String) async throws -> String {
        try await RetryHelper.retry(
            config: .serverError,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.fetchEuropePMCXML(pmcId: pmcId)
        }
    }

    /// Fetch full-text XML from Europe PMC and convert to markdown.
    ///
    /// - Parameter pmcId: PubMed Central ID (with or without "PMC" prefix).
    /// - Returns: Markdown-formatted article text.
    /// - Throws: `FullTextError` on failure.
    private func fetchEuropePMCXML(pmcId: String) async throws -> String {
        // Normalize PMC ID (ensure it has the PMC prefix)
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        guard let url = URL(string: "\(europePMCBaseURL)/\(normalizedId)/fullTextXML") else {
            throw FullTextError.invalidResponse("Invalid PMC ID format")
        }

        AppLogger.fullText.debug("Fetching Europe PMC XML from: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = FullTextConstants.requestTimeoutSeconds

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError(URLError(.badServerResponse))
        }

        AppLogger.fullText.debug("Europe PMC response status: \(httpResponse.statusCode)")

        let statusCode = httpResponse.statusCode
        switch statusCode {
        case 200:
            break  // Success, continue to parse
        case 404:
            throw FullTextError.noFullTextAvailable
        case 429, 500, 502, 503, 504:
            // Server errors and rate limiting - retryable
            AppLogger.fullText.warning("Europe PMC server error (\(statusCode)), will retry with backoff")
            throw FullTextError.serverError(statusCode: statusCode)
        default:
            throw FullTextError.invalidResponse("HTTP \(statusCode)")
        }

        // Parse JATS XML to markdown, passing the known PMC ID for figure URLs
        let parser = JATSXMLParser(data: data, knownPMCId: normalizedId)
        do {
            return try parser.parseToMarkdown()
        } catch let parseError as JATSParseError {
            throw FullTextError.xmlParseError(parseError.localizedDescription)
        } catch {
            throw FullTextError.xmlParseError(error.localizedDescription)
        }
    }

    // MARK: - Unpaywall

    /// Fetch PDF URL from Unpaywall with retry logic.
    private func fetchUnpaywallPDFWithRetry(doi: String) async throws -> URL {
        try await RetryHelper.retry(
            config: .networkDefault,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.fetchUnpaywallPDF(doi: doi)
        }
    }

    /// Fetch open access PDF URL from Unpaywall.
    ///
    /// - Parameter doi: Digital Object Identifier.
    /// - Returns: URL to downloadable PDF.
    /// - Throws: `FullTextError` on failure.
    private func fetchUnpaywallPDF(doi: String) async throws -> URL {
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FullTextError.noIdentifiers
        }

        guard let url = URL(string: "\(unpaywallBaseURL)/\(encodedDOI)?email=\(email)") else {
            throw FullTextError.invalidResponse("Invalid DOI format")
        }

        AppLogger.fullText.debug("Fetching Unpaywall data from: \(url.absoluteString)")

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = FullTextConstants.requestTimeoutSeconds

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError(URLError(.badServerResponse))
        }

        AppLogger.fullText.debug("Unpaywall response status: \(httpResponse.statusCode)")

        guard httpResponse.statusCode == 200 else {
            if httpResponse.statusCode == 404 {
                throw FullTextError.noFullTextAvailable
            }
            throw FullTextError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        // Parse Unpaywall response
        let result: UnpaywallResponse
        do {
            result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)
        } catch {
            AppLogger.fullText.error("Failed to decode Unpaywall response: \(error.localizedDescription)")
            throw FullTextError.invalidResponse("JSON decode error: \(error.localizedDescription)")
        }

        // Try best OA location first
        if let bestOA = result.bestOaLocation,
           let urlString = bestOA.urlForPdf ?? bestOA.url,
           let pdfURL = URL(string: urlString) {
            AppLogger.fullText.debug("Found best OA location: \(pdfURL.absoluteString)")
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let urlString = location.urlForPdf ?? location.url,
               let pdfURL = URL(string: urlString) {
                AppLogger.fullText.debug("Found OA location: \(pdfURL.absoluteString)")
                return pdfURL
            }
        }

        throw FullTextError.noFullTextAvailable
    }

    // MARK: - PDF Caching

    /// Download and cache a PDF file.
    ///
    /// - Parameters:
    ///   - url: URL to download the PDF from.
    ///   - pmid: PubMed ID for naming the cached file.
    /// - Returns: Local file path to the cached PDF.
    /// - Throws: `FullTextError` on failure.
    func downloadAndCachePDF(from url: URL, for pmid: String) async throws -> String {
        AppLogger.fullText.info("Downloading PDF for PMID \(pmid) from \(url.absoluteString)")

        let (data, response) = try await RetryHelper.retry(
            config: .pdfDownload,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.session.data(from: url)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FullTextError.pdfDownloadFailed("Invalid response")
        }

        // Verify it looks like a PDF
        guard data.count > 4,
              data.prefix(4) == Data([0x25, 0x50, 0x44, 0x46]) else {  // %PDF
            throw FullTextError.pdfDownloadFailed("Response is not a valid PDF")
        }

        // Cache the PDF
        let filePath = try cachePDF(data: data, for: pmid)
        AppLogger.fullText.info("Cached PDF at: \(filePath)")

        return filePath
    }

    /// Save PDF data to the cache directory.
    ///
    /// - Parameters:
    ///   - data: PDF file data.
    ///   - pmid: PubMed ID for naming the file.
    /// - Returns: Path to the cached file.
    /// - Throws: `FullTextError.cachingFailed` on failure.
    private func cachePDF(data: Data, for pmid: String) throws -> String {
        let cacheDir = Self.pdfCacheDirectory
        let fileURL = cacheDir.appendingPathComponent("\(pmid).pdf")

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            AppLogger.fullText.error("Failed to cache PDF: \(error.localizedDescription)")
            throw FullTextError.cachingFailed(error.localizedDescription)
        }
    }

    /// Get the cache directory for PDF files.
    ///
    /// Creates the directory if it doesn't exist.
    static var pdfCacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = appSupport
            .appendingPathComponent(FullTextConstants.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(FullTextConstants.pdfCacheFolderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
        } catch {
            AppLogger.fullText.error("Failed to create PDF cache directory: \(error.localizedDescription)")
        }

        return cacheDir
    }

    /// Check if a cached PDF exists for a document.
    ///
    /// - Parameter pmid: PubMed ID to check.
    /// - Returns: Path to cached PDF if it exists, nil otherwise.
    static func cachedPDFPath(for pmid: String) -> String? {
        let fileURL = pdfCacheDirectory.appendingPathComponent("\(pmid).pdf")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL.path
        }
        return nil
    }

    /// Delete a cached PDF file.
    ///
    /// - Parameter pmid: PubMed ID of the PDF to delete.
    static func deleteCachedPDF(for pmid: String) {
        let fileURL = pdfCacheDirectory.appendingPathComponent("\(pmid).pdf")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clear all cached PDFs.
    static func clearPDFCache() {
        let cacheDir = pdfCacheDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents where fileURL.pathExtension == "pdf" {
                try FileManager.default.removeItem(at: fileURL)
            }
            AppLogger.fullText.info("Cleared PDF cache")
        } catch {
            AppLogger.fullText.error("Failed to clear PDF cache: \(error.localizedDescription)")
        }
    }
}

// MARK: - Unpaywall Response Types

/// Response from Unpaywall API.
private struct UnpaywallResponse: Codable {
    /// Best available open access location.
    let bestOaLocation: OALocation?

    /// All available open access locations.
    let oaLocations: [OALocation]?

    enum CodingKeys: String, CodingKey {
        case bestOaLocation = "best_oa_location"
        case oaLocations = "oa_locations"
    }
}

/// Open access location from Unpaywall.
private struct OALocation: Codable {
    /// Landing page URL.
    let url: String?

    /// Direct PDF URL (if available).
    let urlForPdf: String?

    /// Host type (publisher, repository, etc.).
    let hostType: String?

    /// License information.
    let license: String?

    enum CodingKeys: String, CodingKey {
        case url
        case urlForPdf = "url_for_pdf"
        case hostType = "host_type"
        case license
    }
}

// MARK: - Constants

/// Constants for full-text retrieval service.
enum FullTextConstants {
    /// Europe PMC REST API base URL.
    static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    /// Unpaywall API base URL.
    static let unpaywallBaseURL = "https://api.unpaywall.org/v2"

    /// Default email for API identification when none configured.
    static let defaultEmail = "user@example.com"

    /// Request timeout in seconds.
    static let requestTimeoutSeconds: TimeInterval = 45

    /// Download timeout in seconds (for large PDFs).
    static let downloadTimeoutSeconds: TimeInterval = 180

    /// Application Support folder name.
    static let appSupportFolderName = "MedicalFactChecker"

    /// PDF cache folder name.
    static let pdfCacheFolderName = "PDFCache"
}
