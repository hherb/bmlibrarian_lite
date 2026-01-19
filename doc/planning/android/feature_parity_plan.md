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

## Phase 1.5: Navigation Integration

### 1.5.1 Navigation Route Addition

**Goal**: Wire up the Full-Text Viewer to document cards and report screen

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/navigation/`

**Current State**:
- Navigation uses bottom tabs: FactCheck, Report, History, Settings
- `DocumentCard` is click-expandable only (no navigation)
- `DocumentDetailSheet` shows in modal bottom sheet with no full-text access

**Implementation**:

```kotlin
// NavRoutes.kt - Add new route
sealed class NavRoute(val route: String, val title: String) {
    // ... existing routes ...

    data object FullTextViewer : NavRoute(
        route = "fulltext",
        title = "Full Text"
    ) {
        const val routeWithArgs = "fulltext/{documentId}"
        const val ARG_DOCUMENT_ID = "documentId"

        fun createRoute(documentId: String) = "fulltext/$documentId"
    }
}
```

### 1.5.2 Navigation Composable

**Location**: `AppNavigation.kt`

```kotlin
// Add to NavHost composables
composable(
    route = NavRoute.FullTextViewer.routeWithArgs,
    arguments = listOf(
        navArgument(NavRoute.FullTextViewer.ARG_DOCUMENT_ID) {
            type = NavType.StringType
        }
    )
) { backStackEntry ->
    val documentId = backStackEntry.arguments
        ?.getString(NavRoute.FullTextViewer.ARG_DOCUMENT_ID) ?: return@composable

    FullTextViewerScreen(
        documentId = documentId,
        onNavigateBack = { navController.popBackStack() }
    )
}
```

### 1.5.3 DocumentCard Navigation

**File**: `ui/factcheck/components/DocumentCard.kt`

**Current**: Simple expansion toggle
```kotlin
clickable { expanded = !expanded }
```

**Updated**: Conditional navigation + expansion
```kotlin
@Composable
fun DocumentCard(
    document: Document,
    onViewFullText: (String) -> Unit,  // NEW: navigation callback
    modifier: Modifier = Modifier
) {
    var expanded by remember { mutableStateOf(false) }

    Card(
        modifier = modifier.clickable {
            if (document.hasFullText) {
                onViewFullText(document.id)
            } else {
                expanded = !expanded
            }
        }
    ) {
        // ... existing content ...

        // Add full-text button in expanded view
        if (expanded && !document.hasFullText && !document.fullTextUnavailable) {
            OutlinedButton(
                onClick = { /* Trigger fetch */ }
            ) {
                Icon(Icons.Default.Download, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text("Get Full Text")
            }
        }

        if (expanded && document.hasFullText) {
            FilledTonalButton(
                onClick = { onViewFullText(document.id) }
            ) {
                Icon(Icons.Default.Article, contentDescription = null)
                Spacer(modifier = Modifier.width(8.dp))
                Text("View Full Text")
            }
        }
    }
}
```

### 1.5.4 FactCheckScreen Integration

**File**: `ui/factcheck/FactCheckScreen.kt`

```kotlin
@Composable
fun FactCheckScreen(
    viewModel: FactCheckViewModel = hiltViewModel(),
    onNavigateToFullText: (String) -> Unit  // NEW
) {
    val documents by viewModel.documents.collectAsState()

    LazyColumn {
        items(documents) { document ->
            DocumentCard(
                document = document,
                onViewFullText = onNavigateToFullText  // Pass through
            )
        }
    }
}
```

### 1.5.5 DocumentDetailSheet Enhancement

**File**: `ui/report/components/DocumentDetailSheet.kt`

Add "View Full Text" button alongside "Open in PubMed":

```kotlin
@Composable
fun DocumentDetailSheet(
    document: Document,
    onDismiss: () -> Unit,
    onViewFullText: (String) -> Unit,  // NEW
    onOpenInPubMed: () -> Unit
) {
    ModalBottomSheet(onDismissRequest = onDismiss) {
        // ... existing content ...

        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(8.dp)
        ) {
            if (document.hasFullText || !document.fullTextUnavailable) {
                OutlinedButton(
                    onClick = { onViewFullText(document.id) },
                    modifier = Modifier.weight(1f)
                ) {
                    Icon(Icons.Default.Article, contentDescription = null)
                    Spacer(modifier = Modifier.width(4.dp))
                    Text(if (document.hasFullText) "View Full Text" else "Get Full Text")
                }
            }

            OutlinedButton(
                onClick = onOpenInPubMed,
                modifier = Modifier.weight(1f)
            ) {
                Icon(Icons.Default.OpenInBrowser, contentDescription = null)
                Spacer(modifier = Modifier.width(4.dp))
                Text("Open in PubMed")
            }
        }
    }
}
```

### 1.5.6 Full-Text Source Badge

**File**: `ui/fulltext/components/FullTextSourceBadge.kt`

```kotlin
@Composable
fun FullTextSourceBadge(
    source: String?,
    modifier: Modifier = Modifier
) {
    val (icon, label, color) = when (source) {
        Constants.FULLTEXT_SOURCE_EUROPE_PMC -> Triple(
            Icons.Default.Article,
            "Europe PMC",
            MaterialTheme.colorScheme.primary
        )
        Constants.FULLTEXT_SOURCE_UNPAYWALL -> Triple(
            Icons.Default.Lock, // Open lock icon
            "Unpaywall",
            Color(0xFF4CAF50) // Green
        )
        Constants.FULLTEXT_SOURCE_DOI -> Triple(
            Icons.Default.Link,
            "Publisher",
            MaterialTheme.colorScheme.secondary
        )
        Constants.FULLTEXT_SOURCE_CACHED -> Triple(
            Icons.Default.Storage,
            "Cached",
            MaterialTheme.colorScheme.tertiary
        )
        else -> return
    }

    Surface(
        shape = RoundedCornerShape(4.dp),
        color = color.copy(alpha = 0.12f),
        modifier = modifier
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(4.dp)
        ) {
            Icon(
                imageVector = icon,
                contentDescription = null,
                tint = color,
                modifier = Modifier.size(16.dp)
            )
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = color
            )
        }
    }
}
```

---

## Phase 2: User Experience Features (P1)

### 2.1 Onboarding System

**Goal**: Guided first-run experience explaining app features (9 pages matching iOS)

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/onboarding/`

**Reference**: `ios/MedicalFactChecker/Sources/Views/Onboarding/OnboardingView.swift`

**Data Model**:

```kotlin
// OnboardingPage.kt
data class OnboardingPage(
    val id: Int,
    val icon: ImageVector,
    val iconColors: List<Color>,  // Gradient colors
    val title: String,
    val description: String,
    val linkUrl: String? = null,
    val linkText: String? = null
)

// Predefined pages (match iOS exactly)
object OnboardingPages {
    val pages = listOf(
        OnboardingPage(
            id = 0,
            icon = Icons.Default.Science,
            iconColors = listOf(Color(0xFF4FC3F7), Color(0xFF2196F3)),
            title = "Welcome to Medical Fact Checker",
            description = "An AI-powered tool that helps you verify medical claims against peer-reviewed literature from PubMed and Europe PMC."
        ),
        OnboardingPage(
            id = 1,
            icon = Icons.Default.Edit,
            iconColors = listOf(Color(0xFFBA68C8), Color(0xFF9C27B0)),
            title = "Enter Your Claim",
            description = "Type any medical claim you want to verify. The AI will analyze it and search for relevant scientific evidence."
        ),
        OnboardingPage(
            id = 2,
            icon = Icons.Default.Search,
            iconColors = listOf(Color(0xFF81C784), Color(0xFF4CAF50)),
            title = "AI-Powered Search",
            description = "Our AI converts your claim into optimized search queries for PubMed and Europe PMC, finding the most relevant medical literature."
        ),
        OnboardingPage(
            id = 3,
            icon = Icons.Default.Analytics,
            iconColors = listOf(Color(0xFFFFB74D), Color(0xFFFF9800)),
            title = "Document Scoring",
            description = "Each document is scored for relevance using AI analysis. Higher scores indicate stronger relevance to your claim."
        ),
        OnboardingPage(
            id = 4,
            icon = Icons.Default.Assignment,
            iconColors = listOf(Color(0xFF4DD0E1), Color(0xFF00BCD4)),
            title = "Evidence Reports",
            description = "Get comprehensive reports synthesizing the evidence, with citations to source documents and clear verdicts."
        ),
        OnboardingPage(
            id = 5,
            icon = Icons.Default.Key,
            iconColors = listOf(Color(0xFFE57373), Color(0xFFF44336)),
            title = "API Keys Required",
            description = "You'll need an API key from an OpenAI-compatible LLM provider to use the scoring and report features."
        ),
        OnboardingPage(
            id = 6,
            icon = Icons.Default.AttachMoney,
            iconColors = listOf(Color(0xFFA5D6A7), Color(0xFF66BB6A)),
            title = "Pay-Per-Use Pricing",
            description = "LLM providers charge per token used. Set a budget limit to control costs. Typical fact-checks cost $0.01-0.10."
        ),
        OnboardingPage(
            id = 7,
            icon = Icons.Default.AutoAwesome,
            iconColors = listOf(Color(0xFFFFCC80), Color(0xFFFFB300)),
            title = "Free Trial with Mistral",
            description = "Mistral AI offers a free tier. Sign up at their console to get started without any cost.",
            linkUrl = "https://console.mistral.ai/",
            linkText = "Open Mistral Console"
        ),
        OnboardingPage(
            id = 8,
            icon = Icons.Default.RocketLaunch,
            iconColors = listOf(Color(0xFF90CAF9), Color(0xFF42A5F5)),
            title = "Ready to Start",
            description = "Configure your API key in Settings, then start fact-checking medical claims with scientific evidence!"
        )
    )
}
```

