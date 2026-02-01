# Phase 1: Provider Detection and Parallel Requests

## Objective

Enable parallel LLM requests for cloud providers while maintaining sequential behavior for local inference.

## Terminology Note

The Python desktop app uses `question` (research question context) while the iOS/Android
mobile apps use `claim` (medical fact-checking context). Both refer to the same concept:
the text being evaluated against the document for relevance scoring. This document uses
`question` for Python code and `claim` for Swift/Kotlin code to match each platform's
existing conventions.

## Python Implementation

### 1.1 Add Constants

**File**: `src/bmlibrarian_lite/constants.py`

Add these constants to the existing file (note: retry constants already exist, reuse them):

```python
# =============================================================================
# Parallel Processing Settings
# =============================================================================

# Concurrency levels for parallel LLM requests
CONCURRENCY_SEQUENTIAL = 1      # One request at a time (local inference)
CONCURRENCY_MODERATE = 3        # Moderate parallelism
CONCURRENCY_AGGRESSIVE = 5      # High parallelism
CONCURRENCY_CLOUD_DEFAULT = 3   # Default for cloud APIs

# Known large-scale providers that support parallel requests
# These providers have infrastructure to handle concurrent requests efficiently
PARALLEL_PROVIDERS: tuple[str, ...] = (
    "api.anthropic.com",
    "api.openai.com",
    "api.deepseek.com",
    "generativelanguage.googleapis.com",  # Google AI
    "api.groq.com",
    "api.together.xyz",
    "api.fireworks.ai",
    "api.mistral.ai",
    "api.cohere.ai",
)

# Cancellation check interval for async workers (seconds)
CANCELLATION_CHECK_INTERVAL_SECONDS = 0.1

# Cancellation timeout for waiting on workers (seconds)
CANCELLATION_TIMEOUT_SECONDS = 30

# Note: Reuse existing retry constants:
# - DEFAULT_MAX_RETRIES (3)
# - DEFAULT_RETRY_BASE_DELAY (1.0)
# - DEFAULT_RETRY_MAX_DELAY (10.0)
# - DEFAULT_RETRY_JITTER_FACTOR (0.2)
```

### 1.2 Provider Detection

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

### 1.3 Parallel Scoring Implementation

**File**: `src/bmlibrarian_lite/agents/parallel_scoring.py` (new file)

