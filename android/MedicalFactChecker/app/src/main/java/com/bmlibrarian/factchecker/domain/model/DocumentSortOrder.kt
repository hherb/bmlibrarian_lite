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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity

/**
 * Sort order options for documents.
 *
 * Mirrors iOS DocumentSortOrder for cross-platform consistency.
 */
enum class DocumentSortOrder(val displayName: String) {
    /** Sort by relevance score, highest first. */
    SCORE_HIGH_TO_LOW("Score (High → Low)"),

    /** Sort by relevance score, lowest first. */
    SCORE_LOW_TO_HIGH("Score (Low → High)"),

    /** Sort by batch order (original search result order). */
    BATCH_ORDER("Batch Order"),

    /** Sort alphabetically by title. */
    ALPHABETICAL("Alphabetical");

    companion object {
        /** Default sort order. */
        val DEFAULT = SCORE_HIGH_TO_LOW

        /**
         * Sort a list of documents by the specified order.
         *
         * @param documents The documents to sort.
         * @param order The sort order to apply.
         * @return Sorted list of documents.
         */
        fun sortDocuments(
            documents: List<DocumentEntity>,
            order: DocumentSortOrder
        ): List<DocumentEntity> {
            return when (order) {
                SCORE_HIGH_TO_LOW -> documents.sortedByDescending { it.relevanceScore ?: 0 }
                SCORE_LOW_TO_HIGH -> documents.sortedBy { it.relevanceScore ?: 0 }
                BATCH_ORDER -> documents.sortedWith(
                    compareBy({ it.batchNumber }, { it.resultPosition })
                )
                ALPHABETICAL -> documents.sortedBy { it.title.lowercase() }
            }
        }
    }
}
