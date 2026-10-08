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
package com.bmlibrarian.factchecker.data.repository

import android.content.SharedPreferences
import android.util.Log
import io.mockk.every
import io.mockk.mockk
import kotlinx.coroutines.CancellationException
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertThrows
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import java.security.GeneralSecurityException

/**
 * Saving a key (the CORE and NCBI keys, #480, #496): committed, so a failed write
 * is known; the cache takes the key only once it is written; and nothing that
 * fails is reported as saved, or logged with the key.
 */
class WriteSecretKeyTest {

    private val prefKey = "core_api_key"
    private val key = "secret-core-key"
    private val cache = mutableMapOf(prefKey to "old-key")

    @Before
    fun setUp() {
        Log.clear()
    }

    /** Preferences whose editor's commit answers [committed]. */
    private fun prefsCommitting(committed: Boolean): SharedPreferences {
        val editor = mockk<SharedPreferences.Editor> {
            every { putString(any(), any()) } returns this
            every { commit() } returns committed
        }
        return mockk { every { edit() } returns editor }
    }

    @Test
    fun `a committed key is written and cached`() {
        assertTrue(writeSecretKey({ prefsCommitting(true) }, cache, prefKey, key, "CORE API key"))
        assertEquals(key, cache[prefKey])
    }

    @Test
    fun `a commit that fails leaves the key in use`() {
        assertFalse(writeSecretKey({ prefsCommitting(false) }, cache, prefKey, key, "CORE API key"))
        assertEquals("old-key", cache[prefKey])
        assertEquals(listOf("SettingsRepository: The CORE API key could not be written"), Log.lines)
    }

    /** An encryption failure in the write is reported, not thrown, and the key is never logged. */
    @Test
    fun `a write that throws is a failure`() {
        val editor = mockk<SharedPreferences.Editor> {
            every { putString(any(), any()) } throws SecurityException("keystore")
        }
        val prefs = mockk<SharedPreferences> { every { edit() } returns editor }
        assertFalse(writeSecretKey({ prefs }, cache, prefKey, key, "CORE API key"))
        assertEquals("old-key", cache[prefKey])
        assertEquals(listOf("SettingsRepository: The CORE API key could not be saved: SecurityException"), Log.lines)
    }

    /** Opening the encrypted store can fail too (its master key): a failure, not a crash. */
    @Test
    fun `preferences that cannot be opened are a failure`() {
        val opening: () -> SharedPreferences = { throw IllegalStateException(GeneralSecurityException("master key")) }
        assertFalse(writeSecretKey(opening, cache, prefKey, key, "NCBI API key"))
        assertEquals("old-key", cache[prefKey])
        assertFalse(Log.lines.toString(), Log.lines.any { key in it })
    }

    @Test
    fun `cancellation still propagates`() {
        val opening: () -> SharedPreferences = { throw CancellationException("cancelled") }
        assertThrows(CancellationException::class.java) {
            writeSecretKey(opening, cache, prefKey, key, "CORE API key")
        }
    }
}
