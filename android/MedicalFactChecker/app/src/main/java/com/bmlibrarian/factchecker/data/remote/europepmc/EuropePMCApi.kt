package com.bmlibrarian.factchecker.data.remote.europepmc

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit interface for Europe PMC REST API.
 *
 * Base URL: https://www.ebi.ac.uk/europepmc/webservices/rest/
 *
 * Europe PMC provides access to life sciences literature including:
 * - PubMed/MEDLINE articles
 * - PMC full-text articles
 * - Preprints (bioRxiv, medRxiv, etc.)
 */
interface EuropePMCApi {

    /**
     * Search Europe PMC for articles.
     *
     * Note: No sort parameter is used - Europe PMC defaults to relevance sorting.
     * The "RELEVANCE desc" parameter was deprecated by Europe PMC API in late 2025.
     *
     * @param query Search query (supports Europe PMC query syntax)
     * @param resultType Result detail level ("lite", "core", or "idlist")
     * @param pageSize Number of results per page
     * @param cursorMark Cursor for pagination (use "*" for first page)
     * @param format Response format (always "json")
     * @return Search response with articles and pagination cursor
     */
    @GET("search")
    suspend fun search(
        @Query("query") query: String,
        @Query("resultType") resultType: String = DEFAULT_RESULT_TYPE,
        @Query("pageSize") pageSize: Int = DEFAULT_PAGE_SIZE,
        @Query("cursorMark") cursorMark: String = INITIAL_CURSOR,
        @Query("format") format: String = "json"
    ): Response<EuropePMCSearchResponse>

    /**
     * Get full text XML for a PMC article.
     *
     * @param pmcId PubMed Central ID (with or without "PMC" prefix)
     * @return Full text XML as string
     */
    @GET("{pmcId}/fullTextXML")
    suspend fun getFullTextXml(
        @Path("pmcId") pmcId: String
    ): Response<String>

    /**
     * Get article metadata by ID.
     *
     * @param source Source database (MED, PMC, PPR)
     * @param id Article ID (PMID for MED, PMCID for PMC)
     * @param format Response format
     * @return Single article metadata
     */
    @GET("{source}/{id}")
    suspend fun getArticle(
        @Path("source") source: String,
        @Path("id") id: String,
        @Query("format") format: String = "json"
    ): Response<EuropePMCSearchResponse>

    companion object {
        /** Default result type - includes full metadata. */
        const val DEFAULT_RESULT_TYPE = "core"

        /** Default page size for search results. */
        const val DEFAULT_PAGE_SIZE = 20

        /** Initial cursor value for first page. */
        const val INITIAL_CURSOR = "*"

        // Note: No sort constant needed - Europe PMC defaults to relevance sorting.
        // The "RELEVANCE desc" parameter was deprecated by Europe PMC API in late 2025.

        /** Sort by date (newest first) - still supported via P_PDATE_D. */
        const val SORT_DATE_DESC = "P_PDATE_D desc"

        /** Source: PubMed/MEDLINE. */
        const val SOURCE_MED = "MED"

        /** Source: PubMed Central. */
        const val SOURCE_PMC = "PMC"

        /** Source: Preprints. */
        const val SOURCE_PPR = "PPR"
    }
}
