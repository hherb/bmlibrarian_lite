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

package com.bmlibrarian.factchecker.domain.embedding

import android.content.Context
import com.google.mlkit.nl.textembedding.TextEmbedder
import com.google.mlkit.nl.textembedding.TextEmbedding
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.tasks.await
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for computing semantic similarity between texts using ML Kit embeddings.
 *
 * Uses Google ML Kit's on-device sentence embeddings to compute cosine similarity
 * between a claim and document abstracts. This provides a fast, free alternative
 * to LLM-based scoring for relevance assessment.
 *
 * Mirrors iOS EmbeddingService using NLEmbedding.
 */
@Singleton
class EmbeddingService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var textEmbedder: TextEmbedder? = null
    private var initializationAttempted = false
    private var initializationError: Exception? = null

    /**
     * Check if text embedding is available on this device.
     *
     * @return True if ML Kit text embedding is available.
     */
    val isAvailable: Boolean
        get() = initializationError == null && (textEmbedder != null || !initializationAttempted)

    /**
     * Initialize the text embedder lazily.
     *
     * @return True if initialization succeeded.
     */
    private suspend fun ensureInitialized(): Boolean {
        if (textEmbedder != null) return true
        if (initializationAttempted && initializationError != null) return false

        return try {
            initializationAttempted = true
            textEmbedder = TextEmbedder.getClient(TextEmbedding.TextEmbedderOptions.builder().build())
            true
        } catch (e: Exception) {
            initializationError = e
            false
        }
    }

    /**
     * Compute semantic similarity between a claim and document text.
     *
     * @param claim The medical claim being fact-checked.
     * @param documentText Combined title and abstract of the document.
     * @return Cosine similarity score (0.0 to 1.0), or null if embeddings unavailable.
     */
    suspend fun computeSimilarity(claim: String, documentText: String): Double? {
        if (!ensureInitialized()) return null
        val embedder = textEmbedder ?: return null

        return try {
            val claimResult = embedder.embed(claim).await()
            val docResult = embedder.embed(documentText).await()

            val claimVector = claimResult.floatEmbedding
            val docVector = docResult.floatEmbedding

            if (claimVector != null && docVector != null) {
                val similarity = SimilarityCalculator.cosineSimilarity(claimVector, docVector)
                SimilarityCalculator.clampSimilarity(similarity)
            } else {
                null
            }
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Score multiple documents against a claim.
     *
     * More efficient than calling computeSimilarity repeatedly since
     * the claim embedding is computed only once.
     *
     * @param claim The medical claim being fact-checked.
     * @param documents List of pairs of (title, abstract).
     * @return List of similarity scores (0.0 to 1.0), null for failed embeddings.
     */
    suspend fun scoreDocuments(
        claim: String,
        documents: List<Pair<String, String?>>
    ): List<Double?> {
        if (!ensureInitialized()) {
            return List(documents.size) { null }
        }
        val embedder = textEmbedder ?: return List(documents.size) { null }

        return try {
            // Compute claim embedding once
            val claimResult = embedder.embed(claim).await()
            val claimVector = claimResult.floatEmbedding
                ?: return List(documents.size) { null }

            // Score each document
            documents.map { (title, abstract) ->
                try {
                    val documentText = combineDocumentText(title, abstract)
                    val docResult = embedder.embed(documentText).await()
                    val docVector = docResult.floatEmbedding

                    if (docVector != null) {
                        val similarity = SimilarityCalculator.cosineSimilarity(claimVector, docVector)
                        SimilarityCalculator.clampSimilarity(similarity)
                    } else {
                        null
                    }
                } catch (e: Exception) {
                    null
                }
            }
        } catch (e: Exception) {
            List(documents.size) { null }
        }
    }

    /**
     * Convert a raw similarity score (0.0-1.0) to a 1-5 relevance scale.
     *
     * @param similarity Raw cosine similarity (0.0 to 1.0).
     * @return Normalized score (1 to 5).
     */
    fun normalizeToRelevanceScale(similarity: Double): Int {
        return SimilarityCalculator.normalizeToRelevanceScale(similarity)
    }

    /**
     * Combine document title and abstract into a single text for embedding.
     *
     * @param title Document title.
     * @param abstract Document abstract.
     * @return Combined text with title given slight emphasis.
     */
    private fun combineDocumentText(title: String, abstract: String?): String {
        return if (abstract.isNullOrBlank()) {
            title
        } else {
            "$title. $abstract"
        }
    }

    /**
     * Release resources when no longer needed.
     */
    fun close() {
        textEmbedder?.close()
        textEmbedder = null
    }
}

/**
 * Result of an embedding scoring operation.
 *
 * @property rawScore The raw cosine similarity (0.0 to 1.0).
 * @property normalizedScore The score normalized to 1-5 scale.
 */
data class EmbeddingResult(
    val rawScore: Double,
    val normalizedScore: Int
)
