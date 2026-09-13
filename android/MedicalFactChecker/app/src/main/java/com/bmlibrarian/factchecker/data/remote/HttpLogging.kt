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

import okhttp3.logging.HttpLoggingInterceptor

/**
 * The interceptor debug builds log HTTP traffic with.
 *
 * `BASIC` writes one line per request and per response, each naming the full
 * URL. That is why no credential may travel in a URL (#243): the NCBI key once
 * did, and reached logcat with every search. It is also why the level must not
 * be raised to `HEADERS` or `BODY` without redaction, since LLM keys travel in
 * headers and the NCBI key in the E-utilities request body.
 *
 * @param logger Where the lines go; the platform log by default
 * @return A logging interceptor at `BASIC` level
 */
fun debugHttpLoggingInterceptor(
    logger: HttpLoggingInterceptor.Logger = HttpLoggingInterceptor.Logger.DEFAULT
): HttpLoggingInterceptor =
    HttpLoggingInterceptor(logger).apply {
        level = HttpLoggingInterceptor.Level.BASIC
    }
