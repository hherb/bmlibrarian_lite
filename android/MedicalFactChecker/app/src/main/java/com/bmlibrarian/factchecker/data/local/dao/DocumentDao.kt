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

package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import androidx.room.Update
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for document operations.
 *
 * Provides CRUD operations and queries for scientific documents.
 * Uses Kotlin Flow for reactive queries that emit on data changes.
 */
@Dao
interface DocumentDao {

    // ==================== Insert Operations ====================

    /**
     * Insert a new document, replacing if ID already exists.
     *
     * @param document The document entity to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(document: DocumentEntity)

    /**
     * Insert multiple documents, replacing if IDs already exist.
     *
     * @param documents List of document entities to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(documents: List<DocumentEntity>)

    // ==================== Update Operations ====================

    /**
     * Update an existing document.
     *
     * @param document The document entity with updated values
     */
    @Update
    suspend fun update(document: DocumentEntity)

    /**
     * Update relevance score for a document.
     *
     * @param id Document ID
     * @param score Relevance score (1-5)
     * @param rationale LLM explanation for the score
     * @param scoredAt Timestamp when scoring was performed
     */
    @Query("""
        UPDATE documents SET
            relevance_score = :score,
            score_rationale = :rationale,
            scored_at = :scoredAt
        WHERE id = :id
    """)
    suspend fun updateScore(
        id: String,
        score: Int,
        rationale: String?,
        scoredAt: Long = System.currentTimeMillis()
    )

    /**
     * Update full text content for a document.
     *
     * @param id Document ID
     * @param markdown Full text as markdown
     * @param source Source of full text (europepmc, unpaywall, doi)
     * @param fetchedAt Timestamp when full text was fetched
     */
    @Query("""
        UPDATE documents SET
            full_text_markdown = :markdown,
            full_text_source = :source,
            full_text_fetched_at = :fetchedAt
        WHERE id = :id
    """)
    suspend fun updateFullTextMarkdown(
        id: String,
        markdown: String,
        source: String,
        fetchedAt: Long = System.currentTimeMillis()
    )

    /**
     * Update PDF path for a document.
     *
     * @param id Document ID
     * @param pdfPath Local path to the PDF file
     * @param source Source of the PDF
     * @param fetchedAt Timestamp when PDF was fetched
     */
    @Query("""
        UPDATE documents SET
            pdf_path = :pdfPath,
            full_text_source = :source,
            full_text_fetched_at = :fetchedAt
        WHERE id = :id
    """)
    suspend fun updatePdfPath(
        id: String,
        pdfPath: String,
        source: String,
        fetchedAt: Long = System.currentTimeMillis()
    )

    /**
     * Mark full text as unavailable for a document.
     *
     * @param id Document ID
     */
    @Query("UPDATE documents SET full_text_unavailable = 1 WHERE id = :id")
    suspend fun markFullTextUnavailable(id: String)

    /**
     * Update embedding score for a document.
     *
     * @param id Document ID
     * @param embeddingScore Raw embedding similarity score (0.0-1.0)
     * @param embeddingScoreNormalized Normalized score (1-5)
     */
    @Query("""
        UPDATE documents SET
            embedding_score = :embeddingScore,
            embedding_score_normalized = :embeddingScoreNormalized
        WHERE id = :id
    """)
    suspend fun updateEmbeddingScore(
        id: String,
        embeddingScore: Double,
        embeddingScoreNormalized: Int
    )

    // ==================== Delete Operations ====================

    /**
     * Delete a document.
     *
     * @param document The document entity to delete
     */
    @Delete
    suspend fun delete(document: DocumentEntity)

    /**
     * Delete all documents for a session.
     *
     * @param sessionId Session ID
     */
    @Query("DELETE FROM documents WHERE session_id = :sessionId")
    suspend fun deleteBySessionId(sessionId: String)

    // ==================== Query Operations ====================

    /**
     * Get a document by ID.
     *
     * @param id Document ID
     * @return The document or null if not found
     */
    @Query("SELECT * FROM documents WHERE id = :id")
    suspend fun getById(id: String): DocumentEntity?

