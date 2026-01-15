package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for tracking API usage and costs.
 *
 * Records token usage for each LLM API call to enable budget tracking
 * and cost estimation. Used for both per-run and monthly budget limits.
 *
 * Mirrors iOS UsageRecord model for cross-platform consistency.
 */
@Entity(
    tableName = "usage_records",
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["created_at"])
    ]
)
data class UsageRecordEntity(
    /** Unique identifier for this record. */
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    /** ID of the session this usage is associated with (null for non-session usage). */
    @ColumnInfo(name = "session_id")
    val sessionId: String? = null,

    /** LLM provider name (e.g., "openai", "anthropic", "ollama"). */
    @ColumnInfo(name = "provider")
    val provider: String,

    /** Model identifier (e.g., "gpt-4", "claude-3-opus"). */
    @ColumnInfo(name = "model")
    val model: String,

    /** Type of operation: "query_conversion", "scoring", "citation", "report". */
    @ColumnInfo(name = "operation")
    val operation: String,

    /** Number of input tokens consumed. */
    @ColumnInfo(name = "input_tokens")
    val inputTokens: Int,

    /** Number of output tokens generated. */
    @ColumnInfo(name = "output_tokens")
    val outputTokens: Int,

    /** Estimated cost in USD. */
    @ColumnInfo(name = "cost_usd")
    val costUsd: Double,

    /** When this usage occurred. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    /**
     * Get total tokens (input + output).
     *
     * @return Total token count
     */
    val totalTokens: Int
        get() = inputTokens + outputTokens

    /**
     * Get a summary string for display.
     *
     * @return String like "scoring: 500 in / 100 out = $0.0012"
     */
    val summaryString: String
        get() = "$operation: $inputTokens in / $outputTokens out = \$${String.format("%.4f", costUsd)}"

    companion object {
        /** Operation type for query conversion. */
        const val OPERATION_QUERY_CONVERSION = "query_conversion"

        /** Operation type for document scoring. */
        const val OPERATION_SCORING = "scoring"

        /** Operation type for citation extraction. */
        const val OPERATION_CITATION = "citation"

        /** Operation type for report generation. */
        const val OPERATION_REPORT = "report"
    }
}
