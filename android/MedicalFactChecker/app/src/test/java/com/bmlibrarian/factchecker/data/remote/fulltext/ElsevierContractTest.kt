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

import com.bmlibrarian.factchecker.domain.model.OpenAccessShortfall
import com.bmlibrarian.factchecker.domain.model.OpenAccessSource
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
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

/**
 * Elsevier's pure rules against the shared contract (#480, stage C2):
 * `doc/cross_platform/fulltext_parity/elsevier_article.json`, every table.
 * ElsevierServiceTest walks the `answers` and `session` tables again through
 * the real service and a local server.
 */
class ElsevierContractTest {

    private val contract: JsonObject by lazy { elsevierContract() }

    /** A contract table's rows, at least [minimum] of them: an emptied table would pass every loop vacuously. */
    private fun table(name: String, minimum: Int): List<JsonObject> {
        val rows = contract.getValue(name).jsonArray.map { it.jsonObject }
        assertTrue("$name has ${rows.size} rows; an emptied table would pass vacuously", rows.size >= minimum)
        return rows
    }

    private fun JsonObject.string(key: String): String = this[key]!!.jsonPrimitive.content

    @Test
    fun `every contract table is read here`() {
        assertEquals(
            setOf(
                "schema_version", "description", "service_name", "source", "source_label",
                "desktop_source_type", "base_url", "doi_prefix", "pause_after_consecutive_429",
                "key_refused_status", "key_refused_reason", "network_refused_status", "network_refused_token",
                "network_refused_reason", "first_page_header", "first_page_prefix", "error_body_max_bytes",
                "follows_redirects", "requests_per_second", "eligible", "article_url", "sendable", "answers",
                "session"
            ),
            contract.keys
        )
    }

    @Test
    fun `the names and values are the contract's`() {
        assertEquals(Constants.ELSEVIER_SERVICE_NAME, contract.string("service_name"))
        assertEquals(Constants.FULLTEXT_SOURCE_ELSEVIER, contract.string("source"))
        assertEquals(OpenAccessSource.ELSEVIER.persistedValue, contract.string("source"))
        assertEquals(OpenAccessSource.ELSEVIER.serviceName, contract.string("service_name"))
        assertEquals(Constants.FULLTEXT_SOURCE_ELSEVIER_LABEL, contract.string("source_label"))
        // The desktop's own type: no Android value names it, so it is only read here
        assertEquals("elsevier_api", contract.string("desktop_source_type"))
        assertEquals(Constants.ELSEVIER_BASE_URL, contract.string("base_url"))
        assertEquals(Constants.ELSEVIER_DOI_PREFIX, contract.string("doi_prefix"))
        assertEquals(
            Constants.ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429,
            contract["pause_after_consecutive_429"]!!.jsonPrimitive.int
        )
        assertEquals(Constants.ELSEVIER_KEY_REFUSED_STATUS, contract["key_refused_status"]!!.jsonPrimitive.int)
        assertEquals(Constants.CORE_KEY_REFUSED_REASON, contract.string("key_refused_reason"))
        assertEquals(Constants.ELSEVIER_NETWORK_REFUSED_STATUS, contract["network_refused_status"]!!.jsonPrimitive.int)
        assertEquals(Constants.ELSEVIER_NETWORK_REFUSED_TOKEN, contract.string("network_refused_token"))
        assertEquals(Constants.ELSEVIER_NETWORK_REFUSED_REASON, contract.string("network_refused_reason"))
        assertEquals(Constants.ELSEVIER_STATUS_HEADER, contract.string("first_page_header"))
        assertEquals(Constants.ELSEVIER_WARNING_PREFIX, contract.string("first_page_prefix"))
        assertEquals(Constants.ELSEVIER_ERROR_BODY_MAX_BYTES, contract["error_body_max_bytes"]!!.jsonPrimitive.int)
        // Redirects are never followed: ElsevierServiceTest pins the client's refusal
        assertFalse(contract["follows_redirects"]!!.jsonPrimitive.boolean)
        assertEquals(
            MILLIS_PER_SECOND / contract["requests_per_second"]!!.jsonPrimitive.int,
            Constants.ELSEVIER_MIN_INTERVAL_MS
        )
    }

    @Test
    fun `each eligible row`() {
        for (row in table("eligible", MIN_ELIGIBLE_ROWS)) {
            assertEquals(
                row.string("doi"),
                row["eligible"]!!.jsonPrimitive.boolean,
                Elsevier.isEligible(row.string("doi"))
            )
        }
    }

