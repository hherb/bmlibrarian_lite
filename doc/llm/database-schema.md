# BMLibrarian Lite Database Schema

This document describes the database schema used by BMLibrarian Lite for LLM context.

## Overview

BMLibrarian Lite uses a dual-storage architecture:
- **ChromaDB**: Vector database for embeddings and semantic search
- **SQLite**: Relational database for structured metadata and sessions

All data is stored in `~/.bmlibrarian_lite/` by default.

## ChromaDB Collections

### `lite_documents`

Stores document metadata and abstracts with vector embeddings.

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique document ID (e.g., `pmid-12345678`) |
| `document` | string | Document abstract text (embedded) |
| `title` | string | Document title |
| `authors` | JSON string | List of author names |
| `year` | integer | Publication year (0 if unknown) |
| `journal` | string | Journal name |
| `doi` | string | Digital Object Identifier |
| `pmid` | string | PubMed ID |
| `pmc_id` | string | PubMed Central ID |
| `url` | string | Document URL |
| `mesh_terms` | JSON string | List of MeSH terms |
| `source` | string | Document source (`pubmed`, `manual`, `pdf`) |

### `lite_chunks`

Stores document chunks for interrogation with vector embeddings.

| Field | Type | Description |
|-------|------|-------------|
| `id` | string | Unique chunk ID |
| `document` | string | Chunk text content (embedded) |
| `document_id` | string | Parent document ID |
| `chunk_index` | integer | Position in document |
| `start_char` | integer | Starting character offset |
| `end_char` | integer | Ending character offset |

## SQLite Tables

### `search_sessions`

Records PubMed searches for history and reproducibility.

```sql
CREATE TABLE search_sessions (
    id TEXT PRIMARY KEY,
    query TEXT NOT NULL,                    -- PubMed query string
    natural_language_query TEXT NOT NULL,   -- Original user question
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    document_count INTEGER DEFAULT 0,       -- Number of results
    metadata TEXT DEFAULT '{}'              -- JSON metadata
);
```

### `review_checkpoints`

Tracks systematic review workflow progress.

```sql
CREATE TABLE review_checkpoints (
    id TEXT PRIMARY KEY,
    research_question TEXT NOT NULL,        -- User's research question
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    step TEXT DEFAULT 'start',              -- Workflow step
    search_session_id TEXT,                 -- FK to search_sessions
    report TEXT,                            -- Generated report text
    metadata TEXT DEFAULT '{}',             -- JSON metadata
    FOREIGN KEY (search_session_id) REFERENCES search_sessions(id)
);
```

Workflow steps: `start` → `search` → `scoring` → `citation` → `report` → `complete`

### `scored_documents`

Stores document relevance scores from the scoring agent.

```sql
CREATE TABLE scored_documents (
    id TEXT PRIMARY KEY,
    checkpoint_id TEXT NOT NULL,            -- FK to review_checkpoints
    document_id TEXT NOT NULL,              -- Reference to ChromaDB document
    score INTEGER NOT NULL CHECK (score BETWEEN 1 AND 5),
    explanation TEXT,                       -- LLM's scoring rationale
    scored_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id)
);
```

Score meanings:
- 5: Highly relevant, directly addresses the question
- 4: Relevant, provides useful supporting evidence
- 3: Moderately relevant, tangentially related
- 2: Low relevance, limited applicability
- 1: Not relevant

### `citations`

Stores extracted citations from documents.

```sql
CREATE TABLE citations (
    id TEXT PRIMARY KEY,
    checkpoint_id TEXT NOT NULL,            -- FK to review_checkpoints
    document_id TEXT NOT NULL,              -- Reference to ChromaDB document
    passage TEXT NOT NULL,                  -- Extracted citation text
    relevance_score INTEGER,                -- Citation relevance (1-5)
    context TEXT,                           -- LLM's rationale for selection
    FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id)
);
```

### `interrogation_sessions`

Tracks document Q&A sessions.

```sql
CREATE TABLE interrogation_sessions (
    id TEXT PRIMARY KEY,
    document_id TEXT NOT NULL,              -- Document being interrogated
    document_title TEXT NOT NULL,           -- Document title
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    messages TEXT DEFAULT '[]',             -- JSON array of Q&A messages
    metadata TEXT DEFAULT '{}'              -- JSON metadata
);
```

