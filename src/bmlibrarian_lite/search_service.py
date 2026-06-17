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

"""Unified search service for literature retrieval.

This module provides a unified interface for searching across multiple
literature databases (PubMed and Europe PMC). It handles:
- Provider selection based on configuration
- Query translation between provider syntaxes
- Result merging and deduplication for combined searches
- Progress reporting during searches

Usage:
    from bmlibrarian_lite.search_service import SearchService
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.data_models import SearchProvider

    config = LiteConfig.load()
    service = SearchService(config)

    # Search with configured provider
    result = service.search("diabetes treatment", max_results=50)

    # Search specific provider
    result = service.search(
        "diabetes treatment",
        provider=SearchProvider.EUROPEPMC,
        max_results=50,
    )
"""

import logging
from collections.abc import Callable
from dataclasses import dataclass, field

from .config import LiteConfig
from .data_models import (
    CursorPaginationState,
    LiteDocument,
    OffsetPaginationState,
    SearchProvider,
)
from .europepmc import ArticleInfo, EuropePMCClient
from .pubmed import ArticleMetadata, PubMedQuery, PubMedSearchClient
from .query_translator import QueryTranslator
from .search_merger import MergedArticle, SearchResultMerger

logger = logging.getLogger(__name__)


@dataclass
class UnifiedSearchResult:
    """Result from a unified search operation.

    Contains the search results along with metadata about the search
    including which provider(s) were used and pagination state.

    Attributes:
        articles: List of merged articles
        documents: Articles converted to LiteDocument format
        total_count: Total number of results available
        fetched_count: Number of results actually fetched
        provider: Provider(s) used for this search
        pubmed_count: Number of results from PubMed (if applicable)
        europepmc_count: Number of results from Europe PMC (if applicable)
        duplicates_removed: Number of duplicates removed in merge
        pagination: Pagination state for continuation
    """

    articles: list[MergedArticle] = field(default_factory=list)
    documents: list[LiteDocument] = field(default_factory=list)
    total_count: int = 0
    fetched_count: int = 0
    provider: SearchProvider = SearchProvider.PUBMED
    pubmed_count: int = 0
    europepmc_count: int = 0
    duplicates_removed: int = 0
    pagination: CursorPaginationState | OffsetPaginationState | None = None


