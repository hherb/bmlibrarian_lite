# Parallel Processing Implementation Plan

This document provides implementation guidance for the parallel processing strategy defined in `parallel_processing.md`. Implementation is divided into four phases, each building on the previous.

## Overview

| Phase | Focus | Deliverables |
|-------|-------|--------------|
| 1 | Provider detection + parallel requests | Core parallelization working |
| 2 | Checkpointing + progress reporting | Resumable sessions, UI feedback |
| 3 | Cancellation support | Graceful termination |
| 4 | Error queue UI + result re-ordering | Polish and UX |

## Phase 1: Provider Detection and Parallel Requests

### Objective

Enable parallel LLM requests for cloud providers while maintaining sequential behavior for local inference.

### Python Implementation

#### 1.1 Add Constants

**File**: `src/bmlibrarian_lite/constants.py`

```python
# Parallel processing constants
CONCURRENCY_SEQUENTIAL = 1
CONCURRENCY_MODERATE = 3
CONCURRENCY_AGGRESSIVE = 5
CONCURRENCY_CLOUD_DEFAULT = 3

# Known large-scale providers that support parallel requests
PARALLEL_PROVIDERS = [
    "api.anthropic.com",
    "api.openai.com",
    "api.deepseek.com",
    "generativelanguage.googleapis.com",
    "api.groq.com",
    "api.together.xyz",
    "api.fireworks.ai",
    "api.mistral.ai",
    "api.cohere.ai",
]

# Retry constants
RETRY_BASE_DELAY_SECONDS = 1.0
RETRY_MAX_DELAY_SECONDS = 10.0
RETRY_JITTER_MIN = 0.75
RETRY_JITTER_MAX = 1.25
MAX_LLM_RETRIES = 3

# Rate limiting
RATE_LIMIT_MIN_INTERVAL_SECONDS = 0.1
```

#### 1.2 Provider Detection

**File**: `src/bmlibrarian_lite/llm/concurrency.py` (new file)

```python
"""Concurrency detection and management for LLM requests."""

from urllib.parse import urlparse
from typing import Optional

from ..constants import (
    CONCURRENCY_SEQUENTIAL,
    CONCURRENCY_CLOUD_DEFAULT,
    PARALLEL_PROVIDERS,
)


def detect_concurrency(provider_url: str, user_override: Optional[int] = None) -> int:
    """
    Detect appropriate concurrency level based on provider URL.

    Args:
        provider_url: The LLM API endpoint URL.
        user_override: Optional user-specified concurrency level.

    Returns:
        Number of concurrent requests to allow.
    """
    if user_override is not None:
        return user_override

    parsed = urlparse(provider_url)
    host = parsed.hostname.lower() if parsed.hostname else ""

    for provider in PARALLEL_PROVIDERS:
        if provider in host:
            return CONCURRENCY_CLOUD_DEFAULT

    return CONCURRENCY_SEQUENTIAL


def get_provider_url_from_config(config) -> str:
    """Extract provider URL from configuration."""
    model_string = config.model
    if ":" in model_string:
        provider, _ = model_string.split(":", 1)
    else:
        provider = "anthropic"

    if provider == "anthropic":
        return "https://api.anthropic.com/v1"
    elif provider == "ollama":
        return config.ollama_host or "http://localhost:11434"
    elif provider == "openai":
        return "https://api.openai.com/v1"
    else:
        # Generic OpenAI-compatible endpoint
        return getattr(config, "llm_base_url", "http://localhost:8080")
```

#### 1.3 Parallel Scoring Implementation

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py` (new file)

```python
"""Parallel document scoring using asyncio."""

import asyncio
import random
from dataclasses import dataclass
from typing import List, Optional, Callable

from ..constants import (
    RETRY_BASE_DELAY_SECONDS,
    RETRY_MAX_DELAY_SECONDS,
    RETRY_JITTER_MIN,
    RETRY_JITTER_MAX,
    MAX_LLM_RETRIES,
)
from ..models import LiteDocument
from .scoring_agent import ScoringAgent


