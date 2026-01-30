# Android-iOS Feature Parity Plan for MedicalFactChecker

## Executive Summary

After thorough analysis of both codebases, I've identified significant gaps in the Android implementation compared to iOS. The iOS app is substantially more mature with advanced features like parallel processing, checkpoint-based resumption, embedding scoring, iCloud sync, background task management, and sophisticated error handling. The Android app has a solid foundation but requires substantial work to achieve parity.

---

## Feature Comparison Matrix

### Core Workflow Features

| Feature | iOS | Android | Status |
|---------|-----|---------|--------|
| Basic fact-check workflow | ✅ | ✅ | At parity |
| Query conversion (claim to PubMed) | ✅ | ✅ | At parity |
| PubMed search | ✅ | ✅ | At parity |
| Europe PMC search | ✅ | ✅ | At parity |
| Combined search (both providers) | ✅ | ✅ | At parity |
| Document scoring | ✅ | ✅ | At parity |
| Citation extraction | ✅ | ✅ | At parity |
| Report generation | ✅ | ✅ | At parity |
| Budget tracking (per-run & monthly) | ✅ | ✅ | At parity |

### Advanced Workflow Features

| Feature | iOS | Android | Priority |
|---------|-----|---------|----------|
| **Parallel document scoring** | ✅ (TaskGroup with max concurrency) | ❌ | **HIGH** |
| **Checkpoint-based resumption** | ✅ (Phase 2) | ❌ | **HIGH** |
| **Graceful cancellation** | ✅ (Phase 3) | Basic | **HIGH** |
| **Error queue with retry** | ✅ (Phase 4) | ❌ | **HIGH** |
| **Embedding scoring (NLEmbedding)** | ✅ | ❌ | **MEDIUM** |
| **Smart search (alternative queries)** | ✅ | Partial | **MEDIUM** |
| **Background task management** | ✅ (BGProcessingTask) | ❌ | **HIGH** |
| **Session refresh on resume** | ✅ | ❌ | **MEDIUM** |
| **Background pause/resume** | ✅ | ❌ | **MEDIUM** |

### Data & Persistence

| Feature | iOS | Android | Status |
|---------|-----|---------|--------|
| SwiftData/Room persistence | ✅ | ✅ | At parity |
| Document model | ✅ (28+ fields) | ✅ (similar) | At parity |
| Session pagination state | ✅ (both providers) | ✅ | At parity |
| Processing checkpoints | ✅ | ❌ | **Gap** |
| Error persistence | ✅ | ❌ | **Gap** |
| Usage records | ✅ | ✅ | At parity |
| **iCloud/Cloud sync** | ✅ (BioMedLit package) | ❌ | **Major Gap** |
| Selective sync/eviction | ✅ | ❌ | **Major Gap** |
| Session pinning | ✅ | ❌ | **Major Gap** |

### UI Features

| Feature | iOS | Android | Status |
|---------|-----|---------|--------|
| Fact check screen | ✅ | ✅ | At parity |
| Document cards | ✅ | ✅ | At parity |
| **Scored documents with sorting** | ✅ (4 sort options) | Basic | **Gap** |
| **Embedding score comparison** | ✅ | ❌ | **Gap** |
| **Error queue UI** | ✅ | ❌ | **Gap** |
| **Full text viewer** | ✅ (HTML/Markdown/PDF) | Basic | **Gap** |
| History screen | ✅ | ✅ | At parity |
| Report screen | ✅ | ✅ | At parity |
| Settings screen | ✅ | ✅ | Minor gaps |
| **Background status banner** | ✅ | ❌ | **Gap** |
| **Onboarding/Help** | ✅ | ❌ | **Gap** |
| **Key passages in document view** | ✅ | ❌ | **Gap** |

### Settings & Configuration

| Feature | iOS | Android | Status |
|---------|-----|---------|--------|
| LLM provider selection | ✅ | ✅ | At parity |
| Model selection | ✅ | ✅ | At parity |
| **Dynamic model fetching** | ✅ | ❌ | **Gap** |
| API connection test | ✅ | ✅ | At parity |
| API key storage (secure) | ✅ | ✅ | At parity |
| Search provider selection | ✅ | ✅ | At parity |
| Batch size setting | ✅ | ✅ | At parity |
| Relevance threshold | ✅ | ✅ | At parity |
| **Embedding scoring toggle** | ✅ | ❌ | **Gap** |
| **Parallel processing concurrency** | ✅ | ❌ | **Gap** |
| Budget limits | ✅ | ✅ | At parity |
| **Clear all data** | ✅ | ❌ | **Gap** |

