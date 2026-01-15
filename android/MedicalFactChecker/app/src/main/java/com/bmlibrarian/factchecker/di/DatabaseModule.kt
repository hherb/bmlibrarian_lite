package com.bmlibrarian.factchecker.di

import android.content.Context
import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent

/**
 * Hilt module providing database dependencies.
 *
 * This module will provide Room database instance and DAOs.
 * Full implementation will be added in Phase 2 (Data Models & SQLite).
 *
 * Dependencies that will be provided:
 * - AppDatabase: Main Room database instance
 * - FactCheckSessionDao: DAO for fact-check sessions
 * - DocumentDao: DAO for documents
 * - CitationDao: DAO for citations
 * - EvidenceReportDao: DAO for evidence reports
 * - UsageRecordDao: DAO for usage tracking
 */
@Module
@InstallIn(SingletonComponent::class)
object DatabaseModule {
    // Room database and DAOs will be provided here in Phase 2
    // Placeholder module to ensure Hilt graph is complete
}
