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

import org.bmlib.ffi.RetractionKind
import org.bmlib.ffi.RetractionLookup
import org.bmlib.ffi.RetractionSource
import org.bmlib.ffi.RetractionStatus

/**
 * The contract's names for bmlib's enums (`retraction_status.json`), the
 * form a check is stored in. Each is a `when`, so a case bmlib adds is a
 * compile error here rather than a name stored as unmapped (#649).
 */
internal object RetractionNames {

    fun name(source: RetractionSource): String = when (source) {
        RetractionSource.RETRACTION_WATCH_EXPORT -> "retraction_watch_export"
        RetractionSource.CROSSREF_RETRACTION_WATCH -> "crossref_retraction_watch"
        RetractionSource.CROSSREF_PUBLISHER -> "crossref_publisher"
        RetractionSource.PUBMED_LABEL -> "pubmed_label"
    }

    fun name(kind: RetractionKind): String = when (kind) {
        RetractionKind.RETRACTION -> "retraction"
        RetractionKind.WITHDRAWAL -> "withdrawal"
        RetractionKind.REMOVAL -> "removal"
        RetractionKind.PARTIAL_RETRACTION -> "partial_retraction"
        RetractionKind.EXPRESSION_OF_CONCERN -> "expression_of_concern"
        RetractionKind.CORRECTION -> "correction"
        RetractionKind.ERRATUM -> "erratum"
        RetractionKind.CORRIGENDUM -> "corrigendum"
        RetractionKind.ADDENDUM -> "addendum"
        RetractionKind.CLARIFICATION -> "clarification"
        RetractionKind.NEW_VERSION -> "new_version"
        RetractionKind.NEW_EDITION -> "new_edition"
        RetractionKind.REINSTATEMENT -> "reinstatement"
        RetractionKind.OTHER -> "other"
    }

    fun name(status: RetractionStatus): String = when (status) {
        RetractionStatus.RETRACTED -> "retracted"
        RetractionStatus.CONCERN -> "concern"
        RetractionStatus.CLEAR -> "clear"
        RetractionStatus.UNCHECKED -> "unchecked"
    }

    fun name(lookup: RetractionLookup): String = when (lookup) {
        RetractionLookup.RETRACTION_WATCH_EXPORT -> "retraction_watch_export"
        RetractionLookup.CROSSREF -> "crossref"
    }

    /** The status [name] names, or null for a name this build does not know. */
    fun status(name: String): RetractionStatus? = RetractionStatus.entries.firstOrNull { name(it) == name }

    /** The source [name] names, or null for a name this build does not know. */
    fun source(name: String): RetractionSource? = RetractionSource.entries.firstOrNull { name(it) == name }
}
