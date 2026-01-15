# Phase 4: Query Syntax Translator

This document details the implementation of the query syntax translator that converts between PubMed and Europe PMC query formats.

---

## Goals

1. Build PubMed → Europe PMC query translator
2. Build Europe PMC → PubMed translator (for reverse compatibility)
3. Handle all common query patterns
4. Preserve search intent during translation
5. Create comprehensive test suite

---

## 1. Query Syntax Comparison

### Field Tag Mapping

| Concept | PubMed Syntax | Europe PMC Syntax |
|---------|---------------|-------------------|
| MeSH term | `"Term"[MeSH]` | `MeSH_TERM:"Term"` |
| Title/Abstract | `term[tiab]` | `TITLE_ABS:term` |
| Title only | `term[ti]` | `TITLE:term` |
| Abstract only | `term[ab]` | `ABSTRACT:term` |
| Author | `"Name"[au]` | `AUTH:"Name"` |
| Journal | `"Journal"[ta]` | `JOURNAL:"Journal"` |
| Publication Year | `2020[dp]` | `PUB_YEAR:2020` |
| Date range | `2020:2024[dp]` | `PUB_YEAR:[2020 TO 2024]` |
| Has abstract | `hasabstract` | `HAS_ABSTRACT:Y` |
| Free full text | `free full text[sb]` | `OPEN_ACCESS:Y` |
| Publication type | `"Review"[pt]` | `PUB_TYPE:"review"` |

### Boolean Operators

| Operator | PubMed | Europe PMC |
|----------|--------|------------|
| AND | `AND` | `AND` |
| OR | `OR` | `OR` |
| NOT | `NOT` | `NOT` |

Boolean operators work the same in both systems.

### Special Filters

| Filter | PubMed | Europe PMC |
|--------|--------|------------|
| Humans only | `"Humans"[MeSH]` | `MeSH_TERM:"Humans"` |
| English only | `english[la]` | `LANG:"eng"` |
| Clinical trial | `"Clinical Trial"[pt]` | `PUB_TYPE:"clinical-trial"` |
| Systematic review | `"Systematic Review"[pt]` | `PUB_TYPE:"systematic-review"` |
| Preprints | N/A | `SRC:PPR` |
| Exclude preprints | N/A | `NOT SRC:PPR` |

---

## 2. Query Translator Implementation

### File: `Sources/Utilities/QueryTranslator.swift` (new file)

