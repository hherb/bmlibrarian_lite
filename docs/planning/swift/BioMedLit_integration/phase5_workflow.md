# Phase 5: FactCheckWorkflow Updates

## Objective

Update the iOS `FactCheckWorkflow` to match the macOS version's improved search workflow, user decision flow, smart search integration, and deduplication.

## Files to Modify

- `ios/MedicalFactChecker/Sources/Services/FactCheckWorkflow.swift`

## Major Changes Overview

1. **User Decision Flow**: Always prompt user after scoring (don't auto-continue)
2. **Smart Search as Explicit Choice**: Offer smart search in decision prompt
3. **Improved Deduplication**: Check PMID, DOI, and PMC ID
4. **Cursor Pagination**: Track Europe PMC cursor in session
5. **Structured Query Storage**: Store parsed StructuredQuery for provider translation

## Detailed Changes

### 1. Add New Properties

Add these properties to `FactCheckWorkflow`:

```swift
// MARK: - Properties

/// The structured query parsed from LLM response.
///
/// Stored in memory (not persisted) so we can rebuild provider-specific
/// queries during the workflow.
private var structuredQuery: StructuredQuery?

/// Whether we're specifically waiting for smart search decision.
@Published var awaitingSmartSearchDecision: Bool = false

/// Callback when user needs to decide on smart search.
///
/// Called when no relevant documents found and smart search hasn't been tried.
/// The completion handler should be called with `true` to try smart search,
/// or `false` to proceed with current results.
var onAskSmartSearch: ((String, @escaping (Bool) -> Void) -> Void)?
```

### 2. Update Query Conversion Step

Change `convertClaimToQuery()` to parse and store the structured query:

```swift
/// Convert the user's claim to a structured query.
private func convertClaimToQuery(claim: String) async throws {
    guard let session = session else { return }

    session.currentStep = .convertingQuery
    progressMessage = "Converting claim to search query..."

    // Call LLM to get structured query JSON
    let llmResponse = try await llmService.generateStructuredQuery(claim: claim)

    // Parse the structured query
    guard let query = StructuredQuery.parse(from: llmResponse) else {
        throw FactCheckError.queryGenerationFailed("Failed to parse structured query from LLM response")
    }

    // Store for later use
    self.structuredQuery = query

    // Build provider-specific query string
    let provider = session.searchProvider ?? .pubmed
    let queryString = QueryBuilderFactory.build(from: query, for: provider)

    session.pubmedQuery = queryString
}
```

### 3. Update Search Step with Cursor Support

Modify `searchForDocuments()` to use cursor-based pagination:

```swift
/// Search for documents using the current query.
private func searchForDocuments() async throws {
    guard let session = session else { return }

    session.currentStep = .searchingPubMed
    progressMessage = "Searching for documents..."

    // Build search options
    let options = SearchOptions(
        provider: session.searchProvider ?? .pubmed,
        includePreprints: session.includePreprints,
        maxResults: settings.batchSize,
        offset: session.currentSearchOffset,
        cursorMark: nil  // Initial search has no cursor
    )

    // Use the stored structured query to build provider-specific query
    let queryString: String
    if let structuredQuery = self.structuredQuery {
        queryString = QueryBuilderFactory.build(from: structuredQuery, for: options.provider)
    } else if let storedQuery = session.pubmedQuery {
        // Fallback for resumed sessions
        queryString = storedQuery
    } else {
        throw FactCheckError.queryGenerationFailed("No query available")
    }

    // Execute search
    let result = try await SearchServiceFactory.search(
        query: queryString,
        options: options,
        settings: settings,
        cursor: session.europePMCCursor
    )

    // Store pagination state
    session.totalPubMedResults = result.totalCount
    session.currentSearchOffset = result.nextOffset

    // Update cursor for Europe PMC
    if result.provider == .europePMC || result.provider == .both {
        session.europePMCCursor = result.nextCursorMark
        session.europePMCHasMore = result.nextCursorMark != nil
    }
    if result.provider == .pubmed || result.provider == .both {
        session.pubmedHasMore = result.hasMore
    }

    // Process and deduplicate articles
    let newArticles = deduplicateArticles(result.articles, session: session)

    // Create Document models from articles
    for article in newArticles {
        let document = Document(from: article)
        document.session = session
        session.documents?.append(document)
        modelContext.insert(document)
    }

    session.documentsFound = (session.documents?.count ?? 0)
    session.batchesFetched += 1
}
```

### 4. Add Improved Deduplication

Replace or update the deduplication logic:

```swift
/// Deduplicate articles against already-fetched documents.
///
/// Checks PMID, DOI, and PMC ID to avoid duplicates across providers.
///
/// - Parameters:
///   - articles: Newly fetched articles.
///   - session: Current session with existing documents.
/// - Returns: Articles that are not duplicates.
private func deduplicateArticles(
    _ articles: [ArticleMetadata],
    session: FactCheckSession
) -> [ArticleMetadata] {
    let existingDocs = session.documents ?? []

    // Build sets of existing identifiers
    let existingPmids = Set(existingDocs.compactMap { $0.pmid })
    let existingDois = Set(existingDocs.compactMap { $0.doi?.lowercased() })
    let existingPmcIds = Set(existingDocs.compactMap { $0.pmcId })

    return articles.filter { article in
        // Check PMID
        if let pmid = article.pmid, existingPmids.contains(pmid) {
            return false
        }

        // Check DOI (case-insensitive)
        if let doi = article.doi?.lowercased(), existingDois.contains(doi) {
            return false
        }

        // Check PMC ID
        if let pmcId = article.pmcId, existingPmcIds.contains(pmcId) {
            return false
        }

        return true
    }
}
```

### 5. Update User Decision Logic

Change the decision flow to always prompt (never auto-continue):

```swift
/// Determine if user input is needed and present options.
private func checkUserDecision() async {
    guard let session = session else { return }

    let relevantCount = session.relevantDocuments.count
    let hasMoreDocs = session.canFetchMoreFromAnyProvider
    let smartSearchAvailable = !session.smartSearchEnabled

    // Always ask user after scoring, regardless of results
    if relevantCount == 0 {
        // No relevant documents - offer smart search if available
        if smartSearchAvailable {
            awaitingSmartSearchDecision = true
            awaitingUserDecision = true
            userDecisionPrompt = "No relevant documents found. Would you like to try alternative search queries (Smart Search) or proceed with generating a report?"
        } else if hasMoreDocs {
            awaitingUserDecision = true
            userDecisionPrompt = "No relevant documents found. Would you like to fetch more documents or proceed with generating a report?"
        } else {
            // Nothing more we can do - proceed to report
            await proceedWithCurrentDocuments()
        }
    } else if relevantCount < settings.minimumRelevantDocuments {
        // Some relevant but below threshold
        if hasMoreDocs {
            awaitingUserDecision = true
            userDecisionPrompt = "Found \(relevantCount) relevant document(s). Would you like to search for more or proceed with what we have?"
        } else if smartSearchAvailable {
            awaitingSmartSearchDecision = true
            awaitingUserDecision = true
            userDecisionPrompt = "Found \(relevantCount) relevant document(s), but no more available. Try Smart Search for alternative queries or proceed with current results?"
        } else {
            await proceedWithCurrentDocuments()
        }
    } else {
        // Sufficient relevant documents - always ask before continuing
        awaitingUserDecision = true
        userDecisionPrompt = "Found \(relevantCount) relevant documents. Proceed to citation extraction or search for more evidence?"
    }
}
```

### 6. Add Smart Search Methods

Add the smart search workflow methods:

```swift
/// Continue workflow with smart search (alternative queries).
@MainActor
public func continueWithSmartSearch() async {
    guard let session = session else { return }

    awaitingUserDecision = false
    awaitingSmartSearchDecision = false

    do {
        session.smartSearchEnabled = true
        session.currentStep = .fetchingMoreEvidence
        progressMessage = "Generating alternative search queries..."

        // Generate alternative queries using LLM
        let alternativeQueries = try await generateAlternativeQueries(for: session.claim)

        if alternativeQueries.isEmpty {
            // No alternatives generated - proceed with current docs
            progressMessage = "No alternative queries generated"
            await proceedWithCurrentDocuments()
            return
        }

        // Store alternatives in session
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(alternativeQueries.map { $0.concepts }),
           let jsonString = String(data: data, encoding: .utf8) {
            session.alternativeQueries = jsonString
        }

        // Search with first alternative query
        session.currentAlternativeQueryIndex = 0
        if let firstQuery = alternativeQueries.first {
            self.structuredQuery = firstQuery
            try await searchForDocuments()
            try await scoreDocuments()
            await checkUserDecision()
        }

    } catch {
        handleError(error)
    }
}

/// Generate alternative structured queries for smart search.
private func generateAlternativeQueries(for claim: String) async throws -> [StructuredQuery] {
    let llmResponse = try await llmService.generateAlternativeQueries(claim: claim)
    return ResponseParser.parseStructuredQueryArray(llmResponse)
}
```

### 7. Update continueWithMoreDocuments

Update to use proper pagination:

```swift
/// Continue workflow by fetching more documents.
@MainActor
public func continueWithMoreDocuments() async {
    guard let session = session else { return }

    awaitingUserDecision = false
    awaitingSmartSearchDecision = false

    do {
        session.currentStep = .fetchingMoreEvidence
        progressMessage = "Fetching more documents..."

        // Search will use existing offset/cursor from session
        try await searchForDocuments()
        try await scoreDocuments()
        await checkUserDecision()

    } catch {
        handleError(error)
    }
}
```

## LLM Service Updates

The `LLMService` may need new methods for structured query generation. Add if not present:

```swift
/// Generate a structured query JSON from a medical claim.
func generateStructuredQuery(claim: String) async throws -> String {
    let prompt = """
    Convert this medical claim into a structured search query for biomedical databases.

    Claim: \(claim)

    Return a JSON object with this exact structure:
    {
      "concepts": [
        {"name": "concept name", "mesh_terms": ["MeSH Term 1"], "keywords": ["keyword1", "keyword2"]}
      ]
    }

    Each concept should be a distinct facet of the search (e.g., drug, condition, outcome).
    MeSH terms are standardized medical vocabulary. Keywords are free-text alternatives.
    """

    return try await sendMessage(prompt)
}

/// Generate alternative structured queries for smart search.
func generateAlternativeQueries(claim: String) async throws -> String {
    let prompt = """
    The original search for this medical claim didn't find enough relevant results:

    Claim: \(claim)

    Generate 2-3 alternative search strategies as an array of structured queries.
    Try different angles: broader terms, narrower terms, related concepts, synonyms.

    Return a JSON array:
    [
      {"concepts": [{"name": "...", "mesh_terms": ["..."], "keywords": ["..."]}]},
      {"concepts": [...]}
    ]
    """

    return try await sendMessage(prompt)
}
```

## Validation Steps

1. Build iOS project - no compilation errors
2. Test full workflow:
   - Enter claim -> generates structured query
   - Search executes with correct provider
   - Documents deduplicated properly
   - User always prompted after scoring
   - Smart search works when selected
   - Pagination with cursor works for Europe PMC
3. Test resuming a session:
   - Cursor properly restored for Europe PMC
   - Offset properly restored for PubMed
   - Deduplication works across resume

## Reference Files

- macOS version: `macos/MedicalFactCheckerMac/Sources/Services/FactCheckWorkflow.swift` (full file, ~800 lines)
