"""
Unified storage layer for BMLibrarian Lite.

Uses SQLite for all structured data and sqlite-vec for vector search.
All data is persisted to the configured data directory.

Usage:
    from bmlibrarian_lite import LiteConfig
    from bmlibrarian_lite.storage import LiteStorage

    config = LiteConfig.load()
    storage = LiteStorage(config)

    # Add documents
    storage.add_document(doc, embedding_function=embed_fn)

    # Search by semantic similarity
    results = storage.search_documents("query", embedding_function=embed_fn)
"""

import hashlib
import json
import logging
import sqlite3
import struct
import uuid
from contextlib import contextmanager
from datetime import datetime
from typing import Any, Generator, Optional

import sqlite_vec

from .config import LiteConfig
from .constants import (
    BENCHMARK_QUESTION_HASH_LENGTH,
    DEFAULT_EMBEDDING_DIMENSIONS,
    PUBMED_CACHE_TTL_SECONDS,
)
from .data_models import (
    BenchmarkRun,
    BenchmarkStatus,
    DocumentSource,
    Evaluator,
    EvaluatorType,
    LiteChunk,
    LiteDocument,
    ResearchQuestionSummary,
    ReviewCheckpoint,
    SearchSession,
    ScoredDocument,
)
from .exceptions import SQLiteError, LiteStorageError

logger = logging.getLogger(__name__)


def compute_question_hash(question: str) -> str:
    """
    Compute deterministic hash for research question lookup.

    Normalizes the question text (lowercase, whitespace-collapsed)
    before hashing to handle minor variations.

    Args:
        question: Research question text

    Returns:
        Hex hash string of length BENCHMARK_QUESTION_HASH_LENGTH

    Raises:
        ValueError: If question is empty or None
    """
    if not question or not question.strip():
        raise ValueError("Question cannot be empty")
    normalized = " ".join(question.lower().strip().split())
    return hashlib.sha256(normalized.encode()).hexdigest()[:BENCHMARK_QUESTION_HASH_LENGTH]


