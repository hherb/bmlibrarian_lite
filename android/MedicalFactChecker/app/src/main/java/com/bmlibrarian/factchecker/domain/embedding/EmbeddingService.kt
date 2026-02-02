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
import android.util.Log
import com.google.mediapipe.tasks.core.BaseOptions
import com.google.mediapipe.tasks.text.textembedder.TextEmbedder
import com.google.mediapipe.tasks.text.textembedder.TextEmbedderResult
import dagger.hilt.android.qualifiers.ApplicationContext
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.sync.Mutex
import kotlinx.coroutines.sync.withLock
import kotlinx.coroutines.withContext
import okhttp3.OkHttpClient
import okhttp3.Request
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import java.io.File
import java.io.FileOutputStream
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Service for computing semantic similarity between texts using MediaPipe embeddings.
 *
 * Uses Google MediaPipe's on-device Universal Sentence Encoder to compute cosine
 * similarity between a claim and document abstracts. This provides a fast, free
 * alternative to LLM-based scoring for relevance assessment.
 *
 * The model (~25MB) is downloaded on first use and cached locally.
 *
 * Mirrors iOS EmbeddingService using NLEmbedding.
 */
@Singleton
class EmbeddingService @Inject constructor(
    @ApplicationContext private val context: Context,
    private val okHttpClient: OkHttpClient
) {
    private var textEmbedder: TextEmbedder? = null
    private var initializationAttempted = false
    private var initializationError: Exception? = null
    private val initMutex = Mutex()

    /**
     * Check if text embedding is available.
     *
     * Returns true if the embedder is initialized or hasn't been attempted yet.
     * Call [ensureInitialized] to actually initialize and check availability.
     *
     * @return True if embedding might be available.
     */
    val isAvailable: Boolean
        get() = initializationError == null && (textEmbedder != null || !initializationAttempted)

    /**
     * Check if the model has been downloaded.
     *
     * @return True if the model file exists locally.
     */
    val isModelDownloaded: Boolean
        get() = getModelFile().exists()

    /**
     * Initialize the text embedder lazily.
     *
     * Downloads the model if not present, then creates the TextEmbedder.
     * Thread-safe via mutex.
     *
     * @return True if initialization succeeded.
     */
    suspend fun ensureInitialized(): Boolean = initMutex.withLock {
        if (textEmbedder != null) return@withLock true
        if (initializationAttempted && initializationError != null) return@withLock false

        initializationAttempted = true

        return@withLock try {
            // Download model if needed
            val modelFile = getModelFile()
            if (!modelFile.exists()) {
                downloadModel(modelFile)
            }

            // Create embedder
            val baseOptions = BaseOptions.builder()
                .setModelAssetPath(modelFile.absolutePath)
                .build()

            val options = TextEmbedder.TextEmbedderOptions.builder()
                .setBaseOptions(baseOptions)
                .build()

            textEmbedder = TextEmbedder.createFromOptions(context, options)
            Log.d(TAG, "TextEmbedder initialized successfully")
            true
        } catch (e: Exception) {
            Log.e(TAG, "Failed to initialize TextEmbedder", e)
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
            withContext(Dispatchers.Default) {
                val claimResult = embedder.embed(claim)
                val docResult = embedder.embed(documentText)

                computeSimilarityFromResults(claimResult, docResult)
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error computing similarity", e)
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
            withContext(Dispatchers.Default) {
                // Compute claim embedding once
                val claimResult = embedder.embed(claim)
                val claimEmbedding = claimResult.embeddingResult()
                    .embeddings()
                    .firstOrNull() ?: return@withContext List(documents.size) { null }

                // Score each document
                documents.map { (title, abstract) ->
                    try {
                        val documentText = combineDocumentText(title, abstract)
                        val docResult = embedder.embed(documentText)
                        val docEmbedding = docResult.embeddingResult()
                            .embeddings()
                            .firstOrNull()

                        if (docEmbedding != null) {
                            val similarity = TextEmbedder.cosineSimilarity(
                                claimEmbedding,
                                docEmbedding
                            )
                            SimilarityCalculator.clampSimilarity(similarity)
                        } else {
                            null
                        }
                    } catch (e: Exception) {
                        Log.e(TAG, "Error embedding document", e)
                        null
                    }
                }
            }
        } catch (e: Exception) {
            Log.e(TAG, "Error scoring documents", e)
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
     * Release resources when no longer needed.
     */
    fun close() {
        textEmbedder?.close()
        textEmbedder = null
        initializationAttempted = false
        initializationError = null
    }

    // ==================== Private Helpers ====================

    /**
     * Get the local model file path.
     *
     * @return File object for the model location.
     */
    private fun getModelFile(): File {
        val modelsDir = File(context.filesDir, Constants.EMBEDDING_MODELS_DIR)
        if (!modelsDir.exists()) {
            modelsDir.mkdirs()
        }
        return File(modelsDir, Constants.EMBEDDING_MODEL_FILENAME)
    }

    /**
     * Download the Universal Sentence Encoder model.
     *
     * @param targetFile The file to save the model to.
     * @throws Exception if download fails.
     */
    private suspend fun downloadModel(targetFile: File) = withContext(Dispatchers.IO) {
        Log.d(TAG, "Downloading embedding model from ${Constants.EMBEDDING_MODEL_URL}")

        val request = Request.Builder()
            .url(Constants.EMBEDDING_MODEL_URL)
            .build()

        NetworkRetry.withExponentialBackoff(
            maxRetries = Constants.NETWORK_MAX_RETRIES,
            shouldRetry = { NetworkRetry.isRetryableException(it) },
            onRetry = { attempt, delayMs, error ->
                Log.w(TAG, "Model download attempt $attempt failed: ${error.message}, retrying in ${delayMs}ms")
            }
        ) {
            val response = okHttpClient.newCall(request).execute()

            if (!response.isSuccessful) {
                if (NetworkRetry.isRetryableStatusCode(response.code)) {
                    throw java.io.IOException("Failed to download model: ${response.code}")
                }
                throw Exception("Failed to download model: ${response.code}")
            }

            response.body?.let { body ->
                FileOutputStream(targetFile).use { output ->
                    body.byteStream().use { input ->
                        input.copyTo(output)
                    }
                }
            } ?: throw Exception("Empty response body")
        }

        Log.d(TAG, "Model downloaded successfully: ${targetFile.length()} bytes")
    }

    /**
     * Compute cosine similarity from two embedding results.
     *
     * @param result1 First embedding result.
     * @param result2 Second embedding result.
     * @return Similarity score (0.0 to 1.0), or null if embeddings unavailable.
     */
    private fun computeSimilarityFromResults(
        result1: TextEmbedderResult,
        result2: TextEmbedderResult
    ): Double? {
        val embedding1 = result1.embeddingResult().embeddings().firstOrNull()
        val embedding2 = result2.embeddingResult().embeddings().firstOrNull()

        return if (embedding1 != null && embedding2 != null) {
            val similarity = TextEmbedder.cosineSimilarity(embedding1, embedding2)
            SimilarityCalculator.clampSimilarity(similarity)
        } else {
            null
        }
    }

    /**
     * Combine document title and abstract into a single text for embedding.
     *
     * @param title Document title.
     * @param abstract Document abstract (may be null).
     * @return Combined text with title given slight emphasis.
     */
    private fun combineDocumentText(title: String, abstract: String?): String {
        return if (abstract.isNullOrBlank()) {
            title
        } else {
            "$title. $abstract"
        }
    }

    companion object {
        private const val TAG = "EmbeddingService"
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
