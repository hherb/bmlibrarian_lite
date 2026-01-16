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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.util.Constants
import java.util.Date

/**
 * Domain model for an evidence report.
 *
 * Provides a cleaner interface than the entity for use in the UI layer.
 */
data class EvidenceReport(
    /** Unique identifier. */
    val id: String,

    /** Session this report belongs to. */
    val sessionId: String,

    /** Overall verdict. */
    val verdict: Verdict,

    /** Brief summary. */
    val summary: String,

    /** Full markdown report. */
    val fullReportMarkdown: String,

    /** Footnotes section. */
    val footnotes: String?,

    /** Model that generated the report. */
    val modelUsed: String,

    /** Total documents reviewed. */
    val totalDocumentsReviewed: Int,

    /** Relevant document count. */
    val relevantDocumentsCount: Int,

    /** Citation count. */
    val citationsCount: Int,

    /** When report was created. */
    val createdAt: Date
) {
    /**
     * Get a preview of the summary.
     *
     * @param maxLength Maximum length for the preview
     * @return Truncated summary with ellipsis if needed
     */
    fun summaryPreview(maxLength: Int = Constants.DEFAULT_SUMMARY_PREVIEW_LENGTH): String {
        return if (summary.length <= maxLength) {
            summary
        } else {
            "${summary.take(maxLength - 3)}..."
        }
    }

    /**
     * Get statistics string for display.
     */
    val statisticsString: String
        get() = "Reviewed $totalDocumentsReviewed documents, " +
                "$relevantDocumentsCount relevant, " +
                "$citationsCount citations"

    /**
     * Get verdict display color.
     */
    val verdictColor get() = verdict.color

    /**
     * Get verdict display name.
     */
    val verdictDisplayName get() = verdict.displayName

    companion object {
        /**
         * Create a domain model from an entity.
         *
         * @param entity The report entity from the database
         * @return The domain model representation
         */
        fun fromEntity(entity: ReportEntity): EvidenceReport {
            return EvidenceReport(
                id = entity.id,
                sessionId = entity.sessionId,
                verdict = entity.verdict,
                summary = entity.summary,
                fullReportMarkdown = entity.fullReportMarkdown,
                footnotes = entity.footnotes,
                modelUsed = entity.modelUsed,
                totalDocumentsReviewed = entity.totalDocumentsReviewed,
                relevantDocumentsCount = entity.relevantDocumentsCount,
                citationsCount = entity.citationsCount,
                createdAt = entity.createdAt
            )
        }
    }
}

/**
 * Extension function to convert ReportEntity to domain model.
 */
fun ReportEntity.toDomain(): EvidenceReport = EvidenceReport.fromEntity(this)

/**
 * Extension function to convert list of ReportEntity to domain models.
 */
fun List<ReportEntity>.toDomainReports(): List<EvidenceReport> = map { it.toDomain() }
