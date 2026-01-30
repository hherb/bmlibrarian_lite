# Phase 4: Error Queue UI and Result Re-ordering (Android)

## Objective

Provide a polished error display with persistence, categorization, and accessibility support. Allow users to re-order results after processing completes.

## Phase Integration Notes

Phase 4 builds on all previous phases:

### Dependencies from Phase 1 (Parallel Requests)

- **`ScoringResult`**: Sealed class with `Success` and `Error` variants. Phase 4 displays `Error` results in the queue.
- **`ParallelScoringUseCase`**: Errors from concurrent requests feed into the error queue.

### Dependencies from Phase 2 (Checkpointing)

- **`CheckpointRepository`**: Used for error persistence. Errors can be saved as failed checkpoints.
- **`ScoringCheckpoint`**: Data class extended to include error information.
- Progress events from checkpointing flow through to error handling.

### Dependencies from Phase 3 (Cancellation)

- **`CancellableScoringUseCase`**: Cancellation may leave documents in an error state.
- **`ScoringEvent.Cancelled`**: When processing is cancelled, any accumulated errors should be preserved.

### Key Integration Points

| Component | Phase | Integration |
|-----------|-------|-------------|
| `ScoringResult.Error` | 1 | Source of error data |
| `CheckpointRepository` | 2 | Persistence for errors |
| `ScoringEvent` | 3 | Error propagation |
| `CancellableScoringUseCase` | 3 | Errors during cancellation |

## 4.1 Error Types and Categorization

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/model/ErrorCategory.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.model

import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.*
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.graphics.vector.ImageVector

/**
 * Categories of errors that can occur during document processing.
 */
enum class ErrorCategory(
    val displayName: String,
    val icon: ImageVector,
    val color: Color
) {
    NETWORK(
        displayName = "Network",
        icon = Icons.Default.WifiOff,
        color = Color(0xFFFF9800)  // Orange
    ),
    LLM(
        displayName = "LLM",
        icon = Icons.Default.Psychology,
        color = Color(0xFF9C27B0)  // Purple
    ),
    PARSING(
        displayName = "Parsing",
        icon = Icons.Default.Description,
        color = Color(0xFF2196F3)  // Blue
    ),
    TIMEOUT(
        displayName = "Timeout",
        icon = Icons.Default.Timer,
        color = Color(0xFFFFC107)  // Amber
    ),
    UNKNOWN(
        displayName = "Unknown",
        icon = Icons.Default.Help,
        color = Color(0xFF9E9E9E)  // Gray
    );

    companion object {
        /**
         * Categorize an error based on its message.
         */
        fun fromMessage(message: String): ErrorCategory {
            val lowercased = message.lowercase()

            return when {
                lowercased.containsAny("network", "connection", "offline", "internet", "unreachable", "socket") ->
                    NETWORK
                lowercased.containsAny("timeout", "timed out") ->
                    TIMEOUT
                lowercased.containsAny("parse", "decode", "json", "xml", "invalid format", "malformed") ->
                    PARSING
                lowercased.containsAny("llm", "model", "api key", "rate limit", "token", "openai", "anthropic", "claude") ->
                    LLM
                else -> UNKNOWN
            }
        }

        /**
         * Categorize an error from an exception.
         */
        fun fromException(exception: Throwable): ErrorCategory {
            return when {
                exception is java.net.SocketTimeoutException -> TIMEOUT
                exception is java.net.UnknownHostException -> NETWORK
                exception is java.net.ConnectException -> NETWORK
                exception is java.io.IOException && exception.message?.contains("timeout") == true -> TIMEOUT
                exception is kotlinx.serialization.SerializationException -> PARSING
                else -> fromMessage(exception.message ?: "")
            }
        }

        private fun String.containsAny(vararg keywords: String): Boolean =
            keywords.any { this.contains(it) }
    }
}
```

## 4.2 Error Entry Model with Room Persistence

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/entity/ErrorEntryEntity.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.Entity
import androidx.room.Index
import androidx.room.PrimaryKey
import com.bmlibrarian.factchecker.domain.model.ErrorCategory
import java.time.Instant

/**
 * Room entity for persisted error entries.
 */
@Entity(
    tableName = "error_entries",
    indices = [
        Index(value = ["sessionId"]),
        Index(value = ["sessionId", "pmid"])
    ]
)
data class ErrorEntryEntity(
    @PrimaryKey(autoGenerate = true)
    val id: Long = 0,
    val pmid: String,
    val step: String,
    val message: String,
    val category: String,  // ErrorCategory.name
    val timestamp: Instant,
    val sessionId: String,
    val retryCount: Int = 0
) {
    fun toErrorEntry(): ErrorEntry = ErrorEntry(
        id = id,
        pmid = pmid,
        step = step,
        message = message,
        category = ErrorCategory.valueOf(category),
        timestamp = timestamp,
        sessionId = sessionId,
        retryCount = retryCount
    )
}

/**
 * Domain model for error entries.
 */
data class ErrorEntry(
    val id: Long = 0,
    val pmid: String,
    val step: String,
    val message: String,
    val category: ErrorCategory,
    val timestamp: Instant = Instant.now(),
    val sessionId: String = "",
    val retryCount: Int = 0
) {
    fun toEntity(): ErrorEntryEntity = ErrorEntryEntity(
        id = id,
        pmid = pmid,
        step = step,
        message = message,
        category = category.name,
        timestamp = timestamp,
        sessionId = sessionId,
        retryCount = retryCount
    )

    companion object {
        /**
         * Create an ErrorEntry from an error message with automatic categorization.
         */
        fun fromMessage(
            pmid: String,
            step: String,
            message: String,
            sessionId: String = ""
        ): ErrorEntry = ErrorEntry(
            pmid = pmid,
            step = step,
            message = message,
            category = ErrorCategory.fromMessage(message),
            sessionId = sessionId
        )

        /**
         * Create an ErrorEntry from an exception with automatic categorization.
         */
        fun fromException(
            pmid: String,
            step: String,
            exception: Throwable,
            sessionId: String = ""
        ): ErrorEntry = ErrorEntry(
            pmid = pmid,
            step = step,
            message = exception.message ?: "Unknown error",
            category = ErrorCategory.fromException(exception),
            sessionId = sessionId
        )
    }
}
```

