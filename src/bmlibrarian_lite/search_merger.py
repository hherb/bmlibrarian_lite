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

"""Search result merger for combining and deduplicating results from multiple providers.

When searching both PubMed and Europe PMC, the same article may appear in both
result sets. This module provides functionality to merge results and remove
duplicates while preserving the richest metadata from each source.

Deduplication priority:
    1. PMID match - Most reliable, uniquely identifies PubMed articles
    2. DOI match - Very reliable, cross-provider identifier
    3. PMC ID match - Reliable for open access articles
    4. Title similarity - Fallback using Jaccard similarity (threshold: 0.8)

Usage:
    from bmlibrarian_lite.search_merger import SearchResultMerger
    from bmlibrarian_lite.pubmed import ArticleMetadata
    from bmlibrarian_lite.europepmc import ArticleInfo

    merged = SearchResultMerger.merge(
        pubmed_results=pubmed_articles,
        europepmc_results=epmc_articles,
    )
"""

import logging
from dataclasses import dataclass, field

from .constants import (
    MIN_WORD_LENGTH_FOR_SIMILARITY,
    TITLE_HASH_LENGTH,
    TITLE_SIMILARITY_THRESHOLD,
)
from .data_models import DocumentSource, LiteDocument
from .europepmc import ArticleInfo
from .pubmed import ArticleMetadata

logger = logging.getLogger(__name__)


@dataclass
class MergedArticle:
    """A merged article combining data from multiple sources.

    When the same article is found in both PubMed and Europe PMC,
    this class combines the metadata, preferring more complete data.

    Attributes:
        pmid: PubMed ID
        pmcid: PubMed Central ID
        doi: Digital Object Identifier
        title: Article title
        abstract: Article abstract
        authors: List of author names
        journal: Journal name
        year: Publication year
        mesh_terms: MeSH terms (from PubMed)
        url: URL to article
        sources: Set of sources where this article was found
        is_preprint: Whether this is a preprint
        has_fulltext_xml: Whether JATS XML full text is available
    """

    pmid: str | None = None
    pmcid: str | None = None
    doi: str | None = None
    title: str = ""
    abstract: str = ""
    authors: list[str] = field(default_factory=list)
    journal: str | None = None
    year: int | None = None
    mesh_terms: list[str] = field(default_factory=list)
    url: str | None = None
    sources: set[str] = field(default_factory=set)
    is_preprint: bool = False
    has_fulltext_xml: bool = False

    @property
    def primary_source(self) -> DocumentSource:
        """Get the primary source for this article."""
        if "pubmed" in self.sources:
            return DocumentSource.PUBMED
        return DocumentSource.EUROPEPMC

    @property
    def document_id(self) -> str:
        """Generate a document ID for this article."""
        if self.pmid:
            return f"pmid-{self.pmid}"
        elif self.doi:
            # Sanitize DOI for use as ID
            safe_doi = self.doi.replace("/", "_").replace(":", "_")
            return f"doi-{safe_doi}"
        elif self.pmcid:
            return f"pmc-{self.pmcid}"
        else:
            # Fallback to title hash
            import hashlib
            title_hash = hashlib.md5(self.title.encode()).hexdigest()[:TITLE_HASH_LENGTH]
            return f"title-{title_hash}"

    def to_lite_document(self) -> LiteDocument:
        """Convert to LiteDocument for storage."""
        return LiteDocument(
            id=self.document_id,
            title=self.title,
            abstract=self.abstract,
            authors=self.authors,
            year=self.year,
            journal=self.journal,
            doi=self.doi,
            pmid=self.pmid,
            pmc_id=self.pmcid,
            url=self.url,
            mesh_terms=self.mesh_terms,
            source=self.primary_source,
            is_preprint=self.is_preprint,
            metadata={
                "sources": list(self.sources),
                "has_fulltext_xml": self.has_fulltext_xml,
            },
        )


