# BMLibrarian Lite v0.3.0 Release Notes

## Highlights

This is a major release with extensive cross-platform expansion. BMLibrarian Lite now runs natively on **iOS**, **macOS**, and **Android** alongside the existing Python desktop app. The Python package gains a new **Study Transparency Analyzer**, **Europe PMC** as an alternative search provider, and **risk warning integration** in generated reports.

## Major Features

### Study Transparency Analyzer

- Analyze biomedical studies for transparency indicators (funding disclosure, conflict of interest, data availability, pre-registration, etc.)
- Pure-function analyzers for funding sources, trial compliance, and transparency scoring
- CrossRef and ClinicalTrials.gov service integration for external validation
- TransparencyAnalysisService with comprehensive test coverage
- Risk badges displayed on document cards in the systematic review workflow

### Risk Warnings in Reports

- Reports now include risk warnings based on transparency analysis results
- Configurable risk warning settings per transparency dimension
- Risk warning helper functions integrated into the report generation pipeline

### Europe PMC Search Provider

- Added Europe PMC as an alternative to PubMed for literature search
- Cursor-based pagination support for Europe PMC results
- Provider-specific query syntax translation
- Search result merging and deduplication across providers (PMID/DOI/PMC/title)

### Full-Text Discovery and Viewing

- Europe PMC XML full-text retrieval
- Unpaywall integration for open-access PDF discovery
- JATS XML parsing to HTML/Markdown with table, figure, and reference support
- Manual full-text upload button for documents behind paywalls
- Full-text viewer with clickable figure/table references and anchor navigation

### iOS and macOS Native Apps

- Full-featured SwiftUI apps for iOS and macOS
- SwiftData persistence with iCloud sync support
- NLEmbedding for on-device semantic similarity scoring
- OpenAI-compatible API integration (Anthropic, Ollama, Mistral, etc.)
- Parallel document scoring with checkpointing and cancellation
- Resume-from-history: continue previous searches with incremental pagination
- Comprehensive onboarding flow with API key guidance
- PDF export with paper size selection
- Background processing support
- BioMedLit shared Swift package for cross-platform code reuse

### Android Native App

- Full Kotlin/Compose implementation with Material Design 3
- Room database with Hilt dependency injection
- PubMed, Europe PMC, LLM, and Unpaywall API services
- JATS XML full-text viewer matching iOS display quality
- History restoration and resume search functionality
- Dynamic model fetching from API providers
- Cross-platform sync foundation
- Collapsible query display and structured abstract formatting

## Improvements

### Search and Query

- StructuredQuery intermediate format for provider-agnostic searches
- Smart search mode with HyDE (Hypothetical Document Embeddings)
- Improved query translation handling multi-word unquoted terms
- Search deduplication across multiple providers
- Collapsible query display across all platforms

### Report Generation

- Clickable citation references grouped by document
- Markdown rendering with proper block elements
- Improved prompts for balanced evidence synthesis
- Disclaimer and model info footnotes in reports

### Cross-Platform Sync

- BioMedLit shared Swift package with JATS parsing, services, and utilities
- SyncEngine with selective sync and session eviction management
- iCloud and local folder sync support
- Cross-platform sync foundation for Android

### UI/UX

- DPI-aware scaling across the desktop GUI
- Lazy tab loading to prevent startup layout errors
- Improved human review UX with clickable titles and larger abstract fonts
- Score badges and quality indicators in audit trail

## Bug Fixes

- Fixed silent "Get Full Text" failure on Android
- Fixed broken figure display in Android full-text viewer
- Fixed PubMed XML parser losing text with embedded formatting tags
- Fixed year displayed with thousands separator (2,022 instead of 2022)
- Fixed JSON parsing for nested LLM responses
- Fixed cursor passing and UI for resumed session pagination
- Fixed Europe PMC hitCount parsing (Int not String)
- Fixed JATS XML parser losing text around inline elements
- Fixed SwiftData enum persistence issues
- Fixed scoring JSON parsing failures on macOS
- Fixed various magic numbers replaced with named constants

## Breaking Changes

- License changed from GPL-3.0 to AGPL-3.0
- Python package now requires `tenacity` and `backoff` for retry logic

## Technical Notes

- Hatchling build system (unchanged)
- `set_version.py` script updates all version locations
- FastEmbed for CPU-optimized embeddings (no PyTorch required)
- sqlite-vec for vector similarity search

## Upgrade Instructions

1. Back up your `~/.bmlibrarian_lite/` directory
2. Install the new version: `pip install --upgrade bmlibrarian-lite`
3. Existing databases are compatible; no migration required for the Python app

---

**Full Changelog**: https://github.com/hherb/bmlibrarian_lite/compare/0.2.0...0.3.0