## 4.3 Error Entry DAO

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/dao/ErrorEntryDao.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.*
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntryEntity
import kotlinx.coroutines.flow.Flow

@Dao
interface ErrorEntryDao {

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insert(error: ErrorEntryEntity): Long

    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun insertAll(errors: List<ErrorEntryEntity>)

    @Query("SELECT * FROM error_entries WHERE sessionId = :sessionId ORDER BY timestamp DESC")
    fun getErrorsForSession(sessionId: String): Flow<List<ErrorEntryEntity>>

    @Query("SELECT * FROM error_entries WHERE sessionId = :sessionId ORDER BY timestamp DESC")
    suspend fun getErrorsForSessionOnce(sessionId: String): List<ErrorEntryEntity>

    @Query("SELECT * FROM error_entries WHERE sessionId = :sessionId AND category = :category ORDER BY timestamp DESC")
    fun getErrorsByCategory(sessionId: String, category: String): Flow<List<ErrorEntryEntity>>

    @Query("SELECT COUNT(*) FROM error_entries WHERE sessionId = :sessionId")
    suspend fun getErrorCount(sessionId: String): Int

    @Query("SELECT category, COUNT(*) as count FROM error_entries WHERE sessionId = :sessionId GROUP BY category")
    suspend fun getErrorCountsByCategory(sessionId: String): List<CategoryCount>

    @Query("UPDATE error_entries SET retryCount = retryCount + 1 WHERE sessionId = :sessionId AND pmid IN (:pmids)")
    suspend fun incrementRetryCount(sessionId: String, pmids: List<String>)

    @Query("DELETE FROM error_entries WHERE sessionId = :sessionId AND pmid IN (:pmids)")
    suspend fun deleteErrors(sessionId: String, pmids: List<String>)

    @Query("DELETE FROM error_entries WHERE sessionId = :sessionId")
    suspend fun clearSession(sessionId: String)

    @Delete
    suspend fun delete(error: ErrorEntryEntity)
}

/**
 * Data class for category count query results.
 */
data class CategoryCount(
    val category: String,
    val count: Int
)
```

## 4.4 Error Repository

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/repository/ErrorRepository.kt`