    /**
     * Get all documents for a session, ordered by result position.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of documents
     */
    @Query("SELECT * FROM documents WHERE session_id = :sessionId ORDER BY result_position")
    fun getBySessionId(sessionId: String): Flow<List<DocumentEntity>>

    /**
     * Get all documents for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of documents
     */
    @Query("SELECT * FROM documents WHERE session_id = :sessionId ORDER BY result_position")
    suspend fun getBySessionIdSync(sessionId: String): List<DocumentEntity>

    /**
     * Get scored documents for a session, ordered by score (highest first).
     *
     * @param sessionId Session ID
     * @return Flow emitting list of scored documents
     */
    @Query("""
        SELECT * FROM documents
        WHERE session_id = :sessionId AND relevance_score IS NOT NULL
        ORDER BY relevance_score DESC, result_position
    """)
    fun getScoredBySessionId(sessionId: String): Flow<List<DocumentEntity>>

    /**
     * Get relevant documents for a session (score >= minScore).
     *
     * @param sessionId Session ID
     * @param minScore Minimum relevance score (inclusive)
     * @return Flow emitting list of relevant documents
     */
    @Query("""
        SELECT * FROM documents
        WHERE session_id = :sessionId AND relevance_score >= :minScore
        ORDER BY relevance_score DESC, result_position
    """)
    fun getRelevantBySessionId(sessionId: String, minScore: Int): Flow<List<DocumentEntity>>

    /**
     * Get unscored documents for a session.
     *
     * @param sessionId Session ID
     * @return List of unscored documents
     */
    @Query("SELECT * FROM documents WHERE session_id = :sessionId AND relevance_score IS NULL")
    suspend fun getUnscoredBySessionId(sessionId: String): List<DocumentEntity>

    /**
     * Get documents with full text available.
     *
     * @param sessionId Session ID
     * @return List of documents with full text
     */
    @Query("""
        SELECT * FROM documents
        WHERE session_id = :sessionId
        AND (full_text_markdown IS NOT NULL OR pdf_path IS NOT NULL)
    """)
    suspend fun getWithFullText(sessionId: String): List<DocumentEntity>

    /**
     * Get a document by PMID within a session.
     *
     * @param pmid PubMed ID
     * @param sessionId Session ID
     * @return The document or null if not found
     */
    @Query("SELECT * FROM documents WHERE pmid = :pmid AND session_id = :sessionId LIMIT 1")
    suspend fun getByPmidAndSession(pmid: String, sessionId: String): DocumentEntity?

    /**
     * Get a document by DOI within a session.
     *
     * @param doi Digital Object Identifier
     * @param sessionId Session ID
     * @return The document or null if not found
     */
    @Query("SELECT * FROM documents WHERE doi = :doi AND session_id = :sessionId LIMIT 1")
    suspend fun getByDoiAndSession(doi: String, sessionId: String): DocumentEntity?

    // ==================== Count Operations ====================

    /**
     * Count documents for a session.
     *
     * @param sessionId Session ID
     * @return Total number of documents
     */
    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId")
    suspend fun countBySessionId(sessionId: String): Int

    /**
     * Count scored documents for a session.
     *
     * @param sessionId Session ID
     * @return Number of scored documents
     */
    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId AND relevance_score IS NOT NULL")
    suspend fun countScoredBySessionId(sessionId: String): Int

    /**
     * Count relevant documents for a session.
     *
     * @param sessionId Session ID
     * @param minScore Minimum relevance score (inclusive)
     * @return Number of relevant documents
     */
    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId AND relevance_score >= :minScore")
    suspend fun countRelevantBySessionId(sessionId: String, minScore: Int): Int

    /**
     * Count documents with full text.
     *
     * @param sessionId Session ID
     * @return Number of documents with full text
     */
    @Query("""
        SELECT COUNT(*) FROM documents
        WHERE session_id = :sessionId
        AND (full_text_markdown IS NOT NULL OR pdf_path IS NOT NULL)
    """)
    suspend fun countWithFullText(sessionId: String): Int
}
