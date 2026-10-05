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
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * What the reader is told when every source tried went unsettled, the note for a
 * PDF served and not saved, and how a list of them is stored (#480), read from
 * `doc/cross_platform/fulltext_parity/open_access_statement.json`.
 */
class OpenAccessStatementContractTest {

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    /** The contract file; the walk stops at the checkout root (`.git`, a file in a worktree). */
    private fun contractFile(): File {
        val relative = "doc/cross_platform/fulltext_parity/open_access_statement.json"
        var directory: File? = File("").absoluteFile
        while (directory != null) {
            val candidate = File(directory, relative)
            if (candidate.isFile) return candidate
            if (File(directory, ".git").exists()) break
            directory = directory.parentFile
        }
        error("could not locate $relative above ${File("").absolutePath}")
    }

    private fun table(name: String): List<JsonObject> = contract[name]!!.jsonArray.map { it.jsonObject }

    private fun persisted(name: String): List<JsonObject> =
        contract["persisted"]!!.jsonObject[name]!!.jsonArray.map { it.jsonObject }

    private fun str(row: JsonObject, key: String): String = row[key]!!.jsonPrimitive.content

    /** The shortfall a row's entries describe, in the order given. */
    private fun shortfall(row: JsonObject): OpenAccessShortfall {
        val entries: JsonArray = row["entries"]!!.jsonArray
        return entries.map { element ->
            val entry = element.jsonObject
            if (entry["skipped"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content == "not_configured") {
                return@map OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED
            }
            val source = OpenAccessSource.fromPersisted(str(entry, "source")) ?: error("unknown source in $entry")
            val kind = RequestFailureKind.fromPersisted(str(entry, "kind")) ?: error("unknown kind in $entry")
            val status = entry["status_code"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.int
            OpenAccessShortfall(
                source,
                RequestFailure(kind, status),
                entry["address"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
            )
        }.reduce { all, next -> all + next }
    }

    /** A table added to the contract and asserted nowhere would pin nothing. */
    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf("schema_version", "description", "lead", "hosts", "statements", "not_saved_note", "persisted"),
            contract.keys
        )
        assertEquals(setOf("written", "read"), contract["persisted"]!!.jsonObject.keys)
    }

    @Test
    fun `each host row`() {
        val rows = table("hosts")
        assertTrue("an empty table would pass vacuously", rows.size >= 9)
        for (row in rows) {
            assertEquals("$row", str(row, "host"), OpenAccessShortfall.host(str(row, "address")))
        }
    }

    @Test
    fun `each statement row`() {
        val rows = table("statements")
        assertTrue("an empty table would pass vacuously", rows.size >= 10)
        for (row in rows) {
            assertEquals(str(row, "name"), str(row, "statement"), shortfall(row).notice)
        }
    }

    @Test
    fun `each not saved note row`() {
        val rows = table("not_saved_note")
        assertTrue("an empty table would pass vacuously", rows.size >= 2)
        for (row in rows) {
            assertEquals(
                "$row",
                str(row, "note"),
                OpenAccessShortfall.notSavedNote(str(row, "address"), row["link_kept"]!!.jsonPrimitive.boolean)
            )
        }
    }

    @Test
    fun `each written row`() {
        val rows = persisted("written")
        assertTrue("an empty table would pass vacuously", rows.size >= 4)
        for (row in rows) {
            assertEquals(str(row, "name"), row["stored"], Json.parseToJsonElement(shortfall(row).toJson()))
        }
    }

    @Test
    fun `each read row`() {
        val rows = persisted("read")
        assertTrue("an empty table would pass vacuously", rows.size >= 9)
        for (row in rows) {
            assertEquals(str(row, "name"), shortfall(row), OpenAccessShortfall.fromJson(str(row, "stored")))
        }
    }

    @Test
    fun `every statement row round-trips`() {
        for (row in table("statements")) {
            val shortfall = shortfall(row)
            assertEquals(str(row, "name"), shortfall, OpenAccessShortfall.fromJson(shortfall.toJson()))
        }
    }
}
