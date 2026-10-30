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
package com.bmlibrarian.factchecker.data.remote

import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCArticle
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/** Publication types are kept as the source listed them, for the retraction check's label rule. */
class PublicationTypesTest {

    private val json = Json { ignoreUnknownKeys = true }

    private fun pubTypes(value: String): List<String>? =
        json.decodeFromString<EuropePMCArticle>("""{"title":"T","pubTypeList":{"pubType":$value}}""").pubTypeList?.pubType

    @Test
    fun `Europe PMC's list is kept`() {
        assertEquals(listOf("Retracted Publication", "research-article"), pubTypes("""["Retracted Publication","research-article"]"""))
    }

    @Test
    fun `a lone string is a list of one`() {
        assertEquals(listOf("Retracted Publication"), pubTypes("\"Retracted Publication\""))
    }

    @Test
    fun `entries that are not strings are skipped, any other shape is no list`() {
        assertEquals(listOf("Journal Article"), pubTypes("""[1,"Journal Article",{"a":1}]"""))
        assertNull(pubTypes("""{"a":1}"""))
        assertNull(pubTypes("null"))
    }

    @Test
    fun `no list is not recorded, an empty list is`() {
        assertNull(DocumentEntity(sessionId = "s", title = "T").publicationTypes)
        assertNull(DocumentEntity.encodePublicationTypes(null))
        val listedNone = DocumentEntity(sessionId = "s", title = "T", publicationTypesJson = DocumentEntity.encodePublicationTypes(emptyList()))
        assertEquals(emptyList<String>(), listedNone.publicationTypes)
    }

    @Test
    fun `an unreadable stored list reads as not recorded`() {
        assertNull(DocumentEntity(sessionId = "s", title = "T", publicationTypesJson = "{").publicationTypes)
    }
}
