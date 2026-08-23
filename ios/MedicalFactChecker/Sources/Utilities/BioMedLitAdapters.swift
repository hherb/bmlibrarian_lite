// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
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
///
/// Note: Due to Swift module name collision (both MedicalFactChecker and BioMedLit
/// define SearchProvider), use `BioMedLitAdapters.buildQuery` wrapper instead of
/// calling `BMLQueryBuilderFactory.build` directly from other files.
typealias BMLSearchResultMerger = SearchResultMerger

// MARK: - Unified Article Metadata

/// Unified article metadata that normalizes data from different search providers.
///
/// This struct provides a common interface for article data regardless of source,
/// enabling consistent handling throughout the app. Each provider's response
/// format is converted to this unified representation.
struct UnifiedArticleMetadata: Sendable, Identifiable, Equatable {
    // MARK: - Identification

    /// Unique identifier combining source and ID (e.g., "pubmed-12345678").
    var id: String { "\(source.rawValue)-\(pmid.isEmpty ? (doi ?? title.hashValue.description) : pmid)" }

    /// PubMed ID (may be empty for preprints or non-PubMed sources).
    let pmid: String

    /// PubMed Central ID (e.g., "PMC1234567").
    let pmcId: String?

    /// Digital Object Identifier.
    let doi: String?

    // MARK: - Bibliographic Data

    /// Article title.
    let title: String

    /// Article abstract text.
    let abstract: String

    /// List of author names in display format.
    let authors: [String]

    /// Journal or source name.
    let journal: String

    /// Publication date as string (format varies by source).
    let publicationDate: String?

    /// Publication year as integer for sorting/filtering.
    let year: Int?

    // MARK: - Indexing & Classification

    /// MeSH terms (Medical Subject Headings) for the article.
    let meshTerms: [String]

    // MARK: - Source Tracking

    /// Which provider this article came from.
    let source: SearchProvider

    /// Whether this is a preprint (Europe PMC only).
    let isPreprint: Bool

    /// Whether full text is available in PubMed Central.
    ///
    /// True if the article has a PMC ID or the `inPMC` flag is set.
    /// Used to show availability badge before user attempts to fetch full text.
    let hasFullTextInPMC: Bool

    /// Batch number for pagination tracking.
    let batchNumber: Int

    /// Position within search results (0-indexed).
    let resultPosition: Int

    // MARK: - Initialization

    /// Initialize unified metadata with all fields.
    ///
    /// - Parameters:
    ///   - pmid: PubMed ID.
    ///   - pmcId: PubMed Central ID.
    ///   - doi: Digital Object Identifier.
    ///   - title: Article title.
    ///   - abstract: Abstract text.
    ///   - authors: List of author names.
    ///   - journal: Journal name.
    ///   - publicationDate: Publication date string.
    ///   - year: Publication year.
    ///   - meshTerms: MeSH indexing terms.
    ///   - source: Provider that returned this article.
    ///   - isPreprint: Whether this is a preprint.
    ///   - hasFullTextInPMC: Whether full text is available in PMC.
    ///   - batchNumber: Batch number for tracking.
    ///   - resultPosition: Position in search results.
    init(
        pmid: String = "",
        pmcId: String? = nil,
        doi: String? = nil,
        title: String,
        abstract: String,
        authors: [String] = [],
        journal: String = "",
        publicationDate: String? = nil,
        year: Int? = nil,
        meshTerms: [String] = [],
        source: SearchProvider,
        isPreprint: Bool = false,
        hasFullTextInPMC: Bool = false,
        batchNumber: Int = 1,
        resultPosition: Int = 0
    ) {
        self.pmid = pmid
        self.pmcId = pmcId
        self.doi = doi
        self.title = title
        self.abstract = abstract
        self.authors = authors
        self.journal = journal
        self.publicationDate = publicationDate
        self.year = year
        self.meshTerms = meshTerms
        self.source = source
        self.isPreprint = isPreprint
        self.hasFullTextInPMC = hasFullTextInPMC
        self.batchNumber = batchNumber
        self.resultPosition = resultPosition
    }
}

// MARK: - BioMedLit Adapters

/// Adapters to convert between BioMedLit types and app-local types.
///
/// This allows the app to use BioMedLit services internally while maintaining
/// backwards compatibility with existing app data models.
enum BioMedLitAdapters {
    // MARK: - Query Building (Type-Safe Wrapper)

