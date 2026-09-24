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

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/** A document's transparency, as the app reads it from the stored row. */
class DocumentTransparencyTest {

    /** A result built the way the analysis service builds one. */
    private fun result(
        coiStatement: String? = null,
        fullTextSearched: Boolean? = false,
        industryWithoutData: Boolean = false,
    ): TransparencyResult =
        TransparencyResultBuilder(pmid = "1").apply {
            coiAnalysis = COIAnalysisResult(statement = coiStatement)
            dataAvailability = DataAvailabilityResult(
                disclosureLevel = if (industryWithoutData) DataDisclosureLevel.NOT_AVAILABLE else DataDisclosureLevel.FULL_OPEN,
            )
            industryFundingDetected = industryWithoutData
            dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME)
            this.fullTextSearched = fullTextSearched
        }.build()

    private fun document(
        pmid: String = "1",
        authors: List<String> = listOf("Smith JA", "Jones B"),
        year: Int? = 2021,
        title: String = "A study",
        stored: TransparencyResult? = null,
        source: String = Constants.SOURCE_PUBMED,
    ) = DocumentEntity(
        sessionId = "s",
        pmid = pmid,
        title = title,
        authors = authors,
        publicationYear = year,
        source = source,
        transparencyResultJson = stored?.let { TransparencyJson.encode(it) },
    )

    @Test
    fun `stored result round-trips through the column`() {
        val stored = result()
        assertEquals(stored.riskLevel, document(stored = stored).transparencyResult?.riskLevel)
        assertNull(document().transparencyResult)
    }

    @Test
    fun `an unreadable stored result reads as none and needs re-analysis`() {
        val damaged = document().copy(transparencyResultJson = "{not json")
        assertNull(damaged.transparencyResult)
        assertTrue(damaged.needsTransparencyAnalysis)
    }

    /** No Android text is yet safe to analyse, so every rating says it is limited. */
    @Test
    fun `every rating is limited for want of full text, even one that did not record it`() {
        assertNull(document(stored = result()).analyzableFullText)
        assertEquals(TransparencyCertainty.LIMITED_NO_FULL_TEXT, document(stored = result()).transparencyCertainty)
        assertEquals(
            TransparencyCertainty.LIMITED_NO_FULL_TEXT,
            document(stored = result(fullTextSearched = null)).transparencyCertainty,
        )
        assertEquals(
            "Limited certainty because of lack of full text access",
            document(stored = result()).transparencyCertainty?.note,
        )
    }

    @Test
    fun `a current analysis is not redone but a missing one is`() {
        assertFalse(document(stored = result()).needsTransparencyAnalysis)
        assertTrue(document().needsTransparencyAnalysis)
    }

    @Test
    fun `a document with no identifier cannot be analysed`() {
        assertTrue(document().canAnalyzeTransparency)
        assertFalse(document(pmid = " ").canAnalyzeTransparency)
        assertTrue(document(pmid = " ").copy(doi = "10.1/x").canAnalyzeTransparency)
    }

    @Test
    fun `short reference drops PubMed initials`() {
        assertEquals("Smith et al., 2021", document().shortReference)
        assertEquals("van der Berg, n.d.", document(authors = listOf("van der Berg A"), year = null).shortReference)
        assertEquals("Unknown, 2021", document(authors = emptyList()).shortReference)
    }

    /**
     * Null means "PubMed has no such article", so it is never answered for a
     * PMID the document holds, whichever service the record came through.
     */
    @Test
    fun `stored metadata answers for the document's own PMID only`() = runTest {
        assertEquals("A study", storedMetadataLookup(document()).lookup("1")?.title)
        assertNull(storedMetadataLookup(document()).lookup("2"))
        assertEquals(
            "A study",
            storedMetadataLookup(document(source = Constants.SOURCE_EUROPE_PMC)).lookup("1")?.title,
        )
    }

    /** On Android every rating lacks full text, so a text-only high is unassessed. */
    @Test
    fun `a high rating resting only on unsearched text is unassessed`() {
        assertTrue(document(stored = result()).transparencyIsUnassessed)
        assertFalse(document(stored = result(coiStatement = "None.", industryWithoutData = true)).transparencyIsUnassessed)
        assertFalse(document().transparencyIsUnassessed)
    }

    @Test
    fun `high-risk entries are the documents rated high, in reference order`() {
        val high = result(coiStatement = "None declared.", industryWithoutData = true)
        val textOnly = result()
        val low = result(coiStatement = "None declared.")
        assertEquals(TransparencyRiskLevel.HIGH, high.riskLevel)
        assertEquals(TransparencyRiskLevel.HIGH, textOnly.riskLevel)
        assertFalse(low.riskLevel == TransparencyRiskLevel.HIGH)

        val entries = highRiskTransparencyEntries(
            listOf(
                document(authors = listOf("Young A", "B C"), stored = high),
                document(authors = listOf("Adams A", "B C"), stored = low),
                document(authors = listOf("Baker A", "B C"), stored = high),
                document(authors = listOf("Cole A", "B C")),
                document(authors = listOf("Abel A", "B C"), stored = textOnly),
            ),
        )

        assertEquals(listOf("Baker et al., 2021", "Young et al., 2021"), entries.map { it.reference })
        assertEquals("A study. PMID: 1", entries[0].citation)
        assertEquals(TransparencyCertainty.LIMITED_NO_FULL_TEXT, entries[0].explanation.certainty)
    }
}
