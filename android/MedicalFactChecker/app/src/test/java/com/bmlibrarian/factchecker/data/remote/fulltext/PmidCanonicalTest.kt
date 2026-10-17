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
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.boolean
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

/** A PMID is canonical ASCII digits, or it is not sent: the shared contract's rows. */
class PmidCanonicalTest {
    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/pmid_canonical.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("pmid_canonical.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    @Test
    fun everyContractKeyIsReadHere() {
        assertEquals(
            setOf("schema_version", "description", "source", "stripped_whitespace", "cases"),
            contract.keys
        )
    }

    @Test
    fun everyCaseHasEveryKey() {
        // "note" is prose for the contract's reader, read by no suite.
        val required = setOf("name", "input", "pmid", "pmc_id", "refused")
        for (element in contract.getValue("cases").jsonArray) {
            val row = element.jsonObject
            assertEquals(row["name"].toString(), required, row.keys - "note")
        }
    }

    @Test
    fun theStrippedWhitespaceIsTheContracts() {
        val listed = contract.getValue("stripped_whitespace").jsonArray.map { it.jsonPrimitive.int }
        assertEquals(listed.size, listed.toSet().size)
        assertEquals(listed.toSet(), Constants.PMID_STRIPPED_WHITESPACE)
    }

    @Test
    fun eachContractCase() {
        val cases = contract.getValue("cases").jsonArray
        assertTrue(cases.size >= 11)
        for (element in cases) {
            val row = element.jsonObject
            val input = row.getValue("input").jsonPrimitive.content
            val expected = PmidReading(
                pmid = row["pmid"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull,
                pmcId = row["pmc_id"]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull,
                refused = row.getValue("refused").jsonPrimitive.boolean
            )
            val name = row.getValue("name").jsonPrimitive.content
            assertEquals("$name: input '$input'", expected, Pmid.canonical(input))
        }
    }

    @Test
    fun canonicalCheck() {
        assertTrue(Pmid.isCanonical("33301246"))
        assertFalse(Pmid.isCanonical("0033301246"))
        assertFalse(Pmid.isCanonical(""))
        assertFalse(Pmid.isCanonical("PMC1"))
    }

    @Test
    fun resolveQueriesCarryTheCanonicalPmidOrNone() {
        assertEquals(
            listOf("ext_id:33301246 src:med"),
            FullTextService.pmidQueries("0033301246", doi = null)
        )
        assertEquals(
            listOf("DOI:\"10.1/x\""),
            FullTextService.pmidQueries("1 OR 2", doi = "10.1/x")
        )
        assertEquals(emptyList<String>(), FullTextService.pmidQueries("0000", doi = null))
        assertEquals(listOf("PMCID:PMC7745181"), FullTextService.pmidQueries("PMC7745181", doi = null))
        assertEquals(emptyList<String>(), FullTextService.pmidQueries(null, doi = null))
    }
}
