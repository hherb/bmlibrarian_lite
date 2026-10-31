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

import java.util.Locale
import org.bmlib.ffi.RetractionLookup

/**
 * What the reader is told about retraction checks, worded as the desktop's
 * `retraction_text.py` and Swift's `RetractionText` word it. The saved-work
 * warning and *Check again*'s sentences come with PR 5b; [runNotice] and
 * [PROGRESS_MESSAGE] are Android's own.
 */
object RetractionText {
    /** Title of the papers a run left out, in the report and on screen. */
    const val LEFT_OUT_TITLE = "Left out as retracted"

    /** Heading of the report's section for the papers a run left out. */
    const val LEFT_OUT_HEADING = "## $LEFT_OUT_TITLE"

    /** Shown while the documents about to be scored are checked for retraction. */
    const val PROGRESS_MESSAGE = "Checking retraction status…"

    private const val FAILED_CAUSE = "the check failed"
    /** Replaces the desktop's `bmll retractions-update` hint: the app downloads the data itself. */
    private const val EXPORT_CAUSE = "the Retraction Watch data could not be used (no up-to-date copy is on this device)"
    private const val EXPORT_NOTICE_CAUSE = "a Retraction Watch notice could not be read"
    private const val NO_IDS_CAUSE = "no DOI or PMID"
    private const val NO_DOI_CAUSE = "no DOI, which Crossref needs"
    private const val CROSSREF_SILENT_CAUSE = "Crossref had no usable answer for the DOI"
    private const val CANCELLED_CAUSE = "the check was cancelled before reaching them"
    private const val PUBMED_LABEL = " (PubMed's label)"
    private const val CONCERN_INDENT = "    "
    private const val CROSSREF = "crossref"
    private val SOURCE_NAMES = mapOf("retraction_watch_export" to "Retraction Watch", CROSSREF to "Crossref")

    /** How the report's notice opens (the desktop's `_NOTICE_OPENING`). */
    internal const val NOTICE_OPENING = "> **Retraction check:** "

    /**
     * Why the kept papers are unchecked, each cause once, in the desktop's
     * order: the check failed, the Retraction Watch data (absent, then a
     * notice unreadable), Crossref (its distinct failures joined, then no
     * DOI, then no usable answer), no identifiers, cancelled.
     *
     * @param papers Each kept paper and its check; null when the check never reached it
     * @param failed The papers whose check failed at run time
     * @return The causes; empty when no paper is unchecked
     */
    fun uncheckedCauses(papers: List<Pair<RetractionPaper, PaperRetractionCheck?>>, failed: Set<RetractionPaper>): List<String> {
        val found = mutableSetOf<String>()
        val crossref = mutableListOf<String>()
        for ((paper, check) in papers) {
            if (paper in failed) {
                if (check?.isUnchecked != false) found += FAILED_CAUSE
                continue
            }
            if (check == null) {
                found += CANCELLED_CAUSE
                continue
            }
            if (!check.isUnchecked) continue
            val doiKey = paper.doi?.let(RetractionChecker::doiKey)
            if (doiKey == null && paper.canonicalPmid == null) {
                found += NO_IDS_CAUSE
                continue
            }
            if (check.leftUnanswered(RetractionLookup.RETRACTION_WATCH_EXPORT)) {
                found += if (check.exportDataAsOf == null) EXPORT_CAUSE else EXPORT_NOTICE_CAUSE
            }
            if (check.leftUnanswered(RetractionLookup.CROSSREF)) {
                val failure = check.crossrefFailure
                if (failure != null) {
                    if (failure !in crossref) crossref += failure
                } else {
                    found += if (doiKey == null) NO_DOI_CAUSE else CROSSREF_SILENT_CAUSE
                }
            }
        }
        val causes = listOf(FAILED_CAUSE, EXPORT_CAUSE, EXPORT_NOTICE_CAUSE).filter { it in found }.toMutableList()
        if (crossref.isNotEmpty()) causes += "Crossref could not be used (${crossref.joinToString(", ")})"
        return causes + listOf(NO_DOI_CAUSE, CROSSREF_SILENT_CAUSE, NO_IDS_CAUSE, CANCELLED_CAUSE).filter { it in found }
    }

