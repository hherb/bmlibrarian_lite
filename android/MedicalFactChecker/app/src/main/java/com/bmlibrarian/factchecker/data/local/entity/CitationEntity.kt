package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.ColumnInfo
import androidx.room.Entity
import androidx.room.ForeignKey
import androidx.room.Index
import androidx.room.PrimaryKey
import java.util.Date
import java.util.UUID

/**
 * Room entity for extracted citation passages.
 *
 * Represents a key passage extracted from a document that is relevant
 * to the user's claim. These passages are used in the final evidence report.
 *
 * Mirrors iOS Citation model for cross-platform consistency.
 */
@Entity(
    tableName = "citations",
    foreignKeys = [
        ForeignKey(
            entity = DocumentEntity::class,
            parentColumns = ["id"],
            childColumns = ["document_id"],
            onDelete = ForeignKey.CASCADE
        )
    ],
    indices = [
        Index(value = ["document_id"])
    ]
)
data class CitationEntity(
    /** Unique identifier for this citation. */
    @PrimaryKey
    val id: String = UUID.randomUUID().toString(),

    /** ID of the document this citation was extracted from. */
    @ColumnInfo(name = "document_id")
    val documentId: String,

    /** The extracted passage text. */
    @ColumnInfo(name = "passage")
    val passage: String,

    /** Surrounding context for the passage. */
    @ColumnInfo(name = "context")
    val context: String? = null,

    /** LLM explanation of why this passage is relevant. */
    @ColumnInfo(name = "relevance_explanation")
    val relevanceExplanation: String? = null,

    /** Section of the document where passage was found (e.g., "Methods", "Results"). */
    @ColumnInfo(name = "section")
    val section: String? = null,

    /** When this citation was extracted. */
    @ColumnInfo(name = "created_at")
    val createdAt: Date = Date()
) {
    /**
     * Get a truncated preview of the passage.
     *
     * @param maxLength Maximum length for the preview
     * @return Truncated passage with ellipsis if needed
     */
    fun passagePreview(maxLength: Int = 150): String {
        return if (passage.length <= maxLength) {
            passage
        } else {
            "${passage.take(maxLength - 3)}..."
        }
    }
}
