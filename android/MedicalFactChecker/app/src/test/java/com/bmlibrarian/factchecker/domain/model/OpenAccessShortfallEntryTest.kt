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

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

/**
 * Only Unpaywall's own lookup can be skipped as not configured (#480), as in
 * Swift: an entry that broke this would be written as a skip that
 * [OpenAccessShortfall.fromJson] reads back as Unpaywall's, so it cannot be
 * built.
 */
class OpenAccessShortfallEntryTest {

    @Test
    fun `a skip on any source but Unpaywall cannot be built`() {
        for (source in OpenAccessSource.entries - OpenAccessSource.UNPAYWALL) {
            assertThrows("$source", IllegalArgumentException::class.java) {
                OpenAccessShortfall.Entry(source, OpenAccessUnsettledReason.NotConfigured)
            }
        }
    }

    @Test
    fun `a skip with an address cannot be built`() {
        assertThrows(IllegalArgumentException::class.java) {
            OpenAccessShortfall.Entry(
                OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.NotConfigured, "https://repo.example.org/a.pdf"
            )
        }
    }

    /** Only CORE's or Elsevier's own lookup is skipped for a refused key, never with an address (#498, #480). */
    @Test
    fun `a refused key on any source but CORE or Elsevier, or with an address, cannot be built`() {
        for (source in OpenAccessSource.entries - OpenAccessSource.CORE - OpenAccessSource.ELSEVIER) {
            assertThrows("$source", IllegalArgumentException::class.java) {
                OpenAccessShortfall.Entry(source, OpenAccessUnsettledReason.KeyRefused)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            OpenAccessShortfall.Entry(
                OpenAccessSource.CORE, OpenAccessUnsettledReason.KeyRefused, "https://repo.example.org/a.pdf"
            )
        }
        assertThrows(IllegalArgumentException::class.java) {
            OpenAccessShortfall.Entry(
                OpenAccessSource.ELSEVIER, OpenAccessUnsettledReason.KeyRefused, "https://api.elsevier.com/x"
            )
        }
        // The controls
        assertEquals(
            OpenAccessShortfall.CORE_KEY_REFUSED,
            OpenAccessShortfall(listOf(OpenAccessShortfall.Entry(OpenAccessSource.CORE, OpenAccessUnsettledReason.KeyRefused)))
        )
        assertEquals(
            OpenAccessShortfall.ELSEVIER_KEY_REFUSED,
            OpenAccessShortfall(
                listOf(OpenAccessShortfall.Entry(OpenAccessSource.ELSEVIER, OpenAccessUnsettledReason.KeyRefused))
            )
        )
    }

    /** Only Elsevier's own lookup is skipped as refused from this network, never with an address (#480). */
    @Test
    fun `a network refusal on any source but Elsevier, or with an address, cannot be built`() {
        for (source in OpenAccessSource.entries - OpenAccessSource.ELSEVIER) {
            assertThrows("$source", IllegalArgumentException::class.java) {
                OpenAccessShortfall.Entry(source, OpenAccessUnsettledReason.NetworkRefused)
            }
        }
        assertThrows(IllegalArgumentException::class.java) {
            OpenAccessShortfall.Entry(
                OpenAccessSource.ELSEVIER, OpenAccessUnsettledReason.NetworkRefused, "https://api.elsevier.com/x"
            )
        }
        // The control
        assertEquals(
            OpenAccessShortfall.ELSEVIER_NETWORK_REFUSED,
            OpenAccessShortfall(
                listOf(OpenAccessShortfall.Entry(OpenAccessSource.ELSEVIER, OpenAccessUnsettledReason.NetworkRefused))
            )
        )
    }

    /** The controls: Unpaywall's skip, a blank address (no address), and failures on every source. */
    @Test
    fun `Unpaywall's skip and every failure can be built, and round-trip`() {
        val skip = OpenAccessShortfall.Entry(OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.NotConfigured, "  ")
        assertNull(skip.address)
        assertEquals(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED, OpenAccessShortfall(listOf(skip)))
        assertEquals(
            OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED,
            OpenAccessShortfall.fromJson(OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED.toJson())
        )
        for (source in OpenAccessSource.entries) {
            val failed = OpenAccessShortfall(
                source, RequestFailure(RequestFailureKind.TIMEOUT), "https://repo.example.org/a.pdf"
            )
            assertEquals("$source", failed, OpenAccessShortfall.fromJson(failed.toJson()))
        }
    }
}
