# Phase 3: Cancellation Support

## Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

## Python Implementation

### 3.1 Cancellation Token

**File**: `src/bmlibrarian_lite/utils/cancellation.py` (new file)

```python
"""Thread-safe cancellation support."""

import threading
from typing import Callable, List


class CancellationToken:
    """Thread-safe cancellation signal."""

    def __init__(self):
        self._cancelled = False
        self._lock = threading.Lock()
        self._callbacks: List[Callable[[], None]] = []

    def cancel(self) -> None:
        """Signal cancellation to all workers."""
        with self._lock:
            if not self._cancelled:
                self._cancelled = True
                for callback in self._callbacks:
                    try:
                        callback()
                    except Exception:
                        pass

    def is_cancelled(self) -> bool:
        """Check if cancellation was requested."""
        with self._lock:
            return self._cancelled

    def register_callback(self, callback: Callable[[], None]) -> None:
        """Register a callback to be called on cancellation."""
        with self._lock:
            if self._cancelled:
                callback()
            else:
                self._callbacks.append(callback)

    def reset(self) -> None:
        """Reset the token for reuse."""
        with self._lock:
            self._cancelled = False
            self._callbacks.clear()
```

### 3.2 Cancellable Parallel Scoring

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add cancellation support:

```python
async def score_documents_cancellable(
    documents: List[LiteDocument],
    claim: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    cancellation_token: CancellationToken,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
    on_cancelled: Optional[Callable[[int, int], None]] = None,
) -> List[ScoringResult]:
    """
    Score documents with cancellation support.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        session_id: Session identifier for checkpointing.
        storage: Storage instance for checkpoints.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        cancellation_token: Token to check for cancellation.
        on_progress: Optional callback for progress updates.
        on_cancelled: Optional callback(processed, remaining) when cancelled.

    Returns:
        List of ScoringResult objects processed before cancellation.
    """
    results = []
    pending = list(documents)
    active_tasks = set()

    async def process_document(doc: LiteDocument):
        if cancellation_token.is_cancelled():
            return None

        agent = agent_factory()
        result = await score_single_document_async(agent, doc, claim)

        if not result.is_error and not cancellation_token.is_cancelled():
            storage.save_checkpoint(
                session_id, doc.pmid, "scoring",
                {"score": result.score, "rationale": result.rationale},
            )

        return result

    semaphore = asyncio.Semaphore(max_concurrent)

    async def bounded_process(doc: LiteDocument):
        async with semaphore:
            return await process_document(doc)

    # Create tasks
    tasks = {asyncio.create_task(bounded_process(doc)): doc for doc in pending}

    try:
        while tasks and not cancellation_token.is_cancelled():
            done, _ = await asyncio.wait(
                tasks.keys(),
                timeout=CANCELLATION_CHECK_INTERVAL_SECONDS,
                return_when=asyncio.FIRST_COMPLETED,
            )

            for task in done:
                doc = tasks.pop(task)
                result = task.result()
                if result:
                    results.append(result)
                    if on_progress:
                        on_progress(ProgressMessage(
                            type=ProgressType.DOCUMENT_COMPLETED,
                            pmid=doc.pmid,
                            step="scoring",
                            current=len(results),
                            total=len(documents),
                        ))

    except asyncio.CancelledError:
        pass

    # Cancel remaining tasks
    for task in tasks:
        task.cancel()

    if cancellation_token.is_cancelled() and on_cancelled:
        on_cancelled(len(results), len(documents) - len(results))

    return results
```

### 3.3 UI Integration

**File**: `src/bmlibrarian_lite/gui/systematic_review_tab.py`

```python
class SystematicReviewTab(QWidget):
    def __init__(self, ...):
        # ... existing init ...
        self._cancellation_token = CancellationToken()
        self._setup_cancel_button()

    def _setup_cancel_button(self):
        self.cancel_button = QPushButton("Cancel")
        self.cancel_button.clicked.connect(self._handle_cancel)
        self.cancel_button.setEnabled(False)
        # Add to layout

    def _start_scoring(self):
        self._cancellation_token.reset()
        self.cancel_button.setEnabled(True)
        # ... start worker ...

    def _handle_cancel(self):
        self.cancel_button.setEnabled(False)
        self.cancel_button.setText("Cancelling...")
        self._cancellation_token.cancel()

    def _on_scoring_cancelled(self, processed: int, remaining: int):
        self.cancel_button.setText("Cancel")
        self.status_label.setText(
            f"Cancelled. {processed} documents processed, {remaining} skipped."
        )
        self._enable_resume_button()
```

## Swift Implementation (iOS/macOS)

### 3.1 Cancellation Support with Task

**File**: `ios/MedicalFactChecker/Sources/Services/CancellableScoringService.swift`