    /**
     * A run's summary clause, naming why papers are unchecked.
     *
     * @param excluded Papers left out as retracted
     * @param unchecked Kept papers whose status could not be checked
     * @param causes [uncheckedCauses]; empty for a restored snapshot, which records none
     * @return The clause; null when both counts are 0
     */
    fun runSummaryClause(excluded: Int, unchecked: Int, causes: List<String>): String? {
        val parts = mutableListOf<String>()
        if (excluded > 0) parts += "${grouped(excluded)} ${if (excluded == 1) "retracted paper" else "retracted papers"} left out"
        if (unchecked > 0) {
            val owner = if (unchecked == 1) "1 paper's" else "${grouped(unchecked)} papers'"
            val clause = "$owner retraction status could not be checked"
            parts += if (causes.isEmpty()) clause else "$clause: ${causes.joinToString("; ")}"
        }
        return if (parts.isEmpty()) null else parts.joinToString("; ")
    }

    /**
     * One paper's status, for a detail view: the deciding notice's date and
     * DOI (or "(PubMed's label)"), the unanswered sources, or "No retraction
     * found"; then the Retraction Watch data's day when it was consulted.
     */
    fun paperStatusLine(check: PaperRetractionCheck): String {
        val line = StringBuilder()
        val deciding = check.deciding
        if (check.isRetracted || check.isConcern) {
            line.append(if (check.isRetracted) "Retracted" else "Expression of concern")
            // the label, not a notice: a notice without a DOI is still Retraction Watch's or Crossref's
            if (deciding == null || check.isDecidedByLabel) {
                line.append(PUBMED_LABEL)
            } else {
                deciding.date?.takeIf { it.isNotEmpty() }?.let { line.append(if (check.isRetracted) " on $it" else ", $it") }
                deciding.noticeDoi?.takeIf { it.isNotEmpty() }?.let { line.append(" (notice $it)") }
            }
        } else if (check.isUnchecked) {
            val names = check.unanswered.map { lookup ->
                val name = SOURCE_NAMES[lookup] ?: lookup
                val failure = check.crossrefFailure
                if (lookup == CROSSREF && failure != null) "$name ($failure)" else name
            }
            line.append("Retraction status not checked")
            if (names.isNotEmpty()) line.append(": ").append(names.joinToString(", "))
        } else {
            line.append("No retraction found")
        }
        check.exportDataAsOf?.let { line.append("; Retraction Watch data as of $it") }
        return line.toString()
    }

    /** When the status was checked (the UTC date), or that it never was. */
    fun checkedOnLine(atMs: Long?): String =
        if (atMs == null) "Retraction status never checked" else "Retraction status checked ${RetractionIndexStore.today(atMs)}"

    /**
     * The report's methods line: when the run's status was checked and how
     * many kept papers were not. A run that held papers and decided none says
     * it could not check, never a date.
     *
     * @param checkedAtMs The oldest check time among decided papers, or null
     * @param notChecked Kept papers that could not be checked
     * @param heldPapers Whether the run held any paper to check
     */
    fun methodsLine(checkedAtMs: Long?, notChecked: Int, heldPapers: Boolean): String {
        if (checkedAtMs == null) return if (heldPapers) "Retraction status could not be checked" else checkedOnLine(null)
        val line = checkedOnLine(checkedAtMs)
        if (notChecked == 0) return line
        return "$line; ${if (notChecked == 1) "1 paper" else "${grouped(notChecked)} papers"} could not be checked"
    }

    /** The report's opening notice (the desktop's `format_retraction_notice`): "> **Retraction check:** <clause>.". */
    fun reportNotice(clause: String): String = "$NOTICE_OPENING$clause."

    /** The run's notice on the fact-check screen: "Retraction check: <clause>.". */
    fun runNotice(clause: String): String = "Retraction check: $clause."

    /**
     * A session's line (the desktop's `saved_work_line`): when its decided
     * papers were checked (the oldest), and how many were not; "could not be
     * checked" when none is decided, "never checked" for none.
     *
     * @param checks The session's checks
     * @param causes [uncheckedCauses] of the unchecked papers; added only when a paper is unchecked
     */
    fun savedWorkLine(checks: Collection<PaperRetractionCheck>, causes: List<String> = emptyList()): String {
        val line = methodsLine(
            checkedAtMs = checks.filterNot { it.isUnchecked }.minOfOrNull { it.checkedAtMs },
            notChecked = checks.count { it.isUnchecked },
            heldPapers = checks.isNotEmpty()
        )
        // the causes follow the not-checked count, as they follow the run notice's
        return if (causes.isEmpty() || checks.none { it.isUnchecked }) line else "$line: ${causes.joinToString("; ")}"
    }

    /** The button that checks a reopened session's papers again. */
    const val CHECK_AGAIN_LABEL = "Check again"

    /** The saved-work line while *Check again* runs. */
    const val CHECKING_AGAIN_LINE = "Checking retraction status…"

