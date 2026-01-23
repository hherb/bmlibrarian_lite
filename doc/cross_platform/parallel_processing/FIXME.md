# FIXME: Cross-Platform Issues to Review

Issues found during iOS/Swift review that may also apply to Android and Python implementations.

## Critical Issues

### 1. ScoringResult Type Conflict (Phase 1 vs Phase 2)

**Problem**: Phase 1 defines a `ScoringResult` type for active processing (holds full document reference), while Phase 2 redefines it as a Codable type for checkpointing (holds only essential data).

**Platforms to check**:
- [ ] Android/Kotlin: Check if `ScoringResult` in Phase 1 conflicts with Phase 2
- [ ] Python: Check if `ParallelScoringResult` vs checkpoint data structures conflict

**Fix applied in Swift**: Renamed Phase 2's type to `ScoringCheckpoint` for persistence, keeping `ScoringResult` for active processing.

---

### 2. LLM Service API Signature Inconsistency

**Problem**: Different phases show different return types for the scoring API:
- Phase 1 & 3: Returns tuple `(score, rationale)`
- Phase 2: Returns result object directly

**Platforms to check**:
- [ ] Android/Kotlin: Verify `scoringRepository.scoreDocument()` return type is consistent
- [ ] Python: Verify `LiteScoringAgent.score_document()` return type matches across phases

**Fix applied in Swift**: Standardized on tuple return `(score: Int, rationale: String)`.

---

### 3. Document ID (PMID) Optionality Handling

**Problem**: Some code assumes `document.pmid` is non-optional, other code uses nil-coalescing.

**Platforms to check**:
- [ ] Android/Kotlin: Check if `Document.pmid` is nullable and handled consistently
- [ ] Python: Check if `LiteDocument.pmid` can be None and is handled consistently

**Fix applied in Swift**: Consistently use `doc.pmid ?? ""` and filter out documents with nil PMIDs before processing.

---

## Logic Issues

### 4. Inefficient Checkpoint Loading Loop

**Problem**: Phase 2 iterates through ALL documents to find checkpointed ones, instead of only iterating checkpointed PMIDs.

**Platforms to check**:
- [ ] Android/Kotlin: Check `scoreDocuments()` in `CheckpointedScoringUseCase`
- [ ] Python: Check `score_documents_with_checkpointing()` loop logic

**Fix applied in Swift**: Changed to iterate only documents whose PMIDs are in the checkpointed set.

---

### 5. Checkpoint Data Structure Inconsistency Between Phases

**Problem**: Phase 3's checkpoint struct may have different fields than Phase 2's, causing incompatibility when resuming sessions.

**Platforms to check**:
- [ ] Android/Kotlin: Verify `ScoringCheckpoint` fields match between Phase 2 and Phase 3
- [ ] Python: Verify checkpoint dict keys are consistent across phases

**Fix applied in Swift**: Phase 3's `ScoringCheckpoint` now matches Phase 2 with all fields (pmid, score, rationale, isError, errorMessage).

---

## Documentation Issues

### 6. Service Naming Progression Unclear

**Problem**: Phase 1 → 2 → 3 each introduce new service classes (`ParallelScoringService` → `CheckpointedScoringService` → `CancellableScoringService`) but don't clarify if they replace each other or coexist.

**Platforms to check**:
- [ ] All: Add note clarifying that Phase 3's service is the final implementation that includes all features (parallel, checkpointing, cancellation)

---

### 7. Progress Callback Pattern Inconsistency

**Problem**: Phase 1 and 3 use simple callbacks `(pmid, current, total) -> Void`, while Phase 2 introduces a delegate protocol with `ProgressMessage` objects.

**Platforms to check**:
- [ ] All: Decide on one pattern and document it consistently
- [ ] Python: Uses `ProgressSignals` (Qt) vs callback - verify consistency

---

## Completed Fixes (Swift)

- [x] Fixed `Codable` as parameter type → use generic `<T: Codable>`
- [x] Added `ScoringCheckpoint` separate from `ScoringResult`
- [x] Fixed predicate variable capturing for SwiftData
- [x] Added missing `import SwiftData` in tests
- [x] Fixed checkpoint loading to only iterate checkpointed documents
- [x] Added type definitions to Phase 3 (was missing `ScoringResult`)
- [x] Standardized `llmService.scoreDocument(_:claim:)` API signature
- [x] Fixed Phase 3 `ScoringCheckpoint` to match Phase 2's definition (added pmid, isError, errorMessage fields)
