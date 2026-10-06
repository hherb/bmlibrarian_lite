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

import com.bmlibrarian.factchecker.util.Constants
import java.util.Locale
import kotlinx.serialization.json.JsonArray
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonArray
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.addJsonObject
import kotlinx.serialization.json.put

/**
 * Which lookup of the Unpaywall tier could not settle whether an open-access
 * copy exists.
 *
 * @property persistedValue The value stored for this source, shared with iOS and
 *   macOS: never rename one
 * @property serviceName The source as the reader is told of it, worded to sit
 *   mid-sentence (Python's `SERVICE_UNPAYWALL`, `SERVICE_UNPAYWALL_LANDING_PAGE` and
 *   `SERVICE_UNPAYWALL_PDF`)
 */
enum class OpenAccessSource(val persistedValue: String, val serviceName: String) {
    /**
     * Unpaywall itself: it was not asked, its answer did not arrive or could not
     * be read, or it answered with an error status other than 404.
     */
    UNPAYWALL("unpaywall", "Unpaywall"),

    /** The landing page Unpaywall named in place of a PDF (#464). */
    LANDING_PAGE("unpaywall_landing_page", "the open-access copy's landing page"),

    /**
     * The PDF Unpaywall named, its `url_for_pdf` or the one its landing page
     * declares, when it could not be obtained: an address that cannot be
     * requested, a download that failed, or a body that is not a PDF (#478).
     * Unpaywall answered; the copy it pointed at went unassessed.
     */
    PDF("unpaywall_pdf", "the open-access copy's PDF"),

    /** OpenAlex's record of the work, asked for the PDFs Unpaywall did not name (#480, stage B). */
    OPENALEX("openalex", Constants.OPENALEX_SERVICE_NAME),

    /** A PDF OpenAlex named that could not be obtained: OpenAlex answered, the copy went unassessed. */
    OPENALEX_PDF("openalex_pdf", "OpenAlex's copy"),

