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

import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import java.io.File
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * The verb a failed lookup earns, read from the contract all three platforms share
 * (#447): `doc/cross_platform/request_failure_parity/answered_lookup_verb.json`.
 *
 * Each platform used to pin its own table, so a change on one passed that
 * platform's tests and left the three disagreeing about what the reader is told.
 */
class AnsweredLookupVerbContractTest {

    @Serializable
    private data class Contract(
        @SerialName("unanswered_statuses") val unansweredStatuses: UnansweredStatuses,
        val predicate: List<PredicateRow>,
        @SerialName("absence_not_established") val absenceNotEstablished: List<SentenceRow>
    )

    /** The statuses that are not an answer: each one listed, and a range. */
    @Serializable
    private data class UnansweredStatuses(val listed: List<Int>, val from: Int, val through: Int) {
        val all: Set<Int> get() = listed.toSet() + (from..through)
    }

    /** One (kind, status) and whether it is an answer. */
    @Serializable
    private data class PredicateRow(
        val kind: String,
        @SerialName("status_code") val statusCode: Int?,
        @SerialName("is_answer") val isAnswer: Boolean
    )

    /** One failure and the whole sentence the reader is shown for it. */
    @Serializable
    private data class SentenceRow(
        val kind: String,
        @SerialName("status_code") val statusCode: Int?,
        val sentence: String
    )

    private val contract: Contract by lazy {
        Json { ignoreUnknownKeys = true }.decodeFromString(Contract.serializer(), contractFile().readText())
    }

    /**
     * The contract, found by walking up from the Gradle working directory. Read
     * from the repository, never copied into test resources: every platform must
     * read the same bytes.
     */
    private fun contractFile(): File {
        val relative = "doc/cross_platform/request_failure_parity/answered_lookup_verb.json"
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val found = File(candidate, relative)
            if (found.isFile) return found
            candidate = candidate.parentFile
        }
        error("could not locate $relative above ${File("").absolutePath}")
    }

    /** The failure a row names; a kind the contract spells wrongly fails loudly. */
    private fun failure(kind: String, statusCode: Int?): RequestFailure =
        RequestFailure(
            requireNotNull(RequestFailureKind.fromPersisted(kind)) { "unknown kind '$kind'" },
            statusCode
        )

    @Test
    fun `each predicate row`() {
        assertFalse(contract.predicate.isEmpty())
        for (row in contract.predicate) {
            assertEquals("$row", row.isAnswer, failure(row.kind, row.statusCode).isAnswer)
        }
    }

    /** Python and Swift name the same statuses. */
    @Test
    fun `the unanswered statuses are the contract's`() {
        assertEquals(contract.unansweredStatuses.all, Constants.UNANSWERED_STATUS_CODES)
    }

    /** A kind added later cannot inherit a verb nobody chose for it. */
    @Test
    fun `every kind has a row`() {
        assertEquals(
            RequestFailureKind.entries.map { it.persistedValue }.toSet(),
            contract.predicate.map { it.kind }.toSet()
        )
    }

    /** The reader's sentence, asserted whole, so the tail cannot drift from BioMedLit's. */
    @Test
    fun `each sentence row`() {
        assertFalse(contract.absenceNotEstablished.isEmpty())
        for (row in contract.absenceNotEstablished) {
            assertEquals(row.sentence, absenceNotEstablishedMessage(failure(row.kind, row.statusCode)))
        }
    }
}
