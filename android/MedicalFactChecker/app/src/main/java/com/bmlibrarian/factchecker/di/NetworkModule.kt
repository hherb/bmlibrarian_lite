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
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCApi
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService
import com.bmlibrarian.factchecker.data.remote.fulltext.UnpaywallApi
import com.bmlibrarian.factchecker.data.remote.llm.AnthropicApi
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.llm.ModelFetchService
import com.bmlibrarian.factchecker.data.remote.llm.OllamaApi
import com.bmlibrarian.factchecker.data.remote.llm.OpenAIApi
import com.bmlibrarian.factchecker.BuildConfig
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedApi
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import dagger.hilt.android.qualifiers.ApplicationContext
import com.bmlibrarian.factchecker.util.Constants
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
import retrofit2.converter.scalars.ScalarsConverterFactory
import java.util.concurrent.TimeUnit
import javax.inject.Named
import javax.inject.Singleton

/**
 * Hilt module providing network dependencies.
 *
 * Provides configured OkHttpClient, Retrofit instances, and API services
 * for LLM, PubMed, and Europe PMC integrations.
 */
@Module
@InstallIn(SingletonComponent::class)
object NetworkModule {

    // ==================== OkHttpClient ====================

    /**
     * Provides a configured OkHttpClient for all network requests.
     *
     * Configuration:
     * - Logging interceptor for debugging (body level in debug builds)
     * - Connection timeout: 30 seconds
     * - Read timeout: 120 seconds (allows for slow LLM responses)
     * - Write timeout: 60 seconds
     * - Automatic retry on connection failure
     *
     * @return A configured OkHttpClient instance
     */
    @Provides
    @Singleton
    fun provideOkHttpClient(): OkHttpClient {
        val builder = OkHttpClient.Builder()
            .connectTimeout(Constants.NETWORK_CONNECT_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .readTimeout(LLM_READ_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .writeTimeout(Constants.NETWORK_WRITE_TIMEOUT_SECONDS, TimeUnit.SECONDS)
            .retryOnConnectionFailure(true)

        // Only add logging interceptor in debug builds, and use BASIC level
        // to avoid the performance overhead of logging full request/response bodies
        if (BuildConfig.DEBUG) {
            val loggingInterceptor = HttpLoggingInterceptor().apply {
                level = HttpLoggingInterceptor.Level.BASIC
            }
            builder.addInterceptor(loggingInterceptor)
        }

        return builder.build()
    }

    // ==================== Retrofit Builders ====================

    /**
     * Provides a base Retrofit builder configured with Kotlin Serialization.
     *
     * Services should use this builder and add their specific baseUrl.
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

    /**
     * Provides a Retrofit builder with both Scalars and JSON converters.
     *
     * Used for APIs that return both XML (as string) and JSON responses.
     *
     * @param okHttpClient The OkHttpClient to use for requests
     * @param json The Json instance for serialization
     * @return A configured Retrofit.Builder with scalars support
     */
    @Provides
    @Singleton
    @Named("scalarsAndJson")
    fun provideScalarsRetrofitBuilder(
        okHttpClient: OkHttpClient,
        json: Json
    ): Retrofit.Builder {
        val contentType = "application/json".toMediaType()
        return Retrofit.Builder()
            .client(okHttpClient)
            // Scalars first for raw string responses (XML)
            .addConverterFactory(ScalarsConverterFactory.create())
            // JSON second for parsed responses
            .addConverterFactory(json.asConverterFactory(contentType))
    }

    // ==================== LLM APIs ====================

    /**
     * Provides the OpenAI-compatible API interface.
     *
     * Uses a placeholder base URL since actual URLs are provided dynamically.
     *
     * @param retrofitBuilder The Retrofit builder to use
     * @return OpenAI API interface
     */
    @Provides
    @Singleton
    fun provideOpenAIApi(retrofitBuilder: Retrofit.Builder): OpenAIApi {
        return retrofitBuilder
            .baseUrl(PLACEHOLDER_BASE_URL)
            .build()
            .create(OpenAIApi::class.java)
    }

    /**
     * Provides the Anthropic API interface.
     *
     * Uses a placeholder base URL since actual URLs are provided dynamically.
     *
     * @param retrofitBuilder The Retrofit builder to use
     * @return Anthropic API interface
     */
    @Provides
    @Singleton
    fun provideAnthropicApi(retrofitBuilder: Retrofit.Builder): AnthropicApi {
        return retrofitBuilder
            .baseUrl(PLACEHOLDER_BASE_URL)
            .build()
            .create(AnthropicApi::class.java)
    }

    /**
     * Provides the Ollama API interface.
     *
     * Uses a placeholder base URL since actual URLs are provided dynamically.
     *
     * @param retrofitBuilder The Retrofit builder to use
     * @return Ollama API interface
     */
    @Provides
    @Singleton
    fun provideOllamaApi(retrofitBuilder: Retrofit.Builder): OllamaApi {
        return retrofitBuilder
            .baseUrl(PLACEHOLDER_BASE_URL)
            .build()
            .create(OllamaApi::class.java)
    }

    /**
     * Provides the LLM service.
     *
     * @param openAIApi OpenAI-compatible API interface
     * @param anthropicApi Anthropic API interface
     * @return LLM service instance
     */
    @Provides
    @Singleton
    fun provideLLMService(
        openAIApi: OpenAIApi,
        anthropicApi: AnthropicApi
    ): LLMService {
        return LLMService(openAIApi, anthropicApi)
    }

    /**
     * Provides the Model Fetch service.
     *
     * Used for dynamically fetching available models from LLM providers.
     *
     * @param openAIApi OpenAI-compatible API interface
     * @param anthropicApi Anthropic API interface
     * @param ollamaApi Ollama API interface
     * @return Model fetch service instance
     */
    @Provides
    @Singleton
    fun provideModelFetchService(
        openAIApi: OpenAIApi,
        anthropicApi: AnthropicApi,
        ollamaApi: OllamaApi
    ): ModelFetchService {
        return ModelFetchService(openAIApi, anthropicApi, ollamaApi)
    }

    // ==================== PubMed API ====================

    /**
     * Provides the PubMed API interface.
     *
     * Uses scalars converter for XML responses from efetch.
     *
     * @param retrofitBuilder The Retrofit builder with scalars support
     * @return PubMed API interface
     */
    @Provides
    @Singleton
    fun providePubMedApi(
        @Named("scalarsAndJson") retrofitBuilder: Retrofit.Builder
    ): PubMedApi {
        return retrofitBuilder
            .baseUrl(Constants.PUBMED_BASE_URL)
            .build()
            .create(PubMedApi::class.java)
    }

    /**
     * Provides the PubMed service.
     *
     * @param api PubMed API interface
     * @return PubMed service instance
     */
    @Provides
    @Singleton
    fun providePubMedService(api: PubMedApi): PubMedService {
        return PubMedService(api)
    }

    // ==================== Europe PMC API ====================

    /**
     * Provides the Europe PMC API interface.
     *
     * Uses scalars converter for XML full-text responses.
     *
     * @param retrofitBuilder The Retrofit builder with scalars support
     * @return Europe PMC API interface
     */
    @Provides
    @Singleton
    fun provideEuropePMCApi(
        @Named("scalarsAndJson") retrofitBuilder: Retrofit.Builder
    ): EuropePMCApi {
        return retrofitBuilder
            .baseUrl(Constants.EUROPE_PMC_BASE_URL)
            .build()
            .create(EuropePMCApi::class.java)
    }

    /**
     * Provides the Europe PMC service.
     *
     * @param api Europe PMC API interface
     * @return Europe PMC service instance
     */
    @Provides
    @Singleton
    fun provideEuropePMCService(api: EuropePMCApi): EuropePMCService {
        return EuropePMCService(api)
    }

    // ==================== Unpaywall API ====================

    /**
     * Provides the Unpaywall API interface.
     *
     * Used for looking up open access PDF versions of articles.
     *
     * @param retrofitBuilder The Retrofit builder to use
     * @return Unpaywall API interface
     */
    @Provides
    @Singleton
    fun provideUnpaywallApi(retrofitBuilder: Retrofit.Builder): UnpaywallApi {
        return retrofitBuilder
            .baseUrl(UnpaywallApi.BASE_URL)
            .build()
            .create(UnpaywallApi::class.java)
    }

    // ==================== Full-Text Service ====================

    /**
     * Provides the Full-Text service.
     *
     * Orchestrates full-text retrieval from Europe PMC, Unpaywall, and DOI fallback.
     *
     * @param context Application context for caching
     * @param europePmcService Europe PMC service
     * @param unpaywallApi Unpaywall API interface
     * @param okHttpClient HTTP client for PDF downloads
     * @return Full-text service instance
     */
    @Provides
    @Singleton
    fun provideFullTextService(
        @ApplicationContext context: Context,
        europePmcService: EuropePMCService,
        unpaywallApi: UnpaywallApi,
        okHttpClient: OkHttpClient
    ): FullTextService {
        return FullTextService(context, europePmcService, unpaywallApi, okHttpClient)
    }

    // ==================== Constants ====================

    /** Placeholder base URL for dynamic URL APIs. */
    private const val PLACEHOLDER_BASE_URL = "https://placeholder.local/"

    /** Extended read timeout for LLM API calls (can be slow). */
    private const val LLM_READ_TIMEOUT_SECONDS = 120L
}
