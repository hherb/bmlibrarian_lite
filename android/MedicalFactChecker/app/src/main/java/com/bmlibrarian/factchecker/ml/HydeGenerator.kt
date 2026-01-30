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

package com.bmlibrarian.factchecker.ml

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Generator for HyDE (Hypothetical Document Embeddings).
 *
 * HyDE improves embedding-based retrieval by converting the query (claim)
 * into a hypothetical document that would answer it. This synthetic document
 * is then used for embedding comparison instead of the raw query, bridging
 * the semantic gap between short queries and full abstracts.
 *
 * Reference: Gao et al., "Precise Zero-Shot Dense Retrieval without Relevance Labels"
 *
 * Features:
 * - Generates synthetic scientific abstracts from medical claims
 * - Validates and cleans generated content
 * - Low additional cost (one LLM call per session)
 * - Can be cached and reused for smart search alternatives
 */
@Singleton
class HydeGenerator @Inject constructor(
    private val llmService: LLMService
) {

    companion object {
        private const val TAG = "HydeGenerator"

        /** System prompt for HyDE abstract generation. */
        private val SYSTEM_PROMPT = """
            You are a scientific writing assistant specializing in biomedical research.
            Your task is to write hypothetical scientific abstracts that would address
            medical claims or questions. Write in a formal, academic style appropriate
            for peer-reviewed publications.
        """.trimIndent()
    }

    /**
     * Generate a hypothetical abstract that would address the given claim.
     *
     * The generated abstract mimics the structure of real scientific abstracts
     * and is used to improve embedding-based document retrieval.
     *
     * @param claim The medical claim to generate a hypothetical abstract for
     * @param provider The LLM provider to use
     * @param apiKey The API key for authentication
     * @param model The model ID to use
     * @return The generated abstract, or null if generation fails
     */
    suspend fun generateHypotheticalAbstract(
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String
    ): String? {
        return try {
            val prompt = buildPrompt(claim)

            val result = llmService.chat(
                provider = provider,
                apiKey = apiKey,
                model = model,
                systemPrompt = SYSTEM_PROMPT,
                userPrompt = prompt,
                maxTokens = Constants.LLM_SCORING_MAX_TOKENS,
                temperature = 0.7 // Slightly higher temperature for creative generation
            )

            if (result.isSuccess) {
                val response = result.getOrThrow().content
                validateAndClean(response)
            } else {
                Log.e(TAG, "HyDE generation failed: ${result.exceptionOrNull()?.message}")
                null
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to generate HyDE abstract: ${e.message}")
            null
        }
    }

    /**
     * Build the user prompt for HyDE abstract generation.
     *
     * @param claim The medical claim
     * @return Formatted prompt for the LLM
     */
    private fun buildPrompt(claim: String): String = """
        Given the medical claim: "$claim"

        Write a hypothetical abstract (${Constants.HYDE_TARGET_WORD_COUNT_MIN}-${Constants.HYDE_TARGET_WORD_COUNT_MAX} words) of a scientific study that would directly address this claim.

        Include typical abstract sections:
        - **Background**: Why this topic matters
        - **Methods**: Study design and participants
        - **Results**: Key findings with statistics
        - **Conclusion**: What the evidence suggests

        Use medical terminology appropriate for a peer-reviewed publication. Write as if this is a real published study abstract.

        Output ONLY the abstract text, no headings or labels.
    """.trimIndent()

    /**
     * Validate and clean the generated abstract.
     *
     * Removes section headers and validates word count.
     *
     * @param response Raw response from the LLM
     * @return Cleaned abstract, or null if validation fails
     */
    private fun validateAndClean(response: String): String? {
        // Remove common section header patterns
        val cleaned = response
            .replace(Regex("^(Background|Methods|Results|Conclusion):?\\s*", RegexOption.MULTILINE), "")
            .replace(Regex("\\*\\*[^*]+\\*\\*:?\\s*"), "") // Remove **bold** headers
            .trim()

        // Validate word count
        val wordCount = cleaned.split(Regex("\\s+")).size
        if (wordCount < Constants.HYDE_TARGET_WORD_COUNT_MIN / 2) {
            Log.w(TAG, "Generated abstract too short: $wordCount words")
            return null
        }

        return cleaned
    }
}
