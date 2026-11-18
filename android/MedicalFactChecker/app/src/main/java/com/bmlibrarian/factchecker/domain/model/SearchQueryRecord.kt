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

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import java.text.NumberFormat

/**
 * One search query a session ran, and the documents it brought into the session.
 *
 * A session runs its initial query (page after page, as more evidence is
 * fetched) and, through smart search, alternative queries. Each is kept once,
 * with every document it added, so the reader can see every query that was
 * asked and how much each one found. Mirrors iOS's `SearchQueryRecord`.
 *
 * @property kind Where the query came from
 * @property provider The provider the query was asked of
 * @property query The query as it was sent (PubMed's when both providers were asked)
 * @property europePmcQuery The query as Europe PMC was asked it, when both
 *   providers were searched and it is not [query]
 * @property documentIds The documents this query added to the session, by
 *   document id, in the order they were added; null when not recorded (a
 *   session saved before queries were logged). A document another query had
 *   already found is not added again, so it counts for the query that found it first.
 * @property totalHits How many matches the source(s) reported, the latest
 *   page's; null when not known
 */
@Serializable
data class SearchQueryRecord(
    val kind: Kind,
    val provider: SearchProvider,
    val query: String,
    @SerialName("europe_pmc_query") val europePmcQuery: String? = null,
    @SerialName("document_ids") val documentIds: List<String>? = null,
    @SerialName("total_hits") val totalHits: Int? = null
) {
    /** Where a query came from. */
    @Serializable
    enum class Kind {
        /** The query the claim was converted to. */
        @SerialName("initial") INITIAL,

        /** A query smart search generated when the initial one found too little. */
        @SerialName("alternative") ALTERNATIVE
    }

    /** Whether [other] is the same query, asked of the same provider. */
    fun isSameQuery(other: SearchQueryRecord): Boolean =
        kind == other.kind && provider == other.provider && query == other.query
}

/**
 * How much one query found, and how much of it was relevant.
 *
 * @property found Documents the query added to the session
 * @property scored Of those, the documents scored so far
 * @property relevant Of those, the documents scored at or above the relevance threshold
 */
data class SearchQueryStatistics(val found: Int, val scored: Int, val relevant: Int)

/**
 * A query and what it found, as the reader is shown it.
 *
 * @property label The query's name in the list ("Initial query", "Alternative 1", …)
 * @property record The query
 * @property statistics What it found; null when that was not recorded
 */
data class SearchQueryRow(
    val label: String,
    val record: SearchQueryRecord,
    val statistics: SearchQueryStatistics?
)

/** Pure rules for a session's log of queries. Mirrors iOS's `SearchQueryLog`. */
object SearchQueryLog {
    private val serializer = ListSerializer(SearchQueryRecord.serializer())
    private val json = Json { ignoreUnknownKeys = true }

    /**
     * The log with [run] recorded in it.
     *
     * A query already in the log (the same kind, provider and query: a later
     * page of it) gains the run's documents and its latest count of matches; a
     * new one is added at the end. A record whose documents were not recorded
     * stays unrecorded: its count would be only the latest pages'.
     *
     * @param run The query as it was just run, with the documents it added
     * @param log The queries recorded so far, in the order they first ran
     * @return The log with the run recorded
     */
    fun recording(run: SearchQueryRecord, log: List<SearchQueryRecord>): List<SearchQueryRecord> {
        val index = log.indexOfFirst { it.isSameQuery(run) }
        if (index < 0) return log + run
        val existing = log[index]
        val merged = existing.copy(
            documentIds = existing.documentIds?.let { held ->
                val heldSet = held.toSet()
                held + (run.documentIds ?: emptyList()).filterNot { it in heldSet }
            },
            totalHits = run.totalHits ?: existing.totalHits
        )
        return log.toMutableList().also { it[index] = merged }
    }

    /**
     * How much [record] found, and how much of it was relevant.
     *
     * @param record The query
     * @param scores The relevance score of every scored document in the
     *   session, by document id; a document not scored yet is absent
     * @param minScore The lowest score that counts as relevant
     * @return The query's counts, or null when its documents were not recorded
     */
    fun statistics(record: SearchQueryRecord, scores: Map<String, Int>, minScore: Int): SearchQueryStatistics? {
        val ids = record.documentIds ?: return null
        val held = ids.mapNotNull { scores[it] }
        return SearchQueryStatistics(found = ids.size, scored = held.size, relevant = held.count { it >= minScore })
    }

