//
//  FullTextConstants.swift
//  MedicalFactChecker
//
//  Constants for full-text retrieval service.
//

import Foundation

/// Constants for the full-text retrieval service.
enum FullTextConstants {
    // MARK: - API URLs

    /// Base URL for Europe PMC REST API.
    static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    /// Base URL for Unpaywall API.
    static let unpaywallBaseURL = "https://api.unpaywall.org/v2"

    /// Base URL for DOI resolution.
    static let doiBaseURL = "https://doi.org"

    /// Base URL for PubMed.
    static let pubmedBaseURL = "https://pubmed.ncbi.nlm.nih.gov"

    // MARK: - Timeouts

    /// Timeout for API requests in seconds.
    static let requestTimeoutSeconds: TimeInterval = 30

    /// Timeout for resource downloads (PDFs) in seconds.
    static let downloadTimeoutSeconds: TimeInterval = 120

    // MARK: - HTTP Status Codes

    /// HTTP status code for successful response.
    static let httpStatusOK = 200

    /// HTTP status code for not found.
    static let httpStatusNotFound = 404

    // MARK: - Formatting

    /// Maximum number of authors to display before using "et al."
    static let maxAuthorsBeforeEtAl = 3

    /// Maximum markdown heading level.
    static let maxHeadingLevel = 6

    // MARK: - File Paths

    /// Directory name for storing downloaded PDFs.
    static let pdfDirectoryName = "PDFs"

    /// Prefix for PDF filenames.
    static let pdfFilenamePrefix = "pmid-"

    /// Extension for PDF files.
    static let pdfExtension = "pdf"

    // MARK: - Fallback Values

    /// Default filename for downloaded articles without a name.
    static let defaultPDFFilename = "article.pdf"

    /// Fallback email for API identification when user hasn't configured one.
    /// Note: APIs like Unpaywall prefer a real email for contact purposes.
    static let fallbackEmail = "user@medicalfactchecker.app"
}
