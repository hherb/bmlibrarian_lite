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

// NOTE: This app-specific SearchResultMerger works with app-local types (UnifiedSearchResult, ArticleMetadata).
// A generic SearchResultMerger for BioMedLit types is available in the BioMedLit package at:
// Packages/BioMedLit/Sources/BioMedLit/Utilities/SearchResultMerger.swift

import Foundation
import BioMedLit

// MARK: - Constants

/// Constants for search result merging.
private enum MergerConstants {
    /// Minimum Jaccard similarity to consider titles as duplicates.
    static let titleSimilarityThreshold: Double = 0.8

    /// Minimum word length to include in similarity calculation.
    static let minWordLength = 2
}

// MARK: - Search Result Merger

/// Merges and deduplicates search results from multiple providers.
///
/// This utility combines results from PubMed and Europe PMC, removing
/// duplicate articles based on PMID, DOI, PMC ID, or title similarity.
///
/// Deduplication priority:
/// 1. PMID match (most reliable)
/// 2. DOI match (very reliable)
/// 3. PMC ID match
/// 4. Title similarity > threshold (fallback)
enum SearchResultMerger {
    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > PMC ID > Title similarity
    ///
    /// Note: For subsequent pages, callers need to track pagination separately
    /// since PubMed uses offset and Europe PMC uses cursor marks.
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed.
    ///   - europePMCResult: Results from Europe PMC.
    /// - Returns: Merged, deduplicated result with combined pagination state.
    static func merge(
        pubmedResult: UnifiedSearchResult,
        europePMCResult: UnifiedSearchResult
    ) -> UnifiedSearchResult {
        var seen = Set<String>()
        var merged: [ArticleMetadata] = []

        // Add PubMed results first (primary source, higher priority)
        for article in pubmedResult.articles {
            let key = deduplicationKey(for: article)
            if !seen.contains(key) {
                seen.insert(key)
                // Also add alternative keys for more robust deduplication
                addAlternativeKeys(for: article, to: &seen)
                merged.append(article)
            }
        }

        // Add unique Europe PMC results
        for article in europePMCResult.articles {
            let key = deduplicationKey(for: article)

            // Check all possible keys for this article
            let isDuplicate = seen.contains(key) ||
                alternativeKeysContained(for: article, in: seen) ||
                titleMatchesExisting(article, in: merged)

            if !isDuplicate {
                seen.insert(key)
                addAlternativeKeys(for: article, to: &seen)
                merged.append(article)
            }
        }

        // Sort by relevance (original position is a proxy)
        let sorted = merged.sorted { $0.resultPosition < $1.resultPosition }

        // Estimate total (may have duplicates we removed)
        let estimatedTotal = pubmedResult.totalCount + europePMCResult.totalCount

        // Create combined pagination state
        // We track both offset (for PubMed) and cursor (for Europe PMC)
        let combinedPagination = CombinedPaginationState(
            pubmedPagination: pubmedResult.pagination,
            europePMCPagination: europePMCResult.pagination
        )

        return UnifiedSearchResult(
            articles: sorted,
            totalCount: estimatedTotal,
            pagination: combinedPagination,
            provider: .both
        )
    }

    // MARK: - Deduplication Keys

    /// Generate a unique key for deduplication.
    ///
    /// Priority: PMID > DOI > normalized title
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

    /// Add alternative deduplication keys for an article.
    ///
    /// This ensures that articles can be matched by any of their identifiers.
    ///
    /// - Parameters:
    ///   - article: Article to add keys for.
    ///   - seen: Set to add keys to.
    private static func addAlternativeKeys(
        for article: ArticleMetadata,
        to seen: inout Set<String>
    ) {
        // Add PMID key
        if !article.pmid.isEmpty {
            seen.insert("pmid:\(article.pmid)")
        }

        // Add DOI key
        if let doi = article.doi, !doi.isEmpty {
            seen.insert("doi:\(doi.lowercased())")
        }

        // Add PMC ID key
        if let pmcId = article.pmcId, !pmcId.isEmpty {
            seen.insert("pmc:\(pmcId.lowercased())")
        }
    }

    /// Check if any alternative key for an article is in the seen set.
    ///
    /// - Parameters:
    ///   - article: Article to check.
    ///   - seen: Set of seen keys.
    /// - Returns: True if any key matches.
    private static func alternativeKeysContained(
        for article: ArticleMetadata,
        in seen: Set<String>
    ) -> Bool {
        if !article.pmid.isEmpty && seen.contains("pmid:\(article.pmid)") {
            return true
        }
        if let doi = article.doi, !doi.isEmpty, seen.contains("doi:\(doi.lowercased())") {
            return true
        }
        if let pmcId = article.pmcId, !pmcId.isEmpty, seen.contains("pmc:\(pmcId.lowercased())") {
            return true
        }
        return false
    }

    /// Check if article title matches any existing article using similarity.
    ///
    /// - Parameters:
    ///   - article: New article to check.
    ///   - existing: Existing articles to compare against.
    /// - Returns: True if a title match is found.
    private static func titleMatchesExisting(
        _ article: ArticleMetadata,
        in existing: [ArticleMetadata]
    ) -> Bool {
        for existingArticle in existing {
            if titleSimilarity(article.title, existingArticle.title) > MergerConstants.titleSimilarityThreshold {
                return true
            }
        }
        return false
    }

    // MARK: - Similarity Calculation

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

        // Same PMC ID
        if let pmcA = articleA.pmcId, let pmcB = articleB.pmcId,
           !pmcA.isEmpty && pmcA.lowercased() == pmcB.lowercased() {
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

        guard union > 0 else { return 0.0 }

        return Double(intersection) / Double(union)
    }

    /// Extract meaningful words from a title for comparison.
    ///
    /// Filters out short words and normalizes to lowercase.
    ///
    /// - Parameter title: The title to extract words from.
    /// - Returns: Set of lowercase words.
    private static func extractWords(from title: String) -> Set<String> {
        Set(
            title
                .lowercased()
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= MergerConstants.minWordLength }
        )
    }
}
