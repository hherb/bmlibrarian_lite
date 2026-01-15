package com.bmlibrarian.factchecker.domain.workflow

/**
 * Sealed class representing budget-related errors in the workflow.
 *
 * Used to signal that a budget limit has been reached and the workflow
 * cannot continue without exceeding the configured limits.
 *
 * @property usedUsd Amount already spent in USD
 * @property limitUsd Budget limit that was exceeded
 */
sealed class BudgetError(
    message: String,
    val usedUsd: Double,
    val limitUsd: Double
) : Exception(message) {

    /**
     * Per-run budget has been exceeded.
     *
     * @property usedUsd Amount spent in this run
     * @property limitUsd The per-run budget limit
     */
    class RunBudgetExceeded(
        usedUsd: Double,
        limitUsd: Double
    ) : BudgetError(
        message = "Run budget exceeded: ${formatCost(usedUsd)} used of ${formatCost(limitUsd)} limit",
        usedUsd = usedUsd,
        limitUsd = limitUsd
    )

    /**
     * Monthly budget has been exceeded.
     *
     * @property usedUsd Amount spent this month
     * @property limitUsd The monthly budget limit
     */
    class MonthlyBudgetExceeded(
        usedUsd: Double,
        limitUsd: Double
    ) : BudgetError(
        message = "Monthly budget exceeded: ${formatCost(usedUsd)} used of ${formatCost(limitUsd)} limit",
        usedUsd = usedUsd,
        limitUsd = limitUsd
    )

    /**
     * Check if this is a monthly budget error (vs per-run).
     *
     * @return true if this represents a monthly budget exceeded error
     */
    val isMonthly: Boolean
        get() = this is MonthlyBudgetExceeded

    /**
     * Get remaining budget (may be negative if already exceeded).
     *
     * @return Remaining budget in USD
     */
    val remainingUsd: Double
        get() = limitUsd - usedUsd

    companion object {
        /**
         * Format a cost value for display.
         *
         * @param amount Amount in USD
         * @return Formatted string (e.g., "$1.23")
         */
        fun formatCost(amount: Double): String = String.format("$%.2f", amount)

        /**
         * Check if a cost would exceed the run budget.
         *
         * @param currentCost Current accumulated cost
         * @param additionalCost Cost to be added
         * @param limit Budget limit
         * @return true if adding the cost would exceed the limit
         */
        fun wouldExceedRunBudget(
            currentCost: Double,
            additionalCost: Double,
            limit: Double
        ): Boolean = (currentCost + additionalCost) > limit

        /**
         * Check if a cost would exceed the monthly budget.
         *
         * @param monthlyCost Total monthly cost so far
         * @param additionalCost Cost to be added
         * @param limit Monthly budget limit
         * @return true if adding the cost would exceed the limit
         */
        fun wouldExceedMonthlyBudget(
            monthlyCost: Double,
            additionalCost: Double,
            limit: Double
        ): Boolean = (monthlyCost + additionalCost) > limit
    }
}
