package com.bmlibrarian.factchecker.util

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/**
 * Every text a model analyses is read without its reference list, in sliding
 * windows, and the windows' answers merged: the shared rows of
 * `doc/cross_platform/llm_parity/text_windows.json` (Python is canonical).
 */
class TextWindowsContractTest {

    private val contract: JsonObject by lazy {
        val relative = "doc/cross_platform/llm_parity/text_windows.json"
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, relative) }
            .firstOrNull { it.isFile }
            ?: error("could not locate $relative above ${File("").absolutePath}")
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    private fun rows(key: String) = contract[key]!!.jsonArray.map { it.jsonObject }.also {
        assertTrue("an empty $key table would pass vacuously", it.isNotEmpty())
    }

    private fun JsonObject.text(key: String) = getValue(key).jsonPrimitive.content

    private fun JsonObject.texts(key: String) = getValue(key).jsonArray.map { it.jsonPrimitive.content }

    @Test
    fun `the window and the boundaries are the contract's`() {
        assertEquals(Constants.TEXT_WINDOW_CHARS, contract["window_chars"]!!.jsonPrimitive.int)
        assertEquals(Constants.TEXT_WINDOW_OVERLAP_CHARS, contract["overlap_chars"]!!.jsonPrimitive.int)
        assertEquals(TextWindows.BOUNDARY_SEARCH_CHARS, contract["boundary_search_chars"]!!.jsonPrimitive.int)
        assertEquals(contract.texts("boundary_markers"), TextWindows.BOUNDARY_MARKERS.map { it.first })
    }

    @Test
    fun `each windows case`() {
        for (row in rows("windows")) {
            val windows = TextWindows.analysisWindows(
                row.text("text"),
                windowChars = row.getValue("window_chars").jsonPrimitive.int,
                overlapChars = row.getValue("overlap_chars").jsonPrimitive.int
            )
            assertEquals(row.text("name"), row.texts("windows"), windows)
        }
    }

    @Test
    fun `each references case`() {
        for (row in rows("references")) {
            assertEquals(row.text("name"), row.text("without_references"), TextWindows.withoutReferences(row.text("text")))
        }
    }

    @Test
    fun `each merge case`() {
        for (row in rows("merge")) {
            assertEquals(row.text("name"), row.texts("kept"), TextWindows.mergedWindowItems(row.texts("passages")) { it })
        }
    }
}