    /** Added to the saved-work line when *Check again* failed. */
    const val CHECK_AGAIN_FAILED = "; it could not be checked again, so this is still the run's record"

    /** Added to the saved-work line when the stored checks could not be read. */
    const val STORED_CHECKS_UNREAD = "; later checks could not be read"

    /**
     * A restored session's saved-work line, or a document's detail status, when
     * its retraction status could not be read at all (Android only so far):
     * never "never checked", since not knowing is not absence.
     */
    const val STATUS_UNREAD = "Retraction status could not be read"

    /** Added to the saved-work line when *Check again*'s answers could not be saved. */
    const val CHECK_AGAIN_NOT_SAVED = "; the new status could not be saved with this run"

    /** *Check again*'s note for decided papers no source answered this time, whose record stays; "" for none. */
    fun notCheckedAgainClause(count: Int): String =
        if (count == 0) "" else "; ${if (count == 1) "1 paper" else "${grouped(count)} papers"} could not be checked again"

    /**
     * Warns that papers a saved report cites are now retracted or under
     * concern (the desktop's `saved_work_warning`), one paper per line. It
     * suggests re-running the question; the report is not rewritten.
     *
     * @param changed Each paper's title and latest check
     * @return The warning; null when nothing changed
     */
    fun savedWorkWarning(changed: List<Pair<String, PaperRetractionCheck>>): String? {
        if (changed.isEmpty()) return null
        val subject = if (changed.size == 1) "1 paper this report cites has" else "${grouped(changed.size)} papers this report cites have"
        val papers = changed.map { (title, check) ->
            "• ${collapsedWhitespace(title)}: ${paperStatusLine(check)}"
        }
        return (listOf("Since this report was written, $subject a retraction warning:") + papers +
            "The report has not been changed; re-run the question to bring it up to date.").joinToString("\n")
    }

    /**
     * A left-out paper's line (the desktop's `excluded_line`): why the run
     * left it out, then its status now when that differs.
     *
     * @param runCheck The check the run used
     * @param current The latest check
     */
    fun excludedLine(runCheck: PaperRetractionCheck, current: PaperRetractionCheck): String {
        val line = "Excluded: retracted. ${paperStatusLine(runCheck)}"
        val now = paperStatusLine(current)
        return if (now == paperStatusLine(runCheck)) line else "$line. Checked again: $now"
    }

    /**
     * One entry of the left-out section: "- <title>. Retracted <date>; notice <doi>",
     * or "Retracted (PubMed's label)". The title is escaped for markdown.
     */
    fun leftOutEntry(title: String, check: PaperRetractionCheck): String {
        val line = StringBuilder("- ${plainTitle(title)}. Retracted")
        val deciding = check.deciding
        if (deciding == null || check.isDecidedByLabel) {
            line.append(PUBMED_LABEL)
        } else {
            deciding.date?.takeIf { it.isNotEmpty() }?.let { line.append(" $it") }
            deciding.noticeDoi?.takeIf { it.isNotEmpty() }?.let { line.append("; notice $it") }
        }
        return line.toString()
    }

    /** The caveat under a cited paper that stands under an expression of concern. */
    fun concernCaveat(check: PaperRetractionCheck): String {
        val detail = listOfNotNull(check.deciding?.date, check.deciding?.noticeDoi?.let { "notice $it" })
            .filter { it.isNotEmpty() }
            .joinToString(", ")
        return "${CONCERN_INDENT}⚠️ Expression of concern" + if (detail.isEmpty()) "" else " ($detail)"
    }

    /** A title safe inside one markdown line: whitespace collapsed, specials escaped, by code point (#649). */
    internal fun plainTitle(title: String): String {
        val out = StringBuilder()
        collapsedWhitespace(title).codePoints().forEach { point ->
            if (point < 0x80 && point.toChar() in MARKDOWN_SPECIALS) out.append('\\')
            out.appendCodePoint(point)
        }
        return out.toString()
    }

    /** Runs of whitespace as one space, trimmed. */
    private fun collapsedWhitespace(text: String): String =
        // Char.isWhitespace, not a regex \s: ASCII-only on the JVM, Unicode on Android
        text.map { if (it.isWhitespace()) ' ' else it }.joinToString("").split(' ').filter { it.isNotEmpty() }.joinToString(" ")

    private const val MARKDOWN_SPECIALS = "\\`*_[]<>"

    /** The desktop's `{n:,}`. */
    private fun grouped(count: Int): String = String.format(Locale.US, "%,d", count)
}