```kotlin
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.CategoryCount
import com.bmlibrarian.factchecker.data.local.dao.ErrorEntryDao
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntry
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntryEntity
import com.bmlibrarian.factchecker.domain.model.ErrorCategory
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.map
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Repository for managing error entries.
 *
 * Provides persistence and retrieval of processing errors
 * with support for reactive updates via Flow.
 */
@Singleton
class ErrorRepository @Inject constructor(
    private val errorEntryDao: ErrorEntryDao
) {
    /**
     * Save an error to persistent storage.
     */
    suspend fun saveError(error: ErrorEntry): Long {
        return errorEntryDao.insert(error.toEntity())
    }

    /**
     * Save multiple errors.
     */
    suspend fun saveErrors(errors: List<ErrorEntry>) {
        errorEntryDao.insertAll(errors.map { it.toEntity() })
    }

    /**
     * Get all errors for a session as a Flow.
     */
    fun getErrors(sessionId: String): Flow<List<ErrorEntry>> {
        return errorEntryDao.getErrorsForSession(sessionId)
            .map { entities -> entities.map { it.toErrorEntry() } }
    }

    /**
     * Get all errors for a session (one-shot).
     */
    suspend fun getErrorsOnce(sessionId: String): List<ErrorEntry> {
        return errorEntryDao.getErrorsForSessionOnce(sessionId)
            .map { it.toErrorEntry() }
    }

    /**
     * Get errors filtered by category.
     */
    fun getErrorsByCategory(sessionId: String, category: ErrorCategory): Flow<List<ErrorEntry>> {
        return errorEntryDao.getErrorsByCategory(sessionId, category.name)
            .map { entities -> entities.map { it.toErrorEntry() } }
    }

    /**
     * Get error count for a session.
     */
    suspend fun getErrorCount(sessionId: String): Int {
        return errorEntryDao.getErrorCount(sessionId)
    }

    /**
     * Increment retry count for specific PMIDs.
     */
    suspend fun incrementRetryCount(sessionId: String, pmids: List<String>) {
        errorEntryDao.incrementRetryCount(sessionId, pmids)
    }

    /**
     * Remove errors for successfully retried PMIDs.
     */
    suspend fun removeErrors(sessionId: String, pmids: List<String>) {
        errorEntryDao.deleteErrors(sessionId, pmids)
    }

    /**
     * Clear all errors for a session.
     */
    suspend fun clearSession(sessionId: String) {
        errorEntryDao.clearSession(sessionId)
    }
}
```

## 4.5 Error Queue Composable with Accessibility

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/components/ErrorQueueView.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.components

import androidx.compose.animation.AnimatedVisibility
import androidx.compose.animation.expandVertically
import androidx.compose.animation.shrinkVertically
import androidx.compose.foundation.BorderStroke
import androidx.compose.foundation.background
import androidx.compose.foundation.clickable
import androidx.compose.foundation.horizontalScroll
import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.KeyboardArrowDown
import androidx.compose.material.icons.filled.KeyboardArrowUp
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntry
import com.bmlibrarian.factchecker.domain.model.ErrorCategory

@Composable
fun ErrorQueueView(
    errors: List<ErrorEntry>,
    onRetry: (List<String>) -> Unit,
    onClear: () -> Unit,
    modifier: Modifier = Modifier
) {
    if (errors.isEmpty()) return

    var isExpanded by remember { mutableStateOf(false) }
    var selectedCategory by remember { mutableStateOf<ErrorCategory?>(null) }

    val filteredErrors = remember(errors, selectedCategory) {
        selectedCategory?.let { category ->
            errors.filter { it.category == category }
        } ?: errors
    }

    val errorCountsByCategory = remember(errors) {
        errors.groupingBy { it.category }.eachCount()
    }

    Card(
        modifier = modifier
            .fillMaxWidth()
            .semantics {
                contentDescription = "Error queue with ${errors.size} errors"
            },
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.errorContainer.copy(alpha = 0.3f)
        )
    ) {
        Column {
            // Header
            ErrorQueueHeader(
                errorCount = errors.size,
                isExpanded = isExpanded,
                onExpandToggle = { isExpanded = !isExpanded },
                onRetry = { onRetry(errors.map { it.pmid }) },
                onClear = onClear
            )

            // Category filters
            AnimatedVisibility(
                visible = isExpanded,
                enter = expandVertically(),
                exit = shrinkVertically()
            ) {
                Column {
                    CategoryFilterRow(
                        totalCount = errors.size,
                        countsByCategory = errorCountsByCategory,
                        selectedCategory = selectedCategory,
                        onCategorySelected = { selectedCategory = it }
                    )

                    // Error list
                    LazyColumn(
                        modifier = Modifier
                            .fillMaxWidth()
                            .heightIn(max = 200.dp)
                            .padding(horizontal = 16.dp, vertical = 8.dp),
                        verticalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        items(filteredErrors, key = { it.id }) { error ->
                            ErrorCard(error = error)
                        }
                    }
                }
            }
        }
    }
}

