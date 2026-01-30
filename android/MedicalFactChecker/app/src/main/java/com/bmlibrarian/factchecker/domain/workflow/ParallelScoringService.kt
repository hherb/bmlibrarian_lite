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

import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.delay
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.pow
import kotlin.random.Random

/**
 * Service for parallel document scoring using Kotlin Coroutines.
 *
 * Uses a Semaphore to limit concurrent scoring requests while processing
 * documents in parallel. Results are reported via progress callbacks as
 * they complete.
 *
 * Thread Safety:
 * - Input uses ScoringInput data classes (not Room entities)
 * - Output uses ScoringResult sealed classes
 * - The calling workflow applies results to DocumentEntities on the main thread
 *
 * Mirrors iOS ParallelScoringService for cross-platform consistency.
 *
 * Example usage:
 * ```kotlin
 * val service = ParallelScoringService(llmService)
 *
 * val inputs = documents.map { ScoringInput.fromDocument(it) }
 *
 * val results = service.scoreDocuments(
 *     documents = inputs,
 *     claim = "Vitamin D reduces COVID-19 severity",
 *     provider = LLMProvider.OPENAI,
 *     apiKey = "...",
 *     model = "gpt-4o",
 *     maxConcurrent = 3
 * ) { documentId, completed, total ->
 *     println("Scored $completed/$total")
 * }
 * ```
 */
