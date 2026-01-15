# Phase 2: Data Models & SQLite Persistence

## Overview

This phase implements the data persistence layer using Room Database (SQLite). We'll create entities that mirror the iOS SwiftData models, establish relationships, and implement the repository pattern.

**Estimated Duration**: 1-2 weeks
**Prerequisites**: Phase 1 completed
**Deliverable**: Working persistence layer with all entities and DAOs

## iOS Model Reference

The Android entities correspond to these iOS SwiftData models:

| iOS Model | Android Entity | Purpose |
|-----------|---------------|---------|
| `FactCheckSession` | `SessionEntity` | Workflow session state |
| `Document` | `DocumentEntity` | PubMed/Europe PMC documents |
| `Citation` | `CitationEntity` | Extracted citation passages |
| `EvidenceReport` | `ReportEntity` | Generated evidence report |
| `UsageRecord` | `UsageRecordEntity` | Token usage tracking |

## Tasks

### 2.1 Create Type Converters

```kotlin
// data/local/converter/Converters.kt
package com.bmlibrarian.factchecker.data.local.converter

import androidx.room.TypeConverter
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import com.google.gson.Gson
import com.google.gson.reflect.TypeToken
import java.util.Date

/**
 * Room type converters for complex types.
 */
class Converters {

    private val gson = Gson()

    // Date converters
    @TypeConverter
    fun fromTimestamp(value: Long?): Date? = value?.let { Date(it) }

    @TypeConverter
    fun dateToTimestamp(date: Date?): Long? = date?.time

    // String list converters (for authors, MeSH terms)
    @TypeConverter
    fun fromStringList(value: List<String>?): String? {
        return value?.let { gson.toJson(it) }
    }

    @TypeConverter
    fun toStringList(value: String?): List<String>? {
        if (value == null) return null
        val listType = object : TypeToken<List<String>>() {}.type
        return gson.fromJson(value, listType)
    }

    // WorkflowStep enum converter
    @TypeConverter
    fun fromWorkflowStep(step: WorkflowStep): String = step.name

    @TypeConverter
    fun toWorkflowStep(value: String): WorkflowStep = WorkflowStep.valueOf(value)

    // Verdict enum converter
    @TypeConverter
    fun fromVerdict(verdict: Verdict?): String? = verdict?.name

    @TypeConverter
    fun toVerdict(value: String?): Verdict? = value?.let { Verdict.valueOf(it) }

    // SearchProvider enum converter
    @TypeConverter
    fun fromSearchProvider(provider: SearchProvider): String = provider.name

    @TypeConverter
    fun toSearchProvider(value: String): SearchProvider = SearchProvider.valueOf(value)
}
```

### 2.2 Create Domain Enums

```kotlin
// domain/model/WorkflowStep.kt
package com.bmlibrarian.factchecker.domain.model

/**
 * Workflow states for the fact-checking process.
 * Mirrors iOS WorkflowStep enum.
 */
enum class WorkflowStep {
    IDLE,
    CONVERTING_QUERY,
    SEARCHING_PUBMED,
    SCORING_DOCUMENTS,
    AWAITING_USER_DECISION,
    EXTRACTING_CITATIONS,
    GENERATING_REPORT,
    FETCHING_MORE_EVIDENCE,
    COMPLETED,
    FAILED,
    BUDGET_EXCEEDED
}
```

