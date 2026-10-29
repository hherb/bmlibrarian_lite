// BMLibrarian Lite - Biomedical Literature Research Tool
// Copyright (C) 2024-2026 Dr Horst Herb
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as published by
// the Free Software Foundation, either version 3 of the License, or
// (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program. If not, see <https://www.gnu.org/licenses/>.
package com.bmlibrarian.factchecker.util.retraction

import android.util.Log
import com.bmlibrarian.factchecker.data.remote.fulltext.Pmid
import kotlinx.serialization.SerializationException
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonElement
import kotlinx.serialization.json.JsonObject
import org.bmlib.ffi.RetractionLookup
import org.bmlib.ffi.RetractionSource
import org.bmlib.ffi.RetractionStatus
import org.bmlib.ffi.RetractionVerdict
import org.bmlib.ffi.retractionStatus

/**
 * One paper as a retraction check asks about it.
 *
 * @property doi The paper's DOI, in any form bmlib normalises
 * @property pmid The paper's PMID; one that is not canonical is no PMID
 * @property publicationTypes The record's publication types (PubMed's label);
 *   none when not recorded
 */
data class RetractionPaper(val doi: String?, val pmid: String?, val publicationTypes: List<String>) {

    /** The PMID in canonical form, or null when there is none. */
    val canonicalPmid: String?
        get() = pmid?.let { Pmid.canonical(it).pmid }

    /**
     * The key this paper's check is stored under (the desktop's `paper_key`):
     * `doi:` and the Crossref key, else `pmid:` and the canonical PMID; null
     * with neither. Calls bmlib, so it throws without the native library.
     */
    val paperKey: String?
        get() = doi?.let(RetractionChecker::doiKey)?.let { "doi:$it" } ?: canonicalPmid?.let { "pmid:$it" }
}

/**
 * The evidence that decided a check, in the contract's names.
 *
 * @property source Where it was found (`retraction_watch_export`, `pubmed_label`, …)
 * @property kind What it is (`retraction`, `expression_of_concern`, …)
 * @property date The notice's date, ISO, as precise as deposited
 * @property noticeDoi The notice's normalised DOI
 * @property recordId The Retraction Watch record ID
 * @property rawKind The source's own word for the kind
 */
@Serializable
data class StoredRetractionEvidence(
    val source: String,
    val kind: String,
    val date: String? = null,
    val noticeDoi: String? = null,
    val recordId: String? = null,
    val rawKind: String? = null
)

/**
 * One paper's retraction check as it is stored: bmlib's verdict, when it was
 * made and what it rested on.
 *
 * @property status The status's contract name: `retracted`, `concern`, `clear` or `unchecked`
 * @property deciding The newest retraction or concern, otherwise the newest reinstatement
 * @property unanswered Every lookup that did not answer (`retraction_watch_export`, `crossref`)
 * @property checkedAtMs When it was decided, in epoch milliseconds
 * @property exportDataAsOf The `dataAsOf` of the index consulted; null when it was not consulted
 * @property crossrefFailure Why Crossref did not answer, in the app's own words
 *   (`RequestFailure.describe()`); null when it answered or was not asked
 */
