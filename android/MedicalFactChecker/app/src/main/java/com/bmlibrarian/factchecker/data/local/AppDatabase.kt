package com.bmlibrarian.factchecker.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import com.bmlibrarian.factchecker.data.local.converter.Converters
import com.bmlibrarian.factchecker.data.local.dao.CitationDao
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.dao.UsageRecordDao
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.local.entity.UsageRecordEntity

/**
 * Room database for MedicalFactChecker.
 *
 * Contains all entities for the fact-checking workflow:
 * - Sessions: Fact-check workflow instances
 * - Documents: Scientific articles from PubMed/Europe PMC
 * - Citations: Extracted passages from documents
 * - Reports: Generated evidence reports
 * - UsageRecords: API usage and cost tracking
 *
 * Schema is exported to $projectDir/schemas for migration tracking.
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

    /**
     * Get the Session DAO.
     *
     * @return SessionDao for session operations
     */
    abstract fun sessionDao(): SessionDao

    /**
     * Get the Document DAO.
     *
     * @return DocumentDao for document operations
     */
    abstract fun documentDao(): DocumentDao

    /**
     * Get the Citation DAO.
     *
     * @return CitationDao for citation operations
     */
    abstract fun citationDao(): CitationDao

    /**
     * Get the Report DAO.
     *
     * @return ReportDao for report operations
     */
    abstract fun reportDao(): ReportDao

    /**
     * Get the Usage Record DAO.
     *
     * @return UsageRecordDao for usage tracking operations
     */
    abstract fun usageRecordDao(): UsageRecordDao

    companion object {
        /** Database file name. */
        const val DATABASE_NAME = "medical_factchecker.db"
    }
}
