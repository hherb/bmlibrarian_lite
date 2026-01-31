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
import androidx.room.Delete
import androidx.room.Embedded
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Relation
import androidx.room.Update
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.Flow

/**
 * Data class for session with embedded report from JOIN query.
 *
 * Used to efficiently fetch sessions with their reports in a single query,
 * avoiding N+1 query problems.
 */
data class SessionWithReportResult(
    @Embedded val session: SessionEntity,
    @Relation(
        parentColumn = "id",
        entityColumn = "session_id"
    )
    val report: ReportEntity?
)

/**
 * Data Access Object for session operations.
 *
 * Provides CRUD operations and queries for fact-check sessions.
 * Uses Kotlin Flow for reactive queries that emit on data changes.
 */
@Dao
interface SessionDao {

    // ==================== Insert Operations ====================

    /**
     * Insert a new session, replacing if ID already exists.
     *
     * @param session The session entity to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(session: SessionEntity)

    // ==================== Update Operations ====================

    /**
     * Update an existing session.
     *
     * @param session The session entity with updated values
     */
    @Update
    suspend fun update(session: SessionEntity)

    /**
     * Update only the workflow step for a session.
     *
     * @param id Session ID
     * @param step New workflow step
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions
        SET workflow_step = :step, updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun updateWorkflowStep(
        id: String,
        step: WorkflowStep,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Add token usage to a session's running totals.
     *
     * @param id Session ID
     * @param inputTokens Input tokens to add
     * @param outputTokens Output tokens to add
     * @param cost Cost to add in USD
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            total_input_tokens = total_input_tokens + :inputTokens,
            total_output_tokens = total_output_tokens + :outputTokens,
            estimated_cost_usd = estimated_cost_usd + :cost,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun addTokenUsage(
        id: String,
        inputTokens: Int,
        outputTokens: Int,
        cost: Double,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Update the PubMed query for a session.
     *
     * @param id Session ID
     * @param query The generated PubMed query
     * @param alternativeQuery Optional alternative query suggestion
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            pubmed_query = :query,
            alternative_query = :alternativeQuery,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun updateQuery(
        id: String,
        query: String,
        alternativeQuery: String?,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Update PubMed pagination state.
     *
     * @param id Session ID
     * @param offset New offset value
     * @param totalResults Total available results
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            pubmed_offset = :offset,
            pubmed_total_results = :totalResults,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun updatePubMedPagination(
        id: String,
        offset: Int,
        totalResults: Int,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Update Europe PMC pagination state.
     *
     * @param id Session ID
     * @param cursor New cursor value (null if no more pages)
     * @param totalResults Total available results
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            epmc_cursor = :cursor,
            epmc_total_results = :totalResults,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun updateEpmcPagination(
        id: String,
        cursor: String?,
        totalResults: Int,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Set error message and mark session as failed.
     *
     * @param id Session ID
     * @param errorMessage The error message
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            error_message = :errorMessage,
            workflow_step = 'FAILED',
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun setError(
        id: String,
        errorMessage: String,
        updatedAt: Long = System.currentTimeMillis()
    )

    /**
     * Update HyDE (Hypothetical Document Embedding) abstract.
     *
     * @param id Session ID
     * @param hydeAbstract The generated hypothetical abstract
     * @param generatedAt Timestamp when HyDE was generated
     * @param updatedAt Timestamp for the update
     */
    @Query("""
        UPDATE sessions SET
            hyde_abstract = :hydeAbstract,
            hyde_generated_at = :generatedAt,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun updateHydeAbstract(
        id: String,
        hydeAbstract: String,
        generatedAt: Long = System.currentTimeMillis(),
        updatedAt: Long = System.currentTimeMillis()
    )

    // ==================== Delete Operations ====================

    /**
     * Delete a session.
     *
     * @param session The session entity to delete
     */
    @Delete
    suspend fun delete(session: SessionEntity)

    /**
     * Delete a session by ID.
     *
     * @param id Session ID to delete
     */
    @Query("DELETE FROM sessions WHERE id = :id")
    suspend fun deleteById(id: String)

    /**
     * Delete all sessions.
     */
    @Query("DELETE FROM sessions")
    suspend fun deleteAll()

    // ==================== Query Operations ====================

    /**
     * Get a session by ID.
     *
     * @param id Session ID
     * @return The session or null if not found
     */
    @Query("SELECT * FROM sessions WHERE id = :id")
    suspend fun getById(id: String): SessionEntity?

    /**
     * Get a session by ID as a Flow (reactive).
     *
     * @param id Session ID
     * @return Flow emitting session updates
     */
    @Query("SELECT * FROM sessions WHERE id = :id")
    fun getByIdFlow(id: String): Flow<SessionEntity?>

    /**
     * Get all sessions ordered by creation date (newest first).
     *
     * @return Flow emitting list of all sessions
     */
    @Query("SELECT * FROM sessions ORDER BY created_at DESC")
    fun getAllSessions(): Flow<List<SessionEntity>>

    /**
     * Get sessions by workflow step.
     *
     * @param step The workflow step to filter by
     * @return Flow emitting sessions in the specified step
     */
    @Query("SELECT * FROM sessions WHERE workflow_step = :step ORDER BY created_at DESC")
    fun getSessionsByStep(step: WorkflowStep): Flow<List<SessionEntity>>

    /**
     * Get completed sessions.
     *
     * @return Flow emitting completed sessions
     */
    @Query("SELECT * FROM sessions WHERE workflow_step = 'COMPLETED' ORDER BY created_at DESC")
    fun getCompletedSessions(): Flow<List<SessionEntity>>

    /**
     * Get sessions that are in progress (not terminal).
     *
     * @return Flow emitting in-progress sessions
     */
    @Query("""
        SELECT * FROM sessions
        WHERE workflow_step NOT IN ('COMPLETED', 'FAILED', 'BUDGET_EXCEEDED')
        ORDER BY updated_at DESC
    """)
    fun getInProgressSessions(): Flow<List<SessionEntity>>

    /**
     * Count total sessions.
     *
     * @return Total number of sessions
     */
    @Query("SELECT COUNT(*) FROM sessions")
    suspend fun count(): Int

    /**
     * Count completed sessions.
     *
     * @return Number of completed sessions
     */
    @Query("SELECT COUNT(*) FROM sessions WHERE workflow_step = 'COMPLETED'")
    suspend fun countCompleted(): Int

    // ==================== Relation Queries ====================

    /**
     * Get completed sessions with their reports in a single query.
     *
     * Uses Room's @Relation to efficiently fetch sessions with their
     * associated reports, avoiding N+1 query problems.
     *
     * @return Flow emitting sessions with their reports
     */
    @androidx.room.Transaction
    @Query("SELECT * FROM sessions WHERE workflow_step = 'COMPLETED' ORDER BY created_at DESC")
    fun getCompletedSessionsWithReports(): Flow<List<SessionWithReportResult>>
}
