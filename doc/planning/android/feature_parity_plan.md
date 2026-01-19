# Android Feature Parity Implementation Plan

This document outlines the implementation plan to bring the Android MedicalFactChecker app up to feature parity with the iOS version.

## Executive Summary

The Android app has solid core functionality (hybrid search, LLM scoring, report generation, budget controls) but lacks several important iOS features:

| Priority | Feature | Effort | Impact |
|----------|---------|--------|--------|
| P0 | Full-Text Viewer | High | Critical for research utility |
| P0 | JATS XML Parsing | High | Required for full-text display |
| P1 | Onboarding System | Medium | First-run experience |
| P1 | Disclaimer Screen | Low | Legal compliance |
| P1 | Help Documentation | Medium | User assistance |
| P1 | Smart Search (Alternative Queries) | Medium | Better search results |
| P2 | On-Device Embeddings | High | Cost-free relevance scoring |
| P2 | HyDE Generation | Low | Better embedding matching |
| P3 | Cloud Sync | High | Cross-device continuity |

---

## Phase 1: Critical Full-Text Features (P0)

### 1.1 JATS XML Parser

**Goal**: Parse Europe PMC JATS XML into displayable HTML/Markdown

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/util/jats/`

**Implementation**:

```kotlin
// JATSXMLParser.kt
class JATSXMLParser(
    private val xmlData: ByteArray,
    private val knownPMCId: String?
) {
    data class JATSArticle(
        val title: String,
        val authors: List<Author>,
        val abstract: String?,
        val sections: List<Section>,
        val figures: List<Figure>,
        val tables: List<Table>,
        val references: List<Reference>
    )

    fun parseToMarkdown(): String
    fun parseToHTML(): String
    fun parseToArticle(): JATSArticle
}
```

**Key Parsing Tasks**:
1. Extract article metadata (`<article-meta>`)
2. Parse body sections (`<body><sec>`)
3. Extract figures with Europe PMC URLs (`<fig>`)
4. Parse tables with proper formatting (`<table-wrap>`)
5. Handle references (`<ref-list>`)
6. Convert inline elements (bold, italic, subscript, superscript)

**Reference**: See `doc/cross_platform/jats_parsing.md` and `Packages/BioMedLit/Sources/BioMedLit/JATSXMLParser.swift`

### 1.2 Full-Text Viewer Screen

**Goal**: Display full-text content from multiple sources

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/fulltext/`

**Components**:

```kotlin
// FullTextScreen.kt - Main viewer
@Composable
fun FullTextScreen(
    document: Document,
    viewModel: FullTextViewModel
)

// FullTextViewModel.kt - State management
class FullTextViewModel @Inject constructor(
    private val fullTextRepository: FullTextRepository
) : ViewModel() {
    sealed class FullTextState {
        object Loading : FullTextState()
        data class HtmlContent(val html: String) : FullTextState()
        data class MarkdownContent(val markdown: String) : FullTextState()
        data class PdfContent(val uri: Uri) : FullTextState()
        data class WebUrl(val url: String) : FullTextState()
        data class Error(val message: String) : FullTextState()
        object Unavailable : FullTextState()
    }
}
```

**Content Renderers**:

1. **HTML Renderer** (for JATS XML converted content)
   - Use AndroidView with WebView
   - Enable JavaScript for interactive tables
   - Handle image loading from Europe PMC URLs
   - Support zoom and scroll

2. **Markdown Renderer**
   - Use existing markdown library (Markwon or similar)
   - Support code blocks, tables, lists
   - Render in ScrollView

3. **PDF Viewer**
   - Use AndroidPdfViewer library or PdfRenderer API
   - Page navigation
   - Zoom controls
   - Download/cache PDFs locally

4. **Web Fallback**
   - Open in Custom Chrome Tab
   - Fall back to DOI URL

**UI Features**:
- Source badge showing where content came from
- Share button
- Loading states
- Error handling with retry

### 1.3 Full-Text Retrieval Service

**Goal**: Implement the 3-source fallback chain

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/data/remote/fulltext/`

```kotlin
// FullTextService.kt
class FullTextService @Inject constructor(
    private val europePMCApi: EuropePMCApi,
    private val httpClient: OkHttpClient
) {
    sealed class FullTextResult {
        data class EuropePMCXml(val xml: String) : FullTextResult()
        data class UnpaywallPdf(val pdfUrl: String) : FullTextResult()
        data class DoiUrl(val url: String) : FullTextResult()
        object Unavailable : FullTextResult()
    }

    suspend fun fetchFullText(
        pmcId: String?,
        doi: String?,
        pmid: String?
    ): FullTextResult
}
```

**Fallback Chain**:
1. **Europe PMC XML**: If PMC ID available, fetch JATS XML
2. **Unpaywall API**: If DOI available, query `https://api.unpaywall.org/v2/{doi}?email={email}`
3. **DOI Resolution**: Fall back to `https://doi.org/{doi}`

