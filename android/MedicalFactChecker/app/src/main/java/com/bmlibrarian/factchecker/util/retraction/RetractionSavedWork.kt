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

/**
 * What a reopened session knows about its papers since its run, worked out
 * from the checks the run used (its snapshot, never rewritten) and each
 * paper's stored row (Swift's `RetractionSavedWork`; the desktop's
 * `rechecked_snapshot` and `changed_since_snapshot`). With one row per paper,
 * that row is the paper's latest check, shared by every session holding it.
 */
object RetractionSavedWork {
    /**
     * The checks a reopened session's line and badges are read from: each the
     * run's, unless the paper's stored row is newer and is not an unchecked one
     * over a decided one. A session whose run recorded none (it predates the
     * check) reads the stored rows alone.
     *
     * @param run The checks the run used, by document id
     * @param stored Each document's paper's stored row, by document id
     * @return The checks, by document id
     */
    fun recheckedChecks(
        run: Map<String, PaperRetractionCheck>,
        stored: Map<String, PaperRetractionCheck>
    ): Map<String, PaperRetractionCheck> {
        if (run.isEmpty()) return stored
        return run.mapValues { (id, check) -> stored[id]?.let { rechecked(check, it) } ?: check }
    }

    /** One paper's check since its run: [stored] when newer than [run] and not an unchecked one over a decided one. */
    fun rechecked(run: PaperRetractionCheck, stored: PaperRetractionCheck): PaperRetractionCheck =
        if (stored.checkedAtMs > run.checkedAtMs && !(stored.isUnchecked && !run.isUnchecked)) stored else run

    /**
     * The cited papers whose status changed for the worse since the run: the
     * latest check is no older than the run's, says retracted or concern, and
     * the run saw another status. A paper the run never checked, or checked
     * without an answer, warns whenever its latest check does: an unchecked
     * check's time is no check time, so an older retraction known elsewhere
     * is still news.
     *
     * @param run The checks the run used, by document id
     * @param latest Each cited paper's latest check, by document id
     * @param cited The documents the report cites, in the order to warn in
     * @return The changed documents' ids, in [cited]'s order
     */
    fun changedSinceRun(
        run: Map<String, PaperRetractionCheck>,
        latest: Map<String, PaperRetractionCheck>,
        cited: List<String>
    ): List<String> = cited.filter { id ->
        val check = latest[id]
        if (check == null || !(check.isRetracted || check.isConcern)) return@filter false
        val seen = run[id]
        seen == null || seen.isUnchecked || (check.checkedAtMs >= seen.checkedAtMs && check.status != seen.status)
    }
}