@dataclass
class ScoringResult:
    """Result of scoring a single document."""

    document: LiteDocument
    score: Optional[int]
    rationale: Optional[str]
    error: Optional[str] = None

    @property
    def is_error(self) -> bool:
        """Check if this result represents an error."""
        return self.error is not None


def calculate_backoff_delay(attempt: int) -> float:
    """
    Calculate exponential backoff delay with jitter.

    Args:
        attempt: Zero-based attempt number.

    Returns:
        Delay in seconds with jitter applied.
    """
    base_delay = RETRY_BASE_DELAY_SECONDS * (2 ** attempt)
    jitter = random.uniform(RETRY_JITTER_MIN, RETRY_JITTER_MAX)
    return min(base_delay * jitter, RETRY_MAX_DELAY_SECONDS)


async def score_single_document_async(
    agent: ScoringAgent,
    document: LiteDocument,
    claim: str,
) -> ScoringResult:
    """
    Score a single document with retry logic.

    Args:
        agent: The scoring agent instance.
        document: The document to score.
        claim: The medical claim being fact-checked.

    Returns:
        ScoringResult with document, score, and rationale.
    """
    for attempt in range(MAX_LLM_RETRIES):
        try:
            # Run blocking scoring in thread pool
            loop = asyncio.get_event_loop()
            score, rationale = await loop.run_in_executor(
                None, agent.score_document, document, claim
            )

            return ScoringResult(
                document=document,
                score=score,
                rationale=rationale,
            )

        except Exception as e:
            if attempt < MAX_LLM_RETRIES - 1:
                delay = calculate_backoff_delay(attempt)
                await asyncio.sleep(delay)
            else:
                return ScoringResult(
                    document=document,
                    score=None,
                    rationale=None,
                    error=str(e),
                )


async def score_documents_parallel(
    documents: List[LiteDocument],
    claim: str,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[str, int, int], None]] = None,
) -> List[ScoringResult]:
    """
    Score multiple documents in parallel.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback(pmid, current, total) for progress updates.

    Returns:
        List of ScoringResult objects.
    """
    semaphore = asyncio.Semaphore(max_concurrent)
    results: List[ScoringResult] = []
    completed = 0
    total = len(documents)

    async def score_with_limit(doc: LiteDocument) -> ScoringResult:
        nonlocal completed
        async with semaphore:
            agent = agent_factory()
            result = await score_single_document_async(agent, doc, claim)

            completed += 1
            if on_progress:
                on_progress(doc.pmid, completed, total)

            return result

    tasks = [score_with_limit(doc) for doc in documents]
    results = await asyncio.gather(*tasks, return_exceptions=False)

    return results


def run_parallel_scoring(
    documents: List[LiteDocument],
    claim: str,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[str, int, int], None]] = None,
) -> List[ScoringResult]:
    """
    Synchronous wrapper for parallel scoring.

    Use this from non-async code (e.g., Qt workers).
    """
    return asyncio.run(
        score_documents_parallel(
            documents, claim, agent_factory, max_concurrent, on_progress
        )
    )
```

#### 1.4 Integration with SystematicReviewTab

**File**: `src/bmlibrarian_lite/gui/systematic_review_tab.py`

Modify the scoring worker to use parallel processing when appropriate:

```python
# In the scoring worker class
from ..llm.concurrency import detect_concurrency, get_provider_url_from_config
from ..agents.parallel_scoring import run_parallel_scoring, ScoringResult

