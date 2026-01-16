# Phase 10: Testing & Polish

## Overview

This final phase focuses on comprehensive testing, performance optimization, bug fixes, and final polish before release.

**Estimated Duration**: 1-2 weeks
**Prerequisites**: Phases 1-9 completed
**Deliverable**: Production-ready Android app

## Testing Strategy

### Test Pyramid

```
           ┌─────────────┐
           │   E2E/UI    │  ← Few, slow, comprehensive
           │   Tests     │
          ┌┴─────────────┴┐
          │ Integration   │  ← Some, medium speed
          │    Tests      │
         ┌┴───────────────┴┐
         │   Unit Tests    │  ← Many, fast, focused
         └─────────────────┘
```

## Tasks

### 10.1 Unit Tests

#### Service Tests

```kotlin
// test/data/remote/llm/LLMServiceTest.kt
package com.bmlibrarian.factchecker.data.remote.llm

import io.mockk.*
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class LLMServiceTest {

    private lateinit var api: LLMApi
    private lateinit var service: LLMService

    @Before
    fun setup() {
        api = mockk()
        service = LLMService(api)
    }

    @Test
    fun `chat returns success on valid response`() = runTest {
        // Arrange
        val provider = LLMProvider.ANTHROPIC
        coEvery {
            api.chatCompletion(any(), any(), any(), any())
        } returns Response.success(ChatCompletionResponse(
            id = "test-id",
            choices = listOf(ChatChoice(
                index = 0,
                message = ChatMessage("assistant", "Test response"),
                finish_reason = "stop"
            )),
            usage = TokenUsage(100, 50, 150)
        ))

        // Act
        val result = service.chat(
            provider = provider,
            apiKey = "test-key",
            model = "claude-sonnet-4-20250514",
            systemPrompt = "You are a helper",
            userPrompt = "Hello"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals("Test response", result.getOrNull()?.content)
        assertEquals(100, result.getOrNull()?.inputTokens)
        assertEquals(50, result.getOrNull()?.outputTokens)
    }

    @Test
    fun `chat retries on transient failure`() = runTest {
        // Arrange
        var callCount = 0
        coEvery {
            api.chatCompletion(any(), any(), any(), any())
        } answers {
            callCount++
            if (callCount < 3) {
                throw java.io.IOException("Network error")
            }
            Response.success(ChatCompletionResponse(
                id = "test-id",
                choices = listOf(ChatChoice(0, ChatMessage("assistant", "Success"), "stop")),
                usage = null
            ))
        }

        // Act
        val result = service.chat(
            provider = LLMProvider.ANTHROPIC,
            apiKey = "test-key",
            model = "claude-sonnet-4-20250514",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isSuccess)
        assertEquals(3, callCount)
    }

    @Test
    fun `chat fails immediately on auth error`() = runTest {
        // Arrange
        coEvery {
            api.chatCompletion(any(), any(), any(), any())
        } returns Response.error(401, "Unauthorized".toResponseBody())

        // Act
        val result = service.chat(
            provider = LLMProvider.ANTHROPIC,
            apiKey = "invalid-key",
            model = "claude-sonnet-4-20250514",
            systemPrompt = "Test",
            userPrompt = "Test"
        )

        // Assert
        assertTrue(result.isFailure)
        coVerify(exactly = 1) { api.chatCompletion(any(), any(), any(), any()) }
    }

    @Test
    fun `parseScoreResponse handles valid JSON`() {
        val json = """{"score": 4, "rationale": "Highly relevant"}"""
        val result = service.parseScoreResponse(json)

        assertEquals(4, result.first)
        assertEquals("Highly relevant", result.second)
    }

    @Test
    fun `parseScoreResponse handles markdown code blocks`() {
        val json = """```json
        {"score": 3, "rationale": "Moderately relevant"}
        ```"""
        val result = service.parseScoreResponse(json)

        assertEquals(3, result.first)
    }

    @Test
    fun `parseScoreResponse clamps score to valid range`() {
        val json = """{"score": 10, "rationale": "Test"}"""
        val result = service.parseScoreResponse(json)

        assertEquals(5, result.first) // Clamped to max
    }
}
```

