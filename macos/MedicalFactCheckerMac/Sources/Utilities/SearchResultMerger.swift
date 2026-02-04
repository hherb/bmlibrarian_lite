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

// NOTE: This app-specific SearchResultMerger works with app-local types
// (UnifiedSearchResult, UnifiedArticleMetadata).
// A generic SearchResultMerger for BioMedLit types is available in the BioMedLit package at:
// Packages/BioMedLit/Sources/BioMedLit/Utilities/SearchResultMerger.swift

import Foundation
import BioMedLit

/// Merges and deduplicates search results from multiple literature search providers.
///
/// When searching both PubMed and Europe PMC, the same article may appear in both
/// result sets. This utility merges results while removing duplicates, preserving
/// the higher-quality metadata from the preferred source.
///
/// Deduplication priority:
/// 1. PMID match (most reliable)
/// 2. DOI match (very reliable)
/// 3. Title similarity > threshold (fallback)
enum SearchResultMerger {
    // MARK: - Configuration

    /// Configuration constants for result merging.
    private enum Config {
        /// Minimum Jaccard similarity to consider titles as duplicates.
        static let titleSimilarityThreshold = 0.8

        /// Minimum word length to include in similarity calculation.
        static let minWordLength = 2
    }

    // MARK: - Merge Results

    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// PubMed results are given priority as the primary source. Europe PMC articles
    /// are only added if they don't duplicate a PubMed article.
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed search.
    ///   - europePMCResult: Results from Europe PMC search.
    /// - Returns: Merged, deduplicated result.
    static func merge(
        pubmedResult: UnifiedSearchResult,
        europePMCResult: UnifiedSearchResult
    ) -> UnifiedSearchResult {
        var seen = Set<String>()
        var merged: [UnifiedArticleMetadata] = []

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

        // Sort by relevance (original position is a proxy for relevance)
        let sorted = merged.sorted { $0.resultPosition < $1.resultPosition }

        // Re-assign result positions after merge
        let reindexed = sorted.enumerated().map { index, article in
            UnifiedArticleMetadata(
                pmid: article.pmid,
                pmcId: article.pmcId,
                doi: article.doi,
                title: article.title,
                abstract: article.abstract,
                authors: article.authors,
                journal: article.journal,
                publicationDate: article.publicationDate,
                year: article.year,
                meshTerms: article.meshTerms,
                source: article.source,
                isPreprint: article.isPreprint,
                batchNumber: article.batchNumber,
                resultPosition: index
            )
        }

        // Estimate total (actual may be lower due to duplicates we removed)
        let estimatedTotal = pubmedResult.totalCount + europePMCResult.totalCount

        // Create combined pagination state
        let pagination = OffsetPaginationState(
            totalCount: estimatedTotal,
            offset: pubmedResult.pagination.logicalOffset,
            batchSize: reindexed.count
        )

        return UnifiedSearchResult(
            articles: reindexed,
            totalCount: estimatedTotal,
            pagination: pagination,
            provider: .both
        )
    }

    // MARK: - Deduplication Keys

    /// Generate a unique key for deduplication.
    ///
    /// Priority: PMID > DOI > normalized title
    ///
    /// - Parameter article: Article to generate key for.
    /// - Returns: Deduplication key string.
    private static func deduplicationKey(for article: UnifiedArticleMetadata) -> String {
        // Prefer PMID (most reliable)
        if !article.pmid.isEmpty {
            return "pmid:\(article.pmid)"
        }

        // Fall back to DOI
        if let doi = article.doi, !doi.isEmpty {
            return "doi:\(doi.lowercased())"
        }

        // Last resort: normalized title
        return "title:\(normalizeTitle(article.title))"
    }

    /// Add alternative deduplication keys for an article.
    ///
    /// This ensures that articles can be matched by any of their identifiers.
    ///
    /// - Parameters:
    ///   - article: Article to add keys for.
    ///   - seen: Set to add keys to.
    private static func addAlternativeKeys(
        for article: UnifiedArticleMetadata,
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
        for article: UnifiedArticleMetadata,
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
        _ article: UnifiedArticleMetadata,
        in existing: [UnifiedArticleMetadata]
    ) -> Bool {
        for existingArticle in existing {
            if titleSimilarity(article.title, existingArticle.title) > Config.titleSimilarityThreshold {
                return true
            }
        }
        return false
    }

    // MARK: - Similarity Calculation

    /// Calculate Jaccard similarity between two titles.
    ///
    /// Jaccard similarity is the size of intersection divided by size of union
    /// of the word sets from both titles.
    ///
    /// - Parameters:
    ///   - titleA: First title.
    ///   - titleB: Second title.
    /// - Returns: Similarity score (0.0 to 1.0).
    static func titleSimilarity(_ titleA: String, _ titleB: String) -> Double {
        let wordsA = extractWords(from: titleA)
        let wordsB = extractWords(from: titleB)

        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0.0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        guard union > 0 else { return 0.0 }

        return Double(intersection) / Double(union)
    }

    /// Extract meaningful words from a title for comparison.
    ///
    /// Filters out short words and normalizes to lowercase.
    ///
    /// - Parameter title: Title string.
    /// - Returns: Set of normalized words.
    private static func extractWords(from title: String) -> Set<String> {
        Set(
            title.lowercased()
                .components(separatedBy: .alphanumerics.inverted)
                .filter { $0.count >= Config.minWordLength }
        )
    }

    /// Normalize a title for comparison.
    ///
    /// Removes non-alphanumeric characters and lowercases.
    ///
    /// - Parameter title: Title to normalize.
    /// - Returns: Normalized title string.
    private static func normalizeTitle(_ title: String) -> String {
        title.lowercased()
            .components(separatedBy: .alphanumerics.inverted)
            .joined()
    }

    // MARK: - Public Duplicate Check

    /// Check if two articles are likely duplicates.
    ///
    /// Uses the same logic as the merge process to determine if two articles
    /// represent the same publication.
    ///
    /// - Parameters:
    ///   - articleA: First article.
    ///   - articleB: Second article.
    /// - Returns: True if articles are likely duplicates.
    static func areDuplicates(
        _ articleA: UnifiedArticleMetadata,
        _ articleB: UnifiedArticleMetadata
    ) -> Bool {
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

        // Similar title (Jaccard similarity above threshold)
        return titleSimilarity(articleA.title, articleB.title) > Config.titleSimilarityThreshold
    }
}
