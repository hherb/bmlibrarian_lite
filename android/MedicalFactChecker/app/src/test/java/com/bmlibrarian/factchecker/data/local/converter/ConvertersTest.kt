/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.data.local.converter

import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import java.util.Date

/**
 * Unit tests for Room type converters.
 *
 * Tests round-trip conversion for all custom types to ensure
 * data integrity when saving to and loading from the database.
 */
class ConvertersTest {

    private lateinit var converters: Converters

    @Before
    fun setup() {
        converters = Converters()
    }

    // ==================== Date Converter Tests ====================

    @Test
    fun `fromTimestamp with valid timestamp returns correct Date`() {
        val timestamp = 1704067200000L // 2024-01-01 00:00:00 UTC
        val result = converters.fromTimestamp(timestamp)

        assertEquals(Date(timestamp), result)
    }

    @Test
    fun `fromTimestamp with null returns null`() {
        val result = converters.fromTimestamp(null)

        assertNull(result)
    }

    @Test
    fun `dateToTimestamp with valid Date returns correct timestamp`() {
        val date = Date(1704067200000L)
        val result = converters.dateToTimestamp(date)

        assertEquals(1704067200000L, result)
    }

    @Test
    fun `dateToTimestamp with null returns null`() {
        val result = converters.dateToTimestamp(null)

        assertNull(result)
    }

    @Test
    fun `Date converter round-trips correctly`() {
        val originalDate = Date()
        val timestamp = converters.dateToTimestamp(originalDate)
        val restoredDate = converters.fromTimestamp(timestamp)

        assertEquals(originalDate, restoredDate)
    }

    // ==================== String List Converter Tests ====================

    @Test
    fun `fromStringList with valid list returns JSON array`() {
        val list = listOf("Author A", "Author B", "Author C")
        val result = converters.fromStringList(list)

        // JSON should contain all elements
        assert(result != null)
        assert(result!!.contains("Author A"))
        assert(result.contains("Author B"))
        assert(result.contains("Author C"))
    }

    @Test
    fun `fromStringList with empty list returns empty JSON array`() {
        val list = emptyList<String>()
        val result = converters.fromStringList(list)

        assertEquals("[]", result)
    }

    @Test
    fun `fromStringList with null returns null`() {
        val result = converters.fromStringList(null)

        assertNull(result)
    }

    @Test
    fun `toStringList with valid JSON returns correct list`() {
        val json = """["Author A","Author B","Author C"]"""
        val result = converters.toStringList(json)

        assertEquals(listOf("Author A", "Author B", "Author C"), result)
    }

    @Test
    fun `toStringList with empty JSON array returns empty list`() {
        val json = "[]"
        val result = converters.toStringList(json)

        assertEquals(emptyList<String>(), result)
    }

    @Test
    fun `toStringList with null returns null`() {
        val result = converters.toStringList(null)

        assertNull(result)
    }

    @Test
    fun `toStringList with invalid JSON returns empty list`() {
        val invalidJson = "not valid json"
        val result = converters.toStringList(invalidJson)

        assertEquals(emptyList<String>(), result)
    }

    @Test
    fun `String list converter round-trips correctly`() {
        val original = listOf("First Author", "Second Author", "Third Author")
        val json = converters.fromStringList(original)
        val restored = converters.toStringList(json)

        assertEquals(original, restored)
    }

    @Test
    fun `String list converter handles special characters`() {
        val original = listOf("O'Connor", "Müller", "García-López")
        val json = converters.fromStringList(original)
        val restored = converters.toStringList(json)

        assertEquals(original, restored)
    }

    // ==================== WorkflowStep Converter Tests ====================

    @Test
    fun `fromWorkflowStep converts all values correctly`() {
        WorkflowStep.entries.forEach { step ->
            val result = converters.fromWorkflowStep(step)
            assertEquals(step.name, result)
        }
    }

    @Test
    fun `toWorkflowStep converts all values correctly`() {
        WorkflowStep.entries.forEach { step ->
            val result = converters.toWorkflowStep(step.name)
            assertEquals(step, result)
        }
    }

    @Test
    fun `toWorkflowStep with unknown value returns IDLE`() {
        val result = converters.toWorkflowStep("UNKNOWN_STEP")

        assertEquals(WorkflowStep.IDLE, result)
    }

    @Test
    fun `WorkflowStep converter round-trips correctly for all values`() {
        WorkflowStep.entries.forEach { step ->
            val string = converters.fromWorkflowStep(step)
            val restored = converters.toWorkflowStep(string)
            assertEquals(step, restored)
        }
    }

    // ==================== Verdict Converter Tests ====================

    @Test
    fun `fromVerdict converts all values correctly`() {
        Verdict.entries.forEach { verdict ->
            val result = converters.fromVerdict(verdict)
            assertEquals(verdict.name, result)
        }
    }

    @Test
    fun `fromVerdict with null returns null`() {
        val result = converters.fromVerdict(null)

        assertNull(result)
    }

    @Test
    fun `toVerdict converts all values correctly`() {
        Verdict.entries.forEach { verdict ->
            val result = converters.toVerdict(verdict.name)
            assertEquals(verdict, result)
        }
    }

    @Test
    fun `toVerdict with null returns null`() {
        val result = converters.toVerdict(null)

        assertNull(result)
    }

    @Test
    fun `toVerdict with unknown value returns UNCLEAR`() {
        val result = converters.toVerdict("UNKNOWN_VERDICT")

        assertEquals(Verdict.UNCLEAR, result)
    }

    @Test
    fun `Verdict converter round-trips correctly for all values`() {
        Verdict.entries.forEach { verdict ->
            val string = converters.fromVerdict(verdict)
            val restored = converters.toVerdict(string)
            assertEquals(verdict, restored)
        }
    }

    // ==================== SearchProvider Converter Tests ====================

    @Test
    fun `fromSearchProvider converts all values correctly`() {
        SearchProvider.entries.forEach { provider ->
            val result = converters.fromSearchProvider(provider)
            assertEquals(provider.name, result)
        }
    }

    @Test
    fun `toSearchProvider converts all values correctly`() {
        SearchProvider.entries.forEach { provider ->
            val result = converters.toSearchProvider(provider.name)
            assertEquals(provider, result)
        }
    }

    @Test
    fun `toSearchProvider with unknown value returns PUBMED`() {
        val result = converters.toSearchProvider("UNKNOWN_PROVIDER")

        assertEquals(SearchProvider.PUBMED, result)
    }

    @Test
    fun `SearchProvider converter round-trips correctly for all values`() {
        SearchProvider.entries.forEach { provider ->
            val string = converters.fromSearchProvider(provider)
            val restored = converters.toSearchProvider(string)
            assertEquals(provider, restored)
        }
    }
}
