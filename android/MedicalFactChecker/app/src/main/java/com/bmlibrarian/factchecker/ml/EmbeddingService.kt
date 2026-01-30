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

import android.content.Context
import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.util.Constants
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.tensorflow.lite.Interpreter
import java.io.FileInputStream
import java.nio.MappedByteBuffer
import java.nio.channels.FileChannel
import javax.inject.Inject
import javax.inject.Singleton
import kotlin.math.sqrt

/**
 * On-device embedding service for semantic similarity scoring.
 *
 * Uses TensorFlow Lite with Universal Sentence Encoder to compute
 * embeddings locally, enabling free relevance scoring without LLM API calls.
 * Matches the iOS NLEmbedding approach for cross-platform consistency.
 *
 * Features:
 * - Lazy initialization of TFLite interpreter
 * - Batch scoring for efficiency
 * - Cosine similarity calculation
 * - Threshold-based normalization to 1-5 scale
 * - Graceful degradation if model unavailable
 */
@Singleton
class EmbeddingService @Inject constructor(
    @ApplicationContext private val context: Context
) {

    companion object {
        private const val TAG = "EmbeddingService"
    }

    /** TFLite interpreter for embedding computation. */
    private var interpreter: Interpreter? = null

    /** Flag indicating if the service has been initialized. */
    private var isInitialized = false

    /**
     * Result of embedding-based document scoring.
     *
     * @property documentId The ID of the scored document
     * @property rawScore Raw cosine similarity (0.0-1.0)
     * @property normalizedScore Normalized to 1-5 relevance scale
     */
    data class EmbeddingScore(
        val documentId: String,
        val rawScore: Float,
        val normalizedScore: Int
    )

    /**
     * Check if the embedding service is available.
     *
     * Returns false on older devices or if the model file is not present.
     *
     * @return true if the service can be used
     */
    val isAvailable: Boolean
        get() = try {
            context.assets.open(Constants.EMBEDDING_MODEL_FILENAME).use { true }
        } catch (e: Exception) {
            Log.d(TAG, "Embedding model not available: ${e.message}")
            false
        }

    /**
     * Initialize the TFLite interpreter.
     *
     * Should be called before using [computeSimilarity] or [scoreDocuments].
     * Safe to call multiple times; subsequent calls are no-ops.
     *
     * @return true if initialization succeeded, false otherwise
     */
    suspend fun initialize(): Boolean = withContext(Dispatchers.IO) {
        if (isInitialized) return@withContext true

        try {
            val modelFile = loadModelFile()
            val options = Interpreter.Options().apply {
                numThreads = Constants.EMBEDDING_NUM_THREADS
            }
            interpreter = Interpreter(modelFile, options)
            isInitialized = true
            Log.i(TAG, "Embedding service initialized successfully")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize embedding service: ${e.message}")
            false
        }
    }

    /**
     * Load the TFLite model file from assets.
     *
     * @return MappedByteBuffer containing the model
     */
    private fun loadModelFile(): MappedByteBuffer {
        val fileDescriptor = context.assets.openFd(Constants.EMBEDDING_MODEL_FILENAME)
        val inputStream = FileInputStream(fileDescriptor.fileDescriptor)
        val fileChannel = inputStream.channel
        val startOffset = fileDescriptor.startOffset
        val declaredLength = fileDescriptor.declaredLength
        return fileChannel.map(FileChannel.MapMode.READ_ONLY, startOffset, declaredLength)
    }

    /**
     * Compute similarity between a claim and a single document.
     *
     * @param claim The medical claim text
     * @param documentText The document text (title + abstract)
     * @return Cosine similarity (0.0-1.0), or null if computation fails
     */
    fun computeSimilarity(claim: String, documentText: String): Float? {
        val interp = interpreter ?: return null

        return try {
            val claimEmbedding = computeEmbedding(claim, interp) ?: return null
            val docEmbedding = computeEmbedding(documentText, interp) ?: return null
            cosineSimilarity(claimEmbedding, docEmbedding)
        } catch (e: Exception) {
            Log.e(TAG, "Similarity computation failed: ${e.message}")
            null
        }
    }

    /**
     * Score multiple documents in batch.
     *
     * More efficient than individual calls because the claim embedding
     * is computed once and reused for all documents.
     *
     * @param claim The medical claim text
     * @param documents List of documents to score
     * @return List of embedding scores (may be smaller than input if some fail)
     */
    suspend fun scoreDocuments(
        claim: String,
        documents: List<DocumentEntity>
    ): List<EmbeddingScore> = withContext(Dispatchers.Default) {
        val interp = interpreter ?: return@withContext emptyList()

        try {
            // Compute claim embedding once
            val claimEmbedding = computeEmbedding(claim, interp)
                ?: return@withContext emptyList()

            // Score each document
            documents.mapNotNull { doc ->
                val documentText = buildDocumentText(doc)
                val docEmbedding = computeEmbedding(documentText, interp)
                    ?: return@mapNotNull null

                val rawScore = cosineSimilarity(claimEmbedding, docEmbedding)
                EmbeddingScore(
                    documentId = doc.id,
                    rawScore = rawScore,
                    normalizedScore = normalizeToRelevanceScale(rawScore)
                )
            }
        } catch (e: Exception) {
            Log.e(TAG, "Batch scoring failed: ${e.message}")
            emptyList()
        }
    }

    /**
     * Build document text for embedding.
     *
     * Format: "{title}. {abstract}" (title first for position weighting)
     *
     * @param document The document entity
     * @return Combined text for embedding
     */
    private fun buildDocumentText(document: DocumentEntity): String {
        return buildString {
            append(document.title)
            if (!document.title.endsWith(".")) append(".")
            append(" ")
            document.abstractText?.let { append(it) }
        }
    }

    /**
     * Compute embedding for a text input.
     *
     * @param text The input text
     * @param interpreter The TFLite interpreter
     * @return Float array of embedding dimensions, or null on failure
     */
    private fun computeEmbedding(text: String, interpreter: Interpreter): FloatArray? {
        return try {
            // Note: Actual input format depends on the model
            // Universal Sentence Encoder typically expects string input directly
            val inputArray = arrayOf(text)
            val outputArray = Array(1) { FloatArray(Constants.EMBEDDING_DIMENSION) }

            interpreter.run(inputArray, outputArray)
            outputArray[0]
        } catch (e: Exception) {
            Log.e(TAG, "Embedding computation failed: ${e.message}")
            null
        }
    }

    /**
     * Compute cosine similarity between two embedding vectors.
     *
     * @param a First embedding vector
     * @param b Second embedding vector
     * @return Cosine similarity in range [-1, 1], typically [0, 1] for text
     */
    private fun cosineSimilarity(a: FloatArray, b: FloatArray): Float {
        require(a.size == b.size) { "Vectors must have same dimension" }

        var dotProduct = 0f
        var normA = 0f
        var normB = 0f

        for (i in a.indices) {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        val denominator = sqrt(normA) * sqrt(normB)
        return if (denominator > 0) dotProduct / denominator else 0f
    }

    /**
     * Convert raw similarity (0.0-1.0) to 1-5 relevance scale.
     *
     * Thresholds match iOS implementation exactly for cross-platform consistency.
     *
     * @param similarity Raw cosine similarity
     * @return Normalized score (1-5)
     */
    fun normalizeToRelevanceScale(similarity: Float): Int {
        return when {
            similarity < Constants.EMBEDDING_THRESHOLD_NOT_RELEVANT -> 1
            similarity < Constants.EMBEDDING_THRESHOLD_MARGINAL -> 2
            similarity < Constants.EMBEDDING_THRESHOLD_MODERATE -> 3
            similarity < Constants.EMBEDDING_THRESHOLD_HIGHLY_RELEVANT -> 4
            else -> 5
        }
    }

    /**
     * Release resources when no longer needed.
     *
     * Call this when the service is being disposed.
     */
    fun close() {
        interpreter?.close()
        interpreter = null
        isInitialized = false
        Log.i(TAG, "Embedding service closed")
    }
}
