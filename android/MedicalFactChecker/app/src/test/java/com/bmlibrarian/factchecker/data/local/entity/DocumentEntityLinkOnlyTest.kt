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

package com.bmlibrarian.factchecker.data.local.entity

import com.bmlibrarian.factchecker.data.remote.fulltext.FullTextService.FullTextResult
import com.bmlibrarian.factchecker.data.remote.fulltext.NotEstablishedSource
import com.bmlibrarian.factchecker.data.remote.fulltext.PdfDownload
import com.bmlibrarian.factchecker.data.remote.fulltext.recordingFullTextFetch
import com.bmlibrarian.factchecker.domain.model.FullTextLinkKind
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertSame
import org.junit.Test
import java.util.Date

/**
 * A record whose last fetch left only a link reads as link-only, not as never
 * fetched, and says which link it holds (#471).
 *
 * Driven through [recordingFullTextFetch], the one writer, so the predicate is
 * tested against what a fetch actually stores rather than a hand-built row.
 */
class DocumentEntityLinkOnlyTest {

    private val fresh = DocumentEntity(id = "d", sessionId = "s", title = "t", doi = "10.1/x")

    private suspend fun recorded(result: FullTextResult, downloaded: String? = null) =
        fresh.recordingFullTextFetch(result) {
            downloaded?.let(PdfDownload::Saved) ?: PdfDownload.Failed(RequestFailure(RequestFailureKind.HTTP_STATUS, 404))
        }.document

    @Test
    fun `a record never fetched is not link-only`() {
        assertFalse(fresh.isLinkOnly)
        assertNull(fresh.linkOnlyKind)
    }

    @Test
    fun `a DOI fallback is a link to the publisher's page`() = runTest {
        val doc = recorded(FullTextResult.DoiUrl("https://doi.org/10.1/x"))

        assertSame(FullTextLinkKind.PUBLISHER_PAGE, doc.linkOnlyKind)
    }

    /** Europe PMC's PDF, when its download failed: a copy found, not held. */
    @Test
    fun `a Europe PMC PDF that could not be downloaded is an undownloaded PDF`() = runTest {
        val answer = FullTextResult.EuropePmcPdf("https://europepmc.org/a.pdf")

        assertSame(FullTextLinkKind.UNDOWNLOADED_PDF, recorded(answer).linkOnlyKind)
    }

    /** An Unpaywall PDF that could not be downloaded is refused for the DOI link (#478). */
    @Test
    fun `an Unpaywall PDF that could not be downloaded is the publisher's page`() = runTest {
        val answer = FullTextResult.UnpaywallPdf("https://repo.example.org/a.pdf", doi = "10.1/x")

        assertSame(FullTextLinkKind.PUBLISHER_PAGE, recorded(answer).linkOnlyKind)
    }

    /** The controls: text in hand, a settled absence, and a fetch that settled nothing. */
    @Test
    fun `text in hand, an absence and an unsettled fetch are not link-only`() = runTest {
        val notLinkOnly = listOf(
            recorded(FullTextResult.UnpaywallPdf("https://repo.example.org/a.pdf", doi = "10.1/x"), downloaded = "/cache/a.pdf"),
            recorded(FullTextResult.EuropePmcXml(xml = "<a/>", markdown = "m", html = "<p>h</p>")),
            recorded(FullTextResult.PmcOpenDataXml(xml = "<a/>", markdown = "m", html = "<p>h</p>")),
            recorded(FullTextResult.Unavailable("No full text source available")),
            recorded(FullTextResult.NotEstablished(
                RequestFailure(RequestFailureKind.TIMEOUT), NotEstablishedSource.EUROPE_PMC
            )),
        )
        for (doc in notLinkOnly) {
            assertFalse("$doc", doc.isLinkOnly)
            assertNull("$doc", doc.linkOnlyKind)
        }
    }

    /** Refresh clears the date with the content, so the record is offered a fetch again. */
    @Test
    fun `a record whose fetch date was cleared is not link-only`() = runTest {
        val cleared = recorded(FullTextResult.DoiUrl("https://doi.org/10.1/x")).copy(fullTextFetchedAt = null)

        assertNull(cleared.linkOnlyKind)
    }

    /** A source this build does not know claims no more than "not retrieved". */
    @Test
    fun `an unknown source reads as the publisher's page`() {
        val doc = fresh.copy(fullTextSource = "a-newer-source", fullTextFetchedAt = Date())

        assertSame(FullTextLinkKind.PUBLISHER_PAGE, doc.linkOnlyKind)
        assertSame(FullTextLinkKind.PUBLISHER_PAGE, FullTextLinkKind.forStoredSource(null))
        assertSame(FullTextLinkKind.UNDOWNLOADED_PDF, FullTextLinkKind.forStoredSource(Constants.FULLTEXT_SOURCE_EUROPE_PMC))
    }

    /**
     * The sentences, pinned whole: neither claims access the chain never
     * established, as "Full text is available on the publisher's website" did.
     */
    @Test
    fun `each kind says what the link is and nothing more`() {
        assertEquals(
            "This article's full text was not retrieved; the publisher's page may offer it.",
            FullTextLinkKind.PUBLISHER_PAGE.statement
        )
        assertEquals(
            "A PDF of this article was found but could not be downloaded.",
            FullTextLinkKind.UNDOWNLOADED_PDF.statement
        )
    }
}
