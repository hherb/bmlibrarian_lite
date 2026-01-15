# Phase 4: Workflow Engine

## Overview

This phase implements the core fact-checking workflow engine - a state machine that orchestrates the entire process from claim input to evidence report generation. The workflow handles state transitions, progress tracking, budget enforcement, and batch pagination.

**Estimated Duration**: 1-2 weeks
**Prerequisites**: Phases 1-3 completed
**Deliverable**: Complete workflow engine with all 11 states

## Workflow State Machine

```
┌─────────┐
│  IDLE   │
└────┬────┘
     │ startFactCheck()
     ▼
┌──────────────────┐
│ CONVERTING_QUERY │
└────────┬─────────┘
         │ query converted
         ▼
┌─────────────────┐
│ SEARCHING_PUBMED│
└────────┬────────┘
         │ documents found
         ▼
┌───────────────────┐
│ SCORING_DOCUMENTS │
└────────┬──────────┘
         │ scoring complete
         ▼
┌──────────────────────────┐     ┌────────────────────────┐
│ AWAITING_USER_DECISION   │────►│ SEARCHING_PUBMED       │
│ "Fetch more documents?"  │     │ (next batch)           │
└────────┬─────────────────┘     └────────────────────────┘
         │ user says "no" or enough docs
         ▼
┌─────────────────────┐
│ EXTRACTING_CITATIONS│
└────────┬────────────┘
         │ citations extracted
         ▼
┌────────────────────┐
│ GENERATING_REPORT  │
└────────┬───────────┘
         │ report generated
         ▼
┌───────────┐
│ COMPLETED │
└───────────┘

Error paths → FAILED
Budget exceeded → BUDGET_EXCEEDED
```

## Tasks

### 4.1 Create Workflow State Classes

```kotlin
// domain/workflow/WorkflowState.kt
package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.domain.model.WorkflowStep

/**
 * Sealed class representing the current state of the workflow.
 */
sealed class WorkflowState {

    abstract val step: WorkflowStep

    /**
     * Idle state - ready to start a new fact check.
     */
    data object Idle : WorkflowState() {
        override val step = WorkflowStep.IDLE
    }

    /**
     * Converting the claim to a PubMed query.
     */
    data class ConvertingQuery(
        val claim: String
    ) : WorkflowState() {
        override val step = WorkflowStep.CONVERTING_QUERY
    }

    /**
     * Searching PubMed/Europe PMC for documents.
     */
    data class Searching(
        val query: String,
        val provider: String,
        val batchNumber: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.SEARCHING_PUBMED
    }

    /**
     * Scoring documents for relevance.
     */
    data class Scoring(
        val currentDocument: Int,
        val totalDocuments: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.SCORING_DOCUMENTS
    }

    /**
     * Waiting for user decision on fetching more documents.
     */
    data class AwaitingUserDecision(
        val relevantCount: Int,
        val targetCount: Int,
        val availableCount: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.AWAITING_USER_DECISION
    }

    /**
     * Extracting citations from relevant documents.
     */
    data class ExtractingCitations(
        val currentDocument: Int,
        val totalDocuments: Int
    ) : WorkflowState() {
        override val step = WorkflowStep.EXTRACTING_CITATIONS
    }

    /**
     * Generating the evidence report.
     */
    data object GeneratingReport : WorkflowState() {
        override val step = WorkflowStep.GENERATING_REPORT
    }

    /**
     * Fetching more evidence with alternative query.
     */
    data class FetchingMoreEvidence(
        val alternativeQuery: String
    ) : WorkflowState() {
        override val step = WorkflowStep.FETCHING_MORE_EVIDENCE
    }

    /**
     * Workflow completed successfully.
     */
    data class Completed(
        val reportId: String
    ) : WorkflowState() {
        override val step = WorkflowStep.COMPLETED
    }

    /**
     * Workflow failed with an error.
     */
    data class Failed(
        val error: String
    ) : WorkflowState() {
        override val step = WorkflowStep.FAILED
    }

    /**
     * Budget exceeded during workflow.
     */
    data class BudgetExceeded(
        val message: String,
        val currentCost: Double,
        val budgetLimit: Double
    ) : WorkflowState() {
        override val step = WorkflowStep.BUDGET_EXCEEDED
    }
}

/**
 * Progress information for UI display.
 */
data class WorkflowProgress(
    val step: WorkflowStep,
    val message: String,
    val percentage: Float, // 0.0 to 1.0
    val documentsFound: Int = 0,
    val documentsScored: Int = 0,
    val relevantDocuments: Int = 0,
    val citationsExtracted: Int = 0,
    val currentCostUsd: Double = 0.0
)
```

