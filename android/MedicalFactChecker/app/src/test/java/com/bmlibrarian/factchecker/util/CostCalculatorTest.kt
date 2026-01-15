package com.bmlibrarian.factchecker.util

import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.ModelInfo
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for CostCalculator utility.
 */
class CostCalculatorTest {

    // ==================== Cost Calculation Tests ====================

    @Test
    fun `calculateCost computes correct cost for GPT-4o`() {
        val gpt4o = LLMProvider.OPENAI.getModel("gpt-4o")!!
        // GPT-4o: $2.50/1M input, $10.00/1M output

        val cost = CostCalculator.calculateCost(gpt4o, inputTokens = 1000, outputTokens = 500)

        // Expected: (1000/1M * 2.50) + (500/1M * 10.00) = 0.0025 + 0.005 = 0.0075
        assertEquals(0.0075, cost, 0.0001)
    }

    @Test
    fun `calculateCost computes correct cost for Claude Sonnet`() {
        val sonnet = LLMProvider.ANTHROPIC.getModel("claude-sonnet-4-20250514")!!
        // Claude Sonnet: $3.00/1M input, $15.00/1M output

        val cost = CostCalculator.calculateCost(sonnet, inputTokens = 10000, outputTokens = 2000)

        // Expected: (10000/1M * 3.00) + (2000/1M * 15.00) = 0.03 + 0.03 = 0.06
        assertEquals(0.06, cost, 0.0001)
    }

    @Test
    fun `calculateCost returns zero for free models`() {
        val llamaLocal = LLMProvider.OLLAMA.getModel("llama3.2")!!

        val cost = CostCalculator.calculateCost(llamaLocal, inputTokens = 100000, outputTokens = 50000)

        assertEquals(0.0, cost, 0.0001)
    }

    @Test
    fun `calculateCost with provider and model IDs`() {
        val cost = CostCalculator.calculateCost(
            providerId = "openai",
            modelId = "gpt-4o-mini",
            inputTokens = 100000,
            outputTokens = 10000
        )
        // GPT-4o-mini: $0.15/1M input, $0.60/1M output
        // Expected: (100000/1M * 0.15) + (10000/1M * 0.60) = 0.015 + 0.006 = 0.021
        assertEquals(0.021, cost, 0.0001)
    }

    @Test
    fun `calculateCost returns zero for unknown provider`() {
        val cost = CostCalculator.calculateCost(
            providerId = "unknown",
            modelId = "model",
            inputTokens = 1000,
            outputTokens = 500
        )

        assertEquals(0.0, cost, 0.0001)
    }

    @Test
    fun `calculateCost returns zero for unknown model`() {
        val cost = CostCalculator.calculateCost(
            providerId = "openai",
            modelId = "unknown-model",
            inputTokens = 1000,
            outputTokens = 500
        )

        assertEquals(0.0, cost, 0.0001)
    }

    // ==================== Workflow Cost Estimation Tests ====================

    @Test
    fun `estimateWorkflowCost calculates full workflow`() {
        val gpt4oMini = LLMProvider.OPENAI.getModel("gpt-4o-mini")!!

        val cost = CostCalculator.estimateWorkflowCost(
            modelInfo = gpt4oMini,
            documentCount = 20
        )

        // Should include query conversion, scoring, citations (30% of 20 = 6), and report
        assertTrue(cost > 0)
    }

    @Test
    fun `estimateWorkflowCost respects flags`() {
        val gpt4oMini = LLMProvider.OPENAI.getModel("gpt-4o-mini")!!

        val fullCost = CostCalculator.estimateWorkflowCost(
            modelInfo = gpt4oMini,
            documentCount = 10,
            includeQueryConversion = true,
            includeCitations = true,
            includeReport = true
        )

        val minimalCost = CostCalculator.estimateWorkflowCost(
            modelInfo = gpt4oMini,
            documentCount = 10,
            includeQueryConversion = false,
            includeCitations = false,
            includeReport = false
        )

        assertTrue(fullCost > minimalCost)
    }

