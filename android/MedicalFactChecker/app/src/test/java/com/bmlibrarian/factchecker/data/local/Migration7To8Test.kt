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

package com.bmlibrarian.factchecker.data.local

import androidx.sqlite.db.SupportSQLiteDatabase
import io.mockk.every
import io.mockk.mockk
import java.io.File
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Migration 7 → 8 adds exactly what schema 8 has over schema 7 (#466).
 *
 * A registered migration that leaves a column out fails Room's schema check and
 * crashes on open; this test catches that before it ships. There is no
 * `room-testing` dependency to run the migration against a real database, so it
 * compares the migration's statements with Room's own exported schemas. That the
 * migration is registered at all is `AppDatabaseMigrationsTest`'s concern.
 */
class Migration7To8Test {

    private val schemaDirectory =
        File("schemas/com.bmlibrarian.factchecker.data.local.AppDatabase").let {
            if (it.isDirectory) it else File("app/${it.path}")
        }

    /** A table's columns in an exported schema, as name → SQLite affinity. */
    private fun columns(version: Int, table: String): Map<String, String> {
        val schema = Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
        val entity = schema.jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject }
            .single { it["tableName"]!!.jsonPrimitive.content == table }
        return entity["fields"]!!.jsonArray.associate {
            val field = it as JsonObject
            field["columnName"]!!.jsonPrimitive.content to field["affinity"]!!.jsonPrimitive.content
        }
    }

    @Test
    fun `migration adds exactly the columns schema 8 adds to documents`() {
        val statements = mutableListOf<String>()
        val database = mockk<SupportSQLiteDatabase>()
        every { database.execSQL(any<String>()) } answers { statements += firstArg<String>() }

        AppDatabase.MIGRATION_7_8.migrate(database)

        val added = statements.associate { statement ->
            val match = Regex("""ALTER TABLE documents ADD COLUMN (\w+) (\w+)""").find(statement)
                ?: error("unexpected statement: $statement")
            match.groupValues[1] to match.groupValues[2]
        }
        val before = columns(7, "documents")
        val after = columns(8, "documents")

        assertEquals(after - before.keys, added)
        assertEquals(before.keys, after.keys - added.keys)
    }

    /** Every table an exported schema holds. */
    private fun tables(version: Int): Set<String> =
        Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
            .jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject["tableName"]!!.jsonPrimitive.content }
            .toSet()

    @Test
    fun `migration touches no other table`() {
        assertEquals(tables(7), tables(8))
        val others = tables(7) - "documents"
        assertEquals("schema 7 lists its tables", true, others.size >= 3)
        for (table in others) {
            assertEquals(table, columns(7, table), columns(8, table))
        }
    }
}
