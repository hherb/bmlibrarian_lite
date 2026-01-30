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

package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.CitationDao
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing documents and citations.
 *
 * Provides a clean API for document and citation operations,
 * abstracting the underlying DAO implementations.
 *
 * @param documentDao The Document DAO for database operations
 * @param citationDao The Citation DAO for database operations
 */
@Singleton
class DocumentRepository @Inject constructor(
    private val documentDao: DocumentDao,
    private val citationDao: CitationDao
) {

    // ==================== Document Query Operations ====================

    /**
     * Get all documents for a session as a Flow.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of documents
     */
    fun getDocumentsBySession(sessionId: String): Flow<List<DocumentEntity>> =
        documentDao.getBySessionId(sessionId)

    /**
     * Get all documents for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of documents
     */
    suspend fun getDocumentsBySessionSync(sessionId: String): List<DocumentEntity> =
        documentDao.getBySessionIdSync(sessionId)

    /**
     * Get scored documents for a session as a Flow.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of scored documents ordered by score (highest first)
     */
    fun getScoredDocumentsBySession(sessionId: String): Flow<List<DocumentEntity>> =
        documentDao.getScoredBySessionId(sessionId)

    /**
     * Get relevant documents for a session as a Flow.
     *
     * @param sessionId Session ID
     * @param minScore Minimum relevance score (defaults to SCORING_MIN_RELEVANT_SCORE)
     * @return Flow emitting list of relevant documents
     */
    fun getRelevantDocumentsBySession(
        sessionId: String,
        minScore: Int = Constants.SCORING_MIN_RELEVANT_SCORE
    ): Flow<List<DocumentEntity>> =
        documentDao.getRelevantBySessionId(sessionId, minScore)

    /**
     * Get unscored documents for a session.
     *
     * @param sessionId Session ID
     * @return List of documents without relevance scores
     */
    suspend fun getUnscoredDocuments(sessionId: String): List<DocumentEntity> =
        documentDao.getUnscoredBySessionId(sessionId)

    /**
     * Get a document by ID.
     *
     * @param id Document ID
     * @return The document or null if not found
     */
    suspend fun getDocument(id: String): DocumentEntity? = documentDao.getById(id)

    /**
     * Get documents with full text available.
     *
     * @param sessionId Session ID
     * @return List of documents with full text
     */
    suspend fun getDocumentsWithFullText(sessionId: String): List<DocumentEntity> =
        documentDao.getWithFullText(sessionId)

    // ==================== Document Write Operations ====================

    /**
     * Save a single document.
     *
     * @param document The document to save
     */
    suspend fun saveDocument(document: DocumentEntity) {
        documentDao.insert(document)
    }

    /**
     * Save multiple documents.
     *
     * @param documents List of documents to save
     */
    suspend fun saveDocuments(documents: List<DocumentEntity>) {
        documentDao.insertAll(documents)
    }

    /**
     * Update a document.
     *
     * @param document The document with updated values
     */
    suspend fun updateDocument(document: DocumentEntity) {
        documentDao.update(document)
    }

    /**
     * Update relevance score for a document.
     *
     * @param documentId Document ID
     * @param score Relevance score (1-5)
     * @param rationale LLM explanation for the score
     */
    suspend fun updateDocumentScore(documentId: String, score: Int, rationale: String?) {
        documentDao.updateScore(documentId, score, rationale)
    }

    /**
     * Update full text content for a document.
     *
     * @param documentId Document ID
     * @param markdown Full text as markdown
     * @param source Source of full text (europepmc, unpaywall, doi)
     */
    suspend fun updateFullTextMarkdown(documentId: String, markdown: String, source: String) {
        documentDao.updateFullTextMarkdown(documentId, markdown, source)
    }

    /**
     * Update PDF path for a document.
     *
     * @param documentId Document ID
     * @param pdfPath Local path to the PDF file
     * @param source Source of the PDF
     */
    suspend fun updatePdfPath(documentId: String, pdfPath: String, source: String) {
        documentDao.updatePdfPath(documentId, pdfPath, source)
    }

    /**
     * Mark full text as unavailable for a document.
     *
     * @param documentId Document ID
     */
    suspend fun markFullTextUnavailable(documentId: String) {
        documentDao.markFullTextUnavailable(documentId)
    }

    /**
     * Update embedding score for a document.
     *
     * @param documentId Document ID
     * @param embeddingScore Raw embedding similarity score (0.0-1.0)
     * @param embeddingScoreNormalized Normalized score (1-5)
     */
    suspend fun updateEmbeddingScore(
        documentId: String,
        embeddingScore: Double,
        embeddingScoreNormalized: Int
    ) {
        documentDao.updateEmbeddingScore(documentId, embeddingScore, embeddingScoreNormalized)
    }

    // ==================== Document Existence Checks ====================

    /**
     * Check if a document with the given PMID exists in the session.
     *
     * @param pmid PubMed ID
     * @param sessionId Session ID
     * @return true if document exists
     */
    suspend fun documentExistsByPmid(pmid: String, sessionId: String): Boolean {
        return documentDao.getByPmidAndSession(pmid, sessionId) != null
    }

    /**
     * Check if a document with the given DOI exists in the session.
     *
     * @param doi Digital Object Identifier
     * @param sessionId Session ID
     * @return true if document exists
     */
    suspend fun documentExistsByDoi(doi: String, sessionId: String): Boolean {
        return documentDao.getByDoiAndSession(doi, sessionId) != null
    }

    // ==================== Document Count Operations ====================

    /**
     * Get total document count for a session.
     *
     * @param sessionId Session ID
     * @return Number of documents
     */
    suspend fun getDocumentCount(sessionId: String): Int =
        documentDao.countBySessionId(sessionId)

    /**
     * Get scored document count for a session.
     *
     * @param sessionId Session ID
     * @return Number of scored documents
     */
    suspend fun getScoredCount(sessionId: String): Int =
        documentDao.countScoredBySessionId(sessionId)

    /**
     * Get relevant document count for a session.
     *
     * @param sessionId Session ID
     * @param minScore Minimum relevance score (defaults to SCORING_MIN_RELEVANT_SCORE)
     * @return Number of relevant documents
     */
    suspend fun getRelevantCount(
        sessionId: String,
        minScore: Int = Constants.SCORING_MIN_RELEVANT_SCORE
    ): Int = documentDao.countRelevantBySessionId(sessionId, minScore)

    /**
     * Get count of documents with full text.
     *
     * @param sessionId Session ID
     * @return Number of documents with full text
     */
    suspend fun getFullTextCount(sessionId: String): Int =
        documentDao.countWithFullText(sessionId)

    // ==================== Citation Operations ====================

    /**
     * Get all citations for a session as a Flow.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of citations
     */
    fun getCitationsBySession(sessionId: String): Flow<List<CitationEntity>> =
        citationDao.getBySessionId(sessionId)

    /**
     * Get all citations for a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of citations
     */
    suspend fun getCitationsBySessionSync(sessionId: String): List<CitationEntity> =
        citationDao.getBySessionIdSync(sessionId)

    /**
     * Get citations for a document as a Flow.
     *
     * @param documentId Document ID
     * @return Flow emitting list of citations
     */
    fun getCitationsByDocument(documentId: String): Flow<List<CitationEntity>> =
        citationDao.getByDocumentId(documentId)

    /**
     * Get citations for a document (non-reactive).
     *
     * @param documentId Document ID
     * @return List of citations
     */
    suspend fun getCitationsByDocumentSync(documentId: String): List<CitationEntity> =
        citationDao.getByDocumentIdSync(documentId)

    /**
     * Save a single citation.
     *
     * @param citation The citation to save
     */
    suspend fun saveCitation(citation: CitationEntity) {
        citationDao.insert(citation)
    }

    /**
     * Save multiple citations.
     *
     * @param citations List of citations to save
     */
    suspend fun saveCitations(citations: List<CitationEntity>) {
        citationDao.insertAll(citations)
    }

    /**
     * Get citation count for a session.
     *
     * @param sessionId Session ID
     * @return Number of citations
     */
    suspend fun getCitationCount(sessionId: String): Int =
        citationDao.countBySessionId(sessionId)

    /**
     * Get citation count for a document.
     *
     * @param documentId Document ID
     * @return Number of citations
     */
    suspend fun getCitationCountForDocument(documentId: String): Int =
        citationDao.countByDocumentId(documentId)

    // ==================== Delete Operations ====================

    /**
     * Delete all documents for a session.
     *
     * Note: Due to CASCADE foreign key constraints, this will also
     * delete all associated citations.
     *
     * @param sessionId Session ID
     */
    suspend fun deleteDocumentsBySession(sessionId: String) {
        documentDao.deleteBySessionId(sessionId)
    }

    /**
     * Delete all citations for a document.
     *
     * @param documentId Document ID
     */
    suspend fun deleteCitationsByDocument(documentId: String) {
        citationDao.deleteByDocumentId(documentId)
    }
}
