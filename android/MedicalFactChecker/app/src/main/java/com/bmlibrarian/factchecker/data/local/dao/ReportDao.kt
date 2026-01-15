package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for report operations.
 *
 * Provides CRUD operations and queries for evidence reports.
 * Uses Kotlin Flow for reactive queries that emit on data changes.
 */
@Dao
interface ReportDao {

    // ==================== Insert Operations ====================

    /**
     * Insert a new report, replacing if ID already exists.
     *
     * @param report The report entity to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(report: ReportEntity)

    // ==================== Update Operations ====================

    /**
     * Update an existing report.
     *
     * @param report The report entity with updated values
     */
    @Update
    suspend fun update(report: ReportEntity)

    // ==================== Delete Operations ====================

    /**
     * Delete a report.
     *
     * @param report The report entity to delete
     */
    @Delete
    suspend fun delete(report: ReportEntity)

    /**
     * Delete the report for a session.
     *
     * @param sessionId Session ID
     */
    @Query("DELETE FROM reports WHERE session_id = :sessionId")
    suspend fun deleteBySessionId(sessionId: String)

    // ==================== Query Operations ====================

    /**
     * Get a report by ID.
     *
     * @param id Report ID
     * @return The report or null if not found
     */
    @Query("SELECT * FROM reports WHERE id = :id")
    suspend fun getById(id: String): ReportEntity?

    /**
     * Get the report for a session.
     *
     * @param sessionId Session ID
     * @return The report or null if not found
     */
    @Query("SELECT * FROM reports WHERE session_id = :sessionId")
    suspend fun getBySessionId(sessionId: String): ReportEntity?

    /**
     * Get the report for a session as a Flow (reactive).
     *
     * @param sessionId Session ID
     * @return Flow emitting report updates
     */
    @Query("SELECT * FROM reports WHERE session_id = :sessionId")
    fun getBySessionIdFlow(sessionId: String): Flow<ReportEntity?>

    /**
     * Get all reports ordered by creation date (newest first).
     *
     * @return Flow emitting list of all reports
     */
    @Query("SELECT * FROM reports ORDER BY created_at DESC")
    fun getAllReports(): Flow<List<ReportEntity>>

    /**
     * Check if a report exists for a session.
     *
     * @param sessionId Session ID
     * @return true if report exists
     */
    @Query("SELECT EXISTS(SELECT 1 FROM reports WHERE session_id = :sessionId)")
    suspend fun existsForSession(sessionId: String): Boolean

    // ==================== Count Operations ====================

    /**
     * Count total reports.
     *
     * @return Total number of reports
     */
    @Query("SELECT COUNT(*) FROM reports")
    suspend fun count(): Int
}
