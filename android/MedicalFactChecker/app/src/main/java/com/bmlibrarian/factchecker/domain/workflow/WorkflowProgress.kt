package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.WorkflowStep

/**
 * Progress information for UI display during workflow execution.
 *
 * Provides detailed progress metrics for rendering progress indicators
 * and status messages to the user.
 *
 * @property step Current workflow step
 * @property message Human-readable progress message
 * @property percentage Overall completion percentage (0.0 to 1.0)
 * @property documentsFound Total documents found from search
 * @property documentsScored Documents scored so far
 * @property relevantDocuments Documents meeting relevance threshold
 * @property citationsExtracted Citation passages extracted
 * @property currentCostUsd Estimated cost accumulated so far (USD)
 * @property currentBatch Current batch number for pagination
 * @property totalBatches Total batches expected (if known)
 */
data class WorkflowProgress(
    val step: WorkflowStep,
    val message: String,
    val percentage: Float,
    val documentsFound: Int = 0,
    val documentsScored: Int = 0,
    val relevantDocuments: Int = 0,
    val citationsExtracted: Int = 0,
    val currentCostUsd: Double = 0.0,
    val currentBatch: Int = 1,
    val totalBatches: Int? = null
) {
    /**
     * Check if workflow is actively processing (not idle, completed, or failed).
     *
     * @return true if workflow is in a processing state
     */
    val isProcessing: Boolean
        get() = step.isProcessing()

    /**
     * Check if workflow has completed (successfully or otherwise).
     *
     * @return true if workflow is in a terminal state
     */
    val isComplete: Boolean
        get() = step.isTerminal()

    /**
     * Get percentage as an integer (0-100).
     *
     * @return Integer percentage value
     */
    val percentageInt: Int
        get() = (percentage * 100).toInt().coerceIn(0, 100)

    /**
     * Format cost as a displayable string.
     *
     * @return Formatted cost string (e.g., "$0.05")
     */
    val formattedCost: String
        get() = String.format("$%.2f", currentCostUsd)

    companion object {
        /**
         * Create initial idle progress.
         *
         * @return Progress indicating idle state
         */
        fun idle(): WorkflowProgress = WorkflowProgress(
            step = WorkflowStep.IDLE,
            message = "Ready",
            percentage = 0f
        )

        /**
         * Progress percentages for each workflow step.
         * Used for calculating overall completion percentage.
         */
        val STEP_PERCENTAGES = mapOf(
            WorkflowStep.IDLE to 0f,
            WorkflowStep.CONVERTING_QUERY to 0.05f,
            WorkflowStep.SEARCHING_PUBMED to 0.20f,
            WorkflowStep.SCORING_DOCUMENTS to 0.50f,
            WorkflowStep.AWAITING_USER_DECISION to 0.55f,
            WorkflowStep.EXTRACTING_CITATIONS to 0.75f,
            WorkflowStep.GENERATING_REPORT to 0.90f,
            WorkflowStep.FETCHING_MORE_EVIDENCE to 0.60f,
            WorkflowStep.COMPLETED to 1.0f,
            WorkflowStep.FAILED to 1.0f,
            WorkflowStep.BUDGET_EXCEEDED to 1.0f
        )

        /**
         * Get the base percentage for a workflow step.
         *
         * @param step The workflow step
         * @return Base percentage for that step
         */
        fun basePercentageFor(step: WorkflowStep): Float = STEP_PERCENTAGES[step] ?: 0f

        // ==================== Intermediate Progress Constants ====================
        // These constants represent progress within workflow steps for fine-grained UI updates.

        /** Progress percentage when starting document search. */
        const val PROGRESS_SEARCHING_START = 0.15f

        /** Progress percentage when starting document scoring. */
        const val PROGRESS_SCORING_START = 0.25f

        /** Progress range for document scoring (scoring goes from SCORING_START to this + SCORING_START). */
        const val PROGRESS_SCORING_RANGE = 0.25f

        /** Progress percentage when awaiting user decision. */
        const val PROGRESS_AWAITING_USER = 0.50f

        /** Progress percentage when starting citation extraction. */
        const val PROGRESS_EXTRACTION_START = 0.60f

        /** Progress range for citation extraction (from EXTRACTION_START to this + EXTRACTION_START). */
        const val PROGRESS_EXTRACTION_RANGE = 0.15f

        /** Progress percentage when scoring new documents during fetch more evidence. */
        const val PROGRESS_SCORING_MORE_EVIDENCE = 0.65f

        /** Progress percentage when starting report generation. */
        const val PROGRESS_REPORT_GENERATION = 0.85f

        /** Progress percentage when workflow is complete. */
        const val PROGRESS_COMPLETE = 1.0f
    }
}