@Composable
private fun ErrorQueueHeader(
    errorCount: Int,
    isExpanded: Boolean,
    onExpandToggle: () -> Unit,
    onRetry: () -> Unit,
    onClear: () -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .clickable(
                onClickLabel = if (isExpanded) "Collapse error list" else "Expand error list"
            ) { onExpandToggle() }
            .padding(16.dp)
            .semantics { heading() },
        verticalAlignment = Alignment.CenterVertically
    ) {
        Icon(
            imageVector = Icons.Default.Warning,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.error
        )
        Spacer(modifier = Modifier.width(8.dp))
        Text(
            text = "Errors ($errorCount)",
            style = MaterialTheme.typography.titleMedium,
            color = MaterialTheme.colorScheme.error,
            modifier = Modifier.semantics {
                contentDescription = "$errorCount errors occurred during processing"
            }
        )
        Spacer(modifier = Modifier.weight(1f))

        TextButton(
            onClick = onRetry,
            modifier = Modifier.semantics {
                contentDescription = "Retry all failed documents"
            }
        ) {
            Text("Retry All")
        }
        TextButton(
            onClick = onClear,
            modifier = Modifier.semantics {
                contentDescription = "Clear all errors"
            }
        ) {
            Text("Clear")
        }
        Icon(
            imageVector = if (isExpanded) Icons.Default.KeyboardArrowUp
                          else Icons.Default.KeyboardArrowDown,
            contentDescription = if (isExpanded) "Collapse" else "Expand"
        )
    }
}

@Composable
private fun CategoryFilterRow(
    totalCount: Int,
    countsByCategory: Map<ErrorCategory, Int>,
    selectedCategory: ErrorCategory?,
    onCategorySelected: (ErrorCategory?) -> Unit
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .horizontalScroll(rememberScrollState())
            .padding(horizontal = 16.dp, vertical = 8.dp),
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // "All" chip
        CategoryFilterChip(
            label = "All",
            count = totalCount,
            isSelected = selectedCategory == null,
            color = MaterialTheme.colorScheme.outline,
            onClick = { onCategorySelected(null) }
        )

        // Category chips
        ErrorCategory.entries.forEach { category ->
            val count = countsByCategory[category] ?: 0
            if (count > 0) {
                CategoryFilterChip(
                    label = category.displayName,
                    count = count,
                    isSelected = selectedCategory == category,
                    color = category.color,
                    onClick = { onCategorySelected(category) }
                )
            }
        }
    }
}

@Composable
private fun CategoryFilterChip(
    label: String,
    count: Int,
    isSelected: Boolean,
    color: androidx.compose.ui.graphics.Color,
    onClick: () -> Unit
) {
    FilterChip(
        selected = isSelected,
        onClick = onClick,
        label = {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Text(label)
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    "($count)",
                    style = MaterialTheme.typography.labelSmall
                )
            }
        },
        colors = FilterChipDefaults.filterChipColors(
            selectedContainerColor = color.copy(alpha = 0.2f),
            selectedLabelColor = color
        ),
        border = if (isSelected) BorderStroke(1.dp, color) else null,
        modifier = Modifier.semantics {
            contentDescription = "$label errors: $count. ${if (isSelected) "Selected" else "Not selected"}"
        }
    )
}

