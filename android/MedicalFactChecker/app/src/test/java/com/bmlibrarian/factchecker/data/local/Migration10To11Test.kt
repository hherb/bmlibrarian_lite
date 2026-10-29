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

import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Migration 10 → 11 adds exactly what schema 11 has over schema 10: the
 * documents' publication types, the sessions' retraction snapshot, and the
 * per-paper retraction_checks table. Compared with Room's exported schemas
 * ([ExportedSchemas]), as Room's check on open compares them.
 */
class Migration10To11Test {

    private val statements = ExportedSchemas.statements(AppDatabase.MIGRATION_10_11)

    /** The columns the migration adds to [table], by name. */
    private fun addedTo(table: String) = statements
        .filter { it.startsWith("ALTER TABLE $table ") }
        .associate { ExportedSchemas.added(it, table) }

    @Test
    fun `migration adds exactly the columns schema 11 adds`() {
        for ((table, column) in listOf("documents" to "publication_types_json", "sessions" to "retraction_snapshot_json")) {
            val before = ExportedSchemas.columns(10, table)
            val after = ExportedSchemas.columns(11, table)
            assertEquals(table, after - before.keys, addedTo(table))
            assertEquals(table, mapOf(column to ExportedSchemas.Column("TEXT", notNull = false, defaultValue = null)), addedTo(table))
        }
    }

    @Test
    fun `migration creates the retraction table as Room does`() {
        assertEquals(ExportedSchemas.tables(10) + "retraction_checks", ExportedSchemas.tables(11))
        assertEquals(listOf(ExportedSchemas.createSql(11, "retraction_checks")), statements.filter { it.startsWith("CREATE") })
    }

    @Test
    fun `migration runs nothing else and touches no other table`() {
        assertEquals(3, statements.size)
        for (table in ExportedSchemas.tables(10) - setOf("documents", "sessions")) {
            assertEquals(table, ExportedSchemas.columns(10, table), ExportedSchemas.columns(11, table))
        }
    }
}
