/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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
 * Input data for extracting citations from a single document.
 *
 * Contains only the fields needed for the citation extraction prompt, avoiding
 * direct reference to Room entity objects for thread safety in coroutines.
 *
 * Mirrors iOS CitationInput for cross-platform consistency.
 *
 * @property documentId Unique identifier for matching back to the DocumentEntity.
 * @property pmid PubMed ID for display and tracking.
 * @property title Document title for the extraction prompt.
 * @property content Document content (abstract or full text) for citation extraction.
 */
data class CitationInput(
    val documentId: String,
    val pmid: String?,
    val title: String,
    val content: String
) {
    companion object {
        /**
         * Create citation input from a DocumentEntity.
         *
         * Uses full text markdown if available, otherwise falls back to abstract.
         *
         * @param document The document entity to convert.
         * @return CitationInput with extracted fields.
         */
        fun fromDocument(document: DocumentEntity): CitationInput {
            return CitationInput(
                documentId = document.id,
                pmid = document.pmid,
                title = document.title,
                content = document.abstractText ?: document.fullTextMarkdown ?: ""
            )
        }
    }
}
