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
///
/// Designed for easy extraction into a reusable Swift package in the future.
enum QueryConstants {

    // MARK: - Term Limits

    /// Maximum number of MeSH terms per concept in a query.
    ///
    /// Limiting terms prevents queries from becoming too broad or hitting
    /// API limits. Additional terms beyond this limit are silently dropped.
    static let maxMeSHTermsPerConcept = 3

    /// Maximum number of keywords per concept in a query.
    ///
    /// Limiting keywords keeps queries focused and prevents excessive
    /// complexity in the generated query string.
    static let maxKeywordsPerConcept = 3

    // MARK: - PubMed Query Syntax

    /// PubMed field tag for MeSH (Medical Subject Headings) terms.
    static let pubmedMeSHFieldTag = "[MeSH]"

    /// PubMed field tag for title/abstract search.
    static let pubmedTitleAbstractFieldTag = "[tiab]"

    /// PubMed filter for requiring abstracts.
    static let pubmedHasAbstractFilter = "hasabstract"

    /// PubMed field tag for publication type.
    static let pubmedPublicationTypeTag = "[pt]"

    // MARK: - Europe PMC Query Syntax

    /// Europe PMC field prefix for title/abstract search.
    static let europePMCTitleAbstractField = "TITLE_ABS:"

    /// Europe PMC filter for requiring abstracts.
    static let europePMCHasAbstractFilter = "HAS_ABSTRACT:y"

    /// Europe PMC filter to exclude preprints.
    static let europePMCExcludePreprintsFilter = "NOT SRC:PPR"

    // MARK: - Publication Types

    /// Publication types to include in PubMed queries for quality filtering.
    ///
    /// These publication types represent higher-quality study designs
    /// for evidence-based medicine. Articles without these types are excluded.
    static let pubmedIncludedPublicationTypes: [String] = [
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
    static let excludedPublicationTypes: [String] = [
        "News",
        "Editorial",
        "Letter",
        "Comment",
        "Biography",
        "Interview"
    ]

    // MARK: - Logical Operators

    /// AND operator for combining concepts.
    static let andOperator = " AND "

    /// OR operator for combining terms within a concept.
    static let orOperator = " OR "

    /// NOT operator for exclusion filters.
    static let notOperator = " NOT "
}
