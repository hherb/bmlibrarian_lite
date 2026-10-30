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
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Migration 9 → 10 adds exactly what schema 10 has over schema 9.
 *
 * A registered migration that leaves a column out fails Room's schema check and
 * crashes on open; this test catches that before it ships. There is no
 * `room-testing` dependency to run the migration against a real database, so it
 * compares the migration's statements with Room's own exported schemas. That the
 * migration is registered at all is `AppDatabaseMigrationsTest`'s concern.
 */
class Migration9To10Test {

    /**
     * Name, affinity, nullability and default all match schema 10: Room's check
     * compares each, so `ADD COLUMN … TEXT NOT NULL DEFAULT ''` would crash
     * every upgrade even with the right name and affinity.
     */
    @Test
    fun `migration adds exactly the columns schema 10 adds to documents`() {
        val added = ExportedSchemas.statements(AppDatabase.MIGRATION_9_10).associate { ExportedSchemas.added(it) }
        val before = ExportedSchemas.columns(9, "documents")
        val after = ExportedSchemas.columns(10, "documents")

        assertEquals(after - before.keys, added)
        assertEquals(before.keys, after.keys - added.keys)
        assertEquals(
            mapOf(
                "full_text_abstract_only" to ExportedSchemas.Column("INTEGER", notNull = true, defaultValue = "0"),
                "full_text_pdf_text" to ExportedSchemas.Column("TEXT", notNull = false, defaultValue = null),
                "citations_read_full_text" to ExportedSchemas.Column("INTEGER", notNull = false, defaultValue = null)
            ),
            added
        )
    }

    /** The parser itself: a nullability or default that differs is seen, not dropped. */
    @Test
    fun `a NOT NULL or a default in the statement is read`() {
        assertEquals(
            "c" to ExportedSchemas.Column("TEXT", notNull = true, defaultValue = "''"),
            ExportedSchemas.added("ALTER TABLE documents ADD COLUMN c TEXT NOT NULL DEFAULT ''")
        )
        assertEquals(
            "c" to ExportedSchemas.Column("INTEGER", notNull = false, defaultValue = "0"),
            ExportedSchemas.added("ALTER TABLE documents ADD COLUMN c INTEGER DEFAULT 0")
        )
        assertThrows(IllegalStateException::class.java) {
            ExportedSchemas.added("ALTER TABLE documents ADD COLUMN c TEXT COLLATE NOCASE")
        }
    }

    @Test
    fun `migration touches no other table`() {
        assertEquals(ExportedSchemas.tables(9), ExportedSchemas.tables(10))
        val others = ExportedSchemas.tables(9) - "documents"
        assertEquals("schema 9 lists its tables", true, others.size >= 3)
        for (table in others) {
            assertEquals(table, ExportedSchemas.columns(9, table), ExportedSchemas.columns(10, table))
        }
    }
}
