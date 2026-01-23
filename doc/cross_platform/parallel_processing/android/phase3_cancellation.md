# Phase 3: Cancellation Support (Android)

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## 3.1 Cancellable Use Case

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/CancellableScoringUseCase.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.data.repository.CheckpointRepository
import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.model.ScoringResult
import kotlinx.coroutines.*
import kotlinx.coroutines.flow.*
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import javax.inject.Inject

sealed class ScoringEvent {
    data class Progress(val pmid: String, val current: Int, val total: Int) : ScoringEvent()
    data class Completed(val results: List<ScoringResult>) : ScoringEvent()
    data class Cancelled(val processed: Int, val remaining: Int) : ScoringEvent()
    data class Error(val message: String) : ScoringEvent()
}

class CancellableScoringUseCase @Inject constructor(
    private val scoringRepository: ScoringRepository,
    private val checkpointRepository: CheckpointRepository
) {
    private var currentJob: Job? = null

    fun scoreDocuments(
        documents: List<Document>,
        sessionId: String,
        claim: String,
        maxConcurrent: Int,
        scope: CoroutineScope
    ): Flow<ScoringEvent> = callbackFlow {
        currentJob = scope.launch {
            val semaphore = Semaphore(maxConcurrent)
            val results = mutableListOf<ScoringResult>()
            var completed = 0
            val total = documents.count()

            try {
                coroutineScope {
                    val deferreds = documents.map { doc ->
                        async {
                            // Check cancellation before starting
                            ensureActive()

                            semaphore.withPermit {
                                ensureActive()
                                scoreAndCheckpoint(doc, sessionId, claim)
                            }
                        }
                    }

                    deferreds.forEach { deferred ->
                        try {
                            val result = deferred.await()
                            results.add(result)
                            completed++
                            trySend(ScoringEvent.Progress(
                                result.document.pmid ?: "",
                                completed,
                                total
                            ))
                        } catch (e: CancellationException) {
                            throw e
                        }
                    }
                }

                trySend(ScoringEvent.Completed(results))
            } catch (e: CancellationException) {
                trySend(ScoringEvent.Cancelled(results.size, total - results.size))
            } catch (e: Exception) {
                trySend(ScoringEvent.Error(e.message ?: "Unknown error"))
            }

            close()
        }

        awaitClose { currentJob?.cancel() }
    }

    fun cancel() {
        currentJob?.cancel()
        currentJob = null
    }

    private suspend fun scoreAndCheckpoint(
        document: Document,
        sessionId: String,
        claim: String
    ): ScoringResult {
        return try {
            val (score, rationale) = scoringRepository.scoreDocument(document, claim)

            // Save checkpoint
            checkpointRepository.saveCheckpoint(
                sessionId = sessionId,
                pmid = document.pmid ?: "",
                step = "scoring",
                result = ScoringCheckpoint(score, rationale)
            )

            ScoringResult.Success(document, score, rationale)
        } catch (e: Exception) {
            ScoringResult.Error(document, e)
        }
    }
}

@kotlinx.serialization.Serializable
data class ScoringCheckpoint(
    val score: Int,
    val rationale: String?
)
```

## 3.2 ViewModel Integration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/FactCheckViewModel.kt`

```kotlin
@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val scoringUseCase: CancellableScoringUseCase
) : ViewModel() {

    private val _uiState = MutableStateFlow(FactCheckUiState())
    val uiState: StateFlow<FactCheckUiState> = _uiState.asStateFlow()

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

    fun cancelScoring() {
        _uiState.update { it.copy(isCancelling = true) }
        scoringUseCase.cancel()
    }
}

data class FactCheckUiState(
    val isProcessing: Boolean = false,
    val isCancelling: Boolean = false,
    val processedCount: Int = 0,
    val totalCount: Int = 0,
    val statusMessage: String = "",
    val errorMessage: String? = null
)
```

## Key Kotlin Patterns

### Coroutine Cancellation

Kotlin coroutines provide cooperative cancellation:

- `ensureActive()` - Throws `CancellationException` if cancelled
- `isActive` - Check if the coroutine is still active
- `job.cancel()` - Request cancellation of a job
- `CancellationException` - Propagates through coroutine hierarchy

### Flow with callbackFlow

The `callbackFlow` builder creates a cold Flow that:

- Emits events as scoring progresses
- Handles cancellation via `awaitClose`
- Provides backpressure via `trySend`

### Semaphore for Concurrency Control

`Semaphore.withPermit` ensures:

- Maximum concurrent requests respected
- Automatic permit release on completion or exception
- Fair ordering of waiting coroutines

### StateFlow for UI State

`MutableStateFlow` with `update` provides:

- Thread-safe state updates
- Automatic UI recomposition in Jetpack Compose
- Atomic read-modify-write operations

## Testing

```kotlin
@Test
fun `cancellation stops processing and preserves results`() = runTest {
    val documents = (1..10).map { createTestDocument(it) }
    val useCase = CancellableScoringUseCase(mockRepository, mockCheckpointRepo)

    val events = mutableListOf<ScoringEvent>()
    val job = launch {
        useCase.scoreDocuments(documents, "session", "claim", 3, this)
            .collect { events.add(it) }
    }

    // Wait for some progress
    advanceTimeBy(1000)

    // Cancel
    useCase.cancel()
    job.join()

    // Verify cancellation event was emitted
    val cancelled = events.filterIsInstance<ScoringEvent.Cancelled>()
    assertThat(cancelled).hasSize(1)
    assertThat(cancelled.first().processed).isGreaterThan(0)
}
```

## Acceptance Criteria

- [ ] Cancel button visible during processing
- [ ] Cancellation stops new documents from being processed
- [ ] In-flight requests complete (not aborted mid-request)
- [ ] UI shows cancellation status with counts
- [ ] Checkpointed results preserved after cancellation
- [ ] Session can be resumed after cancellation