**Screen Implementation**:

```kotlin
// OnboardingScreen.kt
@OptIn(ExperimentalFoundationApi::class)
@Composable
fun OnboardingScreen(
    onComplete: () -> Unit
) {
    val pagerState = rememberPagerState(pageCount = { OnboardingPages.pages.size })
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(16.dp)
    ) {
        // Skip button (top-right)
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.End
        ) {
            TextButton(onClick = onComplete) {
                Text("Skip")
            }
        }

        // Pager
        HorizontalPager(
            state = pagerState,
            modifier = Modifier.weight(1f)
        ) { pageIndex ->
            OnboardingPageView(
                page = OnboardingPages.pages[pageIndex],
                onLinkClick = { url ->
                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(url))
                    context.startActivity(intent)
                }
            )
        }

        // Page indicators (dots)
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(vertical = 16.dp),
            horizontalArrangement = Arrangement.Center
        ) {
            repeat(OnboardingPages.pages.size) { index ->
                val isSelected = pagerState.currentPage == index
                Box(
                    modifier = Modifier
                        .padding(horizontal = 4.dp)
                        .size(if (isSelected) 10.dp else 8.dp)
                        .background(
                            color = if (isSelected)
                                MaterialTheme.colorScheme.primary
                            else
                                MaterialTheme.colorScheme.outline.copy(alpha = 0.5f),
                            shape = CircleShape
                        )
                )
            }
        }

        // Navigation buttons
        Row(
            modifier = Modifier.fillMaxWidth(),
            horizontalArrangement = Arrangement.spacedBy(16.dp)
        ) {
            // Back button
            if (pagerState.currentPage > 0) {
                OutlinedButton(
                    onClick = {
                        scope.launch {
                            pagerState.animateScrollToPage(pagerState.currentPage - 1)
                        }
                    },
                    modifier = Modifier.weight(1f)
                ) {
                    Text("Back")
                }
            } else {
                Spacer(modifier = Modifier.weight(1f))
            }

            // Next/Get Started button
            Button(
                onClick = {
                    if (pagerState.currentPage == OnboardingPages.pages.lastIndex) {
                        onComplete()
                    } else {
                        scope.launch {
                            pagerState.animateScrollToPage(pagerState.currentPage + 1)
                        }
                    }
                },
                modifier = Modifier.weight(1f)
            ) {
                Text(
                    if (pagerState.currentPage == OnboardingPages.pages.lastIndex)
                        "Get Started"
                    else
                        "Next"
                )
            }
        }
    }
}

@Composable
fun OnboardingPageView(
    page: OnboardingPage,
    onLinkClick: (String) -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .padding(24.dp),
        horizontalAlignment = Alignment.CenterHorizontally,
        verticalArrangement = Arrangement.Center
    ) {
        // Gradient icon
        Box(
            modifier = Modifier
                .size(80.dp)
                .background(
                    brush = Brush.linearGradient(page.iconColors),
                    shape = CircleShape
                ),
            contentAlignment = Alignment.Center
        ) {
            Icon(
                imageVector = page.icon,
                contentDescription = null,
                tint = Color.White,
                modifier = Modifier.size(40.dp)
            )
        }

        Spacer(modifier = Modifier.height(32.dp))

        Text(
            text = page.title,
            style = MaterialTheme.typography.headlineSmall,
            fontWeight = FontWeight.Bold,
            textAlign = TextAlign.Center
        )

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = page.description,
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        // Optional external link
        page.linkUrl?.let { url ->
            Spacer(modifier = Modifier.height(24.dp))
            TextButton(onClick = { onLinkClick(url) }) {
                Icon(
                    imageVector = Icons.Default.OpenInNew,
                    contentDescription = null,
                    modifier = Modifier.size(18.dp)
                )
                Spacer(modifier = Modifier.width(8.dp))
                Text(page.linkText ?: "Learn More")
            }
        }
    }
}
```

**ViewModel & Storage**:

```kotlin
// OnboardingViewModel.kt
@HiltViewModel
class OnboardingViewModel @Inject constructor(
    private val dataStore: DataStore<Preferences>
) : ViewModel() {

    companion object {
        val HAS_COMPLETED_ONBOARDING = booleanPreferencesKey("has_completed_onboarding")
    }

    val hasCompletedOnboarding: Flow<Boolean> = dataStore.data
        .map { preferences -> preferences[HAS_COMPLETED_ONBOARDING] ?: false }

    fun completeOnboarding() {
        viewModelScope.launch {
            dataStore.edit { preferences ->
                preferences[HAS_COMPLETED_ONBOARDING] = true
            }
        }
    }
}
```

**Constants**:
- Page count: 9 pages
- Icon size: 80.dp (gradient background), 40.dp (icon itself)
- Spacing: 32.dp (after icon), 16.dp (after title), 24.dp (before link)
- Indicator dot size: 10.dp (selected), 8.dp (unselected)

### 2.2 Disclaimer Screen

**Goal**: Legal disclaimer before first use (shown before onboarding)

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/disclaimer/`

**Reference**: `ios/MedicalFactChecker/Sources/Views/Onboarding/DisclaimerView.swift`

**Implementation**:

```kotlin
// DisclaimerPoint.kt
data class DisclaimerPoint(
    val icon: ImageVector,
    val title: String,
    val description: String
)

object DisclaimerPoints {
    val points = listOf(
        DisclaimerPoint(
            icon = Icons.Default.Psychology,
            title = "AI-Generated Analysis",
            description = "All analysis, scoring, and reports are generated by artificial intelligence and may contain errors or inaccuracies."
        ),
        DisclaimerPoint(
            icon = Icons.Default.LocalHospital,
            title = "Not Medical Advice",
            description = "This app does not provide medical advice, diagnosis, or treatment recommendations."
        ),
        DisclaimerPoint(
            icon = Icons.Default.People,
            title = "Consult Professionals",
            description = "Always consult qualified healthcare professionals for medical decisions and advice."
        ),
        DisclaimerPoint(
            icon = Icons.Default.Warning,
            title = "No Self-Treatment",
            description = "Never use this app to self-diagnose or self-treat medical conditions. Seek professional help."
        )
    )
}

// DisclaimerScreen.kt
@Composable
fun DisclaimerScreen(
    onAccept: () -> Unit
) {
    Column(
        modifier = Modifier
            .fillMaxSize()
            .background(MaterialTheme.colorScheme.background)
            .padding(16.dp),
        horizontalAlignment = Alignment.CenterHorizontally
    ) {
        Spacer(modifier = Modifier.height(32.dp))

        // App icon and title
        Icon(
            imageVector = Icons.Default.Science,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(64.dp)
        )

        Spacer(modifier = Modifier.height(16.dp))

        Text(
            text = "Medical Fact Checker",
            style = MaterialTheme.typography.headlineMedium,
            fontWeight = FontWeight.Bold
        )

        Spacer(modifier = Modifier.height(32.dp))

        // Disclaimer points in colored container
        Surface(
            modifier = Modifier.fillMaxWidth(),
            shape = RoundedCornerShape(12.dp),
            color = Color(0xFFFFF3E0) // Light orange background (matches iOS orange.opacity(0.1))
        ) {
            Column(
                modifier = Modifier.padding(16.dp),
                verticalArrangement = Arrangement.spacedBy(16.dp)
            ) {
                DisclaimerPoints.points.forEach { point ->
                    DisclaimerPointRow(point)
                }
            }
        }

        Spacer(modifier = Modifier.weight(1f))

        // Footer text
        Text(
            text = "By continuing, you acknowledge that you have read and understood these limitations.",
            style = MaterialTheme.typography.bodySmall,
            textAlign = TextAlign.Center,
            color = MaterialTheme.colorScheme.onSurfaceVariant
        )

        Spacer(modifier = Modifier.height(16.dp))

        // Accept button
        Button(
            onClick = onAccept,
            modifier = Modifier
                .fillMaxWidth()
                .height(48.dp),
            shape = RoundedCornerShape(12.dp)
        ) {
            Text(
                text = "I Understand",
                style = MaterialTheme.typography.titleMedium
            )
        }

        Spacer(modifier = Modifier.height(16.dp))
    }
}

@Composable
fun DisclaimerPointRow(point: DisclaimerPoint) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.spacedBy(12.dp)
    ) {
        Icon(
            imageVector = point.icon,
            contentDescription = null,
            tint = MaterialTheme.colorScheme.primary,
            modifier = Modifier.size(24.dp)
        )
        Column {
            Text(
                text = point.title,
                style = MaterialTheme.typography.titleSmall,
                fontWeight = FontWeight.Bold
            )
            Text(
                text = point.description,
                style = MaterialTheme.typography.bodySmall,
                color = MaterialTheme.colorScheme.onSurfaceVariant
            )
        }
    }
}
```

**Storage & ViewModel**:

```kotlin
// DisclaimerViewModel.kt
@HiltViewModel
class DisclaimerViewModel @Inject constructor(
    private val dataStore: DataStore<Preferences>
) : ViewModel() {

    companion object {
        val HAS_ACCEPTED_DISCLAIMER = booleanPreferencesKey("has_accepted_disclaimer")
    }

    val hasAcceptedDisclaimer: Flow<Boolean> = dataStore.data
        .map { preferences -> preferences[HAS_ACCEPTED_DISCLAIMER] ?: false }

    fun acceptDisclaimer() {
        viewModelScope.launch {
            dataStore.edit { preferences ->
                preferences[HAS_ACCEPTED_DISCLAIMER] = true
            }
        }
    }
}
```

**App Startup Flow**:
```kotlin
// In MainActivity or root composable
@Composable
fun AppRoot() {
    val disclaimerViewModel: DisclaimerViewModel = hiltViewModel()
    val onboardingViewModel: OnboardingViewModel = hiltViewModel()

    val hasAcceptedDisclaimer by disclaimerViewModel.hasAcceptedDisclaimer.collectAsState(initial = null)
    val hasCompletedOnboarding by onboardingViewModel.hasCompletedOnboarding.collectAsState(initial = null)

    when {
        hasAcceptedDisclaimer == null || hasCompletedOnboarding == null -> {
            // Loading state
            LoadingScreen()
        }
        hasAcceptedDisclaimer == false -> {
            DisclaimerScreen(
                onAccept = { disclaimerViewModel.acceptDisclaimer() }
            )
        }
        hasCompletedOnboarding == false -> {
            OnboardingScreen(
                onComplete = { onboardingViewModel.completeOnboarding() }
            )
        }
        else -> {
            // Main app content
            AppNavigation()
        }
    }
}
```

**Constants**:
- Background color: `Color(0xFFFFF3E0)` (light orange)
- Icon size: 64.dp (app icon), 24.dp (point icons)
- Button corner radius: 12.dp
- Content padding: 16.dp

### 2.3 Help Documentation

**Goal**: In-app help with usage guidance (loads markdown from assets)

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ui/help/`

