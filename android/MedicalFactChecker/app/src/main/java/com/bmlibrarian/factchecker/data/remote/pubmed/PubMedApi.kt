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

import retrofit2.Response
import retrofit2.http.Field
import retrofit2.http.FormUrlEncoded
import retrofit2.http.POST

/**
 * Retrofit interface for NCBI E-utilities PubMed API.
 *
 * Base URL: https://eutils.ncbi.nlm.nih.gov/entrez/eutils/
 *
 * Every request is a form-encoded POST with its parameters in the body, so the
 * API key never appears in a URL (#243, the Android half of #196). A query
 * string is part of the URL, and a URL is what gets printed: OkHttp's
 * `HttpLoggingInterceptor` writes each request line, URL included, to logcat in
 * debug builds. NCBI reads `api_key` from a POST body on `esearch` and `efetch`
 * exactly as from a query string. Build the interface with [createPubMedApi],
 * whose client refuses redirects: a 307 or 308 would re-send the body, key
 * included, to whatever host it names.
 *
 * [apiKey][search] and [email][search] have no defaults, so every call states
 * what it sends. [PubMedService] reads both from its credential source.
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
     * @param apiKey Optional NCBI API key (increases rate limit); a null field
     *   is omitted from the body
     * @param email Contact email (recommended by NCBI), or null to send none
     * @return ESearch response with PMIDs
     */
    @FormUrlEncoded
    @POST("esearch.fcgi")
    suspend fun search(
        @Field("db") db: String = "pubmed",
        @Field("term") term: String,
        @Field("retmode") retMode: String = "json",
        @Field("retmax") retMax: Int = DEFAULT_BATCH_SIZE,
        @Field("retstart") retStart: Int = 0,
        @Field("usehistory") useHistory: String = "y",
        @Field("api_key") apiKey: String?,
        @Field("email") email: String?
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
     * @param apiKey Optional NCBI API key; a null field is omitted from the body
     * @param email Contact email, or null to send none
     * @return XML string containing article data
     */
    @FormUrlEncoded
    @POST("efetch.fcgi")
    suspend fun fetch(
        @Field("db") db: String = "pubmed",
        @Field("id") ids: String,
        @Field("retmode") retMode: String = "xml",
        @Field("rettype") retType: String = "abstract",
        @Field("api_key") apiKey: String?,
        @Field("email") email: String?
    ): Response<String>

    companion object {
        /** Default number of results per batch. */
        const val DEFAULT_BATCH_SIZE = 20

        /** Rate limit delay without API key (milliseconds). */
        const val RATE_LIMIT_DELAY_MS = 334L

        /** Rate limit delay with API key (milliseconds). */
        const val RATE_LIMIT_DELAY_WITH_KEY_MS = 100L
    }
}
