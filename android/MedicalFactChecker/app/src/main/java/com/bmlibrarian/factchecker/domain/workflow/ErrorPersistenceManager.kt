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

import com.bmlibrarian.factchecker.data.local.dao.ProcessingErrorDao
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import com.bmlibrarian.factchecker.data.local.entity.ProcessingErrorEntity
import kotlinx.coroutines.flow.Flow
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages error persistence for retry functionality.
 *
 * Tracks errors that occur during document processing (scoring, citation extraction)
 * to enable retry functionality and error reporting in the UI.
 *
 * Mirrors iOS error persistence pattern for cross-platform consistency.
 *
 * Usage:
 * ```kotlin
 * val manager = ErrorPersistenceManager(errorDao)
 *
 * // Record an error
 * manager.recordScoringError(sessionId, result)
 *
 * // Get retryable errors
 * val errors = manager.getRetryableErrors(sessionId)
 *
 * // Mark error as retried
 * manager.markRetried(error.id)
 * ```
 */
@Singleton
class ErrorPersistenceManager @Inject constructor(
    private val errorDao: ProcessingErrorDao
) {

    // ==================== Recording Errors ====================

    /**
     * Record a scoring error from a failed ScoringResult.
     *
     * @param sessionId The session identifier.
     * @param result The failed scoring result.
     */
    suspend fun recordScoringError(
        sessionId: String,
        result: ScoringResult
    ) {
        val (errorType, errorMessage, isRetryable) = when (result) {
            is ScoringResult.Failure -> Triple(
                categorizeError(result.errorMessage),
                result.errorMessage,
                result.isRetryable
            )
            is ScoringResult.ParseFailure -> Triple(
                ProcessingErrorEntity.TYPE_PARSE,
                result.parseError,
                true // Parse errors are retryable
            )
            is ScoringResult.Success -> return // Not an error
        }

        val error = ProcessingErrorEntity(
            sessionId = sessionId,
            documentId = result.documentId,
            step = ProcessingCheckpointEntity.STEP_SCORING,
            errorType = errorType,
            errorMessage = errorMessage,
            isRetryable = isRetryable
        )
        errorDao.insert(error)
    }

    /**
     * Record multiple scoring errors.
     *
     * @param sessionId The session identifier.
     * @param results The failed scoring results.
     */
    suspend fun recordScoringErrors(
        sessionId: String,
        results: List<ScoringResult>
    ) {
        val errors = results.mapNotNull { result ->
            when (result) {
                is ScoringResult.Failure -> ProcessingErrorEntity(
                    sessionId = sessionId,
                    documentId = result.documentId,
                    step = ProcessingCheckpointEntity.STEP_SCORING,
                    errorType = categorizeError(result.errorMessage),
                    errorMessage = result.errorMessage,
                    isRetryable = result.isRetryable
                )
                is ScoringResult.ParseFailure -> ProcessingErrorEntity(
                    sessionId = sessionId,
                    documentId = result.documentId,
                    step = ProcessingCheckpointEntity.STEP_SCORING,
                    errorType = ProcessingErrorEntity.TYPE_PARSE,
                    errorMessage = result.parseError,
                    isRetryable = true
                )
                is ScoringResult.Success -> null
            }
        }
        if (errors.isNotEmpty()) {
            errorDao.insertAll(errors)
        }
    }

    /**
     * Record a citation extraction error.
     *
     * @param sessionId The session identifier.
     * @param documentId The document identifier.
     * @param error The exception that occurred.
     */
    suspend fun recordCitationError(
        sessionId: String,
        documentId: String,
        error: Throwable
    ) {
        val errorEntity = ProcessingErrorEntity(
            sessionId = sessionId,
            documentId = documentId,
            step = ProcessingCheckpointEntity.STEP_CITATION,
            errorType = ProcessingErrorEntity.errorTypeFromException(error),
            errorMessage = error.message ?: "Unknown error",
            isRetryable = isRetryable(error)
        )
        errorDao.insert(errorEntity)
    }

    // ==================== Querying Errors ====================

    /**
     * Get all errors for a session.
     *
     * @param sessionId The session identifier.
     * @return List of errors.
     */
    suspend fun getErrors(sessionId: String): List<ProcessingErrorEntity> {
        return errorDao.getErrorsBySession(sessionId)
    }

    /**
     * Get retryable errors for a session.
     *
     * @param sessionId The session identifier.
     * @return List of retryable errors.
     */
    suspend fun getRetryableErrors(sessionId: String): List<ProcessingErrorEntity> {
        return errorDao.getRetryableErrors(sessionId)
    }

    /**
     * Get retryable errors for a specific step.
     *
     * @param sessionId The session identifier.
     * @param step The processing step.
     * @return List of retryable errors.
     */
    suspend fun getRetryableErrorsByStep(
        sessionId: String,
        step: String
    ): List<ProcessingErrorEntity> {
        return errorDao.getRetryableErrorsByStep(sessionId, step)
    }

    /**
     * Get document IDs that have errors for a step.
     *
     * @param sessionId The session identifier.
     * @param step The processing step.
     * @return Set of document IDs with errors.
     */
    suspend fun getErrorDocumentIds(
        sessionId: String,
        step: String
    ): Set<String> {
        return errorDao.getErrorDocumentIds(sessionId, step).toSet()
    }

    /**
     * Get count of retryable errors.
     *
     * @param sessionId The session identifier.
     * @return Number of retryable errors.
     */
    suspend fun getRetryableCount(sessionId: String): Int {
        return errorDao.getRetryableCount(sessionId)
    }

    /**
     * Observe errors for a session as a Flow.
     *
     * @param sessionId The session identifier.
     * @return Flow of error lists.
     */
    fun observeErrors(sessionId: String): Flow<List<ProcessingErrorEntity>> {
        return errorDao.observeErrors(sessionId)
    }

    /**
     * Observe retryable error count for a session.
     *
     * @param sessionId The session identifier.
     * @return Flow of retryable error count.
     */
    fun observeRetryableCount(sessionId: String): Flow<Int> {
        return errorDao.observeRetryableCount(sessionId)
    }

    // ==================== Managing Errors ====================

    /**
     * Mark an error as retried.
     *
     * Increments the retry count and updates the last retry timestamp.
     *
     * @param errorId The error identifier.
     */
    suspend fun markRetried(errorId: String) {
        errorDao.incrementRetryCount(errorId, Date().time)
    }

    /**
     * Remove an error (after successful retry).
     *
     * @param errorId The error identifier.
     */
    suspend fun removeError(errorId: String) {
        errorDao.deleteError(errorId)
    }

    /**
     * Remove errors for successfully processed documents.
     *
     * Call after retry succeeds to clean up the error record.
     *
     * @param sessionId The session identifier.
     * @param documentIds The document IDs that were successfully processed.
     */
    suspend fun removeErrorsForDocuments(
        sessionId: String,
        documentIds: Set<String>
    ) {
        val errors = errorDao.getErrorsBySession(sessionId)
        errors.filter { it.documentId in documentIds }
            .forEach { errorDao.deleteError(it.id) }
    }

    /**
     * Delete all errors for a session.
     *
     * @param sessionId The session identifier.
     */
    suspend fun deleteErrors(sessionId: String) {
        errorDao.deleteErrorsBySession(sessionId)
    }

    /**
     * Clean up resolved errors (max retries reached or non-retryable).
     *
     * @param sessionId The session identifier.
     */
    suspend fun cleanupResolvedErrors(sessionId: String) {
        errorDao.deleteResolvedErrors(sessionId)
    }

    // ==================== Helper Methods ====================

    /**
     * Categorize an error message into an error type.
     */
    private fun categorizeError(message: String): String {
        val lowerMessage = message.lowercase()
        return when {
            lowerMessage.contains("timeout") -> ProcessingErrorEntity.TYPE_TIMEOUT
            lowerMessage.contains("network") ||
                    lowerMessage.contains("connection") -> ProcessingErrorEntity.TYPE_NETWORK
            lowerMessage.contains("parse") ||
                    lowerMessage.contains("json") -> ProcessingErrorEntity.TYPE_PARSE
            lowerMessage.contains("401") ||
                    lowerMessage.contains("403") ||
                    lowerMessage.contains("429") ||
                    lowerMessage.contains("rate") -> ProcessingErrorEntity.TYPE_API
            else -> ProcessingErrorEntity.TYPE_UNKNOWN
        }
    }

    /**
     * Determine if an error is retryable.
     */
    private fun isRetryable(error: Throwable): Boolean {
        val message = error.message?.lowercase() ?: return true
        // Non-retryable errors
        if (message.contains("401") || message.contains("403")) return false
        if (message.contains("invalid") && message.contains("key")) return false
        // Everything else is retryable
        return true
    }
}
