package com.bmlibrarian.factchecker.domain.model

/**
 * Search provider options for literature search.
 *
 * Allows users to select which database(s) to search for evidence.
 * Each provider has different strengths:
 * - PubMed: Comprehensive biomedical literature, MeSH indexing
 * - Europe PMC: Includes preprints, open access focus, full-text XML
 *
 * Mirrors iOS SearchProvider enum for cross-platform consistency.
 *
 * @property displayName Human-readable name for UI display
 */
enum class SearchProvider(val displayName: String) {
    /** Search PubMed only (NCBI E-utilities). */
    PUBMED("PubMed"),

    /** Search Europe PMC only (includes preprints). */
    EUROPE_PMC("Europe PMC"),

    /** Search both providers and merge results. */
    BOTH("Both");

    /**
     * Check if this provider includes PubMed.
     *
     * @return true if PubMed should be searched
     */
    fun includesPubMed(): Boolean = this == PUBMED || this == BOTH

    /**
     * Check if this provider includes Europe PMC.
     *
     * @return true if Europe PMC should be searched
     */
    fun includesEuropePMC(): Boolean = this == EUROPE_PMC || this == BOTH

    companion object {
        /**
         * Parse search provider from string.
         *
         * @param value The provider string
         * @return The corresponding SearchProvider, defaults to PUBMED
         */
        fun fromString(value: String): SearchProvider {
            return when (value.lowercase().trim()) {
                "pubmed" -> PUBMED
                "europe pmc", "europepmc", "europe_pmc" -> EUROPE_PMC
                "both" -> BOTH
                else -> PUBMED
            }
        }
    }
}
