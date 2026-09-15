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

package com.bmlibrarian.factchecker.data.remote.pubmed

import com.bmlibrarian.factchecker.domain.model.RetrievalShortfall
import com.bmlibrarian.factchecker.domain.model.SearchPaging
import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonElement

/**
 * ESearch response from NCBI E-utilities.
 *
 * Contains search results metadata and list of PMIDs.
 */
@Serializable
data class ESearchResponse(
    @SerialName("esearchresult")
    val esearchResult: ESearchResult? = null
)

/**
 * ESearch result data.
 */
@Serializable
data class ESearchResult(
    /** Total number of matching articles. */
    val count: String? = null,
    /** Number of results returned in this response. */
    @SerialName("retmax")
    val retMax: String? = null,
    /** Starting position in results. */
    @SerialName("retstart")
    val retStart: String? = null,
    /** List of PubMed IDs. */
    @SerialName("idlist")
    val idList: List<String>? = null,
    /** Web environment ID for large result sets. */
    @SerialName("webenv")
    val webEnv: String? = null,
    /** Query key for web environment. */
    @SerialName("querykey")
    val queryKey: String? = null,
    /** Query translation information. */
    @SerialName("querytranslation")
    val queryTranslation: String? = null,
    /** Error list if search failed. */
    @SerialName("errorlist")
    val errorList: ESearchErrorList? = null,
    /**
     * The error E-utilities reports inside an HTTP 200 instead of a result (#255).
     *
     * Any value marks a failed search, so it is read as whatever JSON it holds.
     * Its text is never logged or shown: what NCBI writes into a failed answer
     * can repeat the request.
     */
    @SerialName("ERROR")
    val error: JsonElement? = null
) {
    /** The result without [error]'s text, which is shown only as present or absent. */
    override fun toString(): String =
        "ESearchResult(count=$count, retMax=$retMax, retStart=$retStart, idList=$idList, webEnv=$webEnv, " +
            "queryKey=$queryKey, queryTranslation=$queryTranslation, errorList=$errorList, " +
            "error=${if (error == null) "null" else "(not shown)"})"
}

/**
 * Search error list.
 */
@Serializable
data class ESearchErrorList(
    @SerialName("phrasesnotfound")
    val phrasesNotFound: List<String>? = null,
    @SerialName("fieldsnotfound")
    val fieldsNotFound: List<String>? = null
)

/**
 * Parsed article data from PubMed XML.
 *
 * This is a domain object created by parsing the XML response,
 * not a serializable DTO.
 */
data class ParsedArticle(
    /** PubMed ID. */
    val pmid: String,
    /** Digital Object Identifier. */
    val doi: String? = null,
    /** PubMed Central ID. */
    val pmcId: String? = null,
    /** Article title. */
    val title: String,
    /** Abstract text with all sections combined. */
    val abstractText: String? = null,
    /** Structured abstract sections. */
    val abstractSections: List<AbstractSection>? = null,
    /** List of author names (LastName ForeName format). */
    val authors: List<String> = emptyList(),
    /** Journal title. */
    val journal: String? = null,
    /** Publication date string. */
    val publicationDate: String? = null,
    /** Publication year. */
    val publicationYear: Int? = null,
    /** MeSH descriptor terms. */
    val meshTerms: List<String> = emptyList(),
    /** Publication types (e.g., "Randomized Controlled Trial"). */
    val publicationTypes: List<String> = emptyList(),
    /** Keywords. */
    val keywords: List<String> = emptyList()
)

/**
 * Structured abstract section.
 */
data class AbstractSection(
    /** Section label (e.g., "Background", "Methods", "Results"). */
    val label: String?,
    /** Section content. */
    val text: String
)

/**
 * One page of a PubMed search that answered.
 *
 * A search that failed is never one of these: [PubMedService.search] returns a
 * [com.bmlibrarian.factchecker.domain.model.SourceRequestException] instead.
 * What a search that answered still failed to retrieve is in [shortfalls].
 */
data class PubMedSearchResult(
    /** List of parsed articles. */
    val articles: List<ParsedArticle>,
    /** Total number of results for the query. */
    val totalResults: Int,
    /** The next page's offset: past the PMIDs this page listed, and past those it should have listed but did not. */
    val nextOffset: Int,
    /** What this page failed to retrieve: PMIDs left unlisted or unfetched, and unreadable articles. */
    val shortfalls: List<RetrievalShortfall>
) {
    /** Whether PubMed has a next page to list. */
    val hasMore: Boolean
        get() = SearchPaging.pubMedHasNextPage(nextOffset, totalResults)
}