### LLM Provider Model Updates Needed

| Provider | iOS Models | Android Needs Update |
|----------|------------|---------------------|
| Anthropic | Claude 4.5 series | Add Claude 4.5 |
| OpenAI | GPT-5.2, o4-mini, o3, 4o | Update to latest |
| DeepSeek | V3.2 | Update to V3.2 |
| Groq | Llama 4 series | Update to Llama 4 |
| Mistral | Large 3, Medium, Small | Minor updates |
| Ollama | llama3.2, mistral | At parity |

---

## Prioritized Implementation Plan

### Phase 1: Critical Core Features (Weeks 1-3)
**Goal: Achieve functional parity for core workflow reliability**

#### 1.1 Parallel Document Scoring Service
**Complexity: HIGH** | **Priority: CRITICAL**

**Files to create:**
- `domain/workflow/ParallelScoringService.kt`
- `domain/workflow/ScoringInput.kt`
- `domain/workflow/ScoringResult.kt`

**Implementation:**
```kotlin
// Use Kotlin coroutines with async/awaitAll for parallel execution
class ParallelScoringService @Inject constructor(
    private val llmApi: LLMApi,
    private val settings: UserSettings
) {
    private val concurrencyLimit = settings.parallelConcurrency // Default: 3 for cloud, 1 for Ollama

    suspend fun scoreDocuments(
        documents: List<Document>,
        claim: String,
        onProgress: (Int, Int) -> Unit
    ): List<ScoringResult> = coroutineScope {
        documents
            .chunked(concurrencyLimit)
            .flatMap { batch ->
                batch.map { doc ->
                    async { scoreDocument(doc, claim) }
                }.awaitAll()
                    .also { onProgress(it.size, documents.size) }
            }
    }
}
```

**Reference:** `ios/MedicalFactChecker/Sources/Services/ParallelScoringService.swift`

#### 1.2 Checkpoint Manager
**Complexity: HIGH** | **Priority: CRITICAL**

**Files to create:**
- `data/local/entity/ProcessingCheckpoint.kt`
- `data/local/dao/CheckpointDao.kt`
- `domain/workflow/CheckpointManager.kt`

**Database Entity:**
```kotlin
@Entity(tableName = "processing_checkpoints")
data class ProcessingCheckpoint(
    @PrimaryKey val sessionId: String,
    val phase: String,
    val completedDocumentIds: String, // JSON array
    val scoringResults: String, // JSON map
    val lastUpdated: Long
)
```

**Reference:** `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift`

#### 1.3 Graceful Cancellation Support
**Complexity: MEDIUM** | **Priority: HIGH**

**Files to modify:**
- `domain/workflow/FactCheckWorkflow.kt`

**Implementation:**
- Add `Job` tracking for workflow coroutine
- Implement cooperative cancellation with `isActive` checks
- Preserve checkpointed work on cancel
- Set session state to `AWAITING_USER_DECISION` on cancel

#### 1.4 Error Queue with Retry
**Complexity: MEDIUM** | **Priority: HIGH**

**Files to create:**
- `data/local/entity/ProcessingError.kt`
- `data/local/dao/ProcessingErrorDao.kt`
- `domain/workflow/ErrorPersistenceManager.kt`
- `ui/factcheck/components/ErrorQueueView.kt`

**Database Entity:**
```kotlin
@Entity(tableName = "processing_errors")
data class ProcessingError(
    @PrimaryKey(autoGenerate = true) val id: Long = 0,
    val sessionId: String,
    val documentId: String,
    val errorType: String,
    val errorMessage: String,
    val retryCount: Int = 0,
    val createdAt: Long
)
```

---

### Phase 2: Advanced Scoring & Processing (Weeks 4-5)
**Goal: Add smart scoring and processing features**

#### 2.1 Embedding Scoring Service
**Complexity: HIGH** | **Priority: MEDIUM**

