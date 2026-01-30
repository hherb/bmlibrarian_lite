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

package com.bmlibrarian.factchecker.di

import android.content.Context
import androidx.room.Room
import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.local.dao.CitationDao
import com.bmlibrarian.factchecker.data.local.dao.DocumentDao
import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.local.dao.ProcessingErrorDao
import com.bmlibrarian.factchecker.data.local.dao.ReportDao
import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.dao.UsageRecordDao
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module providing database dependencies.
 *
 * Provides the Room database instance and all DAOs as singletons.
 * The database uses destructive migration for development; production
 * should use proper migration strategies.
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {

    /**
     * Provides the Room database instance.
     *
     * Configuration:
     * - Uses fallbackToDestructiveMigration for development convenience
     * - Schema is exported to $projectDir/schemas for migration tracking
     *
     * @param context Application context
     * @return Singleton AppDatabase instance
     */
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
            // Add migrations for schema changes
            .addMigrations(
                AppDatabase.MIGRATION_1_2,
                AppDatabase.MIGRATION_2_3
            )
            // Fallback for any unexpected version issues during development
            .fallbackToDestructiveMigration()
            .build()
    }

    /**
     * Provides the Session DAO.
     *
     * @param database The AppDatabase instance
     * @return SessionDao for session operations
     */
    @Provides
    fun provideSessionDao(database: AppDatabase): SessionDao {
        return database.sessionDao()
    }

    /**
     * Provides the Document DAO.
     *
     * @param database The AppDatabase instance
     * @return DocumentDao for document operations
     */
    @Provides
    fun provideDocumentDao(database: AppDatabase): DocumentDao {
        return database.documentDao()
    }

    /**
     * Provides the Citation DAO.
     *
     * @param database The AppDatabase instance
     * @return CitationDao for citation operations
     */
    @Provides
    fun provideCitationDao(database: AppDatabase): CitationDao {
        return database.citationDao()
    }

    /**
     * Provides the Report DAO.
     *
     * @param database The AppDatabase instance
     * @return ReportDao for report operations
     */
    @Provides
    fun provideReportDao(database: AppDatabase): ReportDao {
        return database.reportDao()
    }

    /**
     * Provides the Usage Record DAO.
     *
     * @param database The AppDatabase instance
     * @return UsageRecordDao for usage tracking operations
     */
    @Provides
    fun provideUsageRecordDao(database: AppDatabase): UsageRecordDao {
        return database.usageRecordDao()
    }

    /**
     * Provides the Processing Checkpoint DAO.
     *
     * @param database The AppDatabase instance
     * @return ProcessingCheckpointDao for checkpoint operations
     */
    @Provides
    fun provideProcessingCheckpointDao(database: AppDatabase): ProcessingCheckpointDao {
        return database.processingCheckpointDao()
    }

    /**
     * Provides the Processing Error DAO.
     *
     * @param database The AppDatabase instance
     * @return ProcessingErrorDao for error tracking operations
     */
    @Provides
    fun provideProcessingErrorDao(database: AppDatabase): ProcessingErrorDao {
        return database.processingErrorDao()
    }
}
