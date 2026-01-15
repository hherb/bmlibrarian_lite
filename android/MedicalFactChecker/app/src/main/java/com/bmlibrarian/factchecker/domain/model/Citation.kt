package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import java.util.Date

/**
 * Domain model for an extracted citation passage.
 *
 * Provides a cleaner interface than the entity for use in the UI layer.
 */
data class Citation(
    /** Unique identifier. */
    val id: String,

    /** Document this citation is from. */
    val documentId: String,

    /** The extracted passage text. */
    val passage: String,

    /** Surrounding context. */
    val context: String?,

    /** Why this passage is relevant. */
    val relevanceExplanation: String?,

    /** Section where passage was found. */
    val section: String?,

    /** When this was extracted. */
    val createdAt: Date
) {
    /**
     * Get a preview of the passage.
     *
     * @param maxLength Maximum length for the preview
     * @return Truncated passage with ellipsis if needed
     */
    fun passagePreview(maxLength: Int = 150): String {
        return if (passage.length <= maxLength) {
            passage
        } else {
            "${passage.take(maxLength - 3)}..."
        }
    }

    companion object {
        /**
         * Create a domain model from an entity.
         *
         * @param entity The citation entity from the database
         * @return The domain model representation
         */
        fun fromEntity(entity: CitationEntity): Citation {
            return Citation(
                id = entity.id,
                documentId = entity.documentId,
                passage = entity.passage,
                context = entity.context,
                relevanceExplanation = entity.relevanceExplanation,
                section = entity.section,
                createdAt = entity.createdAt
            )
        }
    }
}

/**
 * Extension function to convert CitationEntity to domain model.
 */
fun CitationEntity.toDomain(): Citation = Citation.fromEntity(this)

/**
 * Extension function to convert list of CitationEntity to domain models.
 */
fun List<CitationEntity>.toDomainCitations(): List<Citation> = map { it.toDomain() }