```kotlin
// domain/model/Verdict.kt
package com.bmlibrarian.factchecker.domain.model

import androidx.compose.ui.graphics.Color
import com.bmlibrarian.factchecker.ui.theme.*

/**
 * Evidence verdict for a fact check.
 * Mirrors iOS Verdict enum.
 */
enum class Verdict(val displayName: String, val color: Color) {
    SUPPORTED("Supported", VerdictSupported),
    LIKELY_SUPPORTED("Likely Supported", VerdictLikelySupported),
    UNCLEAR("Unclear", VerdictUnclear),
    LIKELY_REFUTED("Likely Refuted", VerdictLikelyRefuted),
    REFUTED("Refuted", VerdictRefuted);

    companion object {
        /**
         * Parse verdict from LLM response string.
         */
        fun fromString(value: String): Verdict {
            return when (value.lowercase().trim()) {
                "supported", "true", "confirmed" -> SUPPORTED
                "likely supported", "probably true" -> LIKELY_SUPPORTED
                "unclear", "uncertain", "insufficient evidence" -> UNCLEAR
                "likely refuted", "probably false" -> LIKELY_REFUTED
                "refuted", "false", "disproven" -> REFUTED
                else -> UNCLEAR
            }
        }
    }
}
```

```kotlin
// domain/model/SearchProvider.kt
package com.bmlibrarian.factchecker.domain.model

/**
 * Search provider options.
 * Mirrors iOS SearchProvider enum.
 */
enum class SearchProvider(val displayName: String) {
    PUBMED("PubMed"),
    EUROPE_PMC("Europe PMC"),
    BOTH("Both");
}
```

### 2.3 Create Entity Classes

#### SessionEntity

```kotlin
// data/local/entity/SessionEntity.kt
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import java.util.Date
import java.util.UUID

/**
 * Room entity for fact-check sessions.
 * Mirrors iOS FactCheckSession model.
 */
@Entity(tableName = "sessions")
data class SessionEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    @ColumnInfo(name = "claim_text")
    val claimText: String,

    @ColumnInfo(name = "pubmed_query")
    val pubmedQuery: String? = null,

    @ColumnInfo(name = "alternative_query")
    val alternativeQuery: String? = null,

    @ColumnInfo(name = "workflow_step")
    val workflowStep: WorkflowStep = WorkflowStep.IDLE,

    @ColumnInfo(name = "search_provider")
    val searchProvider: SearchProvider = SearchProvider.PUBMED,

    @ColumnInfo(name = "include_preprints")
    val includePreprints: Boolean = false,

    // PubMed pagination
    @ColumnInfo(name = "pubmed_offset")
    val pubmedOffset: Int = 0,

    @ColumnInfo(name = "pubmed_total_results")
    val pubmedTotalResults: Int = 0,

    // Europe PMC pagination
    @ColumnInfo(name = "epmc_cursor")
    val epmcCursor: String? = null,

    @ColumnInfo(name = "epmc_total_results")
    val epmcTotalResults: Int = 0,

    // Batch tracking
    @ColumnInfo(name = "current_batch")
    val currentBatch: Int = 1,

    @ColumnInfo(name = "documents_in_batch")
    val documentsInBatch: Int = 0,

    // Cost tracking
    @ColumnInfo(name = "total_input_tokens")
    val totalInputTokens: Int = 0,

    @ColumnInfo(name = "total_output_tokens")
    val totalOutputTokens: Int = 0,

    @ColumnInfo(name = "estimated_cost_usd")
    val estimatedCostUsd: Double = 0.0,

    // Error tracking
    @ColumnInfo(name = "error_message")
    val errorMessage: String? = null,

    // Timestamps
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date(),

    @ColumnInfo(name = "updated_at")
    val updatedAt: Date = Date()
) {
    /**
     * Check if more documents are available from search providers.
     */
    val hasMoreDocuments: Boolean
        get() = when (searchProvider) {
            SearchProvider.PUBMED -> pubmedOffset < pubmedTotalResults
            SearchProvider.EUROPE_PMC -> epmcCursor != null
            SearchProvider.BOTH -> pubmedOffset < pubmedTotalResults || epmcCursor != null
        }

    /**
     * Check if the workflow is in a terminal state.
     */
    val isTerminal: Boolean
        get() = workflowStep in listOf(
            WorkflowStep.COMPLETED,
            WorkflowStep.FAILED,
            WorkflowStep.BUDGET_EXCEEDED
        )
}
```

#### DocumentEntity