**Caching**:
- Cache downloaded PDFs in app cache directory
- Store parsed markdown/HTML in Room database
- Track full-text source in Document entity

### 1.4 Database Schema Updates

Add to `DocumentEntity`:

```kotlin
@Entity(tableName = "documents")
data class DocumentEntity(
    // ... existing fields ...

    // Full-text fields
    @ColumnInfo(name = "full_text_content") val fullTextContent: String? = null,
    @ColumnInfo(name = "full_text_source") val fullTextSource: String? = null, // europepmc, unpaywall, doi
    @ColumnInfo(name = "full_text_fetched_at") val fullTextFetchedAt: Long? = null,
    @ColumnInfo(name = "full_text_unavailable") val fullTextUnavailable: Boolean = false,
    @ColumnInfo(name = "pdf_cache_path") val pdfCachePath: String? = null
)
```

---

## Phase 2: User Experience Features (P1)

### 2.1 Onboarding System

**Goal**: Guided first-run experience explaining app features

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/onboarding/`

**Components**:

```kotlin
// OnboardingScreen.kt
@Composable
fun OnboardingScreen(
    onComplete: () -> Unit
)

// OnboardingPage.kt
data class OnboardingPage(
    val title: String,
    val description: String,
    val imageRes: Int
)
```

**Pages** (mirror iOS):
1. **Welcome**: Introduction to Medical Fact Checker
2. **How It Works**: Claim → Search → Score → Report workflow
3. **Search Providers**: PubMed and Europe PMC explanation
4. **AI Scoring**: How LLM evaluates relevance
5. **Get Started**: Configure API key prompt

**Implementation**:
- Use HorizontalPager from Accompanist
- Store `hasCompletedOnboarding` in DataStore
- Show on first launch only
- Skip button available

### 2.2 Disclaimer Screen

**Goal**: Legal disclaimer before first use

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/disclaimer/`

```kotlin
@Composable
fun DisclaimerScreen(
    onAccept: () -> Unit
)
```

**Content**:
- App is for informational purposes only
- Not a substitute for professional medical advice
- AI limitations and potential errors
- User responsibility acknowledgment
- "I Understand" acceptance button

**Storage**: `hasAcceptedDisclaimer` in DataStore

### 2.3 Help Documentation

**Goal**: In-app help with usage guidance

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/help/`

**Components**:

```kotlin
@Composable
fun HelpScreen()

// Topics
sealed class HelpTopic {
    object GettingStarted : HelpTopic()
    object SearchProviders : HelpTopic()
    object UnderstandingScores : HelpTopic()
    object ReadingReports : HelpTopic()
    object ConfiguringLLM : HelpTopic()
    object BudgetManagement : HelpTopic()
    object Troubleshooting : HelpTopic()
}
```

**Implementation**:
- Markdown content stored in `assets/help/`
- Render with Markwon library
- Collapsible sections for FAQs
- Link from Settings screen

### 2.4 Smart Search (Alternative Queries)

**Goal**: Generate alternative search queries when initial results are poor

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/`

**Implementation**:

```kotlin
// GenerateAlternativeQueriesUseCase.kt
class GenerateAlternativeQueriesUseCase @Inject constructor(
    private val llmService: LLMService
) {
    data class AlternativeQuery(
        val query: String,
        val strategy: String,
        val rationale: String
    )

    suspend fun execute(
        originalClaim: String,
        originalQuery: String,
        foundCount: Int
    ): List<AlternativeQuery>
}
```

**Workflow Integration**:
1. If `relevantCount < 3` after initial search, trigger smart search
2. Generate 2-3 alternative queries using different strategies:
   - Broader terms (remove specificity)
   - Related concepts (synonyms, MeSH alternatives)
   - Different phrasing
3. Execute searches with deduplication against existing PMIDs
4. UI: Show "Trying alternative search..." progress
5. Store alternative queries in session for audit

**Session Entity Updates**:

```kotlin
@ColumnInfo(name = "smart_search_enabled") val smartSearchEnabled: Boolean = false,
@ColumnInfo(name = "alternative_queries") val alternativeQueries: String? = null, // JSON array
@ColumnInfo(name = "current_query_index") val currentQueryIndex: Int = 0,
@ColumnInfo(name = "fetched_pmids") val fetchedPmids: String? = null // JSON array for deduplication
```

