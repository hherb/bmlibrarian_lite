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
)
from .exceptions import (
    LiteError,
    ConfigurationError,
    LiteStorageError,
    EmbeddingError,
    LLMError,
)
from .pdf_discovery import PDFDiscoverer, PDFSource, DiscoveryResult, close_browser_session

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
