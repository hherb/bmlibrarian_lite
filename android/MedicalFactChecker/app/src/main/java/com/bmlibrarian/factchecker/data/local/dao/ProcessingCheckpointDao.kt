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
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for processing checkpoints.
 *
 * Provides operations for saving and loading checkpoint data to enable
 * workflow resumption after app kill or crash.
 */
@Dao
interface ProcessingCheckpointDao {

    /**
     * Insert or update a checkpoint.
     *
     * Uses REPLACE strategy to update existing checkpoints with same
     * (sessionId, documentId, step) primary key.
     *
     * @param checkpoint The checkpoint to insert or update.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertOrUpdate(checkpoint: ProcessingCheckpointEntity)

    /**
     * Insert or update multiple checkpoints.
     *
     * @param checkpoints The checkpoints to insert or update.
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertOrUpdateAll(checkpoints: List<ProcessingCheckpointEntity>)

    /**
     * Get a specific checkpoint.
     *
     * @param sessionId The session ID.
     * @param documentId The document ID.
     * @param step The processing step.
     * @return The checkpoint, or null if not found.
     */
    @Query("""
        SELECT * FROM processing_checkpoints
        WHERE session_id = :sessionId AND document_id = :documentId AND step = :step
    """)
    suspend fun getCheckpoint(
        sessionId: String,
        documentId: String,
        step: String
    ): ProcessingCheckpointEntity?

    /**
     * Get all checkpoints for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return List of checkpoints.
     */
    @Query("""
        SELECT * FROM processing_checkpoints
        WHERE session_id = :sessionId AND step = :step
        ORDER BY created_at ASC
    """)
    suspend fun getCheckpointsByStep(
        sessionId: String,
        step: String
    ): List<ProcessingCheckpointEntity>

    /**
     * Get all document IDs that have checkpoints for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return Set of checkpointed document IDs.
     */
    @Query("""
        SELECT document_id FROM processing_checkpoints
        WHERE session_id = :sessionId AND step = :step
    """)
    suspend fun getCheckpointedDocumentIds(
        sessionId: String,
        step: String
    ): List<String>

    /**
     * Get count of checkpoints for a session and step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     * @return Number of checkpoints.
     */
    @Query("""
        SELECT COUNT(*) FROM processing_checkpoints
        WHERE session_id = :sessionId AND step = :step
    """)
    suspend fun getCheckpointCount(
        sessionId: String,
        step: String
    ): Int

    /**
     * Get all checkpoints for a session.
     *
     * @param sessionId The session ID.
     * @return List of all checkpoints.
     */
    @Query("""
        SELECT * FROM processing_checkpoints
        WHERE session_id = :sessionId
        ORDER BY created_at ASC
    """)
    suspend fun getAllCheckpoints(sessionId: String): List<ProcessingCheckpointEntity>

    /**
     * Observe checkpoints for a session as a Flow.
     *
     * @param sessionId The session ID.
     * @return Flow of checkpoint lists.
     */
    @Query("""
        SELECT * FROM processing_checkpoints
        WHERE session_id = :sessionId
        ORDER BY created_at ASC
    """)
    fun observeCheckpoints(sessionId: String): Flow<List<ProcessingCheckpointEntity>>

    /**
     * Delete all checkpoints for a session.
     *
     * Call this when a session completes successfully to clean up.
     *
     * @param sessionId The session ID.
     */
    @Query("DELETE FROM processing_checkpoints WHERE session_id = :sessionId")
    suspend fun deleteCheckpoints(sessionId: String)

    /**
     * Delete checkpoints for a specific step.
     *
     * @param sessionId The session ID.
     * @param step The processing step.
     */
    @Query("""
        DELETE FROM processing_checkpoints
        WHERE session_id = :sessionId AND step = :step
    """)
    suspend fun deleteCheckpointsByStep(sessionId: String, step: String)

    /**
     * Delete a specific checkpoint.
     *
     * @param sessionId The session ID.
     * @param documentId The document ID.
     * @param step The processing step.
     */
    @Query("""
        DELETE FROM processing_checkpoints
        WHERE session_id = :sessionId AND document_id = :documentId AND step = :step
    """)
    suspend fun deleteCheckpoint(sessionId: String, documentId: String, step: String)
}
