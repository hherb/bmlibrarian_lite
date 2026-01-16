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

// MARK: - Validation Result

/// Validation result for a translated query.
struct QueryValidationResult: Sendable {
    /// Whether the translation appears valid.
    let isValid: Bool

    /// Warning messages (non-fatal issues).
    let warnings: [String]

    /// Original untranslated components (passed through).
    let untranslatedComponents: [String]

    /// Whether the query is essentially plain text (no field tags).
    let isPlainText: Bool
}

// MARK: - Query Validator

/// Validates translated queries for correctness.
///
/// Checks for common issues like unbalanced parentheses, untranslated
/// field tags, and syntax errors.
enum QueryValidator {
    // MARK: - Europe PMC Validation

    /// Validate a Europe PMC query.
    ///
    /// Checks for:
    /// - PubMed-style tags that weren't translated
    /// - Balanced parentheses
    /// - Balanced quotes
    ///
    /// - Parameter query: The Europe PMC query to validate.
    /// - Returns: Validation result with any warnings.
    static func validateEuropePMCQuery(_ query: String) -> QueryValidationResult {
        var warnings: [String] = []
        var untranslated: [String] = []

        // Check for PubMed-style tags that weren't translated
        untranslated = findPubMedTags(in: query)
        if !untranslated.isEmpty {
            warnings.append(
                "Query contains PubMed-style field tags that may not work in Europe PMC"
            )
        }

        // Check for balanced parentheses
        if !hasBalancedParentheses(query) {
            warnings.append("Unbalanced parentheses in query")
        }

        // Check for balanced quotes
        if !hasBalancedQuotes(query) {
            warnings.append("Unbalanced quotes in query")
        }

        // Check if it's essentially plain text
        let isPlainText = !query.contains(":") && !query.contains("[")

        return QueryValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            untranslatedComponents: untranslated,
            isPlainText: isPlainText
        )
    }

    // MARK: - PubMed Validation

    /// Validate a PubMed query.
    ///
    /// Checks for:
    /// - Europe PMC-style prefixes that weren't translated
    /// - Balanced parentheses
    /// - Balanced quotes
    ///
    /// - Parameter query: The PubMed query to validate.
    /// - Returns: Validation result with any warnings.
    static func validatePubMedQuery(_ query: String) -> QueryValidationResult {
        var warnings: [String] = []
        var untranslated: [String] = []

        // Check for Europe PMC-style prefixes that weren't translated
        untranslated = findEuropePMCPrefixes(in: query)
        if !untranslated.isEmpty {
            warnings.append(
                "Query contains Europe PMC-style field prefixes that may not work in PubMed"
            )
        }

        // Check for balanced parentheses
        if !hasBalancedParentheses(query) {
            warnings.append("Unbalanced parentheses in query")
        }

        // Check for balanced quotes
        if !hasBalancedQuotes(query) {
            warnings.append("Unbalanced quotes in query")
        }

        let isPlainText = !query.contains("[") && !query.contains(":")

        return QueryValidationResult(
            isValid: warnings.isEmpty,
            warnings: warnings,
            untranslatedComponents: untranslated,
            isPlainText: isPlainText
        )
    }

    // MARK: - Helper Functions

    /// Find PubMed-style field tags in a query.
    ///
    /// - Parameter query: The query to search.
    /// - Returns: Array of found PubMed tags.
    private static func findPubMedTags(in query: String) -> [String] {
        let pattern = #"\[[a-zA-Z]+\]"#
        return findMatches(pattern: pattern, in: query)
    }

    /// Find Europe PMC-style field prefixes in a query.
    ///
    /// - Parameter query: The query to search.
    /// - Returns: Array of found Europe PMC prefixes.
    private static func findEuropePMCPrefixes(in query: String) -> [String] {
        let pattern = #"[A-Z_]+:"#
        return findMatches(pattern: pattern, in: query)
    }

    /// Find all matches for a regex pattern in a string.
    ///
    /// - Parameters:
    ///   - pattern: The regex pattern.
    ///   - query: The string to search.
    /// - Returns: Array of matched strings.
    private static func findMatches(pattern: String, in query: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let matches = regex.matches(
            in: query,
            range: NSRange(query.startIndex..., in: query)
        )

        return matches.compactMap { match in
            guard let range = Range(match.range, in: query) else { return nil }
            return String(query[range])
        }
    }

    /// Check if parentheses are balanced in a query.
    ///
    /// - Parameter query: The query to check.
    /// - Returns: True if parentheses are balanced.
    private static func hasBalancedParentheses(_ query: String) -> Bool {
        let openCount = query.filter { $0 == "(" }.count
        let closeCount = query.filter { $0 == ")" }.count
        return openCount == closeCount
    }

    /// Check if quotes are balanced in a query.
    ///
    /// - Parameter query: The query to check.
    /// - Returns: True if quotes are balanced (even count).
    private static func hasBalancedQuotes(_ query: String) -> Bool {
        let quoteCount = query.filter { $0 == "\"" }.count
        return quoteCount % 2 == 0
    }
}
