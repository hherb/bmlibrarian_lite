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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity

/**
 * Input data for scoring a single document.
 *
 * Contains only the fields needed for the scoring prompt, avoiding
 * direct reference to Room entity objects for thread safety in coroutines.
 *
 * Mirrors iOS ScoringInput for cross-platform consistency.
 *
 * @property documentId Unique identifier for matching back to the DocumentEntity.
 * @property pmid PubMed ID for display and tracking.
 * @property title Document title for the scoring prompt.
 * @property abstract Document abstract for the scoring prompt.
 * @property authors Formatted author string for the scoring prompt.
 * @property year Publication year (0 if unknown).
 * @property journal Journal name (or "Unknown" if not available).
 */
data class ScoringInput(
    val documentId: String,
    val pmid: String?,
    val title: String,
    val abstract: String,
    val authors: String,
    val year: Int,
    val journal: String
) {
    companion object {
        /**
         * Create scoring input from a DocumentEntity.
         *
         * @param document The document entity to convert.
         * @return ScoringInput with extracted fields.
         */
        fun fromDocument(document: DocumentEntity): ScoringInput {
            return ScoringInput(
                documentId = document.id,
                pmid = document.pmid,
                title = document.title,
                abstract = document.abstractText ?: "",
                authors = document.formattedAuthors,
                year = document.publicationYear ?: 0,
                journal = document.journal ?: "Unknown"
            )
        }
    }
}
