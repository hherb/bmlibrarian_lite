package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for AppSettings data class.
 *
 * Tests validation, computed properties, and default values.
 */
class AppSettingsTest {

    // ==================== Default Values Tests ====================

    @Test
    fun `default settings has correct provider`() {
        val settings = AppSettings.DEFAULT
        assertEquals(LLMProvider.OPENAI.id, settings.llmProviderId)
    }

    @Test
    fun `default settings has correct model`() {
        val settings = AppSettings.DEFAULT
        assertEquals(LLMProvider.OPENAI.defaultModel, settings.modelId)
    }

    @Test
    fun `default settings has correct search provider`() {
        val settings = AppSettings.DEFAULT
        assertEquals(SearchProvider.PUBMED, settings.searchProvider)
    }

    @Test
    fun `default settings has preprints disabled`() {
        val settings = AppSettings.DEFAULT
        assertFalse(settings.includePreprints)
    }

    @Test
    fun `default settings has correct batch size`() {
        val settings = AppSettings.DEFAULT
        assertEquals(AppSettings.DEFAULT_BATCH_SIZE, settings.batchSize)
    }

    @Test
    fun `default settings has correct relevance threshold`() {
        val settings = AppSettings.DEFAULT
        assertEquals(Constants.SCORING_MIN_RELEVANT_SCORE, settings.relevanceThreshold)
    }

    @Test
    fun `default settings has correct target relevant docs`() {
        val settings = AppSettings.DEFAULT
        assertEquals(AppSettings.DEFAULT_TARGET_RELEVANT_DOCS, settings.targetRelevantDocuments)
    }

    @Test
    fun `default settings has disclaimer not accepted`() {
        val settings = AppSettings.DEFAULT
        assertFalse(settings.hasAcceptedDisclaimer)
    }

    @Test
    fun `default settings has onboarding not completed`() {
        val settings = AppSettings.DEFAULT
        assertFalse(settings.hasCompletedOnboarding)
    }

    // ==================== Computed Properties Tests ====================

    @Test
    fun `llmProvider returns correct provider for valid id`() {
        val settings = AppSettings(llmProviderId = "anthropic")
        assertNotNull(settings.llmProvider)
        assertEquals("Anthropic", settings.llmProvider?.displayName)
    }

    @Test
    fun `llmProvider returns null for invalid id`() {
        val settings = AppSettings(llmProviderId = "invalid_provider")
        assertNull(settings.llmProvider)
    }

    @Test
    fun `modelInfo returns correct model for valid provider and model`() {
        val settings = AppSettings(
            llmProviderId = "openai",
            modelId = "gpt-4o"
        )
        val modelInfo = settings.modelInfo
        assertNotNull(modelInfo)
        assertEquals("GPT-4o", modelInfo?.displayName)
    }

    @Test
    fun `modelInfo returns null for invalid model`() {
        val settings = AppSettings(
            llmProviderId = "openai",
            modelId = "invalid-model"
        )
        assertNull(settings.modelInfo)
    }

    @Test
    fun `isConfigured returns true for valid configuration`() {
        val settings = AppSettings(
            llmProviderId = "openai",
            modelId = "gpt-4o"
        )
        assertTrue(settings.isConfigured)
    }

    @Test
    fun `isConfigured returns false for empty provider`() {
        val settings = AppSettings(llmProviderId = "", modelId = "gpt-4o")
        assertFalse(settings.isConfigured)
    }

    @Test
    fun `isConfigured returns false for empty model`() {
        val settings = AppSettings(llmProviderId = "openai", modelId = "")
        assertFalse(settings.isConfigured)
    }

    @Test
    fun `requiresApiKey returns true for cloud providers`() {
        val settings = AppSettings(llmProviderId = "openai")
        assertTrue(settings.requiresApiKey)
    }

    @Test
    fun `requiresApiKey returns false for ollama`() {
        val settings = AppSettings(llmProviderId = "ollama")
        assertFalse(settings.requiresApiKey)
    }

    @Test
    fun `effectiveBaseUrl returns provider url for standard providers`() {
        val settings = AppSettings(llmProviderId = "openai")
        assertEquals("https://api.openai.com/v1", settings.effectiveBaseUrl)
    }