### 4.2 Create Workflow Configuration

```kotlin
// domain/workflow/WorkflowConfig.kt
package com.bmlibrarian.factchecker.domain.workflow

/**
 * Configuration for the fact-check workflow.
 */
data class WorkflowConfig(
    val searchProvider: SearchProvider = SearchProvider.PUBMED,
    val includePreprints: Boolean = false,
    val batchSize: Int = 20,
    val relevanceThreshold: Int = 3, // Minimum score to consider relevant
    val targetRelevantDocuments: Int = 10,
    val maxBatches: Int = 5,
    val maxRunBudgetUsd: Double = 1.0,
    val monthlyBudgetUsd: Double = 10.0
) {
    enum class SearchProvider {
        PUBMED, EUROPE_PMC, BOTH
    }
}
```

### 4.3 Implement the Workflow Engine

```kotlin
// domain/workflow/FactCheckWorkflow.kt
package com.bmlibrarian.factchecker.domain.workflow

import com.bmlibrarian.factchecker.data.local.entity.CitationEntity
import com.bmlibrarian.factchecker.data.local.entity.DocumentEntity
import com.bmlibrarian.factchecker.data.local.entity.ReportEntity
import com.bmlibrarian.factchecker.data.local.entity.SessionEntity
import com.bmlibrarian.factchecker.data.local.entity.UsageRecordEntity
import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.llm.LLMService
import com.bmlibrarian.factchecker.data.remote.pubmed.PubMedService
import com.bmlibrarian.factchecker.data.repository.DocumentRepository
import com.bmlibrarian.factchecker.data.repository.SessionRepository
import com.bmlibrarian.factchecker.data.repository.SettingsRepository
import com.bmlibrarian.factchecker.domain.model.LLMProvider
import com.bmlibrarian.factchecker.domain.model.Verdict
import com.bmlibrarian.factchecker.domain.model.WorkflowStep
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import javax.inject.Inject
import javax.inject.Singleton

/**
 * Main workflow engine for fact-checking.
 * Orchestrates the entire process from claim to report.
 */
@Singleton
class FactCheckWorkflow @Inject constructor(
    private val llmService: LLMService,
    private val pubMedService: PubMedService,
    private val europePMCService: EuropePMCService,
    private val sessionRepository: SessionRepository,
    private val documentRepository: DocumentRepository,
    private val settingsRepository: SettingsRepository
) {

    // Current workflow state
    private val _state = MutableStateFlow<WorkflowState>(WorkflowState.Idle)
    val state: StateFlow<WorkflowState> = _state.asStateFlow()

    // Progress tracking
    private val _progress = MutableStateFlow(WorkflowProgress(
        step = WorkflowStep.IDLE,
        message = "Ready",
        percentage = 0f
    ))
    val progress: StateFlow<WorkflowProgress> = _progress.asStateFlow()

    // Current session
    private var currentSession: SessionEntity? = null

    /**
     * Start a new fact-check workflow.
     *
     * @param claim The medical claim to fact-check
     * @param config Workflow configuration
     * @return The session ID
     */
    suspend fun startFactCheck(
        claim: String,
        config: WorkflowConfig = WorkflowConfig()
    ): String {
        // Create new session
        val session = sessionRepository.createSession(claim)
        currentSession = session

        // Update state
        _state.value = WorkflowState.ConvertingQuery(claim)
        updateProgress("Converting claim to search query...", 0.05f)

        try {
            // Check budget
            checkBudget(0.0, config)

            // Step 1: Convert claim to PubMed query
            val query = convertClaimToQuery(claim, config)
            updateSession { it.copy(pubmedQuery = query) }

            // Step 2: Search for documents
            _state.value = WorkflowState.Searching(query, config.searchProvider.name, 1)
            updateProgress("Searching for documents...", 0.15f)
            val documents = searchForDocuments(query, session.id, config)
            updateProgress("Found ${documents.size} documents", 0.25f)

            if (documents.isEmpty()) {
                _state.value = WorkflowState.Failed("No documents found for this claim")
                return session.id
            }

            // Step 3: Score documents
            _state.value = WorkflowState.Scoring(0, documents.size)
            val scoredDocs = scoreDocuments(documents, claim, config)

            val relevantCount = scoredDocs.count { (it.relevanceScore ?: 0) >= config.relevanceThreshold }
            updateProgress("Scored ${scoredDocs.size} documents, $relevantCount relevant", 0.50f)

            // Step 4: Check if we need more documents
            if (relevantCount < config.targetRelevantDocuments && hasMoreDocuments()) {
                _state.value = WorkflowState.AwaitingUserDecision(
                    relevantCount = relevantCount,
                    targetCount = config.targetRelevantDocuments,
                    availableCount = getAvailableDocumentCount()
                )
                return session.id // Will continue when user responds
            }

            // Step 5: Extract citations
            await continueToExtraction(config)

        } catch (e: BudgetExceededException) {
            _state.value = WorkflowState.BudgetExceeded(
                message = e.message ?: "Budget exceeded",
                currentCost = e.currentCost,
                budgetLimit = e.budgetLimit
            )
            updateSession { it.copy(workflowStep = WorkflowStep.BUDGET_EXCEEDED) }
        } catch (e: Exception) {
            _state.value = WorkflowState.Failed(e.message ?: "Unknown error")
            updateSession { it.copy(
                workflowStep = WorkflowStep.FAILED,
                errorMessage = e.message
            ) }
        }

        return session.id
    }

    /**
     * Continue workflow after user decision to fetch more documents.
     */
    suspend fun fetchMoreDocuments(config: WorkflowConfig = WorkflowConfig()) {
        val session = currentSession ?: throw IllegalStateException("No active session")

        try {
            _state.value = WorkflowState.Searching(
                session.pubmedQuery ?: "",
                config.searchProvider.name,
                session.currentBatch + 1
            )

            val newDocs = searchForDocuments(
                session.pubmedQuery ?: "",
                session.id,
                config,
                isNextBatch = true
            )

            if (newDocs.isNotEmpty()) {
                val scoredDocs = scoreDocuments(newDocs, session.claimText, config)
                val relevantCount = documentRepository.getRelevantCount(session.id, config.relevanceThreshold)

                if (relevantCount < config.targetRelevantDocuments && hasMoreDocuments()) {
                    _state.value = WorkflowState.AwaitingUserDecision(
                        relevantCount = relevantCount,
                        targetCount = config.targetRelevantDocuments,
                        availableCount = getAvailableDocumentCount()
                    )
                    return
                }
            }

            continueToExtraction(config)

        } catch (e: Exception) {
            _state.value = WorkflowState.Failed(e.message ?: "Error fetching more documents")
        }
    }

    /**
     * Continue workflow after user declines to fetch more.
     */
    suspend fun skipMoreDocuments(config: WorkflowConfig = WorkflowConfig()) {
        continueToExtraction(config)
    }

    /**
     * Continue to citation extraction and report generation.
     */
    private suspend fun continueToExtraction(config: WorkflowConfig) {
        val session = currentSession ?: throw IllegalStateException("No active session")

        // Get relevant documents
        val relevantDocs = documentRepository.getUnscoredDocuments(session.id)
            .filter { (it.relevanceScore ?: 0) >= config.relevanceThreshold }

        // Step 5: Extract citations
        _state.value = WorkflowState.ExtractingCitations(0, relevantDocs.size)
        updateProgress("Extracting citations...", 0.60f)

        val citations = extractCitations(relevantDocs, session.claimText, config)
        updateProgress("Extracted ${citations.size} citations", 0.75f)

        // Step 6: Generate report
        _state.value = WorkflowState.GeneratingReport
        updateProgress("Generating evidence report...", 0.85f)

        val report = generateReport(session.claimText, citations, relevantDocs, config)
        updateProgress("Report complete", 1.0f)

        // Update session and complete
        updateSession { it.copy(workflowStep = WorkflowStep.COMPLETED) }
        _state.value = WorkflowState.Completed(report.id)
    }

    /**
     * Convert a claim to a PubMed query using LLM.
     */
    private suspend fun convertClaimToQuery(claim: String, config: WorkflowConfig): String {
        val settings = settingsRepository.getSettings()
        val provider = LLMProvider.fromId(settings.llmProviderId)
            ?: throw IllegalStateException("Invalid LLM provider")

        val result = llmService.convertToPubMedQuery(
            provider = provider,
            apiKey = settings.apiKey,
            model = settings.modelId,
            claim = claim
        )

        if (result.isFailure) {
            throw result.exceptionOrNull() ?: Exception("Failed to convert query")
        }

        // Track usage
        trackUsage("query_conversion", result)

        return result.getOrThrow()
    }

    /**
     * Search for documents across configured providers.
     */
    private suspend fun searchForDocuments(
        query: String,
        sessionId: String,
        config: WorkflowConfig,
        isNextBatch: Boolean = false
    ): List<DocumentEntity> {
        val session = currentSession ?: throw IllegalStateException("No session")
        val allDocuments = mutableListOf<DocumentEntity>()

        when (config.searchProvider) {
            WorkflowConfig.SearchProvider.PUBMED -> {
                val offset = if (isNextBatch) session.pubmedOffset else 0
                val result = pubMedService.search(
                    query = query,
                    sessionId = sessionId,
                    offset = offset,
                    batchSize = config.batchSize
                )
                if (result.isSuccess) {
                    val searchResult = result.getOrThrow()
                    allDocuments.addAll(searchResult.documents)
                    updateSession { it.copy(
                        pubmedOffset = searchResult.nextOffset,
                        pubmedTotalResults = searchResult.totalResults
                    ) }
                }
            }

            WorkflowConfig.SearchProvider.EUROPE_PMC -> {
                val cursor = if (isNextBatch) session.epmcCursor else null
                val result = europePMCService.search(
                    query = query,
                    sessionId = sessionId,
                    cursor = cursor,
                    batchSize = config.batchSize,
                    includePreprints = config.includePreprints
                )
                if (result.isSuccess) {
                    val searchResult = result.getOrThrow()
                    allDocuments.addAll(searchResult.documents)
                    updateSession { it.copy(
                        epmcCursor = searchResult.nextCursor,
                        epmcTotalResults = searchResult.totalResults
                    ) }
                }
            }

            WorkflowConfig.SearchProvider.BOTH -> {
                // Search both and merge
                val pubmedOffset = if (isNextBatch) session.pubmedOffset else 0
                val pubmedResult = pubMedService.search(
                    query = query,
                    sessionId = sessionId,
                    offset = pubmedOffset,
                    batchSize = config.batchSize / 2
                )

                val epmcCursor = if (isNextBatch) session.epmcCursor else null
                val epmcResult = europePMCService.search(
                    query = query,
                    sessionId = sessionId,
                    cursor = epmcCursor,
                    batchSize = config.batchSize / 2,
                    includePreprints = config.includePreprints
                )

                if (pubmedResult.isSuccess) {
                    val sr = pubmedResult.getOrThrow()
                    allDocuments.addAll(sr.documents)
                    updateSession { it.copy(
                        pubmedOffset = sr.nextOffset,
                        pubmedTotalResults = sr.totalResults
                    ) }
                }

                if (epmcResult.isSuccess) {
                    val sr = epmcResult.getOrThrow()
                    // Deduplicate by PMID
                    val existingPmids = allDocuments.mapNotNull { it.pmid }.toSet()
                    val newDocs = sr.documents.filter { it.pmid !in existingPmids }
                    allDocuments.addAll(newDocs)
                    updateSession { it.copy(
                        epmcCursor = sr.nextCursor,
                        epmcTotalResults = sr.totalResults
                    ) }
                }
            }
        }

        // Save documents
        if (allDocuments.isNotEmpty()) {
            documentRepository.saveDocuments(allDocuments)
        }

        return allDocuments
    }

    /**
     * Score documents for relevance.
     */
    private suspend fun scoreDocuments(
        documents: List<DocumentEntity>,
        claim: String,
        config: WorkflowConfig
    ): List<DocumentEntity> {
        val settings = settingsRepository.getSettings()
        val provider = LLMProvider.fromId(settings.llmProviderId)
            ?: throw IllegalStateException("Invalid LLM provider")

        val scoredDocs = mutableListOf<DocumentEntity>()

        documents.forEachIndexed { index, doc ->
            _state.value = WorkflowState.Scoring(index + 1, documents.size)
            updateProgress(
                "Scoring document ${index + 1} of ${documents.size}",
                0.25f + (0.25f * (index + 1) / documents.size)
            )

            val result = llmService.scoreDocument(
                provider = provider,
                apiKey = settings.apiKey,
                model = settings.modelId,
                claim = claim,
                title = doc.title,
                abstractText = doc.abstractText
            )

            if (result.isSuccess) {
                val (score, rationale) = result.getOrThrow()
                documentRepository.updateDocumentScore(doc.id, score, rationale)
                scoredDocs.add(doc.copy(relevanceScore = score, scoreRationale = rationale))

                // Track usage and check budget
                val cost = trackUsage("scoring", result)
                checkBudget(cost, config)
            } else {
                // Still add document, just without score
                scoredDocs.add(doc)
            }
        }

        return scoredDocs
    }

    /**
     * Extract citations from relevant documents.
     */
    private suspend fun extractCitations(
        documents: List<DocumentEntity>,
        claim: String,
        config: WorkflowConfig
    ): List<CitationEntity> {
        val settings = settingsRepository.getSettings()
        val provider = LLMProvider.fromId(settings.llmProviderId)
            ?: throw IllegalStateException("Invalid LLM provider")

        val allCitations = mutableListOf<CitationEntity>()

        documents.forEachIndexed { index, doc ->
            _state.value = WorkflowState.ExtractingCitations(index + 1, documents.size)
            updateProgress(
                "Extracting citations from document ${index + 1}",
                0.60f + (0.15f * (index + 1) / documents.size)
            )

            val result = llmService.extractCitations(
                provider = provider,
                apiKey = settings.apiKey,
                model = settings.modelId,
                claim = claim,
                title = doc.title,
                abstractText = doc.abstractText
            )

            if (result.isSuccess) {
                val extractions = result.getOrThrow()
                val citations = extractions.map { extraction ->
                    CitationEntity(
                        documentId = doc.id,
                        passage = extraction.passage,
                        relevanceExplanation = extraction.relevance
                    )
                }
                allCitations.addAll(citations)
                documentRepository.saveCitations(citations)

                // Track usage and check budget
                val cost = trackUsage("citation", result)
                checkBudget(cost, config)
            }
        }

        return allCitations
    }

    /**
     * Generate the evidence report.
     */
    private suspend fun generateReport(
        claim: String,
        citations: List<CitationEntity>,
        documents: List<DocumentEntity>,
        config: WorkflowConfig
    ): ReportEntity {
        val session = currentSession ?: throw IllegalStateException("No session")
        val settings = settingsRepository.getSettings()
        val provider = LLMProvider.fromId(settings.llmProviderId)
            ?: throw IllegalStateException("Invalid LLM provider")

        // Build citation data for LLM
        val documentMap = documents.associateBy { it.id }
        val citationData = citations.mapNotNull { citation ->
            val doc = documentMap[citation.documentId] ?: return@mapNotNull null
            LLMService.DocumentCitation(
                title = doc.title,
                passage = citation.passage,
                pmid = doc.pmid
            )
        }

        val result = llmService.generateReport(
            provider = provider,
            apiKey = settings.apiKey,
            model = settings.modelId,
            claim = claim,
            citations = citationData
        )

        if (result.isFailure) {
            throw result.exceptionOrNull() ?: Exception("Failed to generate report")
        }

        val generation = result.getOrThrow()
        trackUsage("report", result)

        val report = ReportEntity(
            sessionId = session.id,
            verdict = Verdict.fromString(generation.verdict),
            summary = generation.summary,
            fullReportMarkdown = generation.report,
            modelUsed = settings.modelId,
            totalDocumentsReviewed = documents.size,
            relevantDocumentsCount = documents.count { (it.relevanceScore ?: 0) >= config.relevanceThreshold },
            citationsCount = citations.size
        )

        // Save report (via repository when implemented)
        return report
    }

    // Helper methods

    private suspend fun updateSession(transform: (SessionEntity) -> SessionEntity) {
        currentSession?.let { session ->
            val updated = transform(session)
            currentSession = updated
            sessionRepository.updateSession(updated)
        }
    }

    private fun updateProgress(message: String, percentage: Float) {
        val session = currentSession
        _progress.value = WorkflowProgress(
            step = _state.value.step,
            message = message,
            percentage = percentage,
            documentsFound = session?.documentsInBatch ?: 0,
            currentCostUsd = session?.estimatedCostUsd ?: 0.0
        )
    }

    private fun hasMoreDocuments(): Boolean {
        return currentSession?.hasMoreDocuments ?: false
    }

    private fun getAvailableDocumentCount(): Int {
        val session = currentSession ?: return 0
        return maxOf(session.pubmedTotalResults - session.pubmedOffset, 0) +
               (if (session.epmcCursor != null) 100 else 0) // Estimate for Europe PMC
    }

    private suspend fun trackUsage(operation: String, result: Result<*>): Double {
        // Extract token counts from LLM result and calculate cost
        // This would need to be implemented based on the actual result type
        return 0.0 // Placeholder
    }

    private fun checkBudget(additionalCost: Double, config: WorkflowConfig) {
        val session = currentSession ?: return
        val newTotal = session.estimatedCostUsd + additionalCost

        if (newTotal > config.maxRunBudgetUsd) {
            throw BudgetExceededException(
                "Run budget exceeded",
                newTotal,
                config.maxRunBudgetUsd
            )
        }

        // Check monthly budget would require querying usage records
    }

    /**
     * Reset the workflow to idle state.
     */
    fun reset() {
        currentSession = null
        _state.value = WorkflowState.Idle
        _progress.value = WorkflowProgress(
            step = WorkflowStep.IDLE,
            message = "Ready",
            percentage = 0f
        )
    }
}

/**
 * Exception for budget exceeded scenarios.
 */
class BudgetExceededException(
    message: String,
    val currentCost: Double,
    val budgetLimit: Double
) : Exception(message)
```

