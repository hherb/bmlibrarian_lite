//
//  QueryTranslator.swift
//  MedicalFactChecker
//
//  Stub implementation for query syntax translation between search providers.
//  Full implementation will be completed in Phase 4.
//

import Foundation

// MARK: - TODO: Phase 4 Implementation
//
// This file contains a stub implementation of the QueryTranslator.
// The full implementation should be completed as part of Phase 4.
//
// Phase 4 requirements (from 04-query-translator.md):
// 1. Build PubMed → Europe PMC query translator
// 2. Build Europe PMC → PubMed translator
// 3. Handle all common query patterns
// 4. Preserve search intent during translation
// 5. Create comprehensive test suite
//
// Field tag mapping to implement:
// | Concept          | PubMed Syntax       | Europe PMC Syntax      |
// |------------------|---------------------|------------------------|
// | MeSH term        | "Term"[MeSH]        | MeSH_TERM:"Term"       |
// | Title/Abstract   | term[tiab]          | TITLE_ABS:term         |
// | Title only       | term[ti]            | TITLE:term             |
// | Abstract only    | term[ab]            | ABSTRACT:term          |
// | Author           | "Name"[au]          | AUTH:"Name"            |
// | Journal          | "Journal"[ta]       | JOURNAL:"Journal"      |
// | Publication Year | 2020[dp]            | PUB_YEAR:2020          |
// | Date range       | 2020:2024[dp]       | PUB_YEAR:[2020 TO 2024]|
// | Has abstract     | hasabstract         | HAS_ABSTRACT:Y         |
// | Free full text   | free full text[sb]  | OPEN_ACCESS:Y          |
//
// Known limitations to document:
// - MeSH Explosion: PubMed auto-explodes; Europe PMC may not
// - Subheadings: PubMed MeSH subheadings (/therapy) have no equivalent
// - PMID Lookup: 12345[pmid] syntax differs between systems
// - Complex Filters: Some PubMed search builder filters have no equivalent
//

/// Utility for translating query syntax between search providers.
///
/// Different literature databases use different query syntax for searching.
/// This translator converts queries to ensure consistent search behavior
/// across providers.
///
/// - Note: This is a stub implementation. Full implementation in Phase 4.
enum QueryTranslator {
    // MARK: - PubMed to Europe PMC

    /// Translate a PubMed query to Europe PMC syntax.
    ///
    /// Currently returns the query with minimal transformation.
    /// Full implementation will handle:
    /// - MeSH term syntax conversion
    /// - Field tag translation
    /// - Date filter conversion
    /// - Special filter translation
    ///
    /// - Parameter query: PubMed query string.
    /// - Returns: Europe PMC-compatible query string.
    ///
    /// - TODO: Phase 4 - Implement full translation logic
    static func pubmedToEuropePMC(_ query: String) -> String {
        // TODO: Phase 4 - Implement comprehensive translation
        //
        // Implementation steps:
        // 1. Parse query into tokens (terms, operators, field tags)
        // 2. Translate field tags: [MeSH] -> MeSH_TERM:, [tiab] -> TITLE_ABS:, etc.
        // 3. Convert date ranges: 2020:2024[dp] -> PUB_YEAR:[2020 TO 2024]
        // 4. Handle special filters: hasabstract -> HAS_ABSTRACT:Y
        // 5. Preserve Boolean operators (AND, OR, NOT)
        // 6. Clean up whitespace and validate result

        var translated = query

        // Minimal translation: handle common PubMed-specific syntax
        // that would cause Europe PMC to fail

        // Remove PubMed-specific "hasabstract" (we add HAS_ABSTRACT:Y separately)
        translated = translated.replacingOccurrences(
            of: "\\s+AND\\s+hasabstract",
            with: "",
            options: .regularExpression
        )
        translated = translated.replacingOccurrences(
            of: "hasabstract\\s+AND\\s+",
            with: "",
            options: .regularExpression
        )
        translated = translated.replacingOccurrences(of: "hasabstract", with: "")

        // Remove PubMed publication type filters that don't translate
        translated = translated.replacingOccurrences(
            of: "NOT\\s*\\([^)]*\\[pt\\][^)]*\\)",
            with: "",
            options: .regularExpression
        )

        // Basic field tag translation (partial - expand in Phase 4)
        translated = translated.replacingOccurrences(of: "[tiab]", with: "")
        translated = translated.replacingOccurrences(of: "[ti]", with: "")
        translated = translated.replacingOccurrences(of: "[ab]", with: "")
        translated = translated.replacingOccurrences(of: "[MeSH]", with: "")
        translated = translated.replacingOccurrences(of: "[Mesh]", with: "")
        translated = translated.replacingOccurrences(of: "[mesh]", with: "")

        // Clean up extra whitespace
        translated = translated.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        translated = translated.trimmingCharacters(in: .whitespaces)

        // Remove trailing AND/OR
        translated = translated.replacingOccurrences(
            of: "\\s+(AND|OR)\\s*$",
            with: "",
            options: .regularExpression
        )

        return translated.isEmpty ? query : translated
    }