---

## Phase 3: Advanced Scoring Features (P2)

### 3.1 On-Device Embedding Service

**Goal**: Free, on-device semantic similarity scoring

**Options**:
1. **TensorFlow Lite** with Universal Sentence Encoder
2. **ML Kit** (limited embedding support)
3. **ONNX Runtime** with sentence-transformers model

**Recommended**: TensorFlow Lite with USE (Universal Sentence Encoder)

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ml/`

```kotlin
// EmbeddingService.kt
class EmbeddingService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var interpreter: Interpreter? = null

    suspend fun initialize()

    suspend fun computeSimilarity(
        claim: String,
        documents: List<Document>
    ): List<EmbeddingScore>

    data class EmbeddingScore(
        val documentId: String,
        val rawScore: Float,      // 0.0 - 1.0 cosine similarity
        val normalizedScore: Int  // 1-5 scale
    )
}
```

**Normalization** (match iOS thresholds):
- `< 0.3` → 1
- `0.3 - 0.45` → 2
- `0.45 - 0.55` → 3
- `0.55 - 0.7` → 4
- `>= 0.7` → 5

**Model Selection**:
- Universal Sentence Encoder Lite (~25MB)
- Or MiniLM-L6-v2 ONNX (~22MB)

**Settings Integration**:
- Add `embeddingScoringEnabled` preference
- Toggle in Settings UI
- Display dual scores in DocumentCard

### 3.2 HyDE (Hypothetical Document Embedding)

**Goal**: Generate synthetic "ideal" abstract for better embedding matching

**Implementation**:

```kotlin
// HydeGenerator.kt
class HydeGenerator @Inject constructor(
    private val llmService: LLMService
) {
    suspend fun generateHypotheticalAbstract(claim: String): String
}
```

**Prompt**:
```
Given the medical claim: "{claim}"

Write a hypothetical abstract (150-200 words) of a scientific study that would
directly address this claim. Include typical abstract sections: Background,
Methods, Results, Conclusion. Use medical terminology appropriate for a
peer-reviewed publication.
```

**Workflow**:
1. Before embedding scoring, generate HyDE abstract
2. Use HyDE abstract (instead of raw claim) for embedding comparison
3. Cache HyDE abstract in session

**Session Entity**:
```kotlin
@ColumnInfo(name = "hyde_abstract") val hydeAbstract: String? = null
```

---

## Phase 4: Cloud Sync (P3)

### 4.1 Firebase/Cloud Sync Architecture

**Goal**: Cross-device session synchronization

**Options**:
1. **Firebase Firestore** - Real-time sync, offline support
2. **Firebase Realtime Database** - Simpler, good for basic sync
3. **Custom backend** - More control, more work

**Recommended**: Firebase Firestore with offline persistence

**Implementation Strategy**:

1. **Authentication**:
   - Optional Google Sign-In
   - Anonymous auth for device-only sync

2. **Data Model** (Firestore):
   ```
   users/{userId}/sessions/{sessionId}
   users/{userId}/documents/{documentId}
   users/{userId}/reports/{reportId}
   users/{userId}/usage/{monthKey}
   ```

3. **Sync Logic**:
   - Write-through to Firestore on local changes
   - Listen for remote changes
   - Conflict resolution: latest timestamp wins
   - Offline-first with sync on reconnect

4. **Settings**:
   - `cloudSyncEnabled` preference
   - Privacy warning on enable
   - Manual sync trigger option

---

## Implementation Order and Dependencies

```
Phase 1 (Critical)
├── 1.1 JATS XML Parser
│   └── 1.3 Full-Text Retrieval Service (depends on parser)
│       └── 1.2 Full-Text Viewer Screen (depends on retrieval)
└── 1.4 Database Schema Updates (parallel)

Phase 2 (User Experience)
├── 2.1 Onboarding System (independent)
├── 2.2 Disclaimer Screen (independent)
├── 2.3 Help Documentation (independent)
└── 2.4 Smart Search (depends on workflow understanding)

Phase 3 (Advanced)
├── 3.1 On-Device Embeddings (independent)
└── 3.2 HyDE Generation (depends on 3.1 for usefulness)

