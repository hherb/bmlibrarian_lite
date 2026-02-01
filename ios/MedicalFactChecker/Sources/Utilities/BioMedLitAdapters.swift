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
import BioMedLit

// MARK: - Module Type Aliases
// Note: Types from the BioMedLit module are imported directly (not via BioMedLit. prefix)
// because the module has an enum called BioMedLit which causes a name collision.
// The types SearchResult, SearchArticle, PubMedService, etc. are at the module top-level.

/// Type alias for BioMedLit SearchResult to avoid collision with app types.
typealias BMLSearchResult = SearchResult

/// Type alias for BioMedLit SearchArticle to avoid collision with app types.
typealias BMLSearchArticle = SearchArticle

/// Type alias for BioMedLit SearchProvider to disambiguate from app SearchProvider.
/// Note: The app has its own SearchProvider enum in SearchProvider.swift, and BioMedLit
/// also exports SearchProvider. We use the one from BioMedLit via this alias.
typealias BMLSearchProvider = SearchProvider

/// Type alias for BioMedLit FullTextResult to disambiguate from app FullTextResult.
typealias BMLFullTextResult = FullTextResult

/// Type alias for BioMedLit FullTextSource to disambiguate from app FullTextSource.
typealias BMLFullTextSource = FullTextSource

/// Type alias for BioMedLit PubMedService.
typealias BMLPubMedService = PubMedService

/// Type alias for BioMedLit EuropePMCService.
typealias BMLEuropePMCService = EuropePMCService

/// Type alias for BioMedLit FullTextService.
typealias BMLFullTextService = FullTextService

// MARK: - Shared Utility Type Aliases

/// Type alias for BioMedLit QueryTranslator (now shared in BioMedLit package).
typealias BMLQueryTranslator = QueryTranslator

/// Type alias for BioMedLit ResponseParser (now shared in BioMedLit package).
typealias BMLResponseParser = ResponseParser

/// Type alias for BioMedLit QueryConstants (now shared in BioMedLit package).
typealias BMLQueryConstants = QueryConstants

/// Type alias for BioMedLit StructuredQuery (now shared in BioMedLit package).
typealias BMLStructuredQuery = StructuredQuery

/// Type alias for BioMedLit SearchConcept (now shared in BioMedLit package).
typealias BMLSearchConcept = SearchConcept

/// Type alias for BioMedLit DateRange (now shared in BioMedLit package).
typealias BMLDateRange = DateRange

/// Type alias for BioMedLit Verdict (now shared in BioMedLit package).
typealias BMLVerdict = Verdict

/// Type alias for BioMedLit QueryBuilderFactory (now shared in BioMedLit package).
typealias BMLQueryBuilderFactory = QueryBuilderFactory

/// Type alias for BioMedLit SearchResultMerger (now shared in BioMedLit package).
typealias BMLSearchResultMerger = SearchResultMerger

// MARK: - Article Metadata

/// Intermediate article metadata for search results.
///
/// This lightweight struct is used to pass article data between services
/// before creating SwiftData Document objects.
struct ArticleMetadata: Sendable, Identifiable, Equatable {
    var id: String { pmid }
    let pmid: String
    let title: String
    let abstract: String
    let authors: [String]
    let journal: String
    let publicationDate: String?
    let year: Int?
    let doi: String?
    let pmcId: String?
    let meshTerms: [String]
    let batchNumber: Int
    let resultPosition: Int

    /// Whether this article likely has full text in PMC.
    var hasFullText: Bool {
        pmcId != nil
    }
}

// MARK: - BioMedLit Adapters

/// Adapters to convert between BioMedLit types and app-local types.
///
/// This allows the app to use BioMedLit services internally while maintaining
/// backwards compatibility with existing app data models.
enum BioMedLitAdapters {
    // MARK: - Search Result Conversion