@Composable
private fun ErrorCard(error: ErrorEntry) {
    Surface(
        modifier = Modifier
            .fillMaxWidth()
            .semantics {
                contentDescription = "Error for PMID ${error.pmid}, ${error.category.displayName} error during ${error.step}: ${error.message}"
            },
        shape = RoundedCornerShape(8.dp),
        color = MaterialTheme.colorScheme.surface,
        border = BorderStroke(1.dp, MaterialTheme.colorScheme.error.copy(alpha = 0.3f))
    ) {
        Column(
            modifier = Modifier.padding(12.dp)
        ) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = error.category.icon,
                    contentDescription = null,
                    tint = error.category.color,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "PMID: ${error.pmid}",
                    style = MaterialTheme.typography.labelMedium,
                    fontWeight = FontWeight.Bold
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(
                    text = "(${error.step})",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
                Spacer(modifier = Modifier.weight(1f))
                Surface(
                    shape = RoundedCornerShape(4.dp),
                    color = error.category.color.copy(alpha = 0.2f)
                ) {
                    Text(
                        text = error.category.displayName,
                        style = MaterialTheme.typography.labelSmall,
                        color = error.category.color,
                        modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp)
                    )
                }
            }
            Spacer(modifier = Modifier.height(4.dp))
            Text(
                text = error.message,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant,
                maxLines = 2
            )
            if (error.retryCount > 0) {
                Spacer(modifier = Modifier.height(4.dp))
                Text(
                    text = "Retry attempts: ${error.retryCount}",
                    style = MaterialTheme.typography.labelSmall,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }
    }
}
```

## 4.6 Sorting Controls with Accessibility

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/components/SortingControls.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.material3.MenuAnchorType
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp

/**
 * Sort options for document results.
 *
 * Each option includes a display label and an accessibility description
 * for screen readers.
 */
enum class SortOption(
    val label: String,
    val accessibilityDescription: String
) {
    SCORE_HIGH_TO_LOW(
        "Score (High to Low)",
        "Sort by score, highest first"
    ),
    SCORE_LOW_TO_HIGH(
        "Score (Low to High)",
        "Sort by score, lowest first"
    ),
    TITLE_AZ(
        "Title (A-Z)",
        "Sort by title, A to Z"
    ),
    TITLE_ZA(
        "Title (Z-A)",
        "Sort by title, Z to A"
    ),
    YEAR_NEWEST(
        "Year (Newest First)",
        "Sort by year, newest first"
    ),
    YEAR_OLDEST(
        "Year (Oldest First)",
        "Sort by year, oldest first"
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun SortingControls(
    selectedSort: SortOption,
    onSortSelected: (SortOption) -> Unit,
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }

    Row(
        modifier = modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Text(
            text = "Sort by:",
            style = MaterialTheme.typography.bodyMedium,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )
        Spacer(modifier = Modifier.width(8.dp))

        ExposedDropdownMenuBox(
            expanded = expanded,
            onExpandedChange = { expanded = !expanded },
            modifier = Modifier.semantics {
                contentDescription = "Sort order: ${selectedSort.accessibilityDescription}"
            }
        ) {
            OutlinedTextField(
                value = selectedSort.label,
                onValueChange = {},
                readOnly = true,
                trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
                modifier = Modifier
                    .menuAnchor(MenuAnchorType.PrimaryNotEditable, enabled = true)
                    .width(200.dp),
                textStyle = MaterialTheme.typography.bodyMedium
            )

            ExposedDropdownMenu(
                expanded = expanded,
                onDismissRequest = { expanded = false }
            ) {
                SortOption.entries.forEach { option ->
                    DropdownMenuItem(
                        text = { Text(option.label) },
                        onClick = {
                            onSortSelected(option)
                            expanded = false
                        },
                        modifier = Modifier.semantics {
                            contentDescription = option.accessibilityDescription
                        }
                    )
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))
    }
}

/**
 * Interface for sortable documents.
 *
 * Implement this in your Document model to enable sorting.
 */
interface SortableDocument {
    val score: Int?
    val title: String?
    val year: Int?
    val pmid: String?
}

/**
 * Extension function to sort documents by the selected option.
 *
 * @param option The sort option to apply.
 * @return Sorted list of documents.
 */
fun <T : SortableDocument> List<T>.sortedBy(option: SortOption): List<T> {
    return when (option) {
        SortOption.SCORE_HIGH_TO_LOW -> sortedByDescending { it.score ?: 0 }
        SortOption.SCORE_LOW_TO_HIGH -> sortedBy { it.score ?: 0 }
        SortOption.TITLE_AZ -> sortedBy { (it.title ?: "").lowercase() }
        SortOption.TITLE_ZA -> sortedByDescending { (it.title ?: "").lowercase() }
        SortOption.YEAR_NEWEST -> sortedByDescending { it.year ?: 0 }
        SortOption.YEAR_OLDEST -> sortedBy { it.year ?: 0 }
    }
}
```

## 4.7 Scored Documents Screen Integration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/ScoredDocumentsScreen.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.factcheck

import androidx.compose.foundation.layout.*
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Error
import androidx.compose.material3.*
import androidx.compose.runtime.*
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.contentDescription
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.unit.dp
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntry
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.ui.components.*

@Composable
fun ScoredDocumentsScreen(
    documents: List<Document>,
    errors: List<ErrorEntry>,
    onRetry: (List<String>) -> Unit,
    onClearErrors: () -> Unit,
    modifier: Modifier = Modifier
) {
    var sortOption by remember { mutableStateOf(SortOption.SCORE_HIGH_TO_LOW) }

    val sortedDocuments = remember(documents, sortOption) {
        documents.sortedBy(sortOption)
    }

    val successCount = documents.count { it.score != null }
    val failedCount = errors.size

    Column(
        modifier = modifier
            .fillMaxSize()
            .semantics {
                contentDescription = "Scored documents: $successCount successful, $failedCount failed"
            }
    ) {
        // Error queue at top
        ErrorQueueView(
            errors = errors,
            onRetry = onRetry,
            onClear = onClearErrors,
            modifier = Modifier.padding(16.dp)
        )

        // Sort controls
        SortingControls(
            selectedSort = sortOption,
            onSortSelected = { sortOption = it }
        )

        // Results summary
        ResultsSummary(
            successCount = successCount,
            failedCount = failedCount
        )

        // Document list
        LazyColumn(
            modifier = Modifier.fillMaxSize(),
            contentPadding = PaddingValues(16.dp),
            verticalArrangement = Arrangement.spacedBy(12.dp)
        ) {
            items(sortedDocuments, key = { it.pmid ?: it.hashCode() }) { document ->
                DocumentCard(document = document)
            }
        }
    }
}