Phase 4 (Cloud)
└── 4.1 Cloud Sync (independent but complex)
```

---

## File Structure for New Features

```
app/src/main/java/com/bmlibrarian/factchecker/
├── data/
│   └── remote/
│       └── fulltext/
│           ├── FullTextService.kt
│           └── UnpaywallApi.kt
├── domain/
│   └── usecase/
│       ├── FetchFullTextUseCase.kt
│       └── GenerateAlternativeQueriesUseCase.kt
├── ml/
│   ├── EmbeddingService.kt
│   └── HydeGenerator.kt
├── ui/
│   ├── fulltext/
│   │   ├── FullTextScreen.kt
│   │   ├── FullTextViewModel.kt
│   │   └── components/
│   │       ├── HtmlViewer.kt
│   │       ├── MarkdownViewer.kt
│   │       └── PdfViewer.kt
│   ├── onboarding/
│   │   ├── OnboardingScreen.kt
│   │   └── OnboardingViewModel.kt
│   ├── disclaimer/
│   │   └── DisclaimerScreen.kt
│   └── help/
│       ├── HelpScreen.kt
│       └── HelpViewModel.kt
└── util/
    └── jats/
        ├── JATSXMLParser.kt
        └── JATSModels.kt

app/src/main/assets/
└── help/
    ├── getting_started.md
    ├── search_providers.md
    ├── understanding_scores.md
    └── troubleshooting.md

app/src/main/ml/
└── universal_sentence_encoder.tflite
```

---

## Dependencies to Add

```kotlin
// build.gradle.kts (app)
dependencies {
    // PDF Viewer
    implementation("com.github.barteksc:android-pdf-viewer:3.2.0-beta.1")

    // Markdown rendering
    implementation("io.noties.markwon:core:4.6.2")
    implementation("io.noties.markwon:html:4.6.2")
    implementation("io.noties.markwon:image:4.6.2")

    // XML parsing (for JATS)
    implementation("org.xmlpull:xmlpull:1.1.3.1")

    // TensorFlow Lite (for embeddings)
    implementation("org.tensorflow:tensorflow-lite:2.14.0")
    implementation("org.tensorflow:tensorflow-lite-support:0.4.4")

    // Firebase (for cloud sync - Phase 4)
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))
    implementation("com.google.firebase:firebase-firestore-ktx")
    implementation("com.google.firebase:firebase-auth-ktx")

    // Pager for onboarding
    implementation("com.google.accompanist:accompanist-pager:0.32.0")
    implementation("com.google.accompanist:accompanist-pager-indicators:0.32.0")
}
```

---

## Testing Strategy

### Unit Tests
- JATS XML parsing with sample Europe PMC responses
- Full-text fallback chain logic
- Alternative query generation parsing
- Embedding normalization calculations
- HyDE prompt construction

### Integration Tests
- Full-text retrieval end-to-end
- Smart search workflow integration
- Onboarding flow completion
- Settings persistence

### UI Tests
- Full-text viewer navigation
- Onboarding page transitions
- Help screen rendering
- Document card with dual scores

---

## Metrics for Success

| Feature | Success Metric |
|---------|---------------|
| Full-Text Viewer | Can display Europe PMC XML, Unpaywall PDFs |
| JATS Parser | Correctly parses 95%+ of Europe PMC articles |
| Onboarding | Completion rate > 80% |
| Smart Search | Improves relevant doc discovery by 30%+ |
| Embeddings | Scores correlate with LLM scores (r > 0.6) |
| Cloud Sync | < 5s sync latency, conflict-free merges |

---

## Risk Mitigation

| Risk | Mitigation |
|------|------------|
| JATS parsing complexity | Start with common elements, iterate |
| PDF viewer performance | Use native PdfRenderer, limit zoom |
| TFLite model size | Use quantized model (~25MB) |
| Cloud sync conflicts | Timestamp-based resolution, audit log |
| Unpaywall rate limits | Cache results, respect rate limits |

---

## Appendix: iOS Reference Files

Key iOS files to reference during implementation:

| Feature | iOS File |
|---------|----------|
| JATS Parsing | `Packages/BioMedLit/Sources/BioMedLit/JATSXMLParser.swift` |
| Full-Text Service | `Packages/BioMedLit/Sources/BioMedLit/FullTextService.swift` |
| Workflow | `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift` |
| Embeddings | `ios/MedicalFactChecker/Sources/Services/EmbeddingService.swift` |
| Onboarding | `ios/MedicalFactChecker/Sources/Views/Onboarding/OnboardingView.swift` |
| Help | `ios/MedicalFactChecker/Sources/Views/Help/HelpView.swift` |
| Smart Search | Search for `smartSearch` in `FactCheckWorkflow.swift` |
