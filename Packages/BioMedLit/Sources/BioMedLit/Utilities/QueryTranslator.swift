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

/// Constants for query translation.
private enum QueryTranslatorConstants {
    /// Maximum iterations for whitespace cleanup to prevent infinite loops.
    static let maxCleanupIterations = 10
}

// MARK: - Query Translator

/// Translates queries between different literature database syntaxes.
///
/// Handles common query patterns including MeSH terms, field tags, date filters,
/// and special filters. Unrecognized patterns are passed through as-is.
public enum QueryTranslator {
    // MARK: - Public API

    /// Convert a PubMed query to Europe PMC syntax.
    ///
    /// Handles common PubMed field tags and converts them to Europe PMC equivalents.
    /// Unrecognized patterns are passed through as-is.
    ///
    /// - Parameter query: PubMed query string.
    /// - Returns: Europe PMC query string.
    public static func pubmedToEuropePMC(_ query: String) -> String {
        guard !query.isEmpty else { return query }

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
    public static func europePMCToPubMed(_ query: String) -> String {
        guard !query.isEmpty else { return query }

        var result = query

        // Apply transformations in order
        result = translateMeSHTerms(result, direction: .toPubMed)
        result = translateFieldTags(result, direction: .toPubMed)
        result = translateDateFilters(result, direction: .toPubMed)
        result = translateSpecialFilters(result, direction: .toPubMed)
        result = cleanupQuery(result)

        return result
    }

    // MARK: - Query Syntax Detection

    /// Detect if a query appears to be in PubMed syntax.
    ///
    /// Checks for common PubMed-specific patterns like field tags in brackets.
    ///
    /// - Parameter query: Query string to analyze.
    /// - Returns: True if query appears to be PubMed syntax.
    public static func isPubMedSyntax(_ query: String) -> Bool {
        let pubmedPatterns = [
            #"\[MeSH\]"#,
            #"\[mesh\]"#,
            #"\[Mesh\]"#,
            #"\[tiab\]"#,
            #"\[ti\]"#,
            #"\[ab\]"#,
            #"\[au\]"#,
            #"\[ta\]"#,
            #"\[dp\]"#,
            #"\[pt\]"#,
            #"\[la\]"#,
            #"\[sb\]"#,
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
    /// Checks for common Europe PMC-specific patterns like field prefixes.
    ///
    /// - Parameter query: Query string to analyze.
    /// - Returns: True if query appears to be Europe PMC syntax.
    public static func isEuropePMCSyntax(_ query: String) -> Bool {
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
            "LANG:",
            "PUB_TYPE:",
            "SRC:"
        ]

        let uppercasedQuery = query.uppercased()
        for pattern in europePMCPatterns {
            if uppercasedQuery.contains(pattern) {
                return true
            }
        }
        return false
    }

    // MARK: - Translation Direction

    /// Direction of query translation.
    private enum Direction {
        case toEuropePMC
        case toPubMed
    }

    // MARK: - MeSH Term Translation

    /// Translate MeSH term syntax between systems.
    ///
    /// - Parameters:
    ///   - query: The query to translate.
    ///   - direction: Translation direction.
    /// - Returns: Query with translated MeSH terms.
    private static func translateMeSHTerms(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // "Term"[MeSH] -> MeSH_TERM:"Term"
            result = applyRegex(
                to: result,
                pattern: #""([^"]+)"\s*\[(MeSH|mesh|Mesh)\]"#,
                template: "MeSH_TERM:\"$1\""
            )

        case .toPubMed:
            // MeSH_TERM:"Term" -> "Term"[MeSH]
            result = applyRegex(
                to: result,
                pattern: #"MeSH_TERM:\s*"([^"]+)""#,
                template: "\"$1\"[MeSH]",
                caseInsensitive: true
            )
        }

        return result
    }

    // MARK: - Field Tag Translation

    /// Field tag mappings between PubMed and Europe PMC.
    private static let fieldTagMappings: [(pubmed: String, europePMC: String)] = [
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

    /// Translate field tags between systems.
    ///
    /// - Parameters:
    ///   - query: The query to translate.
    ///   - direction: Translation direction.
    /// - Returns: Query with translated field tags.
    private static func translateFieldTags(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            for mapping in fieldTagMappings {
                result = translateFieldTagToEuropePMC(
                    result,
                    from: mapping.pubmed,
                    to: mapping.europePMC
                )
            }

        case .toPubMed:
            for mapping in fieldTagMappings {
                result = translateFieldTagToPubMed(
                    result,
                    from: mapping.europePMC,
                    to: mapping.pubmed
                )
            }
        }

        return result
    }

    /// Translate a PubMed field tag to Europe PMC prefix.
    private static func translateFieldTagToEuropePMC(
        _ query: String,
        from pubmedTag: String,
        to europePMCPrefix: String
    ) -> String {
        var result = query
        let escapedTag = escapeForRegex(pubmedTag)

        // Quoted term: "something"[tag]
        result = applyRegex(
            to: result,
            pattern: "\"([^\"]+)\"\\s*\(escapedTag)",
            template: "\(europePMCPrefix)\"$1\"",
            caseInsensitive: true
        )

        // Unquoted multi-word term: something something[tag]
        // Match word characters and spaces, but not operators or special chars
        // The pattern captures words (possibly with spaces) before the tag
        result = applyRegex(
            to: result,
            pattern: "([a-zA-Z][a-zA-Z0-9]*(?:\\s+[a-zA-Z][a-zA-Z0-9]*)*)\\s*\(escapedTag)",
            template: "\(europePMCPrefix)\"$1\"",
            caseInsensitive: true
        )

        return result
    }

    /// Translate a Europe PMC prefix to PubMed field tag.
    private static func translateFieldTagToPubMed(
        _ query: String,
        from europePMCPrefix: String,
        to pubmedTag: String
    ) -> String {
        var result = query
        let escapedPrefix = NSRegularExpression.escapedPattern(for: europePMCPrefix)

        // Quoted: PREFIX:"term"
        result = applyRegex(
            to: result,
            pattern: "\(escapedPrefix)\\s*\"([^\"]+)\"",
            template: "\"$1\"\(pubmedTag)",
            caseInsensitive: true
        )

        // Unquoted: PREFIX:term
        result = applyRegex(
            to: result,
            pattern: "\(escapedPrefix)\\s*(\\w+)",
            template: "$1\(pubmedTag)",
            caseInsensitive: true
        )

        return result
    }

    // MARK: - Date Filter Translation

    /// Translate date filters between systems.
    ///
    /// - Parameters:
    ///   - query: The query to translate.
    ///   - direction: Translation direction.
    /// - Returns: Query with translated date filters.
    private static func translateDateFilters(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // Date range: 2020:2024[dp] -> PUB_YEAR:[2020 TO 2024]
            result = applyRegex(
                to: result,
                pattern: #"(\d{4})\s*:\s*(\d{4})\s*\[dp\]"#,
                template: "PUB_YEAR:[$1 TO $2]",
                caseInsensitive: true
            )

            // Single year: 2020[dp] -> PUB_YEAR:2020
            result = applyRegex(
                to: result,
                pattern: #"(\d{4})\s*\[dp\]"#,
                template: "PUB_YEAR:$1",
                caseInsensitive: true
            )

        case .toPubMed:
            // PUB_YEAR:[2020 TO 2024] -> 2020:2024[dp]
            result = applyRegex(
                to: result,
                pattern: #"PUB_YEAR:\s*\[\s*(\d{4})\s+TO\s+(\d{4})\s*\]"#,
                template: "$1:$2[dp]",
                caseInsensitive: true
            )

            // PUB_YEAR:2020 -> 2020[dp]
            result = applyRegex(
                to: result,
                pattern: #"PUB_YEAR:\s*(\d{4})"#,
                template: "$1[dp]",
                caseInsensitive: true
            )
        }

        return result
    }

