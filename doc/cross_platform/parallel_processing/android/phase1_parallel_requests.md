# Phase 1: Provider Detection and Parallel Requests (Android/Kotlin)

## Objective

Enable parallel LLM requests for cloud providers while maintaining sequential behavior for local inference.

## 1.1 Add Constants

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

## 1.2 Concurrency Detection

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/util/ConcurrencyDetector.kt`

```kotlin
package com.bmlibrarian.factchecker.util

import java.net.URL

/**
 * Detects appropriate concurrency level based on LLM provider.
 */
object ConcurrencyDetector {
    /**
     * Detect appropriate concurrency level based on provider URL.
     *
     * @param providerUrl The LLM API endpoint URL.
     * @param userOverride Optional user-specified concurrency level.
     * @return Number of concurrent requests to allow.
     */
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

## 1.3 Scoring Result Model

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/model/ScoringResult.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.model

/**
 * Result of scoring a single document.
 */
sealed class ScoringResult {
    abstract val document: Document

    /**
     * Successful scoring result.
     */
    data class Success(
        override val document: Document,
        val score: Int,
        val rationale: String
    ) : ScoringResult()

    /**
     * Failed scoring result.
     */
    data class Error(
        override val document: Document,
        val exception: Exception
    ) : ScoringResult()

    val isError: Boolean
        get() = this is Error
}
```

## 1.4 Parallel Scoring with Coroutines

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/ParallelScoringUseCase.kt`

```kotlin
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.domain.model.Document
import com.bmlibrarian.factchecker.domain.model.ScoringResult
import com.bmlibrarian.factchecker.domain.repository.ScoringRepository
import kotlinx.coroutines.async
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.sync.Semaphore
import kotlinx.coroutines.sync.withPermit
import javax.inject.Inject

/**
 * Use case for parallel document scoring.
 *
 * Uses Kotlin coroutines with a semaphore to limit concurrent requests
 * while emitting results as they complete via Flow.
 */
class ParallelScoringUseCase @Inject constructor(
    private val scoringRepository: ScoringRepository
) {
    /**
     * Score multiple documents in parallel.
     *
     * @param documents Documents to score.
     * @param claim The medical claim to verify.
     * @param maxConcurrent Maximum concurrent requests.
     * @return Flow emitting scoring results as they complete.
     */
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

    /**
     * Score documents and collect all results.
     *
     * Convenience method that collects the flow into a list.
     *
     * @param documents Documents to score.
     * @param claim The medical claim to verify.
     * @param maxConcurrent Maximum concurrent requests.
     * @param onProgress Callback for progress updates (current, total).
     * @return List of all scoring results.
     */
    suspend fun scoreDocumentsWithProgress(
        documents: List<Document>,
        claim: String,
        maxConcurrent: Int,
        onProgress: (Int, Int) -> Unit
    ): List<ScoringResult> {
        val results = mutableListOf<ScoringResult>()
        var completed = 0
        val total = documents.count()

        scoreDocuments(documents, claim, maxConcurrent).collect { result ->
            results.add(result)
            completed++
            onProgress(completed, total)
        }

        return results
    }
}
```

## 1.5 ViewModel Integration

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/ui/factcheck/FactCheckViewModel.kt`

Add parallel scoring support to the ViewModel:

```kotlin
// In FactCheckViewModel.kt, add these imports and methods:

import com.bmlibrarian.factchecker.util.ConcurrencyDetector
import com.bmlibrarian.factchecker.domain.usecase.ParallelScoringUseCase

@HiltViewModel
class FactCheckViewModel @Inject constructor(
    private val parallelScoringUseCase: ParallelScoringUseCase,
    private val settingsRepository: SettingsRepository,
    // ... other dependencies
) : ViewModel() {

    private val _scoringProgress = MutableStateFlow(0f)
    val scoringProgress: StateFlow<Float> = _scoringProgress.asStateFlow()

    fun scoreDocuments(documents: List<Document>, claim: String) {
        viewModelScope.launch {
            val providerUrl = settingsRepository.getLLMProviderUrl()
            val userOverride = settingsRepository.getConcurrencyOverride()
            val maxConcurrent = ConcurrencyDetector.detectConcurrency(providerUrl, userOverride)

            val results = parallelScoringUseCase.scoreDocumentsWithProgress(
                documents = documents,
                claim = claim,
                maxConcurrent = maxConcurrent
            ) { current, total ->
                _scoringProgress.value = current.toFloat() / total
            }

            // Process results...
            handleScoringResults(results)
        }
    }
}
```

## 1.6 Hilt Module

**File**: `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/di/UseCaseModule.kt`

```kotlin
package com.bmlibrarian.factchecker.di

import com.bmlibrarian.factchecker.domain.repository.ScoringRepository
import com.bmlibrarian.factchecker.domain.usecase.ParallelScoringUseCase
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

@Module
@InstallIn(SingletonComponent::class)
object UseCaseModule {

    @Provides
    @Singleton
    fun provideParallelScoringUseCase(
        scoringRepository: ScoringRepository
    ): ParallelScoringUseCase {
        return ParallelScoringUseCase(scoringRepository)
    }
}
```

## Testing

```bash
# Run unit tests
./gradlew :app:testDebugUnitTest

# Run specific test class
./gradlew :app:testDebugUnitTest --tests "com.bmlibrarian.factchecker.util.ConcurrencyDetectorTest"

# Run instrumented tests
./gradlew :app:connectedDebugAndroidTest

# Run all tests with coverage
./gradlew :app:testDebugUnitTest --coverage
```

### Example Unit Test

**File**: `android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/util/ConcurrencyDetectorTest.kt`

```kotlin
package com.bmlibrarian.factchecker.util

import org.junit.Assert.assertEquals
import org.junit.Test

class ConcurrencyDetectorTest {

    @Test
    fun `detectConcurrency returns cloud default for Anthropic`() {
        val result = ConcurrencyDetector.detectConcurrency("https://api.anthropic.com/v1/messages")
        assertEquals(ParallelProcessingConstants.CONCURRENCY_CLOUD_DEFAULT, result)
    }

    @Test
    fun `detectConcurrency returns sequential for localhost`() {
        val result = ConcurrencyDetector.detectConcurrency("http://localhost:11434/api/generate")
        assertEquals(ParallelProcessingConstants.CONCURRENCY_SEQUENTIAL, result)
    }

    @Test
    fun `detectConcurrency respects user override`() {
        val result = ConcurrencyDetector.detectConcurrency(
            "https://api.anthropic.com/v1/messages",
            userOverride = 5
        )
        assertEquals(5, result)
    }

    @Test
    fun `detectConcurrency returns sequential for invalid URL`() {
        val result = ConcurrencyDetector.detectConcurrency("not-a-valid-url")
        assertEquals(ParallelProcessingConstants.CONCURRENCY_SEQUENTIAL, result)
    }
}
```

## Acceptance Criteria

- [ ] Provider detection correctly identifies cloud vs local providers
- [ ] User override in settings works correctly
- [ ] Parallel scoring completes faster than sequential for cloud providers
- [ ] Sequential behavior maintained for Ollama/local
- [ ] All existing tests pass
- [ ] No race conditions or data corruption
- [ ] Flow emissions work correctly for UI updates
- [ ] Hilt dependency injection configured properly
