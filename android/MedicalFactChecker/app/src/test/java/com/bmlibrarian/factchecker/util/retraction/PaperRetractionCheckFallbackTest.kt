// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import android.util.Log
import io.mockk.every
import io.mockk.mockkStatic
import io.mockk.unmockkStatic
import org.bmlib.ffi.InternalException
import org.bmlib.ffi.retractionStatus
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test

/**
 * A failed check's label stand-in when bmlib itself fails (#675): bmlib is
 * mocked, so this runs without its native library.
 */
class PaperRetractionCheckFallbackTest {
    private val paper = RetractionPaper("10.1000/x", null, listOf("Retracted Publication"))

    @Before
    fun setUp() {
        mockkStatic(BMLIB_FFI)
        Log.clear()
    }

    @After
    fun tearDown() {
        unmockkStatic(BMLIB_FFI)
    }

    @Test
    fun `a label check that panics is failed, never thrown, and its text is not logged`() {
        every { retractionStatus(any(), any(), any(), any()) } throws InternalException("panic: index out of bounds")

        assertEquals(PaperRetractionCheck.failed(RetractionFixture.nowMs), PaperRetractionCheck.failedFor(paper, RetractionFixture.nowMs))
        assertEquals(listOf("PaperRetractionCheck: PubMed label could not be read: InternalException"), Log.lines)
    }

    @Test
    fun `a label check without the native library is failed`() {
        every { retractionStatus(any(), any(), any(), any()) } throws UnsatisfiedLinkError("no bmlib_ffi")

        assertEquals(PaperRetractionCheck.failed(RetractionFixture.nowMs), PaperRetractionCheck.failedFor(paper, RetractionFixture.nowMs))
    }

    private companion object {
        /** The JVM class holding bmlib's top-level UniFFI functions. */
        const val BMLIB_FFI = "org.bmlib.ffi.Bmlib_ffiKt"
    }
}
