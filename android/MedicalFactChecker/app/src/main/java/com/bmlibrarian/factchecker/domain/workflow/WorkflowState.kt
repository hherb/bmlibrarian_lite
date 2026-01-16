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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.WorkflowStep

/**
 * Sealed class representing the current state of the fact-check workflow.
 *
 * Each state contains the relevant data for that phase of the workflow.
 * Mirrors the iOS workflow state model for cross-platform consistency.
 */
sealed class WorkflowState {

    /**
     * The workflow step enum value associated with this state.
     */
    abstract val step: WorkflowStep

    /**
     * Idle state - ready to start a new fact check.
     */
    data object Idle : WorkflowState() {
        override val step = WorkflowStep.IDLE
    }

    /**
     * Converting the user's claim to a PubMed search query.
     *
     * @property claim The user's original claim text
     */
    data class ConvertingQuery(
        val claim: String
    ) : WorkflowState() {
        override val step = WorkflowStep.CONVERTING_QUERY
    }

    /**
     * Searching PubMed or Europe PMC for documents.
     *
     * @property query The PubMed query being executed
     * @property provider The search provider being used
     * @property batchNumber Current batch number for pagination
     */
    data class Searching(
        val query: String,
        val provider: String,
        val batchNumber: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.SEARCHING_PUBMED
    }

    /**
     * Scoring documents for relevance to the claim.
     *
     * @property currentDocument Index of document currently being scored (1-based)
     * @property totalDocuments Total number of documents to score
     */
    data class Scoring(
        val currentDocument: Int,
        val totalDocuments: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.SCORING_DOCUMENTS
    }

    /**
     * Waiting for user decision on fetching more documents.
     *
     * Triggered when insufficient relevant documents are found but more
     * are available from the search provider.
     *
     * @property relevantCount Current count of relevant documents (score >= threshold)
     * @property targetCount Minimum relevant documents desired
     * @property availableCount Additional documents available from search provider
     */
    data class AwaitingUserDecision(
        val relevantCount: Int,
        val targetCount: Int,
        val availableCount: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.AWAITING_USER_DECISION
    }

    /**
     * Extracting citation passages from relevant documents.
     *
     * @property currentDocument Index of document currently being processed (1-based)
     * @property totalDocuments Total number of relevant documents to process
     */
    data class ExtractingCitations(
        val currentDocument: Int,
        val totalDocuments: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.EXTRACTING_CITATIONS
    }

    /**
     * Generating the evidence report.
     */
    data object GeneratingReport : WorkflowState() {
        override val step = WorkflowStep.GENERATING_REPORT
    }

    /**
     * Fetching additional evidence after initial report generation.
     *
     * @property alternativeQuery Optional alternative query being tried
     */
    data class FetchingMoreEvidence(
        val alternativeQuery: String? = null
    ) : WorkflowState() {
        override val step = WorkflowStep.FETCHING_MORE_EVIDENCE
    }

    /**
     * Workflow completed successfully.
     *
     * @property reportId ID of the generated report
     */
    data class Completed(
        val reportId: String
    ) : WorkflowState() {
        override val step = WorkflowStep.COMPLETED
    }

    /**
     * Workflow failed with an error.
     *
     * @property error Error message describing the failure
     * @property cause Optional underlying exception
     */
    data class Failed(
        val error: String,
        val cause: Throwable? = null
    ) : WorkflowState() {
        override val step = WorkflowStep.FAILED
    }

    /**
     * Budget exceeded during workflow.
     *
     * @property message Descriptive message about the budget issue
     * @property currentCostUsd Cost accumulated so far in USD
     * @property budgetLimitUsd The budget limit that was exceeded
     * @property isMonthly True if monthly budget was exceeded, false for per-run budget
     */
    data class BudgetExceeded(
        val message: String,
        val currentCostUsd: Double,
        val budgetLimitUsd: Double,
        val isMonthly: Boolean = false
    ) : WorkflowState() {
        override val step = WorkflowStep.BUDGET_EXCEEDED
    }
}
