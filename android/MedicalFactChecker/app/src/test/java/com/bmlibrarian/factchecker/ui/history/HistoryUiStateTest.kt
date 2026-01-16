package com.bmlibrarian.factchecker.ui.history

import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for HistoryUiState and SessionWithReport data classes.
 *
 * Tests the UI state models used by HistoryViewModel.
 */
class HistoryUiStateTest {

    // ==================== Default State Tests ====================

    @Test
    fun `default state has empty sessions list`() {
        val state = HistoryUiState()

        assertTrue(state.sessions.isEmpty())
    }

    @Test
    fun `default state is loading`() {
        val state = HistoryUiState()

        assertTrue(state.isLoading)
    }

    @Test
    fun `default state has null selected session id`() {
        val state = HistoryUiState()

        assertNull(state.selectedSessionId)
    }

    @Test
    fun `default state does not show delete confirmation`() {
        val state = HistoryUiState()

        assertFalse(state.showDeleteConfirmation)
    }

    @Test
    fun `default state does not show clear all confirmation`() {
        val state = HistoryUiState()

        assertFalse(state.showClearAllConfirmation)
    }

    // ==================== State Update Tests ====================

    @Test
    fun `can update sessions list`() {
        val sessions = listOf(
            createSessionWithReport("session-1"),
            createSessionWithReport("session-2")
        )
        val state = HistoryUiState().copy(sessions = sessions)

        assertEquals(2, state.sessions.size)
    }

    @Test
    fun `can update loading state`() {
        val state = HistoryUiState().copy(isLoading = false)

        assertFalse(state.isLoading)
    }

    @Test
    fun `can update selected session id`() {
        val state = HistoryUiState().copy(selectedSessionId = "session-123")

        assertEquals("session-123", state.selectedSessionId)
    }

    @Test
    fun `can show delete confirmation`() {
        val state = HistoryUiState().copy(
            selectedSessionId = "session-123",
            showDeleteConfirmation = true
        )

        assertEquals("session-123", state.selectedSessionId)
        assertTrue(state.showDeleteConfirmation)
    }

    @Test
    fun `can show clear all confirmation`() {
        val state = HistoryUiState().copy(showClearAllConfirmation = true)

        assertTrue(state.showClearAllConfirmation)
    }

    // ==================== Combined State Tests ====================

    @Test
    fun `state with sessions and not loading`() {
        val sessions = listOf(
            createSessionWithReport("session-1"),
            createSessionWithReport("session-2"),
            createSessionWithReport("session-3")
        )

        val state = HistoryUiState(
            sessions = sessions,
            isLoading = false
        )

        assertEquals(3, state.sessions.size)
        assertFalse(state.isLoading)
    }

    @Test
    fun `delete confirmation state`() {
        val state = HistoryUiState(
            sessions = listOf(createSessionWithReport("session-1")),
            selectedSessionId = "session-1",
            showDeleteConfirmation = true,
            isLoading = false
        )

        assertEquals("session-1", state.selectedSessionId)
        assertTrue(state.showDeleteConfirmation)
        assertFalse(state.showClearAllConfirmation)
    }

    // ==================== Data Class Equality Tests ====================

    @Test
    fun `states with same values are equal`() {
        val state1 = HistoryUiState(isLoading = false)
        val state2 = HistoryUiState(isLoading = false)

        assertEquals(state1, state2)
    }

    @Test
    fun `states with different values are not equal`() {
        val state1 = HistoryUiState(isLoading = true)
        val state2 = HistoryUiState(isLoading = false)

        assertFalse(state1 == state2)
    }

    // ==================== SessionWithReport Tests ====================

    @Test
    fun `session with report contains both session and report`() {
        val session = createTestSession("session-1")
        val report = createTestReport("session-1")

        val sessionWithReport = SessionWithReport(session, report)

        assertEquals(session, sessionWithReport.session)
        assertEquals(report, sessionWithReport.report)
    }

    @Test
    fun `session without report has null report`() {
        val session = createTestSession("session-1")

        val sessionWithReport = SessionWithReport(session, null)

        assertEquals(session, sessionWithReport.session)
        assertNull(sessionWithReport.report)
    }

    @Test
    fun `session with report equality`() {
        val session = createTestSession("session-1")
        val report = createTestReport("session-1")

        val swr1 = SessionWithReport(session, report)
        val swr2 = SessionWithReport(session, report)

        assertEquals(swr1, swr2)
    }

    @Test
    fun `sessions with different reports are not equal`() {
        val session = createTestSession("session-1")
        val report1 = createTestReport("session-1").copy(verdict = Verdict.SUPPORTED)
        val report2 = createTestReport("session-1").copy(verdict = Verdict.REFUTED)

        val swr1 = SessionWithReport(session, report1)
        val swr2 = SessionWithReport(session, report2)

        assertFalse(swr1 == swr2)
    }

    // ==================== Helper Functions ====================

    private fun createTestSession(id: String): SessionEntity {
        return SessionEntity(
            id = id,
            claimText = "Test claim for $id"
        )
    }

    private fun createTestReport(sessionId: String): ReportEntity {
        return ReportEntity(
            id = "report-$sessionId",
            sessionId = sessionId,
            verdict = Verdict.LIKELY_SUPPORTED,
            summary = "Test summary for session $sessionId",
            fullReportMarkdown = "# Test Report\n\nContent here.",
            modelUsed = "claude-sonnet-4-20250514",
            totalDocumentsReviewed = 10,
            relevantDocumentsCount = 5,
            citationsCount = 3
        )
    }

    private fun createSessionWithReport(id: String): SessionWithReport {
        return SessionWithReport(
            session = createTestSession(id),
            report = createTestReport(id)
        )
    }
}
