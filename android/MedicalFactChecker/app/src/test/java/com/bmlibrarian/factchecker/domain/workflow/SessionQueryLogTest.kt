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
import com.bmlibrarian.factchecker.domain.model.SearchConcept
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.SearchQueryLog
import com.bmlibrarian.factchecker.domain.model.SearchQueryRecord
import com.bmlibrarian.factchecker.domain.model.StructuredQuery
import kotlinx.serialization.builtins.ListSerializer
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * A session's queries are read from its log, or, for a session saved before
 * queries were logged, from what it kept.
 */
class SessionQueryLogTest {

    private val session = SessionEntity(claimText = "c", pubmedQuery = "q", searchProvider = SearchProvider.PUBMED)

    private fun run(kind: SearchQueryRecord.Kind, query: String, ids: List<String>) =
        SearchQueryRecord(kind, SearchProvider.PUBMED, query, documentIds = ids)

    @Test
    fun `a session saved before the log lists its query, with every document when it ran no other`() {
        val queries = SessionQueryLog.queries(session, listOf("a", "b"))

        assertEquals(1, queries.size)
        assertEquals(SearchQueryRecord.Kind.INITIAL, queries[0].kind)
        assertEquals(listOf("a", "b"), queries[0].documentIds)
    }

    @Test
    fun `its smart search queries are listed too, without counts it did not keep`() {
        val alternatives = listOf(StructuredQuery(concepts = listOf(SearchConcept(name = "aspirin", keywords = listOf("aspirin")))))
        val kept = session.copy(
            alternativeQueriesJson = Json.encodeToString(ListSerializer(StructuredQuery.serializer()), alternatives)
        )

        val queries = SessionQueryLog.queries(kept, listOf("a"))

        assertEquals(listOf(SearchQueryRecord.Kind.INITIAL, SearchQueryRecord.Kind.ALTERNATIVE), queries.map { it.kind })
        assertTrue(queries[1].query.contains("aspirin"))
        assertNull(queries[0].documentIds)
        assertNull(queries[1].documentIds)
    }

    @Test
    fun `a new query of such a session keeps the earlier ones, and its documents count for it alone`() {
        val log = SessionQueryLog.recorded(
            session, listOf("earlier", "found"), run(SearchQueryRecord.Kind.ALTERNATIVE, "q2", listOf("found"))
        )

        assertEquals(listOf("q", "q2"), log.map { it.query })
        assertEquals(listOf("earlier"), log[0].documentIds)
        assertEquals(listOf("found"), log[1].documentIds)
    }

    @Test
    fun `a new session's first search is its only query`() {
        val first = SearchQueryRecord(SearchQueryRecord.Kind.INITIAL, SearchProvider.EUROPE_PMC, "eq", documentIds = listOf("found"))

        val log = SessionQueryLog.recorded(session, listOf("found"), first)

        assertEquals(listOf(first), log)
    }

    @Test
    fun `a logged session reads its log`() {
        val logged = session.copy(
            searchQueriesJson = SearchQueryLog.encode(listOf(run(SearchQueryRecord.Kind.INITIAL, "q", listOf("a"))))
        )

        val log = SessionQueryLog.recorded(logged, listOf("a", "b"), run(SearchQueryRecord.Kind.INITIAL, "q", listOf("b")))

        assertEquals(listOf("a", "b"), log.single().documentIds)
    }
}
