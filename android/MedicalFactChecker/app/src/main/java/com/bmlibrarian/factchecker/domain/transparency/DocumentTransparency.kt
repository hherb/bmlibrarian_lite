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

package com.bmlibrarian.factchecker.domain.transparency

import android.util.Log
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity

/** Log tag for reading stored transparency results. */
private const val TAG = "DocumentTransparency"

/** A trailing token of initials in a PubMed author name, e.g. "JA" in "Smith JA". */
private val AUTHOR_INITIALS = Regex("""^[A-Z]{1,3}$""")

/**
 * The document's stored transparency result, or null when there is none.
 *
 * A stored result that no longer decodes is logged and read as null; callers
 * that must tell "never analysed" from "unreadable" test
 * [DocumentEntity.transparencyResultJson] directly.
 */
val DocumentEntity.transparencyResult: TransparencyResult?
    get() {
        val json = transparencyResultJson ?: return null
        return try {
            TransparencyJson.decode(json)
        } catch (e: Exception) {
            Log.e(TAG, "Stored transparency result for document $id failed to decode", e)
            null
        }
    }

/**
 * The article text the transparency analysis may read, or null.
 *
 * Always null on Android for now, deliberately. Conflict-of-interest and
 * data-availability statements are looked for only in this text, and a missing
 * COI statement alone rates a study high, so the text must be the article's
 * body and must still carry its back matter. Neither holds yet:
 * - an abstract-only Europe PMC deposit parses and is stored exactly like an
 *   article, with nothing recording that it has no body (#205), and the
 *   cross-platform contract says such a record must be given no text at all;
 * - the JATS parser drops `<fn-group>`, `<ack>`, `<notes>` and the article-meta
 *   `<funding-group>` — where COI and funding statements usually sit — so a
 *   parsed article would read as having no statement when it has one.
 *
 * Every Android rating is therefore made without the full text and says so
 * ([TransparencyCertainty.LIMITED_NO_FULL_TEXT]). Returning text here before
 * both gaps are closed would turn "not parsed" into "not there".
 */
@Suppress("UnusedReceiverParameter")
val DocumentEntity.analyzableFullText: String?
    get() = null

/**
 * How far this document's transparency rating can be relied on, or null when
 * there is no readable analysis.
 *
 * The result's own record of full-text access when it has one; otherwise the
 * document's: with no analysable text now, there was none to analyse then.
 */
val DocumentEntity.transparencyCertainty: TransparencyCertainty?
    get() {
        val result = transparencyResult ?: return null
        result.fullTextSearched?.let { return TransparencyCertainty.from(it) }
        return if (analyzableFullText == null) {
            TransparencyCertainty.LIMITED_NO_FULL_TEXT
        } else {
            TransparencyCertainty.UNRECORDED
        }
    }

/** The document's PubMed ID, when it has a non-blank one. */
val DocumentEntity.usablePmid: String?
    get() = pmid?.trim()?.takeIf { it.isNotEmpty() }

/** The document's DOI, when it has a non-blank one. */
val DocumentEntity.usableDoi: String?
    get() = doi?.trim()?.takeIf { it.isNotEmpty() }

/** Whether the analysis has an identifier to look the study up by. */
val DocumentEntity.canAnalyzeTransparency: Boolean
    get() = usablePmid != null || usableDoi != null

/**
 * Whether the document needs (re-)analysis: never analysed, unreadable, or
 * analysed by an older analyzer.
 */
val DocumentEntity.needsTransparencyAnalysis: Boolean
    get() = transparencyResultJson == null || transparencyResult?.isStale != false

/**
 * How the report refers to the document, e.g. "Smith et al., 2021".
 *
 * PubMed writes authors as "Surname Initials"; the initials are dropped.
 */
val DocumentEntity.shortReference: String
    get() {
        val first = authors.firstOrNull()?.trim().orEmpty()
        val tokens = first.substringBefore(", ").split(" ").filter { it.isNotEmpty() }
        val surname = when {
            tokens.isEmpty() -> "Unknown"
            tokens.size > 1 && AUTHOR_INITIALS.matches(tokens.last()) -> tokens.dropLast(1).joinToString(" ")
            else -> tokens.joinToString(" ")
        }
        val authorPart = if (authors.size > 1) "$surname et al." else surname
        return "$authorPart, ${publicationYear?.toString() ?: "n.d."}"
    }

/**
 * Metadata for the analysis, answered from what the search already stored.
 *
 * The analysis asks PubMed for a PMID's title, journal, authors, DOI and PMC ID.
 * A document holding that PMID already holds that record — fetched from PubMed,
 * or from Europe PMC's mirror of the same MEDLINE citation — so it is answered
 * here without a second request. Null would mean "PubMed has no such article",
 * which nothing established, so it is answered only for a PMID the document
 * does not hold.
 *
 * @param document The document being analysed.
 * @return A lookup answering for that document's PMID.
 */
fun storedMetadataLookup(document: DocumentEntity): ArticleMetadataLookup =
    ArticleMetadataLookup { pmid ->
        if (pmid != document.usablePmid) {
            null
        } else {
            ArticleMetadata(
                title = document.title,
                journal = document.journal,
                authors = document.authors,
                doi = document.usableDoi,
                pmcid = document.pmcId,
            )
        }
    }

/**
 * Whether this document's high rating is shown as unassessed: every reason for it rests on
 * statements in full text that was not searched. See [TransparencyRiskExplanation.isUnassessed].
 */
val DocumentEntity.transparencyIsUnassessed: Boolean
    get() {
        val result = transparencyResult ?: return false
        return TransparencyRiskExplanation.isUnassessed(result, transparencyCertainty)
    }

/**
 * The documents rated high transparency risk, as a report discusses them.
 *
 * A rating shown as unassessed is not discussed as high risk.
 *
 * Ordered by reference, then title, so a report lists them the same way every time.
 *
 * @param documents A session's documents.
 * @return One entry per document rated high.
 */
fun highRiskTransparencyEntries(documents: List<DocumentEntity>): List<HighRiskTransparencyEntry> =
    documents
        .mapNotNull { document ->
            val result = document.transparencyResult
            if (result?.riskLevel == TransparencyRiskLevel.HIGH && !document.transparencyIsUnassessed) {
                document to result
            } else {
                null
            }
        }
        .sortedWith(compareBy({ it.first.shortReference }, { it.first.title }))
        .map { (document, result) ->
            HighRiskTransparencyEntry(
                reference = document.shortReference,
                citation = listOfNotNull(
                    document.title,
                    document.journal,
                    document.usablePmid?.let { "PMID: $it" } ?: document.usableDoi?.let { "DOI: $it" },
                ).joinToString(". "),
                result = result,
                certainty = document.transparencyCertainty,
            )
        }
