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

// MARK: - Structured Query

/// Provider-agnostic representation of a literature search query.
///
/// The LLM outputs this structured format, which is then translated to the native
/// query syntax of each search provider (PubMed, Europe PMC, etc.).
///
/// ## Example
/// ```swift
/// let query = StructuredQuery(
///     concepts: [
///         SearchConcept(
///             name: "artificial intelligence",
///             meshTerms: ["Artificial Intelligence"],
///             keywords: ["AI", "machine learning"]
///         ),
///         SearchConcept(
///             name: "triage",
///             meshTerms: ["Triage"],
///             keywords: ["triage"]
///         )
///     ],
///     requireAbstract: true
/// )
///
/// // Translate to PubMed syntax
/// let pubmedQuery = QueryBuilderFactory.build(from: query, for: .pubmed)
///
/// // Translate to Europe PMC syntax
/// let europepmcQuery = QueryBuilderFactory.build(from: query, for: .europePMC)
/// ```
public struct StructuredQuery: Codable, Sendable, Equatable {
    /// The search concepts, combined with AND logic.
    public let concepts: [SearchConcept]

    /// Whether to require abstracts (filters out articles without abstracts).
    public var requireAbstract: Bool = true

    /// Publication types to exclude (e.g., "News", "Editorial", "Letter").
    public var excludePublicationTypes: [String] = []

    /// Whether to exclude preprints (Europe PMC specific).
    public var excludePreprints: Bool = true

    /// Optional date range filter.
    public var dateRange: DateRange?

    /// Initialize with concepts and default filters.
    ///
    /// - Parameters:
    ///   - concepts: Array of search concepts to combine with AND logic.
    ///   - requireAbstract: Whether to filter out articles without abstracts.
    ///   - excludePublicationTypes: Publication types to exclude from results.
    ///   - excludePreprints: Whether to exclude preprints (Europe PMC only).
    ///   - dateRange: Optional date range filter.
    public init(
        concepts: [SearchConcept],
        requireAbstract: Bool = true,
        excludePublicationTypes: [String] = [],
        excludePreprints: Bool = true,
        dateRange: DateRange? = nil
    ) {
        self.concepts = concepts
        self.requireAbstract = requireAbstract
        self.excludePublicationTypes = excludePublicationTypes
        self.excludePreprints = excludePreprints
        self.dateRange = dateRange
    }

    /// Check if the query has any searchable content.
    public var isEmpty: Bool {
        concepts.isEmpty || concepts.allSatisfy { $0.isEmpty }
    }
}

// MARK: - Search Concept

/// A single concept in a structured query.
///
/// Each concept represents one facet of the search (e.g., "the drug", "the condition",
/// "the outcome"). Terms within a concept are combined with OR logic.
public struct SearchConcept: Codable, Sendable, Equatable {
    /// Human-readable name for this concept.
    public let name: String

    /// MeSH (Medical Subject Headings) terms for this concept.
    ///
    /// MeSH terms provide standardized vocabulary and include automatic
    /// expansion to related terms in PubMed.
    public let meshTerms: [String]

    /// Free-text keywords to search in title and abstract.
    public let keywords: [String]

    /// Initialize with name, MeSH terms, and keywords.
    ///
    /// - Parameters:
    ///   - name: Human-readable name for this concept.
    ///   - meshTerms: MeSH (Medical Subject Headings) terms.
    ///   - keywords: Free-text keywords for title/abstract search.
    public init(name: String, meshTerms: [String] = [], keywords: [String] = []) {
        self.name = name
        self.meshTerms = meshTerms
        self.keywords = keywords
    }

    /// Check if this concept has any searchable terms.
    public var isEmpty: Bool {
        meshTerms.isEmpty && keywords.isEmpty
    }

    /// All terms combined (for simple searches that don't support MeSH).
    public var allTerms: [String] {
        meshTerms + keywords
    }
}

// MARK: - Date Range

/// Date range filter for searches.
public struct DateRange: Codable, Sendable, Equatable {
    /// Start year (inclusive).
    public let startYear: Int

