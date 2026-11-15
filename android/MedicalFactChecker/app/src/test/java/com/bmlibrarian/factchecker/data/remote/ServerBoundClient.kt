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

package com.bmlibrarian.factchecker.data.remote

import okhttp3.OkHttpClient
import okhttp3.mockwebserver.MockWebServer

/**
 * A client that sends every request to [server], keeping its path and query.
 *
 * Lets a test call a `NetworkModule` provider, whose base URL is the real service's,
 * so the wiring the app runs is the wiring tested (#781).
 *
 * @param server The local server
 * @return The client
 */
fun serverBoundClient(server: MockWebServer): OkHttpClient =
    OkHttpClient.Builder()
        .addInterceptor { chain ->
            val url = chain.request().url.newBuilder()
                .scheme(server.url("/").scheme)
                .host(server.hostName)
                .port(server.port)
                .build()
            chain.proceed(chain.request().newBuilder().url(url).build())
        }
        .build()