class SearchService:
    """Unified service for searching literature databases.

    Provides a single interface for searching PubMed and/or Europe PMC,
    handling query translation and result merging automatically.

    Attributes:
        config: Application configuration
    """

    def __init__(self, config: LiteConfig) -> None:
        """Initialize the search service.

        Args:
            config: Application configuration
        """
        self.config = config

        # Initialize clients lazily
        self._pubmed_client: PubMedSearchClient | None = None
        self._europepmc_client: EuropePMCClient | None = None

    @property
    def pubmed_client(self) -> PubMedSearchClient:
        """Get or create the PubMed client."""
        if self._pubmed_client is None:
            self._pubmed_client = PubMedSearchClient(
                email=self.config.pubmed.email or "",
                api_key=self.config.pubmed.api_key,
            )
        return self._pubmed_client

    @property
    def europepmc_client(self) -> EuropePMCClient:
        """Get or create the Europe PMC client."""
        if self._europepmc_client is None:
            self._europepmc_client = EuropePMCClient()
        return self._europepmc_client

    def search(
        self,
        query: str,
        max_results: int | None = None,
        provider: SearchProvider | None = None,
        include_preprints: bool | None = None,
        progress_callback: Callable[[str], None] | None = None,
    ) -> UnifiedSearchResult:
        """Search for articles using the specified or configured provider.

        Automatically translates query syntax if needed and merges results
        when searching both providers.

        Args:
            query: Search query (in PubMed or Europe PMC syntax)
            max_results: Maximum results to return (uses config default if None)
            provider: Provider to use (uses config default if None)
            include_preprints: Whether to include preprints (Europe PMC only)
            progress_callback: Optional callback for progress updates

        Returns:
            UnifiedSearchResult with articles and metadata
        """
        max_results = max_results or self.config.search.max_results
        provider = provider or self.config.search.search_provider
        include_preprints = (
            include_preprints
            if include_preprints is not None
            else self.config.europepmc.include_preprints
        )

        logger.info(f"Searching with provider: {provider.value}, max_results: {max_results}")

        if provider == SearchProvider.PUBMED:
            return self._search_pubmed(query, max_results, progress_callback)
        elif provider == SearchProvider.EUROPEPMC:
            return self._search_europepmc(
                query, max_results, include_preprints, progress_callback
            )
        else:  # BOTH
            return self._search_both(
                query, max_results, include_preprints, progress_callback
            )

    def _search_pubmed(
        self,
        query: str,
        max_results: int,
        progress_callback: Callable[[str], None] | None = None,
    ) -> UnifiedSearchResult:
        """Search PubMed only."""
        if progress_callback:
            progress_callback("Searching PubMed...")

        # Translate query if needed
        if QueryTranslator.is_europepmc_syntax(query):
            pubmed_query = QueryTranslator.europepmc_to_pubmed(query)
            logger.debug(f"Translated Europe PMC query to PubMed: {query} -> {pubmed_query}")
        else:
            pubmed_query = query

        # Create PubMed query object
        query_obj = PubMedQuery(
            original_question=query,
            query_string=pubmed_query,
        )

        # Execute search
        search_result = self.pubmed_client.search(query_obj, max_results=max_results)

        if progress_callback:
            progress_callback(f"Found {search_result.total_count} results, fetching details...")

        # Fetch article details
        articles: list[ArticleMetadata] = []
        if search_result.pmids:
            articles = self.pubmed_client.fetch_articles(search_result.pmids)

        # Convert to merged articles
        merged = [
            self._pubmed_to_merged(article)
            for article in articles
            if article.abstract  # Skip articles without abstracts
        ]

        # Create pagination state
        pagination = OffsetPaginationState(
            total_count=search_result.total_count,
            offset=0,
            batch_size=len(articles),
        )

        return UnifiedSearchResult(
            articles=merged,
            documents=[a.to_lite_document() for a in merged],
            total_count=search_result.total_count,
            fetched_count=len(merged),
            provider=SearchProvider.PUBMED,
            pubmed_count=len(merged),
            europepmc_count=0,
            duplicates_removed=0,
            pagination=pagination,
        )

    def _search_europepmc(
        self,
        query: str,
        max_results: int,
        include_preprints: bool = False,
        progress_callback: Callable[[str], None] | None = None,
    ) -> UnifiedSearchResult:
        """Search Europe PMC only."""
        if progress_callback:
            progress_callback("Searching Europe PMC...")

        # Translate query if needed
        if QueryTranslator.is_pubmed_syntax(query):
            epmc_query = QueryTranslator.pubmed_to_europepmc(query)
            logger.debug(f"Translated PubMed query to Europe PMC: {query} -> {epmc_query}")
        else:
            epmc_query = query

        # Execute search
        articles, pagination = self.europepmc_client.search(
            query=epmc_query,
            max_results=max_results,
            include_preprints=include_preprints,
            page_size=self.config.europepmc.page_size,
        )

        if progress_callback:
            progress_callback(f"Found {pagination.total_count} results")

        # Filter out articles without abstracts
        articles_with_abstract = [a for a in articles if a.abstract]

        # Convert to merged articles
        merged = [self._europepmc_to_merged(article) for article in articles_with_abstract]

        return UnifiedSearchResult(
            articles=merged,
            documents=[a.to_lite_document() for a in merged],
            total_count=pagination.total_count,
            fetched_count=len(merged),
            provider=SearchProvider.EUROPEPMC,
            pubmed_count=0,
            europepmc_count=len(merged),
            duplicates_removed=0,
            pagination=pagination,
        )

    def _search_both(
        self,
        query: str,
        max_results: int,
        include_preprints: bool = False,
        progress_callback: Callable[[str], None] | None = None,
    ) -> UnifiedSearchResult:
        """Search both PubMed and Europe PMC, merging results."""
        # Prepare queries for both providers
        if QueryTranslator.is_pubmed_syntax(query):
            pubmed_query = query
            epmc_query = QueryTranslator.pubmed_to_europepmc(query)
        elif QueryTranslator.is_europepmc_syntax(query):
            epmc_query = query
            pubmed_query = QueryTranslator.europepmc_to_pubmed(query)
        else:
            # Neutral query, use as-is
            pubmed_query = query
            epmc_query = query

        # Search PubMed
        if progress_callback:
            progress_callback("Searching PubMed...")

        pubmed_query_obj = PubMedQuery(
            original_question=query,
            query_string=pubmed_query,
        )

        # Get more results from each provider to account for duplicates
        per_provider_max = max_results  # Request full amount from each

        pubmed_result = self.pubmed_client.search(pubmed_query_obj, max_results=per_provider_max)
        pubmed_articles: list[ArticleMetadata] = []
        if pubmed_result.pmids:
            pubmed_articles = self.pubmed_client.fetch_articles(pubmed_result.pmids)

        # Search Europe PMC
        if progress_callback:
            progress_callback("Searching Europe PMC...")

        epmc_articles, epmc_pagination = self.europepmc_client.search(
            query=epmc_query,
            max_results=per_provider_max,
            include_preprints=include_preprints,
            page_size=self.config.europepmc.page_size,
        )

        if progress_callback:
            progress_callback("Merging results...")

        # Merge and deduplicate
        merged = SearchResultMerger.merge(
            pubmed_results=pubmed_articles,
            europepmc_results=epmc_articles,
            prefer_pubmed=True,
        )

        # Calculate duplicates removed (before any abstract filtering so this
        # count reflects genuine cross-provider deduplication only).
        total_before_merge = len(pubmed_articles) + len(epmc_articles)
        duplicates_removed = total_before_merge - len(merged)

        # Drop articles without an abstract, matching the single-provider
        # search paths (_search_pubmed / _search_europepmc). Downstream scoring
        # and citation extraction operate on the abstract, so abstract-less
        # documents would otherwise be stored and scored on empty text in
        # "Both" mode only.
        merged = [m for m in merged if m.abstract]

        # Limit to max_results
        if len(merged) > max_results:
            merged = merged[:max_results]

        # Estimate total available
        total_available = pubmed_result.total_count + epmc_pagination.total_count

        return UnifiedSearchResult(
            articles=merged,
            documents=[a.to_lite_document() for a in merged],
            total_count=total_available,
            fetched_count=len(merged),
            provider=SearchProvider.BOTH,
            pubmed_count=len(pubmed_articles),
            europepmc_count=len(epmc_articles),
            duplicates_removed=duplicates_removed,
            pagination=None,  # Combined search doesn't support continuation
        )

    def get_total_count(
        self,
        query: str,
        provider: SearchProvider | None = None,
        include_preprints: bool = False,
    ) -> int:
        """Get total count of results without fetching articles.

        Useful for displaying estimated result counts before searching.

        Args:
            query: Search query
            provider: Provider to use (uses config default if None)
            include_preprints: Whether to include preprints

        Returns:
            Total number of matching articles
        """
        provider = provider or self.config.search.search_provider

        if provider == SearchProvider.PUBMED:
            if QueryTranslator.is_europepmc_syntax(query):
                query = QueryTranslator.europepmc_to_pubmed(query)
            query_obj = PubMedQuery(original_question=query, query_string=query)
            return self.pubmed_client.get_count(query_obj)

        elif provider == SearchProvider.EUROPEPMC:
            if QueryTranslator.is_pubmed_syntax(query):
                query = QueryTranslator.pubmed_to_europepmc(query)
            return self.europepmc_client.get_total_count(query, include_preprints)

        else:  # BOTH
            pubmed_query = query
            epmc_query = query

            if QueryTranslator.is_pubmed_syntax(query):
                epmc_query = QueryTranslator.pubmed_to_europepmc(query)
            elif QueryTranslator.is_europepmc_syntax(query):
                pubmed_query = QueryTranslator.europepmc_to_pubmed(query)

            pubmed_query_obj = PubMedQuery(
                original_question=pubmed_query, query_string=pubmed_query
            )
            pubmed_count = self.pubmed_client.get_count(pubmed_query_obj)
            epmc_count = self.europepmc_client.get_total_count(epmc_query, include_preprints)

            # This is an upper bound; actual unique count will be lower due to duplicates
            return pubmed_count + epmc_count

    def _pubmed_to_merged(self, article: ArticleMetadata) -> MergedArticle:
        """Convert PubMed article to MergedArticle."""
        year = None
        if article.publication_date:
            try:
                year = int(article.publication_date[:4])
            except (ValueError, TypeError):
                pass

        return MergedArticle(
            pmid=article.pmid,
            pmcid=article.pmc_id,
            doi=article.doi,
            title=article.title,
            abstract=article.abstract or "",
            authors=article.authors or [],
            journal=article.publication,
            year=year,
            mesh_terms=article.mesh_terms or [],
            url=article.url,
            sources={"pubmed"},
            is_preprint=False,
            has_fulltext_xml=False,
        )

    def _europepmc_to_merged(self, article: ArticleInfo) -> MergedArticle:
        """Convert Europe PMC article to MergedArticle."""
        return MergedArticle(
            pmid=article.pmid,
            pmcid=article.pmcid,
            doi=article.doi,
            title=article.title,
            abstract=article.abstract or "",
            authors=article.authors or [],
            journal=article.journal,
            year=article.year,
            mesh_terms=[],
            url=None,
            sources={"europepmc"},
            is_preprint=article.is_preprint,
            has_fulltext_xml=article.has_fulltext_xml,
        )
