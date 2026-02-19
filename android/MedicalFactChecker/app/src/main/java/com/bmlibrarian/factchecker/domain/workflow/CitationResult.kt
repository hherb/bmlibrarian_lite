/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

import com.bmlibrarian.factchecker.data.remote.llm.LLMService

/**
 * Result of extracting citations from a single document.
 *
 * Lightweight class containing only essential data for updating the
 * DocumentEntity after extraction completes. Designed for safe use across
 * coroutine contexts.
 *
 * Mirrors iOS CitationResult for cross-platform consistency.
 */
sealed class CitationResult {
    /** Document ID for matching back to the source DocumentEntity. */
    abstract val documentId: String

    /** PMID for display and tracking. */
    abstract val pmid: String?

    /** Token usage for this extraction request. */
    abstract val inputTokens: Int
    abstract val outputTokens: Int
    abstract val costUsd: Double

    /**
     * Successful citation extraction result.
     *
     * @property documentId Document ID for matching.
     * @property pmid PubMed ID.
     * @property extractions List of extracted citation passages.
     * @property inputTokens Input tokens used.
     * @property outputTokens Output tokens used.
     * @property costUsd Cost in USD.
     */
    data class Success(
        override val documentId: String,
        override val pmid: String?,
        val extractions: List<LLMService.CitationExtraction>,
        override val inputTokens: Int = 0,
        override val outputTokens: Int = 0,
        override val costUsd: Double = 0.0
    ) : CitationResult()

    /**
     * Failed citation extraction result.
     *
     * @property documentId Document ID for matching.
     * @property pmid PubMed ID.
     * @property errorMessage Description of the error.
     * @property isRetryable Whether this error can be retried.
     * @property inputTokens Input tokens used before failure.
     * @property outputTokens Output tokens used before failure.
     * @property costUsd Cost incurred before failure.
     */
    data class Failure(
        override val documentId: String,
        override val pmid: String?,
        val errorMessage: String,
        val isRetryable: Boolean = true,
        override val inputTokens: Int = 0,
        override val outputTokens: Int = 0,
        override val costUsd: Double = 0.0
    ) : CitationResult()

    /** Whether extraction succeeded. */
    val isSuccess: Boolean
        get() = this is Success

    /** Whether extraction failed. */
    val isError: Boolean
        get() = this is Failure

    /** Get the extractions if successful, empty list otherwise. */
    val extractionsOrEmpty: List<LLMService.CitationExtraction>
        get() = (this as? Success)?.extractions ?: emptyList()

    companion object {
        /**
         * Create a successful citation result.
         */
        fun success(
            documentId: String,
            pmid: String?,
            extractions: List<LLMService.CitationExtraction>,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0.0
        ): CitationResult = Success(
            documentId = documentId,
            pmid = pmid,
            extractions = extractions,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )

        /**
         * Create a failure citation result.
         */
        fun failure(
            documentId: String,
            pmid: String?,
            error: Throwable,
            isRetryable: Boolean = true,
            inputTokens: Int = 0,
            outputTokens: Int = 0,
            costUsd: Double = 0.0
        ): CitationResult = Failure(
            documentId = documentId,
            pmid = pmid,
            errorMessage = error.message ?: "Unknown error",
            isRetryable = isRetryable,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )

        /**
         * Aggregate total token usage from citation results.
         *
         * @param results List of citation results.
         * @return Triple of (inputTokens, outputTokens, costUsd).
         */
        fun aggregateUsage(results: List<CitationResult>): Triple<Int, Int, Double> {
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