    /** CORE's extracted text, asked by DOI with the user's key (#480, stage C). */
    CORE("core", Constants.CORE_SERVICE_NAME);

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
 * Why the open-access copy Unpaywall may know of went unassessed (#464, #466, #480).
 *
 * Unpaywall, the landing page it named, a PDF it or OpenAlex named, or OpenAlex
 * itself could not settle whether a free copy exists, so the chain ended on a
 * fallback without learning it. That is not "no open-access copy": the reader is
 * told so ([notice]), and the document keeps it beside its full-text fields
 * ([toJson]). The shortfall is a list, in the order things were met; with a tried
 * PDF the reader is told every source tried. Python records the same event and
 * words it the same way (`analysis_failures.py`); iOS and macOS have the twin in
 * BioMedLit. The contracts are
 * `doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json` and
 * `open_access_statement.json`.
 *
 * @property entries What went unsettled, in the order met; never empty
 */
data class OpenAccessShortfall(val entries: List<Entry>) {

    /**
     * One lookup, or one PDF a source named, that left the question open.
     *
     * @property source Which lookup, or whose PDF
     * @property reason Why: a failed lookup, or an Unpaywall that was not configured
     * @property address The PDF's address, for a PDF a source named; null for a
     *   service's own lookup. Trimmed; blank is null
     */
    class Entry(
        val source: OpenAccessSource,
        val reason: OpenAccessUnsettledReason,
        address: String? = null
    ) {
        val address: String? = address?.trim()?.ifEmpty { null }

        init {
            // Only Unpaywall's own lookup is ever skipped, as in Swift; any other
            // skip would be written as one that reads back as Unpaywall's
            require(
                reason !is OpenAccessUnsettledReason.NotConfigured ||
                    (source == OpenAccessSource.UNPAYWALL && this.address == null)
            ) { "a not-configured skip is Unpaywall's own lookup, not $source with address ${this.address}" }
        }

        /** The failure, or null for a lookup that was never made. */
        val failure: RequestFailure?
            get() = (reason as? OpenAccessUnsettledReason.Failed)?.failure

        /** Whether it could not be asked (#435), which decides the ending. */
        internal val couldNotBeAsked: Boolean
            get() = failure?.let { !it.isAnswer } ?: true

        /** Its reason as the reader is told it. */
        internal val described: String
            get() = failure?.describe() ?: NOT_CONFIGURED_DESCRIPTION

        override fun equals(other: Any?): Boolean =
            other is Entry && source == other.source && reason == other.reason && address == other.address

        override fun hashCode(): Int = 31 * (31 * source.hashCode() + reason.hashCode()) + (address?.hashCode() ?: 0)

        override fun toString(): String = "Entry(source=$source, reason=$reason, address=$address)"
    }

    init {
        require(entries.isNotEmpty()) { "a shortfall names what went unsettled" }
    }

    /**
     * A lookup that was made, or was not (a skipped Unpaywall).
     *
     * @param source Which lookup could not settle it
     * @param reason Why
     */
    constructor(source: OpenAccessSource, reason: OpenAccessUnsettledReason) :
        this(listOf(Entry(source, reason)))

    /**
     * A lookup, or a PDF, that was tried and failed.
     *
     * @param source Which lookup, or whose PDF
     * @param failure Why, by kind and status only
     * @param address The PDF's address, if it is a PDF's entry
     */
    constructor(source: OpenAccessSource, failure: RequestFailure, address: String? = null) :
        this(listOf(Entry(source, OpenAccessUnsettledReason.Failed(failure), address)))

    /** The first entry's source, for callers that log one; decide nothing from it alone. */
    val source: OpenAccessSource
        get() = entries.first().source

    /** The first entry's reason, for callers that log one; decide nothing from it alone. */
    val reason: OpenAccessUnsettledReason
        get() = entries.first().reason

    /** The first entry's failure, for callers that log one; decide nothing from it alone. */
    val failure: RequestFailure?
        get() = entries.first().failure

    /** This shortfall, then [other]'s entries. */
    operator fun plus(other: OpenAccessShortfall): OpenAccessShortfall = OpenAccessShortfall(entries + other.entries)

    /**
     * What the reader is told (Python's `unestablished_access_clause`, word for
     * word): with a tried PDF, every source tried (#480); otherwise each lookup
     * grouped by its verb (#435). An unconfigured Unpaywall adds the one cause
     * the reader can change.
     */
    val notice: String
        get() = withNudge(if (entries.any { it.address != null }) triedSourcesStatement else groupedStatement)

    /** Lookups only: each grouped by the verb it earns. */
    private val groupedStatement: String
        get() {
            val (unasked, answered) = unsettled(entries)
            val clauses = buildList {
                if (unasked.isNotEmpty()) add("${joined(unasked)} could not be asked")
                if (answered.isNotEmpty()) add("${joined(answered)} did not serve it")
            }
            val ending = if (unasked.isEmpty()) ANSWERED_ENDING else MAY_EXIST_ENDING
            return sentenceStart("${clauses.joinToString(", and ")}, $ending")
        }

    /** Python's `tried_sources_statement`; identical entries are told once. */
    private val triedSourcesStatement: String
        get() {
            val lookups = entries.filter { it.address == null }
            val (unasked, answered) = unsettled(lookups)
            val reasons = answered + unasked
            val services = (lookups.filter { it.failure != null } + lookups.filter { it.failure == null })
                .map { it.source }.distinct()
            class Item(val rank: Int, val position: Int, val text: String, val unasked: Boolean)
            val items = mutableListOf<Item>()
            services.forEachIndexed { position, service ->
                val name = service.serviceName
                items += Item(CHAIN_ORDER.indexOf(service), position, "$name (${reasons[name] ?: ""})", name in unasked)
            }
            entries.filter { it.address != null }.forEachIndexed { offset, entry ->
                items += Item(
                    CHAIN_ORDER.indexOf(entry.source),
                    services.size + offset,
                    "${host(entry.address.orEmpty())}, named by ${namedBy(entry.source)} (${entry.described})",
                    entry.couldNotBeAsked
                )
            }
            val ordered = items.sortedWith(compareBy({ it.rank }, { it.position }))
            val ending = if (ordered.any { it.unasked }) TRIED_UNASKED_ENDING else TRIED_ANSWERED_ENDING
            // Two PDFs on one host refused alike read the same: told once, the
            // first after sorting, as Python's `dict.fromkeys` keeps it.
            val texts = ordered.map { it.text }.distinct()
            return TRIED_SOURCES_LEAD + texts.joinToString("; ") + ". " + ending
        }

    /** Python's `configuration_nudge`: only Unpaywall is ever not configured. */
    private fun withNudge(sentence: String): String =
        if (entries.any { it.reason == OpenAccessUnsettledReason.NotConfigured }) {
            "$sentence Configuring ${OpenAccessSource.UNPAYWALL.serviceName} " +
                "would add an open-access route this search did not have."
        } else {
            sentence
        }

    /**
     * The value a document stores for this shortfall.
     *
     * One lookup without an address keeps schema 1:
     * `{"schema_version":1,"source":…,"failure":{"kind":…,"status_code":…}}` (for a
     * lookup not made, `"skipped":"not_configured"` in its place). Anything else
     * is schema 2: `{"schema_version":2,"entries":[…]}`, each entry in the same
     * shape plus the PDF's `address`.
     *
     * @return JSON text
     */
    fun toJson(): String {
        val single = entries.singleOrNull()
        if (single != null && single.address == null) {
            return buildJsonObject {
                put(KEY_SCHEMA_VERSION, SCHEMA_VERSION)
                storeEntry(single)
            }.toString()
        }
        return buildJsonObject {
            put(KEY_SCHEMA_VERSION, SCHEMA_VERSION_LIST)
            put(
                KEY_ENTRIES,
                buildJsonArray { entries.forEach { entry -> addJsonObject { storeEntry(entry) } } }
            )
        }.toString()
    }

    companion object {
        /** The stored form's schema version for one lookup without an address. */
        private const val SCHEMA_VERSION = 1L

        /** The stored form's schema version for a list (#480). */
        private const val SCHEMA_VERSION_LIST = 2L

        private const val KEY_SCHEMA_VERSION = "schema_version"
        private const val KEY_SOURCE = "source"
        private const val KEY_FAILURE = "failure"
        private const val KEY_SKIPPED = "skipped"
        private const val KEY_ENTRIES = "entries"
        private const val KEY_ADDRESS = "address"

        /** Python's `LookupSkipReason.NOT_CONFIGURED`, as stored. */
        private const val SKIPPED_NOT_CONFIGURED = "not_configured"

        /** Python's `SourceLookupSkipped.describe()` for that reason. */
        private const val NOT_CONFIGURED_DESCRIPTION = "not configured"

        /** The open-access chain's sources in the order they are tried (#480). */
        internal val CHAIN_ORDER = listOf(
            OpenAccessSource.UNPAYWALL,
            OpenAccessSource.LANDING_PAGE,
            OpenAccessSource.PDF,
            OpenAccessSource.OPENALEX,
            OpenAccessSource.OPENALEX_PDF,
            OpenAccessSource.CORE
        )

        private const val TRIED_SOURCES_LEAD = "Failed to obtain a PDF from the following tried sources: "
        private const val MAY_EXIST_ENDING =
            "so a freely available copy may exist. Whether this document is open access was not established."
        private const val ANSWERED_ENDING = "so whether this document is open access was not established."
        private const val TRIED_UNASKED_ENDING =
            "A freely available copy may exist. Whether this document is open access was not established."
        private const val TRIED_ANSWERED_ENDING = "Whether this document is open access was not established."

        /** What the reader is told of a PDF not saved on the device (Python's `not_saved_note`). */
        private const val NOT_SAVED_ADVICE = "Check the free storage space and try again."

        /**
         * Matches what precedes a URL's authority: `scheme://`, or a bare `//`
         * (a scheme-relative address), as urlsplit reads both.
         */
        private val AUTHORITY_START = Regex("^(?:[A-Za-z][A-Za-z0-9+.-]*:)?//")

        /** Where a URL's authority ends. */
        private const val AUTHORITY_END = "/?#"

        /** Unpaywall, never asked for want of a contact email it would accept. */
        val UNPAYWALL_NOT_CONFIGURED =
            OpenAccessShortfall(OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.NotConfigured)

        /** The article a mid-sentence service name may begin with. */
        private const val LOWER_CASE_ARTICLE = "the "

        /**
         * [next] added after whatever is held: how the chain records each lookup
         * and each PDF that went unsettled, in the order met.
         *
         * @param next What went unsettled now
         * @param existing What was recorded before, if anything
         * @return Both, in order
         */
        fun adding(next: OpenAccessShortfall, existing: OpenAccessShortfall?): OpenAccessShortfall =
            existing?.let { it + next } ?: next

        /** Who named a tried PDF. */
        private fun namedBy(source: OpenAccessSource): String = when (source) {
            OpenAccessSource.PDF -> OpenAccessSource.UNPAYWALL.serviceName
            OpenAccessSource.OPENALEX_PDF -> OpenAccessSource.OPENALEX.serviceName
            else -> source.serviceName
        }

        /**
         * Python's `_unsettled`: each service once, by its first failure unless a
         * later one could not be asked; a skipped service is named only if it
         * never failed. Insertion-ordered, so `remove` then `put` is Python's
         * `pop` then insert.
         */
        private fun unsettled(
            lookups: List<Entry>
        ): Pair<LinkedHashMap<String, String>, LinkedHashMap<String, String>> {
            val unasked = LinkedHashMap<String, String>()
            val answered = LinkedHashMap<String, String>()
            for (entry in lookups.filter { it.failure != null }) {
                val name = entry.source.serviceName
                if (name in unasked) continue
                if (entry.couldNotBeAsked) {
                    answered.remove(name)
                    unasked[name] = entry.described
                } else if (name !in answered) {
                    answered[name] = entry.described
                }
            }
            for (entry in lookups.filter { it.failure == null }) {
                val name = entry.source.serviceName
                if (name !in answered && name !in unasked) unasked[name] = entry.described
            }
            return unasked to answered
        }

        /** Python's `_joined`: "A (x)", "A (x) and B (y)", "A (x), B (y) and C (z)". */
        private fun joined(named: Map<String, String>): String {
            val clauses = named.map { (name, reason) -> "$name ($reason)" }
            if (clauses.size < 2) return clauses.firstOrNull().orEmpty()
            return clauses.dropLast(1).joinToString(", ") + " and " + clauses.last()
        }

        /**
         * Python's `address_host`: `urlsplit(address.strip()).hostname`, else the
         * address trimmed; a scheme-relative `//host/…` names its host, as in
         * urlsplit. Not `java.net.URI`, which refuses what urlsplit reads.
         *
         * An authority with a `[` and no `]`, or a `]` and no `[`, has no host:
         * urlsplit refuses it ("Invalid IPv6 URL"), so Python tells the address
         * trimmed, and so does this.
         *
         * @param address The PDF's address, as the source gave it
         * @return The name a tried PDF is told by
         */
        fun host(address: String): String {
            val trimmed = address.trim()
            val start = AUTHORITY_START.find(trimmed) ?: return trimmed
            val rest = trimmed.substring(start.range.last + 1)
            var authority = rest.takeWhile { it !in AUTHORITY_END }
            // urlsplit checks the whole netloc, userinfo included
            if (('[' in authority) != (']' in authority)) return trimmed
            authority = authority.substringAfterLast('@')
            val host = if (authority.startsWith("[") && ']' in authority) {
                authority.substring(1, authority.indexOf(']'))
            } else {
                authority.substringBefore(':')
            }
            return if (host.isEmpty()) trimmed else host.lowercase(Locale.ROOT)
        }

        /**
         * Python's `not_saved_note` (#480): a PDF served and not saved is ours to
         * fix, so it is a note of its own, never in the tried-sources list.
         *
         * @param address The PDF's address
         * @param linkKept Whether the PDF's link is what the reader is given
         * @return The sentence and its advice
         */
        fun notSavedNote(address: String, linkKept: Boolean): String {
            val outcome = if (linkKept) "only its link is kept" else "it could not be read"
            return "A PDF of this article was found at ${host(address)} but could not be saved on this device, " +
                "so $outcome. $NOT_SAVED_ADVICE"
        }

        /** One entry as stored: its source, address if any, and why. */
        private fun kotlinx.serialization.json.JsonObjectBuilder.storeEntry(entry: Entry) {
            put(KEY_SOURCE, entry.source.persistedValue)
            entry.address?.let { put(KEY_ADDRESS, it) }
            when (val reason = entry.reason) {
                is OpenAccessUnsettledReason.Failed -> put(KEY_FAILURE, SearchFailureReporting.failureJson(reason.failure))
                OpenAccessUnsettledReason.NotConfigured -> put(KEY_SKIPPED, SKIPPED_NOT_CONFIGURED)
            }
        }

        /**
         * Read back what a document stored, degrading rather than refusing.
         *
         * The field is written only when something went unsettled, so every
         * stored value is some shortfall and none reads as "nothing to say".
         * What cannot be interpreted, a schema this build does not know and an
         * `entries` that is not a non-empty list included, reads as a failed
         * request to Unpaywall, the tier every open-access lookup belongs to. An
         * unknown source reads as Unpaywall too; the failure degrades as a search
         * shortfall's does. A stored skip is Unpaywall's, whatever source it
         * names: only Unpaywall is skipped.
         *
         * @param stored The stored value, untrusted
         * @return The shortfall, as specific as the stored value allows
         */
        fun fromJson(stored: String): OpenAccessShortfall {
            val uninterpretable = OpenAccessShortfall(OpenAccessSource.UNPAYWALL, RequestFailure(RequestFailureKind.REQUEST_FAILED))
            val fields = SearchFailureReporting.parsedOrNull(stored) as? JsonObject ?: return uninterpretable
            return when (SearchFailureReporting.wholeNumber(fields[KEY_SCHEMA_VERSION])) {
                SCHEMA_VERSION -> OpenAccessShortfall(listOf(restoredEntry(fields)))
                SCHEMA_VERSION_LIST -> {
                    val list = (fields[KEY_ENTRIES] as? JsonArray)?.takeIf { it.isNotEmpty() } ?: return uninterpretable
                    OpenAccessShortfall(
                        list.map { element ->
                            (element as? JsonObject)?.let(::restoredEntry)
                                ?: Entry(OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.Failed(RequestFailure(RequestFailureKind.REQUEST_FAILED)))
                        }
                    )
                }
                else -> uninterpretable
            }
        }

        /** One stored entry, as specific as it allows. */
        private fun restoredEntry(fields: JsonObject): Entry {
            if (fields[KEY_SKIPPED] == JsonPrimitive(SKIPPED_NOT_CONFIGURED)) {
                return Entry(OpenAccessSource.UNPAYWALL, OpenAccessUnsettledReason.NotConfigured)
            }
            val sourceValue = (fields[KEY_SOURCE] as? JsonPrimitive)?.takeIf { it.isString }?.content
            val address = (fields[KEY_ADDRESS] as? JsonPrimitive)?.takeIf { it.isString }?.content
            return Entry(
                OpenAccessSource.fromPersisted(sourceValue) ?: OpenAccessSource.UNPAYWALL,
                OpenAccessUnsettledReason.Failed(SearchFailureReporting.failureFrom(fields[KEY_FAILURE])),
                address
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
