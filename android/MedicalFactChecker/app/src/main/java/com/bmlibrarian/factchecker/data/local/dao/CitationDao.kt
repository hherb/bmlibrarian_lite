package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Delete
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for citation operations.
 *
 * Provides CRUD operations and queries for extracted citation passages.
 * Uses Kotlin Flow for reactive queries that emit on data changes.
 */
@Dao
interface CitationDao {

    // ==================== Insert Operations ====================

    /**
     * Insert a new citation, replacing if ID already exists.
     *
     * @param citation The citation entity to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(citation: CitationEntity)

    /**
     * Insert multiple citations, replacing if IDs already exist.
     *
     * @param citations List of citation entities to insert
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(citations: List<CitationEntity>)

    // ==================== Delete Operations ====================

    /**
     * Delete a citation.
     *
     * @param citation The citation entity to delete
     */
    @Delete
    suspend fun delete(citation: CitationEntity)

    /**
     * Delete all citations for a document.
     *
     * @param documentId Document ID
     */
    @Query("DELETE FROM citations WHERE document_id = :documentId")
    suspend fun deleteByDocumentId(documentId: String)

    // ==================== Query Operations ====================

    /**
     * Get a citation by ID.
     *
     * @param id Citation ID
     * @return The citation or null if not found
     */
    @Query("SELECT * FROM citations WHERE id = :id")
    suspend fun getById(id: String): CitationEntity?

    /**
     * Get all citations for a document.
     *
     * @param documentId Document ID
     * @return Flow emitting list of citations
     */
    @Query("SELECT * FROM citations WHERE document_id = :documentId ORDER BY created_at")
    fun getByDocumentId(documentId: String): Flow<List<CitationEntity>>

    /**
     * Get all citations for a document (non-reactive).
     *
     * @param documentId Document ID
     * @return List of citations
     */
    @Query("SELECT * FROM citations WHERE document_id = :documentId ORDER BY created_at")
    suspend fun getByDocumentIdSync(documentId: String): List<CitationEntity>

    /**
     * Get all citations for documents in a session.
     *
     * @param sessionId Session ID
     * @return Flow emitting list of citations with document info
     */
    @Query("""
        SELECT c.* FROM citations c
        INNER JOIN documents d ON c.document_id = d.id
        WHERE d.session_id = :sessionId
        ORDER BY c.created_at
    """)
    fun getBySessionId(sessionId: String): Flow<List<CitationEntity>>

    /**
     * Get all citations for documents in a session (non-reactive).
     *
     * @param sessionId Session ID
     * @return List of citations
     */
    @Query("""
        SELECT c.* FROM citations c
        INNER JOIN documents d ON c.document_id = d.id
        WHERE d.session_id = :sessionId
        ORDER BY c.created_at
    """)
    suspend fun getBySessionIdSync(sessionId: String): List<CitationEntity>

    // ==================== Count Operations ====================

    /**
     * Count citations for a document.
     *
     * @param documentId Document ID
     * @return Number of citations
     */
    @Query("SELECT COUNT(*) FROM citations WHERE document_id = :documentId")
    suspend fun countByDocumentId(documentId: String): Int

    /**
     * Count citations for a session.
     *
     * @param sessionId Session ID
     * @return Number of citations
     */
    @Query("""
        SELECT COUNT(*) FROM citations c
        INNER JOIN documents d ON c.document_id = d.id
        WHERE d.session_id = :sessionId
    """)
    suspend fun countBySessionId(sessionId: String): Int
}
