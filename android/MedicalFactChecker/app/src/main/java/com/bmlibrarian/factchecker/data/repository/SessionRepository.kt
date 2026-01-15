package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.Flow
import java.util.Date
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing fact-check sessions.
 *
 * Provides a clean API for session operations, abstracting the
 * underlying DAO implementation. All operations are suspend functions
 * for coroutine-based async execution.
 *
 * @param sessionDao The Session DAO for database operations
 */
@Singleton
class SessionRepository @Inject constructor(
    private val sessionDao: SessionDao
) {

    // ==================== Query Operations ====================

    /**
     * Get all sessions as a Flow.
     *
     * @return Flow emitting list of sessions ordered by creation date (newest first)
     */
    fun getAllSessions(): Flow<List<SessionEntity>> = sessionDao.getAllSessions()

    /**
     * Get completed sessions as a Flow.
     *
     * @return Flow emitting list of completed sessions
     */
    fun getCompletedSessions(): Flow<List<SessionEntity>> = sessionDao.getCompletedSessions()

    /**
     * Get in-progress sessions as a Flow.
     *
     * @return Flow emitting list of sessions that are not in terminal state
     */
    fun getInProgressSessions(): Flow<List<SessionEntity>> = sessionDao.getInProgressSessions()

    /**
     * Get a session by ID as a Flow (reactive).
     *
     * @param id Session ID
     * @return Flow emitting session updates, or null if not found
     */
    fun getSessionFlow(id: String): Flow<SessionEntity?> = sessionDao.getByIdFlow(id)

    /**
     * Get a session by ID (non-reactive).
     *
     * @param id Session ID
     * @return The session or null if not found
     */
    suspend fun getSession(id: String): SessionEntity? = sessionDao.getById(id)

    // ==================== Create Operations ====================

    /**
     * Create a new fact-check session.
     *
     * @param claimText The user's claim to fact-check
     * @param searchProvider The search provider to use
     * @param includePreprints Whether to include preprints
     * @return The created session entity
     */
    suspend fun createSession(
        claimText: String,
        searchProvider: SearchProvider = SearchProvider.PUBMED,
        includePreprints: Boolean = false
    ): SessionEntity {
        val session = SessionEntity(
            claimText = claimText,
            searchProvider = searchProvider,
            includePreprints = includePreprints
        )
        sessionDao.insert(session)
        return session
    }

    // ==================== Update Operations ====================

    /**
     * Update a session.
     *
     * @param session The session with updated values
     */
    suspend fun updateSession(session: SessionEntity) {
        sessionDao.update(session.copy(updatedAt = Date()))
    }

    /**
     * Update the workflow step for a session.
     *
     * @param sessionId Session ID
     * @param step New workflow step
     */
    suspend fun updateWorkflowStep(sessionId: String, step: WorkflowStep) {
        sessionDao.updateWorkflowStep(sessionId, step)
    }

    /**
     * Update the PubMed query for a session.
     *
     * @param sessionId Session ID
     * @param query The generated PubMed query
     * @param alternativeQuery Optional alternative query suggestion
     */
    suspend fun updateQuery(sessionId: String, query: String, alternativeQuery: String? = null) {
        sessionDao.updateQuery(sessionId, query, alternativeQuery)
    }

    /**
     * Update PubMed pagination state.
     *
     * @param sessionId Session ID
     * @param offset New offset value
     * @param totalResults Total available results
     */
    suspend fun updatePubMedPagination(sessionId: String, offset: Int, totalResults: Int) {
        sessionDao.updatePubMedPagination(sessionId, offset, totalResults)
    }

    /**
     * Update Europe PMC pagination state.
     *
     * @param sessionId Session ID
     * @param cursor New cursor value (null if no more pages)
     * @param totalResults Total available results
     */
    suspend fun updateEpmcPagination(sessionId: String, cursor: String?, totalResults: Int) {
        sessionDao.updateEpmcPagination(sessionId, cursor, totalResults)
    }

    /**
     * Add token usage to a session.
     *
     * @param sessionId Session ID
     * @param inputTokens Input tokens consumed
     * @param outputTokens Output tokens generated
     * @param cost Cost in USD
     */
    suspend fun addTokenUsage(
        sessionId: String,
        inputTokens: Int,
        outputTokens: Int,
        cost: Double
    ) {
        sessionDao.addTokenUsage(sessionId, inputTokens, outputTokens, cost)
    }

    /**
     * Mark a session as failed with an error message.
     *
     * @param sessionId Session ID
     * @param errorMessage The error message
     */
    suspend fun setError(sessionId: String, errorMessage: String) {
        sessionDao.setError(sessionId, errorMessage)
    }

    // ==================== Delete Operations ====================

    /**
     * Delete a session by ID.
     *
     * Note: Due to CASCADE foreign key constraints, this will also
     * delete all associated documents, citations, and reports.
     *
     * @param sessionId Session ID to delete
     */
    suspend fun deleteSession(sessionId: String) {
        sessionDao.deleteById(sessionId)
    }

    /**
     * Delete all sessions.
     *
     * Warning: This deletes all data in the database.
     */
    suspend fun deleteAllSessions() {
        sessionDao.deleteAll()
    }

    // ==================== Statistics ====================

    /**
     * Get total session count.
     *
     * @return Number of sessions
     */
    suspend fun getSessionCount(): Int = sessionDao.count()

    /**
     * Get completed session count.
     *
     * @return Number of completed sessions
     */
    suspend fun getCompletedSessionCount(): Int = sessionDao.countCompleted()
}
