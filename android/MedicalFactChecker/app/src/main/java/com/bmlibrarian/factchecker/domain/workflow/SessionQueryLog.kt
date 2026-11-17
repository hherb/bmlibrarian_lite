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

package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.QueryBuilderFactory
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SearchQueryLog
import com.bmlibrarian.factchecker.domain.model.SearchQueryRecord
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import kotlinx.serialization.SerializationException
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json

/**
 * A session's log of the queries it ran, read and recorded. Pure; mirrors
 * iOS's `FactCheckSession.searchQueries()` and `recordSearchQuery(_:)`.
 */
object SessionQueryLog {

    /**
     * Every query [session] ran, in the order each first ran.
     *
     * A session saved before queries were logged, or whose log cannot be read,
     * stands in what it kept: see [SearchQueryLog.legacy].
     *
     * @param session The session
     * @param documentIds Every document the session holds, by id
     * @return The queries, empty before the claim has become a query
     */
    fun queries(session: SessionEntity, documentIds: List<String>): List<SearchQueryRecord> =
        SearchQueryLog.decode(session.searchQueriesJson) ?: legacy(session, documentIds)

    /**
     * Whether [session]'s stored log is there but cannot be read.
     */
    fun isUnreadable(session: SessionEntity): Boolean =
        session.searchQueriesJson != null && SearchQueryLog.decode(session.searchQueriesJson) == null

    /**
     * [session]'s log with [run] recorded in it.
     *
     * The first record of a session that searched before queries were logged
     * starts from what that session kept, so its earlier queries are not lost
     * from the list. What it kept counts every document held, the run's own
     * among them once saved: those are the run's, not the kept queries'. A new
     * session's first search has nothing kept to start from.
     *
     * @param session The session, as stored before the run was recorded
     * @param documentIds Every document the session holds, the run's included
     * @param run The query as it was just run, with the documents it added
     * @return The log to store
     */
    fun recorded(session: SessionEntity, documentIds: List<String>, run: SearchQueryRecord): List<SearchQueryRecord> {
        val runs = (run.documentIds ?: emptyList()).toSet()
        val held = SearchQueryLog.decode(session.searchQueriesJson)
            ?: if (documentIds.any { it !in runs } || alternativeQueries(session).isNotEmpty()) {
                legacy(session, documentIds).map { record ->
                    record.copy(documentIds = record.documentIds?.filterNot { it in runs })
                }
            } else {
                emptyList()
            }
        return SearchQueryLog.recording(run, held)
    }

    /** What a session saved before queries were logged kept of its queries. */
    private fun legacy(session: SessionEntity, documentIds: List<String>): List<SearchQueryRecord> =
        SearchQueryLog.legacy(
            initialQuery = session.pubmedQuery,
            provider = session.searchProvider,
            alternatives = alternativeQueries(session).map { query ->
                val withPreprints = query.copy(excludePreprints = !session.includePreprints)
                QueryBuilderFactory.build(withPreprints, SearchProvider.PUBMED) to
                    QueryBuilderFactory.build(withPreprints, SearchProvider.EUROPE_PMC)
            },
            documentIds = documentIds
        )

    /** The alternative queries smart search ran; empty when none, or when the record cannot be read. */
    private fun alternativeQueries(session: SessionEntity): List<StructuredQuery> {
        val json = session.alternativeQueriesJson ?: return emptyList()
        return try {
            Json.decodeFromString(ListSerializer(StructuredQuery.serializer()), json)
        } catch (e: SerializationException) {
            emptyList()
        } catch (e: IllegalArgumentException) {
            emptyList()
        }
    }
}