```swift
//
//  QueryTranslator.swift
//  MedicalFactChecker
//
//  Translates queries between PubMed and Europe PMC syntax.
//

import Foundation

/// Translates queries between different literature database syntaxes.
enum QueryTranslator {

    // MARK: - PubMed to Europe PMC

    /// Convert a PubMed query to Europe PMC syntax.
    ///
    /// Handles common PubMed field tags and converts them to Europe PMC equivalents.
    /// Unrecognized patterns are passed through as-is.
    ///
    /// - Parameter query: PubMed query string.
    /// - Returns: Europe PMC query string.
    static func pubmedToEuropePMC(_ query: String) -> String {
        var result = query

        // Apply transformations in order
        result = translateMeSHTerms(result, direction: .toEuropePMC)
        result = translateFieldTags(result, direction: .toEuropePMC)
        result = translateDateFilters(result, direction: .toEuropePMC)
        result = translateSpecialFilters(result, direction: .toEuropePMC)
        result = cleanupQuery(result)

        return result
    }

    /// Convert a Europe PMC query to PubMed syntax.
    ///
    /// - Parameter query: Europe PMC query string.
    /// - Returns: PubMed query string.
    static func europePMCToPubMed(_ query: String) -> String {
        var result = query

        // Apply transformations in order
        result = translateMeSHTerms(result, direction: .toPubMed)
        result = translateFieldTags(result, direction: .toPubMed)
        result = translateDateFilters(result, direction: .toPubMed)
        result = translateSpecialFilters(result, direction: .toPubMed)
        result = cleanupQuery(result)

        return result
    }

    // MARK: - Translation Direction

    private enum Direction {
        case toEuropePMC
        case toPubMed
    }

    // MARK: - MeSH Term Translation

    private static func translateMeSHTerms(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // "Term"[MeSH] → MeSH_TERM:"Term"
            // Pattern: "anything"[MeSH] or "anything"[mesh]
            let meshPattern = #""([^"]+)"\s*\[(MeSH|mesh|Mesh)\]"#
            if let regex = try? NSRegularExpression(pattern: meshPattern, options: []) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "MeSH_TERM:\"$1\""
                )
            }

        case .toPubMed:
            // MeSH_TERM:"Term" → "Term"[MeSH]
            let meshPattern = #"MeSH_TERM:\s*"([^"]+)""#
            if let regex = try? NSRegularExpression(pattern: meshPattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "\"$1\"[MeSH]"
                )
            }
        }

        return result
    }

    // MARK: - Field Tag Translation

    private static func translateFieldTags(_ query: String, direction: Direction) -> String {
        var result = query

        // Field tag mappings
        let mappings: [(pubmed: String, europePMC: String)] = [
            // Title/Abstract
            ("[tiab]", "TITLE_ABS:"),
            ("[ti]", "TITLE:"),
            ("[ab]", "ABSTRACT:"),

            // Author
            ("[au]", "AUTH:"),
            ("[Author]", "AUTH:"),

            // Journal
            ("[ta]", "JOURNAL:"),
            ("[Journal]", "JOURNAL:"),

            // Publication type
            ("[pt]", "PUB_TYPE:"),
            ("[Publication Type]", "PUB_TYPE:"),
        ]

        switch direction {
        case .toEuropePMC:
            for mapping in mappings {
                // Handle both quoted and unquoted terms
                // term[tiab] → TITLE_ABS:term
                // "term with spaces"[tiab] → TITLE_ABS:"term with spaces"
                result = translateFieldTagToEuropePMC(result, from: mapping.pubmed, to: mapping.europePMC)
            }

        case .toPubMed:
            for mapping in mappings {
                // TITLE_ABS:term → term[tiab]
                // TITLE_ABS:"term" → "term"[tiab]
                result = translateFieldTagToPubMed(result, from: mapping.europePMC, to: mapping.pubmed)
            }
        }

        return result
    }

    private static func translateFieldTagToEuropePMC(_ query: String, from pubmedTag: String, to europePMCPrefix: String) -> String {
        var result = query

        // Quoted term: "something"[tag]
        let quotedPattern = "\"([^\"]+)\"\\s*\\\(pubmedTag.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))"
        if let regex = try? NSRegularExpression(pattern: quotedPattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\(europePMCPrefix)\"$1\""
            )
        }

        // Unquoted term: something[tag]
        let unquotedPattern = "(\\w+)\\s*\\\(pubmedTag.replacingOccurrences(of: "[", with: "\\[").replacingOccurrences(of: "]", with: "\\]"))"
        if let regex = try? NSRegularExpression(pattern: unquotedPattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\(europePMCPrefix)$1"
            )
        }

        return result
    }

    private static func translateFieldTagToPubMed(_ query: String, from europePMCPrefix: String, to pubmedTag: String) -> String {
        var result = query
        let escapedPrefix = NSRegularExpression.escapedPattern(for: europePMCPrefix)

        // Quoted: PREFIX:"term"
        let quotedPattern = "\(escapedPrefix)\\s*\"([^\"]+)\""
        if let regex = try? NSRegularExpression(pattern: quotedPattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "\"$1\"\(pubmedTag)"
            )
        }

        // Unquoted: PREFIX:term
        let unquotedPattern = "\(escapedPrefix)\\s*(\\w+)"
        if let regex = try? NSRegularExpression(pattern: unquotedPattern, options: [.caseInsensitive]) {
            result = regex.stringByReplacingMatches(
                in: result,
                range: NSRange(result.startIndex..., in: result),
                withTemplate: "$1\(pubmedTag)"
            )
        }

        return result
    }

    // MARK: - Date Filter Translation

    private static func translateDateFilters(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // Single year: 2020[dp] → PUB_YEAR:2020
            let singleYearPattern = #"(\d{4})\s*\[dp\]"#
            if let regex = try? NSRegularExpression(pattern: singleYearPattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "PUB_YEAR:$1"
                )
            }

            // Date range: 2020:2024[dp] → PUB_YEAR:[2020 TO 2024]
            let rangePattern = #"(\d{4})\s*:\s*(\d{4})\s*\[dp\]"#
            if let regex = try? NSRegularExpression(pattern: rangePattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "PUB_YEAR:[$1 TO $2]"
                )
            }

        case .toPubMed:
            // PUB_YEAR:2020 → 2020[dp]
            let singleYearPattern = #"PUB_YEAR:\s*(\d{4})"#
            if let regex = try? NSRegularExpression(pattern: singleYearPattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1[dp]"
                )
            }

            // PUB_YEAR:[2020 TO 2024] → 2020:2024[dp]
            let rangePattern = #"PUB_YEAR:\s*\[\s*(\d{4})\s+TO\s+(\d{4})\s*\]"#
            if let regex = try? NSRegularExpression(pattern: rangePattern, options: [.caseInsensitive]) {
                result = regex.stringByReplacingMatches(
                    in: result,
                    range: NSRange(result.startIndex..., in: result),
                    withTemplate: "$1:$2[dp]"
                )
            }
        }

        return result
    }

    // MARK: - Special Filter Translation

    private static func translateSpecialFilters(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // hasabstract → HAS_ABSTRACT:Y
            result = result.replacingOccurrences(
                of: "hasabstract",
                with: "HAS_ABSTRACT:Y",
                options: .caseInsensitive
            )

            // free full text[sb] → OPEN_ACCESS:Y
            result = result.replacingOccurrences(
                of: "free full text[sb]",
                with: "OPEN_ACCESS:Y",
                options: .caseInsensitive
            )

            // Language: english[la] → LANG:"eng"
            result = result.replacingOccurrences(
                of: "english[la]",
                with: "LANG:\"eng\"",
                options: .caseInsensitive
            )

            // Publication types
            let pubTypeMap = [
                "\"Randomized Controlled Trial\"[pt]": "PUB_TYPE:\"randomized-controlled-trial\"",
                "\"Systematic Review\"[pt]": "PUB_TYPE:\"systematic-review\"",
                "\"Meta-Analysis\"[pt]": "PUB_TYPE:\"meta-analysis\"",
                "\"Clinical Trial\"[pt]": "PUB_TYPE:\"clinical-trial\"",
                "\"Review\"[pt]": "PUB_TYPE:\"review\"",
            ]
            for (pubmed, epmc) in pubTypeMap {
                result = result.replacingOccurrences(of: pubmed, with: epmc, options: .caseInsensitive)
            }

        case .toPubMed:
            // HAS_ABSTRACT:Y → hasabstract
            result = result.replacingOccurrences(
                of: "HAS_ABSTRACT:Y",
                with: "hasabstract",
                options: .caseInsensitive
            )

            // OPEN_ACCESS:Y → free full text[sb]
            result = result.replacingOccurrences(
                of: "OPEN_ACCESS:Y",
                with: "free full text[sb]",
                options: .caseInsensitive
            )

            // LANG:"eng" → english[la]
            result = result.replacingOccurrences(
                of: "LANG:\"eng\"",
                with: "english[la]",
                options: .caseInsensitive
            )

            // Remove Europe PMC-specific filters (no PubMed equivalent)
            result = result.replacingOccurrences(
                of: "NOT SRC:PPR",
                with: "",
                options: .caseInsensitive
            )
            result = result.replacingOccurrences(
                of: "SRC:PPR",
                with: "",
                options: .caseInsensitive
            )
        }

        return result
    }

    // MARK: - Cleanup

    private static func cleanupQuery(_ query: String) -> String {
        var result = query

        // Remove double spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        // Remove leading/trailing whitespace
        result = result.trimmingCharacters(in: .whitespaces)

        // Remove empty parentheses
        result = result.replacingOccurrences(of: "()", with: "")
        result = result.replacingOccurrences(of: "( )", with: "")

        // Clean up boolean operators with no operands
        result = result.replacingOccurrences(of: "AND AND", with: "AND")
        result = result.replacingOccurrences(of: "OR OR", with: "OR")
        result = result.replacingOccurrences(of: "AND OR", with: "OR")
        result = result.replacingOccurrences(of: "OR AND", with: "AND")

        // Remove trailing boolean operators
        if result.hasSuffix(" AND") {
            result = String(result.dropLast(4))
        }
        if result.hasSuffix(" OR") {
            result = String(result.dropLast(3))
        }
        if result.hasSuffix(" NOT") {
            result = String(result.dropLast(4))
        }

        // Remove leading boolean operators
        if result.hasPrefix("AND ") {
            result = String(result.dropFirst(4))
        }
        if result.hasPrefix("OR ") {
            result = String(result.dropFirst(3))
        }

        return result.trimmingCharacters(in: .whitespaces)
    }
}
```

