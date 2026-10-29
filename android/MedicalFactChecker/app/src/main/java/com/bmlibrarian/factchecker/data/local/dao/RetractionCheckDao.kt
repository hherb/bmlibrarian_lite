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

package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.bmlibrarian.factchecker.data.local.entity.RetractionCheckEntity

/** Each paper's latest retraction check ([RetractionCheckEntity]). */
@Dao
interface RetractionCheckDao {

    /**
     * The stored checks of these papers.
     *
     * @param paperKeys The papers' keys
     * @return A row per key that has one
     */
    @Query("SELECT * FROM retraction_checks WHERE paper_key IN (:paperKeys)")
    suspend fun get(paperKeys: List<String>): List<RetractionCheckEntity>

    /**
     * Store these checks, replacing each paper's row.
     *
     * @param checks The rows to write
     */
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun upsert(checks: List<RetractionCheckEntity>)
}