#### Repository Tests

```kotlin
// test/data/repository/SessionRepositoryTest.kt
package com.bmlibrarian.factchecker.data.repository

import com.bmlibrarian.factchecker.data.local.dao.SessionDao
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import io.mockk.*
import kotlinx.coroutines.flow.flowOf
import kotlinx.coroutines.test.runTest
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test

class SessionRepositoryTest {

    private lateinit var sessionDao: SessionDao
    private lateinit var repository: SessionRepository

    @Before
    fun setup() {
        sessionDao = mockk()
        repository = SessionRepository(sessionDao)
    }

    @Test
    fun `createSession inserts and returns session`() = runTest {
        // Arrange
        coEvery { sessionDao.insert(any()) } just Runs

        // Act
        val session = repository.createSession("Test claim")

        // Assert
        assertEquals("Test claim", session.claimText)
        assertEquals(WorkflowStep.IDLE, session.workflowStep)
        coVerify { sessionDao.insert(match { it.claimText == "Test claim" }) }
    }

    @Test
    fun `updateWorkflowStep updates session`() = runTest {
        // Arrange
        coEvery { sessionDao.updateWorkflowStep(any(), any(), any()) } just Runs

        // Act
        repository.updateWorkflowStep("session-123", WorkflowStep.SCORING_DOCUMENTS)

        // Assert
        coVerify {
            sessionDao.updateWorkflowStep(
                "session-123",
                WorkflowStep.SCORING_DOCUMENTS,
                any()
            )
        }
    }
}
```

#### Utility Tests

```kotlin
// test/util/CostCalculatorTest.kt
package com.bmlibrarian.factchecker.util

import com.bmlibrarian.factchecker.domain.model.ModelInfo
import org.junit.Assert.*
import org.junit.Test

class CostCalculatorTest {

    @Test
    fun `calculateCost returns correct value`() {
        val modelInfo = ModelInfo("test", "Test", 3.0, 15.0)

        val cost = CostCalculator.calculateCost(modelInfo, 1000, 500)

        // (1000 / 1_000_000) * 3.0 + (500 / 1_000_000) * 15.0 = 0.0105
        assertEquals(0.0105, cost, 0.0001)
    }

    @Test
    fun `calculateCost handles zero tokens`() {
        val modelInfo = ModelInfo("test", "Test", 3.0, 15.0)

        val cost = CostCalculator.calculateCost(modelInfo, 0, 0)

        assertEquals(0.0, cost, 0.0001)
    }

    @Test
    fun `calculateCost handles null modelInfo`() {
        val cost = CostCalculator.calculateCost(null, 1000, 500)

        assertEquals(0.0, cost, 0.0001)
    }

    @Test
    fun `formatCost handles small amounts`() {
        assertEquals("< $0.01", CostCalculator.formatCost(0.001))
        assertEquals("< $0.01", CostCalculator.formatCost(0.009))
    }

    @Test
    fun `formatCost handles normal amounts`() {
        assertEquals("$0.05", CostCalculator.formatCost(0.05))
        assertEquals("$1.23", CostCalculator.formatCost(1.234))
    }

    @Test
    fun `estimateRunCost calculates expected cost`() {
        val modelInfo = ModelInfo("test", "Test", 3.0, 15.0)

        val cost = CostCalculator.estimateRunCost(modelInfo, 20, 6)

        assertTrue(cost > 0)
    }
}
```

### 10.2 Integration Tests

#### Database Tests

