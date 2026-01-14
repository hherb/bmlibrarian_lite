//
//  SearchResultMerger.swift
//  MedicalFactChecker
//
//  Utility for merging search results from multiple providers.
//

import Foundation

// MARK: - Constants

/// Constants for search result merging.
private enum MergerConstants {
    /// Minimum Jaccard similarity to consider titles as duplicates.
    static let titleSimilarityThreshold: Double = 0.8
}

// MARK: - Search Result Merger

/// Merges and deduplicates search results from multiple providers.
///
/// This utility combines results from PubMed and Europe PMC, removing
/// duplicate articles based on PMID, DOI, or title similarity.
enum SearchResultMerger {
    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > Title similarity
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed.
    ///   - europePMCResult: Results from Europe PMC.
    /// - Returns: Merged, deduplicated result.
    static func merge(
        pubmedResult: UnifiedSearchResult,
        europePMCResult: UnifiedSearchResult
    ) -> UnifiedSearchResult {
        var seen = Set<String>()  // Track seen identifiers
        var merged: [ArticleMetadata] = []

        // Add PubMed results first (primary source)
        for article in pubmedResult.articles {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        // Add unique Europe PMC results
        for article in europePMCResult.articles {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        // Sort by relevance (original position is a proxy)
        let sorted = merged.sorted { $0.resultPosition < $1.resultPosition }

        // Estimate total (may have duplicates we removed)
        let estimatedTotal = pubmedResult.totalCount + europePMCResult.totalCount

        return UnifiedSearchResult(
            articles: sorted,
            totalCount: estimatedTotal,
            offset: pubmedResult.offset,
            provider: .both
        )
    }

    /// Generate a unique key for deduplication.
    ///
    /// - Parameter article: The article to generate a key for.
    /// - Returns: A string key for deduplication.
    private static func deduplicationKey(for article: ArticleMetadata) -> String {
        // Prefer PMID (most reliable)
        if !article.pmid.isEmpty {
            return "pmid:\(article.pmid)"
        }

        // Fall back to DOI
        if let doi = article.doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }

        // Last resort: normalized title
        let normalizedTitle = normalizeTitle(article.title)
        return "title:\(normalizedTitle)"
    }

    /// Normalize a title for comparison.
    ///
    /// - Parameter title: The title to normalize.
    /// - Returns: Normalized title with only alphanumeric characters.
    private static func normalizeTitle(_ title: String) -> String {
        title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    /// Check if two articles are likely duplicates.
    ///
    /// - Parameters:
    ///   - articleA: First article.
    ///   - articleB: Second article.
    /// - Returns: True if the articles are likely duplicates.
    static func areDuplicates(_ articleA: ArticleMetadata, _ articleB: ArticleMetadata) -> Bool {
        // Same PMID
        if !articleA.pmid.isEmpty && articleA.pmid == articleB.pmid {
            return true
        }

        // Same DOI
        if let doiA = articleA.doi, let doiB = articleB.doi,
           !doiA.isEmpty && doiA.lowercased() == doiB.lowercased() {
            return true
        }

        // Similar title (Jaccard similarity > threshold)
        let similarity = titleSimilarity(articleA.title, articleB.title)
        return similarity > MergerConstants.titleSimilarityThreshold
    }

    /// Calculate Jaccard similarity between two titles.
    ///
    /// The Jaccard similarity is the size of the intersection divided by
    /// the size of the union of the word sets.
    ///
    /// - Parameters:
    ///   - titleA: First title.
    ///   - titleB: Second title.
    /// - Returns: Similarity score between 0.0 and 1.0.
    static func titleSimilarity(_ titleA: String, _ titleB: String) -> Double {
        let wordsA = extractWords(from: titleA)
        let wordsB = extractWords(from: titleB)

        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        return Double(intersection) / Double(union)
    }

    /// Extract words from a title for comparison.
    ///
    /// - Parameter title: The title to extract words from.
    /// - Returns: Set of lowercase words.
    private static func extractWords(from title: String) -> Set<String> {
        Set(
            title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }
        )
    }
}
