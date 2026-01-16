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