```kotlin
// androidTest/data/local/AppDatabaseTest.kt
package com.bmlibrarian.factchecker.data.local

import android.content.Context
import androidx.room.Room
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bmlibrarian.factchecker.data.local.dao.*
import com.bmlibrarian.factchecker.data.local.entity.*
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class AppDatabaseTest {

    private lateinit var database: AppDatabase
    private lateinit var sessionDao: SessionDao
    private lateinit var documentDao: DocumentDao
    private lateinit var citationDao: CitationDao
    private lateinit var reportDao: ReportDao

    @Before
    fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        database = Room.inMemoryDatabaseBuilder(context, AppDatabase::class.java)
            .allowMainThreadQueries()
            .build()
        sessionDao = database.sessionDao()
        documentDao = database.documentDao()
        citationDao = database.citationDao()
        reportDao = database.reportDao()
    }

    @After
    fun teardown() {
        database.close()
    }

    @Test
    fun insertAndRetrieveSession() = runTest {
        val session = SessionEntity(claimText = "Test claim")
        sessionDao.insert(session)

        val retrieved = sessionDao.getById(session.id)

        assertNotNull(retrieved)
        assertEquals("Test claim", retrieved?.claimText)
        assertEquals(WorkflowStep.IDLE, retrieved?.workflowStep)
    }

    @Test
    fun updateWorkflowStep() = runTest {
        val session = SessionEntity(claimText = "Test")
        sessionDao.insert(session)

        sessionDao.updateWorkflowStep(session.id, WorkflowStep.SCORING_DOCUMENTS)

        val retrieved = sessionDao.getById(session.id)
        assertEquals(WorkflowStep.SCORING_DOCUMENTS, retrieved?.workflowStep)
    }

    @Test
    fun cascadeDeleteSession() = runTest {
        // Create session with documents
        val session = SessionEntity(claimText = "Test")
        sessionDao.insert(session)

        val document = DocumentEntity(
            sessionId = session.id,
            title = "Test Document"
        )
        documentDao.insert(document)

        // Verify document exists
        assertEquals(1, documentDao.countBySessionId(session.id))

        // Delete session
        sessionDao.deleteById(session.id)

        // Verify cascade delete
        assertEquals(0, documentDao.countBySessionId(session.id))
    }

    @Test
    fun documentScoringUpdates() = runTest {
        val session = SessionEntity(claimText = "Test")
        sessionDao.insert(session)

        val document = DocumentEntity(
            sessionId = session.id,
            title = "Test Document"
        )
        documentDao.insert(document)

        // Update score
        documentDao.updateScore(document.id, 4, "Highly relevant")

        val retrieved = documentDao.getById(document.id)
        assertEquals(4, retrieved?.relevanceScore)
        assertEquals("Highly relevant", retrieved?.scoreRationale)
    }

    @Test
    fun getRelevantDocuments() = runTest {
        val session = SessionEntity(claimText = "Test")
        sessionDao.insert(session)

        // Insert documents with different scores
        val docs = listOf(
            DocumentEntity(sessionId = session.id, title = "Doc 1", relevanceScore = 5),
            DocumentEntity(sessionId = session.id, title = "Doc 2", relevanceScore = 3),
            DocumentEntity(sessionId = session.id, title = "Doc 3", relevanceScore = 1),
            DocumentEntity(sessionId = session.id, title = "Doc 4", relevanceScore = 4)
        )
        documentDao.insertAll(docs)

        // Get relevant (score >= 3)
        val relevant = documentDao.getRelevantBySessionId(session.id, 3).first()

        assertEquals(3, relevant.size)
        assertTrue(relevant.all { (it.relevanceScore ?: 0) >= 3 })
    }
}
```

### 10.3 UI Tests