```kotlin
// data/local/entity/DocumentEntity.kt
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for PubMed/Europe PMC documents.
 * Mirrors iOS Document model.
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
        Index(value = ["pmid"], unique = false),
        Index(value = ["relevance_score"])
    ]
)
data class DocumentEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    @ColumnInfo(name = "session_id")
    val sessionId: String,

    // Identifiers
    @ColumnInfo(name = "pmid")
    val pmid: String? = null,

    @ColumnInfo(name = "doi")
    val doi: String? = null,

    @ColumnInfo(name = "pmc_id")
    val pmcId: String? = null,

    // Metadata
    @ColumnInfo(name = "title")
    val title: String,

    @ColumnInfo(name = "abstract_text")
    val abstractText: String? = null,

    @ColumnInfo(name = "authors")
    val authors: List<String> = emptyList(),

    @ColumnInfo(name = "journal")
    val journal: String? = null,

    @ColumnInfo(name = "publication_date")
    val publicationDate: String? = null,

    @ColumnInfo(name = "publication_year")
    val publicationYear: Int? = null,

    @ColumnInfo(name = "mesh_terms")
    val meshTerms: List<String> = emptyList(),

    // Source tracking
    @ColumnInfo(name = "source")
    val source: String = "pubmed", // "pubmed", "europepmc", "preprint"

    @ColumnInfo(name = "is_preprint")
    val isPreprint: Boolean = false,

    // Scoring (LLM-only for now)
    @ColumnInfo(name = "relevance_score")
    val relevanceScore: Int? = null, // 1-5 scale

    @ColumnInfo(name = "score_rationale")
    val scoreRationale: String? = null,

    @ColumnInfo(name = "scored_at")
    val scoredAt: Date? = null,

    // Full text
    @ColumnInfo(name = "full_text_markdown")
    val fullTextMarkdown: String? = null,

    @ColumnInfo(name = "full_text_source")
    val fullTextSource: String? = null,

    @ColumnInfo(name = "pdf_path")
    val pdfPath: String? = null,

    // Batch tracking
    @ColumnInfo(name = "batch_number")
    val batchNumber: Int = 1,

    @ColumnInfo(name = "result_position")
    val resultPosition: Int = 0,

    // Timestamps
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    /**
     * Format authors for display (max 3 + "et al.").
     */
    val formattedAuthors: String
        get() {
            if (authors.isEmpty()) return "Unknown authors"
            return if (authors.size <= 3) {
                authors.joinToString(", ")
            } else {
                "${authors.take(3).joinToString(", ")} et al."
            }
        }

    /**
     * Get citation string for this document.
     */
    val citationString: String
        get() {
            val authorStr = formattedAuthors
            val yearStr = publicationYear?.toString() ?: "n.d."
            val journalStr = journal ?: "Unknown journal"
            return "$authorStr ($yearStr). $title. $journalStr."
        }
}
```

#### CitationEntity

```kotlin
// data/local/entity/CitationEntity.kt
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for extracted citation passages.
 * Mirrors iOS Citation model.
 */
@Entity(
    tableName = "citations",
    foreignKeys = [
        ForeignKey(
            entity = DocumentEntity::class,
            parentColumns = ["id"],
            childColumns = ["document_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["document_id"])
    ]
)
data class CitationEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    @ColumnInfo(name = "document_id")
    val documentId: String,

    @ColumnInfo(name = "passage")
    val passage: String,

    @ColumnInfo(name = "context")
    val context: String? = null,

    @ColumnInfo(name = "relevance_explanation")
    val relevanceExplanation: String? = null,

    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
)
```

#### ReportEntity

