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

import android.util.Log
import com.bmlibrarian.factchecker.util.Constants
import java.security.MessageDigest

/**
 * The fingerprints a service asked with the user's own key remembers a refusal
 * by (#498, #480 stage C2): Python's `keyed_service_session.key_digest` and
 * `credentials_digest`. The key and the token themselves are never held for
 * that, and a digest is never logged.
 */
object KeyDigest {
    /** The algorithm of every digest here. */
    private const val ALGORITHM = "SHA-256"

    /** What joins the key and the token in [credentials]. */
    private const val SEPARATOR = "\n"

    /**
     * The fingerprint a refused key is remembered by.
     *
     * @param apiKey The key; trimmed here, so padding names the same key
     * @return The SHA-256 digest of the trimmed key's UTF-8 bytes, as lower-case hex
     */
    fun key(apiKey: String): String = sha256Hex(apiKey.trim())

    /**
     * The fingerprint a refusal from this network is remembered by. A token added
     * in the settings makes other credentials, which are asked again.
     *
     * @param apiKey The key; trimmed here
     * @param token The institutional token, or null; trimmed here, and a blank one is no token
     * @return The SHA-256 digest (lower-case hex) of `trim(key) + "\n" + trim(token or "")`
     */
    fun credentials(apiKey: String, token: String?): String =
        sha256Hex(apiKey.trim() + SEPARATOR + token.orEmpty().trim())

    /**
     * The SHA-256 digest of a text's UTF-8 bytes.
     *
     * @param text The text
     * @return 64 lower-case hex digits
     */
    fun sha256Hex(text: String): String =
        MessageDigest.getInstance(ALGORITHM)
            .digest(text.toByteArray(Charsets.UTF_8))
            .joinToString("") { "%02x".format(it) }
}

/**
 * What one keyed service's fetches leave for the next, within its lifetime
 * (Python's `KeyedServiceSession`, BioMedLit's twin).
 *
 * CORE and Elsevier share the rules, each with its own instance, so a CORE 429
 * never pauses Elsevier. Consecutive fetches ending in 429 pause the service for
 * the rest of the session: its key buys a quota no pacing can express. A fetch
 * ending on the service's key-refused status refuses the key it was sent with,
 * held as its [KeyDigest.key]: another key, such as one corrected in the
 * settings, is asked as usual. A refusal from this network refuses those
 * credentials, held as their [KeyDigest.credentials]. A fetch that makes no
 * request (refused or paused) is recorded nowhere: the caller does not call
 * [record] for it.
 *
 * @param serviceName The service as log lines name it
 * @param keyRefusedStatus The HTTP status that means the key is refused
 * @param pauseAfter Consecutive 429 endings that pause the service
 * @param logTag The tag its log lines carry
 */
class KeyedServiceSession(
    private val serviceName: String,
    private val keyRefusedStatus: Int,
    private val pauseAfter: Int,
    private val logTag: String
) {
    private val lock = Any()
    private var consecutive429 = 0

    @Volatile
    private var paused = false

    @Volatile
    private var refusedKeyDigest: String? = null

    @Volatile
    private var refusedCredentialsDigest: String? = null

    /** Whether the service is paused for the rest of the session. */
    val isPaused: Boolean get() = paused

    /**
     * Whether the service refused this key this session; any other key is asked as usual.
     *
     * @param keyDigest The key's [KeyDigest.key]
     */
    fun refuses(keyDigest: String): Boolean = refusedKeyDigest == keyDigest

    /**
     * Whether the service refused these credentials from this network this session;
     * any other key, or the same key with another token, is asked as usual.
     *
     * @param credentialsDigest The key's and token's [KeyDigest.credentials]
     */
    fun refusesNetwork(credentialsDigest: String): Boolean = refusedCredentialsDigest == credentialsDigest

    /**
     * Note how one fetch that made a request ended: the key-refused status marks the
     * key it was sent with refused, in place of any before; like any ending but a
     * 429, it also resets the 429 count. A new refusal, and the pause when this
     * ending starts it, are logged once (never the key or its digest).
     *
     * @param status The ending's HTTP status, or null for none (a transport failure)
     * @param keyDigest The [KeyDigest.key] of the key it was sent with
     */
    fun record(status: Int?, keyDigest: String) {
        synchronized(lock) {
            if (status == keyRefusedStatus && refusedKeyDigest != keyDigest) {
                refusedKeyDigest = keyDigest
                Log.w(logTag, "$serviceName refused the configured key (HTTP $status); not asked with it again this session")
            }
            if (status != Constants.HTTP_TOO_MANY_REQUESTS) {
                consecutive429 = 0
                return
            }
            consecutive429 += 1
            if (consecutive429 >= pauseAfter && !paused) {
                paused = true
                Log.w(logTag, "$serviceName answered HTTP 429 $consecutive429 times in a row; not asked again this session")
            }
        }
    }

    /**
     * Note a fetch the service refused from this network. It is an ending, so it
     * resets the 429 count; those credentials are refused, in place of any before.
     * Logged once, when new; the credentials and their digest never are.
     *
     * @param credentialsDigest The [KeyDigest.credentials] it was sent with
     */
    fun recordNetworkRefused(credentialsDigest: String) {
        synchronized(lock) {
            consecutive429 = 0
            if (refusedCredentialsDigest != credentialsDigest) {
                refusedCredentialsDigest = credentialsDigest
                Log.w(logTag, "$serviceName refused the configured credentials from this network; not asked with them again this session")
            }
        }
    }
}
