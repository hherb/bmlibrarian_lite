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

import com.bmlibrarian.factchecker.util.Constants
import com.jakewharton.retrofit2.converter.kotlinx.serialization.asConverterFactory
import kotlinx.serialization.json.Json
import okhttp3.Interceptor
import okhttp3.MediaType.Companion.toMediaType
import okhttp3.OkHttpClient
import retrofit2.Invocation
import retrofit2.Retrofit
import retrofit2.converter.scalars.ScalarsConverterFactory

/** Media type of the JSON bodies esearch returns. */
private const val JSON_MEDIA_TYPE = "application/json"

/**
 * Removes Retrofit's [Invocation] tag from a request before anything else sees it.
 *
 * Retrofit tags every request with the interface call's arguments, the API key
 * among them, and OkHttp's `Request.toString()` prints tags. Without this, any
 * interceptor or log line that printed a PubMed request would print the key.
 */
private val dropInvocationTag = Interceptor { chain ->
    chain.proceed(chain.request().newBuilder().tag(Invocation::class.java, null).build())
}

/**
 * Derive the HTTP client every E-utilities request goes through.
 *
 * It is [base], with the same timeouts, interceptors and connection pool,
 * except that it follows no redirect. With the parameters in a POST body, a
 * 307 or 308 would re-send the body, API key included, to whatever host the
 * redirect names, and a 301, 302 or 303 would re-send the request as a GET
 * without its parameters, which NCBI answers as a search for nothing. Unfollowed,
 * the 3xx arrives as the response itself, which [PubMedService] reports as
 * [com.bmlibrarian.factchecker.domain.model.PubMedError.RedirectRefusedError].
 * Not even a redirect to an NCBI host is followed: these endpoints never
 * legitimately redirect, and a same-host redirect can still downgrade to
 * `http://` and carry the key in cleartext.
 *
 * Its first interceptor also drops Retrofit's [Invocation] tag, which holds the
 * API key and which `Request.toString()` would print.
 *
 * Only PubMed gets this client: Unpaywall and publisher PDF links depend on
 * redirects, so the shared client must keep following them.
 *
 * @param base The app's shared client
 * @return A client that returns every redirect instead of following it
 */
fun pubMedHttpClient(base: OkHttpClient): OkHttpClient =
    base.newBuilder()
        .apply { interceptors().add(0, dropInvocationTag) }
        .followRedirects(false)
        .followSslRedirects(false)
        .build()

/**
 * Build the [PubMedApi], on a client derived by [pubMedHttpClient].
 *
 * Uses its own `Retrofit.Builder` rather than the shared `scalarsAndJson` one.
 * That builder is a mutable singleton, so setting this client on it would hand
 * the no-redirect client to every API built from it afterwards.
 *
 * @param baseClient The app's shared client, from which the PubMed client is derived
 * @param json The Json instance for esearch responses
 * @param baseUrl The E-utilities base URL, ending in a slash
 * @return The PubMed API interface
 */
fun createPubMedApi(
    baseClient: OkHttpClient,
    json: Json,
    baseUrl: String = Constants.PUBMED_BASE_URL
): PubMedApi =
    Retrofit.Builder()
        .baseUrl(baseUrl)
        .client(pubMedHttpClient(baseClient))
        // Scalars first for raw string responses (efetch XML)
        .addConverterFactory(ScalarsConverterFactory.create())
        // JSON second for parsed responses (esearch)
        .addConverterFactory(json.asConverterFactory(JSON_MEDIA_TYPE.toMediaType()))
        .build()
        .create(PubMedApi::class.java)
