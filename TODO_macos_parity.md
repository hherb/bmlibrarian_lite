# macOS / iOS Feature Parity TODO

Comprehensive parity review comparing `macos/MedicalFactCheckerMac/` and `ios/MedicalFactChecker/`.

## Critical Issues (Functional Bugs)

- [x] **1. iOS `hasFullText` missing `fullTextHTML` check** — `Document.swift` returns `false` when only HTML content is available (no `fullTextContent`), causing documents to appear as having no full text.
- [x] **2. iOS `applyFullTextResult` discards markdown** — The `.html` case sets `fullTextContent = nil`, losing the markdown fallback. macOS stores both HTML and markdown.
- [x] **3. macOS CheckpointManager is dead code** — The file exists but `FactCheckWorkflow` never instantiates it. Scoring is NOT resumable on macOS; if the app quits mid-scoring, all progress is lost.
- [x] **4. `cancelFactCheck` sets opposite state** — iOS sets `awaitingUserDecision = true` (allowing resume). macOS sets it to `false` (silent stop with no resume prompt).

## High-Priority Gaps

- [x] **5. iOS SearchResultMerger is weaker** — iOS only checks a single dedup key. macOS has multi-key tracking (PMID+DOI+PMC), title cross-checking, and PMC ID matching. iOS can miss duplicates when searching "Both" providers.
- [x] **6. iOS CloudKit migration has no fallback** — macOS has 3 fallback strategies (staged → lightweight → delete+recreate). iOS tries once and fails hard on schema migration errors.
- [x] **7. iOS `FullTextSource` types diverge** — iOS `.html` case stores only HTML string. macOS stores both HTML and markdown. macOS has `canDisplayInApp`, factory methods, and `Equatable` conformance that iOS lacks.
- [x] **8. macOS `restoreForViewing` doesn't load persisted errors** — When revisiting a historical session, Phase 4 errors from the original run are not shown.
- [x] **9. macOS ProgressDelegate lacks `didScoreDocument`** — iOS can update the UI incrementally as each document is scored. macOS cannot.

## Medium-Priority: macOS has, iOS lacks

- [x] **10. Dedicated Full Text tab** — Standalone document browser with filtering (With Full Text / Pending / All Scored). Added to iOS.
- [x] **11. History search/filter** — Text field to search past sessions by claim text. iOS now has `.searchable()` with filtering.
- [x] **12. History detail pane** — Split-view with comprehensive session stats (scored count, relevant, tokens, duration). Added to iOS with NavigationSplitView.
- [x] **13. Copy to Clipboard for reports** — Direct clipboard action for report text. Added to iOS share menus.
- [ ] **14. Print reports** — `NSPrintOperation` support (macOS-only, platform-appropriate).
- [x] **15. Show/Hide API Key toggle** — Eye button to reveal/hide key in settings. Added to iOS.
- [x] **16. Structured OSLog logging** — `Logger.swift` with category-specific loggers. Added to iOS matching macOS AppLogger.
- [x] **17. `fullTextSourceDisplay` handles `"cached"` case** — iOS switch is missing this case.
- [ ] **18. `SchemaV0` migration** — macOS can handle pre-versioning databases. iOS cannot.
- [x] **19. `onAskSmartSearch` callback** — Both platforms use shared FactCheckWorkflow which prompts user with smart search option.

## Medium-Priority: iOS has, macOS lacks

- [x] **20. `maxConcurrentRequests` setting** — User-configurable concurrency for parallel LLM requests. Added to macOS AppSettings and Settings UI.
- [x] **21. Detailed Model Pricing table** — `ModelPricingView` with per-model input/output costs. Added to macOS Budget settings tab.
- [x] **22. PDF paper size selection** — A4 vs Letter picker for report export. Added to macOS export menu, uses `PDFExporter.preferredPaperSize`.
- [x] **23. Error badge on tab** — Configuration warning in macOS sidebar when API key is missing.
- [x] **24. Manual JSON fallback in query building** — Shared FactCheckWorkflow has `buildQueryFromJSON`, `extractJSONFromResponse`, `buildQueryFromConcepts` fallbacks for both platforms.

## Architectural Divergence (Consolidation into BioMedLit Package)

- [x] **25. Move SearchResultMerger into BioMedLit** — Package version upgraded with multi-key dedup (alt keys, PMC ID, title matching during merge, minWordLength filter). App copies remain as thin wrappers for app-local types.
- [x] **26. Move QueryBuilder/QueryTranslator into BioMedLit** — Package version now has exclude-list pub types, date range, `buildAll()`, conditional quoting. macOS local copy replaced with re-export. QueryTranslator was already re-exported.
- [x] **27. Move PromptTemplates/ResponseParser into BioMedLit** — PromptTemplates moved to package; both app copies replaced with re-exports. ResponseParser was already re-exported.
- [x] **28. Move ReportFormatter into BioMedLit** — Moved to package; both app copies replaced with re-exports.
- [x] **29. Move CostCalculator/BudgetChecker into BioMedLit** — Moved to package with `providerName: String?` parameter (decoupled from app-local `LLMProvider`). App copies provide convenience overloads accepting `LLMProvider?`.
- [x] **30. Unify SearchOptions struct** — macOS is missing `cursorMark` and `defaults(for:)`. iOS is missing `maxResults`/`offset` in restore.
- [x] **31. Unify FullTextSource enum** — Align cases, add `canDisplayInApp`, factory methods, `Equatable`, `Sendable`.
- [x] **32. Remove iOS local JATSXMLParser.swift** — Duplicates BioMedLit package JATS parsing. Replaced with re-export.
- [ ] **33. Unify BioMedLitAdapters** — iOS and macOS use different adapter types (`ArticleMetadata` vs `UnifiedArticleMetadata`).

## Low-Priority / Cosmetic

- [x] **34. iOS PDFExporter uses magic numbers** — macOS uses `MacPDFLayout` constants. iOS hardcodes page dimensions. Added `PDFLayout` constants enum.
- [x] **35. Disclaimer content differs** — Both platforms now have "No Self-Treatment" and "Your Privacy" points.
- [x] **36. `[weak self]` in Task closures** — Fixed in shared FactCheckWorkflow. All Task closures now use [weak self].
- [x] **37. Copyright years inconsistent** — All files updated to `2024-2026`.
- [ ] **38. Property naming inconsistency** — iOS: `currentSearchOptions` / macOS: `searchOptions`. iOS: `searchOptions:` param / macOS: `overrideSearchOptions:`.
- [x] **39. `EvidenceReport.generationFootnote` logic differs** — iOS uses live session data with Ollama "(Local)" suffix. macOS uses stored report statistics. Now aligned.
- [ ] **40. Documentation density differs** — iOS has thorough doc comments on `ErrorPersistenceManager`; macOS has minimal.
