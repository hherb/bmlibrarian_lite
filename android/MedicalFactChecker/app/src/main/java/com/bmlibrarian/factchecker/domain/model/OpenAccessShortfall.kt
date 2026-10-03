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

package com.bmlibrarian.factchecker.domain.model

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * Which lookup of the Unpaywall tier could not settle whether an open-access
 * copy exists.
 *
 * @property persistedValue The value stored for this source, shared with iOS and
 *   macOS: never rename one
 * @property serviceName The source as the reader is told of it, worded to sit
 *   mid-sentence (Python's `SERVICE_UNPAYWALL` and `SERVICE_UNPAYWALL_LANDING_PAGE`)
 */
enum class OpenAccessSource(val persistedValue: String, val serviceName: String) {
    /**
     * Unpaywall itself: it was not asked, its answer did not arrive or could not
     * be read, or it answered with an error status other than 404.
     */
    UNPAYWALL("unpaywall", "Unpaywall"),

    /** The landing page Unpaywall named in place of a PDF (#464). */
    LANDING_PAGE("unpaywall_landing_page", "the open-access copy's landing page");

    companion object {
        /**
         * Read a stored source.
         *
         * @param value The stored value, untrusted
         * @return The source it names, or null for a value this build does not know
         */
        fun fromPersisted(value: String?): OpenAccessSource? =
            entries.firstOrNull { it.persistedValue == value }
    }
}

/**
 * Why a lookup of the Unpaywall tier left the question of a free copy open.
 *
 * Python records the two as a `SourceLookupFailure` and a `SourceLookupSkipped`
 * with `LookupSkipReason.NOT_CONFIGURED`.
 */
sealed interface OpenAccessUnsettledReason {
    /**
     * The lookup was made and did not settle it.
     *
     * @property failure Why, by kind and status only
     */
    data class Failed(val failure: RequestFailure) : OpenAccessUnsettledReason

    /**
     * Unpaywall was never asked: there is no contact email it would accept.
     * Only [OpenAccessSource.UNPAYWALL] is ever skipped so; see
     * [OpenAccessShortfall.UNPAYWALL_NOT_CONFIGURED].
     */
    data object NotConfigured : OpenAccessUnsettledReason
}

/**
 * Why the open-access copy Unpaywall may know of went unassessed (#464, #466).
 *
 * Unpaywall, or the landing page it named, could not settle whether a free copy
 * exists, so the chain ended on a fallback without learning it. That is not "no
 * open-access copy": the reader is told so ([notice]), and the document keeps it
 * beside its full-text fields ([toJson]). Python records the same event as a
 * `SourceLookupFailure` (or, for an Unpaywall with no usable email, a
 * `SourceLookupSkipped`) and words it the same way; iOS and macOS have the twin
 * in BioMedLit. The contract is
 * `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json`.
 *
 * @property source Which lookup could not settle it
 * @property reason Why: a failed lookup, or an Unpaywall that was not configured
 */
data class OpenAccessShortfall(
    val source: OpenAccessSource,
    val reason: OpenAccessUnsettledReason
) {
    /**
     * A lookup that was made and failed.
     *
     * @param source Which lookup could not settle it
     * @param failure Why, by kind and status only
     */
    constructor(source: OpenAccessSource, failure: RequestFailure) :
        this(source, OpenAccessUnsettledReason.Failed(failure))

    /** The failure, or null for a lookup that was never made. */
    val failure: RequestFailure?
        get() = (reason as? OpenAccessUnsettledReason.Failed)?.failure

    /**
     * What the reader is told: which lookup went unsettled, and what that leaves
     * open about access.
     *
     * The verb follows #435 ([RequestFailure.isAnswer]). A lookup that could not
     * be asked may have missed a free copy, and the reader is told so; one that
     * answered without serving the copy is no reason to think one exists. An
     * Unpaywall that was not configured could not be asked, and the reader is
     * also told that configuring it would help, the one cause they can change.
     * Python's `analysis_failures.unestablished_access_clause`, word for word.
     */
    val notice: String
        get() {
            val name = sentenceStart(source.serviceName)
            return when (reason) {
                is OpenAccessUnsettledReason.Failed -> {
                    val named = "$name (${reason.failure.describe()})"
                    if (reason.failure.isAnswer) {
                        "$named did not serve it, so whether this document is open access was not established."
                    } else {
                        "$named $MAY_EXIST"
                    }
                }
                OpenAccessUnsettledReason.NotConfigured ->
                    "$name ($NOT_CONFIGURED_DESCRIPTION) $MAY_EXIST " +
                        "Configuring ${source.serviceName} would add an open-access route this search did not have."
            }
        }

    /**
     * The value a document stores for this shortfall.
     *
     * @return `{"schema_version":1,"source":…,"failure":{"kind":…,"status_code":…}}`,
     *   the failure in the shape a search shortfall stores it; for a lookup that
     *   was not configured, `{"schema_version":1,"source":"unpaywall","skipped":"not_configured"}`
     */
    fun toJson(): String = buildJsonObject {
        put(KEY_SCHEMA_VERSION, SCHEMA_VERSION)
        put(KEY_SOURCE, source.persistedValue)
        when (reason) {
            is OpenAccessUnsettledReason.Failed -> put(KEY_FAILURE, SearchFailureReporting.failureJson(reason.failure))
            OpenAccessUnsettledReason.NotConfigured -> put(KEY_SKIPPED, SKIPPED_NOT_CONFIGURED)
        }
    }.toString()

    companion object {
        /** The stored form's schema version. */
        private const val SCHEMA_VERSION = 1L

        private const val KEY_SCHEMA_VERSION = "schema_version"
        private const val KEY_SOURCE = "source"
        private const val KEY_FAILURE = "failure"
        private const val KEY_SKIPPED = "skipped"

        /** Python's `LookupSkipReason.NOT_CONFIGURED`, as stored. */
        private const val SKIPPED_NOT_CONFIGURED = "not_configured"

        /** Python's `SourceLookupSkipped.describe()` for that reason. */
        private const val NOT_CONFIGURED_DESCRIPTION = "not configured"

        /** The ending for a lookup that could not be asked. */
        private const val MAY_EXIST =
            "could not be asked, so a freely available copy may exist. " +
                "Whether this document is open access was not established."

        /** Unpaywall, never asked for want of a contact email it would accept. */
        val UNPAYWALL_NOT_CONFIGURED =
            OpenAccessShortfall(OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.NotConfigured)

        /** The article a mid-sentence service name may begin with. */
        private const val LOWER_CASE_ARTICLE = "the "

        /**
         * Read back what a document stored, degrading rather than refusing.
         *
         * The field is written only when something went unsettled, so every
         * stored value is some shortfall and none reads as "nothing to say".
         * What cannot be interpreted, a schema this build does not know
         * included, reads as a failed request to Unpaywall, the tier every
         * open-access lookup belongs to. An unknown source reads as Unpaywall
         * too; the failure degrades as a search shortfall's does. A stored skip
         * is Unpaywall's, whatever source it names: only Unpaywall is skipped.
         *
         * @param stored The stored value, untrusted
         * @return The shortfall, as specific as the stored value allows
         */
        fun fromJson(stored: String): OpenAccessShortfall {
            val fields = SearchFailureReporting.parsedOrNull(stored) as? JsonObject
            if (fields == null || SearchFailureReporting.wholeNumber(fields[KEY_SCHEMA_VERSION]) != SCHEMA_VERSION) {
                return OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.REQUEST_FAILED))
            }
            if (fields[KEY_SKIPPED] == JsonPrimitive(SKIPPED_NOT_CONFIGURED)) {
                return UNPAYWALL_NOT_CONFIGURED
            }
            val sourceValue = (fields[KEY_SOURCE] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return OpenAccessShortfall(
                OpenAccessSource.fromPersisted(sourceValue) ?: OpenAccessSource.UNPAYWALL,
                SearchFailureReporting.failureFrom(fields[KEY_FAILURE])
            )
        }

        /**
         * Capitalise a leading "the", as Python's `_sentence_start` does; a name
         * such as "Unpaywall" keeps its own case.
         *
         * @param name A service name
         * @return The name, fit to begin a sentence
         */
        private fun sentenceStart(name: String): String =
            if (name.startsWith(LOWER_CASE_ARTICLE)) "The " + name.removePrefix(LOWER_CASE_ARTICLE) else name
    }
}
