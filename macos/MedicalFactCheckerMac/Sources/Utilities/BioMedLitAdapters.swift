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

// MARK: - BioMedLit Adapters

/// Adapters to convert between BioMedLit types and app-local types.
///
/// This allows the app to use BioMedLit services internally while maintaining
/// backwards compatibility with existing app data models.
enum BioMedLitAdapters {
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
        _ article: SearchArticle,
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
            journal: article.journal ?? "",
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

    /// Convert BioMedLit SearchResult to app UnifiedSearchResult.
    ///
    /// - Parameters:
    ///   - result: The BioMedLit SearchResult.
    ///   - appProvider: App search provider.
    ///   - batchNumber: Which batch this result represents.
    ///   - basePosition: Starting position for result numbering.
    /// - Returns: App-compatible UnifiedSearchResult.
    static func toUnifiedSearchResult(
        _ result: SearchResult,
        appProvider: SearchProvider,
        batchNumber: Int,
        basePosition: Int
    ) -> UnifiedSearchResult {
        let articles = result.articles.enumerated().map { index, article in
            toUnifiedArticleMetadata(
                article,
                appProvider: appProvider,
                batchNumber: batchNumber,
                resultPosition: basePosition + index
            )
        }

        // Convert pagination state
        let pagination: any PaginationState
        if let nextOffset = result.nextOffset {
            pagination = OffsetPaginationState(
                totalCount: result.totalCount,
                offset: basePosition,
                batchSize: articles.count
            )
        } else if let nextCursor = result.nextCursor {
            pagination = CursorPaginationState(
                totalCount: result.totalCount,
                fetchedCount: basePosition + articles.count,
                currentCursor: nil,
                nextCursor: nextCursor
            )
        } else {
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
    static func toBioMedLitProvider(_ provider: SearchProvider) -> BioMedLit.SearchProvider {
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

    /// Convert BioMedLit FullTextResult to app's FullTextResult.
    ///
    /// This adapts the BioMedLit package's FullTextResult enum to the app's
    /// FullTextResult struct which has a different structure.
    ///
    /// - Parameter bmlResult: The BioMedLit FullTextResult.
    /// - Returns: App-compatible FullTextResult.
    static func toAppFullTextResult(_ bmlResult: BioMedLit.FullTextResult) -> FullTextResult {
        switch bmlResult {
        case .europePMC(let html, let markdown):
            return .europePMC(html: html, markdown: markdown)
        case .unpaywall(let pdfURL):
            return .unpaywall(pdfURL: pdfURL)
        case .doi(let webURL):
            return .doi(webURL: webURL)
        case .cached(let filePath):
            // Convert file path to URL for cached PDF
            let url = URL(fileURLWithPath: filePath)
            return .cached(content: .pdfURL(url))
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
        return cleanedString.components(separatedBy: ", ")
    }
}

// MARK: - BioMedLit Service Extensions

extension PubMedService {
    /// Create a configured PubMed service from app settings.
    ///
    /// - Parameter settings: App settings containing NCBI credentials.
    /// - Returns: Configured PubMed service.
    static func create(from settings: AppSettings) -> PubMedService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        let apiKey = settings.ncbiAPIKey.isEmpty ? nil : settings.ncbiAPIKey
        return PubMedService(email: email, apiKey: apiKey)
    }
}

extension EuropePMCService {
    /// Create a configured Europe PMC service.
    ///
    /// - Returns: Configured Europe PMC service.
    static func create() -> EuropePMCService {
        return EuropePMCService()
    }
}

extension FullTextService {
    /// Create a configured full text service from app settings.
    ///
    /// - Parameter settings: App settings containing email for API identification.
    /// - Returns: Configured full text service.
    static func create(from settings: AppSettings) -> FullTextService {
        let email = settings.ncbiEmail.isEmpty ? "user@medicalfactchecker.app" : settings.ncbiEmail
        return FullTextService(email: email)
    }
}
