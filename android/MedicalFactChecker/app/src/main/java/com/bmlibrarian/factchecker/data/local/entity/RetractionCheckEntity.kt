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

package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.PrimaryKey

/**
 * The latest retraction check of one paper, shared by every session that
 * holds it (the desktop's `retraction_checks` row, keyed as it is).
 *
 * Keyed by paper rather than by document, so what one session learnt serves
 * the next and survives a deleted session (#651). A paper with neither DOI
 * nor PMID has no key and no row.
 *
 * @property paperKey `doi:` and bmlib's Crossref key, else `pmid:` and the
 *   canonical PMID (`RetractionPaper.paperKey`)
 * @property checkJson The check, as `PaperRetractionCheck` JSON
 */
@Entity(tableName = "retraction_checks")
data class RetractionCheckEntity(
    @PrimaryKey
    @ColumnInfo(name = "paper_key")
    val paperKey: String,

    @ColumnInfo(name = "check_json")
    val checkJson: String
)
