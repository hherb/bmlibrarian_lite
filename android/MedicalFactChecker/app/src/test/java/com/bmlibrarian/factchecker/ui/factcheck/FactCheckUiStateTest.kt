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

package com.bmlibrarian.factchecker.ui.factcheck

import com.bmlibrarian.factchecker.domain.workflow.WorkflowProgress
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for FactCheckUiState data class.
 *
 * Tests the UI state model used by FactCheckViewModel.
 */
class FactCheckUiStateTest {

    // ==================== Default State Tests ====================

    @Test
    fun `default state has empty claim text`() {
        val state = FactCheckUiState()

        assertEquals("", state.claimText)
    }

    @Test
    fun `default state is not running`() {
        val state = FactCheckUiState()

        assertFalse(state.isRunning)
    }

    @Test
    fun `default state has Idle workflow state`() {
        val state = FactCheckUiState()

        assertEquals(WorkflowState.Idle, state.workflowState)
    }

    @Test
    fun `default state has idle progress`() {
        val state = FactCheckUiState()

        assertEquals(WorkflowProgress.idle(), state.progress)
    }

    @Test
    fun `default state has empty documents list`() {
        val state = FactCheckUiState()

        assertTrue(state.documents.isEmpty())
    }

    @Test
    fun `default state does not show config warning`() {
        val state = FactCheckUiState()

        assertFalse(state.showConfigWarning)
    }

    @Test
    fun `default state has no error message`() {
        val state = FactCheckUiState()

        assertNull(state.errorMessage)
    }

    @Test
    fun `default state has zero monthly usage`() {
        val state = FactCheckUiState()

        assertEquals(0.0, state.monthlyUsedUsd, 0.001)
    }

    @Test
    fun `default state has default budget values`() {
        val state = FactCheckUiState()

        assertEquals(
            Constants.DEFAULT_MONTHLY_BUDGET_USD.toDouble(),
            state.monthlyBudgetUsd,
            0.001
        )
        assertEquals(
            Constants.DEFAULT_MAX_RUN_BUDGET_USD.toDouble(),
            state.runBudgetUsd,
            0.001
        )
    }

    // ==================== State Update Tests ====================

    @Test
    fun `can update claim text`() {
        val state = FactCheckUiState()
        val updated = state.copy(claimText = "Vitamin D prevents COVID")

        assertEquals("Vitamin D prevents COVID", updated.claimText)
    }

    @Test
    fun `can update running state`() {
        val state = FactCheckUiState()
        val updated = state.copy(isRunning = true)

        assertTrue(updated.isRunning)
    }

    @Test
    fun `can update workflow state`() {
        val state = FactCheckUiState()
        val newWorkflowState = WorkflowState.ConvertingQuery("test claim")
        val updated = state.copy(workflowState = newWorkflowState)

        assertEquals(newWorkflowState, updated.workflowState)
    }

    @Test
    fun `can update config warning`() {
        val state = FactCheckUiState()
        val updated = state.copy(showConfigWarning = true)

        assertTrue(updated.showConfigWarning)
    }

    @Test
    fun `can update error message`() {
        val state = FactCheckUiState()
        val updated = state.copy(errorMessage = "Network error")

        assertEquals("Network error", updated.errorMessage)
    }

    @Test
    fun `can update budget values`() {
        val state = FactCheckUiState()
        val updated = state.copy(
            monthlyUsedUsd = 5.50,
            monthlyBudgetUsd = 20.0,
            runBudgetUsd = 1.0
        )

        assertEquals(5.50, updated.monthlyUsedUsd, 0.001)
        assertEquals(20.0, updated.monthlyBudgetUsd, 0.001)
        assertEquals(1.0, updated.runBudgetUsd, 0.001)
    }

    // ==================== Workflow State Mapping Tests ====================

    @Test
    fun `isRunning is true for ConvertingQuery state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.ConvertingQuery("claim"),
            isRunning = true
        )

        assertTrue(state.isRunning)
    }

    @Test
    fun `isRunning is true for Searching state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.Searching("query", "PUBMED", 1),
            isRunning = true
        )

        assertTrue(state.isRunning)
    }

    @Test
    fun `isRunning is true for Scoring state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.Scoring(1, 10),
            isRunning = true
        )

        assertTrue(state.isRunning)
    }

    @Test
    fun `isRunning is false for Completed state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.Completed("report-id"),
            isRunning = false
        )

        assertFalse(state.isRunning)
    }

    @Test
    fun `isRunning is false for Failed state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.Failed("error"),
            isRunning = false
        )

        assertFalse(state.isRunning)
    }

    @Test
    fun `isRunning is false for AwaitingUserDecision state`() {
        val state = FactCheckUiState(
            workflowState = WorkflowState.AwaitingUserDecision(3, 10, 50),
            isRunning = false
        )

        assertFalse(state.isRunning)
    }

    // ==================== Error State Tests ====================

    @Test
    fun `error from Failed workflow state`() {
        val errorMessage = "API rate limit exceeded"
        val state = FactCheckUiState(
            workflowState = WorkflowState.Failed(errorMessage),
            errorMessage = errorMessage
        )

        assertEquals(errorMessage, state.errorMessage)
    }

    @Test
    fun `error from BudgetExceeded workflow state`() {
        val budgetMessage = "Monthly budget exceeded"
        val state = FactCheckUiState(
            workflowState = WorkflowState.BudgetExceeded(
                message = budgetMessage,
                currentCostUsd = 10.5,
                budgetLimitUsd = 10.0
            ),
            errorMessage = budgetMessage
        )

        assertEquals(budgetMessage, state.errorMessage)
    }

    // ==================== Data Class Equality Tests ====================

    @Test
    fun `states with same values are equal`() {
        val state1 = FactCheckUiState(claimText = "test")
        val state2 = FactCheckUiState(claimText = "test")

        assertEquals(state1, state2)
    }

    @Test
    fun `states with different values are not equal`() {
        val state1 = FactCheckUiState(claimText = "test1")
        val state2 = FactCheckUiState(claimText = "test2")

        assertFalse(state1 == state2)
    }
}