```kotlin
// androidTest/ui/FactCheckE2ETest.kt
package com.bmlibrarian.factchecker.ui

import androidx.compose.ui.test.*
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.bmlibrarian.factchecker.MainActivity
import dagger.hilt.android.testing.HiltAndroidRule
import dagger.hilt.android.testing.HiltAndroidTest
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@HiltAndroidTest
@RunWith(AndroidJUnit4::class)
class FactCheckE2ETest {

    @get:Rule(order = 0)
    val hiltRule = HiltAndroidRule(this)

    @get:Rule(order = 1)
    val composeRule = createAndroidComposeRule<MainActivity>()

    @Before
    fun setup() {
        hiltRule.inject()
    }

    @Test
    fun fullNavigationFlow() {
        // Start on FactCheck tab
        composeRule.onNodeWithText("Check").assertIsSelected()

        // Navigate to Settings
        composeRule.onNodeWithText("Settings").performClick()
        composeRule.onNodeWithText("LLM Provider").assertExists()

        // Navigate to History
        composeRule.onNodeWithText("History").performClick()
        composeRule.onNodeWithText("No History Yet").assertExists()

        // Navigate to Report
        composeRule.onNodeWithText("Report").performClick()
        composeRule.onNodeWithText("No Report Available").assertExists()

        // Back to Check
        composeRule.onNodeWithText("Check").performClick()
        composeRule.onNodeWithText("Medical Claim").assertExists()
    }

    @Test
    fun factCheckInput() {
        // Enter claim
        composeRule.onNodeWithText("Medical Claim").assertExists()
        composeRule.onNode(hasSetTextAction()).performTextInput("Test medical claim")

        // Button should be enabled
        composeRule.onNodeWithText("Check Claim").assertIsEnabled()
    }

    @Test
    fun settingsConfiguration() {
        // Navigate to Settings
        composeRule.onNodeWithText("Settings").performClick()

        // Expand provider dropdown
        composeRule.onNodeWithText("Provider").performClick()

        // Select OpenAI
        composeRule.onNodeWithText("OpenAI").performClick()

        // Verify model selector updated (would show GPT models)
        composeRule.onNodeWithText("Model").assertExists()
    }
}
```

### 10.4 Performance Optimization

#### Memory Optimization

```kotlin
// Ensure proper cleanup in ViewModels
override fun onCleared() {
    super.onCleared()
    // Cancel any ongoing operations
    // Clear cached data
}

// Use LazyColumn for long lists
LazyColumn {
    items(
        items = documents,
        key = { it.id } // Stable keys for efficient updates
    ) { document ->
        DocumentCard(document)
    }
}

// Avoid recomposition with remember and derivedStateOf
val relevantCount by remember(documents) {
    derivedStateOf { documents.count { it.relevanceScore >= 3 } }
}
```

#### Network Optimization

```kotlin
// Configure OkHttp caching
val cacheSize = 10L * 1024 * 1024 // 10 MB
val cache = Cache(context.cacheDir, cacheSize)

OkHttpClient.Builder()
    .cache(cache)
    .addInterceptor { chain ->
        val request = chain.request().newBuilder()
            .header("Cache-Control", "max-age=300") // 5 minutes
            .build()
        chain.proceed(request)
    }
    .build()
```

#### Database Optimization

```kotlin
// Use indices for frequently queried columns
@Entity(
    tableName = "documents",
    indices = [
        Index(value = ["session_id"]),
        Index(value = ["relevance_score"])
    ]
)

// Batch inserts
@Insert(onConflict = OnConflictStrategy.REPLACE)
suspend fun insertAll(documents: List<DocumentEntity>)

// Use transactions for related operations
@Transaction
suspend fun insertSessionWithDocuments(
    session: SessionEntity,
    documents: List<DocumentEntity>
)
```

### 10.5 Bug Fix Checklist

- [ ] Handle configuration changes (rotation) gracefully
- [ ] Preserve scroll position on tab switches
- [ ] Handle back button correctly
- [ ] Show loading states for all async operations
- [ ] Handle empty states in all lists
- [ ] Validate input before API calls
- [ ] Handle network errors with user-friendly messages
- [ ] Prevent double-clicks on buttons
- [ ] Handle deep links correctly
- [ ] Test with different screen sizes
- [ ] Test with dark mode
- [ ] Test with different font sizes (accessibility)
- [ ] Handle keyboard visibility correctly
- [ ] Clear sensitive data on logout/reset

