package com.bmlibrarian.factchecker.data.local.converter

import androidx.room.TypeConverter
import com.bmlibrarian.factchecker.domain.model.SearchProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import java.util.Date

/**
 * Room type converters for complex types.
 *
 * Uses Kotlin Serialization for JSON encoding/decoding of lists,
 * and simple string conversion for enums and dates.
 * This approach is type-safe and efficient.
 */
class Converters {

    /**
     * Json instance configured for Room converter usage.
     * Uses lenient parsing and ignores unknown keys for forward compatibility.
     */
    private val json = Json {
        ignoreUnknownKeys = true
        isLenient = true
        encodeDefaults = true
    }

    // ==================== Date Converters ====================

    /**
     * Convert timestamp to Date.
     *
     * @param value Milliseconds since epoch, or null
     * @return Date instance, or null if input was null
     */
    @TypeConverter
    fun fromTimestamp(value: Long?): Date? = value?.let { Date(it) }

    /**
     * Convert Date to timestamp.
     *
     * @param date Date instance, or null
     * @return Milliseconds since epoch, or null if input was null
     */
    @TypeConverter
    fun dateToTimestamp(date: Date?): Long? = date?.time

    // ==================== String List Converters ====================

    /**
     * Convert List<String> to JSON string for storage.
     *
     * @param value List of strings, or null
     * @return JSON array string, or null if input was null
     */
    @TypeConverter
    fun fromStringList(value: List<String>?): String? {
        return value?.let { json.encodeToString(it) }
    }

    /**
     * Convert JSON string to List<String>.
     *
     * @param value JSON array string, or null
     * @return List of strings, or null if input was null
     */
    @TypeConverter
    fun toStringList(value: String?): List<String>? {
        if (value == null) return null
        return try {
            json.decodeFromString<List<String>>(value)
        } catch (e: Exception) {
            // Return empty list on parse error to avoid crashes
            emptyList()
        }
    }

    // ==================== WorkflowStep Enum Converter ====================

    /**
     * Convert WorkflowStep enum to string for storage.
     *
     * @param step The workflow step enum value
     * @return The enum name as a string
     */
    @TypeConverter
    fun fromWorkflowStep(step: WorkflowStep): String = step.name

    /**
     * Convert string to WorkflowStep enum.
     *
     * @param value The enum name string
     * @return The corresponding WorkflowStep enum value
     */
    @TypeConverter
    fun toWorkflowStep(value: String): WorkflowStep {
        return try {
            WorkflowStep.valueOf(value)
        } catch (e: IllegalArgumentException) {
            // Default to IDLE if unknown value encountered (forward compatibility)
            WorkflowStep.IDLE
        }
    }

    // ==================== Verdict Enum Converter ====================

    /**
     * Convert Verdict enum to string for storage.
     *
     * @param verdict The verdict enum value, or null
     * @return The enum name as a string, or null
     */
    @TypeConverter
    fun fromVerdict(verdict: Verdict?): String? = verdict?.name

    /**
     * Convert string to Verdict enum.
     *
     * @param value The enum name string, or null
     * @return The corresponding Verdict enum value, or null
     */
    @TypeConverter
    fun toVerdict(value: String?): Verdict? {
        if (value == null) return null
        return try {
            Verdict.valueOf(value)
        } catch (e: IllegalArgumentException) {
            // Default to UNCLEAR if unknown value encountered
            Verdict.UNCLEAR
        }
    }

    // ==================== SearchProvider Enum Converter ====================

    /**
     * Convert SearchProvider enum to string for storage.
     *
     * @param provider The search provider enum value
     * @return The enum name as a string
     */
    @TypeConverter
    fun fromSearchProvider(provider: SearchProvider): String = provider.name

    /**
     * Convert string to SearchProvider enum.
     *
     * @param value The enum name string
     * @return The corresponding SearchProvider enum value
     */
    @TypeConverter
    fun toSearchProvider(value: String): SearchProvider {
        return try {
            SearchProvider.valueOf(value)
        } catch (e: IllegalArgumentException) {
            // Default to PUBMED if unknown value encountered
            SearchProvider.PUBMED
        }
    }
}