```python
"""
Parallel document scoring using asyncio.

This module provides parallel execution of document scoring, wrapping
the existing LiteScoringAgent for concurrent processing.
"""

import asyncio
import logging
import random
from dataclasses import dataclass
from typing import Callable, Optional

from ..constants import (
    DEFAULT_MAX_RETRIES,
    DEFAULT_RETRY_BASE_DELAY,
    DEFAULT_RETRY_MAX_DELAY,
    DEFAULT_RETRY_EXPONENTIAL_BASE,
    DEFAULT_RETRY_JITTER_FACTOR,
)
from ..data_models import LiteDocument, ScoredDocument
from .scoring_agent import LiteScoringAgent

logger = logging.getLogger(__name__)


@dataclass
class ParallelScoringResult:
    """
    Result of parallel scoring operation.

    Wraps ScoredDocument with additional error tracking for parallel execution.

    Attributes:
        scored_document: The scored document result (None if failed).
        error: Error message if scoring failed.
    """

    scored_document: Optional[ScoredDocument]
    error: Optional[str] = None

    @property
    def is_error(self) -> bool:
        """Check if this result represents an error."""
        return self.error is not None or (
            self.scored_document is not None and self.scored_document.score < 0
        )

    @property
    def document(self) -> Optional[LiteDocument]:
        """Get the underlying document."""
        return self.scored_document.document if self.scored_document else None

    @property
    def score(self) -> Optional[int]:
        """Get the score (None if error)."""
        if self.scored_document and self.scored_document.score > 0:
            return self.scored_document.score
        return None

    @property
    def explanation(self) -> Optional[str]:
        """Get the explanation."""
        return self.scored_document.explanation if self.scored_document else None


# Note: The calculate_backoff_delay function below is provided for reference
# and potential use in custom retry logic. Currently, the LiteScoringAgent
# handles retries internally via the @llm_retry decorator, so this function
# is not called in the parallel scoring implementation. It may be useful for
# future phases that require manual retry control.

def calculate_backoff_delay(attempt: int) -> float:
    """
    Calculate exponential backoff delay with jitter.

    Uses the existing retry constants from constants.py.

    Note: Currently unused as the agent handles retries via @llm_retry decorator.
    Provided for potential use in custom retry scenarios.

    Args:
        attempt: Zero-based attempt number.

    Returns:
        Delay in seconds with jitter applied.
    """
    base_delay = DEFAULT_RETRY_BASE_DELAY * (DEFAULT_RETRY_EXPONENTIAL_BASE ** attempt)
    # Apply jitter: delay * (1 ± jitter_factor)
    jitter_range = base_delay * DEFAULT_RETRY_JITTER_FACTOR
    jittered_delay = base_delay + random.uniform(-jitter_range, jitter_range)
    return min(max(jittered_delay, 0), DEFAULT_RETRY_MAX_DELAY)


async def score_single_document_async(
    agent: LiteScoringAgent,
    question: str,
    document: LiteDocument,
) -> ParallelScoringResult:
    """
    Score a single document asynchronously.

    Wraps the synchronous LiteScoringAgent.score_document() method
    to run in a thread pool executor.

    Note: The agent itself handles retries via @llm_retry decorator.
    This function provides the async wrapper for parallel execution.

    Args:
        agent: The scoring agent instance.
        question: Research question for scoring.
        document: The document to score.

    Returns:
        ParallelScoringResult with scored document or error.
    """
    try:
        loop = asyncio.get_running_loop()
        # Run blocking score_document in thread pool
        # Note: score_document(question, document) - question is first parameter
        scored_doc = await loop.run_in_executor(
            None, agent.score_document, question, document
        )

        # Check for error codes (negative scores indicate failures)
        if scored_doc.score < 0:
            return ParallelScoringResult(
                scored_document=scored_doc,
                error=scored_doc.explanation,
            )

        return ParallelScoringResult(scored_document=scored_doc)

    except Exception as e:
        logger.error(f"Unexpected error scoring document {document.id}: {e}")
        return ParallelScoringResult(
            scored_document=None,
            error=str(e),
        )


async def score_documents_parallel(
    documents: list[LiteDocument],
    question: str,
    agent_factory: Callable[[], LiteScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[str, int, int], None]] = None,
) -> list[ParallelScoringResult]:
    """
    Score multiple documents in parallel.

    Args:
        documents: List of documents to score.
        question: Research question for scoring.
        agent_factory: Factory function to create LiteScoringAgent instances.
            Each concurrent task gets its own agent instance.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback(pmid, current, total) for progress updates.

    Returns:
        List of ParallelScoringResult objects in same order as input documents.
    """
    semaphore = asyncio.Semaphore(max_concurrent)
    completed = 0
    total = len(documents)
    lock = asyncio.Lock()

    async def score_with_limit(doc: LiteDocument) -> ParallelScoringResult:
        nonlocal completed
        async with semaphore:
            agent = agent_factory()
            result = await score_single_document_async(agent, question, doc)

            async with lock:
                completed += 1
                current = completed

            if on_progress and doc.pmid:
                on_progress(doc.pmid, current, total)

            return result

    tasks = [score_with_limit(doc) for doc in documents]
    results = await asyncio.gather(*tasks, return_exceptions=False)

    return list(results)


def run_parallel_scoring(
    documents: list[LiteDocument],
    question: str,
    agent_factory: Callable[[], LiteScoringAgent],
    max_concurrent: int,
    on_progress: Optional[Callable[[str, int, int], None]] = None,
) -> list[ParallelScoringResult]:
    """
    Synchronous wrapper for parallel scoring.

    Creates a new event loop to run the async scoring. Use this from
    non-async code such as Qt worker threads.

    Warning: Do not call this from within an existing async context
    or from the Qt main thread. Use score_documents_parallel directly
    in async contexts.

    Args:
        documents: List of documents to score.
        question: Research question for scoring.
        agent_factory: Factory function to create LiteScoringAgent instances.
        max_concurrent: Maximum number of concurrent requests.
        on_progress: Optional callback(pmid, current, total) for progress updates.

    Returns:
        List of ParallelScoringResult objects.
    """
    return asyncio.run(
        score_documents_parallel(
            documents, question, agent_factory, max_concurrent, on_progress
        )
    )
```