@Composable
private fun ResultsSummary(
    successCount: Int,
    failedCount: Int
) {
    Row(
        modifier = Modifier
            .fillMaxWidth()
            .padding(horizontal = 16.dp, vertical = 8.dp)
            .semantics {
                contentDescription = "$successCount documents scored successfully, $failedCount failed"
            },
        horizontalArrangement = Arrangement.spacedBy(16.dp),
        verticalAlignment = Alignment.CenterVertically
    ) {
        Row(verticalAlignment = Alignment.CenterVertically) {
            Icon(
                imageVector = Icons.Default.CheckCircle,
                contentDescription = null,
                tint = MaterialTheme.colorScheme.primary,
                modifier = Modifier.size(16.dp)
            )
            Spacer(modifier = Modifier.width(4.dp))
            Text(
                text = "$successCount scored",
                style = MaterialTheme.typography.labelMedium,
                color = MaterialTheme.colorScheme.primary
            )
        }

        if (failedCount > 0) {
            Row(verticalAlignment = Alignment.CenterVertically) {
                Icon(
                    imageVector = Icons.Default.Error,
                    contentDescription = null,
                    tint = MaterialTheme.colorScheme.error,
                    modifier = Modifier.size(16.dp)
                )
                Spacer(modifier = Modifier.width(4.dp))
                Text(
                    text = "$failedCount failed",
                    style = MaterialTheme.typography.labelMedium,
                    color = MaterialTheme.colorScheme.error
                )
            }
        }

        Spacer(modifier = Modifier.weight(1f))
    }
}
```

## 4.8 ViewModel Integration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/FactCheckViewModel.kt`

Add error handling integration:

