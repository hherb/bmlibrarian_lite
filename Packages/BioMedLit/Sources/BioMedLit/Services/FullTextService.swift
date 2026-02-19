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

/// Service for retrieving full-text articles with fallback chain.
///
/// Attempts to retrieve full text from multiple sources in order:
/// 1. **Europe PMC XML** - Preferred source, machine-readable, converts to HTML/markdown
/// 2. **Unpaywall PDF** - Open access PDFs via Unpaywall API
/// 3. **DOI Resolution** - Falls back to opening publisher website
///
/// Thread-safe using Swift's actor model. Includes retry logic with
/// exponential backoff for network operations.
///
/// Usage:
/// ```swift
/// let service = FullTextService(email: "your@email.com")
/// let result = try await service.fetchFullText(
///     pmcId: "PMC7614751",
///     doi: "10.1234/example",
///     pmid: "12345678"
/// )
/// ```
public actor FullTextService {
    // MARK: - Properties

    /// Email for API identification (required by Unpaywall).
    private let email: String

    /// URLSession for network requests.
    private let session: URLSession

    /// Europe PMC service for identifier resolution.
    private let europePMCService: EuropePMCService

    // MARK: - Initialization

    /// Initialize the full-text service.
    ///
    /// - Parameter email: Email address for API identification.
    public init(email: String) {
        self.email = email
        self.europePMCService = EuropePMCService()

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = BioMedLitConstants.defaultRequestTimeout
        config.timeoutIntervalForResource = BioMedLitConstants.pdfDownloadTimeout
        config.waitsForConnectivity = true
        self.session = URLSession(configuration: config)
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
    public func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String
    ) async throws -> FullTextResult {
        BioMedLitLib.logger?.info(
            "Fetching full text for PMID \(pmid) (PMC: \(pmcId ?? "none"), DOI: \(doi ?? "none"))",
            category: .fullText
        )

        // Resolve PMC ID and PDF render URL from PMID or DOI if not already available
        var resolvedPmcId = pmcId
        var pdfRenderURL: String?
        if resolvedPmcId == nil || resolvedPmcId?.isEmpty == true {
            let resolved = await resolvePMCIdAndPDFUrl(pmid: pmid, doi: doi)
            resolvedPmcId = resolved.pmcId
            pdfRenderURL = resolved.pdfRenderURL
        }

        // Try Europe PMC first (best quality - machine readable XML)
        if let pmcId = resolvedPmcId, !pmcId.isEmpty {
            do {
                let content = try await fetchEuropePMCWithRetry(pmcId: pmcId)
                BioMedLitLib.logger?.info(
                    "Successfully retrieved Europe PMC full text for \(pmcId)",
                    category: .fullText
                )
                return .europePMC(html: content.html, markdown: content.markdown)
            } catch {
                BioMedLitLib.logger?.warning(
                    "Europe PMC XML failed for \(pmcId): \(error.localizedDescription)",
                    category: .fullText
                )
            }
        }

        // Try Europe PMC PDF render URL (when XML unavailable but free PDF exists)
        if let urlString = pdfRenderURL, let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.info(
                "Using Europe PMC PDF render: \(urlString)",
                category: .fullText
            )
            return .europePMCPDF(pdfURL: pdfURL)
        }

        // Try Unpaywall (open access PDFs)
        if let doi = doi, !doi.isEmpty {
            do {
                let pdfURL = try await fetchUnpaywallPDFWithRetry(doi: doi)
                BioMedLitLib.logger?.info(
                    "Successfully found Unpaywall PDF for DOI \(doi)",
                    category: .fullText
                )
                return .unpaywall(pdfURL: pdfURL)
            } catch {
                BioMedLitLib.logger?.warning(
                    "Unpaywall failed for DOI \(doi): \(error.localizedDescription)",
                    category: .fullText
                )
            }
        }

        // Fallback to DOI or PubMed URL
        if let doi = doi, !doi.isEmpty,
           let url = URL(string: "\(BioMedLitConstants.doiBaseURL)/\(doi)") {
            BioMedLitLib.logger?.info("Falling back to DOI URL for \(doi)", category: .fullText)
            return .doi(webURL: url)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "\(BioMedLitConstants.pubmedWebBaseURL)/\(pmid)/") {
            BioMedLitLib.logger?.info("Falling back to PubMed URL for PMID \(pmid)", category: .fullText)
            return .doi(webURL: url)
        }

        BioMedLitLib.logger?.error("No full text available for PMID \(pmid)", category: .fullText)
        throw FullTextError.noFullTextAvailable
    }

    // MARK: - Europe PMC

    /// Fetch full-text XML from Europe PMC with retry logic.
    private func fetchEuropePMCWithRetry(pmcId: String) async throws -> (html: String, markdown: String) {
        try await RetryHelper.retry(
            config: .serverError,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.fetchEuropePMCXML(pmcId: pmcId)
        }
    }

    /// Fetch full-text XML from Europe PMC and convert to HTML and markdown.
    ///
    /// - Parameter pmcId: PubMed Central ID (with or without "PMC" prefix).
    /// - Returns: Tuple of HTML and markdown formatted article text.
    /// - Throws: `FullTextError` on failure.
    private func fetchEuropePMCXML(pmcId: String) async throws -> (html: String, markdown: String) {
        // Normalize PMC ID (ensure it has the PMC prefix)
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        guard let url = URL(string: "\(BioMedLitConstants.europePMCBaseURL)/\(normalizedId)/fullTextXML") else {
            throw FullTextError.invalidResponse("Invalid PMC ID format")
        }

        BioMedLitLib.logger?.debug("Fetching Europe PMC XML from: \(url.absoluteString)", category: .fullText)

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError("Invalid server response")
        }

        BioMedLitLib.logger?.debug("Europe PMC response status: \(httpResponse.statusCode)", category: .fullText)

        let statusCode = httpResponse.statusCode
        switch statusCode {
        case BioMedLitConstants.httpStatusOK:
            break  // Success, continue to parse
        case BioMedLitConstants.httpStatusNotFound:
            throw FullTextError.noFullTextAvailable
        case _ where BioMedLitConstants.retryableStatusCodes.contains(statusCode):
            // Server errors and rate limiting - retryable
            BioMedLitLib.logger?.warning(
                "Europe PMC server error (\(statusCode)), will retry with backoff",
                category: .fullText
            )
            throw FullTextError.serverError(statusCode: statusCode)
        default:
            throw FullTextError.invalidResponse("HTTP \(statusCode)")
        }

        // Parse JATS XML to both HTML and markdown, passing the known PMC ID for figure URLs
        let parser = JATSXMLParser(data: data, knownPMCId: normalizedId)
        do {
            let html = try parser.parseToHTML()
            // Create a second parser for markdown (XML parser is consumed after first parse)
            let markdownParser = JATSXMLParser(data: data, knownPMCId: normalizedId)
            let markdown = try markdownParser.parseToMarkdown()
            return (html: html, markdown: markdown)
        } catch let parseError as JATSParseError {
            throw FullTextError.xmlParseError(parseError.localizedDescription)
        } catch {
            throw FullTextError.xmlParseError(error.localizedDescription)
        }
    }

    // MARK: - Identifier Resolution

    /// Resolve a PMC ID and PDF render URL from a PMID or DOI via Europe PMC search.
    ///
    /// Tries PMID first (more specific), then DOI. Also extracts the free PDF
    /// render URL from the ``fullTextUrlList`` in the search response.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID to resolve.
    ///   - doi: DOI to resolve.
    /// - Returns: Tuple of PMC ID and PDF render URL (both optional).
    private func resolvePMCIdAndPDFUrl(
        pmid: String?,
        doi: String?
    ) async -> (pmcId: String?, pdfRenderURL: String?) {
        // Try resolving by PMID first
        if let pmid = pmid, !pmid.isEmpty {
            let query = "ext_id:\(pmid) src:med"
            let resolved = await searchForPMCIdAndPDFUrl(query: query)
            if let pmcId = resolved.pmcId {
                BioMedLitLib.logger?.info(
                    "Resolved PMID \(pmid) to \(pmcId)",
                    category: .fullText
                )
                return resolved
            }
        }

        // Try resolving by DOI
        if let doi = doi, !doi.isEmpty {
            let query = "DOI:\"\(doi)\""
            let resolved = await searchForPMCIdAndPDFUrl(query: query)
            if let pmcId = resolved.pmcId {
                BioMedLitLib.logger?.info(
                    "Resolved DOI \(doi) to \(pmcId)",
                    category: .fullText
                )
                return resolved
            }
        }

        return (nil, nil)
    }

    /// Search Europe PMC and extract PMC ID and PDF render URL from the first result.
    private func searchForPMCIdAndPDFUrl(
        query: String
    ) async -> (pmcId: String?, pdfRenderURL: String?) {
        do {
            let result = try await europePMCService.search(
                query: query,
                pageSize: 1,
                requireAbstract: false
            )
            if let firstArticle = result.articles.first {
                let pmcId = firstArticle.pmcId?.isEmpty == false ? firstArticle.pmcId : nil
                return (pmcId, firstArticle.pdfRenderURL)
            }
        } catch {
            BioMedLitLib.logger?.debug(
                "PMC ID resolution failed for query '\(query)': \(error.localizedDescription)",
                category: .fullText
            )
        }
        return (nil, nil)
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

        guard let url = URL(string: "\(BioMedLitConstants.unpaywallBaseURL)/\(encodedDOI)?email=\(email)") else {
            throw FullTextError.invalidResponse("Invalid DOI format")
        }

        BioMedLitLib.logger?.debug("Fetching Unpaywall data from: \(url.absoluteString)", category: .fullText)

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError("Invalid server response")
        }

        BioMedLitLib.logger?.debug("Unpaywall response status: \(httpResponse.statusCode)", category: .fullText)

        guard httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            if httpResponse.statusCode == BioMedLitConstants.httpStatusNotFound {
                throw FullTextError.noFullTextAvailable
            }
            throw FullTextError.invalidResponse("HTTP \(httpResponse.statusCode)")
        }

        // Parse Unpaywall response
        let result: UnpaywallResponse
        do {
            result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to decode Unpaywall response: \(error.localizedDescription)",
                category: .fullText
            )
            throw FullTextError.invalidResponse("JSON decode error: \(error.localizedDescription)")
        }

        // Try best OA location first
        if let bestOA = result.bestOaLocation,
           let urlString = bestOA.urlForPdf ?? bestOA.url,
           let pdfURL = URL(string: urlString) {
            BioMedLitLib.logger?.debug("Found best OA location: \(pdfURL.absoluteString)", category: .fullText)
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let urlString = location.urlForPdf ?? location.url,
               let pdfURL = URL(string: urlString) {
                BioMedLitLib.logger?.debug("Found OA location: \(pdfURL.absoluteString)", category: .fullText)
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
    public func downloadAndCachePDF(from url: URL, for pmid: String) async throws -> String {
        BioMedLitLib.logger?.info(
            "Downloading PDF for PMID \(pmid) from \(url.absoluteString)",
            category: .fullText
        )

        let (data, response) = try await RetryHelper.retry(
            config: .pdfDownload,
            shouldRetry: RetryHelper.retryOnlyTransient
        ) {
            try await self.session.data(from: url)
        }

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == BioMedLitConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed("Invalid response")
        }

        // Verify it looks like a PDF by checking magic bytes (%PDF)
        let pdfMagic = Data(BioMedLitConstants.pdfMagicBytes)
        guard data.count > pdfMagic.count,
              data.prefix(pdfMagic.count) == pdfMagic else {
            throw FullTextError.pdfDownloadFailed("Response is not a valid PDF")
        }

        // Cache the PDF
        let filePath = try cachePDF(data: data, for: pmid)
        BioMedLitLib.logger?.info("Cached PDF at: \(filePath)", category: .fullText)

        return filePath
    }

    /// Save PDF data to the cache directory.
    private func cachePDF(data: Data, for pmid: String) throws -> String {
        let cacheDir = Self.pdfCacheDirectory
        let fileURL = cacheDir.appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")

        do {
            try data.write(to: fileURL, options: .atomic)
            return fileURL.path
        } catch {
            BioMedLitLib.logger?.error("Failed to cache PDF: \(error.localizedDescription)", category: .fullText)
            throw FullTextError.cachingFailed(error.localizedDescription)
        }
    }

    /// Get the cache directory for PDF files.
    public static var pdfCacheDirectory: URL {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!

        let cacheDir = appSupport
            .appendingPathComponent(BioMedLitConstants.appSupportFolderName, isDirectory: true)
            .appendingPathComponent(BioMedLitConstants.pdfCacheFolderName, isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: cacheDir,
                withIntermediateDirectories: true
            )
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to create PDF cache directory: \(error.localizedDescription)",
                category: .fullText
            )
        }

        return cacheDir
    }

    /// Check if a cached PDF exists for a document.
    ///
    /// - Parameter pmid: PubMed ID to check.
    /// - Returns: Path to cached PDF if it exists, nil otherwise.
    public static func cachedPDFPath(for pmid: String) -> String? {
        let fileURL = pdfCacheDirectory.appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
        if FileManager.default.fileExists(atPath: fileURL.path) {
            return fileURL.path
        }
        return nil
    }

    /// Delete a cached PDF file.
    ///
    /// - Parameter pmid: PubMed ID of the PDF to delete.
    public static func deleteCachedPDF(for pmid: String) {
        let fileURL = pdfCacheDirectory.appendingPathComponent("\(pmid).\(BioMedLitConstants.pdfExtension)")
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// Clear all cached PDFs.
    public static func clearPDFCache() {
        let cacheDir = pdfCacheDirectory
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: cacheDir,
                includingPropertiesForKeys: nil
            )
            for fileURL in contents where fileURL.pathExtension == BioMedLitConstants.pdfExtension {
                try FileManager.default.removeItem(at: fileURL)
            }
            BioMedLitLib.logger?.info("Cleared PDF cache", category: .fullText)
        } catch {
            BioMedLitLib.logger?.error(
                "Failed to clear PDF cache: \(error.localizedDescription)",
                category: .fullText
            )
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