class ScoringWorker(QThread):
    """Worker thread for document scoring."""

    progress = Signal(str, int, int)  # pmid, current, total
    finished = Signal(list)  # List[ScoringResult]
    error = Signal(str)

    def __init__(self, documents, claim, config, parent=None):
        super().__init__(parent)
        self.documents = documents
        self.claim = claim
        self.config = config

    def run(self):
        try:
            # Detect appropriate concurrency
            provider_url = get_provider_url_from_config(self.config)
            max_concurrent = detect_concurrency(
                provider_url,
                user_override=getattr(self.config, 'concurrency_override', None)
            )

            def agent_factory():
                return ScoringAgent(self.config)

            def on_progress(pmid, current, total):
                self.progress.emit(pmid, current, total)

            results = run_parallel_scoring(
                self.documents,
                self.claim,
                agent_factory,
                max_concurrent,
                on_progress,
            )

            self.finished.emit(results)

        except Exception as e:
            self.error.emit(str(e))
```

#### 1.5 Configuration Extension

**File**: `src/bmlibrarian_lite/config.py`

Add concurrency override to configuration:

```python
@dataclass
class LiteConfig:
    # ... existing fields ...

    # Parallel processing settings
    concurrency_override: Optional[int] = None  # None = auto-detect
```

### Swift Implementation (iOS/macOS)

#### 1.1 Add Constants

**File**: `ios/MedicalFactChecker/Sources/Models/ParallelProcessingConstants.swift`

```swift
import Foundation

enum ParallelProcessingConstants {
    static let concurrencySequential = 1
    static let concurrencyModerate = 3
    static let concurrencyAggressive = 5
    static let concurrencyCloudDefault = 3

    static let parallelProviders = [
        "api.anthropic.com",
        "api.openai.com",
        "api.deepseek.com",
        "generativelanguage.googleapis.com",
        "api.groq.com",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.mistral.ai",
        "api.cohere.ai",
    ]

    static let retryBaseDelaySeconds: Double = 1.0
    static let retryMaxDelaySeconds: Double = 10.0
    static let retryJitterMin: Double = 0.75
    static let retryJitterMax: Double = 1.25
    static let maxRetries = 3
}
```

#### 1.2 Concurrency Detection

**File**: `ios/MedicalFactChecker/Sources/Services/ConcurrencyDetector.swift`

```swift
import Foundation

struct ConcurrencyDetector {
    static func detectConcurrency(
        providerURL: URL,
        userOverride: Int? = nil
    ) -> Int {
        if let override = userOverride {
            return override
        }

        guard let host = providerURL.host?.lowercased() else {
            return ParallelProcessingConstants.concurrencySequential
        }

        for provider in ParallelProcessingConstants.parallelProviders {
            if host.contains(provider) {
                return ParallelProcessingConstants.concurrencyCloudDefault
            }
        }

        return ParallelProcessingConstants.concurrencySequential
    }
}
```

#### 1.3 Parallel Scoring with TaskGroup

**File**: `ios/MedicalFactChecker/Sources/Services/ParallelScoringService.swift`

```swift
import Foundation

struct ScoringResult {
    let document: Document
    let score: Int?
    let rationale: String?
    let error: Error?

    var isError: Bool { error != nil }
}

actor ParallelScoringService {
    private let llmService: LLMService
    private let maxConcurrent: Int

    init(llmService: LLMService, maxConcurrent: Int) {
        self.llmService = llmService
        self.maxConcurrent = maxConcurrent
    }

    func scoreDocuments(
        _ documents: [Document],
        claim: String,
        onProgress: @escaping (String, Int, Int) -> Void
    ) async -> [ScoringResult] {
        var results: [ScoringResult] = []
        var completed = 0
        let total = documents.count

        await withTaskGroup(of: ScoringResult.self) { group in
            var pending = documents[...]

            // Launch initial batch
            for _ in 0..<min(maxConcurrent, documents.count) {
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.scoreDocument(doc, claim: claim)
                    }
                }
            }

            // Process results and refill
            for await result in group {
                results.append(result)
                completed += 1
                onProgress(result.document.pmid ?? "", completed, total)

                // Add next document
                if let doc = pending.popFirst() {
                    group.addTask {
                        await self.scoreDocument(doc, claim: claim)
                    }
                }
            }
        }

        return results
    }

    private func scoreDocument(_ document: Document, claim: String) async -> ScoringResult {
        do {
            let (score, rationale) = try await llmService.scoreDocument(document, claim: claim)
            return ScoringResult(document: document, score: score, rationale: rationale, error: nil)
        } catch {
            return ScoringResult(document: document, score: nil, rationale: nil, error: error)
        }
    }
}
```

### Kotlin Implementation (Android)

#### 1.1 Add Constants

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/util/ParallelProcessingConstants.kt`

