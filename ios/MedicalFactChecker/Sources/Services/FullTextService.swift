//
//  FullTextService.swift
//  MedicalFactChecker
//
//  Service for retrieving full text with fallback chain.
//

import Foundation

/// Errors that can occur during full-text retrieval.
enum FullTextError: LocalizedError {
    case noIdentifiers
    case networkError(Error)
    case noFullTextAvailable
    case pdfDownloadFailed
    case xmlParseError(String)

    var errorDescription: String? {
        switch self {
        case .noIdentifiers:
            return "Document has no DOI or PMC ID for full-text lookup"
        case .networkError(let error):
            return "Network error: \(error.localizedDescription)"
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

    private let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"
    private let unpaywallBaseURL = "https://api.unpaywall.org/v2"
    private let email: String
    private let session: URLSession

    // MARK: - Initialization

    /// Initialize the service with an email for API identification.
    ///
    /// - Parameter email: Email address for Unpaywall API (required by their terms).
    init(email: String) {
        self.email = email

        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 120  // Longer for PDF downloads
        self.session = URLSession(configuration: config)
    }

    /// Create service from app settings.
    ///
    /// - Parameter settings: The app settings containing the NCBI email.
    /// - Returns: A configured FullTextService instance.
    static func create(from settings: AppSettings) -> FullTextService {
        let email = settings.ncbiEmail.isEmpty ? "user@example.com" : settings.ncbiEmail
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
        if let doi = doi, !doi.isEmpty, let url = URL(string: "https://doi.org/\(doi)") {
            return FullTextResult(content: .webURL(url), source: .doi)
        }

        // Final fallback: PubMed page
        if let url = URL(string: "https://pubmed.ncbi.nlm.nih.gov/\(pmid)/") {
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
        // Normalize PMC ID
        let normalizedId = pmcId.hasPrefix("PMC") ? pmcId : "PMC\(pmcId)"

        guard let url = URL(string: "\(europePMCBaseURL)/\(normalizedId)/fullTextXML") else {
            throw FullTextError.noIdentifiers
        }

        var request = URLRequest(url: url)
        request.setValue("application/xml", forHTTPHeaderField: "Accept")

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw FullTextError.networkError(URLError(.badServerResponse))
        }

        if httpResponse.statusCode == 404 {
            throw FullTextError.noFullTextAvailable
        }

        guard httpResponse.statusCode == 200 else {
            throw FullTextError.networkError(URLError(.badServerResponse))
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
        guard let encodedDOI = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) else {
            throw FullTextError.noIdentifiers
        }

        guard let url = URL(string: "\(unpaywallBaseURL)/\(encodedDOI)?email=\(email)") else {
            throw FullTextError.noIdentifiers
        }

        let (data, response) = try await session.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw FullTextError.noFullTextAvailable
        }

        // Parse Unpaywall response
        let result = try JSONDecoder().decode(UnpaywallResponse.self, from: data)

        // Try best OA location first, then any OA location
        if let bestOA = result.bestOaLocation,
           let urlString = bestOA.urlForPdf ?? bestOA.url,
           let pdfURL = URL(string: urlString) {
            return pdfURL
        }

        // Try other OA locations
        for location in result.oaLocations ?? [] {
            if let urlString = location.urlForPdf ?? location.url,
               let pdfURL = URL(string: urlString) {
                return pdfURL
            }
        }

        throw FullTextError.noFullTextAvailable
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
              httpResponse.statusCode == 200 else {
            throw FullTextError.pdfDownloadFailed
        }

        // Save to a temporary file
        let fileName = url.lastPathComponent.isEmpty ? "article.pdf" : url.lastPathComponent
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
              httpResponse.statusCode == 200 else {
            throw FullTextError.pdfDownloadFailed
        }

        // Get the documents directory
        let documentsDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let pdfsDir = documentsDir.appendingPathComponent("PDFs", isDirectory: true)

        // Create PDFs directory if needed
        try FileManager.default.createDirectory(at: pdfsDir, withIntermediateDirectories: true)

        // Save with PMID as filename
        let fileName = "pmid-\(pmid).pdf"
        let localURL = pdfsDir.appendingPathComponent(fileName)

        try data.write(to: localURL)

        // Return relative path
        return "PDFs/\(fileName)"
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
