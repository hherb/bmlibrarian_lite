# Changelog

All notable changes to BMLibrarian Lite are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

Versions cover the Python desktop package published to PyPI. Changes to the
iOS/macOS and Android apps are noted where they ship in the same release; those
apps additionally carry their own store version tags (`swift_*`, `appstore_*`).

## [Unreleased]

### Added

- `scripts/set_version.py` now updates the `**Current version:**` line in
  `CLAUDE.md` and promotes the `CHANGELOG.md` `[Unreleased]` section into a
  dated release section, rewriting the compare links. Pass `--skip-changelog`
  to bump versions without touching the changelog.
- Test coverage for `scripts/set_version.py` (`tests/test_set_version.py`).

### Fixed

- **iOS/macOS/Android: DeepSeek model list stopped syncing.** DeepSeek retired
  the `deepseek-chat` / `deepseek-reasoner` IDs in July 2026 in favour of
  `deepseek-v4-flash` / `deepseek-v4-pro`; all three apps whitelisted the old
  IDs exactly, so every model the API returned was filtered out and the picker
  silently fell back to two retired models. The filter now excludes non-chat
  families instead of whitelisting IDs, fallback models and pricing cover V4,
  and a successful fetch replaces a stored model the provider no longer offers
  (hand-typed names for Ollama and custom endpoints are left alone).
- **iOS/macOS/Android: DeepSeek V4 no longer reasons on every call.** V4 replaced
  the V3 chat/reasoner split with a `thinking` parameter that defaults to
  *enabled*, so scoring and citation calls spent output tokens on chain-of-thought
  and had their `temperature` silently ignored. All three apps now send
  `{"thinking": {"type": "disabled"}}` to DeepSeek, and the iOS/macOS connection
  test sends the same options as a real call.
- **iOS/macOS: model fetch failures are no longer silent.** `ModelFetchService`
  propagates errors instead of substituting hardcoded models, so Settings shows
  the real reason (including the HTTP status) rather than a generic notice.

## [0.4.0] - 2026-07-19

### Added

- **MCP server** (`bmlibrarian-lite-mcp`) exposing BMLibrarian Lite as an expert
  medical fact-checker to any MCP client, with progress notifications during
  `fact_check_claim`.
- **Parallel scoring and citation extraction** against cloud APIs, on desktop,
  iOS/macOS, and Android.
- **Europe PMC PDF** added to the full-text discovery fallback chain on all
  platforms, ahead of the Unpaywall and DOI fallbacks.
- **Study transparency analysis** extended across platforms: multi-pass
  conflict-of-interest analysis, full-text support, and effective-refusal
  detection. iOS/macOS gained a transparency detail view, risk badge, and
  summary section; Android gained a byte-parity data-availability classifier
  (`DataAvailabilityAnalyzer`, `DataRepositoryPatterns`, `RegexHelper`).
- **Cross-platform transparency parity guard** pinning Python, Swift, and Kotlin
  to a shared contract, with drift diagnostics.
- **Android smart search** with alternative query generation.

### Changed

- The standalone macOS app is retired in favor of the multiplatform Xcode
  project; Xcode Cloud archiving is fixed and guarded by CI.
- Combined ("Both") search mode reports its total as an explicit lower bound
  rather than an exact count, and drops abstract-less articles.
- `RegexHelper` is Unicode-aware and caches compiled patterns.

### Fixed

- Scoring: a missing `"score"` key is treated as a parse failure instead of
  silently scoring 1.
- PDF: sniffed bytes are preserved, so downloaded PDFs are no longer corrupted.
- Quality: true median sample size for even-sized sets; study types matched by
  evidence priority rather than dict order.
- LLM: thinking tags stripped from reasoning-model output; the actual quality
  model is reported.
- Storage: helpful error when Python lacks SQLite extension support; new
  question-document links counted via `cursor.rowcount`.
- Errors: status-code-less `APIError` classified by message, not as a connection
  failure.
- Transparency open-data precision: negation scope bounded, `no` / `neither…nor`
  negated affirmations caught, short repository tokens word-anchored, and
  refusal signals now override a co-occurring repository mention.