@Serializable
data class PaperRetractionCheck(
    val status: String,
    val deciding: StoredRetractionEvidence? = null,
    val unanswered: List<String> = emptyList(),
    val checkedAtMs: Long,
    val exportDataAsOf: String? = null,
    val crossrefFailure: String? = null
) {
    /** The status; a name this build cannot read is unchecked, never clear. */
    val retractionStatus: RetractionStatus
        get() = RetractionNames.status(status) ?: RetractionStatus.UNCHECKED

    /** Whether the paper is retracted. */
    val isRetracted: Boolean get() = retractionStatus == RetractionStatus.RETRACTED

    /** Whether an expression of concern stands. */
    val isConcern: Boolean get() = retractionStatus == RetractionStatus.CONCERN

    /** Whether every source was consulted and none warns. */
    val isClear: Boolean get() = retractionStatus == RetractionStatus.CLEAR

    /** Whether the evidence could not decide (never read as clear). */
    val isUnchecked: Boolean get() = retractionStatus == RetractionStatus.UNCHECKED

    /** Whether the deciding evidence is the record's own PubMed label. */
    val isDecidedByLabel: Boolean
        get() = deciding?.let { RetractionNames.source(it.source) } == RetractionSource.PUBMED_LABEL

    /** Whether [lookup] did not answer. */
    fun leftUnanswered(lookup: RetractionLookup): Boolean = RetractionNames.name(lookup) in unanswered

    /**
     * Whether this stored check may stand in for a fresh one (the desktop's
     * `RetractionChecker.check`): no older than
     * [RetractionConstants.RETRACTION_CHECK_MAX_AGE_DAYS], every lookup
     * answered (a failure is not knowledge), a status this build can read,
     * and, unless it already says retracted, the paper's own label does not
     * retract it (a fresh label is never hidden behind a stored clear).
     *
     * @param nowMs The current time
     * @param publicationTypes The paper's record's publication types now
     */
    fun isReusable(nowMs: Long, publicationTypes: List<String>): Boolean {
        val maxAgeMs = RetractionConstants.RETRACTION_CHECK_MAX_AGE_DAYS * RetractionConstants.MS_PER_DAY
        if (nowMs - checkedAtMs > maxAgeMs || unanswered.isNotEmpty() || RetractionNames.status(status) == null) return false
        if (isRetracted) return true
        return retractionStatus(null, null, null, publicationTypes).status != RetractionStatus.RETRACTED
    }

    /**
     * Whether this stored check stands against [fresh] (the desktop's
     * `_keeps`): only when [fresh] leaves unanswered a lookup this one
     * answered and does not warn more. A fresh retraction, or a concern over
     * a stored clear, is news even while a lookup is down.
     *
     * This decides what is stored; what is shown is [shown].
     *
     * @param fresh The check just made
     */
    fun standsAgainst(fresh: PaperRetractionCheck): Boolean {
        if ((fresh.unanswered.toSet() - unanswered.toSet()).isEmpty()) return false
        if (fresh.isRetracted) return false
        return !(fresh.isConcern && isClear)
    }

    /**
     * The check the reader is shown, this being the stored one and [fresh]
     * the one just made: this one only when it [standsAgainst] it **and**
     * warns. A stored clear resting on a lookup now down is not knowledge
     * today, so the reader sees [against], unchecked.
     *
     * @param against The check just made
     */
    fun shown(against: PaperRetractionCheck): PaperRetractionCheck =
        if (standsAgainst(against) && (isRetracted || isConcern)) this else against

    companion object {
        private const val TAG = "PaperRetractionCheck"

        private val json = Json { ignoreUnknownKeys = true }

        /**
         * The stored form of bmlib's verdict.
         *
         * @param verdict bmlib's verdict
         * @param checkedAtMs When it was made
         * @param exportDataAsOf The consulted index's `dataAsOf`, or null
         * @param crossrefFailure Why Crossref did not answer, in the app's words
         */
        fun fromVerdict(verdict: RetractionVerdict, checkedAtMs: Long, exportDataAsOf: String?, crossrefFailure: String?) =
            PaperRetractionCheck(
                status = RetractionNames.name(verdict.status),
                deciding = verdict.deciding?.let {
                    StoredRetractionEvidence(
                        source = RetractionNames.name(it.source),
                        kind = RetractionNames.name(it.kind),
                        date = it.date,
                        noticeDoi = it.noticeDoi,
                        recordId = it.recordId,
                        rawKind = it.rawKind
                    )
                },
                unanswered = verdict.unanswered.map(RetractionNames::name),
                checkedAtMs = checkedAtMs,
                exportDataAsOf = exportDataAsOf,
                crossrefFailure = crossrefFailure
            )

        /**
         * A check that failed before any lookup answered: unchecked, both
         * lookups unanswered, so it is never reused and never stands against
         * an answer.
         *
         * @param atMs When the check was attempted
         */
        fun failed(atMs: Long) = PaperRetractionCheck(
            status = RetractionNames.name(RetractionStatus.UNCHECKED),
            unanswered = listOf(RetractionLookup.RETRACTION_WATCH_EXPORT, RetractionLookup.CROSSREF).map(RetractionNames::name),
            checkedAtMs = atMs
        )

        /** [check] as stored JSON. */
        fun encode(check: PaperRetractionCheck): String = json.encodeToString(serializer(), check)

        /** A stored check decoded; null when it cannot be read. */
        fun decode(text: String): PaperRetractionCheck? = try {
            json.decodeFromString(serializer(), text)
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }

        /**
         * What to store for a paper and what the run uses, given its stored
         * row and the check just made (Swift's `Document.takeRetractionCheck`,
         * retraction_checks.py `check`).
         *
         * The stored check stands, keeping its time, when it rests on a PubMed
         * label this document has not recorded (`_label_only_unreadable`) or
         * when it [standsAgainst] [fresh]. A row this build cannot read is
         * overwritten only by a check every lookup answered: it may hold a
         * retraction an outage must not erase.
         *
         * @param storedJson The paper's stored row, or null for none
         * @param fresh The check just made
         * @param typesRecorded Whether this document recorded its publication types
         * @return The check to store (null: keep the row) and the one the run uses
         */
        fun take(storedJson: String?, fresh: PaperRetractionCheck, typesRecorded: Boolean): TakenCheck {
            val stored = storedJson?.let(::decode)
            if (stored == null) {
                if (storedJson != null) Log.w(TAG, "A stored retraction check could not be read")
                return TakenCheck(store = fresh.takeIf { storedJson == null || fresh.unanswered.isEmpty() }, use = fresh)
            }
            if (!fresh.isRetracted && !typesRecorded && (stored.isRetracted || stored.isConcern) && stored.isDecidedByLabel) {
                return TakenCheck(store = null, use = stored)
            }
            if (stored.standsAgainst(fresh)) return TakenCheck(store = null, use = stored.shown(fresh))
            return TakenCheck(store = fresh, use = fresh)
        }
    }
}

