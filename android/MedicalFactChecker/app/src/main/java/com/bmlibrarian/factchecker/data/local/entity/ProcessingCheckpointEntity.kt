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
import androidx.room.Index
import java.util.Date

/**
 * Room entity for processing checkpoints.
 *
 * Stores intermediate results during document processing (scoring, citation extraction)
 * to enable workflow resumption if the app is killed or crashes.
 *
 * Mirrors iOS ProcessingCheckpoint model for cross-platform consistency.
 *
 * @property sessionId The session this checkpoint belongs to.
 * @property documentId The document being processed.
 * @property step Processing step ("scoring" or "citation").
 * @property resultJson JSON-serialized result data.
 * @property createdAt When this checkpoint was created.
 */
@Entity(
    tableName = "processing_checkpoints",
    primaryKeys = ["session_id", "document_id", "step"],
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["session_id", "step"])
    ]
)
data class ProcessingCheckpointEntity(
    /** ID of the session this checkpoint belongs to. */
    @ColumnInfo(name = "session_id")
    val sessionId: String,

    /** ID of the document being processed. */
    @ColumnInfo(name = "document_id")
    val documentId: String,

    /** Processing step: "scoring" or "citation". */
    @ColumnInfo(name = "step")
    val step: String,

    /** JSON-serialized result data. */
    @ColumnInfo(name = "result_json")
    val resultJson: String,

    /** When this checkpoint was created/updated. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    companion object {
        /** Step identifier for scoring checkpoints. */
        const val STEP_SCORING = "scoring"

        /** Step identifier for citation extraction checkpoints. */
        const val STEP_CITATION = "citation"
    }
}