```kotlin
import androidx.lifecycle.SavedStateHandle
import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import com.bmlibrarian.factchecker.data.local.entity.ErrorEntry
import com.bmlibrarian.factchecker.data.repository.ErrorRepository
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.usecase.CancellableScoringUseCase
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.launch
import javax.inject.Inject

/**
 * ViewModel for fact-checking workflow with error handling.
 *
 * Integrates Phase 4 error queue with previous phases for
 * parallel scoring, checkpointing, and cancellation.
 */
@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val scoringUseCase: CancellableScoringUseCase,
    private val errorRepository: ErrorRepository,
    private val savedStateHandle: SavedStateHandle
) : ViewModel() {

    /** Current session ID from saved state or generated. */
    private val currentSessionId: String
        get() = savedStateHandle.get<String>("sessionId") ?: ""

    private val _uiState = MutableStateFlow(FactCheckUiState())
    val uiState: StateFlow<FactCheckUiState> = _uiState.asStateFlow()

    /** Errors flow from repository, updated reactively. */
    val errors: StateFlow<List<ErrorEntry>> = savedStateHandle.getStateFlow("sessionId", "")
        .flatMapLatest { sessionId ->
            if (sessionId.isNotEmpty()) {
                errorRepository.getErrors(sessionId)
            } else {
                flowOf(emptyList())
            }
        }
        .stateIn(viewModelScope, SharingStarted.Lazily, emptyList())

    // Persist sort preference
    private val _sortOption = savedStateHandle.getStateFlow(
        "sortOption",
        SortOption.SCORE_HIGH_TO_LOW.name
    )
    val sortOption: StateFlow<SortOption> = _sortOption.map {
        SortOption.valueOf(it)
    }.stateIn(viewModelScope, SharingStarted.Eagerly, SortOption.SCORE_HIGH_TO_LOW)

    fun setSortOption(option: SortOption) {
        savedStateHandle["sortOption"] = option.name
    }

    fun startScoring(documents: List<Document>, sessionId: String, claim: String, maxConcurrent: Int) {
        _uiState.update { it.copy(isProcessing = true, isCancelling = false) }

        scoringUseCase.scoreDocuments(
            documents = documents,
            sessionId = sessionId,
            claim = claim,
            maxConcurrent = maxConcurrent,
            scope = viewModelScope
        ).onEach { event ->
            when (event) {
                is ScoringEvent.Progress -> {
                    _uiState.update {
                        it.copy(
                            processedCount = event.current,
                            totalCount = event.total
                        )
                    }
                }
                is ScoringEvent.DocumentError -> {
                    // Save error to repository (Phase 4)
                    viewModelScope.launch {
                        val error = ErrorEntry.fromMessage(
                            pmid = event.pmid,
                            step = event.step,
                            message = event.message,
                            sessionId = sessionId
                        )
                        errorRepository.saveError(error)
                    }
                }
                is ScoringEvent.Completed -> {
                    _uiState.update {
                        it.copy(
                            isProcessing = false,
                            statusMessage = "Completed ${event.results.size} documents"
                        )
                    }
                }
                is ScoringEvent.Cancelled -> {
                    _uiState.update {
                        it.copy(
                            isProcessing = false,
                            isCancelling = false,
                            statusMessage = "Cancelled. ${event.processed} processed, ${event.remaining} skipped."
                        )
                    }
                }
                is ScoringEvent.Error -> {
                    _uiState.update {
                        it.copy(
                            isProcessing = false,
                            errorMessage = event.message
                        )
                    }
                }
            }
        }.launchIn(viewModelScope)
    }

    /**
     * Retry scoring for failed documents.
     *
     * Increments retry count and re-queues documents for scoring.
     *
     * @param pmids List of PMIDs to retry.
     */
    fun retryFailedDocuments(pmids: List<String>) {
        viewModelScope.launch {
            // Increment retry count in repository
            errorRepository.incrementRetryCount(currentSessionId, pmids)

            // Get documents to retry from current state
            val currentDocs = _uiState.value.documents
            val documentsToRetry = currentDocs.filter { it.pmid in pmids }

            if (documentsToRetry.isNotEmpty()) {
                // Re-score using existing scoring use case
                startScoring(
                    documents = documentsToRetry,
                    sessionId = currentSessionId,
                    claim = _uiState.value.currentClaim,
                    maxConcurrent = _uiState.value.maxConcurrent
                )
            }
        }
    }

    fun clearErrors() {
        viewModelScope.launch {
            errorRepository.clearSession(currentSessionId)
        }
    }

    fun onDocumentScoredSuccessfully(pmid: String) {
        viewModelScope.launch {
            // Remove from error list if it was a retry
            errorRepository.removeErrors(currentSessionId, listOf(pmid))
        }
    }
}

/**
 * UI state for fact-checking screen.
 */
data class FactCheckUiState(
    val isProcessing: Boolean = false,
    val isCancelling: Boolean = false,
    val processedCount: Int = 0,
    val totalCount: Int = 0,
    val statusMessage: String = "",
    val errorMessage: String? = null,
    val documents: List<Document> = emptyList(),
    val currentClaim: String = "",
    val maxConcurrent: Int = DEFAULT_MAX_CONCURRENT
) {
    companion object {
        /** Default maximum concurrent requests. */
        const val DEFAULT_MAX_CONCURRENT = 5
    }
}
```

## 4.9 Database Migration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/AppDatabase.kt`

Add error entries table:

```kotlin
@Database(
    entities = [
        DocumentEntity::class,
        SessionEntity::class,
        CheckpointEntity::class,
        ErrorEntryEntity::class  // Phase 4
    ],
    version = 2,
    exportSchema = true
)
@TypeConverters(Converters::class)
abstract class AppDatabase : RoomDatabase() {
    abstract fun documentDao(): DocumentDao
    abstract fun sessionDao(): SessionDao
    abstract fun checkpointDao(): CheckpointDao
    abstract fun errorEntryDao(): ErrorEntryDao  // Phase 4

    companion object {
        val MIGRATION_1_2 = object : Migration(1, 2) {
            override fun migrate(database: SupportSQLiteDatabase) {
                database.execSQL("""
                    CREATE TABLE IF NOT EXISTS error_entries (
                        id INTEGER PRIMARY KEY AUTOINCREMENT NOT NULL,
                        pmid TEXT NOT NULL,
                        step TEXT NOT NULL,
                        message TEXT NOT NULL,
                        category TEXT NOT NULL,
                        timestamp INTEGER NOT NULL,
                        sessionId TEXT NOT NULL,
                        retryCount INTEGER NOT NULL DEFAULT 0
                    )
                """)
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_error_entries_sessionId ON error_entries (sessionId)"
                )
                database.execSQL(
                    "CREATE INDEX IF NOT EXISTS index_error_entries_sessionId_pmid ON error_entries (sessionId, pmid)"
                )
            }
        }
    }
}
```

