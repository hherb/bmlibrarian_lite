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

package com.bmlibrarian.factchecker.domain.model

import com.bmlibrarian.factchecker.util.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Which email Unpaywall can be asked with (#466; Python's `usable_unpaywall_email`). */
class UnpaywallContactTest {

    @Test
    fun `a configured address is used, trimmed`() {
        assertEquals("reader@uni.edu", UnpaywallContact.usableEmail("  reader@uni.edu \n"))
    }

    @Test
    fun `blank, missing and the placeholder are no address`() {
        assertNull(UnpaywallContact.usableEmail(null, "", "   ", Constants.UNPAYWALL_DEFAULT_EMAIL))
        assertNull(UnpaywallContact.usableEmail(" ${Constants.UNPAYWALL_DEFAULT_EMAIL} "))
        assertNull(UnpaywallContact.usableEmail())
    }

    @Test
    fun `the first usable candidate wins`() {
        assertEquals("second@uni.edu", UnpaywallContact.usableEmail(Constants.UNPAYWALL_DEFAULT_EMAIL, "second@uni.edu", "third@uni.edu"))
    }

    @Test
    fun `the Unpaywall email is preferred, then the NCBI email the settings screen offers`() {
        assertEquals(
            "unpaywall@uni.edu",
            UnpaywallContact.emailFor(AppSettings(unpaywallEmail = "unpaywall@uni.edu", ncbiEmail = "ncbi@uni.edu"))
        )
        assertEquals("ncbi@uni.edu", UnpaywallContact.emailFor(AppSettings(ncbiEmail = "ncbi@uni.edu")))
        assertNull(UnpaywallContact.emailFor(AppSettings()))
    }
}
