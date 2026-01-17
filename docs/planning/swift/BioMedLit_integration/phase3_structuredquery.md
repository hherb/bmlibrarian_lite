# Phase 3: StructuredQuery and Query Builders

## Objective

Add the provider-agnostic structured query system to iOS. This allows LLM-generated queries to be translated to either PubMed or Europe PMC syntax.

## Files to Create

- `ios/MedicalFactChecker/Sources/Models/StructuredQuery.swift` (new file)

## Overview

The structured query system consists of:
1. **StructuredQuery** - A provider-agnostic query representation
2. **SearchConcept** - Individual search concepts within a query
3. **DateRange** - Optional date filtering
4. **QueryBuilderFactory** - Routes to the appropriate builder
5. **PubMedQueryBuilder** - Converts to PubMed syntax
6. **EuropePMCQueryBuilder** - Converts to Europe PMC syntax

## File Structure

Create a single file `StructuredQuery.swift` containing all these types:

```swift
// MARK: - StructuredQuery.swift

import Foundation

// MARK: - Structured Query

/// Provider-agnostic representation of a literature search query.
///
/// The LLM outputs this structured format, which is then translated to the native
/// query syntax of each search provider (PubMed, Europe PMC, etc.).
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
struct SearchConcept: Codable, Sendable {
    /// Human-readable name for this concept.
    let name: String

    /// MeSH (Medical Subject Headings) terms for this concept.
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

    /// Create a range for the last N years.
    static func lastYears(_ count: Int) -> DateRange {
        let currentYear = Calendar.current.component(.year, from: Date())
        return DateRange(startYear: currentYear - count, endYear: currentYear)
    }
}

// MARK: - JSON Parsing Extension

extension StructuredQuery {
    /// Parse a StructuredQuery from LLM JSON response.
    static func parse(from json: String) -> StructuredQuery? {
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

// MARK: - LLM Response Decoding (Private)

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

private struct LLMConcept: Codable {
    let name: String
    let mesh_terms: [String]?
    let keywords: [String]?
}

// MARK: - Query Builder Factory

/// Factory for building provider-specific queries from StructuredQuery.
enum QueryBuilderFactory {
    /// Build a query string for the specified provider.
    static func build(from query: StructuredQuery, for provider: SearchProvider) -> String {
        switch provider {
        case .pubmed:
            return PubMedQueryBuilder.build(from: query)
        case .europePMC:
            return EuropePMCQueryBuilder.build(from: query)
        case .both:
            // Default to PubMed syntax for "both" mode
            // (Europe PMC accepts PubMed syntax with translation)
            return PubMedQueryBuilder.build(from: query)
        }
    }
}

// MARK: - PubMed Query Builder

/// Builds PubMed query strings from StructuredQuery.
enum PubMedQueryBuilder {
    /// Build a PubMed query string.
    static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return "hasabstract"
        }

        var clauses: [String] = []

        // Build concept clauses
        for concept in query.concepts where !concept.isEmpty {
            var terms: [String] = []

            // Add MeSH terms
            for mesh in concept.meshTerms.prefix(3) {
                terms.append("\"\(mesh)\"[MeSH]")
            }

            // Add keywords (title/abstract search)
            for keyword in concept.keywords.prefix(3) {
                terms.append("\(keyword)[tiab]")
            }

            if !terms.isEmpty {
                let clause = "(" + terms.joined(separator: " OR ") + ")"
                clauses.append(clause)
            }
        }

        guard !clauses.isEmpty else {
            return "hasabstract"
        }

        // Join concepts with AND
        var queryString = clauses.joined(separator: " AND ")

        // Add filters
        if query.requireAbstract {
            queryString += " AND hasabstract"
        }

        // Add publication type filter (exclude low-quality types)
        queryString += " AND (Clinical Trial[pt] OR Randomized Controlled Trial[pt] OR Meta-Analysis[pt] OR Systematic Review[pt] OR Review[pt] OR Observational Study[pt] OR Comparative Study[pt])"

        return queryString
    }
}

// MARK: - Europe PMC Query Builder

/// Builds Europe PMC query strings from StructuredQuery.
enum EuropePMCQueryBuilder {
    /// Build a Europe PMC query string.
    static func build(from query: StructuredQuery) -> String {
        guard !query.isEmpty else {
            return "HAS_ABSTRACT:y"
        }

        var clauses: [String] = []

        // Build concept clauses
        for concept in query.concepts where !concept.isEmpty {
            var terms: [String] = []

            // Europe PMC doesn't have MeSH field, use TITLE_ABS for all
            for mesh in concept.meshTerms.prefix(3) {
                terms.append("TITLE_ABS:\"\(mesh)\"")
            }

            for keyword in concept.keywords.prefix(3) {
                terms.append("TITLE_ABS:\(keyword)")
            }

            if !terms.isEmpty {
                let clause = "(" + terms.joined(separator: " OR ") + ")"
                clauses.append(clause)
            }
        }

        guard !clauses.isEmpty else {
            return "HAS_ABSTRACT:y"
        }

        // Join concepts with AND
        var queryString = clauses.joined(separator: " AND ")

        // Add filters
        if query.requireAbstract {
            queryString += " AND HAS_ABSTRACT:y"
        }

        // Exclude preprints if requested
        if query.excludePreprints {
            queryString += " AND NOT SRC:PPR"
        }

        return queryString
    }
}
```

## Usage Example

```swift
// LLM returns structured JSON
let llmResponse = """
{
  "concepts": [
    {"name": "amlodipine", "mesh_terms": ["Amlodipine"], "keywords": ["amlodipine"]},
    {"name": "arterial stiffness", "mesh_terms": ["Vascular Stiffness"], "keywords": ["arterial stiffness"]}
  ]
}
"""

// Parse the structured query
if let query = StructuredQuery.parse(from: llmResponse) {
    // Build provider-specific query strings
    let pubmedQuery = QueryBuilderFactory.build(from: query, for: .pubmed)
    let europePMCQuery = QueryBuilderFactory.build(from: query, for: .europePMC)

    print(pubmedQuery)
    // ("Amlodipine"[MeSH] OR amlodipine[tiab]) AND ("Vascular Stiffness"[MeSH] OR arterial stiffness[tiab]) AND hasabstract AND ...

    print(europePMCQuery)
    // (TITLE_ABS:"Amlodipine" OR TITLE_ABS:amlodipine) AND (TITLE_ABS:"Vascular Stiffness" OR TITLE_ABS:arterial stiffness) AND HAS_ABSTRACT:y AND NOT SRC:PPR
}
```

## Validation Steps

1. Create the new file in iOS project
2. Build - verify no compilation errors
3. Write unit tests for:
   - `StructuredQuery.parse()` with valid JSON
   - `StructuredQuery.parse()` with markdown-wrapped JSON
   - `PubMedQueryBuilder.build()` output format
   - `EuropePMCQueryBuilder.build()` output format
   - `QueryBuilderFactory.build()` routing

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Models/StructuredQuery.swift` (full file)
