package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for WorkflowState sealed class.
 */
class WorkflowStateTest {

    // ==================== Idle State Tests ====================

    @Test
    fun `Idle state has correct step`() {
        val state = WorkflowState.Idle

        assertEquals(WorkflowStep.IDLE, state.step)
    }

    // ==================== ConvertingQuery State Tests ====================

    @Test
    fun `ConvertingQuery state stores claim`() {
        val claim = "Vitamin D prevents COVID-19"
        val state = WorkflowState.ConvertingQuery(claim)

        assertEquals(WorkflowStep.CONVERTING_QUERY, state.step)
        assertEquals(claim, state.claim)
    }

    // ==================== Searching State Tests ====================

    @Test
    fun `Searching state stores query and provider`() {
        val state = WorkflowState.Searching(
            query = "vitamin D COVID-19",
            provider = "PUBMED",
            batchNumber = 1
        )

        assertEquals(WorkflowStep.SEARCHING_PUBMED, state.step)
        assertEquals("vitamin D COVID-19", state.query)
        assertEquals("PUBMED", state.provider)
        assertEquals(1, state.batchNumber)
    }

    // ==================== Scoring State Tests ====================

    @Test
    fun `Scoring state tracks progress`() {
        val state = WorkflowState.Scoring(
            currentDocument = 5,
            totalDocuments = 20
        )

        assertEquals(WorkflowStep.SCORING_DOCUMENTS, state.step)
        assertEquals(5, state.currentDocument)
        assertEquals(20, state.totalDocuments)
    }

    // ==================== AwaitingUserDecision State Tests ====================

    @Test
    fun `AwaitingUserDecision state has correct data`() {
        val state = WorkflowState.AwaitingUserDecision(
            relevantCount = 3,
            targetCount = 10,
            availableCount = 50
        )

        assertEquals(WorkflowStep.AWAITING_USER_DECISION, state.step)
        assertEquals(3, state.relevantCount)
        assertEquals(10, state.targetCount)
        assertEquals(50, state.availableCount)
    }

    // ==================== ExtractingCitations State Tests ====================

    @Test
    fun `ExtractingCitations state tracks progress`() {
        val state = WorkflowState.ExtractingCitations(
            currentDocument = 2,
            totalDocuments = 5
        )

        assertEquals(WorkflowStep.EXTRACTING_CITATIONS, state.step)
        assertEquals(2, state.currentDocument)
        assertEquals(5, state.totalDocuments)
    }

    // ==================== GeneratingReport State Tests ====================

    @Test
    fun `GeneratingReport state has correct step`() {
        val state = WorkflowState.GeneratingReport

        assertEquals(WorkflowStep.GENERATING_REPORT, state.step)
    }

    // ==================== FetchingMoreEvidence State Tests ====================

    @Test
    fun `FetchingMoreEvidence state has optional alternative query`() {
        val stateWithoutQuery = WorkflowState.FetchingMoreEvidence()
        val stateWithQuery = WorkflowState.FetchingMoreEvidence("alternative query")

        assertEquals(WorkflowStep.FETCHING_MORE_EVIDENCE, stateWithoutQuery.step)
        assertNull(stateWithoutQuery.alternativeQuery)

        assertEquals(WorkflowStep.FETCHING_MORE_EVIDENCE, stateWithQuery.step)
        assertEquals("alternative query", stateWithQuery.alternativeQuery)
    }

    // ==================== Completed State Tests ====================

    @Test
    fun `Completed state stores report ID`() {
        val reportId = "report-123"
        val state = WorkflowState.Completed(reportId)

        assertEquals(WorkflowStep.COMPLETED, state.step)
        assertEquals(reportId, state.reportId)
    }

    // ==================== Failed State Tests ====================

    @Test
    fun `Failed state stores error message`() {
        val error = "Network error occurred"
        val state = WorkflowState.Failed(error)

        assertEquals(WorkflowStep.FAILED, state.step)
        assertEquals(error, state.error)
        assertNull(state.cause)
    }

    @Test
    fun `Failed state can store cause exception`() {
        val error = "API error"
        val cause = Exception("Original error")
        val state = WorkflowState.Failed(error, cause)

        assertEquals(error, state.error)
        assertEquals(cause, state.cause)
    }

    // ==================== BudgetExceeded State Tests ====================

    @Test
    fun `BudgetExceeded state stores budget info`() {
        val state = WorkflowState.BudgetExceeded(
            message = "Run budget exceeded",
            currentCostUsd = 0.55,
            budgetLimitUsd = 0.50,
            isMonthly = false
        )

        assertEquals(WorkflowStep.BUDGET_EXCEEDED, state.step)
        assertEquals("Run budget exceeded", state.message)
        assertEquals(0.55, state.currentCostUsd, 0.001)
        assertEquals(0.50, state.budgetLimitUsd, 0.001)
        assertFalse(state.isMonthly)
    }

    @Test
    fun `BudgetExceeded state can indicate monthly budget`() {
        val state = WorkflowState.BudgetExceeded(
            message = "Monthly budget exceeded",
            currentCostUsd = 10.50,
            budgetLimitUsd = 10.00,
            isMonthly = true
        )

        assertTrue(state.isMonthly)
    }

    // ==================== Step Property Tests ====================

    @Test
    fun `all states map to correct workflow steps`() {
        val states = listOf(
            WorkflowState.Idle,
            WorkflowState.ConvertingQuery("claim"),
            WorkflowState.Searching("q", "p", 1),
            WorkflowState.Scoring(1, 1),
            WorkflowState.AwaitingUserDecision(1, 5, 10),
            WorkflowState.ExtractingCitations(1, 1),
            WorkflowState.GeneratingReport,
            WorkflowState.FetchingMoreEvidence(),
            WorkflowState.Completed("id"),
            WorkflowState.Failed("error"),
            WorkflowState.BudgetExceeded("msg", 1.0, 1.0)
        )

        val expectedSteps = listOf(
            WorkflowStep.IDLE,
            WorkflowStep.CONVERTING_QUERY,
            WorkflowStep.SEARCHING_PUBMED,
            WorkflowStep.SCORING_DOCUMENTS,
            WorkflowStep.AWAITING_USER_DECISION,
            WorkflowStep.EXTRACTING_CITATIONS,
            WorkflowStep.GENERATING_REPORT,
            WorkflowStep.FETCHING_MORE_EVIDENCE,
            WorkflowStep.COMPLETED,
            WorkflowStep.FAILED,
            WorkflowStep.BUDGET_EXCEEDED
        )

        states.forEachIndexed { index, state ->
            assertEquals(expectedSteps[index], state.step)
        }
    }
}
