/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU Affero General Public License as published by
 * the Free Software Foundation, either version 3 of the License, or
 * (at your option) any later version.
 *
 * This program is distributed in the hope that it will be useful,
 * but WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
 * GNU Affero General Public License for more details.
 *
 * You should have received a copy of the GNU Affero General Public License
 * along with this program. If not, see <https://www.gnu.org/licenses/>.
 */

package com.bmlibrarian.factchecker.domain.model

/**
 * Constants for building literature search queries.
 *
 * Mirrors the iOS QueryConstants for cross-platform consistency.
 */
object QueryConstants {
    // Term Limits
    /** Maximum number of MeSH terms per concept in a query. */
    const val MAX_MESH_TERMS_PER_CONCEPT = 3

    /** Maximum number of keywords per concept in a query. */
    const val MAX_KEYWORDS_PER_CONCEPT = 3

    // PubMed Query Syntax
    /** PubMed field tag for MeSH (Medical Subject Headings) terms. */
    const val PUBMED_MESH_FIELD_TAG = "[MeSH]"

    /** PubMed field tag for title/abstract search. */
    const val PUBMED_TITLE_ABSTRACT_FIELD_TAG = "[tiab]"

    /** PubMed filter for requiring abstracts. */
    const val PUBMED_HAS_ABSTRACT_FILTER = "hasabstract"

    /** PubMed field tag for publication type. */
    const val PUBMED_PUBLICATION_TYPE_TAG = "[pt]"

    // Europe PMC Query Syntax
    /** Europe PMC field prefix for title/abstract search. */
    const val EUROPE_PMC_TITLE_ABSTRACT_FIELD = "TITLE_ABS:"

    /** Europe PMC filter for requiring abstracts. */
    const val EUROPE_PMC_HAS_ABSTRACT_FILTER = "HAS_ABSTRACT:y"

    /** Europe PMC filter to exclude preprints. */
    const val EUROPE_PMC_EXCLUDE_PREPRINTS_FILTER = "NOT SRC:PPR"

    // Publication Types to include in PubMed queries for quality filtering
    val PUBMED_INCLUDED_PUBLICATION_TYPES = listOf(
        "Clinical Trial",
        "Randomized Controlled Trial",
        "Meta-Analysis",
        "Systematic Review",
        "Review",
        "Observational Study",
        "Comparative Study"
    )

    // Logical Operators
    /** AND operator for combining concepts. */
    const val AND_OPERATOR = " AND "

    /** OR operator for combining terms within a concept. */
    const val OR_OPERATOR = " OR "
}

/**
 * Factory for building provider-specific queries from StructuredQuery.
 *
 * Routes the query building to the appropriate provider-specific builder.
 * Designed to be easily extensible for additional search providers.
 */
object QueryBuilderFactory {
    /**
     * Build a query string for the specified provider.
     *
     * @param query The provider-agnostic structured query
     * @param provider The target search provider
     * @return Provider-specific query string
     */
    fun build(query: StructuredQuery, provider: SearchProvider): String {
        return when (provider) {
            SearchProvider.PUBMED -> PubMedQueryBuilder.build(query)
            SearchProvider.EUROPE_PMC -> EuropePMCQueryBuilder.build(query)
            SearchProvider.BOTH -> PubMedQueryBuilder.build(query) // Default to PubMed syntax
        }
    }
}

/**
 * Builds PubMed query strings from StructuredQuery.
 *
 * Translates the provider-agnostic StructuredQuery into PubMed's
 * query syntax, including MeSH terms, field tags, and filters.
 */
object PubMedQueryBuilder {
    /**
     * Build a PubMed query string.
     *
     * @param query The structured query to translate
     * @return PubMed-formatted query string
     */
    fun build(query: StructuredQuery): String {
        if (query.isEmpty) {
            return QueryConstants.PUBMED_HAS_ABSTRACT_FILTER
        }

        val clauses = mutableListOf<String>()

        // Build concept clauses
        for (concept in query.concepts.filter { !it.isEmpty }) {
            buildConceptClause(concept)?.let { clauses.add(it) }
        }

        if (clauses.isEmpty()) {
            return QueryConstants.PUBMED_HAS_ABSTRACT_FILTER
        }

        // Join concepts with AND
        var queryString = clauses.joinToString(QueryConstants.AND_OPERATOR)

        // Add abstract filter
        if (query.requireAbstract) {
            queryString += QueryConstants.AND_OPERATOR + QueryConstants.PUBMED_HAS_ABSTRACT_FILTER
        }

        // Add publication type filter (include high-quality types)
        queryString += QueryConstants.AND_OPERATOR + buildPublicationTypeFilter()

        return queryString
    }

