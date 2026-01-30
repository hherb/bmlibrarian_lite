# Phase 2: Checkpointing and Progress Reporting (Android/Kotlin)

## Objective

Enable session resumption after interruption and provide real-time UI feedback during processing.

## 2.1 Checkpoint Entity

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/entity/ProcessingCheckpointEntity.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.entity

import androidx.room.Entity
import java.time.Instant

@Entity(
    tableName = "processing_checkpoints",
    primaryKeys = ["sessionId", "pmid", "step"]
)
data class ProcessingCheckpointEntity(
    val sessionId: String,
    val pmid: String,
    val step: String,
    val resultJson: String,
    val createdAt: Instant = Instant.now()
)
```

## 2.2 Checkpoint DAO

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/dao/ProcessingCheckpointDao.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local.dao

import androidx.room.Dao
import androidx.room.Insert
import androidx.room.OnConflictStrategy
import androidx.room.Query
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity

@Dao
interface ProcessingCheckpointDao {
    @Insert(onConflict = OnConflictStrategy.REPLACE)
    suspend fun saveCheckpoint(checkpoint: ProcessingCheckpointEntity)

    @Query("SELECT * FROM processing_checkpoints WHERE sessionId = :sessionId AND pmid = :pmid AND step = :step")
    suspend fun loadCheckpoint(sessionId: String, pmid: String, step: String): ProcessingCheckpointEntity?

    @Query("SELECT pmid FROM processing_checkpoints WHERE sessionId = :sessionId AND step = :step")
    suspend fun getCheckpointedPmids(sessionId: String, step: String): List<String>

    @Query("DELETE FROM processing_checkpoints WHERE sessionId = :sessionId")
    suspend fun clearSession(sessionId: String)
}
```

## 2.3 Checkpoint Repository

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/repository/CheckpointRepository.kt`

```kotlin
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.local.entity.ProcessingCheckpointEntity
import kotlinx.serialization.encodeToString
import kotlinx.serialization.json.Json
import javax.inject.Inject

class CheckpointRepository @Inject constructor(
    private val checkpointDao: ProcessingCheckpointDao,
    private val json: Json
) {
    /**
     * Save a checkpoint for a processed document.
     *
     * Note: Uses inline reified to enable kotlinx.serialization at call-site.
     */
    suspend inline fun <reified T> saveCheckpoint(sessionId: String, pmid: String, step: String, result: T) {
        val resultJson = json.encodeToString(result)
        checkpointDao.saveCheckpoint(
            ProcessingCheckpointEntity(
                sessionId = sessionId,
                pmid = pmid,
                step = step,
                resultJson = resultJson
            )
        )
    }

    suspend inline fun <reified T> loadCheckpoint(sessionId: String, pmid: String, step: String): T? {
        val checkpoint = checkpointDao.loadCheckpoint(sessionId, pmid, step)
        return checkpoint?.let { json.decodeFromString<T>(it.resultJson) }
    }

    suspend fun getCheckpointedPmids(sessionId: String, step: String): Set<String> {
        return checkpointDao.getCheckpointedPmids(sessionId, step).toSet()
    }

    suspend fun clearSession(sessionId: String) {
        checkpointDao.clearSession(sessionId)
    }
}
```

## 2.4 Progress Reporting

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/model/ProgressMessage.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.model

/**
 * Types of progress updates for parallel processing.
 */
enum class ProgressType {
    DOCUMENT_STARTED,
    DOCUMENT_COMPLETED,
    DOCUMENT_SKIPPED,
    DOCUMENT_FAILED,
    BATCH_COMPLETED,
    PHASE_COMPLETED
}

/**
 * Progress update message for UI feedback.
 */
data class ProgressMessage(
    val type: ProgressType,
    val pmid: String?,
    val step: String,  // "scoring" or "citation"
    val current: Int,
    val total: Int,
    val error: String? = null
)
```

## 2.5 Checkpointed Parallel Scoring

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/CheckpointedScoringUseCase.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.data.repository.CheckpointRepository
import com.bmlibrarian.factchecker.data.repository.ScoringRepository
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.model.ProgressMessage
import com.bmlibrarian.factchecker.domain.model.ProgressType
import com.bmlibrarian.factchecker.util.ConcurrencyDetector
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import javax.inject.Inject

/**
 * Result of scoring a single document for checkpointing.
 *
 * Note: This is a serializable version used for checkpoint storage.
 * For the full ScoringResult sealed class, see domain/model/ScoringResult.kt.
 */
@kotlinx.serialization.Serializable
data class CheckpointedScoringResult(
    val pmid: String,
    val score: Int,
    val rationale: String,
    val isError: Boolean = false,
    val error: String? = null
)