### 1.4 Integration with SystematicReviewTab

**File**: `src/bmlibrarian_lite/gui/systematic_review_tab.py`

Modify the scoring worker to use parallel processing when appropriate:

```python
"""Worker thread for parallel document scoring."""

from PySide6.QtCore import QThread, Signal

from ..data_models import LiteDocument
from ..llm.concurrency import detect_concurrency, get_provider_url_from_config
from ..agents.parallel_scoring import run_parallel_scoring, ParallelScoringResult
from ..agents.scoring_agent import LiteScoringAgent


class ParallelScoringWorker(QThread):
    """
    Worker thread for parallel document scoring.

    Automatically detects appropriate concurrency level based on the
    configured LLM provider.

    Signals:
        progress: Emitted for each completed document (pmid, current, total).
        finished: Emitted when all documents are scored.
        error: Emitted if an unrecoverable error occurs.
    """

    progress = Signal(str, int, int)  # pmid, current, total
    finished = Signal(list)  # list[ParallelScoringResult]
    error = Signal(str)

    def __init__(
        self,
        documents: list[LiteDocument],
        question: str,
        config,
        parent=None,
    ):
        """
        Initialize the scoring worker.

        Args:
            documents: Documents to score.
            question: Research question for relevance scoring.
            config: Application configuration with LLM settings.
            parent: Optional parent QObject.
        """
        super().__init__(parent)
        self.documents = documents
        self.question = question
        self.config = config

    def run(self) -> None:
        """Execute parallel scoring in background thread."""
        try:
            # Detect appropriate concurrency level
            provider_url = get_provider_url_from_config(self.config)
            max_concurrent = detect_concurrency(
                provider_url,
                user_override=getattr(self.config, "concurrency_override", None),
            )

            def agent_factory() -> LiteScoringAgent:
                """Create a new agent instance for each concurrent task."""
                return LiteScoringAgent(self.config)

            def on_progress(pmid: str, current: int, total: int) -> None:
                """Emit progress signal for UI updates."""
                self.progress.emit(pmid, current, total)

            results = run_parallel_scoring(
                self.documents,
                self.question,
                agent_factory,
                max_concurrent,
                on_progress,
            )

            self.finished.emit(results)

        except Exception as e:
            self.error.emit(str(e))
```

### 1.5 Configuration Extension

**File**: `src/bmlibrarian_lite/config.py`

Add concurrency override to configuration:

```python
@dataclass
class LiteConfig:
    # ... existing fields ...

    # Parallel processing settings
    concurrency_override: Optional[int] = None  # None = auto-detect
```

## Swift Implementation (iOS/macOS)

### 1.1 Add Constants

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

### 1.2 Concurrency Detection

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

### 1.3 Parallel Scoring with TaskGroup

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

## Kotlin Implementation (Android)

### 1.1 Add Constants

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

### 1.2 Concurrency Detection

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

### 1.3 Parallel Scoring with Coroutines

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

## Testing Phase 1

```bash
# Python tests
pytest tests/test_concurrency.py -v
pytest tests/test_parallel_scoring.py -v

# Swift tests (Xcode)
xcodebuild test -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 15'

# Kotlin tests (Android Studio)
./gradlew :app:testDebugUnitTest
```

## Acceptance Criteria

- [ ] Provider detection correctly identifies cloud vs local providers
- [ ] User override in settings works correctly
- [ ] Parallel scoring completes faster than sequential for cloud providers
- [ ] Sequential behavior maintained for Ollama/local
- [ ] All existing tests pass
- [ ] No race conditions or data corruption
