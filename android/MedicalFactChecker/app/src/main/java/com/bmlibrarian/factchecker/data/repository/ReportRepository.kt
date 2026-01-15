package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.domain.model.Verdict
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing evidence reports.
 *
 * Provides a clean API for report operations, abstracting the
 * underlying DAO implementation.
 *
 * @param reportDao The Report DAO for database operations
 */
@Singleton
class ReportRepository @Inject constructor(
    private val reportDao: ReportDao
) {

    // ==================== Query Operations ====================

    /**
     * Get the report for a session as a Flow.
     *
     * @param sessionId Session ID
     * @return Flow emitting report updates, or null if not found
     */
    fun getReportBySessionFlow(sessionId: String): Flow<ReportEntity?> =
        reportDao.getBySessionIdFlow(sessionId)

    /**
     * Get the report for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return The report or null if not found
     */
    suspend fun getReportBySession(sessionId: String): ReportEntity? =
        reportDao.getBySessionId(sessionId)

    /**
     * Get a report by ID.
     *
     * @param id Report ID
     * @return The report or null if not found
     */
    suspend fun getReport(id: String): ReportEntity? = reportDao.getById(id)

    /**
     * Get all reports as a Flow.
     *
     * @return Flow emitting list of all reports
     */
    fun getAllReports(): Flow<List<ReportEntity>> = reportDao.getAllReports()

    /**
     * Check if a report exists for a session.
     *
     * @param sessionId Session ID
     * @return true if report exists
     */
    suspend fun hasReport(sessionId: String): Boolean =
        reportDao.existsForSession(sessionId)

    // ==================== Write Operations ====================

    /**
     * Save a report.
     *
     * @param report The report to save
     */
    suspend fun saveReport(report: ReportEntity) {
        reportDao.insert(report)
    }

    /**
     * Create and save a new report.
     *
     * @param sessionId Session ID this report belongs to
     * @param verdict The overall verdict
     * @param summary Brief summary of the evidence
     * @param fullReportMarkdown Full report in markdown format
     * @param footnotes Footnotes with citation details
     * @param modelUsed LLM model that generated the report
     * @param totalDocumentsReviewed Total documents reviewed
     * @param relevantDocumentsCount Documents meeting relevance threshold
     * @param citationsCount Citations included in report
     * @return The created report entity
     */
    suspend fun createReport(
        sessionId: String,
        verdict: Verdict,
        summary: String,
        fullReportMarkdown: String,
        footnotes: String?,
        modelUsed: String,
        totalDocumentsReviewed: Int,
        relevantDocumentsCount: Int,
        citationsCount: Int
    ): ReportEntity {
        val report = ReportEntity(
            sessionId = sessionId,
            verdict = verdict,
            summary = summary,
            fullReportMarkdown = fullReportMarkdown,
            footnotes = footnotes,
            modelUsed = modelUsed,
            totalDocumentsReviewed = totalDocumentsReviewed,
            relevantDocumentsCount = relevantDocumentsCount,
            citationsCount = citationsCount
        )
        reportDao.insert(report)
        return report
    }

    /**
     * Update an existing report.
     *
     * @param report The report with updated values
     */
    suspend fun updateReport(report: ReportEntity) {
        reportDao.update(report)
    }

    // ==================== Delete Operations ====================

    /**
     * Delete the report for a session.
     *
     * @param sessionId Session ID
     */
    suspend fun deleteReportBySession(sessionId: String) {
        reportDao.deleteBySessionId(sessionId)
    }

    // ==================== Statistics ====================

    /**
     * Get total report count.
     *
     * @return Number of reports
     */
    suspend fun getReportCount(): Int = reportDao.count()
}
