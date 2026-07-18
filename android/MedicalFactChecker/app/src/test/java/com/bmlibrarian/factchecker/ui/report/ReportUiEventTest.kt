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

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Unit tests for ReportUiEvent sealed class.
 *
 * Tests the one-shot events emitted by ReportViewModel.
 */
class ReportUiEventTest {

    // ==================== OpenUrl Event Tests ====================

    @Test
    fun `OpenUrl event contains correct url`() {
        val url = "https://pubmed.ncbi.nlm.nih.gov/12345678/"
        val event = ReportUiEvent.OpenUrl(url)

        assertEquals(url, event.url)
    }

    @Test
    fun `OpenUrl event is ReportUiEvent subclass`() {
        val event: ReportUiEvent = ReportUiEvent.OpenUrl("https://example.com")

        // Verify event is properly typed as ReportUiEvent
        assertEquals("https://example.com", (event as ReportUiEvent.OpenUrl).url)
    }

    // ==================== ShareText Event Tests ====================

    @Test
    fun `ShareText event contains correct subject and text`() {
        val subject = "Medical Fact Check Report"
        val text = "Report content here"
        val event = ReportUiEvent.ShareText(subject, text)

        assertEquals(subject, event.subject)
        assertEquals(text, event.text)
    }

    @Test
    fun `ShareText event is ReportUiEvent subclass`() {
        val event: ReportUiEvent = ReportUiEvent.ShareText("Subject", "Text")

        // Verify event is properly typed as ReportUiEvent
        assertEquals("Subject", (event as ReportUiEvent.ShareText).subject)
    }

    @Test
    fun `ShareText event handles multiline text`() {
        val text = """
            Medical Fact Check Report
            ========================

            Verdict: Supported

            Summary text here.
        """.trimIndent()
        val event = ReportUiEvent.ShareText("Report", text)

        assertTrue(event.text.contains("Verdict: Supported"))
    }

    // ==================== ShareFile Event Tests ====================

    @Test
    fun `ShareFile event contains correct file and mime type`() {
        val file = File("/cache/exports/report.pdf")
        val mimeType = "application/pdf"
        val event = ReportUiEvent.ShareFile(file, mimeType)

        assertEquals(file, event.file)
        assertEquals(mimeType, event.mimeType)
    }

    @Test
    fun `ShareFile event is ReportUiEvent subclass`() {
        val event: ReportUiEvent = ReportUiEvent.ShareFile(File("test.pdf"), "application/pdf")

        // Verify event is properly typed as ReportUiEvent
        assertEquals("application/pdf", (event as ReportUiEvent.ShareFile).mimeType)
    }

    // ==================== ShowSnackbar Event Tests ====================

    @Test
    fun `ShowSnackbar event contains correct message`() {
        val message = "Export failed: Network error"
        val event = ReportUiEvent.ShowSnackbar(message)

        assertEquals(message, event.message)
    }

    @Test
    fun `ShowSnackbar event is ReportUiEvent subclass`() {
        val event: ReportUiEvent = ReportUiEvent.ShowSnackbar("Error message")

        // Verify event is properly typed as ReportUiEvent
        assertEquals("Error message", (event as ReportUiEvent.ShowSnackbar).message)
    }

    // ==================== When Expression Exhaustiveness Tests ====================

    @Test
    fun `can pattern match on all event types`() {
        val events = listOf<ReportUiEvent>(
            ReportUiEvent.OpenUrl("https://example.com"),
            ReportUiEvent.ShareText("Subject", "Text"),
            ReportUiEvent.ShareFile(File("test.pdf"), "application/pdf"),
            ReportUiEvent.ShowSnackbar("Message"),
            ReportUiEvent.NavigateToFullText("doc-123")
        )

        events.forEach { event ->
            val result = when (event) {
                is ReportUiEvent.OpenUrl -> "open"
                is ReportUiEvent.ShareText -> "text"
                is ReportUiEvent.ShareFile -> "file"
                is ReportUiEvent.ShowSnackbar -> "snackbar"
                is ReportUiEvent.NavigateToFullText -> "navigate"
            }
            assertTrue(result.isNotEmpty())
        }
    }

    // ==================== Data Class Equality Tests ====================

    @Test
    fun `OpenUrl events with same url are equal`() {
        val event1 = ReportUiEvent.OpenUrl("https://example.com")
        val event2 = ReportUiEvent.OpenUrl("https://example.com")

        assertEquals(event1, event2)
    }

    @Test
    fun `ShareText events with same content are equal`() {
        val event1 = ReportUiEvent.ShareText("Subject", "Text")
        val event2 = ReportUiEvent.ShareText("Subject", "Text")

        assertEquals(event1, event2)
    }

    @Test
    fun `ShowSnackbar events with same message are equal`() {
        val event1 = ReportUiEvent.ShowSnackbar("Error")
        val event2 = ReportUiEvent.ShowSnackbar("Error")

        assertEquals(event1, event2)
    }
}