```swift
import Foundation

actor CancellableScoringService {
    private let llmService: LLMService
    private let checkpointManager: CheckpointManager
    private let maxConcurrent: Int

    private var currentTask: Task<[ScoringResult], Never>?

    init(llmService: LLMService, checkpointManager: CheckpointManager, maxConcurrent: Int) {
        self.llmService = llmService
        self.checkpointManager = checkpointManager
        self.maxConcurrent = maxConcurrent
    }

    func scoreDocuments(
        _ documents: [Document],
        sessionId: String,
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void,
        onCancelled: @escaping (Int, Int) -> Void
    ) async -> [ScoringResult] {
        let task = Task {
            await self.performScoring(
                documents,
                sessionId: sessionId,
                claim: claim,
                onProgress: onProgress,
                onCancelled: onCancelled
            )
        }

        currentTask = task
        return await task.value
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    private func performScoring(
        _ documents: [Document],
        sessionId: String,
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void,
        onCancelled: @escaping (Int, Int) -> Void
    ) async -> [ScoringResult] {
        var results: [ScoringResult] = []
        var completed = 0
        let total = documents.count

        await withTaskGroup(of: ScoringResult?.self) { group in
            var pending = documents[...]

            // Launch initial batch
            for _ in 0..<min(maxConcurrent, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask {
                        // Check cancellation before starting
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreDocument(doc, sessionId: sessionId, claim: claim)
                    }
                }
            }

            // Process results and refill
            for await result in group {
                // Check for cancellation
                if Task.isCancelled {
                    group.cancelAll()
                    onCancelled(results.count, total - results.count)
                    break
                }

                if let result = result {
                    results.append(result)
                    completed += 1
                    onProgress(result.document.pmid ?? "", completed, total)
                }

                // Add next document if not cancelled
                if !Task.isCancelled, let doc = pending.popFirst() {
                    group.addTask {
                        guard !Task.isCancelled else { return nil }
                        return await self.scoreDocument(doc, sessionId: sessionId, claim: claim)
                    }
                }
            }
        }

        return results
    }

    private func scoreDocument(
        _ document: Document,
        sessionId: String,
        claim: String
    ) async -> ScoringResult {
        do {
            let (score, rationale) = try await llmService.scoreDocument(document, claim: claim)

            // Save checkpoint
            try? await checkpointManager.saveCheckpoint(
                sessionId: sessionId,
                pmid: document.pmid ?? "",
                step: "scoring",
                result: ScoringCheckpoint(score: score, rationale: rationale)
            )

            return ScoringResult(document: document, score: score, rationale: rationale, error: nil)
        } catch {
            return ScoringResult(document: document, score: nil, rationale: nil, error: error)
        }
    }
}

struct ScoringCheckpoint: Codable {
    let score: Int
    let rationale: String?
}
```

### 3.2 View Model Integration

**File**: `ios/MedicalFactChecker/Sources/ViewModels/FactCheckViewModel.swift`

```swift
@MainActor
class FactCheckViewModel: ObservableObject {
    @Published var isProcessing = false
    @Published var isCancelling = false
    @Published var processedCount = 0
    @Published var totalCount = 0
    @Published var statusMessage = ""

    private var scoringService: CancellableScoringService?

    func startScoring(documents: [Document], sessionId: String, claim: String) {
        isProcessing = true
        isCancelling = false
        totalCount = documents.count
        processedCount = 0

        Task {
            let results = await scoringService?.scoreDocuments(
                documents,
                sessionId: sessionId,
                claim: claim,
                onProgress: { [weak self] pmid, current, total in
                    Task { @MainActor in
                        self?.processedCount = current
                    }
                },
                onCancelled: { [weak self] processed, remaining in
                    Task { @MainActor in
                        self?.statusMessage = "Cancelled. \(processed) processed, \(remaining) skipped."
                        self?.isProcessing = false
                        self?.isCancelling = false
                    }
                }
            )

            if !isCancelling {
                isProcessing = false
                statusMessage = "Completed \(results?.count ?? 0) documents"
            }
        }
    }

    func cancelScoring() {
        isCancelling = true
        Task {
            await scoringService?.cancel()
        }
    }
}
```

## Kotlin Implementation (Android)

### 3.1 Cancellable Use Case

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

### 3.2 ViewModel Integration

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

## Testing Phase 3

```bash
# Python tests
pytest tests/test_cancellation.py -v
pytest tests/test_cancellable_scoring.py -v

# Integration test: cancel mid-processing
pytest tests/test_cancel_and_resume.py -v
```

## Acceptance Criteria

- [ ] Cancel button visible during processing
- [ ] Cancellation stops new documents from being processed
- [ ] In-flight requests complete (not aborted mid-request)
- [ ] UI shows cancellation status with counts
- [ ] Checkpointed results preserved after cancellation
- [ ] Session can be resumed after cancellation