```kotlin
package com.bmlibrarian.factchecker.util

object ParallelProcessingConstants {
    const val CONCURRENCY_SEQUENTIAL = 1
    const val CONCURRENCY_MODERATE = 3
    const val CONCURRENCY_AGGRESSIVE = 5
    const val CONCURRENCY_CLOUD_DEFAULT = 3

    val PARALLEL_PROVIDERS = listOf(
        "api.anthropic.com",
        "api.openai.com",
        "api.deepseek.com",
        "generativelanguage.googleapis.com",
        "api.groq.com",
        "api.together.xyz",
        "api.fireworks.ai",
        "api.mistral.ai",
        "api.cohere.ai",
    )

    const val RETRY_BASE_DELAY_MS = 1000L
    const val RETRY_MAX_DELAY_MS = 10000L
    const val RETRY_JITTER_MIN = 0.75
    const val RETRY_JITTER_MAX = 1.25
    const val MAX_RETRIES = 3
}
```

#### 1.2 Concurrency Detection

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/util/ConcurrencyDetector.kt`

```kotlin
package com.bmlibrarian.factchecker.util

import java.net.URL

object ConcurrencyDetector {
    fun detectConcurrency(providerUrl: String, userOverride: Int? = null): Int {
        userOverride?.let { return it }

        val host = try {
            URL(providerUrl).host.lowercase()
        } catch (e: Exception) {
            return ParallelProcessingConstants.CONCURRENCY_SEQUENTIAL
        }

        for (provider in ParallelProcessingConstants.PARALLEL_PROVIDERS) {
            if (host.contains(provider)) {
                return ParallelProcessingConstants.CONCURRENCY_CLOUD_DEFAULT
            }
        }

        return ParallelProcessingConstants.CONCURRENCY_SEQUENTIAL
    }
}
```

#### 1.3 Parallel Scoring with Coroutines

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/ParallelScoringUseCase.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.model.ScoringResult
import kotlinx.coroutines.async
import kotlinx.coroutines.awaitAll
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import javax.inject.Inject

class ParallelScoringUseCase @Inject constructor(
    private val scoringRepository: ScoringRepository
) {
    suspend fun scoreDocuments(
        documents: List<Document>,
        claim: String,
        maxConcurrent: Int
    ): Flow<ScoringResult> = flow {
        val semaphore = Semaphore(maxConcurrent)

        coroutineScope {
            val deferreds = documents.map { doc ->
                async {
                    semaphore.withPermit {
                        try {
                            val (score, rationale) = scoringRepository.scoreDocument(doc, claim)
                            ScoringResult.Success(doc, score, rationale)
                        } catch (e: Exception) {
                            ScoringResult.Error(doc, e)
                        }
                    }
                }
            }

            deferreds.forEach { deferred ->
                emit(deferred.await())
            }
        }
    }
}
```

### Testing Phase 1

```bash
# Python tests
pytest tests/test_concurrency.py -v
pytest tests/test_parallel_scoring.py -v

# Swift tests (Xcode)
xcodebuild test -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 15'

# Kotlin tests (Android Studio)
./gradlew :app:testDebugUnitTest
```

### Phase 1 Acceptance Criteria

- [ ] Provider detection correctly identifies cloud vs local providers
- [ ] User override in settings works correctly
- [ ] Parallel scoring completes faster than sequential for cloud providers
- [ ] Sequential behavior maintained for Ollama/local
- [ ] All existing tests pass
- [ ] No race conditions or data corruption

---

## Phase 2: Checkpointing and Progress Reporting