    // MARK: - Europe PMC to PubMed

    /// Translate a Europe PMC query to PubMed syntax.
    ///
    /// Currently returns the query unchanged.
    /// Full implementation will handle reverse translation.
    ///
    /// - Parameter query: Europe PMC query string.
    /// - Returns: PubMed-compatible query string.
    ///
    /// - TODO: Phase 4 - Implement full translation logic
    static func europePMCToPubMed(_ query: String) -> String {
        // TODO: Phase 4 - Implement reverse translation
        //
        // Implementation steps:
        // 1. Parse Europe PMC field prefixes (TITLE_ABS:, MeSH_TERM:, etc.)
        // 2. Convert to PubMed syntax ([tiab], [MeSH], etc.)
        // 3. Handle date ranges: PUB_YEAR:[2020 TO 2024] -> 2020:2024[dp]
        // 4. Convert special filters: HAS_ABSTRACT:Y -> hasabstract
        // 5. Preserve Boolean operators
        // 6. Validate result

        // Stub: return unchanged
        return query
    }

    // MARK: - Query Detection

    /// Detect if a query appears to be in PubMed syntax.
    ///
    /// Checks for common PubMed-specific patterns.
    ///
    /// - Parameter query: Query string to analyze.
    /// - Returns: True if query appears to be PubMed syntax.
    static func isPubMedSyntax(_ query: String) -> Bool {
        let pubmedPatterns = [
            "\\[MeSH\\]",
            "\\[mesh\\]",
            "\\[tiab\\]",
            "\\[ti\\]",
            "\\[ab\\]",
            "\\[au\\]",
            "\\[ta\\]",
            "\\[dp\\]",
            "\\[pt\\]",
            "hasabstract"
        ]

        for pattern in pubmedPatterns {
            if query.range(of: pattern, options: .regularExpression) != nil {
                return true
            }
        }
        return false
    }

    /// Detect if a query appears to be in Europe PMC syntax.
    ///
    /// Checks for common Europe PMC-specific patterns.
    ///
    /// - Parameter query: Query string to analyze.
    /// - Returns: True if query appears to be Europe PMC syntax.
    static func isEuropePMCSyntax(_ query: String) -> Bool {
        let europePMCPatterns = [
            "MeSH_TERM:",
            "TITLE_ABS:",
            "TITLE:",
            "ABSTRACT:",
            "AUTH:",
            "JOURNAL:",
            "PUB_YEAR:",
            "HAS_ABSTRACT:",
            "OPEN_ACCESS:",
            "SRC:"
        ]

        for pattern in europePMCPatterns {
            if query.contains(pattern) {
                return true
            }
        }
        return false
    }
}

// MARK: - Query Validator Stub

/// Utility for validating translated queries.
///
/// - Note: This is a stub. Full implementation in Phase 4.
///
/// - TODO: Phase 4 - Implement QueryValidator as a separate file
enum QueryValidator {
    /// Validation result for a query.
    struct ValidationResult {
        /// Whether the query is valid.
        let isValid: Bool

        /// Warning messages for potential issues.
        let warnings: [String]

        /// Error messages for invalid syntax.
        let errors: [String]
    }

    /// Validate a Europe PMC query.
    ///
    /// - Parameter query: Query to validate.
    /// - Returns: Validation result.
    ///
    /// - TODO: Phase 4 - Implement comprehensive validation
    static func validateEuropePMCQuery(_ query: String) -> ValidationResult {
        var warnings: [String] = []
        var errors: [String] = []

        // Check for balanced parentheses
        let openCount = query.filter { $0 == "(" }.count
        let closeCount = query.filter { $0 == ")" }.count
        if openCount != closeCount {
            errors.append("Unbalanced parentheses: \(openCount) open, \(closeCount) close")
        }

        // Check for balanced quotes
        let quoteCount = query.filter { $0 == "\"" }.count
        if quoteCount % 2 != 0 {
            errors.append("Unbalanced quotes")
        }

        // Warn about untranslated PubMed syntax
        if QueryTranslator.isPubMedSyntax(query) {
            warnings.append("Query may contain untranslated PubMed syntax")
        }

        return ValidationResult(
            isValid: errors.isEmpty,
            warnings: warnings,
            errors: errors
        )
    }

    /// Validate a PubMed query.
    ///
    /// - Parameter query: Query to validate.
    /// - Returns: Validation result.
    ///
    /// - TODO: Phase 4 - Implement comprehensive validation
    static func validatePubMedQuery(_ query: String) -> ValidationResult {
        var warnings: [String] = []
        var errors: [String] = []

        // Check for balanced parentheses
        let openCount = query.filter { $0 == "(" }.count
        let closeCount = query.filter { $0 == ")" }.count
        if openCount != closeCount {
            errors.append("Unbalanced parentheses")
        }

        // Warn about Europe PMC syntax
        if QueryTranslator.isEuropePMCSyntax(query) {
            warnings.append("Query may contain Europe PMC syntax")
        }

        return ValidationResult(
            isValid: errors.isEmpty,
            warnings: warnings,
            errors: errors
        )
    }
}