### 10.6 Final Polish

#### App Icon and Branding

Create app icons in all required sizes:
- `mipmap-mdpi`: 48x48
- `mipmap-hdpi`: 72x72
- `mipmap-xhdpi`: 96x96
- `mipmap-xxhdpi`: 144x144
- `mipmap-xxxhdpi`: 192x192

#### Splash Screen

```kotlin
// themes.xml
<style name="Theme.MedicalFactChecker.Splash" parent="Theme.SplashScreen">
    <item name="windowSplashScreenBackground">@color/primary</item>
    <item name="windowSplashScreenAnimatedIcon">@drawable/ic_launcher_foreground</item>
    <item name="postSplashScreenTheme">@style/Theme.MedicalFactChecker</item>
</style>

// MainActivity.kt
override fun onCreate(savedInstanceState: Bundle?) {
    val splashScreen = installSplashScreen()
    super.onCreate(savedInstanceState)
    // ...
}
```

#### Strings Localization

```xml
<!-- res/values/strings.xml -->
<resources>
    <string name="app_name">Medical Fact Checker</string>
    <string name="tab_check">Check</string>
    <string name="tab_report">Report</string>
    <string name="tab_history">History</string>
    <string name="tab_settings">Settings</string>

    <string name="claim_input_label">Medical Claim</string>
    <string name="claim_input_placeholder">Enter a medical claim to fact-check…</string>
    <string name="button_check_claim">Check Claim</string>

    <string name="verdict_supported">Supported</string>
    <string name="verdict_likely_supported">Likely Supported</string>
    <string name="verdict_unclear">Unclear</string>
    <string name="verdict_likely_refuted">Likely Refuted</string>
    <string name="verdict_refuted">Refuted</string>

    <!-- Add all user-facing strings -->
</resources>
```

#### Accessibility

```kotlin
// Add content descriptions
Icon(
    imageVector = Icons.Default.Search,
    contentDescription = stringResource(R.string.content_desc_search)
)

// Ensure touch targets are at least 48dp
Modifier.size(48.dp)

// Use semantic properties
Modifier.semantics {
    heading()
    stateDescription = "Selected"
}
```

## Release Checklist

### Pre-Release

- [ ] All tests passing
- [ ] No crashes in crash reporting
- [ ] Performance benchmarks acceptable
- [ ] Memory leaks checked with LeakCanary
- [ ] ProGuard rules tested
- [ ] Signed release build works
- [ ] App size acceptable
- [ ] Privacy policy URL added
- [ ] Terms of service URL added

### Play Store Listing

- [ ] App title and description
- [ ] Feature graphic (1024x500)
- [ ] Screenshots (phone, tablet if supported)
- [ ] App category: Medical
- [ ] Content rating questionnaire
- [ ] Data safety form completed
- [ ] Privacy policy linked
- [ ] Contact email configured

### Post-Release Monitoring

- [ ] Crash reporting enabled (Firebase Crashlytics)
- [ ] Analytics configured (if applicable)
- [ ] User feedback channel established
- [ ] Performance monitoring enabled

## Success Metrics

| Metric | Target |
|--------|--------|
| Crash-free rate | > 99% |
| App startup time | < 2 seconds |
| ANR rate | < 0.1% |
| User rating | > 4.0 stars |
| Uninstall rate | < 20% (30 days) |

## Conclusion

With Phase 10 complete, the Android MedicalFactChecker app is ready for release. The app provides:

- Medical claim fact-checking using PubMed literature
- Support for multiple LLM providers
- Secure API key storage
- Budget tracking and limits
- Evidence reports with citations
- Session history
- PDF export capability

Continue to monitor user feedback and iterate on the app based on real-world usage.