**Reference**: `ios/MedicalFactChecker/Sources/Views/Settings/HelpView.swift`

**Markdown Parser Implementation**:

The iOS app has a custom markdown parser. For Android, use the Markwon library with similar styling:

```kotlin
// MarkdownViewer.kt
@Composable
fun MarkdownViewer(
    markdown: String,
    modifier: Modifier = Modifier
) {
    val context = LocalContext.current
    val isDarkTheme = isSystemInDarkTheme()

    // Configure Markwon with custom styling
    val markwon = remember(isDarkTheme) {
        Markwon.builder(context)
            .usePlugin(HtmlPlugin.create())
            .usePlugin(TablePlugin.create(context))
            .usePlugin(ImagesPlugin.create())
            .usePlugin(object : AbstractMarkwonPlugin() {
                override fun configureTheme(builder: MarkwonTheme.Builder) {
                    builder
                        .headingBreakHeight(0)
                        .codeBlockBackgroundColor(
                            if (isDarkTheme) Color(0xFF2D2D2D).toArgb()
                            else Color(0xFFF5F5F5).toArgb()
                        )
                        .codeBackgroundColor(
                            if (isDarkTheme) Color(0xFF2D2D2D).toArgb()
                            else Color(0xFFF5F5F5).toArgb()
                        )
                        .blockQuoteColor(
                            if (isDarkTheme) Color(0xFF4CAF50).toArgb()
                            else Color(0xFF2196F3).toArgb()
                        )
                }
            })
            .build()
    }

    AndroidView(
        modifier = modifier.fillMaxSize(),
        factory = { ctx ->
            TextView(ctx).apply {
                setTextIsSelectable(true)
                setPadding(16.dpToPx(ctx), 16.dpToPx(ctx), 16.dpToPx(ctx), 16.dpToPx(ctx))
                textSize = 16f
                setLineSpacing(4f, 1.2f)
            }
        },
        update = { textView ->
            markwon.setMarkdown(textView, markdown)
        }
    )
}

fun Int.dpToPx(context: Context): Int {
    return (this * context.resources.displayMetrics.density).toInt()
}
```

**Help Screen**:

```kotlin
// HelpScreen.kt
@Composable
fun HelpScreen(
    onNavigateBack: () -> Unit
) {
    val context = LocalContext.current
    var markdownContent by remember { mutableStateOf("Loading...") }
    var loadError by remember { mutableStateOf<String?>(null) }

    // Load markdown from assets
    LaunchedEffect(Unit) {
        try {
            markdownContent = context.assets.open("help/HELP.md")
                .bufferedReader()
                .use { it.readText() }
        } catch (e: Exception) {
            loadError = "Failed to load help content"
            markdownContent = getFallbackHelpContent()
        }
    }

    Scaffold(
        topBar = {
            TopAppBar(
                title = { Text("Help") },
                navigationIcon = {
                    IconButton(onClick = onNavigateBack) {
                        Icon(Icons.Default.ArrowBack, contentDescription = "Back")
                    }
                }
            )
        }
    ) { paddingValues ->
        if (loadError != null) {
            // Show error with fallback
            Column(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
            ) {
                Text(
                    text = loadError!!,
                    color = MaterialTheme.colorScheme.error,
                    modifier = Modifier.padding(16.dp)
                )
                MarkdownViewer(
                    markdown = markdownContent,
                    modifier = Modifier.weight(1f)
                )
            }
        } else {
            LazyColumn(
                modifier = Modifier
                    .fillMaxSize()
                    .padding(paddingValues)
            ) {
                item {
                    MarkdownViewer(markdown = markdownContent)
                }
            }
        }
    }
}

// Fallback content if file not found
fun getFallbackHelpContent(): String = """
# Medical Fact Checker Help

## Getting Started

1. **Enter a Claim**: Type a medical claim you want to verify
2. **Search**: The AI generates search queries for PubMed and Europe PMC
3. **Review**: Documents are scored for relevance (1-5)
4. **Report**: Get a synthesized evidence report

## Search Providers

- **PubMed**: NCBI's biomedical literature database
- **Europe PMC**: European life sciences database with full-text access

## Understanding Scores

| Score | Meaning |
|-------|---------|
| 5 | Directly relevant |
| 4 | Highly relevant |
| 3 | Moderately relevant |
| 2 | Marginally relevant |
| 1 | Not relevant |

## Configuring Your LLM

1. Go to **Settings**
2. Enter your **API Base URL** (e.g., https://api.openai.com/v1)
3. Enter your **API Key**
4. Select a **Model** (e.g., gpt-4o-mini)

## Budget Management

- Set a monthly budget in Settings
- Track usage in real-time
- Get warnings when approaching limit

## Troubleshooting

**No results found?**
- Try broader search terms
- Check your internet connection

**API errors?**
- Verify your API key is correct
- Check your budget isn't exceeded
""".trimIndent()
```

**Privacy Screen** (similar pattern):

```kotlin
// PrivacyScreen.kt
@Composable
fun PrivacyScreen(
    onNavigateBack: () -> Unit
) {
    // Same pattern as HelpScreen, loading PRIVACY.md
}
```

**Assets Structure**:

```
app/src/main/assets/
└── help/
    ├── HELP.md
    └── PRIVACY.md
```

**HELP.md Content** (place in assets):

```markdown
# Medical Fact Checker Help

Welcome to Medical Fact Checker! This guide will help you get the most out of the app.

## Getting Started

### Step 1: Enter a Medical Claim
Type any medical claim you want to verify in the text field. For example:
- "Vitamin D supplementation reduces the risk of COVID-19"
- "Statins cause muscle pain in most patients"
- "Intermittent fasting improves insulin sensitivity"

### Step 2: Search Scientific Literature
The app uses AI to convert your claim into optimized search queries, then searches:
- **PubMed**: The premier biomedical literature database from NCBI
- **Europe PMC**: A comprehensive life sciences database with full-text access

### Step 3: Review Scored Documents
Each document is scored for relevance:

| Score | Meaning | Color |
|-------|---------|-------|
| 5 | Directly addresses the claim | Green |
| 4 | Highly relevant evidence | Blue |
| 3 | Moderately relevant | Yellow |
| 2 | Marginally relevant | Orange |
| 1 | Not relevant to the claim | Red |

### Step 4: Read the Evidence Report
Get a comprehensive report that:
- Synthesizes evidence from multiple sources
- Provides a verdict (Supported, Refuted, Uncertain, Mixed)
- Includes citations to source documents

## Search Providers

### PubMed
- Official database from the National Center for Biotechnology Information
- Contains 35+ million citations
- Best for established medical literature

### Europe PMC
- European life sciences literature database
- Often provides full-text access
- Excellent for recent publications

## Configuring Your LLM Provider

Medical Fact Checker uses OpenAI-compatible APIs. You can use:
- OpenAI (gpt-4o-mini, gpt-4o)
- Mistral AI (free tier available)
- Anthropic Claude
- Local models via Ollama

### Setup Steps
1. Go to **Settings** (gear icon)
2. Enter your **API Base URL**
3. Enter your **API Key**
4. Select your preferred **Model**
5. Tap **Test Connection** to verify

## Budget Management

Control your costs with budget limits:
- Set a monthly spending limit
- View real-time usage tracking
- Receive warnings at 80% and 100%

Typical costs:
- Simple fact-check: $0.01-0.05
- Complex multi-document analysis: $0.05-0.15

## Troubleshooting

### "No relevant documents found"
- Try rephrasing your claim
- Use more general terms
- Check spelling of medical terms

### "API connection failed"
- Verify your API key is correct
- Check your internet connection
- Ensure your API provider is operational

### "Budget exceeded"
- Increase your budget limit in Settings
- Wait for the next billing cycle
- Consider using a more efficient model

## Privacy & Data

- Your claims are sent to your configured LLM provider
- Search queries are sent to PubMed and Europe PMC
- No data is stored on our servers
- History is stored locally on your device
```

**Dependencies**:
```kotlin
// In build.gradle.kts
implementation("io.noties.markwon:core:4.6.2")
implementation("io.noties.markwon:html:4.6.2")
implementation("io.noties.markwon:image:4.6.2")
implementation("io.noties.markwon:ext-tables:4.6.2")
```

**Settings Screen Integration**:
```kotlin
// In SettingsScreen.kt
SettingsItem(
    icon = Icons.Default.Help,
    title = "Help",
    onClick = onNavigateToHelp
)
SettingsItem(
    icon = Icons.Default.PrivacyTip,
    title = "Privacy Policy",
    onClick = onNavigateToPrivacy
)
```

