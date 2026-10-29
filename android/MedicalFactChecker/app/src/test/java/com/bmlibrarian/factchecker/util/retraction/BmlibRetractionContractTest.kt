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

import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.int
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.bmlib.ffi.CrossrefResult
import org.bmlib.ffi.RetractionEvidence
import org.bmlib.ffi.RetractionKind
import org.bmlib.ffi.RetractionSource
import org.bmlib.ffi.RetractionVerdict
import org.bmlib.ffi.crossrefRetractionRequests
import org.bmlib.ffi.parseCrossrefRetractionResponse
import org.bmlib.ffi.retractionStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Assume.assumeTrue
import org.junit.Before
import org.junit.Test
import java.io.File

/**
 * bmlib's retraction-status contract (bmlib#504) through bmlib's Rust over
 * UniFFI: `doc/cross_platform/retraction_parity/retraction_status.json`.
 *
 * The fixture is copied verbatim from bmlib and never edited here; these
 * runners mirror the desktop's `tests/test_retraction_contract.py`. Results are
 * compared as the fixture's own JSON shape. The library is the host build
 * `cargoHostBmlib` puts on `jna.library.path`; without a bmlib checkout the
 * test skips, and CI fails a skipped run.
 */
class BmlibRetractionContractTest {

    private lateinit var contract: JsonObject

    @Before
    fun setUp() {
        val libraryPath = System.getProperty("jna.library.path")
        assumeTrue(
            "no bmlib checkout configured (bmlib.dir / BMLIB_DIR); see doc/cross_platform/bmlib_sync/uniffi_spike.md",
            libraryPath != null && File(libraryPath).isDirectory
        )
        var candidate: File? = File("").absoluteFile
        val relative = "doc/cross_platform/retraction_parity/retraction_status.json"
        while (candidate != null && !File(candidate, relative).isFile) {
            candidate = candidate.parentFile
        }
        val file = File(checkNotNull(candidate) { "no $relative above the working directory" }, relative)
        contract = Json.parseToJsonElement(file.readText()).jsonObject
    }

    private fun cases(key: String): List<JsonObject> =
        contract.getValue(key).jsonArray.map { it.jsonObject }.also { assertFalse(key, it.isEmpty()) }

    private fun JsonObject.string(key: String): String? = (get(key) as? JsonPrimitive)?.contentOrNull

    private fun JsonObject.strings(key: String): List<String> =
        getValue(key).jsonArray.map { it.jsonPrimitive.content }

    /** `body_text` verbatim, or `body` serialised as JSON. */
    private fun body(answer: JsonObject): ByteArray =
        (answer.string("body_text") ?: answer.getValue("body").toString()).toByteArray(Charsets.UTF_8)

    // Fixture names are the enum names lower-cased (`expression_of_concern`).
    private fun evidence(row: JsonObject) = RetractionEvidence(
        source = RetractionSource.valueOf(row.string("source")!!.uppercase()),
        kind = RetractionKind.valueOf(row.string("kind")!!.uppercase()),
        date = row.string("date"),
        noticeDoi = row.string("notice_doi"),
        recordId = row.string("record_id"),
        rawKind = row.string("raw_kind"),
    )

    private fun json(text: String?): JsonElement = text?.let(::JsonPrimitive) ?: JsonNull

    private fun json(evidence: RetractionEvidence) = JsonObject(
        mapOf(
            "source" to JsonPrimitive(evidence.source.name.lowercase()),
            "kind" to JsonPrimitive(evidence.kind.name.lowercase()),
            "date" to json(evidence.date),
            "notice_doi" to json(evidence.noticeDoi),
            "record_id" to json(evidence.recordId),
            "raw_kind" to json(evidence.rawKind),
        )
    )

    private fun json(strings: List<String>) = JsonArray(strings.map(::JsonPrimitive))

    /** An unreachable result's reason is not part of the contract, but it must name why. */
    private fun json(result: CrossrefResult): JsonObject = when (result) {
        is CrossrefResult.Served -> JsonObject(
            mapOf(
                "outcome" to JsonPrimitive("served"),
                "doi" to JsonPrimitive(result.doi),
                "evidence" to JsonArray(result.evidence.map(::json)),
                "retraction_targets" to json(result.retractionTargets),
            )
        )
        CrossrefResult.NotKnown -> JsonObject(mapOf("outcome" to JsonPrimitive("not_known")))
        is CrossrefResult.Unreachable -> {
            assertTrue("an unreachable result names why", result.reason.isNotEmpty())
            JsonObject(mapOf("outcome" to JsonPrimitive("unreachable")))
        }
    }

    private fun json(verdict: RetractionVerdict) = JsonObject(
        mapOf(
            "status" to JsonPrimitive(verdict.status.name.lowercase()),
            "deciding" to (verdict.deciding?.let(::json) ?: JsonNull),
            "unanswered" to json(verdict.unanswered.map { it.name.lowercase() }),
        )
    )

    /** Each rule case's verdict equals the expected one. */
    @Test
    fun ruleCases() {
        for (case in cases("rule_cases")) {
            val name = case.string("name")
            val doi = case.string("doi")
            val crossref = (case["crossref"] as? JsonObject)?.let { answer ->
                val results = parseCrossrefRetractionResponse(
                    answer.getValue("status").jsonPrimitive.int.toUShort(),
                    body(answer),
                    listOf(checkNotNull(answer.string("for") ?: doi) { "$name: no DOI to ask for" }),
                )
                assertEquals(name, 1, results.size)
                results.values.single()
            }
            val verdict = retractionStatus(
                doi,
                (case["export"] as? JsonArray)?.map { evidence(it.jsonObject) },
                crossref,
                case.strings("publication_types"),
            )
            assertEquals(name, case.getValue("expected"), json(verdict))
        }
    }

    /** Each Crossref answer parses to the expected results, keyed by normalised DOI. */
    @Test
    fun parseCases() {
        for (case in cases("parse_cases")) {
            val results = parseCrossrefRetractionResponse(
                case.getValue("status").jsonPrimitive.int.toUShort(),
                body(case),
                case.strings("requested"),
            )
            assertEquals(case.string("name"), case.getValue("expected"), JsonObject(results.mapValues { json(it.value) }))
        }
    }

    /** The Crossref requests built equal the expected ones exactly. */
    @Test
    fun requestCases() {
        for (case in cases("request_cases")) {
            val requests = crossrefRetractionRequests(case.strings("dois"), case.string("mailto"))
            val got = JsonObject(
                mapOf(
                    "batches" to JsonArray(
                        requests.batches.map {
                            JsonObject(mapOf("url" to JsonPrimitive(it.url), "dois" to json(it.dois)))
                        }
                    ),
                    "unsendable" to json(requests.unsendable),
                )
            )
            assertEquals(case.string("name"), case.getValue("expected"), got)
        }
    }

    /** An older fixture predates `crossref.for` (bmlib#508); fail loudly. */
    @Test
    fun theCopyIsThePinnedBmlibs() {
        assertTrue(contract.string("_readme")!!.contains("crossref.for"))
    }
}
