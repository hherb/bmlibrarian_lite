/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2026 Dr Horst Herb
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

package com.bmlibrarian.factchecker.domain.model

import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the reader is told about an open-access copy that went unassessed, and
 * how a document stores it, read from the contract all three platforms share
 * (#466): `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`.
 */
class OpenAccessShortfallContractTest {

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    /**
     * The contract file, read from the repository. The walk stops at the
     * checkout root, so a worktree under the main checkout never reads the main
     * checkout's contract.
     */
    private fun contractFile(): File {
        val relative = "doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json"
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, relative)
            if (candidate.isFile) return candidate
            // `.git` is a directory in a normal checkout and a file in a worktree
            if (File(directory, ".git").exists()) break
            directory = directory.parentFile
        }
        error("could not locate $relative above ${File("").absolutePath}")
    }

    private fun rows(table: JsonArray): List<JsonObject> = table.map { it.jsonObject }

    private fun persisted(name: String): List<JsonObject> =
        rows(contract["persisted"]!!.jsonObject[name]!!.jsonArray)

    /**
     * The shortfall a row names by its `source`, `kind` and `status_code`, or by
     * `skipped` for a lookup that was never made.
     */
    private fun shortfall(row: JsonObject): OpenAccessShortfall {
        val source = OpenAccessSource.fromPersisted(row["source"]!!.jsonPrimitive.content)
            ?: error("unknown source in $row")
        row["skipped"]?.takeUnless { it is JsonNull }?.let { skipped ->
            return when (skipped.jsonPrimitive.content) {
                "not_configured" -> {
                    assertEquals("$row", OpenAccessSource.UNPAYWALL, source)
                    OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED
                }
                "key_refused" -> {
                    assertEquals("$row", OpenAccessSource.CORE, source)
                    OpenAccessShortfall.CORE_KEY_REFUSED
                }
                else -> error("an unknown skip in $row")
            }
        }
        val kind = RequestFailureKind.fromPersisted(row["kind"]!!.jsonPrimitive.content)
            ?: error("unknown kind in $row")
        val status = row["status_code"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.int
        return OpenAccessShortfall(source, RequestFailure(kind, status))
    }

    @Test
    fun `each source is named as Python names it`() {
        val sources = contract["sources"]!!.jsonObject

        assertEquals(OpenAccessSource.entries.map { it.persistedValue }.toSet(), sources.keys)
        for (source in OpenAccessSource.entries) {
            assertEquals(source.persistedValue, sources[source.persistedValue]!!.jsonPrimitive.content, source.serviceName)
        }
    }

    @Test
    fun `each notice row`() {
        val table = rows(contract["notices"]!!.jsonArray)
        assertTrue("an empty table would pass vacuously", table.size >= 10)
        for (row in table) {
            assertEquals("$row", row["notice"]!!.jsonPrimitive.content, shortfall(row).notice)
        }
        fun skipped(row: JsonObject) = row["skipped"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
        assertTrue("a skip row pins the not-configured sentence", table.any { skipped(it) == "not_configured" })
        assertTrue("a skip row pins CORE's refused key (#498)", table.any { skipped(it) == "key_refused" })
    }

    @Test
    fun `each written row`() {
        val table = persisted("written")
        assertTrue("an empty table would pass vacuously", table.size >= 3)
        for (row in table) {
            assertEquals("$row", row["stored"], Json.parseToJsonElement(shortfall(row).toJson()))
        }
    }

    @Test
    fun `each read row`() {
        val table = persisted("read")
        assertTrue("an empty table would pass vacuously", table.size >= 10)
        for (row in table) {
            assertEquals(
                row["name"]!!.jsonPrimitive.content,
                shortfall(row),
                OpenAccessShortfall.fromJson(row["stored"]!!.jsonPrimitive.content)
            )
        }
    }

    @Test
    fun `every shortfall round-trips`() {
        val failures = listOf(
            RequestFailure(RequestFailureKind.TIMEOUT),
            RequestFailure(RequestFailureKind.CONNECTION),
            RequestFailure(RequestFailureKind.SERVICE_ERROR),
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE),
            RequestFailure(RequestFailureKind.REQUEST_FAILED),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 429),
            RequestFailure(RequestFailureKind.HTTP_STATUS, 408),
            RequestFailure(RequestFailureKind.REDIRECT_REFUSED, 307),
            RequestFailure(RequestFailureKind.REDIRECT_REFUSED),
        )
        for (source in OpenAccessSource.entries) {
            for (failure in failures) {
                val shortfall = OpenAccessShortfall(source, failure)

                assertEquals(shortfall, OpenAccessShortfall.fromJson(shortfall.toJson()))
            }
        }
        for (skipped in listOf(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED, OpenAccessShortfall.CORE_KEY_REFUSED)) {
            assertEquals(skipped, OpenAccessShortfall.fromJson(skipped.toJson()))
        }
    }

    /** A refused key is CORE's, configured, and unasked: no nudge (#498). */
    @Test
    fun `a refused key earns no configuration nudge`() {
        val refused = OpenAccessShortfall.CORE_KEY_REFUSED
        assertEquals(OpenAccessSource.CORE, refused.source)
        assertEquals(OpenAccessUnsettledReason.KeyRefused, refused.reason)
        assertNull(refused.failure)
        assertFalse(refused.notice, "Configuring" in refused.notice)
        // The control: alongside an unconfigured Unpaywall, only Unpaywall is nudged
        assertEquals(
            "Unpaywall (not configured) and CORE (the key in the settings was refused) could not be " +
                "asked, so a freely available copy may exist. Whether this document is open access " +
                "was not established. Configuring Unpaywall would add an open-access route this " +
                "search did not have.",
            (OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED + refused).notice
        )
    }

    /** A table added to the contract and asserted nowhere would pin nothing. */
    @Test
    fun `every contract table is read here`() {
        assertEquals(setOf("schema_version", "description", "sources", "notices", "persisted"), contract.keys)
        assertEquals(setOf("written", "read"), contract["persisted"]!!.jsonObject.keys)
    }
}