### 2.4 Smart Search (Alternative Queries)

**Goal**: Generate alternative search queries when initial results are poor

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/domain/usecase/`

**Reference**: `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift` (search for `smartSearch`)

**Key Constants**:
```kotlin
// In Constants.kt
const val SMART_SEARCH_THRESHOLD = 3  // Min relevant docs before triggering
const val MAX_ALTERNATIVE_QUERIES = 3  // Max alternative queries to generate
const val JSON_PARSE_RETRY_ATTEMPTS = 3
const val JSON_PARSE_BASE_DELAY_MS = 1000L
const val JSON_PARSE_BACKOFF_MULTIPLIER = 2.0
```

**Data Models**:

```kotlin
// AlternativeQuery.kt
data class AlternativeQuery(
    val concepts: List<QueryConcept>,
    val strategy: String,       // e.g., "broader_terms", "synonyms", "split_query"
    val rationale: String
)

data class QueryConcept(
    val term: String,
    val meshTerms: List<String>? = null,
    val keywords: List<String>? = null
)

// Serializable for storing in session
@Serializable
data class AlternativeQueryJson(
    val concepts: List<QueryConceptJson>,
    val strategy: String,
    val rationale: String
)

@Serializable
data class QueryConceptJson(
    val term: String,
    val meshTerms: List<String>? = null,
    val keywords: List<String>? = null
)
```

**Use Case Implementation**:

```kotlin
// GenerateAlternativeQueriesUseCase.kt
class GenerateAlternativeQueriesUseCase @Inject constructor(
    private val llmService: LLMService
) {
    suspend fun execute(
        originalClaim: String,
        originalQuery: StructuredQuery,
        relevantCount: Int,
        totalFound: Int
    ): Result<List<AlternativeQuery>> = runCatching {
        val prompt = buildPrompt(originalClaim, originalQuery, relevantCount, totalFound)

        var attempts = 0
        var lastError: Exception? = null

        while (attempts < Constants.JSON_PARSE_RETRY_ATTEMPTS) {
            try {
                val response = llmService.complete(prompt)
                return@runCatching parseAlternativeQueries(response)
            } catch (e: JsonParseException) {
                lastError = e
                attempts++
                if (attempts < Constants.JSON_PARSE_RETRY_ATTEMPTS) {
                    val delay = Constants.JSON_PARSE_BASE_DELAY_MS *
                        Constants.JSON_PARSE_BACKOFF_MULTIPLIER.pow(attempts - 1).toLong()
                    delay(delay)
                }
            }
        }
        throw lastError ?: IllegalStateException("Failed to parse alternative queries")
    }

    private fun buildPrompt(
        claim: String,
        originalQuery: StructuredQuery,
        relevantCount: Int,
        totalFound: Int
    ): String = """
        The initial search for the medical claim found only $relevantCount relevant documents out of $totalFound total.

        Original claim: "$claim"
        Original query concepts: ${originalQuery.concepts.map { it.term }}

        Generate 2-3 alternative search strategies as structured queries. Consider:
        1. If comparing two treatments/medications, search for each separately
        2. Use different synonyms or related terms (consider MeSH alternatives)
        3. Break compound questions into simpler components
        4. Try broader or narrower search terms
        5. Focus on key outcomes or mechanisms

        Return JSON array with this structure:
        [
          {
            "concepts": [
              {
                "term": "main concept",
                "meshTerms": ["MeSH Term 1", "MeSH Term 2"],
                "keywords": ["keyword1", "keyword2"]
              }
            ],
            "strategy": "broader_terms|synonyms|split_query|focus_outcome",
            "rationale": "Brief explanation of why this might find more relevant results"
          }
        ]

        Return ONLY the JSON array, no other text.
    """.trimIndent()

    private fun parseAlternativeQueries(response: String): List<AlternativeQuery> {
        // Extract JSON from response (handle markdown code blocks)
        val jsonString = response
            .replace("```json", "")
            .replace("```", "")
            .trim()

        val jsonList: List<AlternativeQueryJson> = Json.decodeFromString(jsonString)
        return jsonList.map { json ->
            AlternativeQuery(
                concepts = json.concepts.map { c ->
                    QueryConcept(
                        term = c.term,
                        meshTerms = c.meshTerms,
                        keywords = c.keywords
                    )
                },
                strategy = json.strategy,
                rationale = json.rationale
            )
        }
    }
}
```

**Workflow Integration**:

```kotlin
// In FactCheckWorkflow.kt
class FactCheckWorkflow @Inject constructor(
    private val generateAlternatives: GenerateAlternativeQueriesUseCase,
    private val searchService: SearchService,
    // ... other dependencies
) {
    private val _awaitingSmartSearchDecision = MutableStateFlow(false)
    val awaitingSmartSearchDecision: StateFlow<Boolean> = _awaitingSmartSearchDecision

    private var fetchedPmids: MutableSet<String> = mutableSetOf()
    private var currentAlternativeQueries: List<AlternativeQuery> = emptyList()
    private var currentAlternativeIndex = 0

    suspend fun checkAndTriggerSmartSearch(
        session: FactCheckSession,
        relevantCount: Int
    ) {
        if (relevantCount < Constants.SMART_SEARCH_THRESHOLD &&
            !session.smartSearchEnabled &&
            session.alternativeQueries == null
        ) {
            // Generate alternatives
            val result = generateAlternatives.execute(
                originalClaim = session.claim,
                originalQuery = session.structuredQuery,
                relevantCount = relevantCount,
                totalFound = session.documents.size
            )

            result.onSuccess { alternatives ->
                currentAlternativeQueries = alternatives
                // Notify UI that user decision is needed
                _awaitingSmartSearchDecision.value = true
                onSmartSearchAvailable?.invoke(alternatives.size)
            }
        }
    }

    fun continueWithSmartSearch() {
        _awaitingSmartSearchDecision.value = false
        viewModelScope.launch {
            executeSmartSearch()
        }
    }

    fun skipSmartSearch() {
        _awaitingSmartSearchDecision.value = false
        currentAlternativeQueries = emptyList()
    }

    private suspend fun executeSmartSearch() {
        for ((index, alternative) in currentAlternativeQueries.withIndex()) {
            currentAlternativeIndex = index

            onProgress?.invoke(
                "Trying alternative search ${index + 1}/${currentAlternativeQueries.size}: ${alternative.strategy}"
            )

            // Convert alternative to search query
            val query = buildQueryFromAlternative(alternative)

            // Execute search
            val results = searchService.search(query)

            // Filter out already-fetched PMIDs
            val newResults = results.filter { doc ->
                doc.pmid?.let { it !in fetchedPmids } ?: true
            }

            // Add new PMIDs to fetched set
            newResults.forEach { doc ->
                doc.pmid?.let { fetchedPmids.add(it) }
            }

            if (newResults.isNotEmpty()) {
                // Score new documents
                onNewDocumentsFound?.invoke(newResults)
                scoreDocuments(newResults)

                // Check if we have enough relevant docs now
                val newRelevantCount = countRelevantDocs()
                if (newRelevantCount >= Constants.SMART_SEARCH_THRESHOLD) {
                    break
                }
            }
        }

        // Update session with smart search results
        updateSessionWithSmartSearchResults()
    }

    // Callback hooks
    var onProgress: ((String) -> Unit)? = null
    var onSmartSearchAvailable: ((Int) -> Unit)? = null
    var onNewDocumentsFound: ((List<Document>) -> Unit)? = null
}
```

**UI Integration**:

```kotlin
// In FactCheckScreen.kt
@Composable
fun FactCheckScreen(viewModel: FactCheckViewModel = hiltViewModel()) {
    val awaitingSmartSearch by viewModel.awaitingSmartSearchDecision.collectAsState()
    val smartSearchProgress by viewModel.smartSearchProgress.collectAsState()

    // Smart Search Decision Dialog
    if (awaitingSmartSearch) {
        AlertDialog(
            onDismissRequest = { viewModel.skipSmartSearch() },
            title = { Text("Try Alternative Searches?") },
            text = {
                Text(
                    "The initial search found few relevant documents. " +
                    "Would you like to try ${viewModel.alternativeQueryCount} " +
                    "alternative search strategies?"
                )
            },
            confirmButton = {
                Button(onClick = { viewModel.continueWithSmartSearch() }) {
                    Text("Try Alternatives")
                }
            },
            dismissButton = {
                TextButton(onClick = { viewModel.skipSmartSearch() }) {
                    Text("Skip")
                }
            }
        )
    }

    // Smart Search Progress
    smartSearchProgress?.let { progress ->
        LinearProgressIndicator(
            modifier = Modifier.fillMaxWidth()
        )
        Text(
            text = progress,
            style = MaterialTheme.typography.bodySmall,
            modifier = Modifier.padding(horizontal = 16.dp)
        )
    }
}
```

**Session Entity Updates**:

```kotlin
@Entity(tableName = "sessions")
data class SessionEntity(
    // ... existing fields ...

    // Smart Search fields
    @ColumnInfo(name = "smart_search_enabled")
    val smartSearchEnabled: Boolean = false,

    @ColumnInfo(name = "alternative_queries")
    val alternativeQueries: String? = null, // JSON array of AlternativeQueryJson

    @ColumnInfo(name = "current_alternative_index")
    val currentAlternativeIndex: Int = 0,

    @ColumnInfo(name = "fetched_pmids")
    val fetchedPmids: String? = null, // JSON array of PMIDs for deduplication

    @ColumnInfo(name = "smart_search_completed_at")
    val smartSearchCompletedAt: Long? = null
)
```

**History Screen Enhancement**:

Show smart search status in session history:

```kotlin
// In SessionCard.kt
if (session.smartSearchEnabled) {
    Surface(
        shape = RoundedCornerShape(4.dp),
        color = MaterialTheme.colorScheme.tertiaryContainer
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 6.dp, vertical = 2.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(12.dp)
            )
            Text(
                text = "Smart Search",
                style = MaterialTheme.typography.labelSmall
            )
        }
    }
}
```

---

## Phase 3: Advanced Scoring Features (P2)

### 3.1 On-Device Embedding Service

**Goal**: Free, on-device semantic similarity scoring (matches iOS NLEmbedding approach)

**Reference**: `ios/MedicalFactChecker/Sources/Services/EmbeddingService.swift`

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ml/`

