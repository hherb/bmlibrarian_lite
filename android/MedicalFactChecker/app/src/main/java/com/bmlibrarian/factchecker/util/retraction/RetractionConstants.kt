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

/** Retraction checking's values, as BioMedLit's `BioMedLitConstants` and the desktop's `constants.py` hold them. */
object RetractionConstants {
    /** Crossref's public export of the Retraction Watch database (takes `mailto=`). */
    const val RETRACTION_WATCH_EXPORT_URL = "https://api.labs.crossref.org/data/retractionwatch"

    /**
     * The export is refreshed daily upstream; past five weeks a copy is too
     * old to say "not retracted", so it is no longer consulted.
     */
    const val RETRACTION_WATCH_MAX_AGE_DAYS = 35L

    /**
     * The export only grows; a new copy under 95% of the notices already
     * held is a truncated or partial download, and its missing retractions
     * would read as "consulted, nothing found", so the old copy is kept.
     */
    const val RETRACTION_WATCH_MIN_KEEP_RATIO = 0.95

    /**
     * The export is ~68 MB, so a slow link needs far longer than a lookup;
     * an idle timeout between packets, not one for the whole transfer.
     */
    const val RETRACTION_WATCH_DOWNLOAD_TIMEOUT_SECONDS = 120L

    /**
     * After a download bmlib refused (it shrank, or could not be built), the
     * next is a day later: the same export would be refused again, and it is
     * ~68 MB each time (#647).
     */
    const val RETRACTION_WATCH_REFUSED_BACKOFF_MS = 24L * 60 * 60 * 1000

    /**
     * A decided verdict is reused for a week, then asked again: a new
     * retraction reaches Crossref and the export within days, and a review is
     * often repeated within one. A verdict with a lookup unanswered is never
     * reused.
     */
    const val RETRACTION_CHECK_MAX_AGE_DAYS = 7L

    /** Folder under `Context.noBackupFilesDir` holding the export's index: downloaded again on a new device. */
    const val RETRACTION_FOLDER_NAME = "retraction"

    /** The stored index's file name in [RETRACTION_FOLDER_NAME]. */
    const val RETRACTION_INDEX_FILE_NAME = "retraction_watch.index"

    /** The User-Agent product the export download and Crossref lookups send, before the mailto. */
    const val USER_AGENT_PRODUCT = "BMLibrarianLite/1.0"

    /** Milliseconds in a day. */
    const val MS_PER_DAY = 24L * 60 * 60 * 1000
}
