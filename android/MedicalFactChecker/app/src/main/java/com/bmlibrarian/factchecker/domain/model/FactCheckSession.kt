package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import java.util.Date

/**
 * Domain model for a fact-check session.
 *
 * Provides a cleaner interface than the entity for use in the UI layer.
 * Contains computed properties and helper methods for common operations.
 */
data class FactCheckSession(
    /** Unique identifier for this session. */
    val id: String,

    /** The user's original claim text. */
    val claimText: String,

    /** Generated PubMed query. */
    val pubmedQuery: String?,

    /** Alternative query suggestion. */
    val alternativeQuery: String?,

    /** Current workflow step. */
    val workflowStep: WorkflowStep,

    /** Selected search provider. */
    val searchProvider: SearchProvider,

    /** Whether preprints are included. */
    val includePreprints: Boolean,

    /** Total input tokens used. */
    val totalInputTokens: Int,

    /** Total output tokens used. */
    val totalOutputTokens: Int,

    /** Estimated cost in USD. */
    val estimatedCostUsd: Double,

    /** Error message if failed. */
    val errorMessage: String?,

    /** Creation timestamp. */
    val createdAt: Date,

    /** Last update timestamp. */
    val updatedAt: Date,

    /** Whether more documents are available. */
    val hasMoreDocuments: Boolean
) {
    /**
     * Check if the session is in a terminal state.
     */
    val isTerminal: Boolean
        get() = workflowStep.isTerminal()

    /**
     * Check if the session is actively processing.
     */
    val isProcessing: Boolean
        get() = workflowStep.isProcessing()

    /**
     * Get formatted cost string.
     */
    val formattedCost: String
        get() = String.format("$%.4f", estimatedCostUsd)

    /**
     * Get total tokens used.
     */
    val totalTokens: Int
        get() = totalInputTokens + totalOutputTokens

    /**
     * Get a preview of the claim (truncated if too long).
     */
    fun claimPreview(maxLength: Int = 100): String {
        return if (claimText.length <= maxLength) {
            claimText
        } else {
            "${claimText.take(maxLength - 3)}..."
        }
    }

    companion object {
        /**
         * Create a domain model from an entity.
         *
         * @param entity The session entity from the database
         * @return The domain model representation
         */
        fun fromEntity(entity: SessionEntity): FactCheckSession {
            return FactCheckSession(
                id = entity.id,
                claimText = entity.claimText,
                pubmedQuery = entity.pubmedQuery,
                alternativeQuery = entity.alternativeQuery,
                workflowStep = entity.workflowStep,
                searchProvider = entity.searchProvider,
                includePreprints = entity.includePreprints,
                totalInputTokens = entity.totalInputTokens,
                totalOutputTokens = entity.totalOutputTokens,
                estimatedCostUsd = entity.estimatedCostUsd,
                errorMessage = entity.errorMessage,
                createdAt = entity.createdAt,
                updatedAt = entity.updatedAt,
                hasMoreDocuments = entity.hasMoreDocuments
            )
        }
    }
}

/**
 * Extension function to convert SessionEntity to domain model.
 */
fun SessionEntity.toDomain(): FactCheckSession = FactCheckSession.fromEntity(this)

/**
 * Extension function to convert list of SessionEntity to domain models.
 */
fun List<SessionEntity>.toDomain(): List<FactCheckSession> = map { it.toDomain() }