**Technology Options**:
1. **TensorFlow Lite** with Universal Sentence Encoder (recommended)
2. **ONNX Runtime** with MiniLM-L6-v2
3. **MediaPipe** Text Embedder

**Recommended**: TensorFlow Lite with Universal Sentence Encoder Lite (~25MB)

**Key Constants** (match iOS exactly):

```kotlin
// In Constants.kt
object EmbeddingConstants {
    // Similarity to relevance score thresholds (from iOS)
    const val THRESHOLD_NOT_RELEVANT = 0.3f      // < 0.3 → 1
    const val THRESHOLD_MARGINAL = 0.45f         // 0.3-0.45 → 2
    const val THRESHOLD_MODERATE = 0.55f         // 0.45-0.55 → 3
    const val THRESHOLD_HIGHLY_RELEVANT = 0.7f   // 0.55-0.7 → 4
                                                  // >= 0.7 → 5

    // Model configuration
    const val MODEL_FILENAME = "universal_sentence_encoder.tflite"
    const val EMBEDDING_DIM = 512  // USE outputs 512-dimensional vectors
    const val MAX_SEQUENCE_LENGTH = 128
}
```

**Service Implementation**:

```kotlin
// EmbeddingService.kt
@Singleton
class EmbeddingService @Inject constructor(
    @ApplicationContext private val context: Context
) {
    private var interpreter: Interpreter? = null
    private var isInitialized = false

    data class EmbeddingScore(
        val documentId: String,
        val rawScore: Float,      // 0.0 - 1.0 cosine similarity
        val normalizedScore: Int  // 1-5 scale
    )

    /**
     * Check if embedding service is available
     * Returns false on older devices or if model fails to load
     */
    val isAvailable: Boolean
        get() = try {
            // Check if we can access the model file
            context.assets.open(EmbeddingConstants.MODEL_FILENAME).close()
            true
        } catch (e: Exception) {
            false
        }

    /**
     * Initialize the TFLite interpreter
     * Call once before using computeSimilarity
     */
    suspend fun initialize(): Boolean = withContext(Dispatchers.IO) {
        if (isInitialized) return@withContext true

        try {
            val modelFile = loadModelFile()
            val options = Interpreter.Options().apply {
                setNumThreads(4)
                // Use NNAPI delegate if available for hardware acceleration
                addDelegate(NnApiDelegate())
            }
            interpreter = Interpreter(modelFile, options)
            isInitialized = true
            true
        } catch (e: Exception) {
            Log.e("EmbeddingService", "Failed to initialize: ${e.message}")
            false
        }
    }

    private fun loadModelFile(): MappedByteBuffer {
        val fileDescriptor = context.assets.openFd(EmbeddingConstants.MODEL_FILENAME)
        val inputStream = FileInputStream(fileDescriptor.fileDescriptor)
        val fileChannel = inputStream.channel
        val startOffset = fileDescriptor.startOffset
        val declaredLength = fileDescriptor.declaredLength
        return fileChannel.map(FileChannel.MapMode.READ_ONLY, startOffset, declaredLength)
    }

    /**
     * Compute similarity between claim and a single document
     * Returns null if service unavailable or computation fails
     */
    fun computeSimilarity(claim: String, documentText: String): Float? {
        val interp = interpreter ?: return null

        try {
            val claimEmbedding = computeEmbedding(claim, interp) ?: return null
            val docEmbedding = computeEmbedding(documentText, interp) ?: return null
            return cosineSimilarity(claimEmbedding, docEmbedding)
        } catch (e: Exception) {
            Log.e("EmbeddingService", "Similarity computation failed: ${e.message}")
            return null
        }
    }

    /**
     * Score multiple documents in batch (more efficient)
     * Computes claim embedding once and reuses for all documents
     */
    suspend fun scoreDocuments(
        claim: String,
        documents: List<Document>
    ): List<EmbeddingScore> = withContext(Dispatchers.Default) {
        val interp = interpreter ?: return@withContext emptyList()

        try {
            // Compute claim embedding once
            val claimEmbedding = computeEmbedding(claim, interp)
                ?: return@withContext emptyList()

            // Score each document
            documents.mapNotNull { doc ->
                val documentText = buildDocumentText(doc)
                val docEmbedding = computeEmbedding(documentText, interp)
                    ?: return@mapNotNull null

                val rawScore = cosineSimilarity(claimEmbedding, docEmbedding)
                EmbeddingScore(
                    documentId = doc.id,
                    rawScore = rawScore,
                    normalizedScore = normalizeToRelevanceScale(rawScore)
                )
            }
        } catch (e: Exception) {
            Log.e("EmbeddingService", "Batch scoring failed: ${e.message}")
            emptyList()
        }
    }

    /**
     * Build document text for embedding
     * Format: "{title}. {abstract}" (title first for position weighting)
     */
    private fun buildDocumentText(document: Document): String {
        return buildString {
            append(document.title)
            if (!document.title.endsWith(".")) append(".")
            append(" ")
            document.abstractText?.let { append(it) }
        }
    }

    private fun computeEmbedding(text: String, interpreter: Interpreter): FloatArray? {
        // Tokenize and prepare input
        // Note: Actual implementation depends on model's expected input format
        // USE typically expects string input directly

        val inputArray = arrayOf(text)
        val outputArray = Array(1) { FloatArray(EmbeddingConstants.EMBEDDING_DIM) }

        interpreter.run(inputArray, outputArray)
        return outputArray[0]
    }

    /**
     * Compute cosine similarity between two vectors
     * Returns value in range [-1, 1], typically [0, 1] for text embeddings
     */
    private fun cosineSimilarity(a: FloatArray, b: FloatArray): Float {
        require(a.size == b.size) { "Vectors must have same dimension" }

        var dotProduct = 0f
        var normA = 0f
        var normB = 0f

        for (i in a.indices) {
            dotProduct += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }

        val denominator = sqrt(normA) * sqrt(normB)
        return if (denominator > 0) dotProduct / denominator else 0f
    }

    /**
     * Convert raw similarity (0.0-1.0) to 1-5 relevance scale
     * Thresholds match iOS implementation exactly
     */
    fun normalizeToRelevanceScale(similarity: Float): Int {
        return when {
            similarity < EmbeddingConstants.THRESHOLD_NOT_RELEVANT -> 1
            similarity < EmbeddingConstants.THRESHOLD_MARGINAL -> 2
            similarity < EmbeddingConstants.THRESHOLD_MODERATE -> 3
            similarity < EmbeddingConstants.THRESHOLD_HIGHLY_RELEVANT -> 4
            else -> 5
        }
    }

    /**
     * Release resources when no longer needed
     */
    fun close() {
        interpreter?.close()
        interpreter = null
        isInitialized = false
    }
}
```

**Settings Integration**:

```kotlin
// In AppSettings (DataStore)
val EMBEDDING_SCORING_ENABLED = booleanPreferencesKey("embedding_scoring_enabled")

// In SettingsViewModel
val embeddingScoringEnabled: StateFlow<Boolean>

fun setEmbeddingScoringEnabled(enabled: Boolean) {
    viewModelScope.launch {
        dataStore.edit { preferences ->
            preferences[EMBEDDING_SCORING_ENABLED] = enabled
        }
    }
}

// In SettingsScreen
SwitchSettingsItem(
    icon = Icons.Default.Memory,
    title = "On-Device Scoring",
    description = "Use local AI for free relevance scoring (in addition to LLM)",
    checked = embeddingScoringEnabled,
    onCheckedChange = { viewModel.setEmbeddingScoringEnabled(it) },
    enabled = embeddingService.isAvailable
)
```

**Document Entity Updates**:

```kotlin
@Entity(tableName = "documents")
data class DocumentEntity(
    // ... existing fields ...

    // Embedding score fields
    @ColumnInfo(name = "embedding_score")
    val embeddingScore: Float? = null,  // Raw cosine similarity

    @ColumnInfo(name = "embedding_relevance")
    val embeddingRelevance: Int? = null,  // Normalized 1-5

    @ColumnInfo(name = "embedding_scored_at")
    val embeddingScoredAt: Long? = null
)
```

**DocumentCard with Dual Scores**:

```kotlin
@Composable
fun DocumentCard(
    document: Document,
    showEmbeddingScore: Boolean,
    // ... other params
) {
    // ... existing card content ...

    // Score badges row
    Row(
        horizontalArrangement = Arrangement.spacedBy(8.dp)
    ) {
        // LLM Score (primary)
        document.llmScore?.let { score ->
            ScoreBadge(
                score = score,
                label = "LLM",
                isPrimary = true
            )
        }

        // Embedding Score (secondary, if enabled)
        if (showEmbeddingScore) {
            document.embeddingRelevance?.let { score ->
                ScoreBadge(
                    score = score,
                    label = "Local",
                    isPrimary = false
                )
            }
        }
    }
}

@Composable
fun ScoreBadge(
    score: Int,
    label: String,
    isPrimary: Boolean
) {
    val backgroundColor = when (score) {
        5 -> Color(0xFF4CAF50)  // Green
        4 -> Color(0xFF2196F3)  // Blue
        3 -> Color(0xFFFFEB3B)  // Yellow
        2 -> Color(0xFFFF9800)  // Orange
        else -> Color(0xFFF44336)  // Red
    }

    Surface(
        shape = RoundedCornerShape(4.dp),
        color = backgroundColor.copy(alpha = if (isPrimary) 1f else 0.7f)
    ) {
        Column(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalAlignment = Alignment.CenterHorizontally
        ) {
            Text(
                text = score.toString(),
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold,
                color = if (score == 3) Color.Black else Color.White
            )
            Text(
                text = label,
                style = MaterialTheme.typography.labelSmall,
                color = if (score == 3) Color.Black.copy(alpha = 0.7f)
                       else Color.White.copy(alpha = 0.7f)
            )
        }
    }
}
```

