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
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Migration 8 → 9 adds exactly what schema 9 has over schema 8 (#480).
 *
 * A registered migration that leaves a column out fails Room's schema check and
 * crashes on open; this test catches that before it ships. There is no
 * `room-testing` dependency to run the migration against a real database, so it
 * compares the migration's statements with Room's own exported schemas. That the
 * migration is registered at all is `AppDatabaseMigrationsTest`'s concern.
 */
class Migration8To9Test {

    private val schemaDirectory =
        File("schemas/com.bmlibrarian.factchecker.data.local.AppDatabase").let {
            if (it.isDirectory) it else File("app/${it.path}")
        }

    /**
     * A column as Room's schema check compares it: its SQLite affinity, whether
     * it is `NOT NULL`, and its SQL default (null when it has none).
     */
    private data class Column(val affinity: String, val notNull: Boolean, val defaultValue: String?)

    /** A table's columns in an exported schema, by name. */
    private fun columns(version: Int, table: String): Map<String, Column> {
        val schema = Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
        val entity = schema.jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject }
            .single { it["tableName"]!!.jsonPrimitive.content == table }
        return entity["fields"]!!.jsonArray.associate {
            val field = it as JsonObject
            field["columnName"]!!.jsonPrimitive.content to Column(
                affinity = field["affinity"]!!.jsonPrimitive.content,
                notNull = field["notNull"]!!.jsonPrimitive.boolean,
                defaultValue = field["defaultValue"]?.jsonPrimitive?.content
            )
        }
    }

    /**
     * The column an `ALTER TABLE documents ADD COLUMN` statement adds, by name.
     * Only `NOT NULL` and `DEFAULT <value>` may follow the type; any other
     * clause fails, rather than being ignored.
     */
    private fun added(statement: String): Pair<String, Column> {
        val match = Regex("""^ALTER TABLE documents ADD COLUMN (\w+) (\w+)(.*)$""", RegexOption.IGNORE_CASE)
            .find(statement.trim()) ?: error("unexpected statement: $statement")
        var rest = match.groupValues[3].trim()
        var notNull = false
        var defaultValue: String? = null
        while (rest.isNotEmpty()) {
            val notNullClause = Regex("""^NOT\s+NULL\b""", RegexOption.IGNORE_CASE).find(rest)
            val defaultClause = Regex("""^DEFAULT\s+('(?:[^']|'')*'|[^\s]+)""", RegexOption.IGNORE_CASE).find(rest)
            rest = when {
                notNullClause != null -> { notNull = true; rest.substring(notNullClause.range.last + 1).trim() }
                defaultClause != null -> {
                    defaultValue = defaultClause.groupValues[1]
                    rest.substring(defaultClause.range.last + 1).trim()
                }
                else -> error("unexpected clause \"$rest\" in: $statement")
            }
        }
        return match.groupValues[1] to Column(match.groupValues[2].uppercase(), notNull, defaultValue)
    }

    /** The statements [AppDatabase.MIGRATION_8_9] runs, in order. */
    private fun migrationStatements(): List<String> {
        val statements = mutableListOf<String>()
        val database = mockk<SupportSQLiteDatabase>()
        every { database.execSQL(any<String>()) } answers { statements += firstArg<String>() }
        AppDatabase.MIGRATION_8_9.migrate(database)
        return statements
    }

    /**
     * Name, affinity, nullability and default all match schema 9: Room's check
     * compares each, so `ADD COLUMN … TEXT NOT NULL DEFAULT ''` would crash
     * every upgrade even with the right name and affinity.
     */
    @Test
    fun `migration adds exactly the columns schema 9 adds to documents`() {
        val added = migrationStatements().associate(::added)
        val before = columns(8, "documents")
        val after = columns(9, "documents")

        assertEquals(after - before.keys, added)
        assertEquals(before.keys, after.keys - added.keys)
        assertEquals(mapOf("full_text_pdf_not_saved_from" to Column("TEXT", notNull = false, defaultValue = null)), added)
    }

    /** The parser itself: a nullability or default that differs is seen, not dropped. */
    @Test
    fun `a NOT NULL or a default in the statement is read`() {
        assertEquals(
            "c" to Column("TEXT", notNull = true, defaultValue = "''"),
            added("ALTER TABLE documents ADD COLUMN c TEXT NOT NULL DEFAULT ''")
        )
        assertEquals(
            "c" to Column("INTEGER", notNull = false, defaultValue = "0"),
            added("ALTER TABLE documents ADD COLUMN c INTEGER DEFAULT 0")
        )
        assertThrows(IllegalStateException::class.java) {
            added("ALTER TABLE documents ADD COLUMN c TEXT COLLATE NOCASE")
        }
    }

    /** Every table an exported schema holds. */
    private fun tables(version: Int): Set<String> =
        Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
            .jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject["tableName"]!!.jsonPrimitive.content }
            .toSet()

    @Test
    fun `migration touches no other table`() {
        assertEquals(tables(8), tables(9))
        val others = tables(8) - "documents"
        assertEquals("schema 8 lists its tables", true, others.size >= 3)
        for (table in others) {
            assertEquals(table, columns(8, table), columns(9, table))
        }
    }
}
