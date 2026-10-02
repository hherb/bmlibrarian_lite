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

package com.bmlibrarian.factchecker.data.remote.fulltext

import kotlinx.serialization.Serializable
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
 *
 * Serializable because the app's Retrofit builder decodes with kotlinx
 * serialization only: without it Retrofit could not build a converter, every
 * lookup threw "Unable to create converter", and the Unpaywall tier never
 * offered a PDF (found with #464). Every field defaults to null, since
 * Unpaywall omits some and the decoder demands a default for a missing key.
 */
@Serializable
data class UnpaywallResponse(
    /** Digital Object Identifier. */
    val doi: String? = null,

    /** Whether the work is open access. */
    val is_oa: Boolean? = null,

    /** Best open access location. */
    val best_oa_location: UnpaywallOaLocation? = null,

    /** All open access locations. */
    val oa_locations: List<UnpaywallOaLocation>? = null,

    /** Title of the work. */
    val title: String? = null,

    /** Publication year. */
    val year: Int? = null,

    /** Publisher name. */
    val publisher: String? = null
)

/**
 * Open access location information from Unpaywall.
 *
 * `url` is `url_for_pdf` when there is one and the landing page when not, so
 * it never names a PDF that `url_for_pdf` does not (#464): see
 * [UnpaywallLandingPage.chooseUrl].
 */
@Serializable
data class UnpaywallOaLocation(
    /** The PDF when there is one, else the landing page: never a PDF on its own (#464). */
    val url: String? = null,

    /** Direct URL to PDF (may be null). */
    val url_for_pdf: String? = null,

    /** Landing page URL. */
    val url_for_landing_page: String? = null,

    /** License type (e.g., "cc-by", "public-domain"). */
    val license: String? = null,

    /** Version type (e.g., "publishedVersion", "acceptedVersion"). */
    val version: String? = null,

    /** Host type (e.g., "publisher", "repository"). */
    val host_type: String? = null,

    /** Whether this is the best location. */
    val is_best: Boolean? = null
)
