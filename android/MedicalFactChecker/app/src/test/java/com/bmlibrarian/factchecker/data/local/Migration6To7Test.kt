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
 * Migration 6 → 7 adds exactly what schema 7 has over schema 6.
 *
 * The database falls back to destructive migration, so a migration that leaves
 * a column out does not crash: it wipes every saved session instead. There is
 * no `room-testing` dependency to run the migration against a real database,
 * so this compares the migration's statements with Room's own exported schemas.
 */
class Migration6To7Test {

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
    fun `migration adds exactly the columns schema 7 adds to documents`() {
        val statements = mutableListOf<String>()
        val database = mockk<SupportSQLiteDatabase>()
        every { database.execSQL(any<String>()) } answers { statements += firstArg<String>() }

        AppDatabase.MIGRATION_6_7.migrate(database)

        val added = statements.associate { statement ->
            val match = Regex("""ALTER TABLE documents ADD COLUMN (\w+) (\w+)""").find(statement)
                ?: error("unexpected statement: $statement")
            match.groupValues[1] to match.groupValues[2]
        }
        val before = columns(6, "documents")
        val after = columns(7, "documents")

        assertEquals(after - before.keys, added)
        assertEquals(before.keys, after.keys - added.keys)
    }

    @Test
    fun `migration touches no other table`() {
        for (table in listOf("sessions", "citations", "reports")) {
            assertEquals(columns(6, table), columns(7, table))
        }
    }
}