    @Test
    fun `effectiveBaseUrl returns custom url for custom provider`() {
        val settings = AppSettings(
            llmProviderId = "custom",
            customBaseUrl = "https://my-api.example.com/v1"
        )
        assertEquals("https://my-api.example.com/v1", settings.effectiveBaseUrl)
    }

    // ==================== Validation Tests ====================

    @Test
    fun `validate returns empty list for valid settings`() {
        val settings = AppSettings.DEFAULT
        assertTrue(settings.validate().isEmpty())
    }

    @Test
    fun `validate returns error for empty provider`() {
        val settings = AppSettings(llmProviderId = "")
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("provider") })
    }

    @Test
    fun `validate returns error for batch size below minimum`() {
        val settings = AppSettings(batchSize = 1)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("Batch size") })
    }

    @Test
    fun `validate returns error for batch size above maximum`() {
        val settings = AppSettings(batchSize = 1000)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("Batch size") })
    }

    @Test
    fun `validate returns error for invalid relevance threshold`() {
        val settings = AppSettings(relevanceThreshold = 6)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("Relevance threshold") })
    }

    @Test
    fun `validate returns error for target below minimum`() {
        val settings = AppSettings(targetRelevantDocuments = 1)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("Target relevant") })
    }

    @Test
    fun `validate returns error for zero run budget`() {
        val settings = AppSettings(maxRunBudgetUsd = 0.0)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("run budget") })
    }

    @Test
    fun `validate returns error for zero monthly budget`() {
        val settings = AppSettings(monthlyBudgetUsd = 0.0)
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("Monthly budget") })
    }

    @Test
    fun `validate returns error when run budget exceeds monthly budget`() {
        val settings = AppSettings(
            maxRunBudgetUsd = 15.0,
            monthlyBudgetUsd = 10.0
        )
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("cannot exceed") })
    }

    @Test
    fun `validate returns error for custom provider without base url`() {
        val settings = AppSettings(
            llmProviderId = "custom",
            customBaseUrl = ""
        )
        val errors = settings.validate()
        assertTrue(errors.any { it.contains("base URL") })
    }

    // ==================== Copy Tests ====================

    @Test
    fun `copy preserves unchanged values`() {
        val original = AppSettings.DEFAULT
        val copied = original.copy(batchSize = 50)

        assertEquals(50, copied.batchSize)
        assertEquals(original.llmProviderId, copied.llmProviderId)
        assertEquals(original.modelId, copied.modelId)
        assertEquals(original.searchProvider, copied.searchProvider)
    }

    @Test
    fun `copy can change multiple values`() {
        val original = AppSettings.DEFAULT
        val copied = original.copy(
            llmProviderId = "anthropic",
            modelId = "claude-sonnet-4-20250514",
            batchSize = 30
        )

        assertEquals("anthropic", copied.llmProviderId)
        assertEquals("claude-sonnet-4-20250514", copied.modelId)
        assertEquals(30, copied.batchSize)
    }

    // ==================== Companion Object Tests ====================

    @Test
    fun `batch size constants are valid`() {
        assertTrue(AppSettings.MIN_BATCH_SIZE > 0)
        assertTrue(AppSettings.MAX_BATCH_SIZE > AppSettings.MIN_BATCH_SIZE)
        assertTrue(AppSettings.DEFAULT_BATCH_SIZE >= AppSettings.MIN_BATCH_SIZE)
        assertTrue(AppSettings.DEFAULT_BATCH_SIZE <= AppSettings.MAX_BATCH_SIZE)
    }

    @Test
    fun `target relevant docs constants are valid`() {
        assertTrue(AppSettings.MIN_TARGET_RELEVANT_DOCS > 0)
        assertTrue(AppSettings.MAX_TARGET_RELEVANT_DOCS > AppSettings.MIN_TARGET_RELEVANT_DOCS)
        assertTrue(AppSettings.DEFAULT_TARGET_RELEVANT_DOCS >= AppSettings.MIN_TARGET_RELEVANT_DOCS)
        assertTrue(AppSettings.DEFAULT_TARGET_RELEVANT_DOCS <= AppSettings.MAX_TARGET_RELEVANT_DOCS)
    }
}