### 4.4 Create Use Cases (Optional Clean Architecture Layer)

```kotlin
// domain/usecase/StartFactCheckUseCase.kt
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowConfig
import javax.inject.Inject

/**
 * Use case for starting a fact-check.
 */
class StartFactCheckUseCase @Inject constructor(
    private val workflow: FactCheckWorkflow
) {
    suspend operator fun invoke(claim: String, config: WorkflowConfig = WorkflowConfig()): String {
        return workflow.startFactCheck(claim, config)
    }
}
```

```kotlin
// domain/usecase/GetWorkflowStateUseCase.kt
package com.bmlibrarian.factchecker.domain.usecase

import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import com.bmlibrarian.factchecker.domain.workflow.WorkflowState
import kotlinx.coroutines.flow.StateFlow
import javax.inject.Inject

/**
 * Use case for observing workflow state.
 */
class GetWorkflowStateUseCase @Inject constructor(
    private val workflow: FactCheckWorkflow
) {
    operator fun invoke(): StateFlow<WorkflowState> = workflow.state
}
```

### 4.5 Update Hilt Module for Workflow

```kotlin
// di/WorkflowModule.kt
package com.bmlibrarian.factchecker.di

import com.bmlibrarian.factchecker.domain.workflow.FactCheckWorkflow
import dagger.Module
import dagger.Provides
import dagger.hilt.InstallIn
import dagger.hilt.components.SingletonComponent
import javax.inject.Singleton

/**
 * Hilt module for workflow dependencies.
 */
@Module
@InstallIn(SingletonComponent::class)
object WorkflowModule {

    // FactCheckWorkflow is @Singleton and uses constructor injection,
    // so it doesn't need explicit @Provides unless custom setup is needed
}
```