```kotlin
// data/local/entity/ReportEntity.kt
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import com.bmlibrarian.factchecker.domain.model.Verdict
import java.util.Date
import java.util.UUID

/**
 * Room entity for generated evidence reports.
 * Mirrors iOS EvidenceReport model.
 */
@Entity(
    tableName = "reports",
    foreignKeys = [
        ForeignKey(
            entity = SessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["session_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["session_id"], unique = true)
    ]
)
data class ReportEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    @ColumnInfo(name = "session_id")
    val sessionId: String,

    @ColumnInfo(name = "verdict")
    val verdict: Verdict,

    @ColumnInfo(name = "summary")
    val summary: String,

    @ColumnInfo(name = "full_report_markdown")
    val fullReportMarkdown: String,

    @ColumnInfo(name = "footnotes")
    val footnotes: String? = null,

    @ColumnInfo(name = "model_used")
    val modelUsed: String,

    @ColumnInfo(name = "total_documents_reviewed")
    val totalDocumentsReviewed: Int,

    @ColumnInfo(name = "relevant_documents_count")
    val relevantDocumentsCount: Int,

    @ColumnInfo(name = "citations_count")
    val citationsCount: Int,

    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
)
```

#### UsageRecordEntity

```kotlin
// data/local/entity/UsageRecordEntity.kt
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for tracking API usage and costs.
 * Mirrors iOS UsageRecord model.
 */
@Entity(tableName = "usage_records")
data class UsageRecordEntity(
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    @ColumnInfo(name = "session_id")
    val sessionId: String? = null,

    @ColumnInfo(name = "provider")
    val provider: String,

    @ColumnInfo(name = "model")
    val model: String,

    @ColumnInfo(name = "operation")
    val operation: String, // "query_conversion", "scoring", "citation", "report"

    @ColumnInfo(name = "input_tokens")
    val inputTokens: Int,

    @ColumnInfo(name = "output_tokens")
    val outputTokens: Int,

    @ColumnInfo(name = "cost_usd")
    val costUsd: Double,

    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
)
```

### 2.4 Create DAO Interfaces

#### SessionDao

```kotlin
// data/local/dao/SessionDao.kt
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for session operations.
 */
@Dao
interface SessionDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(session: SessionEntity)

    @Update
    suspend fun update(session: SessionEntity)

    @Delete
    suspend fun delete(session: SessionEntity)

    @Query("SELECT * FROM sessions WHERE id = :id")
    suspend fun getById(id: String): SessionEntity?

    @Query("SELECT * FROM sessions WHERE id = :id")
    fun getByIdFlow(id: String): Flow<SessionEntity?>

    @Query("SELECT * FROM sessions ORDER BY created_at DESC")
    fun getAllSessions(): Flow<List<SessionEntity>>

    @Query("SELECT * FROM sessions WHERE workflow_step = :step ORDER BY created_at DESC")
    fun getSessionsByStep(step: WorkflowStep): Flow<List<SessionEntity>>

    @Query("SELECT * FROM sessions WHERE workflow_step = 'COMPLETED' ORDER BY created_at DESC")
    fun getCompletedSessions(): Flow<List<SessionEntity>>

    @Query("UPDATE sessions SET workflow_step = :step, updated_at = :updatedAt WHERE id = :id")
    suspend fun updateWorkflowStep(id: String, step: WorkflowStep, updatedAt: Long = System.currentTimeMillis())

    @Query("""
        UPDATE sessions SET
            total_input_tokens = total_input_tokens + :inputTokens,
            total_output_tokens = total_output_tokens + :outputTokens,
            estimated_cost_usd = estimated_cost_usd + :cost,
            updated_at = :updatedAt
        WHERE id = :id
    """)
    suspend fun addTokenUsage(id: String, inputTokens: Int, outputTokens: Int, cost: Double, updatedAt: Long = System.currentTimeMillis())

    @Query("DELETE FROM sessions WHERE id = :id")
    suspend fun deleteById(id: String)

    @Query("DELETE FROM sessions")
    suspend fun deleteAll()
}
```

#### DocumentDao