    // MARK: - Special Filter Translation

    /// Publication type mappings from PubMed to Europe PMC.
    private static let publicationTypeMappings: [(pubmed: String, europePMC: String)] = [
        ("\"Randomized Controlled Trial\"[pt]", "PUB_TYPE:\"randomized-controlled-trial\""),
        ("\"Systematic Review\"[pt]", "PUB_TYPE:\"systematic-review\""),
        ("\"Meta-Analysis\"[pt]", "PUB_TYPE:\"meta-analysis\""),
        ("\"Clinical Trial\"[pt]", "PUB_TYPE:\"clinical-trial\""),
        ("\"Review\"[pt]", "PUB_TYPE:\"review\""),
    ]

    /// Translate special filters between systems.
    ///
    /// - Parameters:
    ///   - query: The query to translate.
    ///   - direction: Translation direction.
    /// - Returns: Query with translated special filters.
    private static func translateSpecialFilters(_ query: String, direction: Direction) -> String {
        var result = query

        switch direction {
        case .toEuropePMC:
            // hasabstract -> HAS_ABSTRACT:Y
            result = result.replacingOccurrences(
                of: "hasabstract",
                with: "HAS_ABSTRACT:Y",
                options: .caseInsensitive
            )

            // free full text[sb] -> OPEN_ACCESS:Y
            result = result.replacingOccurrences(
                of: "free full text[sb]",
                with: "OPEN_ACCESS:Y",
                options: .caseInsensitive
            )

            // english[la] -> LANG:"eng"
            result = result.replacingOccurrences(
                of: "english[la]",
                with: "LANG:\"eng\"",
                options: .caseInsensitive
            )

            // Publication types
            for mapping in publicationTypeMappings {
                result = result.replacingOccurrences(
                    of: mapping.pubmed,
                    with: mapping.europePMC,
                    options: .caseInsensitive
                )
            }

        case .toPubMed:
            // HAS_ABSTRACT:Y -> hasabstract
            result = result.replacingOccurrences(
                of: "HAS_ABSTRACT:Y",
                with: "hasabstract",
                options: .caseInsensitive
            )

            // OPEN_ACCESS:Y -> free full text[sb]
            result = result.replacingOccurrences(
                of: "OPEN_ACCESS:Y",
                with: "free full text[sb]",
                options: .caseInsensitive
            )

            // LANG:"eng" -> english[la]
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

    /// Clean up a translated query.
    ///
    /// Removes double spaces, fixes boolean operator issues,
    /// and trims whitespace.
    ///
    /// - Parameter query: The query to clean up.
    /// - Returns: Cleaned query string.
    private static func cleanupQuery(_ query: String) -> String {
        var result = query
        var iterations = 0

        // Remove double spaces (with iteration limit)
        while result.contains("  ") && iterations < QueryTranslatorConstants.maxCleanupIterations {
            result = result.replacingOccurrences(of: "  ", with: " ")
            iterations += 1
        }

        // Trim whitespace
        result = result.trimmingCharacters(in: .whitespaces)

        // Remove empty parentheses
        result = result.replacingOccurrences(of: "()", with: "")
        result = result.replacingOccurrences(of: "( )", with: "")

        // Clean up duplicate boolean operators
        result = result.replacingOccurrences(of: "AND AND", with: "AND")
        result = result.replacingOccurrences(of: "OR OR", with: "OR")
        result = result.replacingOccurrences(of: "AND OR", with: "OR")
        result = result.replacingOccurrences(of: "OR AND", with: "AND")

        // Remove trailing boolean operators
        result = removeTrailingBooleanOperators(result)

        // Remove leading boolean operators
        result = removeLeadingBooleanOperators(result)

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Remove trailing boolean operators from a query.
    private static func removeTrailingBooleanOperators(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespaces)

        let trailingOperators = [" AND", " OR", " NOT"]
        for op in trailingOperators {
            if result.hasSuffix(op) {
                result = String(result.dropLast(op.count))
                result = result.trimmingCharacters(in: .whitespaces)
            }
        }

        return result
    }

    /// Remove leading boolean operators from a query.
    private static func removeLeadingBooleanOperators(_ query: String) -> String {
        var result = query.trimmingCharacters(in: .whitespaces)

        let leadingOperators = ["AND ", "OR "]
        for op in leadingOperators {
            if result.hasPrefix(op) {
                result = String(result.dropFirst(op.count))
                result = result.trimmingCharacters(in: .whitespaces)
            }
        }

        return result
    }

    // MARK: - Regex Helpers

    /// Apply a regex replacement to a string.
    ///
    /// - Parameters:
    ///   - string: The string to transform.
    ///   - pattern: The regex pattern.
    ///   - template: The replacement template.
    ///   - caseInsensitive: Whether to match case-insensitively.
    /// - Returns: The transformed string.
    private static func applyRegex(
        to string: String,
        pattern: String,
        template: String,
        caseInsensitive: Bool = false
    ) -> String {
        let options: NSRegularExpression.Options = caseInsensitive ? [.caseInsensitive] : []

        guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else {
            return string
        }

        return regex.stringByReplacingMatches(
            in: string,
            range: NSRange(string.startIndex..., in: string),
            withTemplate: template
        )
    }

    /// Escape a string for use in a regex pattern.
    ///
    /// - Parameter string: The string to escape.
    /// - Returns: The escaped string.
    private static func escapeForRegex(_ string: String) -> String {
        NSRegularExpression.escapedPattern(for: string)
    }
}