---

## 3. Query Validation

### File: `Sources/Utilities/QueryValidator.swift` (new file)

```swift
//
//  QueryValidator.swift
//  MedicalFactChecker
//
//  Validates and analyzes translated queries.
//

import Foundation

/// Validation result for a translated query.
struct QueryValidationResult {
    /// Whether the translation appears valid.
    let isValid: Bool

    /// Warning messages (non-fatal issues).
    let warnings: [String]

    /// Original untranslated components (passed through).
    let untranslatedComponents: [String]

    /// Whether the query is essentially plain text (no field tags).
    let isPlainText: Bool
}

/// Validates translated queries for correctness.
enum QueryValidator {
    /// Validate a Europe PMC query.
    static func validateEuropePMCQuery(_ query: String) -> QueryValidationResult {
        var warnings: [String] = []
        var untranslated: [String] = []

        // Check for PubMed-style tags that weren't translated
        let pubmedTagPattern = #"\[[a-zA-Z]+\]"#
        if let regex = try? NSRegularExpression(pattern: pubmedTagPattern),
           regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil {
            warnings.append("Query contains PubMed-style field tags that may not work in Europe PMC")

            // Extract the untranslated tags
            let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
            for match in matches {
                if let range = Range(match.range, in: query) {
                    untranslated.append(String(query[range]))
                }
            }
        }

        // Check for balanced parentheses
        let openCount = query.filter { $0 == "(" }.count
        let closeCount = query.filter { $0 == ")" }.count
        if openCount != closeCount {
            warnings.append("Unbalanced parentheses in query")
        }

        // Check for balanced quotes
        let quoteCount = query.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            warnings.append("Unbalanced quotes in query")
        }

        // Check if it's essentially plain text
        let hasFieldTags = query.contains(":") || query.contains("[")
        let isPlainText = !hasFieldTags

        return QueryValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            untranslatedComponents: untranslated,
            isPlainText: isPlainText
        )
    }

    /// Validate a PubMed query.
    static func validatePubMedQuery(_ query: String) -> QueryValidationResult {
        var warnings: [String] = []
        var untranslated: [String] = []

        // Check for Europe PMC-style prefixes that weren't translated
        let epmcPrefixPattern = #"[A-Z_]+:"#
        if let regex = try? NSRegularExpression(pattern: epmcPrefixPattern),
           regex.firstMatch(in: query, range: NSRange(query.startIndex..., in: query)) != nil {
            warnings.append("Query contains Europe PMC-style field prefixes that may not work in PubMed")

            let matches = regex.matches(in: query, range: NSRange(query.startIndex..., in: query))
            for match in matches {
                if let range = Range(match.range, in: query) {
                    untranslated.append(String(query[range]))
                }
            }
        }

        // Check for balanced parentheses
        let openCount = query.filter { $0 == "(" }.count
        let closeCount = query.filter { $0 == ")" }.count
        if openCount != closeCount {
            warnings.append("Unbalanced parentheses in query")
        }

        // Check for balanced quotes
        let quoteCount = query.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            warnings.append("Unbalanced quotes in query")
        }

        let hasFieldTags = query.contains("[") || query.contains(":")
        let isPlainText = !hasFieldTags

        return QueryValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            untranslatedComponents: untranslated,
            isPlainText: isPlainText
        )
    }
}
```

