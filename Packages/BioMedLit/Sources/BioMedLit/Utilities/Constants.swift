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

/// Constants for BioMedLit services.
public enum BioMedLitConstants {
    // MARK: - Europe PMC API

    /// Europe PMC REST API base URL.
    public static let europePMCBaseURL = "https://www.ebi.ac.uk/europepmc/webservices/rest"

    /// Europe PMC search endpoint.
    public static let europePMCSearchURL = "\(europePMCBaseURL)/search"

    /// Default page size for Europe PMC searches.
    public static let europePMCDefaultPageSize = 25

    /// Maximum page size for Europe PMC searches.
    public static let europePMCMaxPageSize = 1000

    // MARK: - PubMed API

    /// NCBI E-utilities base URL.
    public static let pubmedBaseURL = "https://eutils.ncbi.nlm.nih.gov/entrez/eutils"

    /// PubMed search endpoint.
    public static let pubmedSearchURL = "\(pubmedBaseURL)/esearch.fcgi"

    /// PubMed fetch endpoint.
    public static let pubmedFetchURL = "\(pubmedBaseURL)/efetch.fcgi"

    /// Default batch size for PubMed searches.
    public static let pubmedDefaultBatchSize = 100

    /// Maximum offset for PubMed searches.
    public static let pubmedMaxOffset = 9999

    /// Rate limit for PubMed without API key (requests per second).
    public static let pubmedRateLimitNoKey = 3

    /// Rate limit for PubMed with API key (requests per second).
    public static let pubmedRateLimitWithKey = 10

    // MARK: - Unpaywall API

    /// Unpaywall API base URL.
    public static let unpaywallBaseURL = "https://api.unpaywall.org/v2"

    // MARK: - DOI Resolution

    /// DOI resolution base URL.
    public static let doiBaseURL = "https://doi.org"

    // MARK: - PubMed Web

    /// PubMed web base URL.
    public static let pubmedWebBaseURL = "https://pubmed.ncbi.nlm.nih.gov"

    // MARK: - Europe PMC Figure URLs

    /// Europe PMC figure/graphic base URL.
    public static let europePMCFigureBaseURL = "https://europepmc.org/articles"

    // MARK: - Timeouts

    /// Default request timeout in seconds.
    public static let defaultRequestTimeout: TimeInterval = 45

    /// PDF download timeout in seconds.
    public static let pdfDownloadTimeout: TimeInterval = 180

    /// Search request timeout in seconds.
    public static let searchRequestTimeout: TimeInterval = 60

    // MARK: - HTTP Status Codes

    /// HTTP 200 OK.
    public static let httpStatusOK = 200

    /// HTTP 404 Not Found.
    public static let httpStatusNotFound = 404

    /// HTTP 429 Too Many Requests.
    public static let httpStatusRateLimited = 429

    /// Retryable HTTP status codes.
    public static let retryableStatusCodes: Set<Int> = [429, 500, 502, 503, 504]

    // MARK: - File Management

    /// Default email for API identification when none configured.
    public static let defaultEmail = "user@example.com"

    /// Application support folder name.
    public static let appSupportFolderName = "BioMedLit"

    /// PDF cache folder name.
    public static let pdfCacheFolderName = "PDFCache"

    /// PDF file extension.
    public static let pdfExtension = "pdf"

    /// PDF filename prefix.
    public static let pdfFilenamePrefix = "article_"
}
