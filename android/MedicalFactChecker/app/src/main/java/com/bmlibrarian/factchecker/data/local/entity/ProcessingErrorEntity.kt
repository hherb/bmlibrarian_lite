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
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for processing errors.
 *
 * Tracks errors that occur during document processing (scoring, citation extraction)
 * to enable retry functionality and error reporting.
 *
 * Mirrors iOS processing error model for cross-platform consistency.
 *
 * @property id Unique identifier for this error record.
 * @property sessionId The session this error belongs to.
 * @property documentId The document that failed processing.
 * @property step Processing step that failed ("scoring" or "citation").
 * @property errorType Category of error (network, parse, api, etc).
 * @property errorMessage Detailed error message.
 * @property isRetryable Whether this error can be retried.
 * @property retryCount Number of retry attempts made.
 * @property maxRetries Maximum retry attempts allowed.
 * @property createdAt When this error was recorded.
 * @property lastRetryAt When the last retry was attempted.
 */
@Entity(
    tableName = "processing_errors",
    foreignKeys = [
        ForeignKey(
            entity = SessionEntity::class,
            parentColumns = ["id"],
            childColumns = ["session_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["session_id", "step"]),
        Index(value = ["is_retryable"])
    ]
)
data class ProcessingErrorEntity(
    /** Unique identifier for this error. */
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    /** ID of the session this error belongs to. */
    @ColumnInfo(name = "session_id")
    val sessionId: String,

    /** ID of the document that failed processing. */
    @ColumnInfo(name = "document_id")
    val documentId: String,

    /** Processing step: "scoring" or "citation". */
    @ColumnInfo(name = "step")
    val step: String,

    /** Category of error. */
    @ColumnInfo(name = "error_type")
    val errorType: String,

    /** Detailed error message. */
    @ColumnInfo(name = "error_message")
    val errorMessage: String,

    /** Whether this error can be retried. */
    @ColumnInfo(name = "is_retryable")
    val isRetryable: Boolean = true,

    /** Number of retry attempts made. */
    @ColumnInfo(name = "retry_count")
    val retryCount: Int = 0,

    /** Maximum retry attempts allowed. */
    @ColumnInfo(name = "max_retries")
    val maxRetries: Int = DEFAULT_MAX_RETRIES,

    /** When this error was recorded. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date(),

    /** When the last retry was attempted. */
    @ColumnInfo(name = "last_retry_at")
    val lastRetryAt: Date? = null
) {
    /** Whether more retries are available. */
    val canRetry: Boolean
        get() = isRetryable && retryCount < maxRetries

    companion object {
        /** Default maximum retry attempts for processing errors. */
        const val DEFAULT_MAX_RETRIES = 3

        /** Error type for network errors. */
        const val TYPE_NETWORK = "network"

        /** Error type for API errors (rate limit, auth, etc). */
        const val TYPE_API = "api"

        /** Error type for parse errors. */
        const val TYPE_PARSE = "parse"

        /** Error type for timeout errors. */
        const val TYPE_TIMEOUT = "timeout"

        /** Error type for unknown errors. */
        const val TYPE_UNKNOWN = "unknown"

        /**
         * Determine error type from an exception.
         */
        fun errorTypeFromException(e: Throwable): String {
            val message = e.message?.lowercase() ?: return TYPE_UNKNOWN
            return when {
                message.contains("timeout") -> TYPE_TIMEOUT
                message.contains("network") || message.contains("connection") -> TYPE_NETWORK
                message.contains("parse") || message.contains("json") -> TYPE_PARSE
                message.contains("401") || message.contains("403") ||
                        message.contains("429") || message.contains("rate") -> TYPE_API
                else -> TYPE_UNKNOWN
            }
        }
    }
}