---

## 4. Test Cases

### File: `Tests/QueryTranslatorTests.swift` (new file)

```swift
//
//  QueryTranslatorTests.swift
//  MedicalFactCheckerTests
//
//  Tests for QueryTranslator.
//

import XCTest
@testable import MedicalFactChecker

final class QueryTranslatorTests: XCTestCase {

    // MARK: - PubMed to Europe PMC

    func testMeSHTermTranslation() {
        let pubmed = #""Diabetes Mellitus"[MeSH]"#
        let expected = #"MeSH_TERM:"Diabetes Mellitus""#
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testTitleAbstractTranslation() {
        let pubmed = "metformin[tiab]"
        let expected = "TITLE_ABS:metformin"
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testQuotedTitleAbstractTranslation() {
        let pubmed = #""insulin resistance"[tiab]"#
        let expected = #"TITLE_ABS:"insulin resistance""#
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testDateRangeTranslation() {
        let pubmed = "2020:2024[dp]"
        let expected = "PUB_YEAR:[2020 TO 2024]"
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testSingleYearTranslation() {
        let pubmed = "2023[dp]"
        let expected = "PUB_YEAR:2023"
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testHasAbstractTranslation() {
        let pubmed = "diabetes AND hasabstract"
        let expected = "diabetes AND HAS_ABSTRACT:Y"
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    func testComplexQueryTranslation() {
        let pubmed = #"("Amlodipine"[MeSH] OR amlodipine[tiab]) AND ("Vascular Stiffness"[MeSH] OR "arterial stiffness"[tiab]) AND hasabstract"#
        let result = QueryTranslator.pubmedToEuropePMC(pubmed)

        XCTAssertTrue(result.contains("MeSH_TERM:\"Amlodipine\""))
        XCTAssertTrue(result.contains("TITLE_ABS:amlodipine"))
        XCTAssertTrue(result.contains("MeSH_TERM:\"Vascular Stiffness\""))
        XCTAssertTrue(result.contains("TITLE_ABS:\"arterial stiffness\""))
        XCTAssertTrue(result.contains("HAS_ABSTRACT:Y"))
    }

    func testPublicationTypeTranslation() {
        let pubmed = #""Systematic Review"[pt]"#
        let expected = #"PUB_TYPE:"systematic-review""#
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(pubmed), expected)
    }

    // MARK: - Europe PMC to PubMed

    func testReverseMeSHTermTranslation() {
        let epmc = #"MeSH_TERM:"Diabetes Mellitus""#
        let expected = #""Diabetes Mellitus"[MeSH]"#
        XCTAssertEqual(QueryTranslator.europePMCToPubMed(epmc), expected)
    }

    func testReverseTitleAbstractTranslation() {
        let epmc = "TITLE_ABS:metformin"
        let expected = "metformin[tiab]"
        XCTAssertEqual(QueryTranslator.europePMCToPubMed(epmc), expected)
    }

    func testReverseDateRangeTranslation() {
        let epmc = "PUB_YEAR:[2020 TO 2024]"
        let expected = "2020:2024[dp]"
        XCTAssertEqual(QueryTranslator.europePMCToPubMed(epmc), expected)
    }

    func testPreprintFilterRemoval() {
        let epmc = "diabetes AND NOT SRC:PPR"
        let result = QueryTranslator.europePMCToPubMed(epmc)
        XCTAssertFalse(result.contains("SRC:PPR"))
        XCTAssertTrue(result.contains("diabetes"))
    }

    // MARK: - Round-Trip Tests

    func testRoundTripMeSH() {
        let original = #""Diabetes Mellitus"[MeSH]"#
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        XCTAssertEqual(roundTrip, original)
    }

    func testRoundTripTitleAbstract() {
        let original = "metformin[tiab]"
        let epmc = QueryTranslator.pubmedToEuropePMC(original)
        let roundTrip = QueryTranslator.europePMCToPubMed(epmc)
        XCTAssertEqual(roundTrip, original)
    }

    // MARK: - Edge Cases

    func testPlainTextPassthrough() {
        let plainText = "diabetes treatment outcomes"
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(plainText), plainText)
        XCTAssertEqual(QueryTranslator.europePMCToPubMed(plainText), plainText)
    }

    func testEmptyQueryHandling() {
        XCTAssertEqual(QueryTranslator.pubmedToEuropePMC(""), "")
        XCTAssertEqual(QueryTranslator.europePMCToPubMed(""), "")
    }

    func testWhitespaceCleanup() {
        let messy = "diabetes  AND   metformin"
        let result = QueryTranslator.pubmedToEuropePMC(messy)
        XCTAssertFalse(result.contains("  "))
    }

    func testTrailingBooleanRemoval() {
        let trailing = "diabetes AND metformin AND"
        let result = QueryTranslator.pubmedToEuropePMC(trailing)
        XCTAssertFalse(result.hasSuffix("AND"))
    }

    // MARK: - Validation Tests

    func testValidQueryValidation() {
        let query = #"MeSH_TERM:"Diabetes" AND TITLE_ABS:metformin"#
        let result = QueryValidator.validateEuropePMCQuery(query)
        XCTAssertTrue(result.isValid)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testUnbalancedParenthesesDetection() {
        let query = "(diabetes AND metformin"
        let result = QueryValidator.validateEuropePMCQuery(query)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.warnings.contains { $0.contains("parentheses") })
    }

    func testUntranslatedTagDetection() {
        let query = "diabetes[tiab] AND MeSH_TERM:\"Cancer\""
        let result = QueryValidator.validateEuropePMCQuery(query)
        XCTAssertFalse(result.isValid)
        XCTAssertTrue(result.untranslatedComponents.contains("[tiab]"))
    }
}
```