/**
 * What [PaperRetractionCheck.take] decided.
 *
 * @property store The check to write as the paper's row, or null to keep the row
 * @property use The check the run excludes, counts and records by
 */
data class TakenCheck(val store: PaperRetractionCheck?, val use: PaperRetractionCheck)

/**
 * A session's snapshot: the check each document's run used, by document id
 * (`sessions.retraction_snapshot_json`). Read entry by entry, so one entry
 * this build cannot read costs itself and is kept as it was (#647).
 */
object RetractionSnapshot {
    private const val TAG = "RetractionSnapshot"

    private val json = Json { ignoreUnknownKeys = true }

    private fun entries(text: String?): Map<String, JsonElement> {
        if (text == null) return emptyMap()
        return try {
            json.parseToJsonElement(text) as? JsonObject ?: emptyMap<String, JsonElement>().also {
                Log.w(TAG, "A retraction snapshot is not an object")
            }
        } catch (e: SerializationException) {
            Log.w(TAG, "A retraction snapshot could not be read")
            emptyMap()
        }
    }

    /**
     * The snapshot's readable entries.
     *
     * @param text The stored snapshot, or null for a session never checked
     * @return Each document's check; an entry this build cannot read is left out
     */
    fun read(text: String?): Map<String, PaperRetractionCheck> = entries(text).mapNotNull { (id, entry) ->
        try {
            id to json.decodeFromJsonElement(PaperRetractionCheck.serializer(), entry)
        } catch (e: SerializationException) {
            null
        } catch (e: IllegalArgumentException) {
            null
        }
    }.toMap()

    /**
     * The snapshot with [checks] added; a document checked again is replaced,
     * and every other entry, readable or not, is kept as it was.
     *
     * @param text The stored snapshot, or null for none
     * @param checks What a run used, by document id
     * @return The snapshot to store
     */
    fun merged(text: String?, checks: Map<String, PaperRetractionCheck>): String {
        val all = entries(text) + checks.mapValues { json.encodeToJsonElement(PaperRetractionCheck.serializer(), it.value) }
        return json.encodeToString(JsonObject.serializer(), JsonObject(all))
    }
}