```kotlin
// data/local/dao/DocumentDao.kt
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for document operations.
 */
@Dao
interface DocumentDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(document: DocumentEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(documents: List<DocumentEntity>)

    @Update
    suspend fun update(document: DocumentEntity)

    @Delete
    suspend fun delete(document: DocumentEntity)

    @Query("SELECT * FROM documents WHERE id = :id")
    suspend fun getById(id: String): DocumentEntity?

    @Query("SELECT * FROM documents WHERE session_id = :sessionId ORDER BY result_position")
    fun getBySessionId(sessionId: String): Flow<List<DocumentEntity>>

    @Query("SELECT * FROM documents WHERE session_id = :sessionId AND relevance_score IS NOT NULL ORDER BY relevance_score DESC")
    fun getScoredBySessionId(sessionId: String): Flow<List<DocumentEntity>>

    @Query("SELECT * FROM documents WHERE session_id = :sessionId AND relevance_score >= :minScore ORDER BY relevance_score DESC")
    fun getRelevantBySessionId(sessionId: String, minScore: Int): Flow<List<DocumentEntity>>

    @Query("SELECT * FROM documents WHERE session_id = :sessionId AND relevance_score IS NULL")
    suspend fun getUnscoredBySessionId(sessionId: String): List<DocumentEntity>

    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId")
    suspend fun countBySessionId(sessionId: String): Int

    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId AND relevance_score IS NOT NULL")
    suspend fun countScoredBySessionId(sessionId: String): Int

    @Query("SELECT COUNT(*) FROM documents WHERE session_id = :sessionId AND relevance_score >= :minScore")
    suspend fun countRelevantBySessionId(sessionId: String, minScore: Int): Int

    @Query("SELECT * FROM documents WHERE pmid = :pmid AND session_id = :sessionId LIMIT 1")
    suspend fun getByPmidAndSession(pmid: String, sessionId: String): DocumentEntity?

    @Query("""
        UPDATE documents SET
            relevance_score = :score,
            score_rationale = :rationale,
            scored_at = :scoredAt
        WHERE id = :id
    """)
    suspend fun updateScore(id: String, score: Int, rationale: String?, scoredAt: Long = System.currentTimeMillis())

    @Query("DELETE FROM documents WHERE session_id = :sessionId")
    suspend fun deleteBySessionId(sessionId: String)
}
```

#### CitationDao

```kotlin
// data/local/dao/CitationDao.kt
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for citation operations.
 */
@Dao
interface CitationDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(citation: CitationEntity)

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(citations: List<CitationEntity>)

    @Delete
    suspend fun delete(citation: CitationEntity)

    @Query("SELECT * FROM citations WHERE id = :id")
    suspend fun getById(id: String): CitationEntity?

    @Query("SELECT * FROM citations WHERE document_id = :documentId ORDER BY created_at")
    fun getByDocumentId(documentId: String): Flow<List<CitationEntity>>

    @Query("""
        SELECT c.* FROM citations c
        INNER JOIN documents d ON c.document_id = d.id
        WHERE d.session_id = :sessionId
        ORDER BY c.created_at
    """)
    fun getBySessionId(sessionId: String): Flow<List<CitationEntity>>

    @Query("SELECT COUNT(*) FROM citations WHERE document_id = :documentId")
    suspend fun countByDocumentId(documentId: String): Int

    @Query("DELETE FROM citations WHERE document_id = :documentId")
    suspend fun deleteByDocumentId(documentId: String)
}
```

#### ReportDao

```kotlin
// data/local/dao/ReportDao.kt
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for report operations.
 */
@Dao
interface ReportDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(report: ReportEntity)

    @Update
    suspend fun update(report: ReportEntity)

    @Delete
    suspend fun delete(report: ReportEntity)

    @Query("SELECT * FROM reports WHERE id = :id")
    suspend fun getById(id: String): ReportEntity?

    @Query("SELECT * FROM reports WHERE session_id = :sessionId")
    suspend fun getBySessionId(sessionId: String): ReportEntity?

    @Query("SELECT * FROM reports WHERE session_id = :sessionId")
    fun getBySessionIdFlow(sessionId: String): Flow<ReportEntity?>

    @Query("DELETE FROM reports WHERE session_id = :sessionId")
    suspend fun deleteBySessionId(sessionId: String)
}
```

