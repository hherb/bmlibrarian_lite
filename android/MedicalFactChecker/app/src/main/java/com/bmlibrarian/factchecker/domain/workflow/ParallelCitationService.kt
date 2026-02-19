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
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.isActive
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import java.util.concurrent.atomic.AtomicInteger
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for parallel citation extraction using Kotlin Coroutines.
 *
 * Uses a Semaphore to limit concurrent extraction requests while processing
 * documents in parallel. Results are reported via progress callbacks as
 * they complete.
 *
 * Thread Safety:
 * - Input uses CitationInput data classes (not Room entities)
 * - Output uses CitationResult sealed classes
 * - Progress counter uses AtomicInteger for thread-safe updates
 * - The calling workflow applies results to DocumentEntities on the main thread
 *
 * Mirrors iOS ParallelCitationService for cross-platform consistency.
 *
 * Example usage:
 * ```kotlin
 * val service = ParallelCitationService(llmService)
 *
 * val inputs = documents.map { CitationInput.fromDocument(it) }
 *
 * val results = service.extractCitations(
 *     documents = inputs,
 *     claim = "Vitamin D reduces COVID-19 severity",
 *     provider = LLMProvider.OPENAI,
 *     apiKey = "...",
 *     model = "gpt-4o",
 *     maxConcurrent = 3
 * ) { documentId, completed, total ->
 *     println("Extracted $completed/$total")
 * }
 * ```
 */
@Singleton
class ParallelCitationService @Inject constructor(
    private val llmService: LLMService
) {
    companion object {
        /** Default max concurrent requests for cloud providers. */
        const val DEFAULT_CLOUD_CONCURRENCY = 3

        /** Max concurrent requests for local providers (Ollama). */
        const val LOCAL_CONCURRENCY = 1
    }

    /**
     * Extract citations from multiple documents in parallel.
     *
     * Uses a semaphore-based approach to maintain exactly `maxConcurrent`
     * requests in flight at any time. Results are returned as they complete.
     *
     * @param documents Documents to extract citations from (as CitationInput objects).
     * @param claim The medical claim to evaluate documents against.
     * @param provider The LLM provider configuration.
     * @param apiKey API key for authentication.
     * @param model Model ID to use.
     * @param maxConcurrent Maximum concurrent extraction requests.
     * @param onProgress Callback for progress updates (documentId, completed, total).
     * @param onResult Optional callback for each result as it completes (for incremental UI updates).
     * @return List of citation results in completion order.
     */
    suspend fun extractCitations(
        documents: List<CitationInput>,
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String,
        maxConcurrent: Int = detectConcurrency(provider),
        onProgress: suspend (String, Int, Int) -> Unit = { _, _, _ -> },
        onResult: suspend (CitationResult) -> Unit = { }
    ): List<CitationResult> = coroutineScope {
        if (documents.isEmpty()) return@coroutineScope emptyList()

        val semaphore = Semaphore(maxConcurrent.coerceAtLeast(1))
        val total = documents.size
        val completed = AtomicInteger(0)
        val modelInfo = provider.getModel(model)

        val deferredResults = documents.map { input ->
            async {
                semaphore.withPermit {
                    if (!isActive) {
                        return@withPermit CitationResult.failure(
                            documentId = input.documentId,
                            pmid = input.pmid,
                            error = kotlinx.coroutines.CancellationException("Citation extraction cancelled"),
                            isRetryable = false
                        )
                    }

                    val result = extractCitationsFromDocument(
                        input = input,
                        claim = claim,
                        provider = provider,
                        apiKey = apiKey,
                        model = model,
                        modelInfo = modelInfo
                    )

                    // Callback for incremental updates
                    onResult(result)

                    // Update progress atomically
                    val currentCompleted = completed.incrementAndGet()
                    onProgress(input.documentId, currentCompleted, total)

                    result
                }
            }
        }

        deferredResults.awaitAll()
    }

    /**
     * Extract citations from a single document.
     *
     * @param input The document citation input.
     * @param claim The claim to extract relevant passages for.
     * @param provider The LLM provider.
     * @param apiKey API key for authentication.
     * @param model Model ID to use.
     * @param modelInfo Model pricing info for cost calculation.
     * @return Citation result with passages or error.
     */
    private suspend fun extractCitationsFromDocument(
        input: CitationInput,
        claim: String,
        provider: LLMProvider,
        apiKey: String,
        model: String,
        modelInfo: com.bmlibrarian.factchecker.domain.model.ModelInfo?
    ): CitationResult {
        val estimatedInput = ParallelScoringService.estimateTokens(claim + input.title + input.content)
        val estimatedOutput = Constants.LLM_CITATION_MAX_TOKENS / Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR
        val cost = modelInfo?.calculateCost(estimatedInput, estimatedOutput) ?: 0.0

        val result = llmService.extractCitations(
            provider = provider,
            apiKey = apiKey,
            model = model,
            claim = claim,
            title = input.title,
            content = input.content.ifEmpty { null }
        )

        return result.fold(
            onSuccess = { extractions ->
                CitationResult.success(
                    documentId = input.documentId,
                    pmid = input.pmid,
                    extractions = extractions,
                    inputTokens = estimatedInput,
                    outputTokens = estimatedOutput,
                    costUsd = cost
                )
            },
            onFailure = { error ->
                CitationResult.failure(
                    documentId = input.documentId,
                    pmid = input.pmid,
                    error = error,
                    isRetryable = ParallelScoringService.isRetryableError(error),
                    inputTokens = estimatedInput,
                    outputTokens = estimatedOutput,
                    costUsd = cost
                )
            }
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
}
