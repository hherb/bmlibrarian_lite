package com.bmlibrarian.factchecker.domain.model

/**
 * Workflow states for the fact-checking process.
 *
 * Represents the various stages a fact-check session can be in,
 * from initial state through completion or failure.
 * Mirrors iOS WorkflowStep enum for cross-platform consistency.
 */
enum class WorkflowStep {
    /** Initial state before any processing begins. */
    IDLE,

    /** Converting user's claim into a PubMed search query. */
    CONVERTING_QUERY,

    /** Searching PubMed/Europe PMC for relevant documents. */
    SEARCHING_PUBMED,

    /** Scoring retrieved documents for relevance. */
    SCORING_DOCUMENTS,

    /** Waiting for user to decide whether to continue or generate report. */
    AWAITING_USER_DECISION,

    /** Extracting citation passages from relevant documents. */
    EXTRACTING_CITATIONS,

    /** Generating the final evidence report. */
    GENERATING_REPORT,

    /** Fetching additional evidence from search providers. */
    FETCHING_MORE_EVIDENCE,

    /** Workflow completed successfully. */
    COMPLETED,

    /** Workflow failed due to an error. */
    FAILED,

    /** Workflow stopped due to budget limits being exceeded. */
    BUDGET_EXCEEDED;

    /**
     * Check if this step represents a terminal state.
     *
     * @return true if the workflow cannot continue from this state
     */
    fun isTerminal(): Boolean = this in listOf(COMPLETED, FAILED, BUDGET_EXCEEDED)

    /**
     * Check if this step represents an active processing state.
     *
     * @return true if the workflow is actively processing
     */
    fun isProcessing(): Boolean = this in listOf(
        CONVERTING_QUERY,
        SEARCHING_PUBMED,
        SCORING_DOCUMENTS,
        EXTRACTING_CITATIONS,
        GENERATING_REPORT,
        FETCHING_MORE_EVIDENCE
    )
}