#### UsageRecordDao

```kotlin
// data/local/dao/UsageRecordDao.kt
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.UsageRecordEntity
import kotlinx.coroutines.flow.Flow

/**
 * Data Access Object for usage record operations.
 */
@Dao
interface UsageRecordDao {

    @Insert
    suspend fun insert(record: UsageRecordEntity)

    @Query("SELECT * FROM usage_records WHERE session_id = :sessionId ORDER BY created_at")
    fun getBySessionId(sessionId: String): Flow<List<UsageRecordEntity>>

    @Query("""
        SELECT SUM(cost_usd) FROM usage_records
        WHERE created_at >= :startOfMonth
    """)
    suspend fun getMonthlySpend(startOfMonth: Long): Double?

    @Query("""
        SELECT SUM(cost_usd) FROM usage_records
        WHERE session_id = :sessionId
    """)
    suspend fun getSessionSpend(sessionId: String): Double?

    @Query("DELETE FROM usage_records WHERE created_at < :beforeDate")
    suspend fun deleteOldRecords(beforeDate: Long)
}
```

### 2.5 Create Database Class

```kotlin
// data/local/AppDatabase.kt
package com.bmlibrarian.factchecker.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.bmlibrarian.factchecker.data.local.converter.Converters
import com.bmlibrarian.factchecker.data.local.dao.*
import com.bmlibrarian.factchecker.data.local.entity.*

/**
 * Room database for MedicalFactChecker.
 */
@Database(
    entities = [
        SessionEntity::class,
        DocumentEntity::class,
        CitationEntity::class,
        ReportEntity::class,
        UsageRecordEntity::class
    ],
    version = 1,
    exportSchema = true
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {

    abstract fun sessionDao(): SessionDao
    abstract fun documentDao(): DocumentDao
    abstract fun citationDao(): CitationDao
    abstract fun reportDao(): ReportDao
    abstract fun usageRecordDao(): UsageRecordDao

    companion object {
        const val DATABASE_NAME = "medical_factchecker.db"
    }
}
```

### 2.6 Update DatabaseModule

```kotlin
// di/DatabaseModule.kt
package com.bmlibrarian.factchecker.di

import android.content.Context
import androidx.room.Room
import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.local.dao.*
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module providing database dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    @Provides
    @Singleton
    fun provideAppDatabase(
        @ApplicationContext context: Context
    ): AppDatabase {
        return Room.databaseBuilder(
            context,
            AppDatabase::class.java,
            AppDatabase.DATABASE_NAME
        )
            .fallbackToDestructiveMigration() // For development; use proper migrations in production
            .build()
    }

    @Provides
    fun provideSessionDao(database: AppDatabase): SessionDao = database.sessionDao()

    @Provides
    fun provideDocumentDao(database: AppDatabase): DocumentDao = database.documentDao()

    @Provides
    fun provideCitationDao(database: AppDatabase): CitationDao = database.citationDao()

    @Provides
    fun provideReportDao(database: AppDatabase): ReportDao = database.reportDao()

    @Provides
    fun provideUsageRecordDao(database: AppDatabase): UsageRecordDao = database.usageRecordDao()
}
```

### 2.7 Create Repository Classes

#### SessionRepository

