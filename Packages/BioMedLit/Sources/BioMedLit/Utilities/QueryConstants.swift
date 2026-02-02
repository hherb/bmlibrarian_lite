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

// MARK: - Query Building Constants

/// Constants for building literature search queries.
///
/// These constants control how structured queries are translated into
/// provider-specific query syntax (PubMed, Europe PMC, etc.).
public enum QueryConstants {

    // MARK: - Term Limits

    /// Maximum number of MeSH terms per concept in a query.
    ///
    /// Limiting terms prevents queries from becoming too broad or hitting
    /// API limits. Additional terms beyond this limit are silently dropped.
    public static let maxMeSHTermsPerConcept = 3

    /// Maximum number of keywords per concept in a query.
    ///
    /// Limiting keywords keeps queries focused and prevents excessive
    /// complexity in the generated query string.
    public static let maxKeywordsPerConcept = 3

    // MARK: - PubMed Query Syntax

    /// PubMed field tag for MeSH (Medical Subject Headings) terms.
    public static let pubmedMeSHFieldTag = "[MeSH]"

    /// PubMed field tag for title/abstract search.
    public static let pubmedTitleAbstractFieldTag = "[tiab]"

    /// PubMed filter for requiring abstracts.
    public static let pubmedHasAbstractFilter = "hasabstract"

    /// PubMed field tag for publication type.
    public static let pubmedPublicationTypeTag = "[pt]"

    // MARK: - Europe PMC Query Syntax

    /// Europe PMC field prefix for title/abstract search.
    public static let europePMCTitleAbstractField = "TITLE_ABS:"

    /// Europe PMC filter for requiring abstracts.
    public static let europePMCHasAbstractFilter = "HAS_ABSTRACT:y"

    /// Europe PMC filter to exclude preprints.
    public static let europePMCExcludePreprintsFilter = "NOT SRC:PPR"

    // MARK: - Publication Types

    /// Publication types to include in PubMed queries for quality filtering.
    ///
    /// These publication types represent higher-quality study designs
    /// for evidence-based medicine. Articles without these types are excluded.
    public static let pubmedIncludedPublicationTypes: [String] = [
        "Clinical Trial",
        "Randomized Controlled Trial",
        "Meta-Analysis",
        "Systematic Review",
        "Review",
        "Observational Study",
        "Comparative Study"
    ]

    /// Publication types to exclude from searches (low-quality for evidence).
    ///
    /// These types are typically not useful for fact-checking medical claims.
    public static let excludedPublicationTypes: [String] = [
        "News",
        "Editorial",
        "Letter",
        "Comment",
        "Biography",
        "Interview"
    ]

    // MARK: - Logical Operators

    /// AND operator for combining concepts.
    public static let andOperator = " AND "

    /// OR operator for combining terms within a concept.
    public static let orOperator = " OR "

    /// NOT operator for exclusion filters.
    public static let notOperator = " NOT "
}
