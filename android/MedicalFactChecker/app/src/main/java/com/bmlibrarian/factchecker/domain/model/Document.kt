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
import com.bmlibrarian.factchecker.util.Constants
import java.util.Date

/**
 * Domain model for a scientific document.
 *
 * Provides a cleaner interface than the entity for use in the UI layer.
 * Contains computed properties and helper methods for common operations.
 */
data class Document(
    /** Unique identifier. */
    val id: String,

    /** Session this document belongs to. */
    val sessionId: String,

    /** PubMed ID. */
    val pmid: String?,

    /** Digital Object Identifier. */
    val doi: String?,

    /** PubMed Central ID. */
    val pmcId: String?,

    /** Article title. */
    val title: String,

    /** Abstract text. */
    val abstractText: String?,

    /** List of authors. */
    val authors: List<String>,

    /** Journal name. */
    val journal: String?,

    /** Publication date string. */
    val publicationDate: String?,

    /** Publication year. */
    val publicationYear: Int?,

    /** MeSH terms. */
    val meshTerms: List<String>,

    /** Source database. */
    val source: String,

    /** Whether this is a preprint. */
    val isPreprint: Boolean,

    /** Relevance score (1-5). */
    val relevanceScore: Int?,

    /** LLM rationale for score. */
    val scoreRationale: String?,

    /** When scoring was performed. */
    val scoredAt: Date?,

    /** Full text as markdown. */
    val fullTextMarkdown: String?,

    /** Source of full text. */
    val fullTextSource: String?,

    /** Path to PDF file. */
    val pdfPath: String?,

    /** When full text was fetched. */
    val fullTextFetchedAt: Date?,

    /** Whether full text is unavailable. */
    val fullTextUnavailable: Boolean,

    /** Formatted authors string. */
    val formattedAuthors: String,

    /** Citation string. */
    val citationString: String,

    /** Whether document has been scored. */
    val isScored: Boolean,

    /** Whether document meets relevance threshold. */
    val isRelevant: Boolean,

    /** Whether full text is available. */
    val hasFullText: Boolean,

    /** Display name for full text source. */
    val fullTextSourceDisplay: String?,

    /** Batch number. */
    val batchNumber: Int,

    /** Position in results. */
    val resultPosition: Int,

    /** Creation timestamp. */
    val createdAt: Date
) {
    /**
     * Get a preview of the abstract.
     *
     * @param maxLength Maximum length for the preview
     * @return Truncated abstract with ellipsis if needed
     */
    fun abstractPreview(maxLength: Int = Constants.DEFAULT_ABSTRACT_PREVIEW_LENGTH): String? {
        return abstractText?.let {
            if (it.length <= maxLength) it
            else "${it.take(maxLength - 3)}..."
        }
    }

    /**
     * Get DOI URL.
     *
     * @return Full DOI URL or null if no DOI
     */
    val doiUrl: String?
        get() = doi?.let { "${Constants.DOI_URL_PREFIX}$it" }

    /**
     * Get PubMed URL.
     *
     * @return Full PubMed URL or null if no PMID
     */
    val pubmedUrl: String?
        get() = pmid?.let { "${Constants.PUBMED_URL_PREFIX}$it/" }

    /**
     * Get PMC URL.
     *
     * @return Full PMC URL or null if no PMC ID
     */
    val pmcUrl: String?
        get() = pmcId?.let { "${Constants.PMC_URL_PREFIX}$it/" }

    companion object {
        /**
         * Create a domain model from an entity.
         *
         * @param entity The document entity from the database
         * @return The domain model representation
         */
        fun fromEntity(entity: DocumentEntity): Document {
            return Document(
                id = entity.id,
                sessionId = entity.sessionId,
                pmid = entity.pmid,
                doi = entity.doi,
                pmcId = entity.pmcId,
                title = entity.title,
                abstractText = entity.abstractText,
                authors = entity.authors,
                journal = entity.journal,
                publicationDate = entity.publicationDate,
                publicationYear = entity.publicationYear,
                meshTerms = entity.meshTerms,
                source = entity.source,
                isPreprint = entity.isPreprint,
                relevanceScore = entity.relevanceScore,
                scoreRationale = entity.scoreRationale,
                scoredAt = entity.scoredAt,
                fullTextMarkdown = entity.fullTextMarkdown,
                fullTextSource = entity.fullTextSource,
                pdfPath = entity.pdfPath,
                fullTextFetchedAt = entity.fullTextFetchedAt,
                fullTextUnavailable = entity.fullTextUnavailable,
                formattedAuthors = entity.formattedAuthors,
                citationString = entity.citationString,
                isScored = entity.isScored,
                isRelevant = entity.isRelevant,
                hasFullText = entity.hasFullText,
                fullTextSourceDisplay = entity.fullTextSourceDisplay,
                batchNumber = entity.batchNumber,
                resultPosition = entity.resultPosition,
                createdAt = entity.createdAt
            )
        }
    }
}

/**
 * Extension function to convert DocumentEntity to domain model.
 */
fun DocumentEntity.toDomain(): Document = Document.fromEntity(this)

/**
 * Extension function to convert list of DocumentEntity to domain models.
 */
fun List<DocumentEntity>.toDomainDocuments(): List<Document> = map { it.toDomain() }