**Files to create:**
- `domain/embedding/EmbeddingService.kt`
- `domain/embedding/SimilarityCalculator.kt`

**Implementation Options:**
1. **ML Kit** (Recommended) - Google's on-device ML
2. **TensorFlow Lite** - Custom sentence embeddings
3. **Remote API** - Simpler but requires network

**Features:**
- Compute semantic similarity between claim and documents
- Normalize to 1-5 relevance scale
- Display alongside LLM scores in UI
- Add settings toggle

#### 2.2 Document Entity Updates
**Complexity: LOW** | **Priority: HIGH**

**Files to modify:**
- `data/local/entity/DocumentEntity.kt`
- `domain/model/Document.kt`

**Add fields:**
```kotlin
val embeddingScore: Double? = null,
val embeddingScoreNormalized: Int? = null,
val scoreParseFailed: Boolean = false,
val fullTextHTML: String? = null
```

#### 2.3 Sorted Documents View
**Complexity: LOW** | **Priority: MEDIUM**

**Files to create/modify:**
- `ui/factcheck/components/SortingControls.kt`
- Modify `FactCheckScreen.kt`

**Implementation:**
```kotlin
enum class DocumentSortOrder {
    SCORE_HIGH_TO_LOW,
    SCORE_LOW_TO_HIGH,
    BATCH_ORDER,
    ALPHABETICAL
}
```

---

### Phase 3: Background Processing & Reliability (Weeks 6-7)
**Goal: Reliable background execution and state management**

#### 3.1 Background Task Manager with WorkManager
**Complexity: HIGH** | **Priority: HIGH**

**Files to create:**
- `service/BackgroundWorkManager.kt`
- `service/FactCheckWorker.kt`

**Implementation:**
```kotlin
class FactCheckWorker(
    context: Context,
    params: WorkerParameters
) : CoroutineWorker(context, params) {

    override suspend fun doWork(): Result {
        // Run as foreground service for long operations
        setForeground(createForegroundInfo())

        // Execute workflow with checkpoint support
        return try {
            workflow.execute()
            Result.success()
        } catch (e: Exception) {
            if (runAttemptCount < 3) Result.retry()
            else Result.failure()
        }
    }
}
```

**Reference:** `ios/MedicalFactChecker/Sources/Services/BackgroundTaskManager.swift`

#### 3.2 Session Refresh on Resume
**Complexity: MEDIUM** | **Priority: MEDIUM**

**Files to modify:**
- `domain/workflow/FactCheckWorkflow.kt`

**Implementation:**
- Add `isResumedSession` flag
- Re-execute search to refresh pagination on resume
- Deduplicate against existing documents
- Handle expired Europe PMC cursors (5-minute expiry)

#### 3.3 Background Pause/Resume UI
**Complexity: LOW** | **Priority: MEDIUM**

**Files to create:**
- `ui/common/BackgroundStatusBanner.kt`

```kotlin
@Composable
fun BackgroundStatusBanner(
    isPaused: Boolean,
    onResume: () -> Unit,
    onDismiss: () -> Unit
)
```

---

### Phase 4: UI Enhancements (Weeks 8-9)
**Goal: UI feature parity**

#### 4.1 Full Text Viewer Enhancement
**Complexity: MEDIUM** | **Priority: MEDIUM**

**Files to modify:**
- `ui/fulltext/FullTextScreen.kt`

**Features:**
- HTML rendering via WebView
- PDF viewer integration (AndroidPdfViewer library)
- Source badges (PMC OA, Unpaywall, etc.)
- Loading states and error handling

#### 4.2 Key Passages in Document View
**Complexity: LOW** | **Priority: LOW**

**Files to modify:**
- `ui/factcheck/components/DocumentCard.kt`

**Features:**
- Display extracted citations in expanded view
- Style with quote icons
- Show relevance explanation from scoring

#### 4.3 Onboarding & Help Screens
**Complexity: LOW** | **Priority: LOW**

**Files to create:**
- `ui/onboarding/OnboardingScreen.kt`
- `ui/help/HelpScreen.kt`

#### 4.4 Settings Enhancements
**Complexity: LOW** | **Priority: MEDIUM**