    @Test
    fun `each article_url row`() {
        for (row in table("article_url", MIN_ARTICLE_URL_ROWS)) {
            val base = row["base_url"]?.jsonPrimitive?.contentOrNull ?: Constants.ELSEVIER_BASE_URL
            assertEquals(row.string("name"), row.string("url"), Elsevier.articleUrl(row.string("doi"), base))
        }
    }

    /** Only printable ASCII is ever sent as the key or the token. */
    @Test
    fun `each sendable row`() {
        for (row in table("sendable", MIN_SENDABLE_ROWS)) {
            val key = row.string("key")
            val token = row["token"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
            assertEquals(row.string("name"), row["sendable"]!!.jsonPrimitive.boolean, Elsevier.isSendable(key, token))
        }
    }

    /** The URL never carries a credential: neither query parameter is ever written. */
    @Test
    fun `no article URL carries a key or a token`() {
        for (row in table("article_url", MIN_ARTICLE_URL_ROWS)) {
            val url = Elsevier.articleUrl(row.string("doi"))
            assertFalse(url, "apiKey" in url || "insttoken" in url || "?" in url)
        }
    }

    @Test
    fun `each answers row`() {
        for (row in table("answers", MIN_ANSWER_ROWS)) {
            val name = row.string("name")
            val answer = Elsevier.classify(row.getValue("status").jsonPrimitive.int, headersOf(row), bodyOf(row))
            assertEquals(name, expectedAnswer(row, row.getValue("status").jsonPrimitive.int), answer)
        }
    }

    /**
     * Each session row from a fresh session: the fetches given, then each check
     * in turn, by the pure rules a fetch follows ([Elsevier.answerWithoutAsking],
     * [Elsevier.classify], [Elsevier.record]).
     */
    @Test
    fun `each session row`() {
        for (row in table("session", MIN_SESSION_ROWS)) {
            val name = row.string("name")
            val session = Elsevier.newSession()
            for (fetch in row.getValue("fetches").jsonArray.map { it.jsonObject }) {
                pureFetch(session, fetch)
            }
            for (check in row.getValue("then").jsonArray.map { it.jsonObject }) {
                val (asked, answer) = pureFetch(session, check)
                assertEquals("$name: $check", check["asked"]!!.jsonPrimitive.boolean, asked)
                assertEquals("$name: $check", expectedSessionAnswer(check), answer)
            }
        }
    }

    /** One fetch by the pure rules: whether a request was made, and the answer. */
    private fun pureFetch(session: KeyedServiceSession, fetch: JsonObject): Pair<Boolean, ElsevierAnswer> {
        val (key, token) = credentialsOf(fetch)
        val keyDigest = KeyDigest.key(key)
        val credentialsDigest = KeyDigest.credentials(key, token)
        Elsevier.answerWithoutAsking(session, keyDigest, credentialsDigest, Elsevier.isSendable(key, token))
            ?.let { return false to it }
        val status = fetch.getValue("status").jsonPrimitive.int
        val body = fetch["body_text"]?.jsonPrimitive?.contentOrNull.orEmpty().toByteArray(Charsets.UTF_8)
        val answer = Elsevier.classify(status, emptyList(), body)
        Elsevier.record(answer, status, session, keyDigest, credentialsDigest)
        return true to answer
    }

    @Test
    fun `a digest is SHA-256 hex of the trimmed key, and of key, newline and token`() {
        assertEquals(Core.keyDigest("key-A"), KeyDigest.key(" key-A\n"))
        assertEquals(SHA256_HEX_DIGITS, KeyDigest.credentials("key-A", null).length)
        assertEquals(KeyDigest.credentials("key-A", null), KeyDigest.credentials(" key-A ", "  "))
        assertEquals(KeyDigest.sha256Hex("key-A\ntoken-T"), KeyDigest.credentials("key-A", " token-T\n"))
        assertFalse(KeyDigest.credentials("key-A", null) == KeyDigest.credentials("key-A", "token-T"))
    }

    @Test
    fun `Elsevier is first in chain order`() {
        assertEquals(OpenAccessSource.ELSEVIER, OpenAccessShortfall.CHAIN_ORDER.first())
    }

    @Test
    fun `the cache file is named by the normalised DOI's digest`() {
        val name = Elsevier.cacheFileName("https://doi.org/10.1016/J.Cell.1")
        assertEquals(name, Elsevier.cacheFileName(" 10.1016/j.cell.1\n"))
        assertEquals("elsevier-${KeyDigest.sha256Hex("10.1016/j.cell.1")}.pdf", name)
    }

    private companion object {
        /** The contract's row counts when these tests were written (#480, stage C2). */
        const val MIN_ELIGIBLE_ROWS = 10
        const val MIN_ARTICLE_URL_ROWS = 12
        const val MIN_ANSWER_ROWS = 24
        const val MIN_SENDABLE_ROWS = 11
        const val MIN_SESSION_ROWS = 11
        const val MILLIS_PER_SECOND = 1000L
        const val SHA256_HEX_DIGITS = 64
    }
}

/** The contract, read from the repository above the working directory. */
internal fun elsevierContract(): JsonObject = Json.parseToJsonElement(
    generateSequence(File("").absoluteFile) { it.parentFile }
        .map { File(it, "doc/cross_platform/fulltext_parity/elsevier_article.json") }
        .first { it.isFile }
        .readText()
).jsonObject

/** A row's response headers, as name and value pairs. */
internal fun headersOf(row: JsonObject): List<Pair<String, String>> =
    row["headers"]?.jsonObject?.map { (name, value) -> name to value.jsonPrimitive.content }.orEmpty()

/** The bytes the contract's `%PDF` body stands for: `%PDF-1.7`, a newline and some bytes. */
internal val CONTRACT_PDF_BODY: ByteArray = "%PDF-1.7\nsome bytes of a PDF".toByteArray(Charsets.US_ASCII)

/** A row's body: a PDF, or `body_padding_bytes` spaces then `body_text`. */
internal fun bodyOf(row: JsonObject): ByteArray {
    if (row["body_pdf"]?.jsonPrimitive?.boolean == true) return CONTRACT_PDF_BODY
    val padding = row["body_padding_bytes"]?.jsonPrimitive?.int ?: 0
    val text = row["body_text"]?.jsonPrimitive?.contentOrNull.orEmpty()
    return " ".repeat(padding).toByteArray(Charsets.US_ASCII) + text.toByteArray(Charsets.UTF_8)
}

/** A row's key and token, the token null when the row gives none. */
internal fun credentialsOf(row: JsonObject): Pair<String, String?> {
    val credentials = row.getValue("credentials").jsonObject
    return credentials.getValue("key").jsonPrimitive.content to
        credentials["token"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.content
}

/** The failure an unreachable row names: its status for http_status, none for any other kind. */
private fun failureOf(row: JsonObject, status: Int?): RequestFailure {
    val kind = RequestFailureKind.fromPersisted(row.getValue("failure_kind").jsonPrimitive.content)
        ?: error("unknown failure kind in $row")
    return if (kind == RequestFailureKind.HTTP_STATUS) RequestFailure.forHttpStatus(status!!) else RequestFailure(kind)
}

/**
 * The answer an `answers` row expects. A first page is its own answer (an absence
 * told apart, so it can be logged); the contract calls it absent, as the fetch does.
 */
internal fun expectedAnswer(row: JsonObject, status: Int): ElsevierAnswer = when (row.getValue("outcome").jsonPrimitive.content) {
    "served" -> ElsevierAnswer.Served
    "absent" -> if (status == Constants.HTTP_OK) ElsevierAnswer.FirstPageOnly else ElsevierAnswer.Absent
    "unreachable" -> ElsevierAnswer.Unreachable(failureOf(row, status))
    "key_refused" -> ElsevierAnswer.KeyRefused
    "network_refused" -> ElsevierAnswer.NetworkRefused
    else -> error("unknown outcome in $row")
}

/** The answer a `session` check expects; an unreachable one names its own `status_code`. */
internal fun expectedSessionAnswer(check: JsonObject): ElsevierAnswer =
    if (check.getValue("outcome").jsonPrimitive.content == "unreachable") {
        ElsevierAnswer.Unreachable(failureOf(check, check["status_code"]?.takeUnless { it is JsonNull }?.jsonPrimitive?.int))
    } else {
        expectedAnswer(check, check.getValue("status").jsonPrimitive.int)
    }

/** The fetch outcome an answer comes to, a PDF served at [savedPath]. */
internal fun fetchFor(answer: ElsevierAnswer, savedPath: String): ElsevierFetch = when (answer) {
    ElsevierAnswer.Served -> ElsevierFetch.Served(savedPath)
    ElsevierAnswer.Absent, ElsevierAnswer.FirstPageOnly -> ElsevierFetch.Absent
    is ElsevierAnswer.Unreachable -> ElsevierFetch.Unreachable(answer.failure)
    ElsevierAnswer.KeyRefused -> ElsevierFetch.KeyRefused
    ElsevierAnswer.NetworkRefused -> ElsevierFetch.NetworkRefused
}
