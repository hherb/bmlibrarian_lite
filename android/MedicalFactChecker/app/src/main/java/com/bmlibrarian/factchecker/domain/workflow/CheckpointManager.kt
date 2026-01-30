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

import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Manages checkpoint persistence for resumable document processing.
 *
 * Provides thread-safe operations for saving and loading processing
 * checkpoints. Checkpoints enable workflow resumption if the app is
 * killed or crashes during long-running operations.
 *
 * Mirrors iOS CheckpointManager for cross-platform consistency.
 *
 * Usage:
 * ```kotlin
 * val manager = CheckpointManager(checkpointDao)
 *
 * // Save a checkpoint after scoring
 * manager.saveScoringCheckpoint(
 *     sessionId = sessionId,
 *     result = scoringResult
 * )
 *
 * // Load checkpoints on resume
 * val checkpointed = manager.getCheckpointedDocumentIds(sessionId, "scoring")
 * val savedResults = manager.loadScoringCheckpoints(sessionId)
 * ```
 */
@Singleton
class CheckpointManager @Inject constructor(
    private val checkpointDao: ProcessingCheckpointDao
) {
    private val json = Json {
        ignoreUnknownKeys = true
        encodeDefaults = true
    }

    // ==================== Scoring Checkpoints ====================

    /**
     * Save a scoring checkpoint for a document.
     *
     * @param sessionId The session identifier.
     * @param result The scoring result to persist.
     */
    suspend fun saveScoringCheckpoint(
        sessionId: String,
        result: ScoringResult
    ) {
        val checkpoint = ProcessingCheckpointEntity(
            sessionId = sessionId,
            documentId = result.documentId,
            step = ProcessingCheckpointEntity.STEP_SCORING,
            resultJson = json.encodeToString(result),
            createdAt = Date()
        )
        checkpointDao.insertOrUpdate(checkpoint)
    }

    /**
     * Save multiple scoring checkpoints.
     *
     * @param sessionId The session identifier.
     * @param results The scoring results to persist.
     */
    suspend fun saveScoringCheckpoints(
        sessionId: String,
        results: List<ScoringResult>
    ) {
        val checkpoints = results.map { result ->
            ProcessingCheckpointEntity(
                sessionId = sessionId,
                documentId = result.documentId,
                step = ProcessingCheckpointEntity.STEP_SCORING,
                resultJson = json.encodeToString(result),
                createdAt = Date()
            )
        }
        checkpointDao.insertOrUpdateAll(checkpoints)
    }

    /**
     * Load a scoring checkpoint for a document.
     *
     * @param sessionId The session identifier.
     * @param documentId The document identifier.
     * @return The scoring result, or null if not found.
     */
    suspend fun loadScoringCheckpoint(
        sessionId: String,
        documentId: String
    ): ScoringResult? {
        val checkpoint = checkpointDao.getCheckpoint(
            sessionId = sessionId,
            documentId = documentId,
            step = ProcessingCheckpointEntity.STEP_SCORING
        ) ?: return null

        return try {
            json.decodeFromString<ScoringResult>(checkpoint.resultJson)
        } catch (e: Exception) {
            null
        }
    }

    /**
     * Load all scoring checkpoints for a session.
     *
     * @param sessionId The session identifier.
     * @return List of scoring results.
     */
    suspend fun loadScoringCheckpoints(sessionId: String): List<ScoringResult> {
        val checkpoints = checkpointDao.getCheckpointsByStep(
            sessionId = sessionId,
            step = ProcessingCheckpointEntity.STEP_SCORING
        )

        return checkpoints.mapNotNull { checkpoint ->
            try {
                json.decodeFromString<ScoringResult>(checkpoint.resultJson)
            } catch (e: Exception) {
                null
            }
        }
    }

    // ==================== Citation Checkpoints ====================

    /**
     * Save a citation extraction checkpoint.
     *
     * @param sessionId The session identifier.
     * @param documentId The document identifier.
     * @param citations The extracted citations as JSON.
     */
    suspend fun saveCitationCheckpoint(
        sessionId: String,
        documentId: String,
        citations: String
    ) {
        val checkpoint = ProcessingCheckpointEntity(
            sessionId = sessionId,
            documentId = documentId,
            step = ProcessingCheckpointEntity.STEP_CITATION,
            resultJson = citations,
            createdAt = Date()
        )
        checkpointDao.insertOrUpdate(checkpoint)
    }

    /**
     * Load citation checkpoint for a document.
     *
     * @param sessionId The session identifier.
     * @param documentId The document identifier.
     * @return The citations JSON, or null if not found.
     */
    suspend fun loadCitationCheckpoint(
        sessionId: String,
        documentId: String
    ): String? {
        val checkpoint = checkpointDao.getCheckpoint(
            sessionId = sessionId,
            documentId = documentId,
            step = ProcessingCheckpointEntity.STEP_CITATION
        )
        return checkpoint?.resultJson
    }

    // ==================== General Operations ====================

    /**
     * Get all document IDs that have been checkpointed for a session and step.
     *
     * Used to determine which documents can be skipped on session resume.
     *
     * @param sessionId The session identifier.
     * @param step Processing step ("scoring" or "citation").
     * @return Set of checkpointed document IDs.
     */
    suspend fun getCheckpointedDocumentIds(
        sessionId: String,
        step: String
    ): Set<String> {
        return checkpointDao.getCheckpointedDocumentIds(sessionId, step).toSet()
    }

    /**
     * Get the count of checkpoints for a session and step.
     *
     * Useful for progress reporting when resuming a session.
     *
     * @param sessionId The session identifier.
     * @param step Processing step ("scoring" or "citation").
     * @return Number of checkpoints.
     */
    suspend fun getCheckpointCount(
        sessionId: String,
        step: String
    ): Int {
        return checkpointDao.getCheckpointCount(sessionId, step)
    }

    /**
     * Check if a session has any checkpoints.
     *
     * @param sessionId The session identifier.
     * @return true if checkpoints exist.
     */
    suspend fun hasCheckpoints(sessionId: String): Boolean {
        return checkpointDao.getAllCheckpoints(sessionId).isNotEmpty()
    }

    /**
     * Delete all checkpoints for a session.
     *
     * Call this when a session completes successfully to clean up checkpoint data.
     *
     * @param sessionId The session identifier.
     */
    suspend fun deleteCheckpoints(sessionId: String) {
        checkpointDao.deleteCheckpoints(sessionId)
    }

    /**
     * Delete checkpoints for a specific step.
     *
     * @param sessionId The session identifier.
     * @param step Processing step to clear.
     */
    suspend fun deleteCheckpointsByStep(sessionId: String, step: String) {
        checkpointDao.deleteCheckpointsByStep(sessionId, step)
    }
}
