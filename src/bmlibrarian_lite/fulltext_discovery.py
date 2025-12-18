"""
Full-text discovery module for BMLibrarian Lite.

Provides unified full-text retrieval that tries multiple sources:
1. Cached full-text markdown (fastest)
2. Europe PMC XML full-text (best quality, machine-readable)
3. Cached PDF
4. PDF download via traditional sources

Usage:
    from bmlibrarian_lite.fulltext_discovery import FulltextDiscoverer

    discoverer = FulltextDiscoverer(unpaywall_email="user@example.com")
    result = discoverer.discover_fulltext(
        pmid="39521399",
        doi="10.1053/j.ajkd.2024.08.012",
    )

    if result.success:
        print(f"Source: {result.source_type}")
        print(f"Content: {result.markdown_content[:200]}...")
"""

import logging
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from .europepmc import EuropePMCClient, ArticleInfo
from .pdf_utils import (
    find_existing_fulltext,
    find_existing_pdf,
    generate_fulltext_path,
    generate_pdf_path,
    get_fulltext_base_dir,
    get_pdf_base_dir,
    save_fulltext_markdown,
    extract_pdf_text,
)
from .pdf_discovery import PDFDiscoverer, DiscoveryResult as PDFDiscoveryResult

logger = logging.getLogger(__name__)


class FulltextSourceType(Enum):
    """Source type for full-text content."""

    CACHED_FULLTEXT = "cached_fulltext"  # Previously cached markdown
    EUROPEPMC_XML = "europepmc_xml"  # Fresh from Europe PMC XML API
    CACHED_PDF = "cached_pdf"  # Previously cached PDF
    DOWNLOADED_PDF = "downloaded_pdf"  # Freshly downloaded PDF
    ABSTRACT_ONLY = "abstract_only"  # Only abstract available
    NOT_FOUND = "not_found"


@dataclass
class FulltextResult:
    """Result of full-text discovery attempt."""

    success: bool
    source_type: FulltextSourceType
    markdown_content: Optional[str] = None
    file_path: Optional[Path] = None
    article_info: Optional[ArticleInfo] = None
    error: Optional[str] = None
    is_paywall: bool = False
    paywall_url: Optional[str] = None


