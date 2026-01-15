package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.bmlibrarian.factchecker.domain.model.Verdict
import java.util.Date
import java.util.UUID

/**
 * Room entity for generated evidence reports.
 *
 * Represents the final output of a fact-checking workflow, containing
 * the verdict, summary, and full markdown report with citations.
 *
 * Mirrors iOS EvidenceReport model for cross-platform consistency.
 */
@Entity(
    tableName = "reports",
    foreignKeys = [
        ForeignKey(
            entity = SessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["session_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["session_id"], unique = true)
    ]
)
data class ReportEntity(
    /** Unique identifier for this report. */
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    /** ID of the session this report belongs to. */
    @ColumnInfo(name = "session_id")
    val sessionId: String,

    /** Overall verdict for the claim. */
    @ColumnInfo(name = "verdict")
    val verdict: Verdict,

    /** Brief summary of the evidence (1-2 sentences). */
    @ColumnInfo(name = "summary")
    val summary: String,

    /** Full report in markdown format with inline citations. */
    @ColumnInfo(name = "full_report_markdown")
    val fullReportMarkdown: String,

    /** Footnotes section with full citation details. */
    @ColumnInfo(name = "footnotes")
    val footnotes: String? = null,

    /** LLM model used to generate this report. */
    @ColumnInfo(name = "model_used")
    val modelUsed: String,

    /** Total number of documents reviewed. */
    @ColumnInfo(name = "total_documents_reviewed")
    val totalDocumentsReviewed: Int,

    /** Number of documents that met relevance threshold. */
    @ColumnInfo(name = "relevant_documents_count")
    val relevantDocumentsCount: Int,

    /** Number of citations included in the report. */
    @ColumnInfo(name = "citations_count")
    val citationsCount: Int,

    /** When this report was generated. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    /**
     * Get a preview of the summary for list display.
     *
     * @param maxLength Maximum length for the preview
     * @return Truncated summary with ellipsis if needed
     */
    fun summaryPreview(maxLength: Int = 200): String {
        return if (summary.length <= maxLength) {
            summary
        } else {
            "${summary.take(maxLength - 3)}..."
        }
    }

    /**
     * Get statistics string for display.
     *
     * @return String like "Reviewed 25 documents, 12 relevant, 8 citations"
     */
    val statisticsString: String
        get() = "Reviewed $totalDocumentsReviewed documents, " +
                "$relevantDocumentsCount relevant, " +
                "$citationsCount citations"
}
