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

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json

/**
 * Provider-agnostic representation of a literature search query.
 *
 * The LLM outputs this structured format, which is then translated to the native
 * query syntax of each search provider (PubMed, Europe PMC, etc.).
 *
 * Mirrors the iOS StructuredQuery for cross-platform consistency.
 */
@Serializable
data class StructuredQuery(
    /** The search concepts, combined with AND logic. */
    val concepts: List<SearchConcept>,

    /** Whether to require abstracts (filters out articles without abstracts). */
    val requireAbstract: Boolean = true,

    /** Whether to exclude preprints (Europe PMC specific). */
    val excludePreprints: Boolean = true
) {
    /** Check if the query has any searchable content. */
    val isEmpty: Boolean
        get() = concepts.isEmpty() || concepts.all { it.isEmpty }

    companion object {
        private val json = Json {
            ignoreUnknownKeys = true
            isLenient = true
            coerceInputValues = true
        }

        /**
         * Parse a StructuredQuery from LLM JSON response.
         *
         * Expected JSON format:
         * ```json
         * {
         *   "concepts": [
         *     {"name": "concept1", "mesh_terms": ["Term1"], "keywords": ["kw1", "kw2"]},
         *     {"name": "concept2", "mesh_terms": ["Term2"], "keywords": ["kw3"]}
         *   ]
         * }
         * ```
         *
         * @param jsonString JSON string from LLM
         * @return Parsed StructuredQuery, or null if parsing fails
         */
        fun parse(jsonString: String): StructuredQuery? {
            return try {
                val cleanJson = extractJSON(jsonString)
                val response = json.decodeFromString<LLMQueryResponse>(cleanJson)
                response.toStructuredQuery()
            } catch (e: Exception) {
                println("[StructuredQuery] JSON parse error: ${e.message}")
                null
            }
        }

        /**
         * Parse an array of StructuredQuery objects from LLM JSON response.
         *
         * Expected JSON format:
         * ```json
         * [
         *   {"concepts": [{"name": "...", "mesh_terms": ["..."], "keywords": ["..."]}]},
         *   {"concepts": [...]}
         * ]
         * ```
         *
         * Handles common LLM response patterns including markdown code blocks.
         *
         * @param jsonString JSON string from LLM containing an array of queries
         * @return List of parsed StructuredQuery objects, or empty list if parsing fails
         */
        fun parseArray(jsonString: String): List<StructuredQuery> {
            return try {
                val cleanJson = extractJSONArray(jsonString)
                val responses = json.decodeFromString<List<LLMQueryResponse>>(cleanJson)
                responses.map { it.toStructuredQuery() }.filter { !it.isEmpty }
            } catch (e: Exception) {
                println("[StructuredQuery] Array parse error: ${e.message}")
                emptyList()
            }
        }

        /**
         * Extract a JSON array from a string that may have markdown wrapping.
         */
        private fun extractJSONArray(text: String): String {
            var cleaned = text.trim()

            // Try markdown code block with json tag
            val jsonBlockPattern = Regex("```json\\s*([\\s\\S]*?)```")
            jsonBlockPattern.find(cleaned)?.let {
                cleaned = it.groupValues[1].trim()
            }

            // Try plain code block
            if (cleaned.contains("```")) {
                val codeBlockPattern = Regex("```\\s*([\\s\\S]*?)```")
                codeBlockPattern.find(cleaned)?.let {
                    cleaned = it.groupValues[1].trim()
                }
            }

            // Find array bounds
            val startIndex = cleaned.indexOf('[')
            val endIndex = cleaned.lastIndexOf(']')
            if (startIndex >= 0 && endIndex > startIndex) {
                return cleaned.substring(startIndex, endIndex + 1)
            }

            return cleaned
        }

        /**
         * Extract JSON from a string that may have markdown wrapping.
         */
        private fun extractJSON(text: String): String {
            var cleaned = text.trim()

            // Try markdown code block with json tag
            val jsonBlockPattern = Regex("```json\\s*([\\s\\S]*?)```")
            jsonBlockPattern.find(cleaned)?.let {
                return it.groupValues[1].trim()
            }

            // Try plain code block
            val codeBlockPattern = Regex("```\\s*([\\s\\S]*?)```")
            codeBlockPattern.find(cleaned)?.let {
                return it.groupValues[1].trim()
            }

            // Try to find JSON object
            val startIndex = cleaned.indexOf('{')
            val endIndex = cleaned.lastIndexOf('}')
            if (startIndex >= 0 && endIndex > startIndex) {
                return cleaned.substring(startIndex, endIndex + 1)
            }

            return cleaned
        }
    }
}

/**
 * A single concept in a structured query.
 *
 * Each concept represents one facet of the search (e.g., "the drug", "the condition",
 * "the outcome"). Terms within a concept are combined with OR logic.
 */
@Serializable
data class SearchConcept(
    /** Human-readable name for this concept. */
    val name: String,

    /** MeSH (Medical Subject Headings) terms for this concept. */
    @SerialName("mesh_terms")
    val meshTerms: List<String> = emptyList(),

    /** Free-text keywords to search in title and abstract. */
    val keywords: List<String> = emptyList()
) {
    /** Check if this concept has any searchable terms. */
    val isEmpty: Boolean
        get() = meshTerms.isEmpty() && keywords.isEmpty()

    /** All terms combined (for simple searches that don't support MeSH). */
    val allTerms: List<String>
        get() = meshTerms + keywords
}

/**
 * Internal response structure for LLM JSON parsing.
 */
@Serializable
private data class LLMQueryResponse(
    val concepts: List<LLMConcept>
) {
    fun toStructuredQuery(): StructuredQuery {
        val searchConcepts = concepts.map { concept ->
            SearchConcept(
                name = concept.name,
                meshTerms = concept.meshTerms ?: emptyList(),
                keywords = concept.keywords ?: emptyList()
            )
        }
        return StructuredQuery(concepts = searchConcepts)
    }
}

/**
 * Internal concept structure for LLM JSON parsing.
 */
@Serializable
private data class LLMConcept(
    val name: String,
    @SerialName("mesh_terms")
    val meshTerms: List<String>? = null,
    val keywords: List<String>? = null
)
