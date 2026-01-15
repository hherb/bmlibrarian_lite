package com.bmlibrarian.factchecker.data.remote.pubmed

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Query

/**
 * Retrofit interface for NCBI E-utilities PubMed API.
 *
 * Base URL: https://eutils.ncbi.nlm.nih.gov/entrez/eutils/
 *
 * Rate limits:
 * - Without API key: 3 requests/second
 * - With API key: 10 requests/second
 */
interface PubMedApi {

    /**
     * Search PubMed for articles matching a query.
     *
     * @param db Database name (always "pubmed")
     * @param term Search query string
     * @param retMode Return mode (always "json" for search)
     * @param retMax Maximum number of results to return
     * @param retStart Starting position for pagination
     * @param useHistory Whether to use web history for large result sets
     * @param apiKey Optional NCBI API key (increases rate limit)
     * @param email Contact email (recommended by NCBI)
     * @return ESearch response with PMIDs
     */
    @GET("esearch.fcgi")
    suspend fun search(
        @Query("db") db: String = "pubmed",
        @Query("term") term: String,
        @Query("retmode") retMode: String = "json",
        @Query("retmax") retMax: Int = DEFAULT_BATCH_SIZE,
        @Query("retstart") retStart: Int = 0,
        @Query("usehistory") useHistory: String = "y",
        @Query("api_key") apiKey: String? = null,
        @Query("email") email: String? = null
    ): Response<ESearchResponse>

    /**
     * Fetch article details by PMIDs.
     *
     * Returns XML format which must be parsed manually.
     *
     * @param db Database name (always "pubmed")
     * @param ids Comma-separated list of PMIDs
     * @param retMode Return mode (always "xml" for fetch)
     * @param retType Return type ("abstract" includes all metadata)
     * @param apiKey Optional NCBI API key
     * @param email Contact email
     * @return XML string containing article data
     */
    @GET("efetch.fcgi")
    suspend fun fetch(
        @Query("db") db: String = "pubmed",
        @Query("id") ids: String,
        @Query("retmode") retMode: String = "xml",
        @Query("rettype") retType: String = "abstract",
        @Query("api_key") apiKey: String? = null,
        @Query("email") email: String? = null
    ): Response<String>

    companion object {
        /** Default number of results per batch. */
        const val DEFAULT_BATCH_SIZE = 20

        /** Maximum allowed offset (PubMed limitation). */
        const val MAX_OFFSET = 9999

        /** Rate limit delay without API key (milliseconds). */
        const val RATE_LIMIT_DELAY_MS = 334L

        /** Rate limit delay with API key (milliseconds). */
        const val RATE_LIMIT_DELAY_WITH_KEY_MS = 100L
    }
}
