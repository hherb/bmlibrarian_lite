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

import androidx.room.migration.Migration
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

/**
 * Room's exported schemas, read as its schema check compares them, for the
 * migration tests. There is no `room-testing` dependency to run a migration
 * against a real database, so each test compares the migration's statements
 * with the exported schemas instead.
 */
object ExportedSchemas {

    private val schemaDirectory =
        File("schemas/com.bmlibrarian.factchecker.data.local.AppDatabase").let {
            if (it.isDirectory) it else File("app/${it.path}")
        }

    /**
     * A column as Room's schema check compares it: its SQLite affinity, whether
     * it is `NOT NULL`, and its SQL default (null when it has none).
     */
    data class Column(val affinity: String, val notNull: Boolean, val defaultValue: String?)

    /** A table's columns in an exported schema, by name. */
    fun columns(version: Int, table: String): Map<String, Column> {
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
     * The column an `ALTER TABLE <table> ADD COLUMN` statement adds, by name.
     * Only `NOT NULL` and `DEFAULT <value>` may follow the type; any other
     * clause fails, rather than being ignored.
     */
    fun added(statement: String, table: String = "documents"): Pair<String, Column> {
        val match = Regex("""^ALTER TABLE $table ADD COLUMN (\w+) (\w+)(.*)$""", RegexOption.IGNORE_CASE)
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

    /**
     * The statements a migration runs, in order.
     *
     * @param migration The migration
     * @return Its statements
     */
    fun statements(migration: Migration): List<String> {
        val statements = mutableListOf<String>()
        val database = mockk<SupportSQLiteDatabase>()
        every { database.execSQL(any<String>()) } answers { statements += firstArg<String>() }
        migration.migrate(database)
        return statements
    }

    /** Every table an exported schema holds. */
    fun tables(version: Int): Set<String> =
        Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
            .jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject["tableName"]!!.jsonPrimitive.content }
            .toSet()

    /**
     * A table's `CREATE TABLE` statement in an exported schema, its name filled in.
     *
     * @param version The schema version
     * @param table The table
     * @return The statement Room creates the table with
     */
    fun createSql(version: Int, table: String): String {
        val schema = Json.parseToJsonElement(File(schemaDirectory, "$version.json").readText())
        val entity = schema.jsonObject["database"]!!.jsonObject["entities"]!!.jsonArray
            .map { it.jsonObject }
            .single { it["tableName"]!!.jsonPrimitive.content == table }
        return entity["createSql"]!!.jsonPrimitive.content.replace("\${TABLE_NAME}", table)
    }
}
