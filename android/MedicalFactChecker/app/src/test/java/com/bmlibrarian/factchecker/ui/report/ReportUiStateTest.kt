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

package com.bmlibrarian.factchecker.ui.report

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.domain.model.Verdict
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for ReportUiState data class.
 *
 * Tests the UI state model used by ReportViewModel.
 */
class ReportUiStateTest {

    // ==================== Default State Tests ====================

    @Test
    fun `default state has null report`() {
        val state = ReportUiState()

        assertNull(state.report)
    }

    @Test
    fun `default state has empty documents list`() {
        val state = ReportUiState()

        assertTrue(state.documents.isEmpty())
    }

    @Test
    fun `default state has null selected document`() {
        val state = ReportUiState()

        assertNull(state.selectedDocument)
    }

    @Test
    fun `default state does not show document sheet`() {
        val state = ReportUiState()

        assertFalse(state.showDocumentSheet)
    }

    @Test
    fun `default state is not exporting`() {
        val state = ReportUiState()

        assertFalse(state.isExporting)
    }

    @Test
    fun `default state has no export error`() {
        val state = ReportUiState()

        assertNull(state.exportError)
    }

    @Test
    fun `default state is loading`() {
        val state = ReportUiState()

        assertTrue(state.isLoading)
    }

    // ==================== State Update Tests ====================

    @Test
    fun `can update report`() {
        val report = createTestReport()
        val state = ReportUiState().copy(report = report)

        assertEquals(report, state.report)
    }

    @Test
    fun `can update documents`() {
        val documents = listOf(createTestDocument("doc-1"), createTestDocument("doc-2"))
        val state = ReportUiState().copy(documents = documents)

        assertEquals(2, state.documents.size)
    }

    @Test
    fun `can update selected document and show sheet`() {
        val document = createTestDocument("doc-1")
        val state = ReportUiState().copy(
            selectedDocument = document,
            showDocumentSheet = true
        )

        assertEquals(document, state.selectedDocument)
        assertTrue(state.showDocumentSheet)
    }

    @Test
    fun `can update exporting state`() {
        val state = ReportUiState().copy(isExporting = true)

        assertTrue(state.isExporting)
    }

    @Test
    fun `can update export error`() {
        val state = ReportUiState().copy(exportError = "PDF export failed")

        assertEquals("PDF export failed", state.exportError)
    }

    @Test
    fun `can update loading state`() {
        val state = ReportUiState().copy(isLoading = false)

        assertFalse(state.isLoading)
    }

    // ==================== Combined State Tests ====================

    @Test
    fun `state with report and documents`() {
        val report = createTestReport()
        val documents = listOf(
            createTestDocument("doc-1"),
            createTestDocument("doc-2"),
            createTestDocument("doc-3")
        )

        val state = ReportUiState(
            report = report,
            documents = documents,
            isLoading = false
        )

        assertEquals(report, state.report)
        assertEquals(3, state.documents.size)
        assertFalse(state.isLoading)
    }

    @Test
    fun `export in progress state`() {
        val state = ReportUiState(
            report = createTestReport(),
            isExporting = true,
            exportError = null,
            isLoading = false
        )

        assertTrue(state.isExporting)
        assertNull(state.exportError)
    }

    @Test
    fun `export failed state`() {
        val state = ReportUiState(
            report = createTestReport(),
            isExporting = false,
            exportError = "Failed to generate PDF",
            isLoading = false
        )

        assertFalse(state.isExporting)
        assertEquals("Failed to generate PDF", state.exportError)
    }

    // ==================== Data Class Equality Tests ====================

    @Test
    fun `states with same values are equal`() {
        val report = createTestReport()
        val state1 = ReportUiState(report = report, isLoading = false)
        val state2 = ReportUiState(report = report, isLoading = false)

        assertEquals(state1, state2)
    }

    @Test
    fun `states with different values are not equal`() {
        val state1 = ReportUiState(isLoading = true)
        val state2 = ReportUiState(isLoading = false)

        assertFalse(state1 == state2)
    }

    // ==================== Helper Functions ====================

    private fun createTestReport(): ReportEntity {
        return ReportEntity(
            id = "report-1",
            sessionId = "session-1",
            verdict = Verdict.SUPPORTED,
            summary = "Test summary",
            fullReportMarkdown = "# Test Report\n\nContent here.",
            modelUsed = "claude-sonnet-4-20250514",
            totalDocumentsReviewed = 10,
            relevantDocumentsCount = 5,
            citationsCount = 3
        )
    }

    private fun createTestDocument(id: String): DocumentEntity {
        return DocumentEntity(
            id = id,
            sessionId = "session-1",
            pmid = "12345678",
            title = "Test Document $id",
            authors = listOf("Author A", "Author B"),
            journal = "Test Journal",
            publicationYear = 2024
        )
    }
}
