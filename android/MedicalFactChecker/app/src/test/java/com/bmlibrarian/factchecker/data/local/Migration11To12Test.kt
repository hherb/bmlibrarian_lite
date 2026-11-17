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
 * Migration 11 → 12 adds exactly what schema 12 has over schema 11: the
 * sessions' log of the queries they ran. Compared with Room's exported
 * schemas ([ExportedSchemas]), as Room's check on open compares them.
 */
class Migration11To12Test {

    private val statements = ExportedSchemas.statements(AppDatabase.MIGRATION_11_12)

    @Test
    fun `migration adds exactly the column schema 12 adds`() {
        val before = ExportedSchemas.columns(11, "sessions")
        val after = ExportedSchemas.columns(12, "sessions")
        val added = statements.associate { ExportedSchemas.added(it, "sessions") }
        assertEquals(after - before.keys, added)
        assertEquals(
            mapOf("search_queries_json" to ExportedSchemas.Column("TEXT", notNull = false, defaultValue = null)),
            added
        )
    }

    @Test
    fun `migration runs nothing else and touches no other table`() {
        assertEquals(1, statements.size)
        assertEquals(ExportedSchemas.tables(11), ExportedSchemas.tables(12))
        for (table in ExportedSchemas.tables(11) - "sessions") {
            assertEquals(table, ExportedSchemas.columns(11, table), ExportedSchemas.columns(12, table))
        }
    }
}