---

## 5. Integration Example

### Usage in SearchServiceFactory

```swift
// In SearchServiceFactory.searchEuropePMC():
private static func searchEuropePMC(
    query: String,
    options: SearchOptions
) async throws -> UnifiedSearchResult {
    let service = EuropePMCService.create()

    // Translate query from PubMed syntax if needed
    let translatedQuery = QueryTranslator.pubmedToEuropePMC(query)

    // Validate translation
    let validation = QueryValidator.validateEuropePMCQuery(translatedQuery)
    if !validation.warnings.isEmpty {
        print("[Search] Query translation warnings: \(validation.warnings)")
    }

    let result = try await service.search(
        query: translatedQuery,
        maxResults: options.maxResults,
        offset: options.offset,
        includePreprints: options.includePreprints
    )

    // ... rest of method
}
```

---

## 6. Testing Checklist

### Unit Tests

- [ ] MeSH term translation (both directions)
- [ ] Title/Abstract field translation
- [ ] Author field translation
- [ ] Journal field translation
- [ ] Date range translation
- [ ] Single year translation
- [ ] hasabstract filter translation
- [ ] Publication type translation
- [ ] Complex query with multiple elements
- [ ] Round-trip translation preserves intent
- [ ] Plain text passthrough
- [ ] Empty query handling
- [ ] Whitespace cleanup
- [ ] Boolean operator cleanup
- [ ] Validation detects unbalanced parentheses
- [ ] Validation detects untranslated tags

