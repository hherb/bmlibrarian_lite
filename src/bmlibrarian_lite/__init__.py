"""
BMLibrarian Lite - Lightweight biomedical literature research tool.

A simplified interface for:
- Systematic literature review (search, score, extract, report)
- Document interrogation (Q&A with loaded documents)

Features:
- SQLite with sqlite-vec for storage and vector search
- FastEmbed for local embeddings (CPU-optimized, no PyTorch)
- Anthropic Claude or Ollama for LLM inference
- NCBI E-utilities for PubMed search (online)
- Europe PMC REST API for alternative search and full-text retrieval

No PostgreSQL or external databases required.
"""

from .config import LiteConfig
from .storage import LiteStorage
from .embeddings import LiteEmbedder
from .data_models import (
    LiteDocument,
    LiteChunk,
    SearchSession,
    ReviewCheckpoint,
    ScoredDocument,
    Citation,
    InterrogationSession,
    SearchProvider,
    CursorPaginationState,
    OffsetPaginationState,
)
from .exceptions import (
    LiteError,
    ConfigurationError,
    LiteStorageError,
    EmbeddingError,
    LLMError,
)
from .pdf_discovery import PDFDiscoverer, PDFSource, DiscoveryResult, close_browser_session
from .search_service import SearchService, UnifiedSearchResult
from .query_translator import QueryTranslator
from .search_merger import SearchResultMerger, MergedArticle

__version__ = "0.2.0"


def main() -> int:
    """
    Main entry point for BMLibrarian Lite.

    This is a convenience wrapper that imports and calls the main function
    from the CLI module.

    Returns:
        Application exit code
    """
    from .cli import main as cli_main
    return cli_main()


__all__ = [
    # Configuration
    "LiteConfig",
    # Storage
    "LiteStorage",
    "LiteEmbedder",
    # Data models
    "LiteDocument",
    "LiteChunk",
    "SearchSession",
    "ReviewCheckpoint",
    "ScoredDocument",
    "Citation",
    "InterrogationSession",
    "SearchProvider",
    "CursorPaginationState",
    "OffsetPaginationState",
    # Search
    "SearchService",
    "UnifiedSearchResult",
    "QueryTranslator",
    "SearchResultMerger",
    "MergedArticle",
    # PDF Discovery
    "PDFDiscoverer",
    "PDFSource",
    "DiscoveryResult",
    "close_browser_session",
    # Exceptions
    "LiteError",
    "ConfigurationError",
    "LiteStorageError",
    "EmbeddingError",
    "LLMError",
    # Version
    "__version__",
]
