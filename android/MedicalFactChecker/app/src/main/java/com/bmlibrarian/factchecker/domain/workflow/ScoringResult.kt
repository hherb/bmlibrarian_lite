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

package com.bmlibrarian.factchecker.domain.workflow

import kotlinx.serialization.Serializable

/**
 * Result of scoring a single document.
 *
 * Lightweight class containing only essential data for updating the
 * DocumentEntity after scoring completes. Designed for safe use across
 * coroutine contexts.
 *
 * Mirrors iOS ScoringResult for cross-platform consistency.
 */
@Serializable
sealed class ScoringResult {
    /** Document ID for matching back to the source DocumentEntity. */
    abstract val documentId: String

    /** PMID for display and tracking. */
    abstract val pmid: String?

    /** Token usage for this scoring request. */
    abstract val inputTokens: Int
    abstract val outputTokens: Int
    abstract val costUsd: Double

    /**
     * Successful scoring result.
     *
     * @property documentId Document ID for matching.
     * @property pmid PubMed ID.
     * @property score Relevance score (1-5).
     * @property rationale Explanation for the score.
     * @property inputTokens Input tokens used.
     * @property outputTokens Output tokens used.
     * @property costUsd Cost in USD.
     */
    @Serializable
    data class Success(
        override val documentId: String,
        override val pmid: String?,
        val score: Int,
        val rationale: String,
        override val inputTokens: Int = 0,
        override val outputTokens: Int = 0,
        override val costUsd: Double = 0.0
    ) : ScoringResult()

    /**
     * Failed scoring result due to API/network error.
     *
     * @property documentId Document ID for matching.
     * @property pmid PubMed ID.
     * @property errorMessage Description of the error.
     * @property isRetryable Whether this error can be retried.
     * @property inputTokens Input tokens used before failure.
     * @property outputTokens Output tokens used before failure.
     * @property costUsd Cost incurred before failure.
     */
    @Serializable
    data class Failure(
        override val documentId: String,
        override val pmid: String?,
        val errorMessage: String,
        val isRetryable: Boolean = true,
        override val inputTokens: Int = 0,
        override val outputTokens: Int = 0,
        override val costUsd: Double = 0.0
    ) : ScoringResult()

    /**
     * Parse failure result (LLM responded but couldn't parse score).
     *
     * @property documentId Document ID for matching.
     * @property pmid PubMed ID.
     * @property rawResponse The unparseable response from the LLM.
     * @property parseError Description of what failed to parse.
     * @property inputTokens Input tokens used.
     * @property outputTokens Output tokens used.
     * @property costUsd Cost in USD.
     */
    @Serializable
    data class ParseFailure(
        override val documentId: String,
        override val pmid: String?,
        val rawResponse: String,
        val parseError: String,
        override val inputTokens: Int = 0,
        override val outputTokens: Int = 0,
        override val costUsd: Double = 0.0
    ) : ScoringResult()

    /** Whether scoring succeeded with a valid score. */
    val isSuccess: Boolean
        get() = this is Success

    /** Whether scoring failed due to an error. */
    val isError: Boolean
        get() = this is Failure || this is ParseFailure

    /** Get the score if successful, null otherwise. */
    val scoreOrNull: Int?
        get() = (this as? Success)?.score

    /** Get the rationale if successful, null otherwise. */
    val rationaleOrNull: String?
        get() = (this as? Success)?.rationale

    companion object {
        /**
         * Create a successful scoring result.
         */
        fun success(
            documentId: String,
            pmid: String?,
            score: Int,
            rationale: String,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0.0
        ): ScoringResult = Success(
            documentId = documentId,
            pmid = pmid,
            score = score,
            rationale = rationale,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )

        /**
         * Create a failure scoring result.
         */
        fun failure(
            documentId: String,
            pmid: String?,
            error: Throwable,
            isRetryable: Boolean = true,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0.0
        ): ScoringResult = Failure(
            documentId = documentId,
            pmid = pmid,
            errorMessage = error.message ?: "Unknown error",
            isRetryable = isRetryable,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )

        /**
         * Create a parse failure scoring result.
         */
        fun parseFailure(
            documentId: String,
            pmid: String?,
            rawResponse: String,
            parseError: String,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0.0
        ): ScoringResult = ParseFailure(
            documentId = documentId,
            pmid = pmid,
            rawResponse = rawResponse,
            parseError = parseError,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )

        /**
         * Aggregate total token usage from scoring results.
         *
         * @param results Array of scoring results.
         * @return Triple of (inputTokens, outputTokens, costUsd).
         */
        fun aggregateUsage(results: List<ScoringResult>): Triple<Int, Int, Double> {
            var totalInput = 0
            var totalOutput = 0
            var totalCost = 0.0

            for (result in results) {
                totalInput += result.inputTokens
                totalOutput += result.outputTokens
                totalCost += result.costUsd
            }

            return Triple(totalInput, totalOutput, totalCost)
        }
    }
}
