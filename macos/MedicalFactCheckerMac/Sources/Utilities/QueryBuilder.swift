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

// MARK: - Query Builder Protocol

/// Protocol for building provider-specific query strings from StructuredQuery.
protocol QueryBuilder {
    /// Build a native query string for this provider.
    ///
    /// - Parameter query: The structured query to translate.
    /// - Returns: Native query string for the provider.
    static func build(from query: StructuredQuery) -> String
}

// MARK: - PubMed Query Builder

/// Builds PubMed query strings from StructuredQuery.
///
/// ## PubMed Syntax Reference
/// - MeSH terms: `"Term"[MeSH]`
/// - Title/Abstract: `keyword[tiab]`
/// - Has abstract filter: `hasabstract`
/// - Publication type: `"Type"[pt]`
/// - Boolean: `AND`, `OR`, `NOT`
enum PubMedQueryBuilder: QueryBuilder {
    /// Standard publication types to exclude for clinical queries.
    static let defaultExcludeTypes = [
        "News", "Newspaper Article", "Editorial", "Letter", "Comment",
        "Published Erratum", "Biography", "Historical Article",
        "Personal Narrative", "Directory", "Retracted Publication"
    ]

    /// Build a PubMed query string.
    static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return "hasabstract"
        }

        var parts: [String] = []

        // Build concept clauses (combined with AND)
        for concept in query.concepts where !concept.isEmpty {
            let clause = buildConceptClause(concept)
            if !clause.isEmpty {
                parts.append("(\(clause))")
            }
        }

        guard !parts.isEmpty else {
            return "hasabstract"
        }

        // Join concepts with AND
        var result = parts.joined(separator: " AND ")

        // Add abstract filter
        if query.requireAbstract {
            result += " AND hasabstract"
        }

        // Add publication type exclusions
        let excludeTypes = query.excludePublicationTypes.isEmpty
            ? defaultExcludeTypes
            : query.excludePublicationTypes

        if !excludeTypes.isEmpty {
            let exclusions = excludeTypes.map { formatPublicationType($0) }
            result += " NOT (\(exclusions.joined(separator: " OR ")))"
        }

        // Add date range
        if let dateRange = query.dateRange {
            result += " AND \(dateRange.startYear):\(dateRange.endYear)[dp]"
        }

        return result
    }

    /// Build clause for a single concept (terms combined with OR).
    private static func buildConceptClause(_ concept: SearchConcept) -> String {
        var terms: [String] = []

        // Add MeSH terms
        for mesh in concept.meshTerms {
            terms.append("\"\(mesh)\"[MeSH]")
        }

        // Add keywords (search in title/abstract)
        for keyword in concept.keywords {
            // Multi-word keywords need quotes
            if keyword.contains(" ") {
                terms.append("\"\(keyword)\"[tiab]")
            } else {
                terms.append("\(keyword)[tiab]")
            }
        }

        return terms.joined(separator: " OR ")
    }

    /// Format a publication type for exclusion.
    private static func formatPublicationType(_ type: String) -> String {
        if type.contains(" ") {
            return "\"\(type)\"[pt]"
        }
        return "\(type)[pt]"
    }
}

// MARK: - Europe PMC Query Builder