    /// Build a query string from a StructuredQuery using the appropriate provider syntax.
    ///
    /// This wrapper function resolves the SearchProvider type collision between
    /// MedicalFactChecker and BioMedLit modules. Call this instead of
    /// `BMLQueryBuilderFactory.build` directly.
    ///
    /// - Parameters:
    ///   - query: The structured query to translate.
    ///   - provider: The app's SearchProvider enum (from MedicalFactChecker).
    /// - Returns: Provider-specific query string.
    static func buildQuery(from query: BMLStructuredQuery, for provider: MedicalFactChecker.SearchProvider) -> String {
        // Convert app SearchProvider to BioMedLit SearchProvider and build query.
        // We use the PubMedQueryBuilder and EuropePMCQueryBuilder directly to avoid
        // the type collision with QueryBuilderFactory.build(from:for:).
        switch provider {
        case .pubmed:
            return PubMedQueryBuilder.build(from: query)
        case .europePMC:
            return EuropePMCQueryBuilder.build(from: query)
        case .both:
            // Default to PubMed syntax for "both" mode
            return PubMedQueryBuilder.build(from: query)
        }
    }

    // MARK: - Search Result Conversion

    /// Convert BioMedLit SearchArticle to app UnifiedArticleMetadata.
    ///
    /// - Parameters:
    ///   - article: The BioMedLit SearchArticle.
    ///   - appProvider: App search provider to record as source.
    ///   - batchNumber: Which batch this article came from.
    ///   - resultPosition: Position in overall search results.
    /// - Returns: App-compatible UnifiedArticleMetadata.
    static func toUnifiedArticleMetadata(
        _ article: BMLSearchArticle,
        appProvider: SearchProvider,
        batchNumber: Int,
        resultPosition: Int
    ) -> UnifiedArticleMetadata {
        // Parse authors string back into array
        let authorsArray = parseAuthors(article.authors)

        return UnifiedArticleMetadata(
            pmid: article.pmid,
            pmcId: article.pmcId,
            doi: article.doi,
            title: article.title,
            abstract: article.abstract,
            authors: authorsArray,
            journal: article.journal,
            publicationDate: article.publicationDate,
            year: Int(article.year),
            meshTerms: [],  // BioMedLit doesn't parse MeSH terms yet
            source: appProvider,
            isPreprint: false,  // BioMedLit SearchArticle doesn't track preprint status
            hasFullTextInPMC: article.hasFullText,
            batchNumber: batchNumber,
            resultPosition: resultPosition
        )
    }

    /// Convert BioMedLit SearchResult to app-compatible articles array.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit SearchResult.
    ///   - appProvider: App search provider to record as source.
    ///   - batchNumber: Which batch this result represents.
    ///   - basePosition: Starting position for result numbering.
    /// - Returns: Array of app-compatible UnifiedArticleMetadata.
    static func toUnifiedArticleMetadataArray(
        _ result: BMLSearchResult,
        appProvider: SearchProvider,
        batchNumber: Int,
        basePosition: Int
    ) -> [UnifiedArticleMetadata] {
        result.articles.enumerated().map { index, article in
            toUnifiedArticleMetadata(
                article,
                appProvider: appProvider,
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
        let articles = toUnifiedArticleMetadataArray(
            result,
            appProvider: appProvider,
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
        // `warnings` and `degradation` are carried across for every case, not
        // just the parsed one: both describe the *retrieval*, and a fallback that
        // dropped them would be a PDF the reader is looking at precisely because
        // the parse failed, with nothing left to say so (#183).
        AppFullTextResult(
            content: content(of: result.content),
            source: appSource(of: result.content),
            warnings: result.warnings,
            degradation: result.degradation
        )
    }

    /// Map the package's content to the app's equivalent.
    ///
    /// - Parameter content: The package-side content.
    /// - Returns: The app-side content type.
    private static func content(of content: FullTextContent) -> AppFullTextContentType {
        switch content {
        case .europePMC(let html, let markdown):
            // Both HTML (for rendering) and markdown (for search/export fallback)
            return .html(content: html, markdown: markdown)
        case .europePMCPDF(let pdfURL), .unpaywall(let pdfURL):
            return .pdfURL(pdfURL)
        case .doi(let webURL):
            return .webURL(webURL)
        case .cached(let filePath):
            return .pdfURL(URL(fileURLWithPath: filePath))
        }
    }

    /// Map the package's source to the app's equivalent.
    ///
    /// - Parameter content: The package-side content, which names its own source.
    /// - Returns: The app-side source.
    private static func appSource(of content: FullTextContent) -> AppFullTextSource {
        switch content {
        case .europePMC: return .europePMC
        case .europePMCPDF: return .europePMCPDF
        case .unpaywall: return .unpaywall
        case .doi: return .doi
        case .cached: return .cached
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

/// Type alias for BioMedLit TransparencyAnalysisService.
typealias BMLTransparencyAnalysisService = TransparencyAnalysisService

extension TransparencyAnalysisService {
    /// Create a configured transparency analysis service from app settings.
    ///
    /// - Parameter settings: App settings containing NCBI credentials.
    /// - Returns: Configured transparency analysis service.
    static func create(from settings: AppSettings) -> TransparencyAnalysisService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return TransparencyAnalysisService(email: email, pubmedApiKey: apiKey)
    }
}
