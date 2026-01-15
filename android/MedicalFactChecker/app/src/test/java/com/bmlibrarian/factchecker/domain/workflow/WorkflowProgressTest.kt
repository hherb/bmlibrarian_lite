package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for WorkflowProgress data class.
 */
class WorkflowProgressTest {

    // ==================== Idle Progress Tests ====================

    @Test
    fun `idle progress has correct defaults`() {
        val progress = WorkflowProgress.idle()

        assertEquals(WorkflowStep.IDLE, progress.step)
        assertEquals("Ready", progress.message)
        assertEquals(0f, progress.percentage, 0.001f)
        assertEquals(0, progress.documentsFound)
        assertEquals(0, progress.documentsScored)
        assertEquals(0, progress.relevantDocuments)
        assertEquals(0, progress.citationsExtracted)
        assertEquals(0.0, progress.currentCostUsd, 0.001)
        assertEquals(1, progress.currentBatch)
    }

    // ==================== Processing State Tests ====================

    @Test
    fun `isProcessing returns true for processing steps`() {
        val processingSteps = listOf(
            WorkflowStep.CONVERTING_QUERY,
            WorkflowStep.SEARCHING_PUBMED,
            WorkflowStep.SCORING_DOCUMENTS,
            WorkflowStep.EXTRACTING_CITATIONS,
            WorkflowStep.GENERATING_REPORT,
            WorkflowStep.FETCHING_MORE_EVIDENCE
        )

        processingSteps.forEach { step ->
            val progress = WorkflowProgress(step, "Test", 0.5f)
            assertTrue("$step should be processing", progress.isProcessing)
        }
    }

    @Test
    fun `isProcessing returns false for non-processing steps`() {
        val nonProcessingSteps = listOf(
            WorkflowStep.IDLE,
            WorkflowStep.AWAITING_USER_DECISION,
            WorkflowStep.COMPLETED,
            WorkflowStep.FAILED,
            WorkflowStep.BUDGET_EXCEEDED
        )

        nonProcessingSteps.forEach { step ->
            val progress = WorkflowProgress(step, "Test", 0.5f)
            assertFalse("$step should not be processing", progress.isProcessing)
        }
    }

    // ==================== Complete State Tests ====================

    @Test
    fun `isComplete returns true for terminal steps`() {
        val terminalSteps = listOf(
            WorkflowStep.COMPLETED,
            WorkflowStep.FAILED,
            WorkflowStep.BUDGET_EXCEEDED
        )

        terminalSteps.forEach { step ->
            val progress = WorkflowProgress(step, "Test", 1.0f)
            assertTrue("$step should be complete", progress.isComplete)
        }
    }

    @Test
    fun `isComplete returns false for non-terminal steps`() {
        val nonTerminalSteps = listOf(
            WorkflowStep.IDLE,
            WorkflowStep.CONVERTING_QUERY,
            WorkflowStep.SEARCHING_PUBMED,
            WorkflowStep.SCORING_DOCUMENTS,
            WorkflowStep.AWAITING_USER_DECISION,
            WorkflowStep.EXTRACTING_CITATIONS,
            WorkflowStep.GENERATING_REPORT,
            WorkflowStep.FETCHING_MORE_EVIDENCE
        )

        nonTerminalSteps.forEach { step ->
            val progress = WorkflowProgress(step, "Test", 0.5f)
            assertFalse("$step should not be complete", progress.isComplete)
        }
    }

    // ==================== Percentage Tests ====================

    @Test
    fun `percentageInt converts correctly`() {
        val progress25 = WorkflowProgress(WorkflowStep.IDLE, "Test", 0.25f)
        val progress50 = WorkflowProgress(WorkflowStep.IDLE, "Test", 0.50f)
        val progress100 = WorkflowProgress(WorkflowStep.IDLE, "Test", 1.0f)

        assertEquals(25, progress25.percentageInt)
        assertEquals(50, progress50.percentageInt)
        assertEquals(100, progress100.percentageInt)
    }

    @Test
    fun `percentageInt clamps to valid range`() {
        val progressNegative = WorkflowProgress(WorkflowStep.IDLE, "Test", -0.5f)
        val progressOver = WorkflowProgress(WorkflowStep.IDLE, "Test", 1.5f)

        assertEquals(0, progressNegative.percentageInt)
        assertEquals(100, progressOver.percentageInt)
    }

    @Test
    fun `percentageInt rounds correctly`() {
        val progress = WorkflowProgress(WorkflowStep.IDLE, "Test", 0.456f)

        assertEquals(45, progress.percentageInt)
    }

