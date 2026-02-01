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

package com.bmlibrarian.factchecker.util

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for ResponseParser utility.
 */
class ResponseParserTest {

    // ==================== Score Response Tests ====================

    @Test
    fun `parseScoreResponse extracts score and rationale from valid JSON`() {
        val json = """{"score": 4, "rationale": "Directly relevant to the claim"}"""

        val result = ResponseParser.parseScoreResponse(json)

        assertEquals(4, result.score)
        assertEquals("Directly relevant to the claim", result.rationale)
    }

    @Test
    fun `parseScoreResponse handles markdown code blocks`() {
        val json = """```json
        {"score": 3, "rationale": "Moderately relevant"}
        ```"""

        val result = ResponseParser.parseScoreResponse(json)

        assertEquals(3, result.score)
        assertEquals("Moderately relevant", result.rationale)
    }

    @Test
    fun `parseScoreResponse coerces score above maximum to 5`() {
        val json = """{"score": 10, "rationale": "Very high score"}"""

        val result = ResponseParser.parseScoreResponse(json)

        assertEquals(5, result.score)
    }

    @Test
    fun `parseScoreResponse coerces score below minimum to 1`() {
        val json = """{"score": 0, "rationale": "Very low score"}"""

        val result = ResponseParser.parseScoreResponse(json)

        assertEquals(1, result.score)
    }

    @Test
    fun `parseScoreResponse returns default for invalid JSON`() {
        val invalidJson = "not a json at all"

        val result = ResponseParser.parseScoreResponse(invalidJson)

        assertEquals(3, result.score)
        assertEquals("Unable to parse response", result.rationale)
    }

    @Test
    fun `parseScoreResponse handles whitespace and formatting`() {
        val json = """
            {
                "score"   :   5  ,
                "rationale"  :  "Well formatted"
            }
        """

        val result = ResponseParser.parseScoreResponse(json)

        assertEquals(5, result.score)
        assertEquals("Well formatted", result.rationale)
    }

    // ==================== Citation Response Tests ====================

    @Test
    fun `parseCitationResponse extracts single citation`() {
        val json = """{"citations": [{"passage": "This is a key finding.", "relevance": "Supports the claim"}]}"""

        val result = ResponseParser.parseCitationResponse(json)

        assertEquals(1, result.size)
        assertEquals("This is a key finding.", result[0].passage)
        assertEquals("Supports the claim", result[0].relevance)
    }

    @Test
    fun `parseCitationResponse extracts multiple citations`() {
        val json = """
        {
            "citations": [
                {"passage": "First finding.", "relevance": "Primary evidence"},
                {"passage": "Second finding.", "relevance": "Supporting evidence"},
                {"passage": "Third finding.", "relevance": "Additional context"}
            ]
        }
        """

        val result = ResponseParser.parseCitationResponse(json)

        assertEquals(3, result.size)
        assertEquals("First finding.", result[0].passage)
        assertEquals("Third finding.", result[2].passage)
    }

    @Test
    fun `parseCitationResponse returns empty list for invalid JSON`() {
        val invalidJson = "no citations here"

        val result = ResponseParser.parseCitationResponse(invalidJson)

        assertTrue(result.isEmpty())
    }

    @Test
    fun `parseCitationResponse handles missing citations array`() {
        val json = """{"result": "success"}"""

        val result = ResponseParser.parseCitationResponse(json)

        assertTrue(result.isEmpty())
    }

    // ==================== Report Response Tests ====================

    @Test
    fun `parseReportResponse extracts all fields`() {
        val json = """
        {
            "verdict": "SUPPORTED",
            "summary": "The evidence strongly supports the claim.",
            "report": "# Report\n\nDetailed analysis follows..."
        }
        """

        val result = ResponseParser.parseReportResponse(json)

        assertEquals("SUPPORTED", result.verdict)
        assertEquals("The evidence strongly supports the claim.", result.summary)
        assertTrue(result.report.contains("Detailed analysis"))
    }

    @Test
    fun `parseReportResponse uppercases verdict`() {
        val json = """{"verdict": "likely_supported", "summary": "Test", "report": "Report"}"""

        val result = ResponseParser.parseReportResponse(json)

        assertEquals("LIKELY_SUPPORTED", result.verdict)
    }

    @Test
    fun `parseReportResponse returns defaults for missing fields`() {
        val json = """{"other": "data"}"""

        val result = ResponseParser.parseReportResponse(json)

        assertEquals("UNCLEAR", result.verdict)
        assertEquals("Unable to generate summary", result.summary)
    }

    @Test
    fun `parseReportResponse handles escaped newlines in report`() {
        val json = """{"verdict": "SUPPORTED", "summary": "Test", "report": "Line 1\\nLine 2\\nLine 3"}"""

        val result = ResponseParser.parseReportResponse(json)

        assertTrue(result.report.contains("\n"))
    }

    // ==================== PubMed Query Response Tests ====================

    @Test
    fun `parseStructuredQueryResponse extracts plain query`() {
        val response = "(COVID-19[MeSH]) AND (vaccine efficacy[Title/Abstract])"

        val result = ResponseParser.parseStructuredQueryResponse(response, "test claim")

        assertEquals("(COVID-19[MeSH]) AND (vaccine efficacy[Title/Abstract])", result)
    }

    @Test
    fun `parseStructuredQueryResponse extracts query from JSON`() {
        val response = """{"query": "diabetes AND treatment[Title]"}"""

        val result = ResponseParser.parseStructuredQueryResponse(response, "test claim")

        assertEquals("diabetes AND treatment[Title]", result)
    }

    @Test
    fun `parseStructuredQueryResponse removes markdown code blocks`() {
        val response = """```
        hypertension AND management
        ```"""

        val result = ResponseParser.parseStructuredQueryResponse(response, "test claim")

        assertEquals("hypertension AND management", result)
    }

    @Test
    fun `parseStructuredQueryResponse extracts quoted query`() {
        val response = """"aspirin AND cardiovascular disease""""

        val result = ResponseParser.parseStructuredQueryResponse(response, "test claim")

        assertEquals("aspirin AND cardiovascular disease", result)
    }

    @Test
    fun `parseStructuredQueryResponse takes first line of multiline response`() {
        val response = """cancer AND immunotherapy

        This query will search for relevant articles..."""

        val result = ResponseParser.parseStructuredQueryResponse(response, "test claim")

        assertEquals("cancer AND immunotherapy", result)
    }
}