    // ==================== Cost Formatting Tests ====================

    @Test
    fun `formatCost formats small amounts with cents`() {
        val formatted = CostCalculator.formatCost(0.05)

        assertEquals("$0.05", formatted)
    }

    @Test
    fun `formatCost formats larger amounts`() {
        val formatted = CostCalculator.formatCost(1.23)

        assertEquals("$1.23", formatted)
    }

    @Test
    fun `formatCost formats very small amounts with precision`() {
        val formatted = CostCalculator.formatCost(0.001)

        // Should show more decimal places for very small amounts
        assertTrue(formatted.contains("0.00"))
    }

    @Test
    fun `formatCostShort returns cents for small amounts`() {
        val formatted = CostCalculator.formatCostShort(0.05)

        assertEquals("5c", formatted)
    }

    @Test
    fun `formatCostShort returns less than 1c for very small amounts`() {
        val formatted = CostCalculator.formatCostShort(0.001)

        assertEquals("<1c", formatted)
    }

    @Test
    fun `formatCostShort returns dollar format for amounts over 1 dollar`() {
        val formatted = CostCalculator.formatCostShort(3.50)

        assertEquals("$3.50", formatted)
    }

    @Test
    fun `formatCostShort returns whole dollars for large amounts`() {
        val formatted = CostCalculator.formatCostShort(15.75)

        assertEquals("$16", formatted)
    }

    // ==================== Budget Tests ====================

    @Test
    fun `wouldExceedBudget returns true when over budget`() {
        val result = CostCalculator.wouldExceedBudget(
            currentCost = 0.45,
            additionalCost = 0.10,
            budget = 0.50
        )

        assertTrue(result)
    }

    @Test
    fun `wouldExceedBudget returns false when within budget`() {
        val result = CostCalculator.wouldExceedBudget(
            currentCost = 0.30,
            additionalCost = 0.10,
            budget = 0.50
        )

        assertFalse(result)
    }

    @Test
    fun `wouldExceedBudget returns false when exactly at budget`() {
        val result = CostCalculator.wouldExceedBudget(
            currentCost = 0.40,
            additionalCost = 0.10,
            budget = 0.50
        )

        assertFalse(result)
    }

    @Test
    fun `remainingBudget calculates correctly`() {
        val remaining = CostCalculator.remainingBudget(budget = 10.0, spent = 3.50)

        assertEquals(6.50, remaining, 0.001)
    }

    @Test
    fun `remainingBudget never returns negative`() {
        val remaining = CostCalculator.remainingBudget(budget = 5.0, spent = 10.0)

        assertEquals(0.0, remaining, 0.001)
    }

    @Test
    fun `budgetUsagePercent calculates correctly`() {
        val percent = CostCalculator.budgetUsagePercent(spent = 2.5, budget = 10.0)

        assertEquals(25, percent)
    }

    @Test
    fun `budgetUsagePercent caps at 100`() {
        val percent = CostCalculator.budgetUsagePercent(spent = 15.0, budget = 10.0)

        assertEquals(100, percent)
    }

    @Test
    fun `budgetUsagePercent returns 0 for zero budget`() {
        val percent = CostCalculator.budgetUsagePercent(spent = 5.0, budget = 0.0)

        assertEquals(0, percent)
    }

    // ==================== ModelInfo Tests ====================

    @Test
    fun `ModelInfo isFree returns true for zero pricing`() {
        val freeModel = ModelInfo("test", "Test", 0.0, 0.0)

        assertTrue(freeModel.isFree)
    }

    @Test
    fun `ModelInfo isFree returns false for non-zero pricing`() {
        val paidModel = ModelInfo("test", "Test", 1.0, 2.0)

        assertFalse(paidModel.isFree)
    }
}