class SearchResultMerger:
    """Merges and deduplicates search results from multiple providers.

    This class provides static methods for combining results from PubMed
    and Europe PMC while removing duplicates and preserving the best
    metadata from each source.
    """

    @staticmethod
    def merge(
        pubmed_results: list[ArticleMetadata],
        europepmc_results: list[ArticleInfo],
        prefer_pubmed: bool = True,
    ) -> list[MergedArticle]:
        """Merge results from PubMed and Europe PMC with deduplication.

        Articles are considered duplicates if they share:
        - The same PMID
        - The same DOI
        - The same PMC ID
        - Very similar titles (Jaccard similarity > 0.8)

        Args:
            pubmed_results: Articles from PubMed
            europepmc_results: Articles from Europe PMC
            prefer_pubmed: When merging duplicates, prefer PubMed metadata

        Returns:
            List of merged articles with duplicates removed
        """
        merged: list[MergedArticle] = []

        # Index for deduplication
        seen_pmids: set[str] = set()
        seen_dois: set[str] = set()
        seen_pmcids: set[str] = set()
        seen_titles: list[str] = []  # For fuzzy matching

        # Process PubMed results first if preferred
        first_batch = pubmed_results if prefer_pubmed else europepmc_results
        second_batch = europepmc_results if prefer_pubmed else pubmed_results
        first_source = "pubmed" if prefer_pubmed else "europepmc"
        second_source = "europepmc" if prefer_pubmed else "pubmed"

        # Process first batch
        for article in first_batch:
            merged_article = SearchResultMerger._convert_to_merged(
                article, first_source
            )
            if merged_article:
                # Track identifiers
                if merged_article.pmid:
                    seen_pmids.add(merged_article.pmid)
                if merged_article.doi:
                    seen_dois.add(merged_article.doi.lower())
                if merged_article.pmcid:
                    seen_pmcids.add(merged_article.pmcid)
                seen_titles.append(merged_article.title.lower())

                merged.append(merged_article)

        # Process second batch with deduplication
        duplicates_found = 0
        for article in second_batch:
            merged_article = SearchResultMerger._convert_to_merged(
                article, second_source
            )
            if not merged_article:
                continue

            # Check for duplicates
            is_duplicate = False
            existing_idx = None

            # Check PMID
            if merged_article.pmid and merged_article.pmid in seen_pmids:
                is_duplicate = True
                existing_idx = SearchResultMerger._find_by_pmid(
                    merged, merged_article.pmid
                )

            # Check DOI
            elif merged_article.doi and merged_article.doi.lower() in seen_dois:
                is_duplicate = True
                existing_idx = SearchResultMerger._find_by_doi(
                    merged, merged_article.doi
                )

            # Check PMC ID
            elif merged_article.pmcid and merged_article.pmcid in seen_pmcids:
                is_duplicate = True
                existing_idx = SearchResultMerger._find_by_pmcid(
                    merged, merged_article.pmcid
                )

            # Check title similarity
            else:
                for idx, seen_title in enumerate(seen_titles):
                    similarity = SearchResultMerger._title_similarity(
                        merged_article.title.lower(), seen_title
                    )
                    if similarity >= TITLE_SIMILARITY_THRESHOLD:
                        is_duplicate = True
                        existing_idx = idx
                        break

            if is_duplicate:
                duplicates_found += 1
                if existing_idx is not None:
                    # Merge metadata from second source into existing
                    SearchResultMerger._merge_metadata(
                        merged[existing_idx], merged_article
                    )
            else:
                # Track new identifiers
                if merged_article.pmid:
                    seen_pmids.add(merged_article.pmid)
                if merged_article.doi:
                    seen_dois.add(merged_article.doi.lower())
                if merged_article.pmcid:
                    seen_pmcids.add(merged_article.pmcid)
                seen_titles.append(merged_article.title.lower())

                merged.append(merged_article)

        logger.info(
            f"Merged {len(pubmed_results)} PubMed + {len(europepmc_results)} Europe PMC "
            f"-> {len(merged)} unique articles ({duplicates_found} duplicates removed)"
        )

        return merged

    @staticmethod
    def _convert_to_merged(
        article: ArticleMetadata | ArticleInfo,
        source: str,
    ) -> MergedArticle | None:
        """Convert an article from either source to MergedArticle."""
        try:
            if isinstance(article, ArticleMetadata):
                # PubMed article
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
                    sources={source},
                    is_preprint=False,
                    has_fulltext_xml=False,
                )
            else:
                # Europe PMC article
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
                    sources={source},
                    is_preprint=article.is_preprint,
                    has_fulltext_xml=article.has_fulltext_xml,
                )
        except Exception as e:
            logger.warning(f"Failed to convert article: {e}")
            return None

    @staticmethod
    def _merge_metadata(existing: MergedArticle, new: MergedArticle) -> None:
        """Merge metadata from new article into existing, filling gaps."""
        existing.sources.update(new.sources)

        # Fill in missing identifiers
        if not existing.pmid and new.pmid:
            existing.pmid = new.pmid
        if not existing.pmcid and new.pmcid:
            existing.pmcid = new.pmcid
        if not existing.doi and new.doi:
            existing.doi = new.doi

        # Fill in missing metadata
        if not existing.abstract and new.abstract:
            existing.abstract = new.abstract
        if not existing.authors and new.authors:
            existing.authors = new.authors
        if not existing.journal and new.journal:
            existing.journal = new.journal
        if not existing.year and new.year:
            existing.year = new.year
        if not existing.url and new.url:
            existing.url = new.url

        # Merge MeSH terms (combine unique)
        if new.mesh_terms:
            existing_terms = set(existing.mesh_terms)
            for term in new.mesh_terms:
                if term not in existing_terms:
                    existing.mesh_terms.append(term)

        # Update flags
        existing.has_fulltext_xml = existing.has_fulltext_xml or new.has_fulltext_xml

    @staticmethod
    def _title_similarity(title1: str, title2: str) -> float:
        """Calculate Jaccard similarity between two titles.

        Uses word-level Jaccard index to compare titles.
        Ignores common words and punctuation.

        Args:
            title1: First title (lowercase)
            title2: Second title (lowercase)

        Returns:
            Similarity score between 0.0 and 1.0
        """
        # Simple word tokenization
        words1 = set(title1.split())
        words2 = set(title2.split())

        # Remove common words and short words
        stop_words = {"a", "an", "the", "of", "in", "on", "for", "to", "and", "or", "is", "are", "with"}
        words1 = {w for w in words1 if w not in stop_words and len(w) > MIN_WORD_LENGTH_FOR_SIMILARITY}
        words2 = {w for w in words2 if w not in stop_words and len(w) > MIN_WORD_LENGTH_FOR_SIMILARITY}

        if not words1 or not words2:
            return 0.0

        intersection = words1 & words2
        union = words1 | words2

        return len(intersection) / len(union) if union else 0.0

    @staticmethod
    def _find_by_pmid(articles: list[MergedArticle], pmid: str) -> int | None:
        """Find article index by PMID."""
        for idx, article in enumerate(articles):
            if article.pmid == pmid:
                return idx
        return None

    @staticmethod
    def _find_by_doi(articles: list[MergedArticle], doi: str) -> int | None:
        """Find article index by DOI."""
        doi_lower = doi.lower()
        for idx, article in enumerate(articles):
            if article.doi and article.doi.lower() == doi_lower:
                return idx
        return None

    @staticmethod
    def _find_by_pmcid(articles: list[MergedArticle], pmcid: str) -> int | None:
        """Find article index by PMC ID."""
        for idx, article in enumerate(articles):
            if article.pmcid == pmcid:
                return idx
        return None

    @staticmethod
    def to_lite_documents(merged_articles: list[MergedArticle]) -> list[LiteDocument]:
        """Convert merged articles to LiteDocuments.

        Convenience method for converting merger output to storage format.

        Args:
            merged_articles: List of MergedArticle objects

        Returns:
            List of LiteDocument objects ready for storage
        """
        return [article.to_lite_document() for article in merged_articles]
