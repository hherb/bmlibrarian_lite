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

import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.util.Constants
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
    fun passagePreview(maxLength: Int = Constants.DEFAULT_PASSAGE_PREVIEW_LENGTH): String {
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