**Additions needed:**
- Dynamic model fetching from provider APIs
- Embedding scoring toggle
- Parallel concurrency setting
- Clear all data option

---

### Phase 5: Model Updates (Week 10)
**Goal: Keep model lists current**

#### 5.1 Update LLM Provider Models
**Complexity: LOW** | **Priority: MEDIUM**

**File to modify:**
- `domain/model/LLMProvider.kt`

**Updates needed:**
```kotlin
// Anthropic
"claude-opus-4-5-20251101" to "Claude 4.5 Opus",
"claude-sonnet-4-5-20251101" to "Claude 4.5 Sonnet",

// OpenAI
"gpt-5.2-turbo" to "GPT-5.2 Turbo",
"o4-mini" to "o4-mini",
"o3" to "o3",

// DeepSeek
"deepseek-v3.2" to "DeepSeek V3.2",

// Groq
"llama-4-70b" to "Llama 4 70B",
"llama-4-scout" to "Llama 4 Scout",
```

#### 5.2 Dynamic Model Fetching
**Complexity: MEDIUM** | **Priority: LOW**

**Files to create:**
- `data/remote/llm/ModelFetchService.kt`

---

### Phase 6: Cloud Sync (Weeks 11-14) - OPTIONAL
**Goal: Cross-device synchronization**

This is the largest gap and could be a separate project.

#### Option A: Firebase-Based Sync (Recommended for Android)
- Firebase Realtime Database or Firestore
- Firebase Auth for user identity
- Implement LWW (Last-Write-Wins) merge strategy
- Selective sync with storage limits

#### Option B: Custom Backend
- REST API with JWT auth
- PostgreSQL backend
- Match iOS sync protocol for cross-platform

#### Option C: Skip (Android Local-Only)
- Accept Android as single-device only
- Focus on other parity items first

---

## Estimated Effort Summary

| Phase | Duration | Complexity | Priority |
|-------|----------|------------|----------|
| Phase 1: Core Features | 3 weeks | High | Critical |
| Phase 2: Advanced Scoring | 2 weeks | High | High |
| Phase 3: Background Processing | 2 weeks | High | High |
| Phase 4: UI Enhancements | 2 weeks | Medium | Medium |
| Phase 5: Model Updates | 1 week | Low | Medium |
| Phase 6: Cloud Sync | 4 weeks | Very High | Optional |

**Total without sync: ~10 weeks**
**Total with sync: ~14 weeks**

---

## Key Reference Files

### iOS Reference Implementations
- `ios/MedicalFactChecker/Sources/Services/ParallelScoringService.swift` - Parallel scoring pattern
- `ios/MedicalFactChecker/Sources/Services/CheckpointManager.swift` - Checkpoint persistence
- `ios/MedicalFactChecker/Sources/Services/BackgroundTaskManager.swift` - Background tasks
- `ios/MedicalFactChecker/Sources/Services/EmbeddingService.swift` - Embedding scoring
- `Packages/BioMedLit/Sources/BioMedLit/Sync/` - Sync infrastructure

### Android Files to Modify/Extend
- `android/.../domain/workflow/FactCheckWorkflow.kt` - Core workflow
- `android/.../data/local/AppDatabase.kt` - Room database
- `android/.../domain/model/LLMProvider.kt` - Provider models
- `android/.../ui/factcheck/FactCheckScreen.kt` - Main UI

---

## Quick Wins (Can Start Immediately)

1. **Model Updates** - Simple file changes, immediate value
2. **Document sorting** - Small UI addition
3. **Clear all data** - Settings enhancement
4. **Key passages display** - UI polish

## Dependencies

```
Phase 1.2 (Checkpoints) ──► Phase 1.3 (Cancellation)
Phase 1.1 (Parallel) ─────► Phase 2.1 (Embedding)
Phase 1.4 (Errors) ───────► Phase 3.1 (Background)
Phase 2.1 (Embedding) ────► Phase 4.4 (Settings toggle)
```

---

## Success Metrics

- [ ] Parallel scoring reduces total processing time by 50%+
- [ ] Checkpoint resumption works after app kill
- [ ] Error retry succeeds for transient failures
- [ ] Background processing completes when app backgrounded
- [ ] All iOS features have Android equivalents (except iCloud-specific)