### Objective

Enable session resumption after interruption and provide real-time UI feedback during processing.

### Python Implementation

#### 2.1 Checkpoint Storage

**File**: `src/bmlibrarian_lite/storage.py`

Add checkpoint table and methods:

```python
# Add to schema creation
CREATE_CHECKPOINTS_TABLE = """
CREATE TABLE IF NOT EXISTS processing_checkpoints (
    session_id TEXT NOT NULL,
    pmid TEXT NOT NULL,
    step TEXT NOT NULL,  -- 'scoring' or 'citation'
    result_json TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (session_id, pmid, step)
)
"""

class LiteStorage:
    # Add methods:

    def save_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
        result: dict,
    ) -> None:
        """Save processing checkpoint for resumption."""
        with self._lock:
            self._conn.execute(
                """
                INSERT OR REPLACE INTO processing_checkpoints
                (session_id, pmid, step, result_json, created_at)
                VALUES (?, ?, ?, ?, ?)
                """,
                (session_id, pmid, step, json.dumps(result), datetime.now().isoformat()),
            )
            self._conn.commit()

    def load_checkpoint(
        self,
        session_id: str,
        pmid: str,
        step: str,
    ) -> Optional[dict]:
        """Load existing checkpoint if available."""
        row = self._conn.execute(
            """
            SELECT result_json FROM processing_checkpoints
            WHERE session_id = ? AND pmid = ? AND step = ?
            """,
            (session_id, pmid, step),
        ).fetchone()
        return json.loads(row[0]) if row else None

    def get_checkpointed_pmids(
        self,
        session_id: str,
        step: str,
    ) -> Set[str]:
        """Get PMIDs that have been checkpointed for a step."""
        rows = self._conn.execute(
            """
            SELECT pmid FROM processing_checkpoints
            WHERE session_id = ? AND step = ?
            """,
            (session_id, step),
        ).fetchall()
        return {row[0] for row in rows}
```

#### 2.2 Progress Signal Protocol

**File**: `src/bmlibrarian_lite/gui/progress_signals.py` (new file)

```python
"""Progress reporting signals for parallel processing."""

from dataclasses import dataclass
from enum import Enum, auto
from typing import Optional
from PySide6.QtCore import QObject, Signal


class ProgressType(Enum):
    """Types of progress updates."""

    DOCUMENT_STARTED = auto()
    DOCUMENT_COMPLETED = auto()
    DOCUMENT_SKIPPED = auto()
    DOCUMENT_FAILED = auto()
    BATCH_COMPLETED = auto()
    PHASE_COMPLETED = auto()


@dataclass
class ProgressMessage:
    """Progress update message."""

    type: ProgressType
    pmid: Optional[str]
    step: str  # 'scoring' or 'citation'
    current: int
    total: int
    error: Optional[str] = None


class ProgressSignals(QObject):
    """Qt signals for progress updates."""

    document_progress = Signal(ProgressMessage)
    phase_completed = Signal(str, int)  # step, count
    error_occurred = Signal(str, str, str)  # pmid, step, error_message
```

