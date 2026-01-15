package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.util.Constants

/**
 * Configuration for the fact-check workflow.
 *
 * Centralizes all workflow parameters to avoid magic numbers and enable
 * easy configuration changes. Values can be overridden when starting a workflow.
 *
 * @property searchProvider Which search provider(s) to use
 * @property includePreprints Whether to include preprints in search results
 * @property batchSize Number of documents to fetch per batch
 * @property relevanceThreshold Minimum score (1-5) to consider a document relevant
 * @property targetRelevantDocuments Target number of relevant documents before stopping
 * @property maxBatches Maximum number of search batches to fetch
 * @property maxRunBudgetUsd Maximum spending allowed for this workflow run (USD)
 * @property monthlyBudgetUsd Monthly budget limit (USD)
 * @property smartSearchEnabled Whether to try alternative queries if initial results are poor
 * @property smartSearchThreshold Minimum relevant documents before triggering smart search
 */
data class WorkflowConfig(
    val searchProvider: SearchProvider = SearchProvider.PUBMED,
    val includePreprints: Boolean = false,
    val batchSize: Int = DEFAULT_BATCH_SIZE,
    val relevanceThreshold: Int = Constants.SCORING_MIN_RELEVANT_SCORE,
    val targetRelevantDocuments: Int = DEFAULT_TARGET_RELEVANT_DOCUMENTS,
    val maxBatches: Int = DEFAULT_MAX_BATCHES,
    val maxRunBudgetUsd: Double = Constants.DEFAULT_MAX_RUN_BUDGET_USD.toDouble(),
    val monthlyBudgetUsd: Double = Constants.DEFAULT_MONTHLY_BUDGET_USD.toDouble(),
    val smartSearchEnabled: Boolean = true,
    val smartSearchThreshold: Int = DEFAULT_SMART_SEARCH_THRESHOLD
) {

    /**
     * Validate the configuration values.
     *
     * @return List of validation error messages, empty if valid
     */
    fun validate(): List<String> {
        val errors = mutableListOf<String>()

        if (batchSize < MIN_BATCH_SIZE || batchSize > MAX_BATCH_SIZE) {
            errors.add("Batch size must be between $MIN_BATCH_SIZE and $MAX_BATCH_SIZE")
        }

        if (relevanceThreshold < Constants.SCORING_MIN_SCORE ||
            relevanceThreshold > Constants.SCORING_MAX_SCORE) {
            errors.add("Relevance threshold must be between ${Constants.SCORING_MIN_SCORE} and ${Constants.SCORING_MAX_SCORE}")
        }

        if (targetRelevantDocuments < 1) {
            errors.add("Target relevant documents must be at least 1")
        }

        if (maxBatches < 1) {
            errors.add("Max batches must be at least 1")
        }

        if (maxRunBudgetUsd <= 0) {
            errors.add("Max run budget must be positive")
        }

        if (monthlyBudgetUsd <= 0) {
            errors.add("Monthly budget must be positive")
        }

        if (smartSearchThreshold < 0) {
            errors.add("Smart search threshold cannot be negative")
        }

        return errors
    }

    /**
     * Check if configuration is valid.
     *
     * @return true if all values are valid
     */
    fun isValid(): Boolean = validate().isEmpty()

    companion object {
        /** Default number of documents per batch. */
        const val DEFAULT_BATCH_SIZE = 20

        /** Minimum allowed batch size. */
        const val MIN_BATCH_SIZE = 5

        /** Maximum allowed batch size. */
        const val MAX_BATCH_SIZE = 100

        /** Default target number of relevant documents. */
        const val DEFAULT_TARGET_RELEVANT_DOCUMENTS = 10

        /** Default maximum number of search batches. */
        const val DEFAULT_MAX_BATCHES = 5

        /** Default threshold for triggering smart search. */
        const val DEFAULT_SMART_SEARCH_THRESHOLD = 3

        /**
         * Create a default configuration.
         *
         * @return Default WorkflowConfig instance
         */
        fun default(): WorkflowConfig = WorkflowConfig()

        /**
         * Create a minimal configuration for testing.
         *
         * @return Configuration with minimal settings for faster testing
         */
        fun forTesting(): WorkflowConfig = WorkflowConfig(
            batchSize = MIN_BATCH_SIZE,
            targetRelevantDocuments = 3,
            maxBatches = 2,
            maxRunBudgetUsd = 0.10,
            smartSearchEnabled = false
        )
    }
}
