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

/// Errors that can occur during full-text retrieval.
enum FullTextError: LocalizedError, Sendable {
    case noIdentifiers
    case networkError(String)
    case noFullTextAvailable
    case pdfDownloadFailed
    case xmlParseError(String)

    var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let message):
            return "Network error: \(message)"
        case .noFullTextAvailable:
            return "No full text available from any source"
        case .pdfDownloadFailed:
            return "Failed to download PDF"
        case .xmlParseError(let reason):
            return "Failed to parse XML: \(reason)"
        }
    }
}

/// Service for retrieving full-text articles with fallback chain.
///
/// Fallback order:
/// 1. Europe PMC XML (preferred - machine-readable, high quality)
/// 2. Unpaywall PDF (open access PDFs)
/// 3. DOI resolution (opens in browser)
actor FullTextService {
    // MARK: - Configuration

    private let email: String
    private let session: URLSession

    // MARK: - Initialization

    /// Initialize the service with an email for API identification.
    ///
    /// - Parameter email: Email address for Unpaywall API (required by their terms).
    init(email: String) {
        self.email = email

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = FullTextConstants.requestTimeoutSeconds
        config.timeoutIntervalForResource = FullTextConstants.downloadTimeoutSeconds
        self.session = URLSession(configuration: config)
    }

    /// Create service from app settings.
    ///
    /// - Parameter settings: The app settings containing the NCBI email.
    /// - Returns: A configured FullTextService instance.
    static func create(from settings: AppSettings) -> FullTextService {
        let email = settings.ncbiEmail.isEmpty
            ? FullTextConstants.fallbackEmail
            : settings.ncbiEmail
        return FullTextService(email: email)
    }

    // MARK: - Main Entry Point

    /// Attempt to retrieve full text for a document.
    ///
    /// Tries sources in order: Europe PMC XML -> Unpaywall PDF -> DOI website
    ///
    /// - Parameters:
    ///   - pmcId: PubMed Central ID (e.g., "PMC1234567")
    ///   - doi: Digital Object Identifier
    ///   - pmid: PubMed ID (for fallback URL)
    /// - Returns: Full text result with content and source
    /// - Throws: FullTextError if all sources fail
    func fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String
    ) async throws -> FullTextResult {
        // Try Europe PMC first (best quality)
        if let pmcId = pmcId, !pmcId.isEmpty {
            do {
                let markdown = try await fetchEuropePMCXML(pmcId: pmcId)
                return FullTextResult(content: .markdown(markdown), source: .europePMC)
            } catch {
                print("[FullText] Europe PMC failed for \(pmcId): \(error)")
            }
        }

        // Try Unpaywall (open access PDFs)
        if let doi = doi, !doi.isEmpty {
            do {
                let pdfURL = try await fetchUnpaywallPDF(doi: doi)
                return FullTextResult(content: .pdfURL(pdfURL), source: .unpaywall)
            } catch {
                print("[FullText] Unpaywall failed for \(doi): \(error)")
            }
        }

        // Fallback to DOI or PubMed URL
        if let doi = doi, !doi.isEmpty,
           let url = URL(string: "\(FullTextConstants.doiBaseURL)/\(doi)") {
            return FullTextResult(content: .webURL(url), source: .doi)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "\(FullTextConstants.pubmedBaseURL)/\(pmid)/") {
            return FullTextResult(content: .webURL(url), source: .doi)
        }

        throw FullTextError.noFullTextAvailable
    }

    /// Convenience method to fetch full text for a Document model.
    ///
    /// - Parameter document: The document to fetch full text for.
    /// - Returns: Full text result with content and source.
    /// - Throws: FullTextError if all sources fail.
    func fetchFullText(for document: Document) async throws -> FullTextResult {
        return try await fetchFullText(
            pmcId: document.pmcId,
            doi: document.doi,
            pmid: document.pmid
        )
    }

    // MARK: - Europe PMC XML

    /// Fetch full-text XML from Europe PMC and convert to markdown.
    ///
    /// - Parameter pmcId: The PubMed Central ID.
    /// - Returns: The article content as markdown.
    /// - Throws: FullTextError on failure.
    private func fetchEuropePMCXML(pmcId: String) async throws -> String {
        // Normalize PMC ID (ensure it has "PMC" prefix)
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        let urlString = "\(FullTextConstants.europePMCBaseURL)/\(normalizedId)/fullTextXML"
        guard let url = URL(string: urlString) else {
            throw FullTextError.noIdentifiers
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError("Invalid server response")
        }

        if httpResponse.statusCode == FullTextConstants.httpStatusNotFound {
            throw FullTextError.noFullTextAvailable
        }

        guard httpResponse.statusCode == FullTextConstants.httpStatusOK else {
            throw FullTextError.networkError("HTTP \(httpResponse.statusCode)")
        }

        // Parse XML and convert to markdown
        return try parseJATSXMLToMarkdown(data)
    }

    /// Parse JATS XML to markdown format.
    ///
    /// - Parameter data: The XML data.
    /// - Returns: The content as markdown.
    /// - Throws: FullTextError on parse failure.
    private func parseJATSXMLToMarkdown(_ data: Data) throws -> String {
        let parser = JATSXMLParser(data: data)
        do {
            return try parser.parseToMarkdown()
        } catch let error as JATSXMLParserError {
            throw FullTextError.xmlParseError(error.localizedDescription)
        } catch {
            throw FullTextError.xmlParseError(error.localizedDescription)
        }
    }

    // MARK: - Unpaywall

    /// Fetch open access PDF URL from Unpaywall.
    ///
    /// - Parameter doi: The DOI to look up.
    /// - Returns: URL to the PDF.
    /// - Throws: FullTextError if no open access version is available.
    private func fetchUnpaywallPDF(doi: String) async throws -> URL {
        // DOIs must be percent-encoded for URL path, including the "/" character
        guard let encodedDOI = encodeDOIForURLPath(doi) else {
            throw FullTextError.noIdentifiers
        }

        let urlString = "\(FullTextConstants.unpaywallBaseURL)/\(encodedDOI)?email=\(email)"
        guard let url = URL(string: urlString) else {
            throw FullTextError.noIdentifiers
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == FullTextConstants.httpStatusOK else {
            throw FullTextError.noFullTextAvailable
        }

        // Parse Unpaywall response
        let result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)

        // Try best OA location first
        if let pdfURL = extractPDFURL(from: result.bestOaLocation) {
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let pdfURL = extractPDFURL(from: location) {
                return pdfURL
            }
        }

        throw FullTextError.noFullTextAvailable
    }

    /// Encode a DOI for use in a URL path.
    ///
    /// DOIs contain "/" characters that must be percent-encoded for URL paths.
    ///
    /// - Parameter doi: The DOI to encode.
    /// - Returns: The percent-encoded DOI, or nil if encoding fails.
    private func encodeDOIForURLPath(_ doi: String) -> String? {
        // Create a character set that excludes "/" for proper DOI encoding
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove("/")
        return doi.addingPercentEncoding(withAllowedCharacters: allowed)
    }

    /// Extract PDF URL from an Unpaywall OA location.
    ///
    /// - Parameter location: The OA location to extract from.
    /// - Returns: The PDF URL, or nil if not available.
    private func extractPDFURL(from location: OALocation?) -> URL? {
        guard let location = location,
              let urlString = location.urlForPdf ?? location.url,
              let pdfURL = URL(string: urlString) else {
            return nil
        }
        return pdfURL
    }

    // MARK: - PDF Download

    /// Download a PDF from a URL and return the local file path.
    ///
    /// - Parameter url: The URL to download the PDF from.
    /// - Returns: Local file URL where the PDF was saved.
    /// - Throws: FullTextError if download fails.
    func downloadPDF(from url: URL) async throws -> URL {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == FullTextConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed
        }

        // Save to a temporary file
        let fileName = url.lastPathComponent.isEmpty
            ? FullTextConstants.defaultPDFFilename
            : url.lastPathComponent
        let tempDir = FileManager.default.temporaryDirectory
        let localURL = tempDir.appendingPathComponent(fileName)

        try data.write(to: localURL)

        return localURL
    }

    /// Download a PDF for a document and save it to the app's documents directory.
    ///
    /// - Parameters:
    ///   - url: The URL to download the PDF from.
    ///   - pmid: The PMID to use for the filename.
    /// - Returns: Path relative to the documents directory.
    /// - Throws: FullTextError if download fails.
    func downloadAndSavePDF(from url: URL, pmid: String) async throws -> String {
        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == FullTextConstants.httpStatusOK else {
            throw FullTextError.pdfDownloadFailed
        }

        // Get the documents directory
        guard let documentsDir = FileManager.default.urls(
            for: .documentDirectory,
            in: .userDomainMask
        ).first else {
            throw FullTextError.pdfDownloadFailed
        }

        let pdfsDir = documentsDir.appendingPathComponent(
            FullTextConstants.pdfDirectoryName,
            isDirectory: true
        )

        // Create PDFs directory if needed
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)

        // Save with PMID as filename
        let fileName = "\(FullTextConstants.pdfFilenamePrefix)\(pmid).\(FullTextConstants.pdfExtension)"
        let localURL = pdfsDir.appendingPathComponent(fileName)

        try data.write(to: localURL)

        // Return relative path
        return "\(FullTextConstants.pdfDirectoryName)/\(fileName)"
    }
}

// MARK: - Unpaywall Response Types

/// Response from the Unpaywall API.
private struct UnpaywallResponse: Codable {
    let bestOaLocation: OALocation?
    let oaLocations: [OALocation]?

    enum CodingKeys: String, CodingKey {
        case bestOaLocation = "best_oa_location"
        case oaLocations = "oa_locations"
    }
}

/// An open access location from Unpaywall.
private struct OALocation: Codable {
    let url: String?
    let urlForPdf: String?

    enum CodingKeys: String, CodingKey {
        case url
        case urlForPdf = "url_for_pdf"
    }
}