#### 2.3 Checkpointed Parallel Scoring

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py`

Add checkpointing support:

```python
async def score_documents_with_checkpointing(
    documents: List[LiteDocument],
    claim: str,
    session_id: str,
    storage: LiteStorage,
    agent_factory: Callable[[], ScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[ProgressMessage], None]] = None,
) -> List[ScoringResult]:
    """
    Score documents with per-document checkpointing.

    Args:
        documents: List of documents to score.
        claim: The medical claim being fact-checked.
        session_id: Session identifier for checkpointing.
        storage: Storage instance for checkpoints.
        agent_factory: Factory function to create ScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback for progress updates.

    Returns:
        List of ScoringResult objects (including from checkpoints).
    """
    # Check for existing checkpoints
    checkpointed = storage.get_checkpointed_pmids(session_id, "scoring")
    to_process = [d for d in documents if d.pmid not in checkpointed]
    results = []

    # Load checkpointed results
    for doc in documents:
        if doc.pmid in checkpointed:
            checkpoint = storage.load_checkpoint(session_id, doc.pmid, "scoring")
            results.append(ScoringResult(
                document=doc,
                score=checkpoint["score"],
                rationale=checkpoint["rationale"],
            ))
            if on_progress:
                on_progress(ProgressMessage(
                    type=ProgressType.DOCUMENT_SKIPPED,
                    pmid=doc.pmid,
                    step="scoring",
                    current=len(results),
                    total=len(documents),
                ))

    # Process remaining documents
    semaphore = asyncio.Semaphore(max_concurrent)

    async def score_and_checkpoint(doc: LiteDocument) -> ScoringResult:
        async with semaphore:
            agent = agent_factory()
            result = await score_single_document_async(agent, doc, claim)

            # Save checkpoint immediately
            if not result.is_error:
                storage.save_checkpoint(
                    session_id,
                    doc.pmid,
                    "scoring",
                    {"score": result.score, "rationale": result.rationale},
                )

            if on_progress:
                on_progress(ProgressMessage(
                    type=ProgressType.DOCUMENT_FAILED if result.is_error else ProgressType.DOCUMENT_COMPLETED,
                    pmid=doc.pmid,
                    step="scoring",
                    current=len(results) + 1,
                    total=len(documents),
                    error=result.error,
                ))

            return result

    tasks = [score_and_checkpoint(doc) for doc in to_process]
    new_results = await asyncio.gather(*tasks)
    results.extend(new_results)

    return results
```

### Swift Implementation

#### 2.1 Checkpoint Storage

**File**: `ios/MedicalFactChecker/Sources/Models/ProcessingCheckpoint.swift`

```swift
import Foundation
import SwiftData

@Model
class ProcessingCheckpoint {
    var sessionId: String
    var pmid: String
    var step: String  // "scoring" or "citation"
    var resultJSON: String
    var createdAt: Date

    init(sessionId: String, pmid: String, step: String, resultJSON: String) {
        self.sessionId = sessionId
        self.pmid = pmid
        self.step = step
        self.resultJSON = resultJSON
        self.createdAt = Date()
    }
}
```

#### 2.2 Checkpoint Manager

**File**: `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

```swift
import Foundation
import SwiftData

actor CheckpointManager {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func saveCheckpoint(sessionId: String, pmid: String, step: String, result: Codable) throws {
        let encoder = JSONEncoder()
        let jsonData = try encoder.encode(result)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"

        let checkpoint = ProcessingCheckpoint(
            sessionId: sessionId,
            pmid: pmid,
            step: step,
            resultJSON: jsonString
        )

        modelContext.insert(checkpoint)
        try modelContext.save()
    }

    func loadCheckpoint<T: Codable>(sessionId: String, pmid: String, step: String) -> T? {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.pmid == pmid && $0.step == step
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoint = try? modelContext.fetch(descriptor).first,
              let data = checkpoint.resultJSON.data(using: .utf8) else {
            return nil
        }

        return try? JSONDecoder().decode(T.self, from: data)
    }

    func getCheckpointedPMIDs(sessionId: String, step: String) -> Set<String> {
        let predicate = #Predicate<ProcessingCheckpoint> {
            $0.sessionId == sessionId && $0.step == step
        }
        let descriptor = FetchDescriptor<ProcessingCheckpoint>(predicate: predicate)

        guard let checkpoints = try? modelContext.fetch(descriptor) else {
            return []
        }

        return Set(checkpoints.map { $0.pmid })
    }
}
```

### Phase 2 Acceptance Criteria

- [ ] Checkpoints saved after each document processed
- [ ] Session resumption skips already-processed documents
- [ ] Progress bar updates per-document
- [ ] Document cards update status in real-time
- [ ] Interrupted sessions can be resumed
- [ ] Checkpoint storage doesn't impact performance significantly

---

