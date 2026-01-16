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
        val event = ReportUiEvent.OpenUrl("https://example.com")

        assertTrue(event is ReportUiEvent)
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
        val event = ReportUiEvent.ShareText("Subject", "Text")

        assertTrue(event is ReportUiEvent)
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
        val event = ReportUiEvent.ShareFile(File("test.pdf"), "application/pdf")

        assertTrue(event is ReportUiEvent)
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
        val event = ReportUiEvent.ShowSnackbar("Error message")

        assertTrue(event is ReportUiEvent)
    }

    // ==================== When Expression Exhaustiveness Tests ====================

    @Test
    fun `can pattern match on all event types`() {
        val events = listOf<ReportUiEvent>(
            ReportUiEvent.OpenUrl("https://example.com"),
            ReportUiEvent.ShareText("Subject", "Text"),
            ReportUiEvent.ShareFile(File("test.pdf"), "application/pdf"),
            ReportUiEvent.ShowSnackbar("Message")
        )

        events.forEach { event ->
            val result = when (event) {
                is ReportUiEvent.OpenUrl -> "open"
                is ReportUiEvent.ShareText -> "text"
                is ReportUiEvent.ShareFile -> "file"
                is ReportUiEvent.ShowSnackbar -> "snackbar"
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