```kotlin
// data/repository/SessionRepository.kt
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing fact-check sessions.
 */
@Singleton
class SessionRepository @Inject constructor(
    private val sessionDao: SessionDao
) {

    fun getAllSessions(): Flow<List<SessionEntity>> = sessionDao.getAllSessions()

    fun getCompletedSessions(): Flow<List<SessionEntity>> = sessionDao.getCompletedSessions()

    fun getSessionFlow(id: String): Flow<SessionEntity?> = sessionDao.getByIdFlow(id)

    suspend fun getSession(id: String): SessionEntity? = sessionDao.getById(id)

    suspend fun createSession(claimText: String): SessionEntity {
        val session = SessionEntity(claimText = claimText)
        sessionDao.insert(session)
        return session
    }

    suspend fun updateSession(session: SessionEntity) {
        sessionDao.update(session.copy(updatedAt = java.util.Date()))
    }

    suspend fun updateWorkflowStep(sessionId: String, step: WorkflowStep) {
        sessionDao.updateWorkflowStep(sessionId, step)
    }

    suspend fun addTokenUsage(sessionId: String, inputTokens: Int, outputTokens: Int, cost: Double) {
        sessionDao.addTokenUsage(sessionId, inputTokens, outputTokens, cost)
    }

    suspend fun deleteSession(sessionId: String) {
        sessionDao.deleteById(sessionId)
    }

    suspend fun deleteAllSessions() {
        sessionDao.deleteAll()
    }
}
```

#### DocumentRepository

```kotlin
// data/repository/DocumentRepository.kt
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.CitationDao
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import kotlinx.coroutines.flow.Flow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing documents and citations.
 */
@Singleton
class DocumentRepository @Inject constructor(
    private val documentDao: DocumentDao,
    private val citationDao: CitationDao
) {

    // Document operations
    fun getDocumentsBySession(sessionId: String): Flow<List<DocumentEntity>> =
        documentDao.getBySessionId(sessionId)

    fun getScoredDocumentsBySession(sessionId: String): Flow<List<DocumentEntity>> =
        documentDao.getScoredBySessionId(sessionId)

    fun getRelevantDocumentsBySession(sessionId: String, minScore: Int = 3): Flow<List<DocumentEntity>> =
        documentDao.getRelevantBySessionId(sessionId, minScore)

    suspend fun getUnscoredDocuments(sessionId: String): List<DocumentEntity> =
        documentDao.getUnscoredBySessionId(sessionId)

    suspend fun getDocument(id: String): DocumentEntity? = documentDao.getById(id)

    suspend fun saveDocuments(documents: List<DocumentEntity>) {
        documentDao.insertAll(documents)
    }

    suspend fun updateDocument(document: DocumentEntity) {
        documentDao.update(document)
    }

    suspend fun updateDocumentScore(documentId: String, score: Int, rationale: String?) {
        documentDao.updateScore(documentId, score, rationale)
    }

    suspend fun documentExists(pmid: String, sessionId: String): Boolean {
        return documentDao.getByPmidAndSession(pmid, sessionId) != null
    }

    suspend fun getDocumentCount(sessionId: String): Int = documentDao.countBySessionId(sessionId)

    suspend fun getScoredCount(sessionId: String): Int = documentDao.countScoredBySessionId(sessionId)

    suspend fun getRelevantCount(sessionId: String, minScore: Int = 3): Int =
        documentDao.countRelevantBySessionId(sessionId, minScore)

    // Citation operations
    fun getCitationsBySession(sessionId: String): Flow<List<CitationEntity>> =
        citationDao.getBySessionId(sessionId)

    fun getCitationsByDocument(documentId: String): Flow<List<CitationEntity>> =
        citationDao.getByDocumentId(documentId)

    suspend fun saveCitation(citation: CitationEntity) {
        citationDao.insert(citation)
    }

    suspend fun saveCitations(citations: List<CitationEntity>) {
        citationDao.insertAll(citations)
    }
}
```

### 2.8 Create Domain Model Mappers

