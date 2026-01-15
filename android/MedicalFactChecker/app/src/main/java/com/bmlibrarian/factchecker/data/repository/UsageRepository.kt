package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.ModelUsageStats
import com.bmlibrarian.factchecker.data.local.dao.UsageRecordDao
import com.bmlibrarian.factchecker.data.local.entity.UsageRecordEntity
import kotlinx.coroutines.flow.Flow
import java.util.Calendar
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing API usage records.
 *
 * Provides a clean API for tracking and querying LLM API usage
 * and costs. Used for budget enforcement and usage statistics.
 *
 * @param usageRecordDao The Usage Record DAO for database operations
 */
@Singleton
class UsageRepository @Inject constructor(
    private val usageRecordDao: UsageRecordDao
) {

    // ==================== Record Operations ====================

    /**
     * Record API usage.
     *
     * @param sessionId Session ID (optional)
     * @param provider LLM provider name
     * @param model Model identifier
     * @param operation Type of operation
     * @param inputTokens Input tokens consumed
     * @param outputTokens Output tokens generated
     * @param costUsd Estimated cost in USD
     */
    suspend fun recordUsage(
        sessionId: String?,
        provider: String,
        model: String,
        operation: String,
        inputTokens: Int,
        outputTokens: Int,
        costUsd: Double
    ) {
        val record = UsageRecordEntity(
            sessionId = sessionId,
            provider = provider,
            model = model,
            operation = operation,
            inputTokens = inputTokens,
            outputTokens = outputTokens,
            costUsd = costUsd
        )
        usageRecordDao.insert(record)
    }

    /**
     * Record API usage with a pre-built entity.
     *
     * @param record The usage record to save
     */
    suspend fun recordUsage(record: UsageRecordEntity) {
        usageRecordDao.insert(record)
    }

    // ==================== Query Operations ====================

    /**
     * Get usage records for a session as a Flow.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of usage records
     */
    fun getUsageBySession(sessionId: String): Flow<List<UsageRecordEntity>> =
        usageRecordDao.getBySessionId(sessionId)

    /**
     * Get usage records for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of usage records
     */
    suspend fun getUsageBySessionSync(sessionId: String): List<UsageRecordEntity> =
        usageRecordDao.getBySessionIdSync(sessionId)

    /**
     * Get usage records by operation type.
     *
     * @param operation Operation type
     * @return List of usage records
     */
    suspend fun getUsageByOperation(operation: String): List<UsageRecordEntity> =
        usageRecordDao.getByOperation(operation)

    // ==================== Cost Queries ====================

    /**
     * Get total spend for a session.
     *
     * @param sessionId Session ID
     * @return Total cost in USD, or 0.0 if no records
     */
    suspend fun getSessionSpend(sessionId: String): Double =
        usageRecordDao.getSessionSpend(sessionId) ?: 0.0

    /**
     * Get spend for the current month.
     *
     * @return Total cost in USD for the current month, or 0.0 if no records
     */
    suspend fun getCurrentMonthSpend(): Double {
        val calendar = Calendar.getInstance().apply {
            set(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return usageRecordDao.getMonthlySpend(calendar.timeInMillis) ?: 0.0
    }

    /**
     * Get spend for a specific month.
     *
     * @param year Year (e.g., 2024)
     * @param month Month (1-12)
     * @return Total cost in USD for the month, or 0.0 if no records
     */
    suspend fun getMonthSpend(year: Int, month: Int): Double {
        val calendar = Calendar.getInstance().apply {
            set(Calendar.YEAR, year)
            set(Calendar.MONTH, month - 1) // Calendar months are 0-indexed
            set(Calendar.DAY_OF_MONTH, 1)
            set(Calendar.HOUR_OF_DAY, 0)
            set(Calendar.MINUTE, 0)
            set(Calendar.SECOND, 0)
            set(Calendar.MILLISECOND, 0)
        }
        return usageRecordDao.getMonthlySpend(calendar.timeInMillis) ?: 0.0
    }

    /**
     * Get total spend for all time.
     *
     * @return Total cost in USD, or 0.0 if no records
     */
    suspend fun getTotalSpend(): Double =
        usageRecordDao.getTotalSpend() ?: 0.0

    // ==================== Token Queries ====================

    /**
     * Get total tokens used for a session.
     *
     * @param sessionId Session ID
     * @return Pair of (inputTokens, outputTokens)
     */
    suspend fun getSessionTokens(sessionId: String): Pair<Int, Int> {
        val sums = usageRecordDao.getSessionTokens(sessionId)
        return Pair(sums.inputTokens, sums.outputTokens)
    }

    // ==================== Statistics ====================

    /**
     * Get usage statistics by model.
     *
     * @return List of model usage statistics
     */
    suspend fun getUsageByModel(): List<ModelUsageStats> =
        usageRecordDao.getUsageByModel()

    /**
     * Get total record count.
     *
     * @return Number of usage records
     */
    suspend fun getRecordCount(): Int = usageRecordDao.count()

    /**
     * Get record count for a session.
     *
     * @param sessionId Session ID
     * @return Number of usage records
     */
    suspend fun getRecordCountForSession(sessionId: String): Int =
        usageRecordDao.countBySessionId(sessionId)

    // ==================== Cleanup Operations ====================

    /**
     * Delete old usage records.
     *
     * @param daysOld Delete records older than this many days
     */
    suspend fun deleteOldRecords(daysOld: Int) {
        val calendar = Calendar.getInstance().apply {
            add(Calendar.DAY_OF_YEAR, -daysOld)
        }
        usageRecordDao.deleteOldRecords(calendar.timeInMillis)
    }

    /**
     * Delete all usage records for a session.
     *
     * @param sessionId Session ID
     */
    suspend fun deleteUsageBySession(sessionId: String) {
        usageRecordDao.deleteBySessionId(sessionId)
    }
}