### Manual Testing

- [ ] Translate actual LLM-generated PubMed queries
- [ ] Verify Europe PMC returns relevant results
- [ ] Compare result counts between direct and translated queries
- [ ] Test edge cases from real user queries

---

## 7. Files to Create

### New Files
- `Sources/Utilities/QueryTranslator.swift`
- `Sources/Utilities/QueryValidator.swift`
- `Tests/QueryTranslatorTests.swift`

---

## 8. Known Limitations

1. **MeSH Explosion**: PubMed automatically explodes MeSH terms; Europe PMC may not
2. **Subheadings**: PubMed MeSH subheadings (`/therapy`) have no Europe PMC equivalent
3. **PMID Lookup**: `12345[pmid]` syntax differs between systems
4. **Complex Filters**: Some PubMed search builder filters have no equivalent

### Mitigation Strategies

- For MeSH explosion: Consider adding related terms manually
- For unsupported features: Log warning and pass through as plain text
- For critical differences: Document in user-facing help text

---

## 9. Estimated Effort

| Task | Complexity | Notes |
|------|------------|-------|
| QueryTranslator core | Medium | Regex-based translation |
| Field tag mapping | Low | Straightforward replacements |
| Date filter translation | Low | Simple pattern matching |
| Special filter translation | Low | String replacements |
| QueryValidator | Low | Basic checks |
| Test suite | Medium | Comprehensive coverage |

**Total estimated complexity: Medium**

---

## Next Phase

After completing this phase, proceed to **Phase 5: Hybrid Search UI** (`05-hybrid-search-ui.md`) to implement the user interface for search provider selection and result display.
