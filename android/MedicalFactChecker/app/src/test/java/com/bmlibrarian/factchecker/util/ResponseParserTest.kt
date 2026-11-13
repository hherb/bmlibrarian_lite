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

import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import java.io.File
import org.junit.Assert.assertNull
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Unit tests for ResponseParser utility.
 */
class ResponseParserTest {

    private val contract: JsonObject by lazy {
        val relative = "doc/cross_platform/llm_parity/score_values.json"
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, relative) }
            .firstOrNull { it.isFile }
            ?: error("could not locate $relative above ${File("").absolutePath}")
        Json.parseToJsonElement(file.readText()).jsonObject
    }

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
    fun `parseScoreResponse never clamps an off-scale score`() {
        for (reply in listOf(
            """{"score": 10, "rationale": "Very high score"}""",
            """{"score": 0, "rationale": "Very low score"}"""
        )) {
            assertNull(reply, ResponseParser.parseScoreResponse(reply).score)
        }
    }

    @Test
    fun `parseScoreResponse reads an unreadable reply as a failure and never a score`() {
        val result = ResponseParser.parseScoreResponse("not a json at all")

        assertNull(result.score)
        assertTrue(result.parseFailed)
    }

    @Test
    fun `parseScoreResponse takes every row of the shared contract`() {
        val cases = contract["cases"]!!.jsonArray.map { it.jsonObject }
        assertTrue(cases.size >= 18)
        for (row in cases) {
            val name = row["name"]!!.jsonPrimitive.content
            val expected = row["score"]!!.let { if (it is JsonNull) null else it.jsonPrimitive.int }
            val result = ResponseParser.parseScoreResponse(row["reply"]!!.jsonPrimitive.content)
            assertEquals(name, expected, result.score)
            assertEquals(name, expected == null, result.parseFailed)
        }
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

    @Test
    fun `a null explanation is skipped, never the word null`() {
        val result = ResponseParser.parseScoreResponse(
            """{"score": 4, "explanation": null, "rationale": "On topic"}"""
        )

        assertEquals(4, result.score)
        assertEquals("On topic", result.rationale)
    }

    @Test
    fun `an explanation that is not a string is skipped`() {
        val result = ResponseParser.parseScoreResponse(
            """{"score": 4, "explanation": {"a": 1}, "reason": "Because"}"""
        )

        assertEquals("Because", result.rationale)
    }

    @Test
    fun `a scored reply with no explanation does not say it was unparsed`() {
        val result = ResponseParser.parseScoreResponse("""{"score": 4}""")

        assertEquals(4, result.score)
        assertEquals(ResponseParser.NO_RATIONALE, result.rationale)
    }

    @Test
    fun `a bare value that is not a JSON number is no score`() {
        // The lenient parser keeps these as literals, and Java reads them as doubles
        for (reply in listOf("""{"score": 4f}""", """{"score": 4d}""", """{"score": 0x4p0}""")) {
            val result = ResponseParser.parseScoreResponse(reply)
            assertNull(reply, result.score)
            assertTrue(reply, result.parseFailed)
        }
    }

    @Test
    fun `a trailing comma still gives the whole-number score`() {
        // iOS repairs {"score": 3,} and reads 3 too
        val result = ResponseParser.parseScoreResponse("""Note: {"score": 3, "explanation": "partly",}""")

        assertEquals(3, result.score)
        assertEquals("partly", result.rationale)
        assertTrue(!result.parseFailed)
    }

    @Test
    fun `a trailing comma after a fraction is no score`() {
        val result = ResponseParser.parseScoreResponse("""Note: {"score": 4.5,}""")

        assertNull(result.score)
        assertTrue(result.parseFailed)
    }

    @Test
    fun `the regex fallback reads a whole number from a reply cut short`() {
        // No balanced object, so no JSON parse: only the regex reads this
        val result = ResponseParser.parseScoreResponse("""{"score": 3, "explanation": "partly", "more": "cut sh""")

        assertEquals(3, result.score)
        assertEquals("partly", result.rationale)
    }

    @Test
    fun `the regex fallback refuses a fraction or an off-scale number`() {
        for (reply in listOf("""{"score": 4.5, "explanation": "cut sh""", """{"score": 9, "explanation": "cut sh""")) {
            val result = ResponseParser.parseScoreResponse(reply)
            assertNull(reply, result.score)
            assertTrue(reply, result.parseFailed)
        }
    }

    @Test
    fun `firstJsonObject treats a brace in a string as text`() {
        assertEquals(
            """{"a": "}{", "b": {"c": "\"}"}}""",
            ResponseParser.firstJsonObject("""x {"a": "}{", "b": {"c": "\"}"}} y {"z": 1}""")
        )
        assertNull(ResponseParser.firstJsonObject("""{"a": 1"""))
        assertNull(ResponseParser.firstJsonObject("no object"))
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
    fun `parseCitationResponse reads no passage beside a value JSON does not define`() {
        for (value in listOf("NaN", "Infinity", "-Infinity", "1e999", "1" + "0".repeat(400))) {
            val reply = """{"citations": [{"passage": "Aspirin reduced stroke.", "relevance": "x", "n": $value}]}"""
            assertEquals(value, emptyList<ResponseParser.CitationResult>(), ResponseParser.parseCitationResponse(reply))
        }
        // Control: a finite number beside it does not refuse the reply
        val reply = """{"citations": [{"passage": "Aspirin reduced stroke.", "relevance": "x", "n": 1e300}]}"""
        assertEquals(1, ResponseParser.parseCitationResponse(reply).size)
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