## Key Kotlin/Android Patterns

### Room Persistence

Room provides SQLite abstraction:

- `@Entity` - Define table schema
- `@Dao` - Define database operations
- `Flow<T>` - Reactive queries that update automatically
- `Migration` - Schema versioning and upgrades

### Jetpack Compose Accessibility

Compose has built-in accessibility support:

- `Modifier.semantics` - Add accessibility metadata
- `contentDescription` - Screen reader text
- `heading()` - Mark headings for navigation
- `Role` - Semantic role for elements

### StateFlow for Reactive UI

StateFlow provides:

- Thread-safe state updates
- Automatic recomposition in Compose
- `stateIn()` for converting Flows to StateFlows
- `savedStateHandle` for surviving process death

### Hilt Dependency Injection

Hilt integration:

- `@Inject constructor` - Constructor injection
- `@HiltViewModel` - ViewModel injection
- `@Singleton` - Scoped dependencies

## Testing

```bash
# Unit tests
./gradlew :app:testDebugUnitTest --tests "*ErrorCategory*"
./gradlew :app:testDebugUnitTest --tests "*ErrorRepository*"
./gradlew :app:testDebugUnitTest --tests "*SortingControls*"

# Instrumented tests
./gradlew :app:connectedDebugAndroidTest --tests "*ErrorQueueViewTest*"
./gradlew :app:connectedDebugAndroidTest --tests "*AccessibilityTest*"
```

### Test Cases

```kotlin
// ErrorCategoryTest.kt
@Test
fun `categorizes network errors correctly`() {
    assertEquals(ErrorCategory.NETWORK, ErrorCategory.fromMessage("Network connection failed"))
    assertEquals(ErrorCategory.NETWORK, ErrorCategory.fromMessage("Unable to reach server"))
    assertEquals(ErrorCategory.NETWORK, ErrorCategory.fromMessage("No internet connection"))
}

@Test
fun `categorizes LLM errors correctly`() {
    assertEquals(ErrorCategory.LLM, ErrorCategory.fromMessage("API key invalid"))
    assertEquals(ErrorCategory.LLM, ErrorCategory.fromMessage("Rate limit exceeded"))
    assertEquals(ErrorCategory.LLM, ErrorCategory.fromMessage("OpenAI service unavailable"))
}

@Test
fun `categorizes from exception type`() {
    assertEquals(ErrorCategory.TIMEOUT, ErrorCategory.fromException(SocketTimeoutException()))
    assertEquals(ErrorCategory.NETWORK, ErrorCategory.fromException(UnknownHostException()))
}

// SortingTest.kt
@Test
fun `sorts by score high to low`() {
    val docs = listOf(
        createDocument(pmid = "1", score = 5),
        createDocument(pmid = "2", score = 10),
        createDocument(pmid = "3", score = 3),
    )

    val sorted = docs.sortedBy(SortOption.SCORE_HIGH_TO_LOW)
    assertEquals(listOf("2", "1", "3"), sorted.map { it.pmid })
}

// ErrorQueueViewTest.kt (Compose UI test)
@Test
fun testErrorQueueAccessibility() {
    composeTestRule.setContent {
        ErrorQueueView(
            errors = testErrors,
            onRetry = {},
            onClear = {}
        )
    }

    // Verify content description
    composeTestRule
        .onNodeWithContentDescription("Error queue with 3 errors")
        .assertExists()

    // Verify expand button
    composeTestRule
        .onNodeWithContentDescription("Expand error list")
        .assertExists()
        .performClick()

    // Verify category filter
    composeTestRule
        .onNodeWithContentDescription("Network errors: 2. Not selected")
        .assertExists()
}
```

## Acceptance Criteria

- [ ] Error queue hidden when empty
- [ ] Error queue appears when first error occurs
- [ ] Errors show PMID, step, message, and category with icon
- [ ] Error categorization correctly identifies network/LLM/parsing/timeout errors
- [ ] Category filter chips allow filtering by error type
- [ ] "Retry All" button re-queues failed documents
- [ ] "Clear" button dismisses errors
- [ ] Errors persist across app restarts (Room database)
- [ ] Retry count tracked and displayed
- [ ] Sort dropdown available after processing
- [ ] Sorting updates document card order immediately
- [ ] Sort preference persisted via SavedStateHandle
- [ ] All interactive elements have content descriptions
- [ ] TalkBack correctly reads error counts and categories
- [ ] Error cards announce full details when focused