- Android: `EuropePmcPdf` branch handled in view models; missing
  `UI_CARD_CORNER_RADIUS` constant restored; PubMed XML parsing made
  unit-testable.

### Security

- Dependency updates including cryptography 48.0.1, urllib3 2.7.0,
  python-multipart 0.0.31, starlette 1.3.1, pyjwt 2.13.0, idna 3.15,
  pillow 12.2.0, and mcp 1.28.1.

## [0.3.0] - 2026-02-10

Cross-platform expansion release. Full detail in
[RELEASE_NOTES_0.3.0.md](RELEASE_NOTES_0.3.0.md).

### Added

- **Native iOS and macOS apps** (SwiftUI, SwiftData, iCloud sync, NLEmbedding
  on-device scoring, parallel scoring with checkpointing) and a **native Android
  app** (Kotlin/Compose, Room, Hilt).
- **BioMedLit** shared Swift package: JATS parsing, Europe PMC/PubMed/full-text
  services, transparency analysis, and sync engine.
- **Study Transparency Analyzer**: funding, conflict-of-interest, data
  availability, and trial-compliance analyzers with CrossRef and
  ClinicalTrials.gov integration; risk badges on document cards.
- **Risk warnings in reports**, configurable per transparency dimension.
- **Europe PMC** as an alternative search provider, with cursor pagination and
  cross-provider deduplication (PMID/DOI/PMC/title).
- Full-text discovery and viewing: Europe PMC XML, Unpaywall PDFs, JATS →
  HTML/Markdown rendering, and manual upload for paywalled documents.
- Smart search mode using HyDE (Hypothetical Document Embeddings).

### Changed

- **License changed from GPL-3.0 to AGPL-3.0.**
- Searches go through a provider-agnostic `StructuredQuery` intermediate format.
- Reports gained clickable citations grouped by document, plus disclaimer and
  model-info footnotes.

### Fixed

- PubMed and JATS XML parsers no longer lose text around embedded formatting and
  inline elements.
- Year no longer rendered with a thousands separator (`2,022`).
- SwiftData enum persistence, resumed-session pagination cursors, and Europe PMC
  `hitCount` parsed as `Int`.

## [0.2.0] - 2025-12-23

Benchmarking and storage release. Full detail in
[RELEASE_NOTES_0.2.0.md](RELEASE_NOTES_0.2.0.md).

### Added

- **Multi-model benchmarking** for relevance scoring and quality assessment,
  with agreement matrices, score distributions, cost/latency tracking, and
  CSV/JSON export.
- **Research Questions tab**: manage past questions, re-run searches with
  incremental pagination, and re-classify/re-score/delete via context menu.
- `question_documents` pivot table for document-question tracking.
- Report versioning with a methodology metadata section.
- `scripts/set_version.py` for release version management.

### Changed

- **Replaced ChromaDB with sqlite-vec**, unifying metadata and embeddings in a
  single SQLite database.
- Benchmark results render in main-window tabs rather than modal dialogs.
- Scores are reused across benchmark runs of the same question.

### Removed

- ChromaDB dependency. Existing ChromaDB data is unused and can be deleted;
  documents are re-indexed on first launch.

## [0.1.1] - 2025-12-18

First published release.

### Added

- PyPI packaging with `bmll` / `bmlibrarian-lite` CLI entry points and a macOS
  DMG build.
- Audit Trail tab with collapsible document cards and LLM rationale display.
- Europe PMC full-text XML retrieval and caching.
- Task-based model configuration with a dynamic model selector and a provider
  base class for LLM backends.
- PDF discovery and download.

### Changed

- License set to GPL-3.0.

### Fixed

- `QThread` destroyed-while-running crash, resolved by deferring cleanup with
  `QTimer`.
- Ollama model listing using object attributes rather than dict access.

[Unreleased]: https://github.com/hherb/bmlibrarian_lite/compare/0.4.0...HEAD
[0.4.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.3.0...0.4.0
[0.3.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.2.0...0.3.0
[0.2.0]: https://github.com/hherb/bmlibrarian_lite/compare/0.1.1...0.2.0
[0.1.1]: https://github.com/hherb/bmlibrarian_lite/releases/tag/0.1.1
