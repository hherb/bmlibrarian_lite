package com.bmlibrarian.factchecker.di

import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import okhttp3.logging.HttpLoggingInterceptor
import retrofit2.Retrofit
import java.util.concurrent.TimeUnit
import javax.inject.Singleton

/**
 * Hilt module providing network dependencies.
 *
 * Provides configured OkHttpClient and Retrofit instances for API communication.
 * Full API service implementations will be added in Phase 3.
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    /** Connection timeout in seconds for all HTTP requests. */
    private const val CONNECT_TIMEOUT_SECONDS = 30L

    /** Read timeout in seconds for HTTP responses. */
    private const val READ_TIMEOUT_SECONDS = 60L

    /** Write timeout in seconds for HTTP requests. */
    private const val WRITE_TIMEOUT_SECONDS = 60L

    /**
     * Provides a configured OkHttpClient for all network requests.
     *
     * Configuration:
     * - Logging interceptor for debugging (body level in debug builds)
     * - Connection timeout: 30 seconds
     * - Read timeout: 60 seconds (allows for slow LLM responses)
     * - Write timeout: 60 seconds
     *
     * @return A configured OkHttpClient instance
     */
    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        val loggingInterceptor = HttpLoggingInterceptor().apply {
            level = HttpLoggingInterceptor.Level.BODY
        }

        return OkHttpClient.Builder()
            .addInterceptor(loggingInterceptor)
            .connectTimeout(CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(WRITE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)
            .build()
    }

    /**
     * Provides a base Retrofit builder configured with Kotlin Serialization.
     *
     * Note: This provides a builder, not a built instance, because different
     * API services require different base URLs. Services should use this
     * builder and add their specific baseUrl.
     *
     * @param okHttpClient The OkHttpClient to use for requests
     * @param json The Json instance for serialization
     * @return A configured Retrofit.Builder
     */
    @Provides
    @Singleton
    fun provideRetrofitBuilder(
        okHttpClient: OkHttpClient,
        json: Json
    ): Retrofit.Builder {
        val contentType = "application/json".toMediaType()
        return Retrofit.Builder()
            .client(okHttpClient)
            .addConverterFactory(json.asConverterFactory(contentType))
    }

    // API service providers will be added in Phase 3:
    // - LLMApiService (for OpenAI-compatible LLM APIs)
    // - PubMedApiService (for NCBI E-utilities)
    // - EuropePMCApiService (for Europe PMC REST API)
    // - UnpaywallApiService (for open access PDF lookup)
}
