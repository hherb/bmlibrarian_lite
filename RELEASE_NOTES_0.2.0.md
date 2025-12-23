# BMLibrarian Lite v0.2.0 Release Notes

## Highlights

This release introduces **multi-model benchmarking** for both relevance scoring and quality assessment, a **unified SQLite storage layer** replacing ChromaDB, and a new **Research Questions tab** for managing and re-running past searches.

## Major Features

### Multi-Model Benchmarking

- **Relevance Score Benchmarking**: Compare how different LLM models score document relevance
  - Side-by-side model comparison with agreement matrices
  - Score distribution analysis across models
  - Per-document score comparison with disagreement highlighting
  - Cost and latency tracking per model
  - Export results to CSV/JSON

- **Quality Assessment Benchmarking** (NEW): Compare study design classification across models
  - Two task types: Study Classification (fast) and Detailed Assessment (comprehensive)
  - Design agreement matrix showing classification consistency
  - Tier agreement matrix for quality tier comparison
  - Design distribution visualization per model
  - Document-level comparison with disagreement indicators

### Research Questions Tab

- View and manage all past research questions
- Re-run searches with incremental PubMed pagination
- Automatic deduplication of already-scored documents
- Context menu actions: Re-classify, Re-score, Delete
- Run benchmarks directly from saved questions

### Unified SQLite Storage

- **Replaced ChromaDB with sqlite-vec** for vector similarity search
- Single SQLite database for all metadata and embeddings
- Improved startup performance and reduced dependencies
- Automatic migration from previous ChromaDB-based storage
- New `question_documents` pivot table for document-question tracking

## Improvements

### Benchmark Workflow

- Benchmark results now display in dedicated main window tabs (not modal dialogs)
- Cross-run score reuse: Reuses scores from previous benchmarks of the same question
- Baseline model score reuse: Avoids re-evaluating documents with baseline model
- Inclusion agreement metrics added to benchmark results
- Gold standard document selection in document review dialog

### UI Enhancements

- PDF viewer integrated into document viewer
- Report versioning with methodology metadata section
- Improved audit trail with quality badges and score indicators
- Better error handling with retry logic for LLM API calls

### Bug Fixes

- Fixed TypeError when clicking Add Model button in benchmark settings
- Fixed benchmark checkpoint_id NOT NULL constraint error
- Fixed scored documents query issues
- Fixed duplicate search issues in benchmark workflow
- Standardized color constants across UI components

## Breaking Changes

- ChromaDB dependency removed - existing ChromaDB data will need to be re-indexed
- Database schema updated with new tables for benchmarking and question tracking

## Technical Notes

- Added `sqlite-vec` for CPU-optimized vector similarity search
- New benchmarking module with runner, statistics, and data models
- Improved error handling with `EvaluationErrorCode` enum
- Tenacity-based retry logic for LLM API resilience
- Version management script (`scripts/set_version.py`) for release automation

## Upgrade Instructions

1. Back up your `~/.bmlibrarian_lite/` directory
2. Install the new version
3. On first launch, existing documents will be re-indexed automatically
4. Previous ChromaDB data is no longer used and can be safely deleted

---

**Full Changelog**: https://github.com/hherb/bmlibrarian_lite/compare/0.1.1...0.2.0
