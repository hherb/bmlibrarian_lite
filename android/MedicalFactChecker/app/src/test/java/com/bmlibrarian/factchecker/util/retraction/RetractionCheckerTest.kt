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

import com.bmlibrarian.factchecker.data.remote.transparency.TransparencyRetryPolicy
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import kotlinx.coroutines.test.runTest
import org.bmlib.ffi.RetractionIndex
import org.bmlib.ffi.RetractionStatus
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

/** The checker and the stored check's rules (`RetractionCheckerTests.swift`). */
class RetractionCheckerTest {
    private lateinit var stub: StubServer

    @Before
    fun setUp() {
        BmlibFfi.assumeAvailable()
        stub = StubServer()
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody(""))
    }

    @After
    fun tearDown() {
        if (::stub.isInitialized) stub.close()
    }

    private fun checker(index: RetractionIndex?): RetractionChecker {
        val lookup = RetractionCrossrefLookup(
            "t@example.org", stub.client(), TransparencyRetryPolicy(initialDelayMs = 0, maxDelayMs = 0), minimumRequestIntervalMs = 0
        )
        return RetractionChecker(index, lookup::results)
    }

    private suspend fun check(paper: RetractionPaper, index: RetractionIndex?): PaperRetractionCheck =
        checker(index).check(listOf(paper), RetractionFixture.nowMs).getValue(paper)

    // ---- The checker

    @Test
    fun `no identifier is unchecked and counted`() = runTest {
        val paper = RetractionPaper(null, null, emptyList())
        val out = checker(RetractionFixture.index()).check(listOf(paper), RetractionFixture.nowMs)
        assertEquals("a paper with no identifier still gets a check", 1, out.size)
        assertEquals("unchecked", out[paper]?.status)
        assertFalse(out.getValue(paper).isClear)
        assertTrue("Crossref is not asked without a DOI", stub.requestedUrls.isEmpty())
    }

    @Test
    fun `no index means the export was not consulted`() = runTest {
        val result = check(RetractionPaper("10.1000/x", null, emptyList()), index = null)
        assertTrue(result.unanswered.toString(), "retraction_watch_export" in result.unanswered)
        assertNotEquals("clear", result.status)
        assertNull(result.exportDataAsOf)
    }

    @Test
    fun `retracted by the index alone`() = runTest {
        // A padded PMID is canonicalised, as the desktop's canonical_pmid does
        val result = check(RetractionPaper(null, "0111", emptyList()), RetractionFixture.index())
        assertEquals("retracted", result.status)
        assertEquals(RetractionStatus.RETRACTED, result.retractionStatus)
        assertEquals("retraction_watch_export", result.deciding?.source)
        assertFalse(result.isDecidedByLabel)
        assertEquals("retraction", result.deciding?.kind)
        assertEquals("1", result.deciding?.recordId)
        assertEquals("10.1000/notice1", result.deciding?.noticeDoi)
        assertEquals(RetractionFixture.TODAY, result.exportDataAsOf)
        assertNull(result.crossrefFailure)
        assertTrue(stub.requestedUrls.isEmpty())
    }

    @Test
    fun `the label alone retracts`() = runTest {
        val result = check(RetractionPaper(null, null, listOf("Retracted Publication")), index = null)
        assertEquals("retracted", result.status)
        assertEquals("pubmed_label", result.deciding?.source)
        assertTrue(result.isDecidedByLabel)
    }

    /** The reason Crossref is asked at all: a retraction newer than the export. */
    @Test
    fun `retracted by Crossref alone`() = runTest {
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody("""
            {"DOI": "10.1000/newer", "updated-by": [{"DOI": "10.1000/newnotice", "type": "retraction",
             "label": "retraction", "source": "retraction-watch", "updated": {"date-parts": [[2026, 10, 1]]},
             "record-id": 77}]}
        """.trimIndent()))
        val result = check(RetractionPaper("10.1000/newer", null, emptyList()), RetractionFixture.index())
        assertEquals("retracted", result.status)
        assertEquals("crossref_retraction_watch", result.deciding?.source)
        assertEquals("10.1000/newnotice", result.deciding?.noticeDoi)
        assertEquals("2026-10-01", result.deciding?.date)
        assertTrue(result.unanswered.isEmpty())
    }

    @Test
    fun `papers sharing a DOI are asked once`() = runTest {
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody("""{"DOI": "10.1000/shared"}"""))
        val first = RetractionPaper("10.1000/Shared", "5", emptyList())
        val second = RetractionPaper("https://doi.org/10.1000/shared", null, emptyList())
        val out = checker(RetractionFixture.index()).check(listOf(first, second), RetractionFixture.nowMs)
        assertEquals(2, out.size)
        assertEquals(1, stub.requestedUrls.size)
        assertEquals(1, stub.requestedUrls.first().split("10.1000/shared").size - 1)
        assertEquals("clear", out[first]?.status)
        assertEquals("clear", out[second]?.status)
    }

    /** Control: a served Crossref answer and a consulted, empty index clear a paper. */
    @Test
    fun `a served Crossref answer and a consulted empty index are clear`() = runTest {
        stub.stubbed = StubServer.answer(200, StubServer.crossrefBody("""{"DOI": "10.1000/unknown"}"""))
        val result = check(RetractionPaper("10.1000/unknown", null, emptyList()), RetractionFixture.index())
        assertEquals("clear", result.status)
        assertTrue(result.isClear)
        assertTrue(result.unanswered.isEmpty())
        assertEquals(RetractionFixture.TODAY, result.exportDataAsOf)
        assertNull(result.crossrefFailure)
    }

    @Test
    fun `a Crossref failure is stored in the app's own words`() = runTest {
        stub.stubbed = StubServer.answer(200, "not json")
        val result = check(RetractionPaper("10.1000/unknown", null, emptyList()), RetractionFixture.index())
        assertEquals(listOf("crossref"), result.unanswered)
        assertNotEquals("clear", result.status)
        assertEquals(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE).describe(), result.crossrefFailure)
    }

    /** An unsendable DOI (a comma) asks nothing and leaves Crossref not asked (#649). */
    @Test
    fun `an unsendable DOI asks Crossref nothing`() = runTest {
        val result = check(RetractionPaper("10.1000/a,b", null, emptyList()), RetractionFixture.index())
        assertTrue(stub.requestedUrls.isEmpty())
        assertTrue(result.leftUnanswered(org.bmlib.ffi.RetractionLookup.CROSSREF))
        assertNull(result.crossrefFailure)
        assertNotEquals("clear", result.status)
    }

    @Test
    fun `concern by the index`() = runTest {
        assertTrue(check(RetractionPaper("10.1000/concerned", null, emptyList()), RetractionFixture.index()).isConcern)
    }

    // ---- The stored form

    @Test
    fun `a stored check round-trips through JSON`() = runTest {
        val result = check(RetractionPaper(null, "111", emptyList()), RetractionFixture.index())
        assertEquals(result, PaperRetractionCheck.decode(PaperRetractionCheck.encode(result)))
    }

    @Test
    fun `a failed check is unchecked with both lookups unanswered`() {
        val failed = PaperRetractionCheck.failed(RetractionFixture.nowMs)
        assertEquals("unchecked", failed.status)
        assertNull(failed.deciding)
        assertEquals(listOf("retraction_watch_export", "crossref"), failed.unanswered)
        assertNull(failed.crossrefFailure)
        assertNull(failed.exportDataAsOf)
        assertEquals(RetractionFixture.nowMs, failed.checkedAtMs)
    }

    @Test
    fun `an unknown status name is unchecked`() {
        val odd = stored("not-a-status")
        assertEquals(RetractionStatus.UNCHECKED, odd.retractionStatus)
        assertFalse(odd.isClear)
    }

    // ---- Reuse (retraction_checks.py check)

    private fun stored(status: String, unanswered: List<String> = emptyList(), daysOld: Double = 1.0) =
        PaperRetractionCheck(status, null, unanswered, RetractionFixture.nowMs - (daysOld * RetractionConstants.MS_PER_DAY).toLong())

    @Test
    fun `a young answered check is reused`() {
        assertTrue(stored("clear").isReusable(RetractionFixture.nowMs, emptyList()))
        assertTrue(stored("clear", daysOld = 7.0).isReusable(RetractionFixture.nowMs, emptyList()))
    }

    @Test
    fun `an old check is asked again`() {
        assertFalse(stored("clear", daysOld = 7.01).isReusable(RetractionFixture.nowMs, emptyList()))
    }

    @Test
    fun `a check with a lookup unanswered is asked again`() {
        assertFalse(stored("concern", listOf("crossref")).isReusable(RetractionFixture.nowMs, emptyList()))
    }

    @Test
    fun `an unknown status is asked again`() {
        assertFalse(stored("not-a-status").isReusable(RetractionFixture.nowMs, emptyList()))
    }

    @Test
    fun `a fresh label is never hidden behind a stored clear`() {
        val types = listOf("Retracted Publication")
        assertFalse(stored("clear").isReusable(RetractionFixture.nowMs, types))
        assertFalse(stored("concern").isReusable(RetractionFixture.nowMs, types))
        assertTrue(stored("retracted").isReusable(RetractionFixture.nowMs, types))
    }

    // ---- An outage never erases an answer (retraction_checks.py _keeps)

    @Test
    fun `a stored answer stands against an outage`() {
        val fresh = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertTrue(stored("clear").standsAgainst(fresh))
        assertTrue(stored("retracted").standsAgainst(fresh))
    }

    /** Control: a fresh retraction or concern is news even while a lookup is down. */
    @Test
    fun `a fresh warning replaces a stored clear during an outage`() {
        assertFalse(stored("clear").standsAgainst(stored("retracted", listOf("crossref"), daysOld = 0.0)))
        assertFalse(stored("clear").standsAgainst(stored("concern", listOf("crossref"), daysOld = 0.0)))
        assertTrue("a concern does not outrank a retraction", stored("retracted").standsAgainst(stored("concern", listOf("crossref"), daysOld = 0.0)))
    }

    @Test
    fun `a fresh answer with no new outage replaces the stored one`() {
        assertFalse(stored("retracted").standsAgainst(stored("clear", daysOld = 0.0)))
        assertFalse(stored("concern", listOf("crossref")).standsAgainst(stored("unchecked", listOf("crossref"), daysOld = 0.0)))
    }

    @Test
    fun `a stored clear is not shown during an outage, a stored warning is`() {
        val fresh = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertEquals(fresh, stored("clear").shown(fresh))
        for (status in listOf("retracted", "concern")) assertEquals(status, stored(status), stored(status).shown(fresh))
        val retraction = stored("retracted", listOf("crossref"), daysOld = 0.0)
        assertEquals(retraction, stored("clear").shown(retraction))
    }

    // ---- What is stored (Swift's Document.takeRetractionCheck)

    @Test
    fun `with no row the fresh check is stored and used`() {
        val fresh = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(fresh, fresh), PaperRetractionCheck.take(null, fresh, typesRecorded = true))
    }

    @Test
    fun `an unreadable row is overwritten only by a fully answered check or a retraction`() {
        val outage = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(null, outage), PaperRetractionCheck.take("{", outage, typesRecorded = true))
        val concern = stored("concern", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(null, concern), PaperRetractionCheck.take("{", concern, typesRecorded = true))
        val answered = stored("clear", daysOld = 0.0)
        assertEquals(TakenCheck(answered, answered), PaperRetractionCheck.take("{", answered, typesRecorded = true))
        // nothing warns more than a retraction, whatever was down (#669)
        val retraction = stored("retracted", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(retraction, retraction), PaperRetractionCheck.take("{", retraction, typesRecorded = true))
    }

    @Test
    fun `a label retraction stands when this document recorded no types`() {
        val label = PaperRetractionCheck("retracted", StoredRetractionEvidence("pubmed_label", "retraction"), checkedAtMs = 1)
        val clear = stored("clear", daysOld = 0.0)
        assertEquals(TakenCheck(null, label), PaperRetractionCheck.take(PaperRetractionCheck.encode(label), clear, typesRecorded = false))
        // control: a document that recorded its types and lacks the label is cleared
        assertEquals(TakenCheck(clear, clear), PaperRetractionCheck.take(PaperRetractionCheck.encode(label), clear, typesRecorded = true))
    }

    @Test
    fun `a stored retraction outlives an outage, kept and shown`() {
        val old = stored("retracted")
        val outage = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(null, old), PaperRetractionCheck.take(PaperRetractionCheck.encode(old), outage, typesRecorded = true))
    }

    /** A stored clear rests on a lookup now down: kept for later, but not knowledge today. */
    @Test
    fun `a stored clear outlives an outage, kept but shown unchecked`() {
        val outage = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        assertEquals(TakenCheck(null, outage), PaperRetractionCheck.take(PaperRetractionCheck.encode(stored("clear")), outage, typesRecorded = true))
    }

    /** The desktop's `_decode`: a name this build does not know makes the row unreadable, so protected. */
    @Test
    fun `a stored row with an unknown status or lookup is unreadable, and an outage never overwrites it`() {
        val outage = stored("unchecked", listOf("crossref"), daysOld = 0.0)
        for (row in listOf(stored("retracted_v2"), stored("concern", listOf("a_new_source")))) {
            val text = PaperRetractionCheck.encode(row)
            assertNull(text, PaperRetractionCheck.decode(text))
            assertEquals(text, TakenCheck(null, outage), PaperRetractionCheck.take(text, outage, typesRecorded = true))
        }
        // control: a known row decodes
        assertEquals(stored("concern", listOf("crossref")), PaperRetractionCheck.decode(PaperRetractionCheck.encode(stored("concern", listOf("crossref")))))
    }

    /** Only a label retraction waits for recorded types; one Retraction Watch decided is cleared by a full answer. */
    @Test
    fun `a stored retraction not decided by the label is replaced by a full answer, types recorded or not`() {
        val notice = PaperRetractionCheck("retracted", StoredRetractionEvidence("retraction_watch_export", "retraction"), checkedAtMs = 1)
        val clear = stored("clear", daysOld = 0.0)
        assertEquals(TakenCheck(clear, clear), PaperRetractionCheck.take(PaperRetractionCheck.encode(notice), clear, typesRecorded = false))
    }

    @Test
    fun `a label retraction reached without types is never downgraded to a concern, but a fresh retraction replaces it`() {
        val label = PaperRetractionCheck("retracted", StoredRetractionEvidence("pubmed_label", "retraction"), checkedAtMs = 1)
        val concern = stored("concern", daysOld = 0.0)
        assertEquals(TakenCheck(null, label), PaperRetractionCheck.take(PaperRetractionCheck.encode(label), concern, typesRecorded = false))
        val retraction = PaperRetractionCheck("retracted", StoredRetractionEvidence("retraction_watch_export", "retraction"), checkedAtMs = 2)
        assertEquals(TakenCheck(retraction, retraction), PaperRetractionCheck.take(PaperRetractionCheck.encode(label), retraction, typesRecorded = false))
    }

    // ---- A failed check (the desktop's _label_check)

    @Test
    fun `a failed check still retracts by the record's own label, and is otherwise unchecked`() {
        val labelled = PaperRetractionCheck.failedFor(RetractionPaper("10.1000/x", null, listOf("Retracted Publication")), RetractionFixture.nowMs)
        assertTrue(labelled.isRetracted)
        assertTrue(labelled.isDecidedByLabel)
        assertEquals(RetractionFixture.nowMs, labelled.checkedAtMs)
        // control: without the label a failed check is unchecked, never clear
        assertEquals(
            PaperRetractionCheck.failed(RetractionFixture.nowMs),
            PaperRetractionCheck.failedFor(RetractionPaper("10.1000/x", null, listOf("Journal Article")), RetractionFixture.nowMs)
        )
    }

    /** An unsendable DOI is not sent to Crossref, but is still its key: the index is searched and the row stored by it. */
    @Test
    fun `an unsendable DOI is still looked up in the index and keyed by its DOI`() = runTest {
        val index = RetractionFixture.index(RetractionFixture.rows + "4,2/6/2010 0:00,10.1000/notice4,\"10.1000/a,b\",,Retraction")
        val paper = RetractionPaper("10.1000/a,b", null, emptyList())
        assertTrue(check(paper, index).isRetracted)
        assertEquals("doi:10.1000/a,b", paper.paperKey)
    }

    // ---- The snapshot (#647: per entry)

    @Test
    fun `an unreadable snapshot entry is kept as it was and the rest are read`() {
        val text = """{"a":{"status":"clear","checkedAtMs":1},"b":{"status":5}}"""
        assertEquals(setOf("a"), RetractionSnapshot.read(text).keys)
        val merged = RetractionSnapshot.merged(text, mapOf("c" to stored("retracted")))
        assertTrue(merged, merged.contains(""""b":{"status":5}"""))
        assertEquals(setOf("a", "c"), RetractionSnapshot.read(merged).keys)
        assertTrue(RetractionSnapshot.read(null).isEmpty())
    }
}
