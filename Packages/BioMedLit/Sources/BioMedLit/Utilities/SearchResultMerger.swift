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
public enum SearchResultMerger {
    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > Title similarity
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed.
    ///   - europePMCResult: Results from Europe PMC.
    /// - Returns: Merged, deduplicated result.
    public static func merge(
        pubmedResult: SearchResult,
        europePMCResult: SearchResult
    ) -> SearchResult {
        var seen = Set<String>()  // Track seen identifiers
        var merged: [SearchArticle] = []

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

        // Estimate total (may have duplicates we removed)
        let estimatedTotal = pubmedResult.totalCount + europePMCResult.totalCount

        return SearchResult(
            articles: merged,
            totalCount: estimatedTotal,
            nextCursor: europePMCResult.nextCursor,
            nextOffset: pubmedResult.nextOffset,
            query: pubmedResult.query,
            provider: .both
        )
    }

    /// Merge arrays of articles, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > Title similarity
    ///
    /// - Parameters:
    ///   - primary: Primary articles (will be preserved in case of duplicates).
    ///   - secondary: Secondary articles (duplicates will be removed).
    /// - Returns: Merged, deduplicated array of articles.
    public static func mergeArticles(
        primary: [SearchArticle],
        secondary: [SearchArticle]
    ) -> [SearchArticle] {
        var seen = Set<String>()
        var merged: [SearchArticle] = []

        // Add primary results first
        for article in primary {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        // Add unique secondary results
        for article in secondary {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                merged.append(article)
            }
        }

        return merged
    }

    /// Generate a unique key for deduplication.
    ///
    /// - Parameter article: The article to generate a key for.
    /// - Returns: A string key for deduplication.
    private static func deduplicationKey(for article: SearchArticle) -> String {
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
    public static func areDuplicates(_ articleA: SearchArticle, _ articleB: SearchArticle) -> Bool {
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
    public static func titleSimilarity(_ titleA: String, _ titleB: String) -> Double {
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
