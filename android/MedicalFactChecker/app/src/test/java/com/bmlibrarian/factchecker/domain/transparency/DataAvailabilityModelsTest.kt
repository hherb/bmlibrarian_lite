package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class DataAvailabilityModelsTest {

    @Test
    fun `disclosure level raw values match cross-platform contract`() {
        assertEquals("full_open", DataDisclosureLevel.FULL_OPEN.rawValue)
        assertEquals("on_request", DataDisclosureLevel.AVAILABLE_ON_REQUEST.rawValue)
        assertEquals("restricted", DataDisclosureLevel.RESTRICTED.rawValue)
        assertEquals("not_available", DataDisclosureLevel.NOT_AVAILABLE.rawValue)
        assertEquals("not_stated", DataDisclosureLevel.NOT_STATED.rawValue)
        assertEquals("unknown", DataDisclosureLevel.UNKNOWN.rawValue)
    }

    @Test
    fun `result defaults are unknown and empty`() {
        val result = DataAvailabilityResult()
        assertEquals(DataDisclosureLevel.UNKNOWN, result.disclosureLevel)
        assertTrue(result.restrictions.isEmpty())
    }

    @Test
    fun `not stated companion carries not stated level`() {
        assertEquals(DataDisclosureLevel.NOT_STATED, DataAvailabilityResult.NOT_STATED.disclosureLevel)
    }
}
