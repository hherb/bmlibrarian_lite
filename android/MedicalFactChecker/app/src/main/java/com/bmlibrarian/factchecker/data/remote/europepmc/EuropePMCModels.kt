/*
 * BMLibrarian Lite - Biomedical Literature Research Tool
 * Copyright (C) 2024-2025 Dr Horst Herb
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

package com.bmlibrarian.factchecker.data.remote.europepmc

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable

/**
 * Europe PMC search response.
 */
@Serializable
data class EuropePMCSearchResponse(
    /** Total number of matching articles. */
    val hitCount: Int? = null,
    /** Cursor for next page of results. */
    val nextCursorMark: String? = null,
    /** List of results. */
    val resultList: EuropePMCResultList? = null
)

/**
 * Container for Europe PMC results.
 */
@Serializable
data class EuropePMCResultList(
    /** List of articles. */
    val result: List<EuropePMCArticle>? = null
)

/**
 * Article from Europe PMC API.
 */
@Serializable
data class EuropePMCArticle(
    /** Internal Europe PMC ID. */
    val id: String? = null,
    /** Source database (MED, PMC, PPR, etc.). */
    val source: String? = null,
    /** PubMed ID. */
    val pmid: String? = null,
    /** PubMed Central ID (with PMC prefix). */
    val pmcid: String? = null,
    /** Digital Object Identifier. */
    val doi: String? = null,
    /** Article title. */
    val title: String? = null,
    /** Author string (comma-separated). */
    val authorString: String? = null,
    /** List of individual authors. */
    val authorList: AuthorList? = null,
    /** Journal title. */
    val journalTitle: String? = null,
    /** Journal ISSN. */
    val journalIssn: String? = null,
    /** Publication date string. */
    val pubDate: String? = null,
    /** Publication year. */
    val pubYear: String? = null,
    /** Abstract text. */
    val abstractText: String? = null,
    /** Affiliation string. */
    val affiliation: String? = null,
    /** Whether article is open access. */
    val isOpenAccess: String? = null,
    /** Open access status (e.g., "Open Access"). */
    @SerialName("openAccessStatus")
    val openAccessStatus: String? = null,
    /** Whether full text is available in Europe PMC. */
    val inEPMC: String? = null,
    /** Whether full text is in PMC. */
    val inPMC: String? = null,
    /** Citation count. */
    val citedByCount: Int? = null,
    /** First publication date. */
    val firstPublicationDate: String? = null,
    /** Language of article. */
    val language: String? = null,
    /** Publication type. */
    val pubTypeList: PubTypeList? = null,
    /** MeSH heading list. */
    val meshHeadingList: MeshHeadingList? = null,
    /** Keyword list. */
    val keywordList: KeywordList? = null,
    /** Whether PDF is available. */
    val hasPDF: String? = null,
    /** Full-text URL list with free PDF render URLs. */
    val fullTextUrlList: FullTextUrlList? = null
)

/**
 * Container for author list.
 */
@Serializable
data class AuthorList(
    val author: List<Author>? = null
)

/**
 * Individual author.
 */
@Serializable
data class Author(
    val fullName: String? = null,
    val firstName: String? = null,
    val lastName: String? = null,
    val initials: String? = null,
    val affiliation: String? = null
)

/**
 * Container for publication types.
 */
@Serializable
data class PubTypeList(
    val pubType: List<String>? = null
)

/**
 * Container for MeSH headings.
 */
@Serializable
data class MeshHeadingList(
    val meshHeading: List<MeshHeading>? = null
)

/**
 * MeSH heading entry.
 */
@Serializable
data class MeshHeading(
    val descriptorName: String? = null,
    val majorTopic_YN: String? = null,
    val meshQualifierList: MeshQualifierList? = null
)

/**
 * Container for MeSH qualifiers.
 */
@Serializable
data class MeshQualifierList(
    val meshQualifier: List<MeshQualifier>? = null
)

/**
 * MeSH qualifier entry.
 */
@Serializable
data class MeshQualifier(
    val qualifierName: String? = null,
    val majorTopic_YN: String? = null
)

/**
 * Container for keywords.
 */
@Serializable
data class KeywordList(
    val keyword: List<String>? = null
)

/**
 * Container for full-text URL list from Europe PMC API.
 */
@Serializable
data class FullTextUrlList(
    val fullTextUrl: List<FullTextUrlEntry>? = null
)

/**
 * Individual full-text URL entry from Europe PMC API.
 *
 * Contains document format, availability, and URL for accessing
 * different versions of the article (PDF, HTML, DOI).
 */
@Serializable
data class FullTextUrlEntry(
    /** Document format (e.g., "pdf", "html", "doi"). */
    val documentStyle: String? = null,
    /** Hosting site (e.g., "Europe_PMC", "DOI"). */
    val site: String? = null,
    /** URL to the document. */
    val url: String? = null,
    /** Availability status (e.g., "Free", "Subscription required"). */
    val availability: String? = null
)

/**
 * Search result from Europe PMC service.
 */
data class EuropePMCSearchResult(
    /** List of parsed articles. */
    val articles: List<EuropePMCArticle>,
    /** Total number of results for the query. */
    val totalResults: Int,
    /** Cursor for next page of results (null if no more results). */
    val nextCursor: String?,
    /** Whether there are more results available. */
    val hasMore: Boolean
) {
    companion object {
        /** Empty search result. */
        val EMPTY = EuropePMCSearchResult(
            articles = emptyList(),
            totalResults = 0,
            nextCursor = null,
            hasMore = false
        )
    }
}
