package com.bmlibrarian.factchecker.domain.workflow

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for BudgetError sealed class.
 */
class BudgetErrorTest {

    // ==================== RunBudgetExceeded Tests ====================

    @Test
    fun `RunBudgetExceeded stores correct values`() {
        val error = BudgetError.RunBudgetExceeded(
            usedUsd = 0.55,
            limitUsd = 0.50
        )

        assertEquals(0.55, error.usedUsd, 0.001)
        assertEquals(0.50, error.limitUsd, 0.001)
        assertFalse(error.isMonthly)
    }

    @Test
    fun `RunBudgetExceeded message contains budget info`() {
        val error = BudgetError.RunBudgetExceeded(
            usedUsd = 0.55,
            limitUsd = 0.50
        )

        val message = error.message ?: ""
        assertTrue(message.contains("0.55"))
        assertTrue(message.contains("0.50"))
        assertTrue(message.lowercase().contains("run budget"))
    }

    @Test
    fun `RunBudgetExceeded calculates remaining budget`() {
        val error = BudgetError.RunBudgetExceeded(
            usedUsd = 0.55,
            limitUsd = 0.50
        )

        assertEquals(-0.05, error.remainingUsd, 0.001)
    }

    // ==================== MonthlyBudgetExceeded Tests ====================

    @Test
    fun `MonthlyBudgetExceeded stores correct values`() {
        val error = BudgetError.MonthlyBudgetExceeded(
            usedUsd = 10.50,
            limitUsd = 10.00
        )

        assertEquals(10.50, error.usedUsd, 0.001)
        assertEquals(10.00, error.limitUsd, 0.001)
        assertTrue(error.isMonthly)
    }

    @Test
    fun `MonthlyBudgetExceeded message contains budget info`() {
        val error = BudgetError.MonthlyBudgetExceeded(
            usedUsd = 10.50,
            limitUsd = 10.00
        )

        val message = error.message ?: ""
        assertTrue(message.contains("10.50"))
        assertTrue(message.contains("10.00"))
        assertTrue(message.lowercase().contains("monthly budget"))
    }

    // ==================== Format Cost Tests ====================

    @Test
    fun `formatCost formats correctly with zero`() {
        assertEquals("$0.00", BudgetError.formatCost(0.0))
    }

    @Test
    fun `formatCost formats correctly with small amount`() {
        assertEquals("$0.05", BudgetError.formatCost(0.05))
    }

    @Test
    fun `formatCost formats correctly with large amount`() {
        assertEquals("$10.50", BudgetError.formatCost(10.5))
    }

    @Test
    fun `formatCost rounds correctly`() {
        assertEquals("$0.12", BudgetError.formatCost(0.123))
        assertEquals("$0.13", BudgetError.formatCost(0.125))
    }

    // ==================== Budget Check Helpers Tests ====================

    @Test
    fun `wouldExceedRunBudget returns true when would exceed`() {
        assertTrue(
            BudgetError.wouldExceedRunBudget(
                currentCost = 0.40,
                additionalCost = 0.15,
                limit = 0.50
            )
        )
    }

    @Test
    fun `wouldExceedRunBudget returns false when within limit`() {
        assertFalse(
            BudgetError.wouldExceedRunBudget(
                currentCost = 0.40,
                additionalCost = 0.09,
                limit = 0.50
            )
        )
    }

    @Test
    fun `wouldExceedRunBudget returns false when exactly at limit`() {
        assertFalse(
            BudgetError.wouldExceedRunBudget(
                currentCost = 0.40,
                additionalCost = 0.10,
                limit = 0.50
            )
        )
    }

    @Test
    fun `wouldExceedMonthlyBudget returns true when would exceed`() {
        assertTrue(
            BudgetError.wouldExceedMonthlyBudget(
                monthlyCost = 9.50,
                additionalCost = 0.75,
                limit = 10.00
            )
        )
    }

    @Test
    fun `wouldExceedMonthlyBudget returns false when within limit`() {
        assertFalse(
            BudgetError.wouldExceedMonthlyBudget(
                monthlyCost = 9.00,
                additionalCost = 0.50,
                limit = 10.00
            )
        )
    }

    // ==================== Exception Behavior Tests ====================

    @Test
    fun `BudgetError is throwable`() {
        val error = BudgetError.RunBudgetExceeded(0.55, 0.50)

        try {
            throw error
        } catch (e: BudgetError) {
            assertEquals(0.55, e.usedUsd, 0.001)
        }
    }

    @Test
    fun `BudgetError can be caught as Exception`() {
        val error = BudgetError.RunBudgetExceeded(0.55, 0.50)

        try {
            throw error
        } catch (e: Exception) {
            assertTrue(e is BudgetError)
        }
    }

    @Test
    fun `isMonthly differentiates error types`() {
        val runError = BudgetError.RunBudgetExceeded(0.55, 0.50)
        val monthlyError = BudgetError.MonthlyBudgetExceeded(10.50, 10.00)

        assertFalse(runError.isMonthly)
        assertTrue(monthlyError.isMonthly)
    }

    // ==================== Remaining Budget Tests ====================

    @Test
    fun `remainingUsd is positive when under limit`() {
        // This shouldn't normally happen (error thrown when exceeded)
        // but testing the calculation works correctly
        val error = BudgetError.RunBudgetExceeded(0.40, 0.50)

        // Note: This creates an "error" even though not exceeded - just for testing
        assertEquals(0.10, error.remainingUsd, 0.001)
    }

    @Test
    fun `remainingUsd is zero at exactly limit`() {
        val error = BudgetError.RunBudgetExceeded(0.50, 0.50)

        assertEquals(0.0, error.remainingUsd, 0.001)
    }

    @Test
    fun `remainingUsd is negative when exceeded`() {
        val error = BudgetError.RunBudgetExceeded(0.75, 0.50)

        assertEquals(-0.25, error.remainingUsd, 0.001)
    }
}