    /**
     * The reader's name for the query at [index] of [log].
     *
     * The initial query is "Initial query"; smart search's are numbered in the
     * order they ran ("Alternative 1", "Alternative 2", …).
     */
    fun label(index: Int, log: List<SearchQueryRecord>): String {
        val upTo = log.subList(0, index + 1)
        return when (log[index].kind) {
            SearchQueryRecord.Kind.INITIAL -> {
                val initials = upTo.count { it.kind == SearchQueryRecord.Kind.INITIAL }
                if (initials > 1) "Initial query ($initials)" else "Initial query"
            }
            SearchQueryRecord.Kind.ALTERNATIVE ->
                "Alternative ${upTo.count { it.kind == SearchQueryRecord.Kind.ALTERNATIVE }}"
        }
    }

    /**
     * The reader's line for a query's counts, e.g. "12 found · 4 relevant".
     *
     * Documents not scored yet are named, so a running search does not read as
     * having found nothing relevant; the source's count of matches is added
     * where it is known.
     *
     * @param statistics The query's counts
     * @param totalHits The matches the source(s) reported, if known
     * @param numberFormat How the count of matches is written
     */
    fun statisticsLine(
        statistics: SearchQueryStatistics,
        totalHits: Int?,
        numberFormat: NumberFormat = NumberFormat.getIntegerInstance()
    ): String {
        val parts = mutableListOf("${statistics.found} found", "${statistics.relevant} relevant")
        val unscored = statistics.found - statistics.scored
        if (unscored > 0) parts += "$unscored not scored"
        if (totalHits != null) parts += "${numberFormat.format(totalHits)} matches"
        return parts.joinToString(" · ")
    }

    /**
     * The rows the reader is shown: every query, named, with its counts.
     *
     * @param log The session's queries
     * @param scores The relevance score of every scored document, by document id
     * @param minScore The lowest score that counts as relevant
     */
    fun rows(log: List<SearchQueryRecord>, scores: Map<String, Int>, minScore: Int): List<SearchQueryRow> =
        log.indices.map { index ->
            SearchQueryRow(label(index, log), log[index], statistics(log[index], scores, minScore))
        }

    /**
     * What a session saved before queries were logged kept of its queries.
     *
     * Its initial query, with every document when it ran no other (so all of
     * them are its), and the alternative queries smart search ran, whose
     * documents were not recorded.
     *
     * @param initialQuery The session's initial query, as stored
     * @param provider The session's provider
     * @param alternatives The alternative queries smart search ran, as sent to
     *   PubMed and to Europe PMC (in that order)
     * @param documentIds Every document the session holds, by id
     * @return The queries, empty when the claim never became a query
     */
    fun legacy(
        initialQuery: String?,
        provider: SearchProvider,
        alternatives: List<Pair<String, String>>,
        documentIds: List<String>
    ): List<SearchQueryRecord> {
        if (initialQuery.isNullOrEmpty()) return emptyList()
        var log = listOf(
            SearchQueryRecord(
                kind = SearchQueryRecord.Kind.INITIAL,
                provider = provider,
                query = initialQuery,
                documentIds = if (alternatives.isEmpty()) documentIds else null
            )
        )
        for ((pubMed, europePmc) in alternatives) {
            log = recording(
                forProvider(SearchQueryRecord.Kind.ALTERNATIVE, provider, pubMed, europePmc, documentIds = null, totalHits = null),
                log
            )
        }
        return log
    }

    /**
     * The record of a query asked of [provider], from its PubMed and Europe PMC forms.
     *
     * @param kind Where the query came from
     * @param provider The provider(s) it was asked of
     * @param pubMedQuery The query as PubMed is asked it
     * @param europePmcQuery The query as Europe PMC is asked it
     * @param documentIds The documents it added to the session
     * @param totalHits The matches the source(s) reported
     */
    fun forProvider(
        kind: SearchQueryRecord.Kind,
        provider: SearchProvider,
        pubMedQuery: String,
        europePmcQuery: String,
        documentIds: List<String>?,
        totalHits: Int?
    ): SearchQueryRecord = SearchQueryRecord(
        kind = kind,
        provider = provider,
        query = if (provider == SearchProvider.EUROPE_PMC) europePmcQuery else pubMedQuery,
        europePmcQuery = europePmcQuery.takeIf { provider == SearchProvider.BOTH && it != pubMedQuery },
        documentIds = documentIds,
        totalHits = totalHits
    )

    /**
     * Decode a stored log.
     *
     * @param stored The log's JSON, or null when none was stored
     * @return The queries, or null when none was stored or it cannot be read
     */
    fun decode(stored: String?): List<SearchQueryRecord>? {
        stored ?: return null
        return try {
            json.decodeFromString(serializer, stored)
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
    }

    /**
     * Encode a log for storage.
     *
     * @return The JSON, or null when it cannot be encoded
     */
    fun encode(log: List<SearchQueryRecord>): String? = try {
        json.encodeToString(serializer, log)
    } catch (e: SerializationException) {
        null
    }
}