**Workflow Integration**:

```kotlin
// In FactCheckWorkflow
suspend fun scoreDocumentsWithEmbedding(
    claim: String,
    documents: List<Document>
) {
    if (!settings.embeddingScoringEnabled || !embeddingService.isAvailable) {
        return
    }

    // Use HyDE abstract if available, otherwise use raw claim
    val queryText = session.hydeAbstract ?: claim

    val scores = embeddingService.scoreDocuments(queryText, documents)

    // Update documents with embedding scores
    scores.forEach { score ->
        documentRepository.updateEmbeddingScore(
            documentId = score.documentId,
            rawScore = score.rawScore,
            normalizedScore = score.normalizedScore
        )
    }
}
```

**Dependencies**:

```kotlin
// In build.gradle.kts
dependencies {
    // TensorFlow Lite
    implementation("org.tensorflow:tensorflow-lite:2.14.0")
    implementation("org.tensorflow:tensorflow-lite-support:0.4.4")

    // Optional: NNAPI delegate for hardware acceleration
    implementation("org.tensorflow:tensorflow-lite-gpu:2.14.0")
}
```

**Model Download Note**:

The TFLite model should be downloaded from TensorFlow Hub:
- Universal Sentence Encoder Lite: https://tfhub.dev/google/lite-model/universal-sentence-encoder-qa-ondevice/1
- Place in `app/src/main/assets/universal_sentence_encoder.tflite`

### 3.2 HyDE (Hypothetical Document Embedding)

**Goal**: Generate synthetic "ideal" abstract for better embedding matching

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/ml/`

**Background**:

HyDE (Hypothetical Document Embeddings) improves embedding-based retrieval by:
1. Converting the query (claim) into a hypothetical document that would answer it
2. Using this synthetic document for embedding comparison instead of the raw query
3. This bridges the semantic gap between short queries and full abstracts

**Implementation**:

```kotlin
// HydeGenerator.kt
class HydeGenerator @Inject constructor(
    private val llmService: LLMService
) {
    companion object {
        const val TARGET_WORD_COUNT_MIN = 150
        const val TARGET_WORD_COUNT_MAX = 200
    }

    /**
     * Generate a hypothetical abstract that would address the given claim.
     * Returns null if generation fails.
     */
    suspend fun generateHypotheticalAbstract(claim: String): String? {
        return try {
            val prompt = buildPrompt(claim)
            val response = llmService.complete(prompt)
            validateAndClean(response)
        } catch (e: Exception) {
            Log.e("HydeGenerator", "Failed to generate HyDE abstract: ${e.message}")
            null
        }
    }

    private fun buildPrompt(claim: String): String = """
        Given the medical claim: "$claim"

        Write a hypothetical abstract ($TARGET_WORD_COUNT_MIN-$TARGET_WORD_COUNT_MAX words) of a scientific study that would directly address this claim.

        Include typical abstract sections:
        - **Background**: Why this topic matters
        - **Methods**: Study design and participants
        - **Results**: Key findings with statistics
        - **Conclusion**: What the evidence suggests

        Use medical terminology appropriate for a peer-reviewed publication. Write as if this is a real published study abstract.

        Output ONLY the abstract text, no headings or labels.
    """.trimIndent()

    private fun validateAndClean(response: String): String? {
        val cleaned = response
            .replace(Regex("^(Background|Methods|Results|Conclusion):?\\s*", RegexOption.MULTILINE), "")
            .replace(Regex("\\*\\*[^*]+\\*\\*:?\\s*"), "")  // Remove **bold** headers
            .trim()

        // Validate word count
        val wordCount = cleaned.split(Regex("\\s+")).size
        if (wordCount < TARGET_WORD_COUNT_MIN / 2) {
            Log.w("HydeGenerator", "Generated abstract too short: $wordCount words")
            return null
        }

        return cleaned
    }
}
```

**Workflow Integration**:

```kotlin
// In FactCheckWorkflow
private suspend fun prepareForEmbeddingScoring() {
    // Generate HyDE abstract if embedding scoring is enabled
    if (settings.embeddingScoringEnabled && session.hydeAbstract == null) {
        onProgress?.invoke("Generating hypothetical document for better matching...")

        val hydeAbstract = hydeGenerator.generateHypotheticalAbstract(session.claim)

        if (hydeAbstract != null) {
            session = session.copy(hydeAbstract = hydeAbstract)
            sessionRepository.updateHydeAbstract(session.id, hydeAbstract)
        }
    }
}

