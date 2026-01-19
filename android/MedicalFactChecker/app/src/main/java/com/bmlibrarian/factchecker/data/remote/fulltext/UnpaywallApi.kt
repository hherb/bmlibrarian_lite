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

package com.bmlibrarian.factchecker.data.remote.fulltext

import retrofit2.Response
import retrofit2.http.GET
import retrofit2.http.Path
import retrofit2.http.Query

/**
 * Retrofit interface for the Unpaywall API.
 *
 * Unpaywall provides free access to legal open access versions of research papers.
 * Requires an email address for identification (API terms of service).
 *
 * @see <a href="https://unpaywall.org/products/api">Unpaywall API Documentation</a>
 */
interface UnpaywallApi {

    /**
     * Look up open access information for a DOI.
     *
     * @param doi Digital Object Identifier (without URL prefix)
     * @param email Email address for API identification
     * @return Unpaywall work information
     */
    @GET("{doi}")
    suspend fun getWorkByDoi(
        @Path("doi", encoded = true) doi: String,
        @Query("email") email: String
    ): Response<UnpaywallResponse>

    companion object {
        const val BASE_URL = "https://api.unpaywall.org/v2/"
    }
}

/**
 * Response from Unpaywall API for a work lookup.
 */
data class UnpaywallResponse(
    /** Digital Object Identifier. */
    val doi: String?,

    /** Whether the work is open access. */
    val is_oa: Boolean?,

    /** Best open access location. */
    val best_oa_location: UnpaywallOaLocation?,

    /** All open access locations. */
    val oa_locations: List<UnpaywallOaLocation>?,

    /** Title of the work. */
    val title: String?,

    /** Publication year. */
    val year: Int?,

    /** Publisher name. */
    val publisher: String?
)

/**
 * Open access location information from Unpaywall.
 */
data class UnpaywallOaLocation(
    /** URL to the OA version (may be PDF or landing page). */
    val url: String?,

    /** Direct URL to PDF (may be null). */
    val url_for_pdf: String?,

    /** Landing page URL. */
    val url_for_landing_page: String?,

    /** License type (e.g., "cc-by", "public-domain"). */
    val license: String?,

    /** Version type (e.g., "publishedVersion", "acceptedVersion"). */
    val version: String?,

    /** Host type (e.g., "publisher", "repository"). */
    val host_type: String?,

    /** Whether this is the best location. */
    val is_best: Boolean?
)
