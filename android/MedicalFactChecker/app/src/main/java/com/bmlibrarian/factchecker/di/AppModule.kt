package com.bmlibrarian.factchecker.di

import android.content.Context
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.android.qualifiers.ApplicationContext
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import javax.inject.Singleton

/**
 * Hilt module providing application-wide singleton dependencies.
 *
 * This module is installed in SingletonComponent, meaning all provided
 * dependencies will live for the entire application lifecycle.
 */
@Module
@InstallIn(SingletonComponent::class)
object AppModule {

    /**
     * Provides a singleton SettingsRepository for accessing app settings.
     *
     * @param context The application context
     * @return A singleton SettingsRepository instance
     */
    @Provides
    @Singleton
    fun provideSettingsRepository(
        @ApplicationContext context: Context
    ): SettingsRepository {
        return SettingsRepository(context)
    }

    /**
     * Provides a configured Json instance for Kotlin Serialization.
     *
     * Configuration:
     * - ignoreUnknownKeys: Allows parsing JSON with extra fields
     * - isLenient: Allows parsing non-standard JSON
     * - encodeDefaults: Includes default values in serialization
     *
     * @return A configured Json instance
     */
    @Provides
    @Singleton
    fun provideJson(): Json {
        return Json {
            ignoreUnknownKeys = true
            isLenient = true
            encodeDefaults = true
            prettyPrint = false
        }
    }
}
