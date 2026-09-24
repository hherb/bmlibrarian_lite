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

package com.bmlibrarian.factchecker.domain.transparency

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** The statement extractors; the same cases as Swift's `JATSBackMatterHeadingTests`. */
class FullTextSectionsTest {

    /** "Data Availability Statement" is a heading, not a statement whose text is "Statement". */
    @Test
    fun `a qualified heading is not captured as the statement`() {
        assertEquals(
            "no new data were created.",
            FullTextSections.extractDataAvailability("## Data Availability Statement\n\nNo new data were created.\n\n## Next"),
        )
        assertEquals(
            "the authors declare none.",
            FullTextSections.extractCoi("Conflict of Interest Statement\n\nThe authors declare none.\n\n"),
        )
    }

    @Test
    fun `an unqualified heading and the inline form are unchanged`() {
        assertEquals("none declared.", FullTextSections.extractCoi("Competing interests: None declared."))
        assertEquals(
            "the authors declare no competing interests.",
            FullTextSections.extractCoi("## Competing interests\n\nThe authors declare no competing interests."),
        )
    }

    /** A bare sentence has no heading to find it by; the parser has to keep the heading. */
    @Test
    fun `a headless statement is not found`() {
        assertNull(FullTextSections.extractCoi("The authors declare no competing interests."))
    }
}
