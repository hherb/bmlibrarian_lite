# Parallel Scoring & Citation Extraction

**Date:** 2026-04-03
**Status:** Approved

## Problem

Scoring and citation extraction process documents sequentially. For cloud APIs (Anthropic, OpenAI-compatible), this wastes time since the API can handle concurrent requests. A 20-document run at ~3s per call takes ~120s; with 4 workers it drops to ~30s.

## Design

### Constants (`constants.py`)

```python
PARALLEL_WORKERS_OLLAMA_DEFAULT = 1
PARALLEL_WORKERS_CLOUD_DEFAULT = 4
```

### Config (`config.py`)

New `ParallelProcessingConfig` dataclass:

```python
@dataclass
class ParallelProcessingConfig:
    scoring_workers: int = 0     # 0 = auto-detect from provider
    citation_workers: int = 0    # 0 = auto-detect from provider
```

Auto-detect: resolve the provider for the task (`document_scoring` / `citation_extraction`). If provider is `"ollama"` -> use `PARALLEL_WORKERS_OLLAMA_DEFAULT` (1), otherwise -> `PARALLEL_WORKERS_CLOUD_DEFAULT` (4).

Add `parallel: ParallelProcessingConfig` field to `LiteConfig`. Serialize/deserialize with the rest of the config JSON.

### Agent changes

**`ScoringAgent.score_documents()`** and **`CitationAgent.extract_all_citations()`** gain an optional `max_workers: int = 1` parameter.

When `max_workers == 1`: current sequential loop (no behavior change).

When `max_workers > 1`: use `concurrent.futures.ThreadPoolExecutor` with sliding-window pattern:

```python
from concurrent.futures import ThreadPoolExecutor, as_completed

with ThreadPoolExecutor(max_workers=max_workers) as executor:
    futures = {
        executor.submit(self.score_document, question, doc): i
        for i, doc in enumerate(documents)
    }
    for future in as_completed(futures):
        completed += 1
        if progress_callback:
            progress_callback(completed, total)
        result = future.result()
        # collect result...
```

Results are sorted after all complete (scoring: by score desc; citations: accumulated in order).

### Thread safety

- Agents are stateless: `score_document()` and `extract_citations()` build independent messages per call
- `LLMClient` uses `httpx` which is thread-safe for separate requests
- Progress callback counter uses `threading.Lock` for atomic increment
- No shared mutable state between concurrent document processing calls

### Callers

**MCP server** (`_handle_fact_check`): resolve `max_workers` from `LiteConfig.parallel` before calling agents. Pass it through.

**GUI workflow**: same resolution. The progress bar total (`2 + 2N`) stays the same; only wall-clock time changes.

### What does NOT change

- `score_document()` / `extract_citations()` single-document methods
- `@llm_retry` decorator and retry logic
- Error handling (negative scores for scoring failures, empty lists for citation failures)
- Progress callback signature `(current, total)`
- MCP progress notification protocol

### Settings UI

The existing settings dialog gets two spinboxes for "Scoring workers" and "Citation workers" (min 1, max 10, default 0=auto). Placed in the LLM/Model settings section.
