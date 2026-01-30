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

package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.bmlibrarian.factchecker.util.Constants
import java.util.Date
import java.util.UUID

/**
 * Room entity for PubMed/Europe PMC documents.
 *
 * Represents a scientific article retrieved from literature databases.
 * Contains bibliographic metadata, relevance scoring, and full-text content.
 *
 * Mirrors iOS Document model for cross-platform consistency.
 */
@Entity(
    tableName = "documents",
    foreignKeys = [
        ForeignKey(
            entity = SessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["session_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["pmid"]),
        Index(value = ["relevance_score"])
    ]
)
data class DocumentEntity(
    /** Unique identifier for this document. */
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    /** ID of the session this document belongs to. */
    @ColumnInfo(name = "session_id")
    val sessionId: String,

    // ==================== Identifiers ====================

    /** PubMed ID (e.g., "12345678"). */
    @ColumnInfo(name = "pmid")
    val pmid: String? = null,

    /** Digital Object Identifier (e.g., "10.1234/example"). */
    @ColumnInfo(name = "doi")
    val doi: String? = null,

    /** PubMed Central ID (e.g., "PMC1234567"). */
    @ColumnInfo(name = "pmc_id")
    val pmcId: String? = null,

    // ==================== Metadata ====================

    /** Article title. */
    @ColumnInfo(name = "title")
    val title: String,

    /** Article abstract text. */
    @ColumnInfo(name = "abstract_text")
    val abstractText: String? = null,

    /** List of author names. */
    @ColumnInfo(name = "authors")
    val authors: List<String> = emptyList(),

    /** Journal name. */
    @ColumnInfo(name = "journal")
    val journal: String? = null,

    /** Publication date string (e.g., "2024 Jan 15"). */
    @ColumnInfo(name = "publication_date")
    val publicationDate: String? = null,

    /** Publication year as integer for sorting/filtering. */
    @ColumnInfo(name = "publication_year")
    val publicationYear: Int? = null,

    /** MeSH terms associated with this article. */
    @ColumnInfo(name = "mesh_terms")
    val meshTerms: List<String> = emptyList(),

    // ==================== Source Tracking ====================

    /** Source database: SOURCE_PUBMED, SOURCE_EUROPE_PMC, or SOURCE_PREPRINT. */
    @ColumnInfo(name = "source")
    val source: String = Constants.SOURCE_PUBMED,

    /** Whether this is a preprint (not peer-reviewed). */
    @ColumnInfo(name = "is_preprint")
    val isPreprint: Boolean = false,

    // ==================== Relevance Scoring ====================

    /** LLM-assigned relevance score (1-5 scale). */
    @ColumnInfo(name = "relevance_score")
    val relevanceScore: Int? = null,

    /** LLM explanation for the relevance score. */
    @ColumnInfo(name = "score_rationale")
    val scoreRationale: String? = null,

    /** When relevance scoring was performed. */
    @ColumnInfo(name = "scored_at")
    val scoredAt: Date? = null,

    /** Whether LLM score parsing failed (got response but couldn't extract score). */
    @ColumnInfo(name = "score_parse_failed")
    val scoreParseFailed: Boolean = false,

    // ==================== Embedding Scoring ====================

    /** Raw embedding similarity score (0.0 to 1.0). */
    @ColumnInfo(name = "embedding_score")
    val embeddingScore: Double? = null,

    /** Embedding score normalized to 1-5 relevance scale. */
    @ColumnInfo(name = "embedding_score_normalized")
    val embeddingScoreNormalized: Int? = null,

    // ==================== Full Text ====================

    /** Full text content as markdown (from Europe PMC XML). */
    @ColumnInfo(name = "full_text_markdown")
    val fullTextMarkdown: String? = null,

    /** Full text content as HTML (alternative format). */
    @ColumnInfo(name = "full_text_html")
    val fullTextHTML: String? = null,

    /** Source of full text: FULLTEXT_SOURCE_EUROPE_PMC, FULLTEXT_SOURCE_UNPAYWALL, etc. */
    @ColumnInfo(name = "full_text_source")
    val fullTextSource: String? = null,

    /** Local path to downloaded PDF file. */
    @ColumnInfo(name = "pdf_path")
    val pdfPath: String? = null,

    /** When full text was fetched. */
    @ColumnInfo(name = "full_text_fetched_at")
    val fullTextFetchedAt: Date? = null,

    /** Whether full text retrieval was attempted but failed. */
    @ColumnInfo(name = "full_text_unavailable")
    val fullTextUnavailable: Boolean = false,

    // ==================== Batch Tracking ====================

    /** Batch number this document was retrieved in. */
    @ColumnInfo(name = "batch_number")
    val batchNumber: Int = 1,

    /** Position in search results within the batch. */
    @ColumnInfo(name = "result_position")
    val resultPosition: Int = 0,

    // ==================== Timestamps ====================

    /** When this document was added to the database. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    /**
     * Format authors for display.
     *
     * Shows up to MAX_AUTHORS_BEFORE_ET_AL authors, then "et al."
     *
     * @return Formatted author string
     */
    val formattedAuthors: String
        get() {
            if (authors.isEmpty()) return "Unknown authors"
            return if (authors.size <= Constants.MAX_AUTHORS_BEFORE_ET_AL) {
                authors.joinToString(", ")
            } else {
                "${authors.take(Constants.MAX_AUTHORS_BEFORE_ET_AL).joinToString(", ")} et al."
            }
        }

    /**
     * Get citation string for this document.
     *
     * Format: "Authors (Year). Title. Journal."
     *
     * @return Formatted citation string
     */
    val citationString: String
        get() {
            val authorStr = formattedAuthors
            val yearStr = publicationYear?.toString() ?: "n.d."
            val journalStr = journal ?: "Unknown journal"
            return "$authorStr ($yearStr). $title. $journalStr."
        }

    /**
     * Check if this document has full text available.
     *
     * @return true if full text markdown, HTML, or PDF is available
     */
    val hasFullText: Boolean
        get() = fullTextMarkdown != null || fullTextHTML != null || pdfPath != null

    /**
     * Check if this document has an embedding score.
     *
     * @return true if embedding score has been computed
     */
    val hasEmbeddingScore: Boolean
        get() = embeddingScore != null

    /**
     * Get display name for full text source.
     *
     * @return Human-readable source name, or null if no full text
     */
    val fullTextSourceDisplay: String?
        get() = when (fullTextSource) {
            Constants.FULLTEXT_SOURCE_EUROPE_PMC -> "Europe PMC"
            Constants.FULLTEXT_SOURCE_UNPAYWALL -> "Unpaywall"
            Constants.FULLTEXT_SOURCE_DOI -> "Publisher"
            Constants.FULLTEXT_SOURCE_CACHED -> "Cached"
            else -> fullTextSource
        }

    /**
     * Check if this document has been scored.
     *
     * @return true if relevance score has been assigned
     */
    val isScored: Boolean
        get() = relevanceScore != null

    /**
     * Check if this document meets the minimum relevance threshold.
     *
     * @return true if score is at or above SCORING_MIN_RELEVANT_SCORE
     */
    val isRelevant: Boolean
        get() = (relevanceScore ?: 0) >= Constants.SCORING_MIN_RELEVANT_SCORE
}