class FulltextDiscoverer:
    """
    Discovers and retrieves full-text content from multiple sources.

    Prioritizes machine-readable XML from Europe PMC over PDF downloads.

    Attributes:
        unpaywall_email: Email for Unpaywall API
        openathens_url: OpenAthens institution URL
        progress_callback: Callback for progress updates
    """

    def __init__(
        self,
        unpaywall_email: Optional[str] = None,
        openathens_url: Optional[str] = None,
        progress_callback: Optional[Callable[[str, str], None]] = None,
        use_browser_fallback: bool = True,
        browser_headless: bool = False,
    ) -> None:
        """
        Initialize full-text discoverer.

        Args:
            unpaywall_email: Email for Unpaywall API
            openathens_url: OpenAthens institution URL
            progress_callback: Callback for progress updates (stage, status)
            use_browser_fallback: If True, use browser for bot-protected downloads
            browser_headless: If True, run browser without visible window
        """
        self.unpaywall_email = unpaywall_email
        self.openathens_url = openathens_url
        self.progress_callback = progress_callback
        self.use_browser_fallback = use_browser_fallback
        self.browser_headless = browser_headless

        self._europepmc = EuropePMCClient()
        self._cancelled = False

    def _emit_progress(self, stage: str, status: str) -> None:
        """Emit progress update."""
        if self.progress_callback:
            self.progress_callback(stage, status)

    def cancel(self) -> None:
        """Cancel the current operation."""
        self._cancelled = True

    def discover_fulltext(
        self,
        doc_dict: Optional[Dict[str, Any]] = None,
        pmid: Optional[str] = None,
        pmcid: Optional[str] = None,
        doi: Optional[str] = None,
        title: Optional[str] = None,
        year: Optional[int] = None,
        skip_pdf: bool = False,
    ) -> FulltextResult:
        """
        Discover and retrieve full-text content for a document.

        Tries sources in order of preference:
        1. Cached full-text markdown
        2. Europe PMC XML (converted to markdown)
        3. Cached PDF (extracted to text)
        4. PDF download (if not skip_pdf)

        Args:
            doc_dict: Document dictionary with identifiers
            pmid: PubMed ID
            pmcid: PubMed Central ID
            doi: Digital Object Identifier
            title: Document title for verification
            year: Publication year
            skip_pdf: If True, don't attempt PDF download

        Returns:
            FulltextResult with content and source information
        """
        self._cancelled = False

        # Build doc_dict from individual params if not provided
        if doc_dict is None:
            doc_dict = {}
        if pmid:
            doc_dict['pmid'] = pmid
        if pmcid:
            doc_dict['pmcid'] = pmcid
        if doi:
            doc_dict['doi'] = doi
        if title:
            doc_dict['title'] = title
        if year:
            doc_dict['year'] = year

        # Extract identifiers
        pmid = doc_dict.get('pmid')
        pmcid = doc_dict.get('pmcid') or doc_dict.get('pmc_id')
        doi = doc_dict.get('doi')
        title = doc_dict.get('title')

        logger.info(f"Full-text discovery: pmid={pmid}, pmcid={pmcid}, doi={doi}")

        # 1. Check for cached full-text markdown
        self._emit_progress("discovery", "checking_cache")
        cached_fulltext = find_existing_fulltext(doc_dict)
        if cached_fulltext:
            logger.info(f"Found cached full-text: {cached_fulltext}")
            try:
                content = cached_fulltext.read_text(encoding='utf-8')
                return FulltextResult(
                    success=True,
                    source_type=FulltextSourceType.CACHED_FULLTEXT,
                    markdown_content=content,
                    file_path=cached_fulltext,
                )
            except Exception as e:
                logger.warning(f"Failed to read cached full-text: {e}")

        if self._cancelled:
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="Cancelled",
            )

        # 2. Try Europe PMC XML
        self._emit_progress("discovery", "checking_europepmc")
        result = self._try_europepmc_xml(doc_dict, pmid, pmcid, doi)
        if result.success:
            return result

        if self._cancelled:
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="Cancelled",
            )

        # 3. Check for cached PDF
        self._emit_progress("discovery", "checking_pdf_cache")
        cached_pdf = find_existing_pdf(doc_dict)
        if cached_pdf:
            logger.info(f"Found cached PDF: {cached_pdf}")
            try:
                text = extract_pdf_text(cached_pdf)
                if text.strip():
                    return FulltextResult(
                        success=True,
                        source_type=FulltextSourceType.CACHED_PDF,
                        markdown_content=text,
                        file_path=cached_pdf,
                    )
            except Exception as e:
                logger.warning(f"Failed to extract text from cached PDF: {e}")

        if self._cancelled or skip_pdf:
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error="Cancelled" if self._cancelled else "No full-text available (PDF download skipped)",
            )

        # 4. Try PDF download as last resort
        self._emit_progress("discovery", "downloading_pdf")
        return self._try_pdf_download(doc_dict, pmid, pmcid, doi, title)

    def _try_europepmc_xml(
        self,
        doc_dict: Dict[str, Any],
        pmid: Optional[str],
        pmcid: Optional[str],
        doi: Optional[str],
    ) -> FulltextResult:
        """Try to get full-text from Europe PMC XML API."""
        try:
            # First check if article is in Europe PMC
            info = self._europepmc.get_article_info(pmid=pmid, pmcid=pmcid, doi=doi)

            if not info:
                logger.debug("Article not found in Europe PMC")
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_FOUND,
                    error="Article not found in Europe PMC",
                )

            # Update doc_dict with info from Europe PMC
            if info.pmcid and not pmcid:
                doc_dict['pmcid'] = info.pmcid
                pmcid = info.pmcid
            if info.year and not doc_dict.get('year'):
                doc_dict['year'] = info.year

            if not info.has_fulltext_xml:
                logger.debug(f"No full-text XML available for {info.pmcid or info.pmid}")
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_FOUND,
                    article_info=info,
                    error="Full-text XML not available in Europe PMC",
                )

            # Get full-text XML
            self._emit_progress("download", "fetching_xml")
            xml_content = self._europepmc.get_fulltext_xml(pmcid=info.pmcid)

            if not xml_content:
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_FOUND,
                    article_info=info,
                    error="Failed to retrieve full-text XML",
                )

            # Convert to markdown
            self._emit_progress("download", "converting")
            markdown_content = self._europepmc.xml_to_markdown(xml_content)

            if not markdown_content.strip():
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_FOUND,
                    article_info=info,
                    error="Failed to convert XML to markdown",
                )

            # Save to cache
            cache_path = save_fulltext_markdown(doc_dict, markdown_content)

            logger.info(f"Successfully retrieved full-text from Europe PMC: {info.pmcid}")
            return FulltextResult(
                success=True,
                source_type=FulltextSourceType.EUROPEPMC_XML,
                markdown_content=markdown_content,
                file_path=cache_path,
                article_info=info,
            )

        except Exception as e:
            logger.warning(f"Europe PMC XML retrieval failed: {e}")
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error=f"Europe PMC error: {e}",
            )

    def _try_pdf_download(
        self,
        doc_dict: Dict[str, Any],
        pmid: Optional[str],
        pmcid: Optional[str],
        doi: Optional[str],
        title: Optional[str],
    ) -> FulltextResult:
        """Try to download PDF as last resort."""
        try:
            pdf_path = generate_pdf_path(doc_dict)

            pdf_discoverer = PDFDiscoverer(
                unpaywall_email=self.unpaywall_email,
                openathens_url=self.openathens_url,
                progress_callback=self.progress_callback,
                use_browser_fallback=self.use_browser_fallback,
                browser_headless=self.browser_headless,
            )

            pdf_result = pdf_discoverer.discover_and_download(
                output_path=pdf_path,
                doi=doi,
                pmid=pmid,
                pmcid=pmcid,
                title=title,
                expected_title=title,
            )

            if pdf_result.success and pdf_result.file_path:
                # Extract text from downloaded PDF
                try:
                    text = extract_pdf_text(pdf_result.file_path)
                    if text.strip():
                        return FulltextResult(
                            success=True,
                            source_type=FulltextSourceType.DOWNLOADED_PDF,
                            markdown_content=text,
                            file_path=pdf_result.file_path,
                        )
                except Exception as e:
                    logger.warning(f"Failed to extract text from downloaded PDF: {e}")

            # PDF download failed or text extraction failed
            if pdf_result.is_paywall:
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_FOUND,
                    error=pdf_result.error,
                    is_paywall=True,
                    paywall_url=pdf_result.paywall_url,
                )

            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error=pdf_result.error or "PDF download failed",
            )

        except Exception as e:
            logger.warning(f"PDF download failed: {e}")
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error=f"PDF download error: {e}",
            )


def discover_fulltext(
    pmid: Optional[str] = None,
    pmcid: Optional[str] = None,
    doi: Optional[str] = None,
    title: Optional[str] = None,
    unpaywall_email: Optional[str] = None,
) -> FulltextResult:
    """
    Convenience function to discover full-text for an article.

    Args:
        pmid: PubMed ID
        pmcid: PubMed Central ID
        doi: Digital Object Identifier
        title: Document title
        unpaywall_email: Email for Unpaywall API

    Returns:
        FulltextResult with content and source information
    """
    discoverer = FulltextDiscoverer(unpaywall_email=unpaywall_email)
    return discoverer.discover_fulltext(
        pmid=pmid,
        pmcid=pmcid,
        doi=doi,
        title=title,
    )
