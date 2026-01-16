package com.bmlibrarian.factchecker.util

import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for Constants object.
 *
 * Validates that constant values are sensible and consistent.
 */
class ConstantsTest {

    // ==================== Token Estimation Constants ====================

    @Test
    fun `TOKEN_ESTIMATE_CHARS_PER_TOKEN is positive`() {
        assertTrue(
            "Characters per token must be positive",
            Constants.TOKEN_ESTIMATE_CHARS_PER_TOKEN > 0
        )
    }

    @Test
    fun `TOKEN_ESTIMATE_CHARS_PER_TOKEN is reasonable for LLM tokenization`() {
        // Most LLMs average between 3-5 characters per token for English text
        assertTrue(
            "Characters per token should be between 2 and 10",
            Constants.TOKEN_ESTIMATE_CHARS_PER_TOKEN in 2..10
        )
    }

    @Test
    fun `OUTPUT_TOKEN_ESTIMATE_DIVISOR is positive`() {
        assertTrue(
            "Output token divisor must be positive",
            Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR > 0
        )
    }

    @Test
    fun `OUTPUT_TOKEN_ESTIMATE_DIVISOR produces reasonable estimates`() {
        // Divisor of 2 means output is estimated at half of max tokens
        assertTrue(
            "Output token divisor should be between 1 and 4",
            Constants.OUTPUT_TOKEN_ESTIMATE_DIVISOR in 1..4
        )
    }

    // ==================== Europe PMC Constants ====================

    @Test
    fun `EUROPE_PMC_AVAILABLE_ESTIMATE is positive`() {
        assertTrue(
            "Europe PMC available estimate must be positive",
            Constants.EUROPE_PMC_AVAILABLE_ESTIMATE > 0
        )
    }

    @Test
    fun `EUROPE_PMC_AVAILABLE_ESTIMATE is reasonable`() {
        // Should be a reasonable page size estimate (not too small, not huge)
        assertTrue(
            "Europe PMC estimate should be between 10 and 1000",
            Constants.EUROPE_PMC_AVAILABLE_ESTIMATE in 10..1000
        )
    }

    // ==================== Budget Constants ====================

    @Test
    fun `DEFAULT_MAX_RUN_BUDGET_USD is positive`() {
        assertTrue(
            "Default max run budget must be positive",
            Constants.DEFAULT_MAX_RUN_BUDGET_USD > 0
        )
    }

    @Test
    fun `DEFAULT_MONTHLY_BUDGET_USD is positive`() {
        assertTrue(
            "Default monthly budget must be positive",
            Constants.DEFAULT_MONTHLY_BUDGET_USD > 0
        )
    }

    @Test
    fun `monthly budget exceeds run budget`() {
        assertTrue(
            "Monthly budget should be greater than single run budget",
            Constants.DEFAULT_MONTHLY_BUDGET_USD > Constants.DEFAULT_MAX_RUN_BUDGET_USD
        )
    }

    // ==================== LLM Max Tokens Constants ====================

    @Test
    fun `LLM max token values are positive`() {
        assertTrue(Constants.LLM_QUERY_MAX_TOKENS > 0)
        assertTrue(Constants.LLM_SCORING_MAX_TOKENS > 0)
        assertTrue(Constants.LLM_CITATION_MAX_TOKENS > 0)
        assertTrue(Constants.LLM_REPORT_MAX_TOKENS > 0)
    }

    @Test
    fun `LLM max tokens have sensible hierarchy`() {
        // Query is simple, should be smallest
        assertTrue(
            "Query tokens should be less than scoring",
            Constants.LLM_QUERY_MAX_TOKENS <= Constants.LLM_SCORING_MAX_TOKENS
        )

        // Report is complex, should be largest
        assertTrue(
            "Report tokens should be greater than citation",
            Constants.LLM_REPORT_MAX_TOKENS >= Constants.LLM_CITATION_MAX_TOKENS
        )
    }

    // ==================== Scoring Constants ====================

    @Test
    fun `scoring range is valid`() {
        assertTrue(
            "Min score must be less than max score",
            Constants.SCORING_MIN_SCORE < Constants.SCORING_MAX_SCORE
        )
    }

