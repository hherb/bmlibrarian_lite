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

package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.bmlibrarian.factchecker.data.local.entity.ProcessingErrorEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for processing errors.
 *
 * Provides operations for tracking and managing errors that occur during
 * document processing, enabling retry functionality and error reporting.
 */
@Dao
interface ProcessingErrorDao {

    /**
     * Insert a new error record.
     *
     * @param error The error to insert.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(error: ProcessingErrorEntity)

    /**
     * Insert multiple error records.
     *
     * @param errors The errors to insert.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(errors: List<ProcessingErrorEntity>)

    /**
     * Update an existing error record.
     *
     * @param error The error to update.
     */
    @Update
    suspend fun update(error: ProcessingErrorEntity)

    /**
     * Get an error by ID.
     *
     * @param id The error ID.
     * @return The error, or null if not found.
     */
    @Query("SELECT * FROM processing_errors WHERE id = :id")
    suspend fun getError(id: String): ProcessingErrorEntity?

    /**
     * Get all errors for a session.
     *
     * @param sessionId The session ID.
     * @return List of errors.
     */
    @Query("""
        SELECT * FROM processing_errors
        WHERE session_id = :sessionId
        ORDER BY created_at DESC
    """)
    suspend fun getErrorsBySession(sessionId: String): List<ProcessingErrorEntity>

    /**
     * Get errors for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return List of errors.
     */
    @Query("""
        SELECT * FROM processing_errors
        WHERE session_id = :sessionId AND step = :step
        ORDER BY created_at DESC
    """)
    suspend fun getErrorsByStep(
        sessionId: String,
        step: String
    ): List<ProcessingErrorEntity>

    /**
     * Get retryable errors for a session.
     *
     * @param sessionId The session ID.
     * @return List of retryable errors.
     */
    @Query("""
        SELECT * FROM processing_errors
        WHERE session_id = :sessionId
        AND is_retryable = 1
        AND retry_count < max_retries
        ORDER BY created_at ASC
    """)
    suspend fun getRetryableErrors(sessionId: String): List<ProcessingErrorEntity>

    /**
     * Get retryable errors for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return List of retryable errors.
     */
    @Query("""
        SELECT * FROM processing_errors
        WHERE session_id = :sessionId
        AND step = :step
        AND is_retryable = 1
        AND retry_count < max_retries
        ORDER BY created_at ASC
    """)
    suspend fun getRetryableErrorsByStep(
        sessionId: String,
        step: String
    ): List<ProcessingErrorEntity>

    /**
     * Observe errors for a session as a Flow.
     *
     * @param sessionId The session ID.
     * @return Flow of error lists.
     */
    @Query("""
        SELECT * FROM processing_errors
        WHERE session_id = :sessionId
        ORDER BY created_at DESC
    """)
    fun observeErrors(sessionId: String): Flow<List<ProcessingErrorEntity>>

    /**
     * Observe retryable errors count for a session.
     *
     * @param sessionId The session ID.
     * @return Flow of retryable error count.
     */
    @Query("""
        SELECT COUNT(*) FROM processing_errors
        WHERE session_id = :sessionId
        AND is_retryable = 1
        AND retry_count < max_retries
    """)
    fun observeRetryableCount(sessionId: String): Flow<Int>

    /**
     * Get count of all errors for a session.
     *
     * @param sessionId The session ID.
     * @return Number of errors.
     */
    @Query("SELECT COUNT(*) FROM processing_errors WHERE session_id = :sessionId")
    suspend fun getErrorCount(sessionId: String): Int

    /**
     * Get count of retryable errors for a session.
     *
     * @param sessionId The session ID.
     * @return Number of retryable errors.
     */
    @Query("""
        SELECT COUNT(*) FROM processing_errors
        WHERE session_id = :sessionId
        AND is_retryable = 1
        AND retry_count < max_retries
    """)
    suspend fun getRetryableCount(sessionId: String): Int

    /**
     * Increment retry count for an error.
     *
     * @param id The error ID.
     * @param lastRetryAt Timestamp of the retry attempt.
     */
    @Query("""
        UPDATE processing_errors
        SET retry_count = retry_count + 1, last_retry_at = :lastRetryAt
        WHERE id = :id
    """)
    suspend fun incrementRetryCount(id: String, lastRetryAt: Long)

    /**
     * Delete an error by ID.
     *
     * @param id The error ID.
     */
    @Query("DELETE FROM processing_errors WHERE id = :id")
    suspend fun deleteError(id: String)

    /**
     * Delete all errors for a session.
     *
     * @param sessionId The session ID.
     */
    @Query("DELETE FROM processing_errors WHERE session_id = :sessionId")
    suspend fun deleteErrorsBySession(sessionId: String)

    /**
     * Delete resolved errors (those where retry succeeded or max retries reached).
     *
     * @param sessionId The session ID.
     */
    @Query("""
        DELETE FROM processing_errors
        WHERE session_id = :sessionId
        AND (is_retryable = 0 OR retry_count >= max_retries)
    """)
    suspend fun deleteResolvedErrors(sessionId: String)

    /**
     * Get document IDs that have errors for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return List of document IDs with errors.
     */
    @Query("""
        SELECT DISTINCT document_id FROM processing_errors
        WHERE session_id = :sessionId AND step = :step
    """)
    suspend fun getErrorDocumentIds(sessionId: String, step: String): List<String>
}