class CheckpointedScoringUseCase @Inject constructor(
    private val checkpointRepository: CheckpointRepository,
    private val scoringRepository: ScoringRepository
) {
    private val _progressFlow = MutableSharedFlow<ProgressMessage>()
    val progressFlow: SharedFlow<ProgressMessage> = _progressFlow

    /**
     * Score documents with per-document checkpointing.
     *
     * @param documents List of documents to score.
     * @param claim The medical claim being fact-checked.
     * @param sessionId Session identifier for checkpointing.
     * @return List of CheckpointedScoringResult objects (including from checkpoints).
     */
    suspend fun scoreDocuments(
        documents: List<Document>,
        claim: String,
        sessionId: String
    ): List<CheckpointedScoringResult> = coroutineScope {
        // Check for existing checkpoints
        val checkpointed = checkpointRepository.getCheckpointedPmids(sessionId, "scoring")

        // Filter documents: those with valid PMIDs that haven't been checkpointed
        val toProcess = documents.filter { doc ->
            val pmid = doc.pmid
            !pmid.isNullOrEmpty() && pmid !in checkpointed
        }
        val results = mutableListOf<CheckpointedScoringResult>()

        // Load checkpointed results - only iterate documents that ARE checkpointed
        for (doc in documents) {
            val pmid = doc.pmid ?: continue
            if (pmid !in checkpointed) continue

            checkpointRepository.loadCheckpoint<CheckpointedScoringResult>(
                sessionId, pmid, "scoring"
            )?.let { checkpoint ->
                    results.add(checkpoint)
                    _progressFlow.emit(
                        ProgressMessage(
                            type = ProgressType.DOCUMENT_SKIPPED,
                            pmid = pmid,
                            step = "scoring",
                            current = results.size,
                            total = documents.size
                        )
                    )
                }
        }

        // Process remaining documents in parallel
        // Uses ConcurrencyDetector from Phase 1
        val maxConcurrent = ConcurrencyDetector.detectConcurrency(scoringRepository.endpointUrl)
        val semaphore = Semaphore(maxConcurrent)

        val newResults = toProcess.map { doc ->
            async {
                semaphore.withPermit {
                    scoreAndCheckpoint(doc, claim, sessionId, documents.size, results.size)
                }
            }
        }.awaitAll()

        results.addAll(newResults)

        _progressFlow.emit(
            ProgressMessage(
                type = ProgressType.PHASE_COMPLETED,
                pmid = null,
                step = "scoring",
                current = results.size,
                total = documents.size
            )
        )

        results
    }

    private suspend fun scoreAndCheckpoint(
        document: Document,
        claim: String,
        sessionId: String,
        total: Int,
        baseCount: Int
    ): CheckpointedScoringResult {
        val pmid = document.pmid ?: ""
        return try {
            // ScoringRepository returns tuple (score, rationale) for consistency with Phase 1 & 3
            val (score, rationale) = scoringRepository.scoreDocument(document, claim)
            val result = CheckpointedScoringResult(
                pmid = pmid,
                score = score,
                rationale = rationale
            )

            // Save checkpoint immediately
            checkpointRepository.saveCheckpoint(
                sessionId = sessionId,
                pmid = pmid,
                step = "scoring",
                result = result
            )

            _progressFlow.emit(
                ProgressMessage(
                    type = ProgressType.DOCUMENT_COMPLETED,
                    pmid = document.pmid,
                    step = "scoring",
                    current = baseCount + 1,
                    total = total
                )
            )

            result
        } catch (e: Exception) {
            val errorResult = CheckpointedScoringResult(
                pmid = pmid,
                score = 0,
                rationale = "",
                isError = true,
                error = e.message
            )

            _progressFlow.emit(
                ProgressMessage(
                    type = ProgressType.DOCUMENT_FAILED,
                    pmid = document.pmid,
                    step = "scoring",
                    current = baseCount + 1,
                    total = total,
                    error = e.message
                )
            )

            errorResult
        }
    }
}
```

## 2.6 Hilt Module for Checkpointing

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/di/CheckpointModule.kt`

```kotlin
package com.bmlibrarian.factchecker.di

import com.bmlibrarian.factchecker.data.local.AppDatabase
import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import com.bmlibrarian.factchecker.data.repository.CheckpointRepository
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import kotlinx.serialization.json.Json
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object CheckpointModule {

    @Provides
    @Singleton
    fun provideProcessingCheckpointDao(database: AppDatabase): ProcessingCheckpointDao {
        return database.processingCheckpointDao()
    }

    @Provides
    @Singleton
    fun provideCheckpointRepository(
        checkpointDao: ProcessingCheckpointDao,
        json: Json
    ): CheckpointRepository {
        return CheckpointRepository(checkpointDao, json)
    }
}
```

## 2.7 Database Migration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/data/local/Migrations.kt`