```kotlin
// domain/model/FactCheckSession.kt
package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import java.util.Date

/**
 * Domain model for fact-check session.
 * Provides a cleaner interface than the entity.
 */
data class FactCheckSession(
    val id: String,
    val claimText: String,
    val pubmedQuery: String?,
    val workflowStep: WorkflowStep,
    val searchProvider: SearchProvider,
    val includePreprints: Boolean,
    val totalInputTokens: Int,
    val totalOutputTokens: Int,
    val estimatedCostUsd: Double,
    val errorMessage: String?,
    val createdAt: Date,
    val updatedAt: Date,
    val hasMoreDocuments: Boolean
) {
    companion object {
        fun fromEntity(entity: SessionEntity): FactCheckSession {
            return FactCheckSession(
                id = entity.id,
                claimText = entity.claimText,
                pubmedQuery = entity.pubmedQuery,
                workflowStep = entity.workflowStep,
                searchProvider = entity.searchProvider,
                includePreprints = entity.includePreprints,
                totalInputTokens = entity.totalInputTokens,
                totalOutputTokens = entity.totalOutputTokens,
                estimatedCostUsd = entity.estimatedCostUsd,
                errorMessage = entity.errorMessage,
                createdAt = entity.createdAt,
                updatedAt = entity.updatedAt,
                hasMoreDocuments = entity.hasMoreDocuments
            )
        }
    }
}
```

```kotlin
// domain/model/Document.kt
package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import java.util.Date

/**
 * Domain model for a document.
 */
data class Document(
    val id: String,
    val sessionId: String,
    val pmid: String?,
    val doi: String?,
    val title: String,
    val abstractText: String?,
    val authors: List<String>,
    val journal: String?,
    val publicationYear: Int?,
    val meshTerms: List<String>,
    val source: String,
    val isPreprint: Boolean,
    val relevanceScore: Int?,
    val scoreRationale: String?,
    val formattedAuthors: String,
    val citationString: String
) {
    companion object {
        fun fromEntity(entity: DocumentEntity): Document {
            return Document(
                id = entity.id,
                sessionId = entity.sessionId,
                pmid = entity.pmid,
                doi = entity.doi,
                title = entity.title,
                abstractText = entity.abstractText,
                authors = entity.authors,
                journal = entity.journal,
                publicationYear = entity.publicationYear,
                meshTerms = entity.meshTerms,
                source = entity.source,
                isPreprint = entity.isPreprint,
                relevanceScore = entity.relevanceScore,
                scoreRationale = entity.scoreRationale,
                formattedAuthors = entity.formattedAuthors,
                citationString = entity.citationString
            )
        }
    }
}
```

## Verification Checklist

- [ ] All entities compile without errors
- [ ] DAOs compile without errors
- [ ] Database builds successfully
- [ ] Type converters work for all custom types
- [ ] Foreign key constraints enforced
- [ ] Cascade deletes work correctly
- [ ] Repository methods function correctly
- [ ] Flow-based queries emit updates

## Testing

### Unit Tests for Converters

```kotlin
// test/data/local/converter/ConvertersTest.kt
@Test
fun `stringList converter round-trips correctly`() {
    val converters = Converters()
    val original = listOf("Author A", "Author B", "Author C")
    val json = converters.fromStringList(original)
    val restored = converters.toStringList(json)
    assertEquals(original, restored)
}

@Test
fun `workflowStep converter handles all values`() {
    val converters = Converters()
    WorkflowStep.values().forEach { step ->
        val string = converters.fromWorkflowStep(step)
        val restored = converters.toWorkflowStep(string)
        assertEquals(step, restored)
    }
}
```

### Integration Tests for DAOs

```kotlin
// androidTest/data/local/dao/SessionDaoTest.kt
@RunWith(AndroidJUnit4::class)
class SessionDaoTest {

    private lateinit var database: AppDatabase
    private lateinit var sessionDao: SessionDao

    @Before
    fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java).build()
        sessionDao = database.sessionDao()
    }

    @After
    fun teardown() {
        database.close()
    }

    @Test
    fun insertAndRetrieveSession() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)
        val retrieved = sessionDao.getById(session.id)
        assertEquals(session.claimText, retrieved?.claimText)
    }
}
```

## Next Phase

Continue to [Phase 3: API Services](./03-api-services.md)