    // ==================== Formatted Cost Tests ====================

    @Test
    fun `formattedCost formats correctly`() {
        val progressZero = WorkflowProgress(WorkflowStep.IDLE, "Test", 0f, currentCostUsd = 0.0)
        val progressSmall = WorkflowProgress(WorkflowStep.IDLE, "Test", 0f, currentCostUsd = 0.05)
        val progressLarge = WorkflowProgress(WorkflowStep.IDLE, "Test", 0f, currentCostUsd = 10.50)
        val progressFractional = WorkflowProgress(WorkflowStep.IDLE, "Test", 0f, currentCostUsd = 0.123)

        assertEquals("$0.00", progressZero.formattedCost)
        assertEquals("$0.05", progressSmall.formattedCost)
        assertEquals("$10.50", progressLarge.formattedCost)
        assertEquals("$0.12", progressFractional.formattedCost)
    }

    // ==================== Step Percentages Tests ====================

    @Test
    fun `STEP_PERCENTAGES contains all workflow steps`() {
        WorkflowStep.entries.forEach { step ->
            assertTrue(
                "Missing percentage for $step",
                WorkflowProgress.STEP_PERCENTAGES.containsKey(step)
            )
        }
    }

    @Test
    fun `STEP_PERCENTAGES are in valid range`() {
        WorkflowProgress.STEP_PERCENTAGES.forEach { (step, percentage) ->
            assertTrue("$step percentage should be >= 0", percentage >= 0f)
            assertTrue("$step percentage should be <= 1", percentage <= 1f)
        }
    }

    @Test
    fun `STEP_PERCENTAGES increase through workflow`() {
        // Early steps should have lower percentages than later steps
        val convertingQuery = WorkflowProgress.basePercentageFor(WorkflowStep.CONVERTING_QUERY)
        val searching = WorkflowProgress.basePercentageFor(WorkflowStep.SEARCHING_PUBMED)
        val scoring = WorkflowProgress.basePercentageFor(WorkflowStep.SCORING_DOCUMENTS)
        val extracting = WorkflowProgress.basePercentageFor(WorkflowStep.EXTRACTING_CITATIONS)
        val generating = WorkflowProgress.basePercentageFor(WorkflowStep.GENERATING_REPORT)
        val completed = WorkflowProgress.basePercentageFor(WorkflowStep.COMPLETED)

        assertTrue(convertingQuery < searching)
        assertTrue(searching < scoring)
        assertTrue(scoring < extracting)
        assertTrue(extracting < generating)
        assertTrue(generating < completed)
        assertEquals(1.0f, completed, 0.001f)
    }

    @Test
    fun `terminal states have 100 percent`() {
        assertEquals(1.0f, WorkflowProgress.basePercentageFor(WorkflowStep.COMPLETED), 0.001f)
        assertEquals(1.0f, WorkflowProgress.basePercentageFor(WorkflowStep.FAILED), 0.001f)
        assertEquals(1.0f, WorkflowProgress.basePercentageFor(WorkflowStep.BUDGET_EXCEEDED), 0.001f)
    }

    // ==================== Progress Data Tests ====================

    @Test
    fun `progress stores all metrics correctly`() {
        val progress = WorkflowProgress(
            step = WorkflowStep.SCORING_DOCUMENTS,
            message = "Scoring document 5 of 20",
            percentage = 0.35f,
            documentsFound = 20,
            documentsScored = 5,
            relevantDocuments = 2,
            citationsExtracted = 0,
            currentCostUsd = 0.03,
            currentBatch = 1,
            totalBatches = 3
        )

        assertEquals(WorkflowStep.SCORING_DOCUMENTS, progress.step)
        assertEquals("Scoring document 5 of 20", progress.message)
        assertEquals(0.35f, progress.percentage, 0.001f)
        assertEquals(20, progress.documentsFound)
        assertEquals(5, progress.documentsScored)
        assertEquals(2, progress.relevantDocuments)
        assertEquals(0, progress.citationsExtracted)
        assertEquals(0.03, progress.currentCostUsd, 0.001)
        assertEquals(1, progress.currentBatch)
        assertEquals(3, progress.totalBatches)
    }

    @Test
    fun `totalBatches can be null`() {
        val progress = WorkflowProgress(
            step = WorkflowStep.SEARCHING_PUBMED,
            message = "Searching...",
            percentage = 0.15f,
            totalBatches = null
        )

        assertEquals(null, progress.totalBatches)
    }
}