    /// End year (inclusive).
    public let endYear: Int

    /// Initialize with start and end years.
    ///
    /// - Parameters:
    ///   - startYear: Start year (inclusive).
    ///   - endYear: End year (inclusive).
    public init(startYear: Int, endYear: Int) {
        self.startYear = startYear
        self.endYear = endYear
    }

    /// Create a range for the last N years.
    ///
    /// - Parameter count: Number of years to include.
    /// - Returns: A DateRange from (currentYear - count) to currentYear.
    public static func lastYears(_ count: Int) -> DateRange {
        let currentYear = Calendar.current.component(.year, from: Date())
        return DateRange(startYear: currentYear - count, endYear: currentYear)
    }
}

// MARK: - JSON Parsing

extension StructuredQuery {
    /// Parse a StructuredQuery from LLM JSON response.
    ///
    /// Expected JSON format:
    /// ```json
    /// {
    ///   "concepts": [
    ///     {"name": "concept1", "mesh_terms": ["Term1"], "keywords": ["kw1", "kw2"]},
    ///     {"name": "concept2", "mesh_terms": ["Term2"], "keywords": ["kw3"]}
    ///   ]
    /// }
    /// ```
    ///
    /// - Parameter json: JSON string from LLM.
    /// - Returns: Parsed StructuredQuery, or nil if parsing fails.
    public static func parse(from json: String) -> StructuredQuery? {
        let cleanJSON = extractJSON(from: json)

        guard let data = cleanJSON.data(using: .utf8) else {
            return nil
        }

        do {
            let decoded = try JSONDecoder().decode(LLMQueryResponse.self, from: data)
            return decoded.toStructuredQuery()
        } catch {
            print("[StructuredQuery] JSON parse error: \(error)")
            return nil
        }
    }