@Singleton
class ParallelScoringService @Inject constructor(
    private val llmService: LLMService
) {
    companion object {
        /** Maximum parse retries per document before giving up. */
        private const val MAX_PARSE_RETRIES = 3

        /** Base delay for parse retry backoff (milliseconds). */
        private const val PARSE_RETRY_BASE_DELAY_MS = 500L

        /** Default max concurrent requests for cloud providers. */
        const val DEFAULT_CLOUD_CONCURRENCY = 3

        /** Max concurrent requests for local providers (Ollama). */
        const val LOCAL_CONCURRENCY = 1
    }

    /**
     * Score multiple documents in parallel.
     *
     * Uses a semaphore-based approach to maintain exactly `maxConcurrent`
     * requests in flight at any time. Results are returned as they complete.
     *
     * @param documents Documents to score (as ScoringInput objects).
     * @param claim The medical claim to evaluate documents against.
     * @param provider The LLM provider configuration.
     * @param apiKey API key for authentication.
     * @param model Model ID to use.
     * @param maxConcurrent Maximum concurrent scoring requests.
     * @param onProgress Callback for progress updates (documentId, completed, total).
     * @return List of scoring results in completion order.
     */
    suspend fun scoreDocuments(
        documents: List<ScoringInput>,
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String,
        maxConcurrent: Int = detectConcurrency(provider),
        onProgress: suspend (String, Int, Int) -> Unit = { _, _, _ -> }
    ): List<ScoringResult> = coroutineScope {
        if (documents.isEmpty()) return@coroutineScope emptyList()

        val semaphore = Semaphore(maxConcurrent.coerceAtLeast(1))
        val total = documents.size
        var completed = 0

        val modelInfo = provider.getModel(model)

        // Launch all scoring tasks with semaphore-limited concurrency
        val deferredResults = documents.map { input ->
            async {
                semaphore.withPermit {
                    if (!isActive) {
                        // Return a cancellation failure if the coroutine was cancelled
                        return@withPermit ScoringResult.failure(
                            documentId = input.documentId,
                            pmid = input.pmid,
                            error = kotlinx.coroutines.CancellationException("Scoring cancelled"),
                            isRetryable = false
                        )
                    }

                    val result = scoreDocument(
                        input = input,
                        claim = claim,
                        provider = provider,
                        apiKey = apiKey,
                        model = model,
                        modelInfo = modelInfo
                    )

                    // Update progress
                    synchronized(this@coroutineScope) {
                        completed++
                    }
                    onProgress(input.documentId, completed, total)

                    result
                }
            }
        }

        // Await all results
        deferredResults.awaitAll()
    }

    /**
     * Score documents with checkpoint support.
     *
     * Skips documents that have already been scored (via checkpointedIds).
     * Results from checkpoints can be provided to include in aggregation.
     *
     * @param documents All documents to potentially score.
     * @param claim The medical claim to evaluate documents against.
     * @param provider The LLM provider configuration.
     * @param apiKey API key for authentication.
     * @param model Model ID to use.
     * @param checkpointedIds Set of document IDs that have been checkpointed.
     * @param maxConcurrent Maximum concurrent scoring requests.
     * @param onProgress Callback for progress updates.
     * @param onResult Callback for each result (for checkpointing).
     * @return List of scoring results for newly scored documents.
     */
    suspend fun scoreDocumentsWithCheckpoints(
        documents: List<ScoringInput>,
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String,
        checkpointedIds: Set<String>,
        maxConcurrent: Int = detectConcurrency(provider),
        onProgress: suspend (String, Int, Int) -> Unit = { _, _, _ -> },
        onResult: suspend (ScoringResult) -> Unit = { }
    ): List<ScoringResult> = coroutineScope {
        // Filter out already checkpointed documents
        val docsToScore = documents.filter { it.documentId !in checkpointedIds }

        if (docsToScore.isEmpty()) return@coroutineScope emptyList()

        val semaphore = Semaphore(maxConcurrent.coerceAtLeast(1))
        val totalRemaining = docsToScore.size
        val totalWithCheckpointed = documents.size
        val checkpointedCount = checkpointedIds.size
        var completed = 0

        val modelInfo = provider.getModel(model)

        val deferredResults = docsToScore.map { input ->
            async {
                semaphore.withPermit {
                    if (!isActive) {
                        return@withPermit ScoringResult.failure(
                            documentId = input.documentId,
                            pmid = input.pmid,
                            error = kotlinx.coroutines.CancellationException("Scoring cancelled"),
                            isRetryable = false
                        )
                    }

                    val result = scoreDocument(
                        input = input,
                        claim = claim,
                        provider = provider,
                        apiKey = apiKey,
                        model = model,
                        modelInfo = modelInfo
                    )

                    // Callback for checkpointing
                    onResult(result)

                    // Update progress (including checkpointed count)
                    synchronized(this@coroutineScope) {
                        completed++
                    }
                    onProgress(
                        input.documentId,
                        checkpointedCount + completed,
                        totalWithCheckpointed
                    )

                    result
                }
            }
        }

        deferredResults.awaitAll()
    }

    /**
     * Score a single document with retry logic for parse failures.
     *
     * @param input The document scoring input.
     * @param claim The claim to evaluate against.
     * @param provider The LLM provider.
     * @param apiKey API key for authentication.
     * @param model Model ID to use.
     * @param modelInfo Model pricing info for cost calculation.
     * @return Scoring result with score/rationale or error.
     */
    private suspend fun scoreDocument(
        input: ScoringInput,
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String,
        modelInfo: ModelInfo?
    ): ScoringResult {
        var lastParseError = ""
        var accumulatedInputTokens = 0
        var accumulatedOutputTokens = 0
        var accumulatedCost = 0.0

        // Retry loop for parse failures
        for (attempt in 0 until MAX_PARSE_RETRIES) {
            val result = llmService.scoreDocument(
                provider = provider,
                apiKey = apiKey,
                model = model,
                claim = claim,
                title = input.title,
                abstractText = input.abstract.ifEmpty { null }
            )

            // Estimate tokens and cost
            val estimatedInput = estimateTokens(claim + input.title + input.abstract)
            val estimatedOutput = Constants.LLM_SCORING_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
            val cost = modelInfo?.calculateCost(estimatedInput, estimatedOutput) ?: 0.0

            accumulatedInputTokens += estimatedInput
            accumulatedOutputTokens += estimatedOutput
            accumulatedCost += cost

            result.fold(
                onSuccess = { (score, rationale) ->
                    return ScoringResult.success(
                        documentId = input.documentId,
                        pmid = input.pmid,
                        score = score,
                        rationale = rationale,
                        inputTokens = accumulatedInputTokens,
                        outputTokens = accumulatedOutputTokens,
                        costUsd = accumulatedCost
                    )
                },
                onFailure = { error ->
                    // Check if this is a parse error (retryable) or API error (not retryable here)
                    val errorMessage = error.message ?: "Unknown error"

                    if (isParseError(error)) {
                        lastParseError = errorMessage

                        // Retry with exponential backoff
                        if (attempt < MAX_PARSE_RETRIES - 1) {
                            val delayMs = PARSE_RETRY_BASE_DELAY_MS * 2.0.pow(attempt.toDouble()).toLong()
                            val jitter = (delayMs * Random.nextDouble(-0.25, 0.25)).toLong()
                            delay(delayMs + jitter)
                        }
                    } else {
                        // API/network error - return immediately
                        return ScoringResult.failure(
                            documentId = input.documentId,
                            pmid = input.pmid,
                            error = error,
                            isRetryable = isRetryableError(error),
                            inputTokens = accumulatedInputTokens,
                            outputTokens = accumulatedOutputTokens,
                            costUsd = accumulatedCost
                        )
                    }
                }
            )
        }

        // All parse retries exhausted
        return ScoringResult.parseFailure(
            documentId = input.documentId,
            pmid = input.pmid,
            rawResponse = "",
            parseError = lastParseError,
            inputTokens = accumulatedInputTokens,
            outputTokens = accumulatedOutputTokens,
            costUsd = accumulatedCost
        )
    }

    /**
     * Detect appropriate concurrency level based on provider.
     *
     * Local providers (Ollama) use single concurrency, while cloud
     * providers can handle multiple concurrent requests.
     *
     * @param provider The LLM provider.
     * @return Recommended concurrency level.
     */
    fun detectConcurrency(provider: LLMProvider): Int {
        return if (provider.requiresApiKey) {
            DEFAULT_CLOUD_CONCURRENCY
        } else {
            LOCAL_CONCURRENCY
        }
    }

    /**
     * Check if an error is a parse error (response parsing failed).
     */
    private fun isParseError(error: Throwable): Boolean {
        val message = error.message?.lowercase() ?: return false
        return message.contains("parse") ||
                message.contains("json") ||
                message.contains("format") ||
                message.contains("invalid score")
    }

    /**
     * Check if an error is retryable (transient network issues).
     */
    private fun isRetryableError(error: Throwable): Boolean {
        val message = error.message?.lowercase() ?: return true
        return message.contains("timeout") ||
                message.contains("connection") ||
                message.contains("network") ||
                message.contains("rate limit") ||
                message.contains("429") ||
                message.contains("503") ||
                message.contains("502")
    }

    /**
     * Estimate token count for text.
     *
     * Uses a rough approximation based on average characters per token.
     *
     * @param text The text to estimate tokens for.
     * @return Estimated token count (minimum 1).
     */
    private fun estimateTokens(text: String): Int {
        return (text.length / Constants.TOKEN_ESTIMATE_CHARS_PER_TOKEN).coerceAtLeast(1)
    }
}
