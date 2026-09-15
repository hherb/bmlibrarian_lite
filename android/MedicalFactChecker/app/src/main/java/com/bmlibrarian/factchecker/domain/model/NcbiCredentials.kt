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

package com.bmlibrarian.factchecker.domain.model

/**
 * What identifies this app to NCBI's E-utilities: an optional API key and an
 * optional contact email.
 *
 * [of] is the only way to build one, and it turns a blank setting into `null`.
 * Two things depend on that: a cleared key sends no `api_key` field at all
 * rather than an empty one, and a key's presence picks the faster rate limit.
 * A plain class with a private constructor, not a data class, so neither a
 * constructor call nor a generated `copy` can skip the rule.
 *
 * [toString] never prints the key. A data class's generated `toString` would,
 * and a credential that reaches a log line or an error message has left the
 * request it was meant for (#243).
 *
 * @property apiKey The NCBI API key, or null when none is configured
 * @property email The contact email, or null when none is configured
 */
class NcbiCredentials private constructor(
    val apiKey: String?,
    val email: String?
) {
    /** Describe the credentials without revealing the key. */
    override fun toString(): String =
        "NcbiCredentials(apiKey=${if (apiKey == null) "none" else "<set>"}, email=$email)"

    companion object {
        /**
         * Credentials from stored settings, where "not set" is a blank string.
         *
         * @param apiKey The stored API key; blank means none
         * @param email The stored email; blank means none
         * @return Credentials with every blank value replaced by null
         */
        fun of(apiKey: String?, email: String?): NcbiCredentials =
            NcbiCredentials(
                apiKey = apiKey?.takeIf { it.isNotBlank() },
                email = email?.takeIf { it.isNotBlank() }
            )
    }
}

/**
 * Where [com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService] reads
 * the credentials it sends.
 *
 * The service asks on every search, so a key saved in settings applies to the
 * next search without rebuilding anything, and no caller can forget to pass it.
 * Every workflow call site once did forget, so the saved key never reached NCBI.
 */
fun interface NcbiCredentialSource {
    /**
     * The credentials to send with the next E-utilities request.
     *
     * @return The current credentials
     */
    fun ncbiCredentials(): NcbiCredentials
}

/**
 * The saved NCBI API key or email could not be read, so no PubMed search can be sent (#252).
 *
 * Encrypted preferences throw when the keystore is broken, such as after a
 * backup restore. That is not a failure of PubMed's, so it is not reported as
 * one: retrying cannot help, and the user's next step is in Settings. The
 * keystore's exception is not kept.
 */
class NcbiCredentialsUnavailableException : Exception(
    "The saved NCBI API key or email could not be read. Re-enter them in Settings, or clear them, then try again."
)
