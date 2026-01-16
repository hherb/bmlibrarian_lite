//
//  QueryBuilder.swift
//  MedicalFactCheckerMac
//
//  Builds native query strings from StructuredQuery for different search providers.
//
//  Each provider has its own query syntax:
//  - PubMed: "Term"[MeSH] OR keyword[tiab]
//  - Europe PMC: MeSH_TERM:"Term" OR TITLE_ABS:"keyword"
//

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
/// - MeSH terms: `MeSH_TERM:"Term"`
/// - Title/Abstract: `TITLE_ABS:"keyword"`
/// - Has abstract filter: `HAS_ABSTRACT:y`
/// - Publication type: `PUB_TYPE:"type"`
/// - Exclude preprints: `NOT SRC:PPR`
/// - Boolean: `AND`, `OR`, `NOT`
/// - Publication year: `PUB_YEAR:2024` or `PUB_YEAR:[2020 TO 2024]`
enum EuropePMCQueryBuilder: QueryBuilder {
    /// Standard publication types to exclude for clinical queries.
    ///
    /// Note: Europe PMC uses lowercase hyphenated format for some types.
    static let defaultExcludeTypes = [
        "News", "Newspaper Article", "Editorial", "Letter", "Comment",
        "Published Erratum", "Biography", "Historical Article",
        "Personal Narrative", "Directory", "Retracted Publication"
    ]

    /// Build a Europe PMC query string.
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
            result += " AND PUB_YEAR:[\(dateRange.startYear) TO \(dateRange.endYear)]"
        }

        return result
    }

    /// Build clause for a single concept (terms combined with OR).
    private static func buildConceptClause(_ concept: SearchConcept) -> String {
        var terms: [String] = []

        // Add MeSH terms
        for mesh in concept.meshTerms {
            terms.append("MeSH_TERM:\"\(mesh)\"")
        }

        // Add keywords (search in title/abstract)
        for keyword in concept.keywords {
            // Always quote in Europe PMC for consistency
            terms.append("TITLE_ABS:\"\(keyword)\"")
        }

        return terms.joined(separator: " OR ")
    }

    /// Format a publication type for exclusion.
    private static func formatPublicationType(_ type: String) -> String {
        return "PUB_TYPE:\"\(type)\""
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
