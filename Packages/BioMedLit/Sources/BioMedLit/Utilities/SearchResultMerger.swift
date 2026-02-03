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

    /// Minimum word length to include in similarity calculation.
    /// Filters out very short words (articles, prepositions) that
    /// add noise to Jaccard similarity.
    static let minWordLength = 2
}

// MARK: - Search Result Merger

/// Merges and deduplicates search results from multiple providers.
///
/// This utility combines results from PubMed and Europe PMC, removing
/// duplicate articles based on PMID, DOI, PMC ID, or title similarity.
///
/// Uses multi-key deduplication: when a PubMed article is inserted, all
/// its identifiers (PMID, DOI, PMC ID) are registered so Europe PMC
/// articles can be matched on any identifier.
public enum SearchResultMerger {
    /// Merge results from PubMed and Europe PMC, removing duplicates.
    ///
    /// Deduplication priority: PMID > DOI > PMC ID > Title similarity
    ///
    /// - Parameters:
    ///   - pubmedResult: Results from PubMed.
    ///   - europePMCResult: Results from Europe PMC.
    /// - Returns: Merged, deduplicated result.
    public static func merge(
        pubmedResult: SearchResult,
        europePMCResult: SearchResult
    ) -> SearchResult {
        var seen = Set<String>()
        var merged: [SearchArticle] = []

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
    /// Deduplication priority: PMID > DOI > PMC ID > Title similarity
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
                addAlternativeKeys(for: article, to: &seen)
                merged.append(article)
            }
        }

        // Add unique secondary results
        for article in secondary {
            let key = deduplicationKey(for: article)
            let isDuplicate = seen.contains(key) ||
                alternativeKeysContained(for: article, in: seen) ||
                titleMatchesExisting(article, in: merged)

            if !isDuplicate {
                seen.insert(key)
                addAlternativeKeys(for: article, to: &seen)
                merged.append(article)
            }
        }

        return merged
    }

    // MARK: - Deduplication Keys

    /// Generate a unique key for deduplication.
    ///
    /// Priority: PMID > DOI > normalized title
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
        return "title:\(normalizeTitle(article.title))"
    }

    /// Add alternative deduplication keys for an article.
    ///
    /// This ensures that articles can be matched by any of their identifiers,
    /// not just the primary key.
    ///
    /// - Parameters:
    ///   - article: Article to add keys for.
    ///   - seen: Set to add keys to.
    private static func addAlternativeKeys(
        for article: SearchArticle,
        to seen: inout Set<String>
    ) {
        if !article.pmid.isEmpty {
            seen.insert("pmid:\(article.pmid)")
        }
        if let doi = article.doi, !doi.isEmpty {
            seen.insert("doi:\(doi.lowercased())")
        }
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
        for article: SearchArticle,
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
        _ article: SearchArticle,
        in existing: [SearchArticle]
    ) -> Bool {
        for existingArticle in existing {
            if titleSimilarity(article.title, existingArticle.title) > MergerConstants.titleSimilarityThreshold {
                return true
            }
        }
        return false
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

    // MARK: - Public Duplicate Check

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

        // Same PMC ID
        if let pmcA = articleA.pmcId, let pmcB = articleB.pmcId,
           !pmcA.isEmpty && pmcA.lowercased() == pmcB.lowercased() {
            return true
        }

        // Similar title (Jaccard similarity > threshold)
        return titleSimilarity(articleA.title, articleB.title) > MergerConstants.titleSimilarityThreshold
    }

    // MARK: - Similarity Calculation

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

        guard !wordsA.isEmpty && !wordsB.isEmpty else { return 0.0 }

        let intersection = wordsA.intersection(wordsB).count
        let union = wordsA.union(wordsB).count

        guard union > 0 else { return 0.0 }

        return Double(intersection) / Double(union)
    }

    /// Extract meaningful words from a title for comparison.
    ///
    /// Filters out very short words to reduce noise in similarity calculation.
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
