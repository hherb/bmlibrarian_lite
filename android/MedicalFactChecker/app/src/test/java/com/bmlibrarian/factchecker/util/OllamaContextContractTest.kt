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
 * The `num_ctx` an Ollama request is sent, by the shared rows of
 * `doc/cross_platform/llm_parity/ollama_context.json` (#760).
 */
class OllamaContextContractTest {

    private val contract: JsonObject by lazy {
        val relative = "doc/cross_platform/llm_parity/ollama_context.json"
        val file = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, relative) }
            .firstOrNull { it.isFile }
            ?: error("could not locate $relative above ${File("").absolutePath}")
        Json.parseToJsonElement(file.readText()).jsonObject
    }

    private fun JsonObject.int(key: String) = getValue(key).jsonPrimitive.int

    @Test
    fun `the bounds are the contract's`() {
        assertEquals(Constants.OLLAMA_CHARS_PER_TOKEN, contract.int("chars_per_token"))
        assertEquals(Constants.OLLAMA_TEMPLATE_TOKENS, contract.int("template_tokens"))
        assertEquals(Constants.OLLAMA_MIN_NUM_CTX, contract.int("min_num_ctx"))
        assertEquals(Constants.OLLAMA_MAX_NUM_CTX, contract.int("max_num_ctx"))
    }

    @Test
    fun `each case`() {
        val rows = contract.getValue("cases").jsonArray.map { it.jsonObject }
        assertTrue("an empty table would pass vacuously", rows.isNotEmpty())
        for (row in rows) {
            assertEquals(
                row.getValue("name").jsonPrimitive.content,
                row.int("num_ctx"),
                OllamaContext.numCtx(row.int("prompt_code_points"), row.int("max_tokens"))
            )
        }
    }

    @Test
    fun `messages are counted in code points, not UTF-16 units`() {
        // U+1F600 is one code point but two UTF-16 units
        val emoji = "😀".repeat(23_808)
        assertEquals(8192, OllamaContext.numCtx(listOf(emoji), 0))
        assertEquals(16384, OllamaContext.numCtx(listOf(emoji, "x"), 0))
    }

    @Test
    fun `the native root drops the OpenAI version segment`() {
        assertEquals("http://localhost:11434", OllamaContext.nativeRoot("http://localhost:11434/v1"))
        assertEquals("http://phone.lan:11434", OllamaContext.nativeRoot("http://phone.lan:11434/v1/"))
        assertEquals("http://phone.lan:11434", OllamaContext.nativeRoot("http://phone.lan:11434"))
    }
}