## Phase 3: Cancellation Support

### Objective

Enable users to cancel in-progress processing with graceful termination and clear feedback.

### Python Implementation

#### 3.1 Cancellation Token

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

#### 3.2 Cancellable Parallel Scoring

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
                timeout=0.1,
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

#### 3.3 UI Integration

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

### Phase 3 Acceptance Criteria

- [ ] Cancel button visible during processing
- [ ] Cancellation stops new documents from being processed
- [ ] In-flight requests complete (not aborted mid-request)
- [ ] UI shows cancellation status with counts
- [ ] Checkpointed results preserved after cancellation
- [ ] Session can be resumed after cancellation

---

## Phase 4: Error Queue UI and Result Re-ordering

### Objective

Provide a polished error display and allow users to re-order results after processing completes.

### Python Implementation

#### 4.1 Error Queue Widget

**File**: `src/bmlibrarian_lite/gui/error_queue_widget.py` (new file)

```python
"""Collapsible error queue widget."""

from dataclasses import dataclass
from datetime import datetime
from typing import List, Optional
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QLabel,
    QPushButton, QScrollArea, QFrame,
)
from PySide6.QtCore import Signal

from ..dpi_scale import scaled


@dataclass
class ErrorEntry:
    """Single error entry."""

    pmid: str
    step: str
    message: str
    timestamp: datetime


class ErrorQueueWidget(QWidget):
    """
    Collapsible widget displaying accumulated errors.

    Hidden when empty, expands to show error list when populated.
    """

    retry_requested = Signal(list)  # List of PMIDs to retry

    def __init__(self, parent: Optional[QWidget] = None):
        super().__init__(parent)
        self._errors: List[ErrorEntry] = []
        self._is_expanded = False
        self._setup_ui()
        self.hide()

    def _setup_ui(self):
        layout = QVBoxLayout(self)
        layout.setContentsMargins(0, 0, 0, 0)

        # Header
        self._header = QFrame()
        self._header.setStyleSheet("background-color: #FFEBEE; border-radius: 4px;")
        header_layout = QHBoxLayout(self._header)

        self._header_label = QLabel("Errors (0)")
        self._header_label.setStyleSheet("color: #C62828; font-weight: bold;")

        self._toggle_button = QPushButton("▼")
        self._toggle_button.setFixedWidth(scaled(24))
        self._toggle_button.clicked.connect(self._toggle_expanded)

        self._retry_button = QPushButton("Retry All")
        self._retry_button.clicked.connect(self._handle_retry)

        self._clear_button = QPushButton("Clear")
        self._clear_button.clicked.connect(self.clear)

        header_layout.addWidget(self._header_label)
        header_layout.addStretch()
        header_layout.addWidget(self._retry_button)
        header_layout.addWidget(self._clear_button)
        header_layout.addWidget(self._toggle_button)

        layout.addWidget(self._header)

        # Error list (collapsible)
        self._scroll_area = QScrollArea()
        self._scroll_area.setWidgetResizable(True)
        self._scroll_area.setMaximumHeight(scaled(200))

        self._error_container = QWidget()
        self._error_layout = QVBoxLayout(self._error_container)
        self._scroll_area.setWidget(self._error_container)
        self._scroll_area.hide()

        layout.addWidget(self._scroll_area)

    def add_error(self, pmid: str, step: str, message: str) -> None:
        """Add error to queue and make widget visible."""
        entry = ErrorEntry(
            pmid=pmid,
            step=step,
            message=message,
            timestamp=datetime.now(),
        )
        self._errors.append(entry)
        self._add_error_widget(entry)
        self._update_visibility()

    def _add_error_widget(self, entry: ErrorEntry):
        frame = QFrame()
        frame.setStyleSheet("background-color: white; border: 1px solid #FFCDD2; border-radius: 4px; padding: 4px;")
        layout = QVBoxLayout(frame)

        pmid_label = QLabel(f"PMID: {entry.pmid} ({entry.step})")
        pmid_label.setStyleSheet("font-weight: bold;")

        message_label = QLabel(entry.message)
        message_label.setWordWrap(True)
        message_label.setStyleSheet("color: #666;")

        layout.addWidget(pmid_label)
        layout.addWidget(message_label)

        self._error_layout.addWidget(frame)

    def _update_visibility(self):
        if self._errors:
            self.show()
            self._header_label.setText(f"Errors ({len(self._errors)})")
        else:
            self.hide()

    def _toggle_expanded(self):
        self._is_expanded = not self._is_expanded
        self._scroll_area.setVisible(self._is_expanded)
        self._toggle_button.setText("▲" if self._is_expanded else "▼")

    def clear(self):
        """Clear all errors and hide widget."""
        self._errors.clear()
        # Clear error widgets
        while self._error_layout.count():
            item = self._error_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()
        self._update_visibility()

    def _handle_retry(self):
        """Emit retry signal with failed PMIDs."""
        pmids = [e.pmid for e in self._errors]
        self.retry_requested.emit(pmids)
        self.clear()

    def get_failed_pmids(self) -> List[str]:
        """Get list of PMIDs that failed."""
        return [e.pmid for e in self._errors]
```

