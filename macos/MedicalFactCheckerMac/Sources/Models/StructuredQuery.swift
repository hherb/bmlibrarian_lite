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
/// let pubmedQuery = PubMedQueryBuilder.build(from: query)
///
/// // Translate to Europe PMC syntax
/// let europepmcQuery = EuropePMCQueryBuilder.build(from: query)
/// ```
struct StructuredQuery: Codable, Sendable {
    /// The search concepts, combined with AND logic.
    let concepts: [SearchConcept]

    /// Whether to require abstracts (filters out articles without abstracts).
    var requireAbstract: Bool = true

    /// Publication types to exclude (e.g., "News", "Editorial", "Letter").
    var excludePublicationTypes: [String] = []

    /// Whether to exclude preprints (Europe PMC specific).
    var excludePreprints: Bool = true

    /// Optional date range filter.
    var dateRange: DateRange?

    /// Initialize with concepts and default filters.
    init(
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
    var isEmpty: Bool {
        concepts.isEmpty || concepts.allSatisfy { $0.isEmpty }
    }
}

// MARK: - Search Concept

/// A single concept in a structured query.
///
/// Each concept represents one facet of the search (e.g., "the drug", "the condition",
/// "the outcome"). Terms within a concept are combined with OR logic.
struct SearchConcept: Codable, Sendable {
    /// Human-readable name for this concept.
    let name: String

    /// MeSH (Medical Subject Headings) terms for this concept.
    ///
    /// MeSH terms provide standardized vocabulary and include automatic
    /// expansion to related terms in PubMed.
    let meshTerms: [String]

    /// Free-text keywords to search in title and abstract.
    let keywords: [String]

    /// Initialize with name, MeSH terms, and keywords.
    init(name: String, meshTerms: [String] = [], keywords: [String] = []) {
        self.name = name
        self.meshTerms = meshTerms
        self.keywords = keywords
    }

    /// Check if this concept has any searchable terms.
    var isEmpty: Bool {
        meshTerms.isEmpty && keywords.isEmpty
    }

    /// All terms combined (for simple searches that don't support MeSH).
    var allTerms: [String] {
        meshTerms + keywords
    }
}

// MARK: - Date Range

/// Date range filter for searches.
struct DateRange: Codable, Sendable {
    /// Start year (inclusive).
    let startYear: Int

    /// End year (inclusive).
    let endYear: Int

    /// Initialize with start and end years.
    init(startYear: Int, endYear: Int) {
        self.startYear = startYear
        self.endYear = endYear
    }

    /// Create a range for the last N years.
    static func lastYears(_ count: Int) -> DateRange {
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
    static func parse(from json: String) -> StructuredQuery? {
        // Try to extract JSON if wrapped in markdown
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
    private static func extractJSON(from text: String) -> String {
        // Try markdown code block
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

// MARK: - LLM Response Decoding

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