class LiteStorage:
    """
    Unified storage layer for BMLibrarian Lite.

    Provides:
    - SQLite database for all structured data (documents, sessions, checkpoints)
    - sqlite-vec extension for vector search
    - Unified API for all storage operations

    All data is persisted to ~/.bmlibrarian_lite/ by default.
    """

    def __init__(self, config: Optional[LiteConfig] = None) -> None:
        """
        Initialize storage layer.

        Args:
            config: Configuration object. If None, uses defaults.
        """
        self.config = config or LiteConfig()
        self._storage_config = self.config.storage

        # Ensure directories exist
        self.config.ensure_directories()

        # Initialize SQLite with sqlite-vec extension
        self._init_sqlite()

        logger.info(f"LiteStorage initialized at {self._storage_config.data_dir}")

    def _init_sqlite(self) -> None:
        """
        Initialize SQLite database with schema and sqlite-vec extension.

        Raises:
            SQLiteError: If SQLite initialization fails
        """
        try:
            with self._sqlite_connection() as conn:
                conn.executescript(self._get_sqlite_schema())
                # Create sqlite-vec virtual tables for document and chunk embeddings
                conn.execute(
                    f"""
                    CREATE VIRTUAL TABLE IF NOT EXISTS vec_documents USING vec0(
                        embedding float[{DEFAULT_EMBEDDING_DIMENSIONS}]
                    )
                    """
                )
                conn.execute(
                    f"""
                    CREATE VIRTUAL TABLE IF NOT EXISTS vec_chunks USING vec0(
                        embedding float[{DEFAULT_EMBEDDING_DIMENSIONS}]
                    )
                    """
                )
                conn.commit()
            # Run migrations for existing data
            self._migrate_benchmark_question_hashes()
            self._migrate_scored_documents_constraint()
            logger.debug(f"SQLite initialized at {self._storage_config.sqlite_path}")
        except sqlite3.Error as e:
            raise SQLiteError(
                f"Failed to initialize SQLite at {self._storage_config.sqlite_path}: {e}"
            ) from e

    def _migrate_benchmark_question_hashes(self) -> None:
        """
        Backfill question_hash for existing benchmark_runs.

        This migration runs on startup and populates the question_hash
        column for any existing runs that don't have one. Also creates
        the index on question_hash.
        """
        try:
            with self._sqlite_connection() as conn:
                # Check if the column exists (handle old schema)
                cursor = conn.execute("PRAGMA table_info(benchmark_runs)")
                columns = [row["name"] for row in cursor.fetchall()]
                if "question_hash" not in columns:
                    conn.execute(
                        "ALTER TABLE benchmark_runs ADD COLUMN question_hash TEXT"
                    )
                    conn.commit()
                    logger.info("Added question_hash column to benchmark_runs table")

                # Create index on question_hash (safe to run multiple times)
                conn.execute(
                    """
                    CREATE INDEX IF NOT EXISTS idx_benchmark_runs_question_hash
                        ON benchmark_runs(question_hash)
                    """
                )
                conn.commit()

                # Backfill hashes for existing runs
                cursor = conn.execute(
                    "SELECT id, question FROM benchmark_runs WHERE question_hash IS NULL"
                )
                rows = cursor.fetchall()
                if rows:
                    for row in rows:
                        question_hash = compute_question_hash(row["question"])
                        conn.execute(
                            "UPDATE benchmark_runs SET question_hash = ? WHERE id = ?",
                            (question_hash, row["id"]),
                        )
                    conn.commit()
                    logger.info(
                        f"Backfilled question_hash for {len(rows)} existing benchmark runs"
                    )
        except sqlite3.Error as e:
            logger.warning(f"Failed to migrate benchmark question hashes: {e}")

    def _migrate_scored_documents_constraint(self) -> None:
        """
        Migrate scored_documents table to allow negative error codes.

        The original CHECK constraint was `score BETWEEN 1 AND 5` which
        prevented storing error codes (negative values). This migration
        recreates the table with the new constraint `score BETWEEN -100 AND 5`.
        """
        try:
            with self._sqlite_connection() as conn:
                # Check if migration is needed by examining table SQL
                cursor = conn.execute(
                    "SELECT sql FROM sqlite_master "
                    "WHERE type='table' AND name='scored_documents'"
                )
                row = cursor.fetchone()
                if row is None:
                    # Table doesn't exist yet, will be created with new schema
                    return

                table_sql = row["sql"]
                # Check if old constraint exists
                if "score BETWEEN 1 AND 5" not in table_sql:
                    # Already migrated or different constraint
                    return

                logger.info(
                    "Migrating scored_documents table to allow negative error codes"
                )

                # Recreate table with new constraint (SQLite table rebuild)
                conn.execute("ALTER TABLE scored_documents RENAME TO _scored_documents_old")
                conn.execute(
                    """
                    CREATE TABLE scored_documents (
                        id TEXT PRIMARY KEY,
                        checkpoint_id TEXT NOT NULL,
                        document_id TEXT NOT NULL,
                        score INTEGER NOT NULL CHECK (score BETWEEN -100 AND 5),
                        explanation TEXT,
                        evaluator_id TEXT,
                        latency_ms INTEGER,
                        tokens_input INTEGER,
                        tokens_output INTEGER,
                        cost_usd REAL,
                        scored_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                        FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id),
                        FOREIGN KEY (evaluator_id) REFERENCES evaluators(id)
                    )
                    """
                )
                # Copy existing data
                conn.execute(
                    """
                    INSERT INTO scored_documents
                    SELECT * FROM _scored_documents_old
                    """
                )
                # Drop old table
                conn.execute("DROP TABLE _scored_documents_old")
                conn.commit()
                logger.info("Successfully migrated scored_documents table")

        except sqlite3.Error as e:
            logger.warning(f"Failed to migrate scored_documents constraint: {e}")

    @contextmanager
    def _sqlite_connection(self) -> Generator[sqlite3.Connection, None, None]:
        """
        Context manager for SQLite connections with sqlite-vec extension.

        Yields:
            SQLite connection with Row factory and sqlite-vec loaded
        """
        conn = sqlite3.connect(
            self._storage_config.sqlite_path,
            detect_types=sqlite3.PARSE_DECLTYPES | sqlite3.PARSE_COLNAMES,
        )
        conn.row_factory = sqlite3.Row
        # Enable extension loading and load sqlite-vec
        conn.enable_load_extension(True)
        sqlite_vec.load(conn)
        conn.enable_load_extension(False)
        try:
            yield conn
        finally:
            conn.close()

    def _get_sqlite_schema(self) -> str:
        """
        Return SQLite schema definition.

        Uses CREATE IF NOT EXISTS for idempotency.

        Returns:
            SQL schema string
        """
        return """
        -- Documents (authoritative source for document metadata)
        CREATE TABLE IF NOT EXISTS documents (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL,
            abstract TEXT,
            authors TEXT,  -- JSON array
            year INTEGER,
            journal TEXT,
            doi TEXT,
            pmid TEXT,
            pmc_id TEXT,
            url TEXT,
            mesh_terms TEXT,  -- JSON array
            source TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        -- Search sessions
        CREATE TABLE IF NOT EXISTS search_sessions (
            id TEXT PRIMARY KEY,
            query TEXT NOT NULL,
            natural_language_query TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            document_count INTEGER DEFAULT 0,
            metadata TEXT DEFAULT '{}'
        );

        -- Review checkpoints
        CREATE TABLE IF NOT EXISTS review_checkpoints (
            id TEXT PRIMARY KEY,
            research_question TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            step TEXT DEFAULT 'start',
            search_session_id TEXT,
            report TEXT,
            metadata TEXT DEFAULT '{}',
            FOREIGN KEY (search_session_id) REFERENCES search_sessions(id)
        );

        -- Evaluators (models or humans that produce evaluations)
        CREATE TABLE IF NOT EXISTS evaluators (
            id TEXT PRIMARY KEY,
            type TEXT NOT NULL CHECK (type IN ('model', 'human')),
            display_name TEXT NOT NULL,
            provider TEXT,
            model_name TEXT,
            temperature REAL,
            max_tokens INTEGER,
            top_p REAL,
            top_k INTEGER,
            human_name TEXT,
            human_email TEXT,
            description TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        -- Scored documents (linked to checkpoints and evaluators)
        CREATE TABLE IF NOT EXISTS scored_documents (
            id TEXT PRIMARY KEY,
            checkpoint_id TEXT NOT NULL,
            document_id TEXT NOT NULL,
            score INTEGER NOT NULL CHECK (score BETWEEN -100 AND 5),
            explanation TEXT,
            evaluator_id TEXT,
            latency_ms INTEGER,
            tokens_input INTEGER,
            tokens_output INTEGER,
            cost_usd REAL,
            scored_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id),
            FOREIGN KEY (evaluator_id) REFERENCES evaluators(id)
        );

        -- Citations (linked to checkpoints)
        CREATE TABLE IF NOT EXISTS citations (
            id TEXT PRIMARY KEY,
            checkpoint_id TEXT NOT NULL,
            document_id TEXT NOT NULL,
            passage TEXT NOT NULL,
            relevance_score INTEGER,
            context TEXT,
            FOREIGN KEY (checkpoint_id) REFERENCES review_checkpoints(id)
        );

        -- User settings
        CREATE TABLE IF NOT EXISTS user_settings (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL,
            updated_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
        );

        -- PubMed cache
        CREATE TABLE IF NOT EXISTS pubmed_cache (
            query_hash TEXT PRIMARY KEY,
            response TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            expires_at TIMESTAMP NOT NULL
        );

        -- Interrogation sessions
        CREATE TABLE IF NOT EXISTS interrogation_sessions (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            document_title TEXT NOT NULL,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            messages TEXT DEFAULT '[]',
            metadata TEXT DEFAULT '{}'
        );

        -- Benchmark runs (for comparing evaluators)
        CREATE TABLE IF NOT EXISTS benchmark_runs (
            id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            description TEXT,
            question TEXT NOT NULL,
            question_hash TEXT,
            task_type TEXT NOT NULL,
            evaluator_ids TEXT NOT NULL,
            document_ids TEXT NOT NULL,
            status TEXT DEFAULT 'pending' CHECK (
                status IN ('pending', 'running', 'completed', 'failed', 'cancelled')
            ),
            progress_current INTEGER DEFAULT 0,
            progress_total INTEGER DEFAULT 0,
            error_message TEXT,
            results_summary TEXT,
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            started_at TIMESTAMP,
            completed_at TIMESTAMP
        );

        -- Pivot table linking questions to documents found
        CREATE TABLE IF NOT EXISTS question_documents (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            question_hash TEXT NOT NULL,
            document_id TEXT NOT NULL,
            search_session_id TEXT,
            found_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            UNIQUE(question_hash, document_id)
        );

        -- Document chunks for interrogation
        CREATE TABLE IF NOT EXISTS chunks (
            id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            title TEXT,
            content TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            total_chunks INTEGER,
            metadata TEXT DEFAULT '{}',
            created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (source_id) REFERENCES documents(id)
        );

        -- Study classifications (linked to documents and evaluators)
        CREATE TABLE IF NOT EXISTS study_classifications (
            id TEXT PRIMARY KEY,
            document_id TEXT NOT NULL,
            study_design TEXT NOT NULL,
            is_randomized INTEGER,
            is_blinded TEXT,
            sample_size INTEGER,
            confidence REAL NOT NULL,
            raw_response TEXT,
            evaluator_id TEXT,
            latency_ms INTEGER,
            tokens_input INTEGER,
            tokens_output INTEGER,
            cost_usd REAL,
            classified_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
            FOREIGN KEY (document_id) REFERENCES documents(id),
            FOREIGN KEY (evaluator_id) REFERENCES evaluators(id)
        );

        -- Create indexes for common queries
        CREATE INDEX IF NOT EXISTS idx_search_sessions_created
            ON search_sessions(created_at);
        CREATE INDEX IF NOT EXISTS idx_checkpoints_updated
            ON review_checkpoints(updated_at);
        CREATE INDEX IF NOT EXISTS idx_scored_docs_checkpoint
            ON scored_documents(checkpoint_id);
        CREATE INDEX IF NOT EXISTS idx_scored_docs_evaluator
            ON scored_documents(evaluator_id);
        CREATE INDEX IF NOT EXISTS idx_scored_docs_doc_eval
            ON scored_documents(document_id, evaluator_id);
        CREATE INDEX IF NOT EXISTS idx_citations_checkpoint
            ON citations(checkpoint_id);
        CREATE INDEX IF NOT EXISTS idx_pubmed_cache_expires
            ON pubmed_cache(expires_at);
        CREATE INDEX IF NOT EXISTS idx_interrogation_sessions_created
            ON interrogation_sessions(created_at);
        CREATE INDEX IF NOT EXISTS idx_evaluators_type
            ON evaluators(type);
        CREATE INDEX IF NOT EXISTS idx_evaluators_provider
            ON evaluators(provider);
        CREATE INDEX IF NOT EXISTS idx_benchmark_runs_status
            ON benchmark_runs(status);
        CREATE INDEX IF NOT EXISTS idx_benchmark_runs_task
            ON benchmark_runs(task_type);
        -- Note: idx_benchmark_runs_question_hash is created in migration
        -- to handle existing databases without the question_hash column
        CREATE INDEX IF NOT EXISTS idx_question_documents_question_hash
            ON question_documents(question_hash);
        CREATE INDEX IF NOT EXISTS idx_question_documents_document_id
            ON question_documents(document_id);
        CREATE INDEX IF NOT EXISTS idx_documents_pmid
            ON documents(pmid);
        CREATE INDEX IF NOT EXISTS idx_documents_doi
            ON documents(doi);
        CREATE INDEX IF NOT EXISTS idx_chunks_source_id
            ON chunks(source_id);
        CREATE INDEX IF NOT EXISTS idx_study_classifications_document
            ON study_classifications(document_id);
        CREATE INDEX IF NOT EXISTS idx_study_classifications_evaluator
            ON study_classifications(evaluator_id);
        CREATE INDEX IF NOT EXISTS idx_study_classifications_doc_eval
            ON study_classifications(document_id, evaluator_id);
        """

    # =========================================================================
    # Helper Functions for sqlite-vec
    # =========================================================================

    @staticmethod
    def _serialize_embedding(embedding: list[float]) -> bytes:
        """
        Serialize embedding to bytes for sqlite-vec storage.

        Args:
            embedding: List of floats

        Returns:
            Packed bytes in float32 format
        """
        return struct.pack(f"{len(embedding)}f", *embedding)

    def _get_document_rowid(self, conn: sqlite3.Connection, doc_id: str) -> Optional[int]:
        """
        Get the rowid for a document from the vec_documents table.

        Args:
            conn: SQLite connection
            doc_id: Document ID

        Returns:
            Rowid if found, None otherwise
        """
        # We use a mapping table or store doc_id -> rowid
        # For simplicity, we use hash of doc_id as rowid
        cursor = conn.execute(
            "SELECT rowid FROM documents WHERE id = ?",
            (doc_id,),
        )
        row = cursor.fetchone()
        return row[0] if row else None

    # =========================================================================
    # Document Operations
    # =========================================================================

    def add_document(
        self,
        document: LiteDocument,
        embedding_function: Any = None,
    ) -> str:
        """
        Add a document to the storage.

        Args:
            document: Document to add
            embedding_function: Embedding function that has embed_single() method

        Returns:
            Document ID

        Raises:
            SQLiteError: If database operation fails

        Example:
            from bmlibrarian_lite.embeddings import LiteEmbedder

            embedder = LiteEmbedder()
            doc = LiteDocument(
                id="pmid-12345",
                title="Example Study",
                abstract="This study examines...",
                authors=["Smith J", "Jones A"],
                year=2023,
            )
            doc_id = storage.add_document(doc, embedding_function=embedder)
        """
        try:
            with self._sqlite_connection() as conn:
                # Insert document metadata
                conn.execute(
                    """
                    INSERT OR REPLACE INTO documents
                    (id, title, abstract, authors, year, journal, doi, pmid,
                     pmc_id, url, mesh_terms, source)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        document.id,
                        document.title,
                        document.abstract,
                        json.dumps(document.authors),
                        document.year,
                        document.journal,
                        document.doi,
                        document.pmid,
                        document.pmc_id,
                        document.url,
                        json.dumps(document.mesh_terms),
                        document.source.value,
                    ),
                )

                # Get rowid for the document
                cursor = conn.execute(
                    "SELECT rowid FROM documents WHERE id = ?",
                    (document.id,),
                )
                rowid = cursor.fetchone()[0]

                # Generate and store embedding if function provided
                if embedding_function and document.abstract:
                    embedding = embedding_function.embed_single(document.abstract)
                    embedding_bytes = self._serialize_embedding(embedding)

                    # Delete existing embedding if any
                    conn.execute(
                        "DELETE FROM vec_documents WHERE rowid = ?",
                        (rowid,),
                    )
                    # Insert new embedding
                    conn.execute(
                        "INSERT INTO vec_documents(rowid, embedding) VALUES (?, ?)",
                        (rowid, embedding_bytes),
                    )

                conn.commit()
                logger.debug(f"Added document {document.id} to storage")
                return document.id
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to add document {document.id}: {e}") from e

    def upsert_document(
        self,
        document: LiteDocument,
        embedding_function: Any = None,
    ) -> str:
        """
        Insert or update a document in the storage.

        This is an alias for add_document, which already performs upsert
        operations.

        Args:
            document: Document to insert or update
            embedding_function: Optional embedding function

        Returns:
            Document ID
        """
        return self.add_document(document, embedding_function)

    def add_documents(
        self,
        documents: list[LiteDocument],
        embedding_function: Any = None,
    ) -> list[str]:
        """
        Add multiple documents to storage.

        Args:
            documents: List of documents to add
            embedding_function: Embedding function that has embed() method

        Returns:
            List of document IDs

        Raises:
            SQLiteError: If database operation fails

        Example:
            docs = [doc1, doc2, doc3]
            ids = storage.add_documents(docs, embedding_function=embedder)
            print(f"Added {len(ids)} documents")
        """
        if not documents:
            return []

        try:
            with self._sqlite_connection() as conn:
                ids = []

                # Batch insert documents
                for doc in documents:
                    conn.execute(
                        """
                        INSERT OR REPLACE INTO documents
                        (id, title, abstract, authors, year, journal, doi, pmid,
                         pmc_id, url, mesh_terms, source)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            doc.id,
                            doc.title,
                            doc.abstract,
                            json.dumps(doc.authors),
                            doc.year,
                            doc.journal,
                            doc.doi,
                            doc.pmid,
                            doc.pmc_id,
                            doc.url,
                            json.dumps(doc.mesh_terms),
                            doc.source.value,
                        ),
                    )
                    ids.append(doc.id)

                # Generate embeddings if function provided
                if embedding_function:
                    texts = [doc.abstract for doc in documents if doc.abstract]
                    if texts:
                        embeddings = embedding_function.embed(texts)

                        # Get rowids and insert embeddings
                        text_idx = 0
                        for doc in documents:
                            if doc.abstract:
                                cursor = conn.execute(
                                    "SELECT rowid FROM documents WHERE id = ?",
                                    (doc.id,),
                                )
                                rowid = cursor.fetchone()[0]

                                embedding_bytes = self._serialize_embedding(
                                    embeddings[text_idx]
                                )
                                # Delete existing embedding if any
                                conn.execute(
                                    "DELETE FROM vec_documents WHERE rowid = ?",
                                    (rowid,),
                                )
                                conn.execute(
                                    "INSERT INTO vec_documents(rowid, embedding) "
                                    "VALUES (?, ?)",
                                    (rowid, embedding_bytes),
                                )
                                text_idx += 1

                conn.commit()
                logger.info(f"Added {len(documents)} documents to storage")
                return ids
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to add {len(documents)} documents: {e}") from e

    def get_document(
        self,
        document_id: str,
        embedding_function: Any = None,
    ) -> Optional[LiteDocument]:
        """
        Retrieve a document by ID.

        Args:
            document_id: Document ID to retrieve
            embedding_function: Unused, kept for API compatibility

        Returns:
            Document if found, None otherwise

        Raises:
            SQLiteError: If database query fails

        Example:
            doc = storage.get_document("pmid-12345678")
            if doc:
                print(f"Found: {doc.title}")
            else:
                print("Document not found")
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute(
                    """
                    SELECT id, title, abstract, authors, year, journal,
                           doi, pmid, pmc_id, url, mesh_terms, source
                    FROM documents
                    WHERE id = ?
                    """,
                    (document_id,),
                )
                row = cursor.fetchone()

                if not row:
                    return None

                return LiteDocument(
                    id=row["id"],
                    title=row["title"],
                    abstract=row["abstract"],
                    authors=json.loads(row["authors"] or "[]"),
                    year=row["year"],
                    journal=row["journal"],
                    doi=row["doi"],
                    pmid=row["pmid"],
                    pmc_id=row["pmc_id"],
                    url=row["url"],
                    mesh_terms=json.loads(row["mesh_terms"] or "[]"),
                    source=DocumentSource(row["source"]),
                )
        except sqlite3.Error as e:
            logger.error(f"Failed to get document {document_id}: {e}")
            raise SQLiteError(f"Failed to get document {document_id}: {e}") from e

    def get_documents(
        self,
        document_ids: list[str],
        embedding_function: Any = None,
    ) -> list[LiteDocument]:
        """
        Retrieve multiple documents by ID.

        Args:
            document_ids: List of document IDs
            embedding_function: Unused, kept for API compatibility

        Returns:
            List of found documents (may be fewer than requested)

        Raises:
            SQLiteError: If database query fails

        Example:
            ids = ["pmid-123", "pmid-456", "pmid-789"]
            docs = storage.get_documents(ids)
            for doc in docs:
                print(f"{doc.id}: {doc.title}")
        """
        if not document_ids:
            return []

        try:
            with self._sqlite_connection() as conn:
                # Use parameterized query with placeholders
                placeholders = ",".join("?" * len(document_ids))
                cursor = conn.execute(
                    f"""
                    SELECT id, title, abstract, authors, year, journal,
                           doi, pmid, pmc_id, url, mesh_terms, source
                    FROM documents
                    WHERE id IN ({placeholders})
                    """,
                    document_ids,
                )

                documents = []
                for row in cursor:
                    documents.append(LiteDocument(
                        id=row["id"],
                        title=row["title"],
                        abstract=row["abstract"],
                        authors=json.loads(row["authors"] or "[]"),
                        year=row["year"],
                        journal=row["journal"],
                        doi=row["doi"],
                        pmid=row["pmid"],
                        pmc_id=row["pmc_id"],
                        url=row["url"],
                        mesh_terms=json.loads(row["mesh_terms"] or "[]"),
                        source=DocumentSource(row["source"]),
                    ))

                return documents
        except sqlite3.Error as e:
            logger.error(f"Failed to get documents: {e}")
            raise SQLiteError(f"Failed to get {len(document_ids)} documents: {e}") from e

    def get_all_document_ids(self) -> set[str]:
        """
        Get all document IDs in the database.

        Returns:
            Set of all document IDs
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute("SELECT id FROM documents")
                return {row["id"] for row in cursor}
        except sqlite3.Error as e:
            logger.error(f"Failed to get document IDs: {e}")
            return set()

    def search_documents(
        self,
        query: str,
        n_results: int = 20,
        embedding_function: Any = None,
    ) -> list[LiteDocument]:
        """
        Search documents by semantic similarity using sqlite-vec.

        Args:
            query: Search query (natural language)
            n_results: Maximum number of results
            embedding_function: Embedding function with embed_single() method

        Returns:
            List of matching documents ordered by similarity

        Raises:
            SQLiteError: If database query fails

        Example:
            # Find documents about heart disease
            results = storage.search_documents(
                query="cardiovascular disease treatment",
                n_results=10,
                embedding_function=embedder
            )
            for doc in results:
                print(f"[{doc.year}] {doc.title}")
        """
        if not embedding_function:
            raise ValueError("embedding_function is required for semantic search")

        try:
            # Generate query embedding
            query_embedding = embedding_function.embed_single(query)
            query_bytes = self._serialize_embedding(query_embedding)

            with self._sqlite_connection() as conn:
                # KNN search using sqlite-vec
                # Note: sqlite-vec requires k=? in WHERE clause, not LIMIT
                cursor = conn.execute(
                    """
                    SELECT
                        d.id, d.title, d.abstract, d.authors, d.year,
                        d.journal, d.doi, d.pmid, d.pmc_id, d.url,
                        d.mesh_terms, d.source,
                        v.distance
                    FROM vec_documents v
                    JOIN documents d ON d.rowid = v.rowid
                    WHERE v.embedding MATCH ? AND k = ?
                    ORDER BY v.distance
                    """,
                    (query_bytes, n_results),
                )

                documents = []
                for row in cursor:
                    documents.append(LiteDocument(
                        id=row["id"],
                        title=row["title"],
                        abstract=row["abstract"],
                        authors=json.loads(row["authors"] or "[]"),
                        year=row["year"],
                        journal=row["journal"],
                        doi=row["doi"],
                        pmid=row["pmid"],
                        pmc_id=row["pmc_id"],
                        url=row["url"],
                        mesh_terms=json.loads(row["mesh_terms"] or "[]"),
                        source=DocumentSource(row["source"]),
                    ))

                return documents
        except sqlite3.Error as e:
            raise SQLiteError(f"Semantic search failed for query: {e}") from e

    def delete_document(
        self,
        document_id: str,
        embedding_function: Any = None,
    ) -> bool:
        """
        Delete a document from storage.

        Args:
            document_id: Document ID to delete
            embedding_function: Unused, kept for API compatibility

        Returns:
            True if deleted, False otherwise
        """
        try:
            with self._sqlite_connection() as conn:
                # Get rowid first to delete from vec_documents
                cursor = conn.execute(
                    "SELECT rowid FROM documents WHERE id = ?",
                    (document_id,),
                )
                row = cursor.fetchone()

                if row:
                    rowid = row[0]
                    # Delete from vec_documents first (foreign key would fail otherwise)
                    conn.execute(
                        "DELETE FROM vec_documents WHERE rowid = ?",
                        (rowid,),
                    )
                    # Delete from documents
                    conn.execute(
                        "DELETE FROM documents WHERE id = ?",
                        (document_id,),
                    )
                    conn.commit()
                    logger.debug(f"Deleted document {document_id}")
                    return True
                return False
        except sqlite3.Error as e:
            logger.error(f"Failed to delete document {document_id}: {e}")
            return False

    # =========================================================================
    # Chunk Operations (for document interrogation)
    # =========================================================================

    def add_chunks(
        self,
        chunks: list[LiteChunk],
        embedding_function: Any = None,
    ) -> list[str]:
        """
        Add document chunks with embeddings for interrogation.

        Args:
            chunks: List of LiteChunk objects
            embedding_function: Embedding function with embed() method

        Returns:
            List of chunk IDs

        Raises:
            SQLiteError: If database operation fails
        """
        if not chunks:
            return []

        try:
            with self._sqlite_connection() as conn:
                chunk_ids = []
                total_chunks = len(chunks)

                for chunk in chunks:
                    # Build metadata JSON
                    metadata = json.dumps({
                        "start_char": chunk.start_char,
                        "end_char": chunk.end_char,
                    })

                    conn.execute(
                        """
                        INSERT OR REPLACE INTO chunks
                        (id, source_id, title, content, chunk_index, total_chunks, metadata)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            chunk.id,
                            chunk.document_id,
                            getattr(chunk, "title", None),
                            chunk.text,
                            chunk.chunk_index,
                            total_chunks,
                            metadata,
                        ),
                    )
                    chunk_ids.append(chunk.id)

                # Generate embeddings if function provided
                if embedding_function:
                    contents = [c.text for c in chunks]
                    embeddings = embedding_function.embed(contents)

                    for i, chunk in enumerate(chunks):
                        # Get rowid for the chunk
                        cursor = conn.execute(
                            "SELECT rowid FROM chunks WHERE id = ?",
                            (chunk.id,),
                        )
                        rowid = cursor.fetchone()[0]

                        embedding_bytes = self._serialize_embedding(embeddings[i])
                        # Delete existing embedding if any
                        conn.execute(
                            "DELETE FROM vec_chunks WHERE rowid = ?",
                            (rowid,),
                        )
                        conn.execute(
                            "INSERT INTO vec_chunks(rowid, embedding) VALUES (?, ?)",
                            (rowid, embedding_bytes),
                        )

                conn.commit()
                source_id = chunks[0].document_id if chunks else "unknown"
                logger.debug(f"Added {len(chunks)} chunks for document {source_id}")
                return chunk_ids
        except sqlite3.Error as e:
            source_id = chunks[0].document_id if chunks else "unknown"
            raise SQLiteError(f"Failed to add chunks for {source_id}: {e}") from e

    def search_chunks(
        self,
        query: str,
        document_id: Optional[str] = None,
        n_results: int = 5,
        embedding_function: Any = None,
    ) -> list[tuple[LiteChunk, float]]:
        """
        Search chunks by semantic similarity using sqlite-vec.

        Args:
            query: Search query
            document_id: Optional document ID to filter by
            n_results: Maximum results to return
            embedding_function: Embedding function with embed_single() method

        Returns:
            List of (LiteChunk, distance) tuples

        Raises:
            SQLiteError: If database query fails
        """
        if not embedding_function:
            raise ValueError("embedding_function is required for semantic search")

        try:
            query_embedding = embedding_function.embed_single(query)
            query_bytes = self._serialize_embedding(query_embedding)

            with self._sqlite_connection() as conn:
                # Note: sqlite-vec requires k=? in WHERE clause, not LIMIT
                if document_id:
                    cursor = conn.execute(
                        """
                        SELECT
                            c.id, c.source_id, c.title, c.content, c.chunk_index,
                            c.total_chunks, c.metadata, v.distance
                        FROM vec_chunks v
                        JOIN chunks c ON c.rowid = v.rowid
                        WHERE v.embedding MATCH ? AND k = ? AND c.source_id = ?
                        ORDER BY v.distance
                        """,
                        (query_bytes, n_results, document_id),
                    )
                else:
                    cursor = conn.execute(
                        """
                        SELECT
                            c.id, c.source_id, c.title, c.content, c.chunk_index,
                            c.total_chunks, c.metadata, v.distance
                        FROM vec_chunks v
                        JOIN chunks c ON c.rowid = v.rowid
                        WHERE v.embedding MATCH ? AND k = ?
                        ORDER BY v.distance
                        """,
                        (query_bytes, n_results),
                    )

                results = []
                for row in cursor:
                    metadata = json.loads(row["metadata"] or "{}")
                    chunk = LiteChunk(
                        id=row["id"],
                        document_id=row["source_id"],
                        text=row["content"],
                        chunk_index=row["chunk_index"],
                        start_char=metadata.get("start_char", 0),
                        end_char=metadata.get("end_char", 0),
                    )
                    results.append((chunk, row["distance"]))

                return results
        except sqlite3.Error as e:
            raise SQLiteError(f"Chunk search failed: {e}") from e

    def get_chunks_for_document(self, document_id: str) -> list[LiteChunk]:
        """
        Get all chunks for a document.

        Args:
            document_id: Document ID

        Returns:
            List of LiteChunk objects ordered by chunk_index
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute(
                    """
                    SELECT id, source_id, content, chunk_index, total_chunks, metadata
                    FROM chunks
                    WHERE source_id = ?
                    ORDER BY chunk_index
                    """,
                    (document_id,),
                )

                chunks = []
                for row in cursor:
                    metadata = json.loads(row["metadata"] or "{}")
                    chunks.append(LiteChunk(
                        id=row["id"],
                        document_id=row["source_id"],
                        text=row["content"],
                        chunk_index=row["chunk_index"],
                        start_char=metadata.get("start_char", 0),
                        end_char=metadata.get("end_char", 0),
                    ))
                return chunks
        except sqlite3.Error as e:
            logger.error(f"Failed to get chunks for {document_id}: {e}")
            return []

    def delete_chunks_for_document(self, document_id: str) -> int:
        """
        Delete all chunks for a document.

        Args:
            document_id: Document ID

        Returns:
            Number of chunks deleted
        """
        try:
            with self._sqlite_connection() as conn:
                # Get rowids to delete from vec_chunks
                cursor = conn.execute(
                    "SELECT rowid FROM chunks WHERE source_id = ?",
                    (document_id,),
                )
                rowids = [row[0] for row in cursor]

                # Delete embeddings
                for rowid in rowids:
                    conn.execute(
                        "DELETE FROM vec_chunks WHERE rowid = ?",
                        (rowid,),
                    )

                # Delete chunks
                conn.execute(
                    "DELETE FROM chunks WHERE source_id = ?",
                    (document_id,),
                )
                conn.commit()
                logger.debug(f"Deleted {len(rowids)} chunks for document {document_id}")
                return len(rowids)
        except sqlite3.Error as e:
            logger.error(f"Failed to delete chunks for {document_id}: {e}")
            return 0

    def count_chunks_for_document(self, source_id: str) -> int:
        """
        Count chunks for a document.

        Args:
            source_id: Source document ID

        Returns:
            Number of chunks
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute(
                    "SELECT COUNT(*) FROM chunks WHERE source_id = ?",
                    (source_id,),
                )
                return cursor.fetchone()[0]
        except sqlite3.Error:
            return 0

    def list_chunked_documents(self) -> list[dict]:
        """
        List all documents that have chunks stored.

        Returns:
            List of dictionaries with document_id, title, and chunk_count
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute(
                    """
                    SELECT source_id, title, COUNT(*) as chunk_count
                    FROM chunks
                    GROUP BY source_id, title
                    ORDER BY source_id
                    """
                )
                return [
                    {
                        "document_id": row["source_id"],
                        "title": row["title"],
                        "chunk_count": row["chunk_count"],
                    }
                    for row in cursor
                ]
        except sqlite3.Error as e:
            logger.error(f"Failed to list chunked documents: {e}")
            return []

    # =========================================================================
    # Search Session Operations
    # =========================================================================

    def create_search_session(
        self,
        query: str,
        natural_language_query: str,
        document_count: int = 0,
        metadata: Optional[dict[str, Any]] = None,
    ) -> SearchSession:
        """
        Create a new search session.

        Records a PubMed search for history and reproducibility.

        Args:
            query: PubMed query string
            natural_language_query: Original natural language query
            document_count: Number of documents found
            metadata: Optional metadata

        Returns:
            Created search session

        Raises:
            SQLiteError: If database insert fails

        Example:
            session = storage.create_search_session(
                query="diabetes[MeSH] AND treatment",
                natural_language_query="How is diabetes treated?",
                document_count=42,
            )
            print(f"Session ID: {session.id}")
        """
        session_id = str(uuid.uuid4())
        now = datetime.now()

        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT INTO search_sessions
                    (id, query, natural_language_query, created_at, document_count, metadata)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        session_id,
                        query,
                        natural_language_query,
                        now,
                        document_count,
                        json.dumps(metadata or {}),
                    ),
                )
                conn.commit()

            return SearchSession(
                id=session_id,
                query=query,
                natural_language_query=natural_language_query,
                created_at=now,
                document_count=document_count,
                metadata=metadata or {},
            )
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to create search session: {e}") from e

    def get_search_sessions(self, limit: int = 50) -> list[SearchSession]:
        """
        Get recent search sessions.

        Args:
            limit: Maximum number of sessions to return

        Returns:
            List of search sessions, most recent first
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, query, natural_language_query, created_at,
                       document_count, metadata
                FROM search_sessions
                ORDER BY created_at DESC
                LIMIT ?
                """,
                (limit,),
            )

            sessions = []
            for row in cursor:
                sessions.append(SearchSession(
                    id=row["id"],
                    query=row["query"],
                    natural_language_query=row["natural_language_query"],
                    created_at=row["created_at"],
                    document_count=row["document_count"],
                    metadata=json.loads(row["metadata"]),
                ))

            return sessions

    def get_search_session(self, session_id: str) -> Optional[SearchSession]:
        """
        Get a search session by ID.

        Args:
            session_id: Session ID

        Returns:
            Search session if found, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, query, natural_language_query, created_at,
                       document_count, metadata
                FROM search_sessions
                WHERE id = ?
                """,
                (session_id,),
            )
            row = cursor.fetchone()

            if not row:
                return None

            return SearchSession(
                id=row["id"],
                query=row["query"],
                natural_language_query=row["natural_language_query"],
                created_at=row["created_at"],
                document_count=row["document_count"],
                metadata=json.loads(row["metadata"]),
            )

    # =========================================================================
    # Review Checkpoint Operations
    # =========================================================================

    def create_checkpoint(
        self,
        research_question: str,
        metadata: Optional[dict[str, Any]] = None,
    ) -> ReviewCheckpoint:
        """
        Create a new review checkpoint.

        Creates a checkpoint to track systematic review progress.
        Use update_checkpoint() to update step and data.

        Args:
            research_question: The research question
            metadata: Optional metadata

        Returns:
            Created checkpoint

        Raises:
            SQLiteError: If database insert fails

        Example:
            checkpoint = storage.create_checkpoint(
                research_question="What are the effects of exercise on depression?"
            )
            print(f"Checkpoint ID: {checkpoint.id}")
            # Later: update progress
            storage.update_checkpoint(checkpoint.id, step="scoring")
        """
        checkpoint_id = str(uuid.uuid4())
        now = datetime.now()

        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT INTO review_checkpoints
                    (id, research_question, created_at, updated_at, step, metadata)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    (
                        checkpoint_id,
                        research_question,
                        now,
                        now,
                        "start",
                        json.dumps(metadata or {}),
                    ),
                )
                conn.commit()

            return ReviewCheckpoint(
                id=checkpoint_id,
                research_question=research_question,
                created_at=now,
                updated_at=now,
                step="start",
                metadata=metadata or {},
            )
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to create checkpoint: {e}") from e

    def update_checkpoint(
        self,
        checkpoint_id: str,
        step: Optional[str] = None,
        search_session_id: Optional[str] = None,
        report: Optional[str] = None,
        metadata: Optional[dict[str, Any]] = None,
    ) -> None:
        """
        Update a review checkpoint.

        Args:
            checkpoint_id: Checkpoint ID to update
            step: New workflow step
            search_session_id: Associated search session
            report: Generated report text
            metadata: Updated metadata
        """
        updates = ["updated_at = ?"]
        values: list[Any] = [datetime.now()]

        if step is not None:
            updates.append("step = ?")
            values.append(step)
        if search_session_id is not None:
            updates.append("search_session_id = ?")
            values.append(search_session_id)
        if report is not None:
            updates.append("report = ?")
            values.append(report)
        if metadata is not None:
            updates.append("metadata = ?")
            values.append(json.dumps(metadata))

        values.append(checkpoint_id)

        with self._sqlite_connection() as conn:
            conn.execute(
                f"UPDATE review_checkpoints SET {', '.join(updates)} WHERE id = ?",
                values,
            )
            conn.commit()

    def get_checkpoint(self, checkpoint_id: str) -> Optional[ReviewCheckpoint]:
        """
        Get a checkpoint by ID.

        Args:
            checkpoint_id: Checkpoint ID to retrieve

        Returns:
            Checkpoint if found, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, research_question, created_at, updated_at, step,
                       search_session_id, report, metadata
                FROM review_checkpoints
                WHERE id = ?
                """,
                (checkpoint_id,),
            )
            row = cursor.fetchone()

            if not row:
                return None

            return ReviewCheckpoint(
                id=row["id"],
                research_question=row["research_question"],
                created_at=row["created_at"],
                updated_at=row["updated_at"],
                step=row["step"],
                search_session_id=row["search_session_id"],
                report=row["report"],
                metadata=json.loads(row["metadata"]),
            )

    def get_recent_checkpoints(self, limit: int = 20) -> list[ReviewCheckpoint]:
        """
        Get recent review checkpoints.

        Args:
            limit: Maximum number to return

        Returns:
            List of checkpoints, most recent first
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, research_question, created_at, updated_at, step,
                       search_session_id, report, metadata
                FROM review_checkpoints
                ORDER BY updated_at DESC
                LIMIT ?
                """,
                (limit,),
            )

            checkpoints = []
            for row in cursor:
                checkpoints.append(ReviewCheckpoint(
                    id=row["id"],
                    research_question=row["research_question"],
                    created_at=row["created_at"],
                    updated_at=row["updated_at"],
                    step=row["step"],
                    search_session_id=row["search_session_id"],
                    report=row["report"],
                    metadata=json.loads(row["metadata"]),
                ))

            return checkpoints

    def delete_checkpoint(self, checkpoint_id: str) -> bool:
        """
        Delete a checkpoint and associated data.

        Args:
            checkpoint_id: Checkpoint ID to delete

        Returns:
            True if deleted, False otherwise
        """
        with self._sqlite_connection() as conn:
            try:
                # Delete associated data first
                conn.execute(
                    "DELETE FROM citations WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                )
                conn.execute(
                    "DELETE FROM scored_documents WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                )
                conn.execute(
                    "DELETE FROM review_checkpoints WHERE id = ?",
                    (checkpoint_id,),
                )
                conn.commit()
                logger.debug(f"Deleted checkpoint {checkpoint_id}")
                return True
            except Exception as e:
                logger.error(f"Failed to delete checkpoint {checkpoint_id}: {e}")
                return False

    # =========================================================================
    # Research Question Operations
    # =========================================================================

    def get_unique_research_questions(
        self,
        limit: int = 50,
    ) -> list[ResearchQuestionSummary]:
        """
        Get unique research questions from past search sessions.

        Returns a list of unique research questions with metadata about
        their most recent runs, document counts, and scoring status.

        Args:
            limit: Maximum number of questions to return

        Returns:
            List of ResearchQuestionSummary objects, most recent first
        """
        with self._sqlite_connection() as conn:
            # Get unique questions with aggregated data
            cursor = conn.execute(
                """
                SELECT
                    natural_language_query,
                    MAX(query) as pubmed_query,
                    MAX(created_at) as last_run_at,
                    SUM(document_count) as total_documents,
                    COUNT(*) as run_count
                FROM search_sessions
                GROUP BY LOWER(TRIM(natural_language_query))
                ORDER BY last_run_at DESC
                LIMIT ?
                """,
                (limit,),
            )

            summaries = []
            for row in cursor:
                question = row["natural_language_query"]
                question_hash = compute_question_hash(question)

                # Count scored documents for this question
                scored_count = self._count_scored_documents_for_question(
                    conn, question
                )

                summaries.append(ResearchQuestionSummary(
                    question=question,
                    question_hash=question_hash,
                    pubmed_query=row["pubmed_query"],
                    last_run_at=row["last_run_at"],
                    total_documents=row["total_documents"] or 0,
                    scored_documents=scored_count,
                    run_count=row["run_count"],
                ))

            return summaries

    def _count_scored_documents_for_question(
        self,
        conn: sqlite3.Connection,
        question: str,
    ) -> int:
        """
        Count scored documents for a research question.

        Args:
            conn: Active SQLite connection
            question: The research question text

        Returns:
            Count of unique scored documents
        """
        # Find checkpoints matching this question directly
        # Then count unique document_ids in scored_documents
        cursor = conn.execute(
            """
            SELECT COUNT(DISTINCT sd.document_id) as count
            FROM scored_documents sd
            INNER JOIN review_checkpoints rc ON sd.checkpoint_id = rc.id
            WHERE LOWER(TRIM(rc.research_question)) = LOWER(TRIM(?))
            """,
            (question,),
        )
        row = cursor.fetchone()
        return row["count"] if row else 0

    def get_scored_document_ids_for_question(
        self,
        question: str,
    ) -> set[str]:
        """
        Get all document IDs that have been scored for a research question.

        This includes documents of any score (even low ones) to enable
        deduplication during incremental searches.

        Args:
            question: The research question text

        Returns:
            Set of document IDs that have been scored
        """
        with self._sqlite_connection() as conn:
            # Get all scored document IDs across all checkpoints for this question
            # We match by normalizing the question text in review_checkpoints
            cursor = conn.execute(
                """
                SELECT DISTINCT sd.document_id
                FROM scored_documents sd
                INNER JOIN review_checkpoints rc ON sd.checkpoint_id = rc.id
                WHERE LOWER(TRIM(rc.research_question)) = LOWER(TRIM(?))
                """,
                (question,),
            )
            return {row["document_id"] for row in cursor}

    def add_question_documents(
        self,
        question: str,
        document_ids: list[str],
        search_session_id: Optional[str] = None,
    ) -> int:
        """
        Record documents found for a research question.

        Uses INSERT OR IGNORE to handle duplicates gracefully - if a document
        was already found for this question, it won't be added again.

        Args:
            question: The research question text
            document_ids: List of document IDs found
            search_session_id: Optional search session that found these docs

        Returns:
            Number of new document associations added
        """
        question_hash = compute_question_hash(question)
        added = 0

        with self._sqlite_connection() as conn:
            for doc_id in document_ids:
                try:
                    conn.execute(
                        """
                        INSERT OR IGNORE INTO question_documents
                        (question_hash, document_id, search_session_id)
                        VALUES (?, ?, ?)
                        """,
                        (question_hash, doc_id, search_session_id),
                    )
                    if conn.total_changes > 0:
                        added += 1
                except Exception:
                    # Ignore duplicates or other errors
                    pass
            conn.commit()

        logger.debug(
            f"Added {added} new document associations for question "
            f"(hash: {question_hash[:8]}...)"
        )
        return added

    def get_document_ids_for_question(
        self,
        question: str,
    ) -> set[str]:
        """
        Get all document IDs that were found for a research question.

        This returns ALL documents that were ever retrieved for this question,
        regardless of whether they have been scored.

        Args:
            question: The research question text

        Returns:
            Set of document IDs found for this question
        """
        question_hash = compute_question_hash(question)

        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT DISTINCT document_id
                FROM question_documents
                WHERE question_hash = ?
                """,
                (question_hash,),
            )
            return {row["document_id"] for row in cursor}

    def get_search_session_by_question(
        self,
        question: str,
    ) -> Optional[SearchSession]:
        """
        Get the most recent search session for a research question.

        Args:
            question: The research question text

        Returns:
            Most recent SearchSession if found, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, query, natural_language_query, created_at,
                       document_count, metadata
                FROM search_sessions
                WHERE LOWER(TRIM(natural_language_query)) = LOWER(TRIM(?))
                ORDER BY created_at DESC
                LIMIT 1
                """,
                (question,),
            )
            row = cursor.fetchone()

            if not row:
                return None

            return SearchSession(
                id=row["id"],
                query=row["query"],
                natural_language_query=row["natural_language_query"],
                created_at=row["created_at"],
                document_count=row["document_count"],
                metadata=json.loads(row["metadata"]),
            )

    def delete_research_question(self, question: str) -> bool:
        """
        Delete a research question and all associated data.

        This removes:
        - All review checkpoints for this question
        - All scored documents for those checkpoints
        - All citations for those checkpoints
        - All question_documents associations

        Note: Documents themselves are NOT deleted as they may be shared
        across multiple questions.

        Args:
            question: The research question text to delete

        Returns:
            True if deletion was successful
        """
        question_hash = compute_question_hash(question)

        with self._sqlite_connection() as conn:
            # Get all checkpoint IDs for this question
            cursor = conn.execute(
                """
                SELECT id FROM review_checkpoints
                WHERE LOWER(TRIM(research_question)) = LOWER(TRIM(?))
                """,
                (question,),
            )
            checkpoint_ids = [row["id"] for row in cursor]

            deleted_scored = 0
            deleted_citations = 0
            deleted_checkpoints = 0

            # Delete scored documents and citations for each checkpoint
            for checkpoint_id in checkpoint_ids:
                cursor = conn.execute(
                    "DELETE FROM scored_documents WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                )
                deleted_scored += cursor.rowcount

                cursor = conn.execute(
                    "DELETE FROM citations WHERE checkpoint_id = ?",
                    (checkpoint_id,),
                )
                deleted_citations += cursor.rowcount

            # Delete the checkpoints
            cursor = conn.execute(
                """
                DELETE FROM review_checkpoints
                WHERE LOWER(TRIM(research_question)) = LOWER(TRIM(?))
                """,
                (question,),
            )
            deleted_checkpoints = cursor.rowcount

            # Delete question_documents associations
            cursor = conn.execute(
                "DELETE FROM question_documents WHERE question_hash = ?",
                (question_hash,),
            )
            deleted_associations = cursor.rowcount

            conn.commit()

            logger.info(
                f"Deleted research question: {deleted_checkpoints} checkpoints, "
                f"{deleted_scored} scored docs, {deleted_citations} citations, "
                f"{deleted_associations} doc associations"
            )

            return deleted_checkpoints > 0 or deleted_associations > 0

    # =========================================================================
    # PubMed Cache Operations
    # =========================================================================

    def get_cached_pubmed_response(self, query_hash: str) -> Optional[str]:
        """
        Get cached PubMed API response.

        Args:
            query_hash: Hash of the query

        Returns:
            Cached response if valid, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT response FROM pubmed_cache
                WHERE query_hash = ? AND expires_at > ?
                """,
                (query_hash, datetime.now()),
            )
            row = cursor.fetchone()
            return row["response"] if row else None

    def cache_pubmed_response(
        self,
        query_hash: str,
        response: str,
        ttl_seconds: int = PUBMED_CACHE_TTL_SECONDS,
    ) -> None:
        """
        Cache a PubMed API response.

        Args:
            query_hash: Hash of the query
            response: Response to cache
            ttl_seconds: Time to live in seconds
        """
        now = datetime.now()
        expires_at = datetime.fromtimestamp(now.timestamp() + ttl_seconds)

        with self._sqlite_connection() as conn:
            conn.execute(
                """
                INSERT OR REPLACE INTO pubmed_cache
                (query_hash, response, created_at, expires_at)
                VALUES (?, ?, ?, ?)
                """,
                (query_hash, response, now, expires_at),
            )
            conn.commit()

    def clear_expired_cache(self) -> int:
        """
        Clear expired cache entries.

        Returns:
            Number of entries cleared
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                "DELETE FROM pubmed_cache WHERE expires_at < ?",
                (datetime.now(),),
            )
            conn.commit()
            return cursor.rowcount

    # =========================================================================
    # Utility Methods
    # =========================================================================

    def get_statistics(self) -> dict[str, Any]:
        """
        Get storage statistics.

        Returns:
            Dictionary with storage statistics
        """
        with self._sqlite_connection() as conn:
            documents = conn.execute(
                "SELECT COUNT(*) FROM documents"
            ).fetchone()[0]
            chunks = conn.execute(
                "SELECT COUNT(*) FROM chunks"
            ).fetchone()[0]
            sessions = conn.execute(
                "SELECT COUNT(*) FROM search_sessions"
            ).fetchone()[0]
            checkpoints = conn.execute(
                "SELECT COUNT(*) FROM review_checkpoints"
            ).fetchone()[0]

        return {
            "documents": documents,
            "chunks": chunks,
            "search_sessions": sessions,
            "checkpoints": checkpoints,
            "data_dir": str(self._storage_config.data_dir),
        }

    def clear_all(self, confirm: bool = False) -> None:
        """
        Clear all data from storage.

        WARNING: This permanently deletes all data!

        Args:
            confirm: Must be True to actually clear data

        Raises:
            ValueError: If confirm is not True
        """
        if not confirm:
            raise ValueError("Must pass confirm=True to clear all data")

        # Clear all SQLite tables including documents and vector embeddings
        with self._sqlite_connection() as conn:
            conn.executescript("""
                DELETE FROM vec_documents;
                DELETE FROM vec_chunks;
                DELETE FROM chunks;
                DELETE FROM documents;
                DELETE FROM citations;
                DELETE FROM scored_documents;
                DELETE FROM review_checkpoints;
                DELETE FROM search_sessions;
                DELETE FROM pubmed_cache;
                DELETE FROM interrogation_sessions;
                DELETE FROM user_settings;
                DELETE FROM question_documents;
            """)
            conn.commit()

        logger.warning("All data cleared from storage")

    # =========================================================================
    # Evaluator Operations
    # =========================================================================

    def upsert_evaluator(self, evaluator: Evaluator) -> str:
        """
        Insert or update an evaluator.

        Args:
            evaluator: Evaluator to upsert

        Returns:
            Evaluator ID

        Raises:
            SQLiteError: If database operation fails
        """
        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT OR REPLACE INTO evaluators
                    (id, type, display_name, provider, model_name, temperature,
                     max_tokens, top_p, top_k, human_name, human_email,
                     description, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        evaluator.id,
                        evaluator.type.value,
                        evaluator.display_name,
                        evaluator.provider,
                        evaluator.model_name,
                        evaluator.temperature,
                        evaluator.max_tokens,
                        evaluator.top_p,
                        evaluator.top_k,
                        evaluator.human_name,
                        evaluator.human_email,
                        evaluator.description,
                        evaluator.created_at,
                    ),
                )
                conn.commit()

            logger.debug(f"Upserted evaluator {evaluator.id}")
            return evaluator.id
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to upsert evaluator: {e}") from e

    def get_evaluator(self, evaluator_id: str) -> Optional[Evaluator]:
        """
        Get an evaluator by ID.

        Args:
            evaluator_id: Evaluator ID to retrieve

        Returns:
            Evaluator if found, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, type, display_name, provider, model_name, temperature,
                       max_tokens, top_p, top_k, human_name, human_email,
                       description, created_at
                FROM evaluators
                WHERE id = ?
                """,
                (evaluator_id,),
            )
            row = cursor.fetchone()

            if not row:
                return None

            return Evaluator(
                id=row["id"],
                type=EvaluatorType(row["type"]),
                display_name=row["display_name"],
                provider=row["provider"],
                model_name=row["model_name"],
                temperature=row["temperature"],
                max_tokens=row["max_tokens"],
                top_p=row["top_p"],
                top_k=row["top_k"],
                human_name=row["human_name"],
                human_email=row["human_email"],
                description=row["description"],
                created_at=row["created_at"],
            )

    def get_evaluators(
        self,
        evaluator_type: Optional[EvaluatorType] = None,
        provider: Optional[str] = None,
    ) -> list[Evaluator]:
        """
        Get evaluators with optional filtering.

        Args:
            evaluator_type: Filter by type (model or human)
            provider: Filter by provider (anthropic, ollama)

        Returns:
            List of matching evaluators
        """
        query = "SELECT * FROM evaluators WHERE 1=1"
        params: list[Any] = []

        if evaluator_type is not None:
            query += " AND type = ?"
            params.append(evaluator_type.value)

        if provider is not None:
            query += " AND provider = ?"
            params.append(provider)

        query += " ORDER BY created_at DESC"

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)

            evaluators = []
            for row in cursor:
                evaluators.append(Evaluator(
                    id=row["id"],
                    type=EvaluatorType(row["type"]),
                    display_name=row["display_name"],
                    provider=row["provider"],
                    model_name=row["model_name"],
                    temperature=row["temperature"],
                    max_tokens=row["max_tokens"],
                    top_p=row["top_p"],
                    top_k=row["top_k"],
                    human_name=row["human_name"],
                    human_email=row["human_email"],
                    description=row["description"],
                    created_at=row["created_at"],
                ))

            return evaluators

    def delete_evaluator(self, evaluator_id: str) -> bool:
        """
        Delete an evaluator.

        Note: This will fail if the evaluator has associated scored documents.

        Args:
            evaluator_id: Evaluator ID to delete

        Returns:
            True if deleted, False otherwise
        """
        with self._sqlite_connection() as conn:
            try:
                cursor = conn.execute(
                    "DELETE FROM evaluators WHERE id = ?",
                    (evaluator_id,),
                )
                conn.commit()
                return cursor.rowcount > 0
            except sqlite3.IntegrityError:
                logger.warning(
                    f"Cannot delete evaluator {evaluator_id}: has associated scores"
                )
                return False

    # =========================================================================
    # Scored Document Operations (Extended for Benchmarking)
    # =========================================================================

    def save_scored_document(
        self,
        scored_doc: ScoredDocument,
        checkpoint_id: str,
    ) -> str:
        """
        Save a scored document with evaluator tracking.

        Args:
            scored_doc: Scored document to save
            checkpoint_id: Associated checkpoint ID

        Returns:
            Scored document ID

        Raises:
            SQLiteError: If database operation fails
        """
        doc_id = str(uuid.uuid4())

        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT INTO scored_documents
                    (id, checkpoint_id, document_id, score, explanation,
                     evaluator_id, latency_ms, tokens_input, tokens_output,
                     cost_usd, scored_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        doc_id,
                        checkpoint_id,
                        scored_doc.document.id,
                        scored_doc.score,
                        scored_doc.explanation,
                        scored_doc.evaluator_id,
                        scored_doc.latency_ms,
                        scored_doc.tokens_input,
                        scored_doc.tokens_output,
                        scored_doc.cost_usd,
                        scored_doc.scored_at,
                    ),
                )
                conn.commit()

            logger.debug(f"Saved scored document {doc_id}")
            return doc_id
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to save scored document: {e}") from e

    def get_scored_document_by_evaluator(
        self,
        document_id: str,
        evaluator_id: str,
        checkpoint_id: Optional[str] = None,
    ) -> Optional[ScoredDocument]:
        """
        Get a scored document by document ID and evaluator ID.

        This is useful for checking if a document has already been
        scored by a specific evaluator (for caching/reuse).

        Args:
            document_id: Document ID
            evaluator_id: Evaluator ID
            checkpoint_id: Optional checkpoint ID filter

        Returns:
            ScoredDocument if found, None otherwise
        """
        query = """
            SELECT sd.*, e.type as eval_type, e.display_name, e.provider,
                   e.model_name, e.temperature as eval_temp, e.max_tokens as eval_max,
                   e.top_p, e.top_k
            FROM scored_documents sd
            LEFT JOIN evaluators e ON sd.evaluator_id = e.id
            WHERE sd.document_id = ? AND sd.evaluator_id = ?
        """
        params: list[Any] = [document_id, evaluator_id]

        if checkpoint_id is not None:
            query += " AND sd.checkpoint_id = ?"
            params.append(checkpoint_id)

        query += " ORDER BY sd.scored_at DESC LIMIT 1"

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)
            row = cursor.fetchone()

            if not row:
                return None

            # Get the full document
            doc = self.get_document(row["document_id"])
            if not doc:
                return None

            # Build evaluator if present
            evaluator = None
            if row["evaluator_id"] and row["eval_type"]:
                evaluator = Evaluator(
                    id=row["evaluator_id"],
                    type=EvaluatorType(row["eval_type"]),
                    display_name=row["display_name"],
                    provider=row["provider"],
                    model_name=row["model_name"],
                    temperature=row["eval_temp"],
                    max_tokens=row["eval_max"],
                    top_p=row["top_p"],
                    top_k=row["top_k"],
                )

            return ScoredDocument(
                document=doc,
                score=row["score"],
                explanation=row["explanation"],
                evaluator_id=row["evaluator_id"],
                evaluator=evaluator,
                latency_ms=row["latency_ms"],
                tokens_input=row["tokens_input"],
                tokens_output=row["tokens_output"],
                cost_usd=row["cost_usd"],
                scored_at=row["scored_at"],
            )

    def get_scores_for_document(
        self,
        document_id: str,
        checkpoint_id: Optional[str] = None,
    ) -> list[ScoredDocument]:
        """
        Get all scores for a document (from different evaluators).

        Args:
            document_id: Document ID
            checkpoint_id: Optional checkpoint ID filter

        Returns:
            List of ScoredDocuments from different evaluators
        """
        query = """
            SELECT sd.*, e.type as eval_type, e.display_name, e.provider,
                   e.model_name, e.temperature as eval_temp, e.max_tokens as eval_max,
                   e.top_p, e.top_k
            FROM scored_documents sd
            LEFT JOIN evaluators e ON sd.evaluator_id = e.id
            WHERE sd.document_id = ?
        """
        params: list[Any] = [document_id]

        if checkpoint_id is not None:
            query += " AND sd.checkpoint_id = ?"
            params.append(checkpoint_id)

        query += " ORDER BY sd.scored_at DESC"

        # Get the document once
        doc = self.get_document(document_id)
        if not doc:
            return []

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)

            results = []
            for row in cursor:
                evaluator = None
                if row["evaluator_id"] and row["eval_type"]:
                    evaluator = Evaluator(
                        id=row["evaluator_id"],
                        type=EvaluatorType(row["eval_type"]),
                        display_name=row["display_name"],
                        provider=row["provider"],
                        model_name=row["model_name"],
                        temperature=row["eval_temp"],
                        max_tokens=row["eval_max"],
                        top_p=row["top_p"],
                        top_k=row["top_k"],
                    )

                results.append(ScoredDocument(
                    document=doc,
                    score=row["score"],
                    explanation=row["explanation"],
                    evaluator_id=row["evaluator_id"],
                    evaluator=evaluator,
                    latency_ms=row["latency_ms"],
                    tokens_input=row["tokens_input"],
                    tokens_output=row["tokens_output"],
                    cost_usd=row["cost_usd"],
                    scored_at=row["scored_at"],
                ))

            return results

    # =========================================================================
    # Study Classification Operations
    # =========================================================================

    def save_study_classification(
        self,
        document_id: str,
        classification: "StudyClassification",
        evaluator_id: Optional[str] = None,
        latency_ms: Optional[int] = None,
        tokens_input: Optional[int] = None,
        tokens_output: Optional[int] = None,
        cost_usd: Optional[float] = None,
    ) -> str:
        """
        Save a study classification with evaluator tracking.

        Args:
            document_id: Document ID
            classification: StudyClassification from the classifier
            evaluator_id: Optional evaluator ID (for benchmarking)
            latency_ms: Optional latency in milliseconds
            tokens_input: Optional input token count
            tokens_output: Optional output token count
            cost_usd: Optional cost in USD

        Returns:
            Classification ID

        Raises:
            SQLiteError: If database operation fails
        """
        classification_id = str(uuid.uuid4())

        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT INTO study_classifications
                    (id, document_id, study_design, is_randomized, is_blinded,
                     sample_size, confidence, raw_response, evaluator_id,
                     latency_ms, tokens_input, tokens_output, cost_usd)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        classification_id,
                        document_id,
                        classification.study_design.value,
                        1 if classification.is_randomized else (0 if classification.is_randomized is False else None),
                        classification.is_blinded,
                        classification.sample_size,
                        classification.confidence,
                        classification.raw_response,
                        evaluator_id,
                        latency_ms,
                        tokens_input,
                        tokens_output,
                        cost_usd,
                    ),
                )
                conn.commit()

            logger.debug(
                f"Saved study classification {classification_id} for {document_id}: "
                f"{classification.study_design.value}"
            )
            return classification_id
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to save study classification: {e}") from e

    def get_study_classification(
        self,
        document_id: str,
        evaluator_id: Optional[str] = None,
    ) -> Optional["StudyClassification"]:
        """
        Get the most recent study classification for a document.

        Args:
            document_id: Document ID
            evaluator_id: Optional evaluator ID filter

        Returns:
            StudyClassification if found, None otherwise
        """
        from .quality.data_models import StudyClassification, StudyDesign

        query = """
            SELECT * FROM study_classifications
            WHERE document_id = ?
        """
        params: list[Any] = [document_id]

        if evaluator_id is not None:
            query += " AND evaluator_id = ?"
            params.append(evaluator_id)

        query += " ORDER BY classified_at DESC LIMIT 1"

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)
            row = cursor.fetchone()

            if not row:
                return None

            return StudyClassification(
                study_design=StudyDesign(row["study_design"]),
                is_randomized=bool(row["is_randomized"]) if row["is_randomized"] is not None else None,
                is_blinded=row["is_blinded"],
                sample_size=row["sample_size"],
                confidence=row["confidence"],
                raw_response=row["raw_response"],
            )

    def get_study_classification_by_evaluator(
        self,
        document_id: str,
        evaluator_id: str,
    ) -> Optional[dict[str, Any]]:
        """
        Get a study classification by document ID and evaluator ID.

        Returns full classification data including metrics for benchmarking.

        Args:
            document_id: Document ID
            evaluator_id: Evaluator ID

        Returns:
            Dictionary with classification data if found, None otherwise
        """
        query = """
            SELECT sc.*, e.type as eval_type, e.display_name, e.provider,
                   e.model_name, e.temperature as eval_temp
            FROM study_classifications sc
            LEFT JOIN evaluators e ON sc.evaluator_id = e.id
            WHERE sc.document_id = ? AND sc.evaluator_id = ?
            ORDER BY sc.classified_at DESC LIMIT 1
        """

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, (document_id, evaluator_id))
            row = cursor.fetchone()

            if not row:
                return None

            return dict(row)

    def get_study_classifications_for_document(
        self,
        document_id: str,
    ) -> list[dict[str, Any]]:
        """
        Get all study classifications for a document.

        Useful for comparing classifications from different evaluators.

        Args:
            document_id: Document ID

        Returns:
            List of classification dictionaries
        """
        query = """
            SELECT sc.*, e.type as eval_type, e.display_name, e.provider,
                   e.model_name
            FROM study_classifications sc
            LEFT JOIN evaluators e ON sc.evaluator_id = e.id
            WHERE sc.document_id = ?
            ORDER BY sc.classified_at DESC
        """

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, (document_id,))
            return [dict(row) for row in cursor]

    def delete_study_classifications_for_document(
        self,
        document_id: str,
        evaluator_id: Optional[str] = None,
    ) -> int:
        """
        Delete study classifications for a document.

        Args:
            document_id: Document ID
            evaluator_id: Optional evaluator ID filter

        Returns:
            Number of classifications deleted
        """
        query = "DELETE FROM study_classifications WHERE document_id = ?"
        params: list[Any] = [document_id]

        if evaluator_id is not None:
            query += " AND evaluator_id = ?"
            params.append(evaluator_id)

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)
            conn.commit()
            return cursor.rowcount

    # =========================================================================
    # Benchmark Run Operations
    # =========================================================================

    def create_benchmark_run(
        self,
        name: str,
        question: str,
        task_type: str,
        evaluator_ids: list[str],
        document_ids: list[str],
        description: Optional[str] = None,
    ) -> BenchmarkRun:
        """
        Create a new benchmark run.

        Args:
            name: Name for the benchmark
            question: Research question being evaluated
            task_type: Type of task (e.g., document_scoring)
            evaluator_ids: List of evaluator IDs to compare
            document_ids: List of document IDs to evaluate
            description: Optional description

        Returns:
            Created BenchmarkRun

        Raises:
            SQLiteError: If database operation fails
        """
        run_id = str(uuid.uuid4())
        now = datetime.now()
        total = len(evaluator_ids) * len(document_ids)
        question_hash = compute_question_hash(question)

        try:
            with self._sqlite_connection() as conn:
                conn.execute(
                    """
                    INSERT INTO benchmark_runs
                    (id, name, description, question, question_hash, task_type,
                     evaluator_ids, document_ids, status, progress_current,
                     progress_total, created_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    (
                        run_id,
                        name,
                        description,
                        question,
                        question_hash,
                        task_type,
                        json.dumps(evaluator_ids),
                        json.dumps(document_ids),
                        BenchmarkStatus.PENDING.value,
                        0,
                        total,
                        now,
                    ),
                )
                conn.commit()

            logger.info(f"Created benchmark run {run_id}")
            return BenchmarkRun(
                id=run_id,
                name=name,
                description=description,
                question=question,
                question_hash=question_hash,
                task_type=task_type,
                evaluator_ids=evaluator_ids,
                document_ids=document_ids,
                status=BenchmarkStatus.PENDING,
                progress_current=0,
                progress_total=total,
                created_at=now,
            )
        except sqlite3.Error as e:
            raise SQLiteError(f"Failed to create benchmark run: {e}") from e

    def get_benchmark_run(self, run_id: str) -> Optional[BenchmarkRun]:
        """
        Get a benchmark run by ID.

        Args:
            run_id: Benchmark run ID

        Returns:
            BenchmarkRun if found, None otherwise
        """
        with self._sqlite_connection() as conn:
            cursor = conn.execute(
                """
                SELECT id, name, description, question, question_hash, task_type,
                       evaluator_ids, document_ids, status, progress_current,
                       progress_total, error_message, results_summary, created_at,
                       started_at, completed_at
                FROM benchmark_runs
                WHERE id = ?
                """,
                (run_id,),
            )
            row = cursor.fetchone()

            if not row:
                return None

            return BenchmarkRun(
                id=row["id"],
                name=row["name"],
                description=row["description"],
                question=row["question"],
                question_hash=row["question_hash"],
                task_type=row["task_type"],
                evaluator_ids=json.loads(row["evaluator_ids"]),
                document_ids=json.loads(row["document_ids"]),
                status=BenchmarkStatus(row["status"]),
                progress_current=row["progress_current"],
                progress_total=row["progress_total"],
                error_message=row["error_message"],
                results_summary=row["results_summary"],
                created_at=row["created_at"],
                started_at=row["started_at"],
                completed_at=row["completed_at"],
            )

    def get_benchmark_runs(
        self,
        status: Optional[BenchmarkStatus] = None,
        task_type: Optional[str] = None,
        limit: int = 50,
    ) -> list[BenchmarkRun]:
        """
        Get benchmark runs with optional filtering.

        Args:
            status: Filter by status
            task_type: Filter by task type
            limit: Maximum number to return

        Returns:
            List of benchmark runs, most recent first
        """
        query = "SELECT * FROM benchmark_runs WHERE 1=1"
        params: list[Any] = []

        if status is not None:
            query += " AND status = ?"
            params.append(status.value)

        if task_type is not None:
            query += " AND task_type = ?"
            params.append(task_type)

        query += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)

            runs = []
            for row in cursor:
                runs.append(BenchmarkRun(
                    id=row["id"],
                    name=row["name"],
                    description=row["description"],
                    question=row["question"],
                    question_hash=row["question_hash"],
                    task_type=row["task_type"],
                    evaluator_ids=json.loads(row["evaluator_ids"]),
                    document_ids=json.loads(row["document_ids"]),
                    status=BenchmarkStatus(row["status"]),
                    progress_current=row["progress_current"],
                    progress_total=row["progress_total"],
                    error_message=row["error_message"],
                    results_summary=row["results_summary"],
                    created_at=row["created_at"],
                    started_at=row["started_at"],
                    completed_at=row["completed_at"],
                ))

            return runs

    def update_benchmark_run(
        self,
        run_id: str,
        status: Optional[BenchmarkStatus] = None,
        progress_current: Optional[int] = None,
        error_message: Optional[str] = None,
        results_summary: Optional[str] = None,
        started_at: Optional[datetime] = None,
        completed_at: Optional[datetime] = None,
    ) -> None:
        """
        Update a benchmark run.

        Args:
            run_id: Benchmark run ID
            status: New status
            progress_current: Current progress count
            error_message: Error message if failed
            results_summary: JSON results summary
            started_at: When execution started
            completed_at: When execution completed
        """
        updates = []
        values: list[Any] = []

        if status is not None:
            updates.append("status = ?")
            values.append(status.value)
        if progress_current is not None:
            updates.append("progress_current = ?")
            values.append(progress_current)
        if error_message is not None:
            updates.append("error_message = ?")
            values.append(error_message)
        if results_summary is not None:
            updates.append("results_summary = ?")
            values.append(results_summary)
        if started_at is not None:
            updates.append("started_at = ?")
            values.append(started_at)
        if completed_at is not None:
            updates.append("completed_at = ?")
            values.append(completed_at)

        if not updates:
            return

        values.append(run_id)

        with self._sqlite_connection() as conn:
            conn.execute(
                f"UPDATE benchmark_runs SET {', '.join(updates)} WHERE id = ?",
                values,
            )
            conn.commit()

    def delete_benchmark_run(self, run_id: str) -> bool:
        """
        Delete a benchmark run.

        Args:
            run_id: Benchmark run ID to delete

        Returns:
            True if deleted, False otherwise
        """
        with self._sqlite_connection() as conn:
            try:
                cursor = conn.execute(
                    "DELETE FROM benchmark_runs WHERE id = ?",
                    (run_id,),
                )
                conn.commit()
                return cursor.rowcount > 0
            except Exception as e:
                logger.error(f"Failed to delete benchmark run {run_id}: {e}")
                return False

    def get_benchmark_runs_by_question(
        self,
        question: str,
        status: Optional[BenchmarkStatus] = None,
        limit: int = 50,
    ) -> list[BenchmarkRun]:
        """
        Get benchmark runs for a specific research question.

        Uses normalized question hash for efficient and consistent lookup,
        handling minor variations in whitespace and capitalization.

        Args:
            question: Research question text
            status: Optional filter by status (e.g., COMPLETED)
            limit: Maximum number of runs to return

        Returns:
            List of matching benchmark runs, most recent first
        """
        question_hash = compute_question_hash(question)

        query = "SELECT * FROM benchmark_runs WHERE question_hash = ?"
        params: list[Any] = [question_hash]

        if status is not None:
            query += " AND status = ?"
            params.append(status.value)

        query += " ORDER BY created_at DESC LIMIT ?"
        params.append(limit)

        with self._sqlite_connection() as conn:
            cursor = conn.execute(query, params)

            runs = []
            for row in cursor:
                runs.append(BenchmarkRun(
                    id=row["id"],
                    name=row["name"],
                    description=row["description"],
                    question=row["question"],
                    question_hash=row["question_hash"],
                    task_type=row["task_type"],
                    evaluator_ids=json.loads(row["evaluator_ids"]),
                    document_ids=json.loads(row["document_ids"]),
                    status=BenchmarkStatus(row["status"]),
                    progress_current=row["progress_current"],
                    progress_total=row["progress_total"],
                    error_message=row["error_message"],
                    results_summary=row["results_summary"],
                    created_at=row["created_at"],
                    started_at=row["started_at"],
                    completed_at=row["completed_at"],
                ))

            return runs

    def get_all_scores_for_question(
        self,
        question: str,
        document_ids: Optional[list[str]] = None,
    ) -> dict[str, dict[str, ScoredDocument]]:
        """
        Get all benchmark scores for a research question across all runs.

        Aggregates scores from all completed benchmark runs for the
        given question. For documents scored multiple times by the
        same evaluator, returns the most recent score.

        Args:
            question: Research question text
            document_ids: Optional filter to specific documents

        Returns:
            Nested dict: evaluator_id -> document_id -> ScoredDocument
        """
        # Get all completed runs for this question
        runs = self.get_benchmark_runs_by_question(
            question, status=BenchmarkStatus.COMPLETED
        )

        if not runs:
            return {}

        # Collect all checkpoint IDs from these runs
        # Note: We need to find scored_documents associated with these runs
        # The scored_documents are linked via checkpoint_id, and we store
        # the evaluator_id with each score

        # Get all evaluator IDs across all runs
        all_evaluator_ids: set[str] = set()
        for run in runs:
            all_evaluator_ids.update(run.evaluator_ids)

        # Build document filter if provided
        doc_filter = set(document_ids) if document_ids else None

        # Query scored documents for each evaluator
        all_scores: dict[str, dict[str, ScoredDocument]] = {}

        for evaluator_id in all_evaluator_ids:
            evaluator = self.get_evaluator(evaluator_id)
            if not evaluator:
                continue

            all_scores[evaluator_id] = {}

            # Get all scores by this evaluator (most recent first)
            with self._sqlite_connection() as conn:
                query = """
                    SELECT DISTINCT sd.document_id, sd.score, sd.explanation,
                           sd.latency_ms, sd.tokens_input, sd.tokens_output,
                           sd.cost_usd, sd.scored_at
                    FROM scored_documents sd
                    WHERE sd.evaluator_id = ?
                    ORDER BY sd.scored_at DESC
                """
                cursor = conn.execute(query, (evaluator_id,))

                seen_docs: set[str] = set()
                for row in cursor:
                    doc_id = row["document_id"]

                    # Skip if we've already seen this doc (we want most recent)
                    if doc_id in seen_docs:
                        continue

                    # Skip if not in document filter
                    if doc_filter and doc_id not in doc_filter:
                        continue

                    seen_docs.add(doc_id)

                    # Get the full document
                    doc = self.get_document(doc_id)
                    if not doc:
                        continue

                    all_scores[evaluator_id][doc_id] = ScoredDocument(
                        document=doc,
                        score=row["score"],
                        explanation=row["explanation"],
                        evaluator_id=evaluator_id,
                        evaluator=evaluator,
                        latency_ms=row["latency_ms"],
                        tokens_input=row["tokens_input"],
                        tokens_output=row["tokens_output"],
                        cost_usd=row["cost_usd"],
                        scored_at=row["scored_at"],
                    )

        return all_scores

    def get_evaluators_for_question(
        self,
        question: str,
    ) -> list[Evaluator]:
        """
        Get all evaluators that have scored documents for a question.

        Args:
            question: Research question text

        Returns:
            List of Evaluator objects that have contributed scores
        """
        # Get all completed runs for this question
        runs = self.get_benchmark_runs_by_question(
            question, status=BenchmarkStatus.COMPLETED
        )

        if not runs:
            return []

        # Collect all unique evaluator IDs
        all_evaluator_ids: set[str] = set()
        for run in runs:
            all_evaluator_ids.update(run.evaluator_ids)

        # Fetch evaluator objects
        evaluators = []
        for evaluator_id in all_evaluator_ids:
            evaluator = self.get_evaluator(evaluator_id)
            if evaluator:
                evaluators.append(evaluator)

        return evaluators
