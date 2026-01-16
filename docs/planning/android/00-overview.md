# Android MedicalFactChecker - Implementation Plan Overview

## Executive Summary

This document outlines the implementation plan for porting the iOS MedicalFactChecker app to Android. The Android version will provide the same core functionality: AI-powered medical fact-checking using PubMed literature search, LLM-based relevance scoring, citation extraction, and evidence report generation.

### Key Decisions

- **UI Framework**: Jetpack Compose (modern, declarative, similar paradigm to SwiftUI)
- **Persistence**: SQLite with Room Database (type-safe, familiar Android pattern)
- **Networking**: Retrofit + OkHttp (industry standard for Android)
- **Concurrency**: Kotlin Coroutines + Flow (equivalent to Swift async/await + actors)
- **Architecture**: MVVM with Clean Architecture layers
- **Scoring**: LLM-only scoring (no on-device embeddings for initial release)

## Project Scope

### Features to Implement

| Feature | Priority | Notes |
|---------|----------|-------|
| Medical claim fact-checking | P0 | Core functionality |
| PubMed search integration | P0 | NCBI E-utilities API |
| Europe PMC search integration | P0 | Alternative/supplementary source |
| Multi-provider LLM support | P0 | 7 providers (Anthropic, OpenAI, etc.) |
| LLM relevance scoring | P0 | 1-5 scale with rationale |
| Citation extraction | P0 | Key passages from documents |
| Evidence report generation | P0 | Markdown report with verdict |
| Session history | P0 | Browse and revisit past checks |
| Budget tracking | P0 | Per-run and monthly limits |
| PDF export | P1 | Export reports as PDF |
| Full-text fetching | P1 | Fetch article full text when available |
| Onboarding flow | P1 | First-run setup wizard |

### Features Deferred

| Feature | Reason |
|---------|--------|
| On-device embedding scoring | Complexity; LLM scoring sufficient for MVP |
| Offline mode | Requires significant additional work |
| Widget support | Future enhancement |

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────┐
│                      Presentation Layer                      │
│  ┌─────────────┐ ┌─────────────┐ ┌─────────────┐ ┌─────────┐│
│  │FactCheckView│ │ ReportView  │ │ HistoryView │ │Settings ││
│  └──────┬──────┘ └──────┬──────┘ └──────┬──────┘ └────┬────┘│
│         │               │               │              │     │
│  ┌──────┴───────────────┴───────────────┴──────────────┴───┐│
│  │                    ViewModels                            ││
│  │  FactCheckVM │ ReportVM │ HistoryVM │ SettingsVM        ││
│  └──────────────────────────┬──────────────────────────────┘│
└─────────────────────────────┼───────────────────────────────┘
                              │
┌─────────────────────────────┼───────────────────────────────┐
│                      Domain Layer                            │
│  ┌──────────────────────────┴──────────────────────────────┐│
│  │                  FactCheckWorkflow                       ││
│  │  (State machine orchestrating the fact-check process)    ││
│  └──────────────────────────┬──────────────────────────────┘│
│                              │                               │
│  ┌────────────┐ ┌────────────┴───┐ ┌────────────────────────┐│
│  │ UseCases   │ │ Domain Models  │ │ Repository Interfaces  ││
│  └────────────┘ └────────────────┘ └────────────────────────┘│
└─────────────────────────────┬───────────────────────────────┘
                              │