Message format in `messages` array:
```json
[
    {"role": "user", "content": "What methods were used?"},
    {"role": "assistant", "content": "The study used..."}
]
```

### `pubmed_cache`

Caches PubMed API responses to reduce API calls.

```sql
CREATE TABLE pubmed_cache (
    query_hash TEXT PRIMARY KEY,            -- Hash of query parameters
    response TEXT NOT NULL,                 -- Cached JSON response
    created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
    expires_at TIMESTAMP NOT NULL           -- Cache expiration time
);
```

Default TTL: 3600 seconds (1 hour)

### `user_settings`

Stores user preferences and settings.

```sql
CREATE TABLE user_settings (
    key TEXT PRIMARY KEY,
    value TEXT NOT NULL,                    -- JSON value
    updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
);
```

## Indexes

```sql
CREATE INDEX idx_search_sessions_created ON search_sessions(created_at);
CREATE INDEX idx_checkpoints_updated ON review_checkpoints(updated_at);
CREATE INDEX idx_scored_docs_checkpoint ON scored_documents(checkpoint_id);
CREATE INDEX idx_citations_checkpoint ON citations(checkpoint_id);
CREATE INDEX idx_pubmed_cache_expires ON pubmed_cache(expires_at);
CREATE INDEX idx_interrogation_sessions_created ON interrogation_sessions(created_at);
```

## Data Models (Python)

The following dataclasses in `data_models.py` correspond to the database schema:

### `LiteDocument`

```python
@dataclass
class LiteDocument:
    id: str
    title: str
    abstract: str
    authors: list[str] = field(default_factory=list)
    year: Optional[int] = None
    journal: Optional[str] = None
    doi: Optional[str] = None
    pmid: Optional[str] = None
    pmc_id: Optional[str] = None
    url: Optional[str] = None
    mesh_terms: list[str] = field(default_factory=list)
    source: DocumentSource = DocumentSource.PUBMED
    metadata: dict[str, Any] = field(default_factory=dict)
```

### `SearchSession`

```python
@dataclass
class SearchSession:
    id: str
    query: str
    natural_language_query: str
    created_at: datetime
    document_count: int = 0
    metadata: dict[str, Any] = field(default_factory=dict)
```

### `ReviewCheckpoint`

```python
@dataclass
class ReviewCheckpoint:
    id: str
    research_question: str
    created_at: datetime
    updated_at: datetime
    step: str = "start"
    search_session_id: Optional[str] = None
    report: Optional[str] = None
    metadata: dict[str, Any] = field(default_factory=dict)
```

### `ScoredDocument`

```python
@dataclass
class ScoredDocument:
    document: LiteDocument
    score: int  # 1-5
    explanation: str = ""
```

### `Citation`

```python
@dataclass
class Citation:
    document: LiteDocument
    passage: str
    relevance_score: int = 0
    context: str = ""
    assessment: Optional[QualityAssessment] = None
```

## Storage API Usage

```python
from bmlibrarian_lite import LiteConfig
from bmlibrarian_lite.storage import LiteStorage

config = LiteConfig.load()
storage = LiteStorage(config)

# Add document
storage.add_document(doc, embedding_function=embed_fn)

# Search documents (semantic)
results = storage.search_documents("query", n_results=20, embedding_function=embed_fn)

# Create search session
session = storage.create_search_session(
    query="diabetes[MeSH]",
    natural_language_query="How is diabetes treated?",
    document_count=42
)

# Create review checkpoint
checkpoint = storage.create_checkpoint(
    research_question="What are the effects of exercise?"
)

# Get statistics
stats = storage.get_statistics()
# Returns: {"documents": N, "chunks": N, "search_sessions": N, "checkpoints": N}
```

## File Locations

| Component | Default Path |
|-----------|--------------|
| ChromaDB | `~/.bmlibrarian_lite/chroma/` |
| SQLite | `~/.bmlibrarian_lite/metadata.db` |
| Config | `~/.bmlibrarian_lite/config.json` |
| PDFs | `~/.bmlibrarian_lite/pdfs/` |
| Fulltexts | `~/.bmlibrarian_lite/fulltexts/` |