    /// Convert BioMedLit SearchArticle to app ArticleMetadata.
    ///
    /// - Parameters:
    ///   - article: The BioMedLit SearchArticle.
    ///   - batchNumber: Which batch this article came from.
    ///   - resultPosition: Position in overall search results.
    /// - Returns: App-compatible ArticleMetadata.
    static func toArticleMetadata(
        _ article: BMLSearchArticle,
        batchNumber: Int,
        resultPosition: Int
    ) -> ArticleMetadata {
        // Parse authors string back into array
        let authorsArray = parseAuthors(article.authors)

        return ArticleMetadata(
            pmid: article.pmid,
            title: article.title,
            abstract: article.abstract,
            authors: authorsArray,
            journal: article.journal,
            publicationDate: article.publicationDate,
            year: Int(article.year) ?? nil,
            doi: article.doi,
            pmcId: article.pmcId,
            meshTerms: [],  // BioMedLit doesn't parse MeSH terms yet
            batchNumber: batchNumber,
            resultPosition: resultPosition
        )
    }

    /// Convert BioMedLit SearchResult to app-compatible articles array.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit SearchResult.
    ///   - batchNumber: Which batch this result represents.
    ///   - basePosition: Starting position for result numbering.
    /// - Returns: Array of app-compatible ArticleMetadata.
    static func toArticleMetadataArray(
        _ result: BMLSearchResult,
        batchNumber: Int,
        basePosition: Int
    ) -> [ArticleMetadata] {
        result.articles.enumerated().map { index, article in
            toArticleMetadata(
                article,
                batchNumber: batchNumber,
                resultPosition: basePosition + index
            )
        }
    }

    // MARK: - Unified Search Result Conversion

    /// Convert BioMedLit SearchResult to UnifiedSearchResult with pagination state.
    ///
    /// Creates appropriate pagination state based on the provider:
    /// - PubMed: Uses offset-based pagination
    /// - Europe PMC: Uses cursor-based pagination
    ///
    /// - Parameters:
    ///   - result: The BioMedLit SearchResult.
    ///   - appProvider: The app's search provider enum.
    ///   - batchNumber: Which batch this result represents.
    ///   - basePosition: Starting position for result numbering.
    ///   - currentCursor: Current cursor for Europe PMC (optional).
    ///   - nextCursor: Next cursor from Europe PMC response (optional).
    /// - Returns: UnifiedSearchResult with proper pagination state.
    static func toUnifiedSearchResult(
        _ result: BMLSearchResult,
        appProvider: SearchProvider,
        batchNumber: Int,
        basePosition: Int,
        currentCursor: String? = nil,
        nextCursor: String? = nil
    ) -> UnifiedSearchResult {
        // Convert articles
        let articles = toArticleMetadataArray(
            result,
            batchNumber: batchNumber,
            basePosition: basePosition
        )

        // Create appropriate pagination state based on provider
        let pagination: any PaginationState
        switch appProvider {
        case .pubmed:
            pagination = OffsetPaginationState(
                totalCount: result.totalCount,
                offset: basePosition,
                batchSize: articles.count
            )
        case .europePMC:
            // For Europe PMC, use cursor-based pagination
            let hasMore = nextCursor != nil && !articles.isEmpty
            pagination = CursorPaginationState(
                totalCount: result.totalCount,
                fetchedCount: basePosition + articles.count,
                currentCursor: currentCursor,
                nextCursor: hasMore ? nextCursor : nil
            )
        case .both:
            // For merged results, use offset-based pagination as default
            pagination = OffsetPaginationState(
                totalCount: result.totalCount,
                offset: basePosition,
                batchSize: articles.count
            )
        }

        return UnifiedSearchResult(
            articles: articles,
            totalCount: result.totalCount,
            pagination: pagination,
            provider: appProvider
        )
    }

    // MARK: - Search Provider Conversion

    /// Convert app SearchProvider to BioMedLit SearchProvider.
    ///
    /// - Parameter provider: App search provider enum.
    /// - Returns: BioMedLit search provider enum.
    static func toBioMedLitProvider(_ provider: SearchProvider) -> BMLSearchProvider {
        switch provider {
        case .pubmed:
            return .pubmed
        case .europePMC:
            return .europePMC
        case .both:
            // BioMedLit doesn't have a "both" option, default to PubMed
            // The app handles "both" by calling both services separately
            return .pubmed
        }
    }

    // MARK: - Full Text Conversion