#### 4.2 Result Re-ordering

**File**: `src/bmlibrarian_lite/gui/audit_literature_tab.py`

Add sorting controls:

```python
class AuditLiteratureTab(QWidget):
    def __init__(self, ...):
        # ... existing init ...
        self._setup_sort_controls()

    def _setup_sort_controls(self):
        sort_layout = QHBoxLayout()

        sort_label = QLabel("Sort by:")
        self._sort_combo = QComboBox()
        self._sort_combo.addItems([
            "Score (High to Low)",
            "Score (Low to High)",
            "Title (A-Z)",
            "Year (Newest First)",
            "Year (Oldest First)",
        ])
        self._sort_combo.currentIndexChanged.connect(self._apply_sort)

        sort_layout.addWidget(sort_label)
        sort_layout.addWidget(self._sort_combo)
        sort_layout.addStretch()

        # Add to main layout

    def _apply_sort(self, index: int):
        sort_key = [
            lambda d: -(d.score or 0),
            lambda d: d.score or 0,
            lambda d: (d.title or "").lower(),
            lambda d: -(d.year or 0),
            lambda d: d.year or 0,
        ][index]

        self._documents.sort(key=sort_key)
        self._refresh_document_cards()
```

### Phase 4 Acceptance Criteria

- [ ] Error queue hidden when empty
- [ ] Error queue appears when first error occurs
- [ ] Errors show PMID, step, and message
- [ ] "Retry All" button re-queues failed documents
- [ ] "Clear" button dismisses errors
- [ ] Sort dropdown available after processing
- [ ] Sorting updates document card order immediately
- [ ] Sort preference persisted in session

---

## Implementation Order

1. **Phase 1** (Core): 3-5 days
   - Constants and provider detection
   - Parallel scoring implementation
   - Integration with existing UI

2. **Phase 2** (Resumption): 2-3 days
   - Checkpoint storage schema
   - Checkpoint save/load logic
   - Progress signal integration

3. **Phase 3** (Cancellation): 2-3 days
   - Cancellation token
   - Worker integration
   - UI feedback

4. **Phase 4** (Polish): 2-3 days
   - Error queue widget
   - Sorting controls
   - Final testing

**Total estimate**: 9-14 days

## Dependencies

- Phase 2 depends on Phase 1 (uses parallel infrastructure)
- Phase 3 depends on Phase 2 (checkpoints enable safe cancellation)
- Phase 4 can proceed in parallel with Phase 3

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| Race conditions in checkpointing | Use database transactions, test under load |
| Cancellation leaves orphaned tasks | Explicit task cleanup, timeout on join |
| Progress updates overwhelm UI | Batch UI updates, use Qt queued connections |
| Memory growth with large sessions | Limit in-memory document cache, lazy loading |
