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

package com.bmlibrarian.factchecker.data.local

import androidx.room.Database
import androidx.room.RoomDatabase
import androidx.room.TypeConverters
import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase
import com.bmlibrarian.factchecker.data.local.converter.Converters
import com.bmlibrarian.factchecker.data.local.dao.CitationDao
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.local.dao.ProcessingErrorDao
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.dao.UsageRecordDao
import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import com.bmlibrarian.factchecker.data.local.entity.ProcessingErrorEntity
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
 * - ProcessingCheckpoints: Checkpoint data for workflow resumption
 * - ProcessingErrors: Error tracking for retry functionality
 *
 * Schema is exported to $projectDir/schemas for migration tracking.
 */
@Database(
    entities = [
        SessionEntity::class,
        DocumentEntity::class,
        CitationEntity::class,
        ReportEntity::class,
        UsageRecordEntity::class,
        ProcessingCheckpointEntity::class,
        ProcessingErrorEntity::class
    ],
    version = 4,
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

    /**
     * Get the Processing Checkpoint DAO.
     *
     * @return ProcessingCheckpointDao for checkpoint operations
     */
    abstract fun processingCheckpointDao(): ProcessingCheckpointDao

    /**
     * Get the Processing Error DAO.
     *
     * @return ProcessingErrorDao for error tracking operations
     */
    abstract fun processingErrorDao(): ProcessingErrorDao

    companion object {
        /** Database file name. */
        const val DATABASE_NAME = "medical_factchecker.db"

        /**
         * Migration from version 1 to 2.
         *
         * Adds processing_checkpoints and processing_errors tables
         * for workflow resumption and error retry functionality.
         */
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(database: SupportSQLiteDatabase) {
                // Create processing_checkpoints table
                database.execSQL("""
                    CREATE TABLE IF NOT EXISTS processing_checkpoints (
                        session_id TEXT NOT NULL,
                        document_id TEXT NOT NULL,
                        step TEXT NOT NULL,
                        result_json TEXT NOT NULL,
                        created_at INTEGER NOT NULL,
                        PRIMARY KEY(session_id, document_id, step)
                    )
                """)
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_processing_checkpoints_session_id ON processing_checkpoints (session_id)"
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_processing_checkpoints_session_id_step ON processing_checkpoints (session_id, step)"
                )

                // Create processing_errors table
                database.execSQL("""
                    CREATE TABLE IF NOT EXISTS processing_errors (
                        id TEXT NOT NULL PRIMARY KEY,
                        session_id TEXT NOT NULL,
                        document_id TEXT NOT NULL,
                        step TEXT NOT NULL,
                        error_type TEXT NOT NULL,
                        error_message TEXT NOT NULL,
                        is_retryable INTEGER NOT NULL DEFAULT 1,
                        retry_count INTEGER NOT NULL DEFAULT 0,
                        max_retries INTEGER NOT NULL DEFAULT 3,
                        created_at INTEGER NOT NULL,
                        last_retry_at INTEGER,
                        FOREIGN KEY(session_id) REFERENCES sessions(id) ON DELETE CASCADE
                    )
                """)
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_processing_errors_session_id ON processing_errors (session_id)"
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_processing_errors_session_id_step ON processing_errors (session_id, step)"
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_processing_errors_is_retryable ON processing_errors (is_retryable)"
                )
            }
        }

        /**
         * Migration from version 2 to 3.
         *
         * Adds embedding scoring fields and fullTextHTML to documents table
         * for Phase 2 iOS parity features.
         */
        val MIGRATION_2_3 = object : Migration(2, 3) {
            override fun migrate(database: SupportSQLiteDatabase) {
                // Add embedding scoring columns
                database.execSQL(
                    "ALTER TABLE documents ADD COLUMN score_parse_failed INTEGER NOT NULL DEFAULT 0"
                )
                database.execSQL(
                    "ALTER TABLE documents ADD COLUMN embedding_score REAL"
                )
                database.execSQL(
                    "ALTER TABLE documents ADD COLUMN embedding_score_normalized INTEGER"
                )
                database.execSQL(
                    "ALTER TABLE documents ADD COLUMN full_text_html TEXT"
                )
            }
        }

        /**
         * Migration from version 3 to 4.
         *
         * Adds HyDE (Hypothetical Document Embedding) fields to sessions table
         * for Phase 3 advanced scoring features.
         */
        val MIGRATION_3_4 = object : Migration(3, 4) {
            override fun migrate(database: SupportSQLiteDatabase) {
                // Add HyDE fields to sessions table
                database.execSQL("ALTER TABLE sessions ADD COLUMN hyde_abstract TEXT")
                database.execSQL("ALTER TABLE sessions ADD COLUMN hyde_generated_at INTEGER")
            }
        }
    }
}
