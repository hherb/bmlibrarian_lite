package com.bmlibrarian.factchecker.util

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import java.text.NumberFormat
import java.util.Locale

/**
 * Utility for calculating and formatting LLM API costs.
 *
 * Provides cost estimation and tracking for various LLM operations.
 * Mirrors iOS CostCalculator for cross-platform consistency.
 */
object CostCalculator {

    /**
     * Calculate cost for a single LLM call.
     *
     * @param modelInfo Model pricing information
     * @param inputTokens Number of input (prompt) tokens
     * @param outputTokens Number of output (completion) tokens
     * @return Cost in USD
     */
    fun calculateCost(
        modelInfo: ModelInfo,
        inputTokens: Int,
        outputTokens: Int
    ): Double {
        return modelInfo.calculateCost(inputTokens, outputTokens)
    }

    /**
     * Calculate cost using provider and model ID.
     *
     * @param providerId LLM provider ID (e.g., "anthropic", "openai")
     * @param modelId Model ID (e.g., "gpt-4o", "claude-sonnet-4-20250514")
     * @param inputTokens Number of input tokens
     * @param outputTokens Number of output tokens
     * @return Cost in USD, or 0 if provider/model not found
     */
    fun calculateCost(
        providerId: String,
        modelId: String,
        inputTokens: Int,
        outputTokens: Int
    ): Double {
        val provider = LLMProvider.fromId(providerId) ?: return 0.0
        val modelInfo = provider.getModel(modelId) ?: return 0.0
        return calculateCost(modelInfo, inputTokens, outputTokens)
    }

    /**
     * Estimate cost for a workflow run.
     *
     * @param modelInfo Model pricing information
     * @param documentCount Number of documents to process
     * @param averageInputTokensPerDoc Average input tokens per document
     * @param averageOutputTokensPerDoc Average output tokens per document
     * @param includeQueryConversion Include query conversion step
     * @param includeCitations Include citation extraction step
     * @param includeReport Include report generation step
     * @return Estimated total cost in USD
     */
    fun estimateWorkflowCost(
        modelInfo: ModelInfo,
        documentCount: Int,
        averageInputTokensPerDoc: Int = DEFAULT_INPUT_TOKENS_PER_DOC,
        averageOutputTokensPerDoc: Int = DEFAULT_OUTPUT_TOKENS_PER_DOC,
        includeQueryConversion: Boolean = true,
        includeCitations: Boolean = true,
        includeReport: Boolean = true
    ): Double {
        var totalCost = 0.0

        // Query conversion (one call)
        if (includeQueryConversion) {
            totalCost += calculateCost(
                modelInfo,
                QUERY_CONVERSION_INPUT_TOKENS,
                QUERY_CONVERSION_OUTPUT_TOKENS
            )
        }

        // Document scoring (one call per document)
        totalCost += documentCount * calculateCost(
            modelInfo,
            averageInputTokensPerDoc,
            averageOutputTokensPerDoc
        )

        // Citation extraction (estimated at 30% of documents being relevant)
        if (includeCitations) {
            val relevantDocs = (documentCount * ESTIMATED_RELEVANCE_RATE).toInt()
            totalCost += relevantDocs * calculateCost(
                modelInfo,
                CITATION_INPUT_TOKENS,
                CITATION_OUTPUT_TOKENS
            )
        }

        // Report generation (one call)
        if (includeReport) {
            totalCost += calculateCost(
                modelInfo,
                REPORT_INPUT_TOKENS,
                REPORT_OUTPUT_TOKENS
            )
        }

        return totalCost
    }

    /**
     * Format cost for display.
     *
     * @param cost Cost in USD
     * @param showCents Whether to show cents for small amounts
     * @return Formatted cost string (e.g., "$0.05" or "$1.23")
     */
    fun formatCost(cost: Double, showCents: Boolean = true): String {
        val formatter = NumberFormat.getCurrencyInstance(Locale.US)
        formatter.minimumFractionDigits = if (showCents || cost < 1.0) 2 else 0
        formatter.maximumFractionDigits = if (cost < 0.01) 4 else 2
        return formatter.format(cost)
    }

    /**
     * Format cost as a short string for compact display.
     *
     * @param cost Cost in USD
     * @return Short formatted string (e.g., "5c", "$1.23", "$12")
     */
    fun formatCostShort(cost: Double): String {
        return when {
            cost < 0.01 -> "<1c"
            cost < 1.0 -> "${(cost * 100).toInt()}c"
            cost < 10.0 -> String.format(Locale.US, "$%.2f", cost)
            else -> String.format(Locale.US, "$%.0f", cost)
        }
    }

    /**
     * Check if a cost exceeds a budget.
     *
     * @param currentCost Current accumulated cost
     * @param additionalCost Cost of next operation
     * @param budget Budget limit
     * @return true if current + additional exceeds budget
     */
    fun wouldExceedBudget(
        currentCost: Double,
        additionalCost: Double,
        budget: Double
    ): Boolean {
        return (currentCost + additionalCost) > budget
    }

    /**
     * Calculate remaining budget.
     *
     * @param budget Total budget
     * @param spent Amount already spent
     * @return Remaining budget (never negative)
     */
    fun remainingBudget(budget: Double, spent: Double): Double {
        return maxOf(0.0, budget - spent)
    }

    /**
     * Get budget usage percentage.
     *
     * @param spent Amount spent
     * @param budget Total budget
     * @return Percentage of budget used (0-100)
     */
    fun budgetUsagePercent(spent: Double, budget: Double): Int {
        if (budget <= 0) return 0
        return ((spent / budget) * 100).toInt().coerceIn(0, 100)
    }

    // Default token estimates for cost estimation
    private const val DEFAULT_INPUT_TOKENS_PER_DOC = 800
    private const val DEFAULT_OUTPUT_TOKENS_PER_DOC = 150
    private const val QUERY_CONVERSION_INPUT_TOKENS = 200
    private const val QUERY_CONVERSION_OUTPUT_TOKENS = 50
    private const val CITATION_INPUT_TOKENS = 1000
    private const val CITATION_OUTPUT_TOKENS = 300
    private const val REPORT_INPUT_TOKENS = 2000
    private const val REPORT_OUTPUT_TOKENS = 800
    private const val ESTIMATED_RELEVANCE_RATE = 0.3
}