┌─────────────────────────────┼───────────────────────────────┐
│                       Data Layer                             │
│  ┌──────────────────────────┴──────────────────────────────┐│
│  │                   Repositories                           ││
│  └───────┬──────────────┬──────────────┬──────────────┬────┘│
│          │              │              │              │      │
│  ┌───────┴────┐ ┌───────┴────┐ ┌───────┴────┐ ┌──────┴────┐ │
│  │ LLMService │ │PubMedService│ │EuropePMC   │ │ Database  │ │
│  │ (Retrofit) │ │ (Retrofit)  │ │Service     │ │ (Room)    │ │
│  └────────────┘ └─────────────┘ └────────────┘ └───────────┘ │
└─────────────────────────────────────────────────────────────┘
```

## Implementation Phases

The implementation is divided into 10 phases, each building on the previous:

### Phase 1: Project Setup & Architecture (1 week)
- Create Android project with Gradle configuration
- Set up dependency injection (Hilt)
- Configure build variants and ProGuard
- Establish package structure

**Deliverable**: Empty but fully configured Android project

### Phase 2: Data Models & SQLite Persistence (1-2 weeks)
- Define Room entities mirroring iOS models
- Create database schema with relationships
- Implement TypeConverters for complex types
- Set up DAOs for CRUD operations
- Create repository layer

**Deliverable**: Working persistence layer with all entities

### Phase 3: API Services (1 week)
- Implement LLMService with Retrofit
- Implement PubMedService (NCBI E-utilities)
- Implement EuropePMCService
- Add retry logic and error handling
- Create response parsers

**Deliverable**: All external API integrations working

### Phase 4: Workflow Engine (1-2 weeks)
- Port FactCheckWorkflow state machine
- Implement workflow steps as coroutines
- Add progress tracking and callbacks
- Handle budget enforcement
- Implement batch pagination logic

**Deliverable**: Complete workflow engine with all 11 states

### Phase 5: Settings & Security (3-5 days)
- Implement AppSettings with SharedPreferences
- Secure API key storage with EncryptedSharedPreferences
- Port LLMProvider configurations
- Add model pricing data

**Deliverable**: Fully functional settings management

### Phase 6: UI - Navigation & FactCheck Screen (1-2 weeks)
- Set up Compose navigation with bottom tabs
- Implement FactCheckView with input, progress, results
- Create document card components
- Handle user decision prompts ("fetch more?")

**Deliverable**: Working fact-check screen end-to-end

### Phase 7: UI - Report View (1 week)
- Implement markdown rendering
- Create clickable reference handling
- Add verdict display with color coding
- Implement PDF export functionality
- Add share functionality

**Deliverable**: Complete report viewing and export

### Phase 8: UI - History View (3-5 days)
- Implement session list with LazyColumn
- Create session card components
- Add delete functionality
- Connect to report view for viewing past sessions

**Deliverable**: Browsable session history

### Phase 9: UI - Settings View (1 week)
- Provider selection UI
- Model selection with pricing display
- API key input with secure storage
- Budget configuration sliders
- Search provider options

**Deliverable**: Full settings configuration UI

### Phase 10: Testing & Polish (1-2 weeks)
- Unit tests for services and workflow
- Integration tests for database
- UI tests for critical flows
- Performance optimization
- Bug fixes and polish

**Deliverable**: Production-ready Android app

## Technology Stack

### Core Dependencies

```kotlin
// build.gradle.kts (app module)
dependencies {
    // Compose BOM
    implementation(platform("androidx.compose:compose-bom:2024.02.00"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.material3:material3")
    implementation("androidx.compose.ui:ui-tooling-preview")

    // Navigation
    implementation("androidx.navigation:navigation-compose:2.7.7")

    // Room Database
    implementation("androidx.room:room-runtime:2.6.1")
    implementation("androidx.room:room-ktx:2.6.1")
    kapt("androidx.room:room-compiler:2.6.1")

    // Retrofit + OkHttp
    implementation("com.squareup.retrofit2:retrofit:2.9.0")
    implementation("com.squareup.retrofit2:converter-gson:2.9.0")
    implementation("com.squareup.okhttp3:okhttp:4.12.0")
    implementation("com.squareup.okhttp3:logging-interceptor:4.12.0")

    // Coroutines
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.8.0")

    // Hilt DI
    implementation("com.google.dagger:hilt-android:2.50")
    kapt("com.google.dagger:hilt-compiler:2.50")
    implementation("androidx.hilt:hilt-navigation-compose:1.2.0")

    // Security
    implementation("androidx.security:security-crypto:1.1.0-alpha06")

    // Markdown rendering
    implementation("io.noties.markwon:core:4.6.2")

    // PDF generation
    implementation("com.itextpdf:itext7-core:7.2.5")

    // JSON parsing
    implementation("com.google.code.gson:gson:2.10.1")

    // XML parsing (for PubMed responses)
    implementation("org.simpleframework:simple-xml:2.7.1")
}
```

### Minimum Requirements

- **Min SDK**: 26 (Android 8.0) - Required for security-crypto
- **Target SDK**: 34 (Android 14)
- **Kotlin**: 1.9.22
- **Gradle**: 8.2

## File Structure

```
app/
├── src/main/
│   ├── java/com/bmlibrarian/factchecker/
│   │   ├── di/                          # Dependency injection modules
│   │   │   ├── AppModule.kt
│   │   │   ├── DatabaseModule.kt
│   │   │   └── NetworkModule.kt
│   │   │
│   │   ├── data/                        # Data layer
│   │   │   ├── local/                   # Room database
│   │   │   │   ├── AppDatabase.kt
│   │   │   │   ├── dao/
│   │   │   │   │   ├── SessionDao.kt
│   │   │   │   │   ├── DocumentDao.kt
│   │   │   │   │   └── CitationDao.kt
│   │   │   │   ├── entity/
│   │   │   │   │   ├── SessionEntity.kt
│   │   │   │   │   ├── DocumentEntity.kt
│   │   │   │   │   ├── CitationEntity.kt
│   │   │   │   │   ├── ReportEntity.kt
│   │   │   │   │   └── UsageRecordEntity.kt
│   │   │   │   └── converter/
│   │   │   │       └── Converters.kt
│   │   │   │
│   │   │   ├── remote/                  # API services
│   │   │   │   ├── llm/
│   │   │   │   │   ├── LLMApi.kt
│   │   │   │   │   └── LLMService.kt
│   │   │   │   ├── pubmed/
│   │   │   │   │   ├── PubMedApi.kt
│   │   │   │   │   └── PubMedService.kt
│   │   │   │   └── europepmc/
│   │   │   │       ├── EuropePMCApi.kt
│   │   │   │       └── EuropePMCService.kt
│   │   │   │
│   │   │   └── repository/
│   │   │       ├── SessionRepository.kt
│   │   │       ├── DocumentRepository.kt
│   │   │       └── SettingsRepository.kt
│   │   │
│   │   ├── domain/                      # Domain layer
│   │   │   ├── model/                   # Domain models
│   │   │   │   ├── FactCheckSession.kt
│   │   │   │   ├── Document.kt
│   │   │   │   ├── Citation.kt
│   │   │   │   ├── EvidenceReport.kt
│   │   │   │   ├── LLMProvider.kt
│   │   │   │   └── WorkflowStep.kt
│   │   │   │
│   │   │   ├── workflow/
│   │   │   │   ├── FactCheckWorkflow.kt
│   │   │   │   └── WorkflowState.kt
│   │   │   │
│   │   │   └── usecase/
│   │   │       ├── ConvertQueryUseCase.kt
│   │   │       ├── ScoreDocumentsUseCase.kt
│   │   │       └── GenerateReportUseCase.kt
│   │   │
│   │   ├── ui/                          # Presentation layer
│   │   │   ├── navigation/
│   │   │   │   └── AppNavigation.kt
│   │   │   │
│   │   │   ├── factcheck/
│   │   │   │   ├── FactCheckScreen.kt
│   │   │   │   ├── FactCheckViewModel.kt
│   │   │   │   └── components/
│   │   │   │       ├── ClaimInput.kt
│   │   │   │       ├── SearchProgress.kt
│   │   │   │       ├── DocumentCard.kt
│   │   │   │       └── FetchMorePrompt.kt
│   │   │   │
│   │   │   ├── report/
│   │   │   │   ├── ReportScreen.kt
│   │   │   │   ├── ReportViewModel.kt
│   │   │   │   └── components/
│   │   │   │       ├── MarkdownReport.kt
│   │   │   │       └── VerdictBadge.kt
│   │   │   │
│   │   │   ├── history/
│   │   │   │   ├── HistoryScreen.kt
│   │   │   │   ├── HistoryViewModel.kt
│   │   │   │   └── components/
│   │   │   │       └── SessionCard.kt
│   │   │   │
│   │   │   ├── settings/
│   │   │   │   ├── SettingsScreen.kt
│   │   │   │   ├── SettingsViewModel.kt
│   │   │   │   └── components/
│   │   │   │       ├── ProviderSelector.kt
│   │   │   │       ├── ModelSelector.kt
│   │   │   │       └── BudgetSlider.kt
│   │   │   │
│   │   │   ├── onboarding/
│   │   │   │   ├── DisclaimerScreen.kt
│   │   │   │   └── OnboardingScreen.kt
│   │   │   │
│   │   │   ├── theme/
│   │   │   │   ├── Color.kt
│   │   │   │   ├── Theme.kt
│   │   │   │   └── Type.kt
│   │   │   │
│   │   │   └── components/              # Shared components
│   │   │       ├── LoadingIndicator.kt
│   │   │       └── ErrorMessage.kt
│   │   │
│   │   ├── util/
│   │   │   ├── CostCalculator.kt
│   │   │   ├── ResponseParser.kt
│   │   │   └── Extensions.kt
│   │   │
│   │   └── MedicalFactCheckerApp.kt     # Application class
│   │
│   └── res/
│       ├── values/
│       │   ├── strings.xml
│       │   └── themes.xml
│       └── drawable/
│
└── src/test/                            # Unit tests
    └── java/com/bmlibrarian/factchecker/
        ├── data/
        ├── domain/
        └── ui/
```

## Risk Assessment

| Risk | Likelihood | Impact | Mitigation |
|------|------------|--------|------------|
| LLM API changes | Low | High | Abstract behind interface, version pinning |
| PubMed rate limiting | Medium | Medium | Implement proper rate limiting, caching |
| Complex workflow bugs | Medium | High | Comprehensive testing, state persistence |
| UI performance issues | Low | Medium | LazyColumn, proper state management |
| Security vulnerabilities | Low | High | Use Android security best practices |

## Success Criteria

1. **Functional parity** with iOS app for core features
2. **Performance**: App startup < 2s, search results < 5s
3. **Reliability**: < 1% crash rate
4. **Security**: All API keys stored encrypted
5. **UX**: Material 3 design, responsive UI

## Related Documents

- [Phase 1: Project Setup](./01-project-setup.md)
- [Phase 2: Data Models & SQLite](./02-data-models.md)
- [Phase 3: API Services](./03-api-services.md)
- [Phase 4: Workflow Engine](./04-workflow-engine.md)
- [Phase 5: Settings & Security](./05-settings-security.md)
- [Phase 6: UI - Navigation & FactCheck](./06-ui-factcheck.md)
- [Phase 7: UI - Report View](./07-ui-report.md)
- [Phase 8: UI - History View](./08-ui-history.md)
- [Phase 9: UI - Settings View](./09-ui-settings.md)
- [Phase 10: Testing & Polish](./10-testing-polish.md)