/// Builds Europe PMC query strings from StructuredQuery.
///
/// ## Europe PMC Syntax Reference
/// - Title/Abstract: `TITLE_ABS:"keyword"`
/// - Has abstract filter: `HAS_ABSTRACT:y`
/// - Exclude preprints: `NOT SRC:PPR`
/// - Boolean: `AND`, `OR`, `NOT`
/// - Publication year: `PUB_YEAR:2024` or `PUB_YEAR:[2020 TO 2024]`
///
/// ## Note on MeSH Terms
/// Europe PMC's MeSH indexing has much lower coverage than PubMed's.
/// Using MeSH_TERM in queries drastically reduces results because most
/// articles aren't indexed with MeSH in Europe PMC. We use keywords only.
///
/// ## Note on Publication Type Exclusions
/// Europe PMC doesn't have the same volume of non-article content as PubMed,
/// so we skip publication type exclusions to avoid filtering out valid results.
enum EuropePMCQueryBuilder: QueryBuilder {
    /// Build a Europe PMC query string.
    ///
    /// Uses keywords only (not MeSH terms) because Europe PMC's MeSH coverage
    /// is much lower than PubMed's, which would drastically reduce results.
    static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return "HAS_ABSTRACT:y"
        }

        var parts: [String] = []

        // Build concept clauses (combined with AND)
        for concept in query.concepts where !concept.isEmpty {
            let clause = buildConceptClause(concept)
            if !clause.isEmpty {
                parts.append("(\(clause))")
            }
        }

        guard !parts.isEmpty else {
            return "HAS_ABSTRACT:y"
        }

        // Join concepts with AND
        var result = parts.joined(separator: " AND ")

        // Add abstract filter
        if query.requireAbstract {
            result += " AND HAS_ABSTRACT:y"
        }

        // Add preprint exclusion
        if query.excludePreprints {
            result += " NOT SRC:PPR"
        }

        // Note: We skip publication type exclusions for Europe PMC because:
        // 1. Europe PMC doesn't have the same volume of non-article content
        // 2. The PUB_TYPE field values differ from PubMed
        // 3. Over-filtering reduces valid results

        // Add date range
        if let dateRange = query.dateRange {
            result += " AND PUB_YEAR:[\(dateRange.startYear) TO \(dateRange.endYear)]"
        }

        return result
    }

    /// Build clause for a single concept (terms combined with OR).
    ///
    /// Uses only keywords (not MeSH terms) because Europe PMC's MeSH coverage
    /// is significantly lower than PubMed's.
    private static func buildConceptClause(_ concept: SearchConcept) -> String {
        var terms: [String] = []

        // Note: We skip MeSH terms for Europe PMC because their MeSH indexing
        // has much lower coverage than PubMed. Including MeSH_TERM would
        // drastically reduce results. Instead, we include MeSH term text as
        // keywords to search in title/abstract.

        // Add MeSH term text as keywords (search as free text)
        for mesh in concept.meshTerms {
            terms.append("TITLE_ABS:\"\(mesh)\"")
        }

        // Add keywords (search in title/abstract)
        for keyword in concept.keywords {
            // Always quote in Europe PMC for consistency
            terms.append("TITLE_ABS:\"\(keyword)\"")
        }

        return terms.joined(separator: " OR ")
    }
}

// MARK: - Query Builder Factory

/// Factory for getting the appropriate query builder for a search provider.
enum QueryBuilderFactory {
    /// Build a query string for the specified provider.
    ///
    /// - Parameters:
    ///   - query: The structured query.
    ///   - provider: The search provider.
    /// - Returns: Native query string for the provider.
    static func build(from query: StructuredQuery, for provider: SearchProvider) -> String {
        switch provider {
        case .pubmed:
            return PubMedQueryBuilder.build(from: query)
        case .europePMC:
            return EuropePMCQueryBuilder.build(from: query)
        case .both:
            // For "both", we'll need to call each builder separately
            // This method returns PubMed format as a fallback
            return PubMedQueryBuilder.build(from: query)
        }
    }

    /// Build query strings for all needed providers.
    ///
    /// - Parameters:
    ///   - query: The structured query.
    ///   - provider: The search provider (determines which queries to build).
    /// - Returns: Dictionary mapping provider to query string.
    static func buildAll(
        from query: StructuredQuery,
        for provider: SearchProvider
    ) -> [SearchProvider: String] {
        switch provider {
        case .pubmed:
            return [.pubmed: PubMedQueryBuilder.build(from: query)]
        case .europePMC:
            return [.europePMC: EuropePMCQueryBuilder.build(from: query)]
        case .both:
            return [
                .pubmed: PubMedQueryBuilder.build(from: query),
                .europePMC: EuropePMCQueryBuilder.build(from: query)
            ]
        }
    }
}
