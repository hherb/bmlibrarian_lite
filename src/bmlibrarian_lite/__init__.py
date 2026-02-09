# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

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

__version__ = "0.3.0"


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