```kotlin
package com.bmlibrarian.factchecker.data.local

import androidx.room.migration.Migration
import androidx.sqlite.db.SupportSQLiteDatabase

val MIGRATION_X_Y = object : Migration(X, Y) {  // Replace X, Y with actual version numbers
    override fun migrate(database: SupportSQLiteDatabase) {
        database.execSQL("""
            CREATE TABLE IF NOT EXISTS processing_checkpoints (
                sessionId TEXT NOT NULL,
                pmid TEXT NOT NULL,
                step TEXT NOT NULL,
                resultJson TEXT NOT NULL,
                createdAt INTEGER NOT NULL,
                PRIMARY KEY (sessionId, pmid, step)
            )
        """)
    }
}
```

## 2.8 Compose Progress UI

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/components/ProcessingProgressCard.kt`

```kotlin
package com.bmlibrarian.factchecker.ui.factcheck.components

import androidx.compose.foundation.layout.*
import androidx.compose.material3.*
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.dp

@Composable
fun ProcessingProgressCard(
    step: String,
    current: Int,
    total: Int,
    skipped: Int,
    failed: Int,
    modifier: Modifier = Modifier
) {
    val progress = if (total > 0) current.toFloat() / total else 0f

    Card(
        modifier = modifier.fillMaxWidth(),
        colors = CardDefaults.cardColors(
            containerColor = MaterialTheme.colorScheme.surfaceVariant
        )
    ) {
        Column(
            modifier = Modifier.padding(16.dp)
        ) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically
            ) {
                Text(
                    text = step.replaceFirstChar { it.uppercase() },
                    style = MaterialTheme.typography.titleMedium
                )
                Text(
                    text = "$current/$total",
                    style = MaterialTheme.typography.bodySmall,
                    color = MaterialTheme.colorScheme.onSurfaceVariant
                )
            }

            Spacer(modifier = Modifier.height(8.dp))

            LinearProgressIndicator(
                progress = { progress },
                modifier = Modifier.fillMaxWidth()
            )

            Spacer(modifier = Modifier.height(8.dp))

            Row(
                horizontalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                if (skipped > 0) {
                    Text(
                        text = "$skipped skipped",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.tertiary
                    )
                }
                if (failed > 0) {
                    Text(
                        text = "$failed failed",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.error
                    )
                }
            }
        }
    }
}
```

## 2.9 ViewModel Integration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/FactCheckViewModel.kt` (additions)

```kotlin
// Add to FactCheckViewModel

import androidx.lifecycle.ViewModel
import androidx.lifecycle.viewModelScope
import dagger.hilt.android.lifecycle.HiltViewModel
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.update
import kotlinx.coroutines.launch
import javax.inject.Inject

@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val checkpointedScoringUseCase: CheckpointedScoringUseCase,
    // ... other dependencies
) : ViewModel() {

    // Progress state
    private val _scoringProgress = MutableStateFlow(ProgressState())
    val scoringProgress: StateFlow<ProgressState> = _scoringProgress.asStateFlow()

    init {
        // Collect progress updates
        viewModelScope.launch {
            checkpointedScoringUseCase.progressFlow.collect { message ->
                updateProgressState(message)
            }
        }
    }

    private fun updateProgressState(message: ProgressMessage) {
        _scoringProgress.update { current ->
            when (message.type) {
                ProgressType.DOCUMENT_COMPLETED -> current.copy(
                    current = message.current,
                    total = message.total
                )
                ProgressType.DOCUMENT_SKIPPED -> current.copy(
                    current = message.current,
                    total = message.total,
                    skipped = current.skipped + 1
                )
                ProgressType.DOCUMENT_FAILED -> current.copy(
                    current = message.current,
                    total = message.total,
                    failed = current.failed + 1
                )
                else -> current
            }
        }
    }
}

data class ProgressState(
    val current: Int = 0,
    val total: Int = 0,
    val skipped: Int = 0,
    val failed: Int = 0
)
```

## Testing Phase 2

```kotlin
// Unit tests for CheckpointRepository
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.ProcessingCheckpointDao
import io.mockk.coEvery
import io.mockk.mockk
import kotlinx.coroutines.test.runTest
import kotlinx.serialization.json.Json
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class CheckpointRepositoryTest {
    private lateinit var checkpointDao: ProcessingCheckpointDao
    private lateinit var repository: CheckpointRepository
    private val json = Json { ignoreUnknownKeys = true }

    @Before
    fun setup() {
        checkpointDao = mockk(relaxed = true)
        repository = CheckpointRepository(checkpointDao, json)
    }

    @Test
    fun `getCheckpointedPmids returns set of pmids`() = runTest {
        coEvery { checkpointDao.getCheckpointedPmids("session1", "scoring") } returns listOf("123", "456")

        val result = repository.getCheckpointedPmids("session1", "scoring")

        assertEquals(setOf("123", "456"), result)
    }
}
```

## Acceptance Criteria

- [ ] Checkpoints saved after each document processed
- [ ] Session resumption skips already-processed documents
- [ ] Progress updates emitted via SharedFlow
- [ ] Compose progress card updates in real-time
- [ ] Interrupted sessions can be resumed
- [ ] Checkpoint storage doesn't impact performance significantly
- [ ] Room database migration works correctly