    /// Extract JSON from a string that may have markdown wrapping.
    ///
    /// Handles common LLM response patterns:
    /// - Pure JSON
    /// - JSON wrapped in ```json ... ``` code blocks
    /// - JSON with leading/trailing text
    ///
    /// - Parameter text: Text potentially containing JSON.
    /// - Returns: Extracted JSON string.
    private static func extractJSON(from text: String) -> String {
        // Try markdown code block with json tag
        if let range = text.range(of: "```json"),
           let endRange = text.range(of: "```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try plain code block
        if let range = text.range(of: "```"),
           let endRange = text.range(of: "```", range: range.upperBound..<text.endIndex) {
            return String(text[range.upperBound..<endRange.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Try to find JSON object
        if let start = text.firstIndex(of: "{"),
           let end = text.lastIndex(of: "}") {
            return String(text[start...end])
        }

        return text
    }
}

// MARK: - LLM Response Decoding (Private)

/// Internal struct for decoding LLM JSON response.
private struct LLMQueryResponse: Codable {
    let concepts: [LLMConcept]

    func toStructuredQuery() -> StructuredQuery {
        let searchConcepts = concepts.map { concept in
            SearchConcept(
                name: concept.name,
                meshTerms: concept.mesh_terms ?? [],
                keywords: concept.keywords ?? []
            )
        }
        return StructuredQuery(concepts: searchConcepts)
    }
}

/// Internal struct for decoding concept from LLM.
private struct LLMConcept: Codable {
    let name: String
    let mesh_terms: [String]?
    let keywords: [String]?
}

// MARK: - Query Builder Factory

/// Factory for building provider-specific queries from StructuredQuery.
///
/// Routes the query building to the appropriate provider-specific builder.
/// Designed to be easily extensible for additional search providers.
///
/// ## Example
/// ```swift
/// let pubmedQuery = QueryBuilderFactory.build(from: structuredQuery, for: .pubmed)
/// let europepmcQuery = QueryBuilderFactory.build(from: structuredQuery, for: .europePMC)
/// ```
public enum QueryBuilderFactory {
    /// Build a query string for the specified provider.
    ///
    /// - Parameters:
    ///   - query: The provider-agnostic structured query.
    ///   - provider: The target search provider.
    /// - Returns: Provider-specific query string.
    public static func build(from query: StructuredQuery, for provider: SearchProvider) -> String {
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

    /// Build query strings for all needed providers.
    ///
    /// When using `.both`, returns separate queries optimized for each provider.
    ///
    /// - Parameters:
    ///   - query: The structured query.
    ///   - provider: The search provider (determines which queries to build).
    /// - Returns: Dictionary mapping provider to query string.
    public static func buildAll(
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

// MARK: - PubMed Query Builder

/// Builds PubMed query strings from StructuredQuery.
///
/// Translates the provider-agnostic StructuredQuery into PubMed's
/// query syntax, including MeSH terms, field tags, and filters.
///
/// Uses an exclude-list approach for publication types rather than an include-list,
/// so that new article types are included by default.
///
/// ## Query Syntax Examples
/// - MeSH term: `"Amlodipine"[MeSH]`
/// - Title/Abstract: `amlodipine[tiab]`
/// - Publication type exclusion: `NOT "News"[pt]`
/// - Has abstract filter: `hasabstract`
/// - Date range: `2020:2024[dp]`
public enum PubMedQueryBuilder {
    /// Standard publication types to exclude for clinical queries.
    ///
    /// An exclude-list is more robust than an include-list because new
    /// article types are included by default rather than silently dropped.
    public static let defaultExcludeTypes = [
        "News", "Newspaper Article", "Editorial", "Letter", "Comment",
        "Published Erratum", "Biography", "Historical Article",
        "Personal Narrative", "Directory", "Retracted Publication"
    ]

    /// Build a PubMed query string.
    ///
    /// - Parameter query: The structured query to translate.
    /// - Returns: PubMed-formatted query string.
    public static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return QueryConstants.pubmedHasAbstractFilter
        }

        var clauses: [String] = []

        // Build concept clauses
        for concept in query.concepts where !concept.isEmpty {
            if let conceptClause = buildConceptClause(from: concept) {
                clauses.append(conceptClause)
            }
        }

        guard !clauses.isEmpty else {
            return QueryConstants.pubmedHasAbstractFilter
        }

        // Join concepts with AND
        var queryString = clauses.joined(separator: QueryConstants.andOperator)

        // Add abstract filter
        if query.requireAbstract {
            queryString += QueryConstants.andOperator + QueryConstants.pubmedHasAbstractFilter
        }

        // Add publication type exclusions
        let excludeTypes = query.excludePublicationTypes.isEmpty
            ? defaultExcludeTypes
            : query.excludePublicationTypes

        if !excludeTypes.isEmpty {
            let exclusions = excludeTypes.map { formatPublicationType($0) }
            queryString += " NOT (\(exclusions.joined(separator: QueryConstants.orOperator)))"
        }

        // Add date range
        if let dateRange = query.dateRange {
            queryString += QueryConstants.andOperator + "\(dateRange.startYear):\(dateRange.endYear)[dp]"
        }

        return queryString
    }

    /// Build a clause for a single concept.
    ///
    /// Combines MeSH terms and keywords with OR, wrapped in parentheses.
    ///
    /// - Parameter concept: The concept to build a clause for.
    /// - Returns: Parenthesized clause string, or nil if empty.
    private static func buildConceptClause(from concept: SearchConcept) -> String? {
        var terms: [String] = []

        // Add MeSH terms
        for mesh in concept.meshTerms.prefix(QueryConstants.maxMeSHTermsPerConcept) {
            terms.append("\"\(mesh)\"\(QueryConstants.pubmedMeSHFieldTag)")
        }

        // Add keywords (title/abstract search)
        // Multi-word keywords need quotes; single-word keywords don't
        for keyword in concept.keywords.prefix(QueryConstants.maxKeywordsPerConcept) {
            if keyword.contains(" ") {
                terms.append("\"\(keyword)\"\(QueryConstants.pubmedTitleAbstractFieldTag)")
            } else {
                terms.append("\(keyword)\(QueryConstants.pubmedTitleAbstractFieldTag)")
            }
        }

        guard !terms.isEmpty else {
            return nil
        }

        return "(" + terms.joined(separator: QueryConstants.orOperator) + ")"
    }

    /// Format a publication type for exclusion.
    private static func formatPublicationType(_ type: String) -> String {
        if type.contains(" ") {
            return "\"\(type)\"\(QueryConstants.pubmedPublicationTypeTag)"
        }
        return "\(type)\(QueryConstants.pubmedPublicationTypeTag)"
    }
}

// MARK: - Europe PMC Query Builder

/// Builds Europe PMC query strings from StructuredQuery.
///
/// Translates the provider-agnostic StructuredQuery into Europe PMC's
/// query syntax. Europe PMC uses a different field syntax than PubMed.
///
/// ## Note on MeSH Terms
/// Europe PMC's MeSH indexing has much lower coverage than PubMed's.
/// Using MeSH_TERM in queries drastically reduces results because most
/// articles aren't indexed with MeSH in Europe PMC. Instead, MeSH term
/// text is searched as keywords in title/abstract.
///
/// ## Note on Publication Type Exclusions
/// Europe PMC doesn't have the same volume of non-article content as PubMed,
/// so we skip publication type exclusions to avoid filtering out valid results.
///
/// ## Query Syntax Examples
/// - Title/Abstract: `TITLE_ABS:"Amlodipine"` or `TITLE_ABS:amlodipine`
/// - Has abstract filter: `HAS_ABSTRACT:y`
/// - Exclude preprints: `NOT SRC:PPR`
/// - Date range: `PUB_YEAR:[2020 TO 2024]`
public enum EuropePMCQueryBuilder {
    /// Build a Europe PMC query string.
    ///
    /// Uses keywords only (not MeSH terms) because Europe PMC's MeSH coverage
    /// is much lower than PubMed's, which would drastically reduce results.
    ///
    /// - Parameter query: The structured query to translate.
    /// - Returns: Europe PMC-formatted query string.
    public static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return QueryConstants.europePMCHasAbstractFilter
        }

        var clauses: [String] = []

        // Build concept clauses
        for concept in query.concepts where !concept.isEmpty {
            if let conceptClause = buildConceptClause(from: concept) {
                clauses.append(conceptClause)
            }
        }

        guard !clauses.isEmpty else {
            return QueryConstants.europePMCHasAbstractFilter
        }

        // Join concepts with AND
        var queryString = clauses.joined(separator: QueryConstants.andOperator)

        // Add abstract filter
        if query.requireAbstract {
            queryString += QueryConstants.andOperator + QueryConstants.europePMCHasAbstractFilter
        }

        // Exclude preprints if requested
        if query.excludePreprints {
            queryString += " NOT SRC:PPR"
        }

        // Add date range
        if let dateRange = query.dateRange {
            queryString += QueryConstants.andOperator + "PUB_YEAR:[\(dateRange.startYear) TO \(dateRange.endYear)]"
        }

        return queryString
    }

    /// Build a clause for a single concept.
    ///
    /// Uses MeSH term text as free-text keywords because Europe PMC's MeSH
    /// indexing has much lower coverage than PubMed's.
    ///
    /// - Parameter concept: The concept to build a clause for.
    /// - Returns: Parenthesized clause string, or nil if empty.
    private static func buildConceptClause(from concept: SearchConcept) -> String? {
        var terms: [String] = []

        // Add MeSH term text as keywords (search as free text)
        for mesh in concept.meshTerms.prefix(QueryConstants.maxMeSHTermsPerConcept) {
            terms.append("\(QueryConstants.europePMCTitleAbstractField)\"\(mesh)\"")
        }

        // Add keywords (search in title/abstract)
        for keyword in concept.keywords.prefix(QueryConstants.maxKeywordsPerConcept) {
            terms.append("\(QueryConstants.europePMCTitleAbstractField)\"\(keyword)\"")
        }

        guard !terms.isEmpty else {
            return nil
        }

        return "(" + terms.joined(separator: QueryConstants.orOperator) + ")"
    }
}