suspend fun scoreDocumentsWithEmbedding(
    claim: String,
    documents: List<Document>
) {
    if (!settings.embeddingScoringEnabled || !embeddingService.isAvailable) {
        return
    }

    // Prepare HyDE abstract
    await prepareForEmbeddingScoring()

    // Use HyDE abstract if available, otherwise fall back to raw claim
    val queryText = session.hydeAbstract ?: claim

    val scores = embeddingService.scoreDocuments(queryText, documents)

    scores.forEach { score ->
        documentRepository.updateEmbeddingScore(
            documentId = score.documentId,
            rawScore = score.rawScore,
            normalizedScore = score.normalizedScore
        )
    }
}
```

**Session Entity Updates**:

```kotlin
@Entity(tableName = "sessions")
data class SessionEntity(
    // ... existing fields ...

    // HyDE field
    @ColumnInfo(name = "hyde_abstract")
    val hydeAbstract: String? = null,

    @ColumnInfo(name = "hyde_generated_at")
    val hydeGeneratedAt: Long? = null
)
```

**Settings Integration**:

HyDE is automatically used when embedding scoring is enabled. No separate toggle needed, but can show status:

```kotlin
// In session details or audit trail
if (session.hydeAbstract != null) {
    Surface(
        shape = RoundedCornerShape(4.dp),
        color = MaterialTheme.colorScheme.secondaryContainer
    ) {
        Row(
            modifier = Modifier.padding(horizontal = 8.dp, vertical = 4.dp),
            horizontalArrangement = Arrangement.spacedBy(4.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Icon(
                imageVector = Icons.Default.AutoAwesome,
                contentDescription = null,
                modifier = Modifier.size(16.dp)
            )
            Text(
                text = "HyDE Enhanced",
                style = MaterialTheme.typography.labelSmall
            )
        }
    }
}
```

**Benefits**:
- Better semantic matching between claims and scientific abstracts
- Particularly effective for vague or broad claims
- Low additional cost (one LLM call per session)
- Can be cached and reused for smart search alternatives

---

## Phase 4: Cloud Sync (P3)

### 4.1 Firebase/Cloud Sync Architecture

**Goal**: Cross-device session synchronization

**Location**: `app/src/main/java/com/bmlibrarian/factchecker/data/sync/`

**Options**:
1. **Firebase Firestore** - Real-time sync, offline support (recommended)
2. **Firebase Realtime Database** - Simpler, good for basic sync
3. **Custom backend** - More control, more work

**Recommended**: Firebase Firestore with offline persistence

### 4.1.1 Firebase Setup

**Dependencies**:

```kotlin
// In build.gradle.kts (app)
dependencies {
    // Firebase BOM for version management
    implementation(platform("com.google.firebase:firebase-bom:32.7.0"))

    // Firestore
    implementation("com.google.firebase:firebase-firestore-ktx")

    // Authentication
    implementation("com.google.firebase:firebase-auth-ktx")

    // Google Sign-In (optional)
    implementation("com.google.android.gms:play-services-auth:20.7.0")
}

// In build.gradle.kts (project)
plugins {
    id("com.google.gms.google-services") version "4.4.0" apply false
}
```

**Firebase Console Setup**:
1. Create Firebase project at console.firebase.google.com
2. Add Android app with package name
3. Download `google-services.json` to `app/` directory
4. Enable Firestore Database
5. Enable Authentication (Anonymous + Google)

### 4.1.2 Authentication Service

```kotlin
// AuthService.kt
@Singleton
class AuthService @Inject constructor(
    private val firebaseAuth: FirebaseAuth
) {
    private val _currentUser = MutableStateFlow<FirebaseUser?>(null)
    val currentUser: StateFlow<FirebaseUser?> = _currentUser

    val isSignedIn: Boolean
        get() = firebaseAuth.currentUser != null

    val userId: String?
        get() = firebaseAuth.currentUser?.uid

    init {
        firebaseAuth.addAuthStateListener { auth ->
            _currentUser.value = auth.currentUser
        }
    }

    /**
     * Sign in anonymously for device-only sync
     */
    suspend fun signInAnonymously(): Result<FirebaseUser> = runCatching {
        firebaseAuth.signInAnonymously().await().user
            ?: throw IllegalStateException("No user returned")
    }

    /**
     * Sign in with Google for cross-device sync
     */
    suspend fun signInWithGoogle(idToken: String): Result<FirebaseUser> = runCatching {
        val credential = GoogleAuthProvider.getCredential(idToken, null)
        firebaseAuth.signInWithCredential(credential).await().user
            ?: throw IllegalStateException("No user returned")
    }

    /**
     * Link anonymous account to Google account
     */
    suspend fun linkWithGoogle(idToken: String): Result<FirebaseUser> = runCatching {
        val credential = GoogleAuthProvider.getCredential(idToken, null)
        firebaseAuth.currentUser?.linkWithCredential(credential)?.await()?.user
            ?: throw IllegalStateException("No user returned")
    }

    fun signOut() {
        firebaseAuth.signOut()
    }
}
```

### 4.1.3 Firestore Data Model

```
users/{userId}/
├── profile/
│   └── {userId}
│       ├── email: String?
│       ├── displayName: String?
│       ├── createdAt: Timestamp
│       └── lastSyncedAt: Timestamp
│
├── sessions/{sessionId}
│   ├── id: String
│   ├── claim: String
│   ├── structuredQuery: Map  (JSON)
│   ├── createdAt: Timestamp
│   ├── updatedAt: Timestamp
│   ├── status: String
│   ├── verdict: String?
│   ├── smartSearchEnabled: Boolean
│   ├── alternativeQueries: String?  (JSON)
│   ├── hydeAbstract: String?
│   └── deviceId: String  (for conflict resolution)
│
├── documents/{documentId}
│   ├── id: String
│   ├── sessionId: String
│   ├── pmid: String?
│   ├── pmcId: String?
│   ├── doi: String?
│   ├── title: String
│   ├── abstractText: String?
│   ├── authors: List<String>
│   ├── journal: String?
│   ├── publicationYear: Int?
│   ├── source: String
│   ├── llmScore: Int?
│   ├── llmRationale: String?
│   ├── embeddingScore: Float?
│   ├── embeddingRelevance: Int?
│   ├── fullTextContent: String?
│   ├── fullTextSource: String?
│   ├── updatedAt: Timestamp
│   └── deviceId: String
│
├── reports/{reportId}
│   ├── id: String
│   ├── sessionId: String
│   ├── content: String  (markdown)
│   ├── verdict: String
│   ├── createdAt: Timestamp
│   └── deviceId: String
│
└── usage/{monthKey}  (e.g., "2024-01")
    ├── inputTokens: Long
    ├── outputTokens: Long
    ├── totalCost: Double
    └── updatedAt: Timestamp
```

### 4.1.4 Sync Service

```kotlin
// CloudSyncService.kt
@Singleton
class CloudSyncService @Inject constructor(
    private val firestore: FirebaseFirestore,
    private val authService: AuthService,
    private val sessionRepository: SessionRepository,
    private val documentRepository: DocumentRepository,
    private val reportRepository: ReportRepository,
    @ApplicationContext private val context: Context
) {
    private val deviceId = Settings.Secure.getString(
        context.contentResolver,
        Settings.Secure.ANDROID_ID
    )

    private var syncJob: Job? = null

    /**
     * Start real-time sync listener
     */
    fun startSync() {
        val userId = authService.userId ?: return

        syncJob?.cancel()
        syncJob = CoroutineScope(Dispatchers.IO).launch {
            // Listen for session changes
            listenForSessions(userId)
            // Listen for document changes
            listenForDocuments(userId)
            // Listen for report changes
            listenForReports(userId)
        }
    }

    fun stopSync() {
        syncJob?.cancel()
        syncJob = null
    }

    private suspend fun listenForSessions(userId: String) {
        firestore.collection("users").document(userId)
            .collection("sessions")
            .addSnapshotListener { snapshot, error ->
                if (error != null) {
                    Log.e("CloudSync", "Session sync error: ${error.message}")
                    return@addSnapshotListener
                }

                snapshot?.documentChanges?.forEach { change ->
                    when (change.type) {
                        DocumentChange.Type.ADDED,
                        DocumentChange.Type.MODIFIED -> {
                            val remoteSession = change.document.toObject(SessionCloud::class.java)
                            handleRemoteSessionChange(remoteSession)
                        }
                        DocumentChange.Type.REMOVED -> {
                            // Handle deletion if needed
                        }
                    }
                }
            }
    }

    private fun handleRemoteSessionChange(remoteSession: SessionCloud) {
        CoroutineScope(Dispatchers.IO).launch {
            val localSession = sessionRepository.getById(remoteSession.id)

            if (localSession == null) {
                // New session from another device
                sessionRepository.insert(remoteSession.toEntity())
            } else if (remoteSession.updatedAt > localSession.updatedAt) {
                // Remote is newer, update local
                if (remoteSession.deviceId != deviceId) {
                    sessionRepository.update(remoteSession.toEntity())
                }
            }
            // If local is newer, uploadSession will handle it
        }
    }

    /**
     * Upload local session to cloud
     */
    suspend fun uploadSession(session: SessionEntity) {
        val userId = authService.userId ?: return

        val cloudSession = SessionCloud.fromEntity(session, deviceId)

        firestore.collection("users").document(userId)
            .collection("sessions")
            .document(session.id)
            .set(cloudSession)
            .await()
    }

    /**
     * Upload local document to cloud
     */
    suspend fun uploadDocument(document: DocumentEntity) {
        val userId = authService.userId ?: return

        val cloudDoc = DocumentCloud.fromEntity(document, deviceId)

        firestore.collection("users").document(userId)
            .collection("documents")
            .document(document.id)
            .set(cloudDoc)
            .await()
    }

    /**
     * Sync all local data to cloud
     */
    suspend fun syncAllToCloud() {
        val userId = authService.userId ?: return

        // Upload all sessions
        sessionRepository.getAll().forEach { session ->
            uploadSession(session)
        }

        // Upload all documents
        documentRepository.getAll().forEach { document ->
            uploadDocument(document)
        }

        // Upload all reports
        reportRepository.getAll().forEach { report ->
            uploadReport(report)
        }

        // Update last sync timestamp
        updateLastSyncedAt(userId)
    }

    /**
     * Fetch all data from cloud to local
     */
    suspend fun syncAllFromCloud() {
        val userId = authService.userId ?: return

        // Fetch sessions
        val sessionsSnapshot = firestore.collection("users").document(userId)
            .collection("sessions")
            .get()
            .await()

        sessionsSnapshot.documents.forEach { doc ->
            val cloudSession = doc.toObject(SessionCloud::class.java) ?: return@forEach
            val localSession = sessionRepository.getById(cloudSession.id)

            if (localSession == null || cloudSession.updatedAt > localSession.updatedAt) {
                sessionRepository.insertOrUpdate(cloudSession.toEntity())
            }
        }

        // Similar for documents and reports...
    }

    private suspend fun updateLastSyncedAt(userId: String) {
        firestore.collection("users").document(userId)
            .collection("profile").document(userId)
            .update("lastSyncedAt", FieldValue.serverTimestamp())
            .await()
    }
}

// Cloud data classes
data class SessionCloud(
    val id: String = "",
    val claim: String = "",
    val structuredQuery: Map<String, Any>? = null,
    val createdAt: Timestamp = Timestamp.now(),
    val updatedAt: Timestamp = Timestamp.now(),
    val status: String = "",
    val verdict: String? = null,
    val smartSearchEnabled: Boolean = false,
    val alternativeQueries: String? = null,
    val hydeAbstract: String? = null,
    val deviceId: String = ""
) {
    fun toEntity(): SessionEntity = SessionEntity(
        id = id,
        claim = claim,
        // ... map other fields
        updatedAt = updatedAt.toDate().time
    )

    companion object {
        fun fromEntity(entity: SessionEntity, deviceId: String): SessionCloud = SessionCloud(
            id = entity.id,
            claim = entity.claim,
            // ... map other fields
            deviceId = deviceId,
            updatedAt = Timestamp(Date(entity.updatedAt))
        )
    }
}
```

### 4.1.5 Settings Integration

```kotlin
// In SettingsScreen.kt
@Composable
fun CloudSyncSection(
    viewModel: SettingsViewModel = hiltViewModel()
) {
    val cloudSyncEnabled by viewModel.cloudSyncEnabled.collectAsState()
    val isSignedIn by viewModel.isSignedIn.collectAsState()
    val syncStatus by viewModel.syncStatus.collectAsState()

    Card(
        modifier = Modifier
            .fillMaxWidth()
            .padding(16.dp)
    ) {
        Column(modifier = Modifier.padding(16.dp)) {
            Text(
                text = "Cloud Sync",
                style = MaterialTheme.typography.titleMedium,
                fontWeight = FontWeight.Bold
            )

            Spacer(modifier = Modifier.height(8.dp))

            // Privacy warning
            if (!cloudSyncEnabled) {
                Surface(
                    color = MaterialTheme.colorScheme.errorContainer,
                    shape = RoundedCornerShape(8.dp)
                ) {
                    Row(
                        modifier = Modifier.padding(12.dp),
                        horizontalArrangement = Arrangement.spacedBy(8.dp)
                    ) {
                        Icon(
                            imageVector = Icons.Default.Info,
                            contentDescription = null,
                            tint = MaterialTheme.colorScheme.error
                        )
                        Text(
                            text = "Enabling sync will upload your sessions, documents, and reports to Google Cloud. Your data will be associated with your Google account.",
                            style = MaterialTheme.typography.bodySmall
                        )
                    }
                }
                Spacer(modifier = Modifier.height(12.dp))
            }

            // Sync toggle
            SwitchSettingsItem(
                icon = Icons.Default.CloudSync,
                title = "Enable Cloud Sync",
                description = if (isSignedIn) "Signed in" else "Sign in to sync",
                checked = cloudSyncEnabled,
                onCheckedChange = { enabled ->
                    if (enabled && !isSignedIn) {
                        viewModel.startGoogleSignIn()
                    } else {
                        viewModel.setCloudSyncEnabled(enabled)
                    }
                }
            )

            // Sync status
            if (cloudSyncEnabled) {
                Spacer(modifier = Modifier.height(8.dp))

                Row(
                    verticalAlignment = Alignment.CenterVertically,
                    horizontalArrangement = Arrangement.spacedBy(8.dp)
                ) {
                    when (syncStatus) {
                        SyncStatus.Syncing -> {
                            CircularProgressIndicator(modifier = Modifier.size(16.dp))
                            Text("Syncing...", style = MaterialTheme.typography.bodySmall)
                        }
                        SyncStatus.Synced -> {
                            Icon(
                                imageVector = Icons.Default.Check,
                                contentDescription = null,
                                tint = Color(0xFF4CAF50),
                                modifier = Modifier.size(16.dp)
                            )
                            Text("Up to date", style = MaterialTheme.typography.bodySmall)
                        }
                        SyncStatus.Error -> {
                            Icon(
                                imageVector = Icons.Default.Error,
                                contentDescription = null,
                                tint = MaterialTheme.colorScheme.error,
                                modifier = Modifier.size(16.dp)
                            )
                            Text("Sync failed", style = MaterialTheme.typography.bodySmall)
                        }
                        else -> {}
                    }
                }

                // Manual sync button
                Spacer(modifier = Modifier.height(8.dp))
                OutlinedButton(
                    onClick = { viewModel.triggerManualSync() }
                ) {
                    Icon(Icons.Default.Refresh, contentDescription = null)
                    Spacer(modifier = Modifier.width(8.dp))
                    Text("Sync Now")
                }
            }
        }
    }
}

enum class SyncStatus {
    Idle, Syncing, Synced, Error
}
```

### 4.1.6 Repository Integration

Modify repositories to trigger sync on changes:

```kotlin
// SessionRepository.kt
class SessionRepository @Inject constructor(
    private val sessionDao: SessionDao,
    private val cloudSyncService: CloudSyncService,
    private val settingsRepository: SettingsRepository
) {
    suspend fun insert(session: SessionEntity) {
        sessionDao.insert(session)

        // Trigger cloud sync if enabled
        if (settingsRepository.isCloudSyncEnabled()) {
            cloudSyncService.uploadSession(session)
        }
    }

    suspend fun update(session: SessionEntity) {
        val updated = session.copy(updatedAt = System.currentTimeMillis())
        sessionDao.update(updated)

        if (settingsRepository.isCloudSyncEnabled()) {
            cloudSyncService.uploadSession(updated)
        }
    }
}
```

### 4.1.7 Conflict Resolution

```kotlin
// ConflictResolver.kt
object ConflictResolver {
    /**
     * Resolve conflicts using last-write-wins strategy
     * with deviceId as tiebreaker
     */
    fun <T : Syncable> resolve(local: T, remote: T): T {
        return when {
            local.updatedAt > remote.updatedAt -> local
            remote.updatedAt > local.updatedAt -> remote
            // Same timestamp, use deviceId as tiebreaker
            local.deviceId > remote.deviceId -> local
            else -> remote
        }
    }
}

interface Syncable {
    val updatedAt: Long
    val deviceId: String
}
```

### 4.1.8 Firestore Security Rules

```javascript
// firestore.rules
rules_version = '2';
service cloud.firestore {
  match /databases/{database}/documents {
    // Users can only access their own data
    match /users/{userId}/{document=**} {
      allow read, write: if request.auth != null && request.auth.uid == userId;
    }
  }
}
```

### 4.1.9 Privacy Considerations

- **Data Minimization**: Only sync essential data, not API keys
- **Encryption**: Firestore uses encryption at rest and in transit
- **User Control**: Clear "Delete My Data" option
- **Transparency**: Show exactly what will be synced
- **Anonymous Option**: Allow sync without Google account (device-only)

---

## Implementation Order and Dependencies

```
Phase 1 (Critical - Full-Text Support)
├── 1.1 JATS XML Parser
│   └── 1.3 Full-Text Retrieval Service (depends on parser)
│       └── 1.2 Full-Text Viewer Screen (depends on retrieval)
├── 1.4 Database Schema Updates (parallel)
└── 1.5 Navigation Integration (depends on 1.2)
    ├── 1.5.1-1.5.2 Navigation Routes
    ├── 1.5.3-1.5.4 DocumentCard & FactCheckScreen
    ├── 1.5.5 DocumentDetailSheet Enhancement
    └── 1.5.6 FullTextSourceBadge

Phase 2 (User Experience)
├── 2.1 Onboarding System (independent, 9 pages)
│   ├── OnboardingPage data model
│   ├── OnboardingScreen with HorizontalPager
│   └── OnboardingViewModel with DataStore
├── 2.2 Disclaimer Screen (independent, shown first)
│   ├── DisclaimerPoint model (4 points)
│   ├── DisclaimerScreen UI
│   └── DisclaimerViewModel with DataStore
├── 2.3 Help Documentation (independent)
│   ├── MarkdownViewer component (Markwon)
│   ├── HelpScreen loading from assets
│   └── HELP.md content file
└── 2.4 Smart Search (depends on workflow)
    ├── AlternativeQuery models
    ├── GenerateAlternativeQueriesUseCase
    ├── Workflow integration with decision dialog
    └── Session entity updates

Phase 3 (Advanced Scoring)
├── 3.1 On-Device Embeddings (independent)
│   ├── EmbeddingService with TFLite
│   ├── Constants (thresholds matching iOS)
│   ├── ScoreBadge component (dual scores)
│   └── Settings toggle
└── 3.2 HyDE Generation (depends on 3.1)
    ├── HydeGenerator class
    ├── Workflow integration
    └── Session entity updates

Phase 4 (Cloud Sync)
└── 4.1 Firebase/Firestore (independent but complex)
    ├── 4.1.1 Firebase setup & dependencies
    ├── 4.1.2 AuthService (Google + Anonymous)
    ├── 4.1.3 Firestore data model
    ├── 4.1.4 CloudSyncService
    ├── 4.1.5 Settings UI integration
    ├── 4.1.6 Repository integration
    ├── 4.1.7 Conflict resolution
    ├── 4.1.8 Security rules
    └── 4.1.9 Privacy considerations
```

**Recommended Implementation Sequence**:

1. **Week 1-2**: Phase 1 (Full-Text) + Phase 2.1-2.2 (Onboarding/Disclaimer)
2. **Week 3**: Phase 2.3-2.4 (Help/Smart Search)
3. **Week 4**: Phase 3 (Embeddings + HyDE)
4. **Week 5+**: Phase 4 (Cloud Sync - can be deferred)

---

## File Structure for New Features

```
app/src/main/java/com/bmlibrarian/factchecker/
├── data/
│   ├── local/
│   │   ├── entity/
│   │   │   ├── SessionEntity.kt      # + smart search, HyDE fields
│   │   │   └── DocumentEntity.kt     # + full-text, embedding fields
│   │   └── dao/
│   │       └── ...
│   ├── remote/
│   │   └── fulltext/
│   │       ├── FullTextService.kt
│   │       └── UnpaywallApi.kt
│   └── sync/                          # Phase 4: Cloud Sync
│       ├── AuthService.kt
│       ├── CloudSyncService.kt
│       ├── ConflictResolver.kt
│       └── models/
│           ├── SessionCloud.kt
│           ├── DocumentCloud.kt
│           └── ReportCloud.kt
│
├── domain/
│   ├── model/
│   │   ├── AlternativeQuery.kt
│   │   └── QueryConcept.kt
│   └── usecase/
│       ├── FetchFullTextUseCase.kt
│       └── GenerateAlternativeQueriesUseCase.kt
│
├── ml/
│   ├── EmbeddingService.kt
│   ├── EmbeddingConstants.kt
│   └── HydeGenerator.kt
│
├── ui/
│   ├── navigation/
│   │   ├── NavRoutes.kt              # + FullTextViewer route
│   │   └── AppNavigation.kt          # + fulltext composable
│   │
│   ├── fulltext/
│   │   ├── FullTextViewerScreen.kt
│   │   ├── FullTextViewModel.kt
│   │   └── components/
│   │       ├── HtmlContentView.kt
│   │       ├── MarkdownContentView.kt
│   │       ├── PdfViewer.kt
│   │       └── FullTextSourceBadge.kt
│   │
│   ├── factcheck/
│   │   └── components/
│   │       ├── DocumentCard.kt       # + onViewFullText callback
│   │       └── ScoreBadge.kt         # + dual score support
│   │
│   ├── onboarding/
│   │   ├── OnboardingScreen.kt
│   │   ├── OnboardingPageView.kt
│   │   ├── OnboardingViewModel.kt
│   │   └── OnboardingPages.kt        # 9-page definitions
│   │
│   ├── disclaimer/
│   │   ├── DisclaimerScreen.kt
│   │   ├── DisclaimerPointRow.kt
│   │   ├── DisclaimerViewModel.kt
│   │   └── DisclaimerPoints.kt       # 4-point definitions
│   │
│   ├── help/
│   │   ├── HelpScreen.kt
│   │   ├── PrivacyScreen.kt
│   │   └── MarkdownViewer.kt
│   │
│   ├── settings/
│   │   └── components/
│   │       └── CloudSyncSection.kt   # Phase 4
│   │
│   └── common/
│       └── AppRoot.kt                # Disclaimer → Onboarding → App flow
│
└── util/
    ├── jats/
    │   ├── JATSXMLParser.kt
    │   └── JATSModels.kt
    └── Constants.kt                   # + embedding thresholds, smart search

app/src/main/assets/
├── help/
│   ├── HELP.md
│   └── PRIVACY.md
└── universal_sentence_encoder.tflite  # ~25MB TFLite model

app/src/main/res/
└── values/
    └── strings.xml                    # Onboarding & disclaimer text
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
