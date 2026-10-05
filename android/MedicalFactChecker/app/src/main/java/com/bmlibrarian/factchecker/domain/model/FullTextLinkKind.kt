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

import com.bmlibrarian.factchecker.util.Constants

/**
 * What a full-text fetch that ended on a link, with no text in hand, left the
 * reader with (#471).
 *
 * Two different facts, and the reader is told which one:
 *
 * - [PUBLISHER_PAGE]: the chain fell back to the DOI link. A DOI resolves to
 *   the publisher's landing page, which is often paywalled, so the link says
 *   nothing about access. "Full text is available on the publisher's website"
 *   claimed something the chain never established.
 * - [UNDOWNLOADED_PDF]: Europe PMC or Unpaywall named a PDF, and the download
 *   failed. A copy was found; we do not hold it.
 *
 * @property title The heading for the full-text screen
 * @property statement The sentence the screen and the cards show
 */
enum class FullTextLinkKind(val title: String, val statement: String) {
    /** The chain ended on the DOI link to the publisher's page. */
    PUBLISHER_PAGE(
        title = "Publisher's Page",
        statement = "This article's full text was not retrieved; the publisher's page may offer it."
    ),

    /** A PDF was found and could not be downloaded. */
    UNDOWNLOADED_PDF(
        title = "PDF Not Downloaded",
        statement = "A PDF of this article was found but could not be downloaded."
    );

    companion object {
        /**
         * The kind of link a stored record ended on, read from its full-text
         * source.
         *
         * Only a PDF tier stores Europe PMC, Unpaywall or OpenAlex without
         * text: Europe PMC's XML always arrives with its markdown. Every other source,
         * including one a newer build wrote, reads as the publisher's page,
         * whose sentence claims nothing beyond "not retrieved".
         *
         * @param fullTextSource The stored `full_text_source`
         * @return The kind of link the record holds
         */
        fun forStoredSource(fullTextSource: String?): FullTextLinkKind = when (fullTextSource) {
            Constants.FULLTEXT_SOURCE_EUROPE_PMC,
            Constants.FULLTEXT_SOURCE_UNPAYWALL,
            Constants.FULLTEXT_SOURCE_OPENALEX -> UNDOWNLOADED_PDF
            else -> PUBLISHER_PAGE
        }
    }
}