## Verification Checklist

- [ ] Workflow starts correctly from idle state
- [ ] Query conversion calls LLM and updates session
- [ ] Document search works for all provider configurations
- [ ] Document scoring processes all documents
- [ ] User decision state triggers correctly
- [ ] Fetching more documents resumes workflow
- [ ] Citation extraction processes relevant documents
- [ ] Report generation creates valid report
- [ ] Budget checking prevents overspend
- [ ] Error states are handled gracefully
- [ ] State flow emits correct updates
- [ ] Progress tracking is accurate

## Testing

### Unit Tests

```kotlin
// test/domain/workflow/FactCheckWorkflowTest.kt
@Test
fun `workflow transitions through states correctly`() = runTest {
    val workflow = createTestWorkflow()

    // Collect states
    val states = mutableListOf<WorkflowState>()
    val job = launch {
        workflow.state.collect { states.add(it) }
    }

    workflow.startFactCheck("Test claim")

    // Verify state progression
    assertTrue(states.any { it is WorkflowState.ConvertingQuery })
    assertTrue(states.any { it is WorkflowState.Searching })
    assertTrue(states.any { it is WorkflowState.Scoring })

    job.cancel()
}

@Test
fun `budget exceeded stops workflow`() = runTest {
    val workflow = createTestWorkflow()
    val config = WorkflowConfig(maxRunBudgetUsd = 0.001) // Very low budget

    workflow.startFactCheck("Test claim", config)

    assertTrue(workflow.state.value is WorkflowState.BudgetExceeded)
}
```

### Integration Tests

```kotlin
// androidTest/domain/workflow/FactCheckWorkflowIntegrationTest.kt
@HiltAndroidTest
class FactCheckWorkflowIntegrationTest {

    @Inject
    lateinit var workflow: FactCheckWorkflow

    @Test
    fun fullWorkflowWithRealAPIs() = runTest {
        // This would use a test LLM API or mock
        val sessionId = workflow.startFactCheck("Vitamin D prevents COVID-19")

        // Wait for completion or timeout
        withTimeout(60_000) {
            workflow.state.first { it is WorkflowState.Completed || it is WorkflowState.Failed }
        }

        assertTrue(workflow.state.value is WorkflowState.Completed)
    }
}
```

## Next Phase

Continue to [Phase 5: Settings & Security](./05-settings-security.md)