    @Test
    fun `relevant score threshold is within range`() {
        assertTrue(
            "Relevant score must be >= min",
            Constants.SCORING_MIN_RELEVANT_SCORE >= Constants.SCORING_MIN_SCORE
        )
        assertTrue(
            "Relevant score must be <= max",
            Constants.SCORING_MIN_RELEVANT_SCORE <= Constants.SCORING_MAX_SCORE
        )
    }

    // ==================== Network Constants ====================

    @Test
    fun `network timeouts are positive`() {
        assertTrue(Constants.NETWORK_CONNECT_TIMEOUT_SECONDS > 0)
        assertTrue(Constants.NETWORK_READ_TIMEOUT_SECONDS > 0)
        assertTrue(Constants.NETWORK_WRITE_TIMEOUT_SECONDS > 0)
    }

    @Test
    fun `retry configuration is sensible`() {
        assertTrue(
            "Max retries should be positive",
            Constants.NETWORK_MAX_RETRIES > 0
        )
        assertTrue(
            "Initial backoff should be positive",
            Constants.NETWORK_INITIAL_BACKOFF_MS > 0
        )
        assertTrue(
            "Max backoff should exceed initial",
            Constants.NETWORK_MAX_BACKOFF_MS >= Constants.NETWORK_INITIAL_BACKOFF_MS
        )
    }

    // ==================== Settings Screen Constants ====================

    @Test
    fun `settings budget slider range is valid`() {
        assertTrue(
            "Min run budget must be positive",
            Constants.SETTINGS_MIN_RUN_BUDGET_USD > 0
        )
        assertTrue(
            "Max run budget must exceed min",
            Constants.SETTINGS_MAX_RUN_BUDGET_USD > Constants.SETTINGS_MIN_RUN_BUDGET_USD
        )
        assertTrue(
            "Min monthly budget must be positive",
            Constants.SETTINGS_MIN_MONTHLY_BUDGET_USD > 0
        )
        assertTrue(
            "Max monthly budget must exceed min",
            Constants.SETTINGS_MAX_MONTHLY_BUDGET_USD > Constants.SETTINGS_MIN_MONTHLY_BUDGET_USD
        )
    }

    @Test
    fun `settings budget slider steps are positive`() {
        assertTrue(
            "Run budget steps must be positive",
            Constants.SETTINGS_RUN_BUDGET_STEPS > 0
        )
        assertTrue(
            "Monthly budget steps must be positive",
            Constants.SETTINGS_MONTHLY_BUDGET_STEPS > 0
        )
    }

    @Test
    fun `settings batch size slider range is valid`() {
        assertTrue(
            "Min batch size must be positive",
            Constants.SETTINGS_MIN_BATCH_SIZE > 0
        )
        assertTrue(
            "Max batch size must exceed min",
            Constants.SETTINGS_MAX_BATCH_SIZE > Constants.SETTINGS_MIN_BATCH_SIZE
        )
        assertTrue(
            "Batch size steps must be positive",
            Constants.SETTINGS_BATCH_SIZE_STEPS > 0
        )
    }

    @Test
    fun `settings target documents slider range is valid`() {
        assertTrue(
            "Min target docs must be positive",
            Constants.SETTINGS_MIN_TARGET_DOCS > 0
        )
        assertTrue(
            "Max target docs must exceed min",
            Constants.SETTINGS_MAX_TARGET_DOCS > Constants.SETTINGS_MIN_TARGET_DOCS
        )
        assertTrue(
            "Target docs steps must be positive",
            Constants.SETTINGS_TARGET_DOCS_STEPS > 0
        )
    }

    @Test
    fun `settings pricing table weights are positive`() {
        assertTrue(
            "Model weight must be positive",
            Constants.SETTINGS_PRICING_MODEL_WEIGHT > 0
        )
        assertTrue(
            "Value weight must be positive",
            Constants.SETTINGS_PRICING_VALUE_WEIGHT > 0
        )
    }

    @Test
    fun `settings budget decimal places is reasonable`() {
        assertTrue(
            "Budget decimal places should be between 0 and 4",
            Constants.SETTINGS_BUDGET_DECIMAL_PLACES in 0..4
        )
    }
}