    /// Convert BioMedLit FullTextResult to app's AppFullTextResult.
    ///
    /// - Parameter result: The BioMedLit FullTextResult.
    /// - Returns: App-compatible AppFullTextResult.
    static func toAppFullTextResult(_ result: BMLFullTextResult) -> AppFullTextResult {
        switch result {
        case .europePMC(let html, _):
            // Use HTML for proper table and figure rendering
            return AppFullTextResult(content: .html(html), source: .europePMC)
        case .unpaywall(let pdfURL):
            return AppFullTextResult(content: .pdfURL(pdfURL), source: .unpaywall)
        case .doi(let webURL):
            return AppFullTextResult(content: .webURL(webURL), source: .doi)
        case .cached(let filePath):
            return AppFullTextResult(content: .pdfURL(URL(fileURLWithPath: filePath)), source: .cached)
        }
    }

    /// Convert BioMedLit FullTextResult to rich content format (with HTML).
    ///
    /// - Parameter result: The BioMedLit FullTextResult.
    /// - Returns: Tuple with content and source information.
    static func toFullTextContent(
        _ result: BMLFullTextResult
    ) -> (content: FullTextContent, source: AppFullTextSource) {
        switch result {
        case .europePMC(let html, let markdown):
            return (
                content: .jatsContent(html: html, markdown: markdown),
                source: .europePMC
            )
        case .unpaywall(let pdfURL):
            return (
                content: .pdfURL(pdfURL),
                source: .unpaywall
            )
        case .doi(let webURL):
            return (
                content: .webURL(webURL),
                source: .doi
            )
        case .cached(let filePath):
            return (
                content: .cachedPDF(URL(fileURLWithPath: filePath)),
                source: .cached
            )
        }
    }

    // MARK: - Private Helpers

    /// Parse author string back into array.
    ///
    /// Handles both "Author1, Author2, Author3" and "Author1, Author2 et al." formats.
    private static func parseAuthors(_ authorsString: String) -> [String] {
        guard !authorsString.isEmpty else { return [] }

        // Handle "et al." case
        let cleanedString = authorsString.replacingOccurrences(of: " et al.", with: "")

        // Split by ", " but be careful with author names that contain commas
        // BioMedLit uses "LastName, FirstName" format joined by ", "
        // We need to split properly
        return cleanedString.components(separatedBy: ", ")
    }
}

// MARK: - Full Text Content

/// App-specific full text content representation.
enum FullTextContent: Sendable {
    /// JATS XML converted to HTML and markdown.
    case jatsContent(html: String, markdown: String)

    /// Direct PDF URL.
    case pdfURL(URL)

    /// Web URL (publisher page).
    case webURL(URL)

    /// Cached PDF file.
    case cachedPDF(URL)

    /// Get markdown content if available.
    var markdown: String? {
        if case .jatsContent(_, let markdown) = self {
            return markdown
        }
        return nil
    }

    /// Get HTML content if available.
    var html: String? {
        if case .jatsContent(let html, _) = self {
            return html
        }
        return nil
    }

    /// Get URL if this is a URL-based content.
    var url: URL? {
        switch self {
        case .pdfURL(let url), .webURL(let url), .cachedPDF(let url):
            return url
        case .jatsContent:
            return nil
        }
    }
}

// MARK: - Unified Article Metadata Extension

extension ArticleMetadata {
    /// The source of this article (for unified search results).
    var source: ArticleSource {
        // Determine source based on available identifiers
        if pmcId != nil {
            return .europePMC
        }
        return .pubmed
    }

    /// Whether this article has full text available in PMC.
    var hasFullTextInPMC: Bool {
        pmcId != nil
    }
}

/// Source of an article in search results.
enum ArticleSource: String, Sendable {
    case pubmed
    case europePMC
}

// MARK: - BioMedLit Service Extensions

extension BMLPubMedService {
    /// Create a configured PubMed service from app settings.
    ///
    /// - Parameter settings: App settings containing NCBI credentials.
    /// - Returns: Configured PubMed service.
    static func create(from settings: AppSettings) -> BMLPubMedService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return BMLPubMedService(email: email, apiKey: apiKey)
    }
}

extension BMLEuropePMCService {
    /// Create a configured Europe PMC service.
    ///
    /// - Returns: Configured Europe PMC service.
    static func create() -> BMLEuropePMCService {
        return BMLEuropePMCService()
    }
}

extension BMLFullTextService {
    /// Create a configured full text service from app settings.
    ///
    /// - Parameter settings: App settings containing email for API identification.
    /// - Returns: Configured full text service.
    static func create(from settings: AppSettings) -> BMLFullTextService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        return BMLFullTextService(email: email)
    }
}
