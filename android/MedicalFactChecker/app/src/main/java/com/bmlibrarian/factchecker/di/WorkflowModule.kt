package com.bmlibrarian.factchecker.di

import dagger.Module
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent

/**
 * Hilt module for workflow-related dependencies.
 *
 * The FactCheckWorkflow is a singleton that uses constructor injection
 * (@Inject constructor), so it doesn't need explicit @Provides methods.
 * This module serves as documentation and a placeholder for any future
 * workflow-related bindings that may need explicit configuration.
 *
 * Dependencies injected into FactCheckWorkflow:
 * - LLMService (from NetworkModule)
 * - PubMedService (from NetworkModule)
 * - EuropePMCService (from NetworkModule)
 * - SessionRepository (from DatabaseModule)
 * - DocumentRepository (from DatabaseModule)
 * - ReportRepository (from DatabaseModule)
 * - UsageRepository (from DatabaseModule)
 * - SettingsRepository (from AppModule)
 *
 * Usage in ViewModels:
 * ```kotlin
 * @HiltViewModel
 * class FactCheckViewModel @Inject constructor(
 *     private val workflow: FactCheckWorkflow
 * ) : ViewModel() {
 *     // Workflow is automatically injected
 * }
 * ```
 */
@Module
@InstallIn(SingletonComponent::class)
object WorkflowModule {
    // FactCheckWorkflow uses constructor injection with @Singleton and @Inject,
    // so Hilt automatically provides it. No explicit @Provides needed.
    //
    // If we need custom configuration or factories in the future, add them here.
}
