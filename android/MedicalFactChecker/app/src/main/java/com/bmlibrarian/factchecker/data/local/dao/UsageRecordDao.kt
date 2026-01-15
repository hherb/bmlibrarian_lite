package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.Query
import com.bmlibrarian.factchecker.data.local.entity.UsageRecordEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for usage record operations.
 *
 * Provides operations for tracking and querying API usage and costs.
 * Used for budget enforcement and usage statistics.
 */
@Dao
interface UsageRecordDao {

    // ==================== Insert Operations ====================

    /**
     * Insert a new usage record.
     *
     * @param record The usage record entity to insert
     */
    @Insert
    suspend fun insert(record: UsageRecordEntity)

    // ==================== Query Operations ====================

    /**
     * Get all usage records for a session.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of usage records
     */
    @Query("SELECT * FROM usage_records WHERE session_id = :sessionId ORDER BY created_at")
    fun getBySessionId(sessionId: String): Flow<List<UsageRecordEntity>>

    /**
     * Get all usage records for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of usage records
     */
    @Query("SELECT * FROM usage_records WHERE session_id = :sessionId ORDER BY created_at")
    suspend fun getBySessionIdSync(sessionId: String): List<UsageRecordEntity>

    /**
     * Get total spend for a session.
     *
     * @param sessionId Session ID
     * @return Total cost in USD, or null if no records
     */
    @Query("SELECT SUM(cost_usd) FROM usage_records WHERE session_id = :sessionId")
    suspend fun getSessionSpend(sessionId: String): Double?

    /**
     * Get monthly spend since a given start date.
     *
     * @param startOfMonth Timestamp for start of month (millis since epoch)
     * @return Total cost in USD for the period, or null if no records
     */
    @Query("SELECT SUM(cost_usd) FROM usage_records WHERE created_at >= :startOfMonth")
    suspend fun getMonthlySpend(startOfMonth: Long): Double?

    /**
     * Get total spend for all time.
     *
     * @return Total cost in USD, or null if no records
     */
    @Query("SELECT SUM(cost_usd) FROM usage_records")
    suspend fun getTotalSpend(): Double?

    /**
     * Get total tokens used for a session.
     *
     * @param sessionId Session ID
     * @return TokenSums containing input and output token totals
     */
    @Query("""
        SELECT
            COALESCE(SUM(input_tokens), 0) AS inputTokens,
            COALESCE(SUM(output_tokens), 0) AS outputTokens
        FROM usage_records
        WHERE session_id = :sessionId
    """)
    suspend fun getSessionTokens(sessionId: String): TokenSums

    /**
     * Get usage records by operation type.
     *
     * @param operation Operation type (e.g., "scoring", "report")
     * @return List of usage records for that operation
     */
    @Query("SELECT * FROM usage_records WHERE operation = :operation ORDER BY created_at DESC")
    suspend fun getByOperation(operation: String): List<UsageRecordEntity>

    /**
     * Get usage statistics by model.
     *
     * @return List of model usage statistics
     */
    @Query("""
        SELECT
            model,
            COUNT(*) as callCount,
            SUM(input_tokens) as totalInputTokens,
            SUM(output_tokens) as totalOutputTokens,
            SUM(cost_usd) as totalCost
        FROM usage_records
        GROUP BY model
        ORDER BY totalCost DESC
    """)
    suspend fun getUsageByModel(): List<ModelUsageStats>

    // ==================== Delete Operations ====================

    /**
     * Delete old usage records.
     *
     * @param beforeDate Delete records created before this timestamp
     */
    @Query("DELETE FROM usage_records WHERE created_at < :beforeDate")
    suspend fun deleteOldRecords(beforeDate: Long)

    /**
     * Delete all usage records for a session.
     *
     * @param sessionId Session ID
     */
    @Query("DELETE FROM usage_records WHERE session_id = :sessionId")
    suspend fun deleteBySessionId(sessionId: String)

    // ==================== Count Operations ====================

    /**
     * Count total usage records.
     *
     * @return Total number of records
     */
    @Query("SELECT COUNT(*) FROM usage_records")
    suspend fun count(): Int

    /**
     * Count usage records for a session.
     *
     * @param sessionId Session ID
     * @return Number of records
     */
    @Query("SELECT COUNT(*) FROM usage_records WHERE session_id = :sessionId")
    suspend fun countBySessionId(sessionId: String): Int
}

/**
 * Data class for token sum query results.
 */
data class TokenSums(
    val inputTokens: Int,
    val outputTokens: Int
)

/**
 * Data class for model usage statistics query results.
 */
data class ModelUsageStats(
    val model: String,
    val callCount: Int,
    val totalInputTokens: Int,
    val totalOutputTokens: Int,
    val totalCost: Double
)