    /**
     * Build a clause for a single concept.
     *
     * Combines MeSH terms and keywords with OR, wrapped in parentheses.
     */
    private fun buildConceptClause(concept: SearchConcept): String? {
        val terms = mutableListOf<String>()

        // Add MeSH terms (limited to prevent over-broad queries)
        for (mesh in concept.meshTerms.take(QueryConstants.MAX_MESH_TERMS_PER_CONCEPT)) {
            terms.add("\"$mesh\"${QueryConstants.PUBMED_MESH_FIELD_TAG}")
        }

        // Add keywords (title/abstract search)
        for (keyword in concept.keywords.take(QueryConstants.MAX_KEYWORDS_PER_CONCEPT)) {
            terms.add("\"$keyword\"${QueryConstants.PUBMED_TITLE_ABSTRACT_FIELD_TAG}")
        }

        if (terms.isEmpty()) {
            return null
        }

        return "(" + terms.joinToString(QueryConstants.OR_OPERATOR) + ")"
    }

    /**
     * Build the publication type filter.
     */
    private fun buildPublicationTypeFilter(): String {
        val typeTerms = QueryConstants.PUBMED_INCLUDED_PUBLICATION_TYPES.map {
            "$it${QueryConstants.PUBMED_PUBLICATION_TYPE_TAG}"
        }
        return "(" + typeTerms.joinToString(QueryConstants.OR_OPERATOR) + ")"
    }
}

/**
 * Builds Europe PMC query strings from StructuredQuery.
 *
 * Translates the provider-agnostic StructuredQuery into Europe PMC's
 * query syntax.
 */
object EuropePMCQueryBuilder {
    /**
     * Build a Europe PMC query string.
     *
     * @param query The structured query to translate
     * @return Europe PMC-formatted query string
     */
    fun build(query: StructuredQuery): String {
        if (query.isEmpty) {
            return QueryConstants.EUROPE_PMC_HAS_ABSTRACT_FILTER
        }

        val clauses = mutableListOf<String>()

        // Build concept clauses
        for (concept in query.concepts.filter { !it.isEmpty }) {
            buildConceptClause(concept)?.let { clauses.add(it) }
        }

        if (clauses.isEmpty()) {
            return QueryConstants.EUROPE_PMC_HAS_ABSTRACT_FILTER
        }

        // Join concepts with AND
        var queryString = clauses.joinToString(QueryConstants.AND_OPERATOR)

        // Add abstract filter
        if (query.requireAbstract) {
            queryString += QueryConstants.AND_OPERATOR + QueryConstants.EUROPE_PMC_HAS_ABSTRACT_FILTER
        }

        // Exclude preprints if requested
        if (query.excludePreprints) {
            queryString += QueryConstants.AND_OPERATOR + QueryConstants.EUROPE_PMC_EXCLUDE_PREPRINTS_FILTER
        }

        return queryString
    }

    /**
     * Build a clause for a single concept.
     *
     * Europe PMC doesn't have a dedicated MeSH field, so all terms
     * are searched in title/abstract.
     */
    private fun buildConceptClause(concept: SearchConcept): String? {
        val terms = mutableListOf<String>()

        // Europe PMC uses TITLE_ABS for both MeSH and keywords
        for (mesh in concept.meshTerms.take(QueryConstants.MAX_MESH_TERMS_PER_CONCEPT)) {
            terms.add("${QueryConstants.EUROPE_PMC_TITLE_ABSTRACT_FIELD}\"$mesh\"")
        }

        for (keyword in concept.keywords.take(QueryConstants.MAX_KEYWORDS_PER_CONCEPT)) {
            terms.add("${QueryConstants.EUROPE_PMC_TITLE_ABSTRACT_FIELD}\"$keyword\"")
        }

        if (terms.isEmpty()) {
            return null
        }

        return "(" + terms.joinToString(QueryConstants.OR_OPERATOR) + ")"
    }
}
