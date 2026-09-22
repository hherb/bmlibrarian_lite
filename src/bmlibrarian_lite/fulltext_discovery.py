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

import requests

from dataclasses import dataclass, field, replace
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, Optional

from .constants import SERVICE_EUROPE_PMC
from .data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from .europepmc import EuropePMCClient, ArticleInfo
from .search_failures import request_failure_from_exception
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
    EUROPEPMC_PDF = "europepmc_pdf"  # PDF from Europe PMC (when XML unavailable)
    CACHED_PDF = "cached_pdf"  # Previously cached PDF
    DOWNLOADED_PDF = "downloaded_pdf"  # Freshly downloaded PDF
    ABSTRACT_ONLY = "abstract_only"  # Only abstract available

    #: Every source we could ask was asked, and none holds a full text.
    #: A claim about the article, and the only value a caller may read as
    #: one.
    NOT_FOUND = "not_found"

    #: Whether a full text exists was not established: the search was
    #: cancelled, a source could not be reached, or a lookup was not made.
    #: Nothing here is the article's fault (#354).
    NOT_ASSESSED = "not_assessed"


@dataclass
class FulltextResult:
    """Result of full-text discovery attempt.

    Attributes:
        success: Whether a full text was retrieved.
        source_type: Which source served it, or -- on failure -- whether
            the absence was established. Every failure used to be
            ``NOT_FOUND``, which is a claim about the article, so a
            throttled Europe PMC reached the transparency analyser as an
            article with no full text and was charged for it (#354).
        markdown_content: The text, on success.
        file_path: Where it was cached, on success.
        article_info: What Europe PMC said about the article, when asked.
        error: What to tell the reader, on failure.
        is_paywall: Whether a source answered "pay or log in".
        paywall_url: Where, so the caller can offer authentication.
        lookups: What went unasked on the way here, whether it failed
            (#347) or was never attempted (#355). Carried so a caller can
            classify rather than parse ``error``: the transparency analyser
            reads it to decide whether a missing statement is the article's
            answer or our own silence.
    """

    success: bool
    source_type: FulltextSourceType
    markdown_content: Optional[str] = None
    file_path: Optional[Path] = None
    article_info: Optional[ArticleInfo] = None
    error: Optional[str] = None
    is_paywall: bool = False
    paywall_url: Optional[str] = None
    lookups: LookupRecord = field(default_factory=LookupRecord)

    @property
    def absence_established(self) -> bool:
        """Whether this article was shown to have no retrievable full text.

        Two conditions, because either alone lies. A ``NOT_FOUND`` resting
        on a lookup that was never made or never answered is our silence,
        not the article's; and a lookup record is only meaningful once the
        chain has finished answering.

        Returns:
            ``True`` only when every lookup that could be made was made and
            answered, and none of them holds a full text.
        """
        return (
            self.source_type is FulltextSourceType.NOT_FOUND
            and not self.lookups.anything_unasked
        )

    def with_lookups(self, record: "LookupRecord") -> "FulltextResult":
        """Add what went unasked to this result.

        Merges rather than replaces, for the reason ``DiscoveryResult``
        does: a discarded unanswered lookup becomes, one layer up, an
        article reported as publishing no data availability statement.

        Args:
            record: What went unasked; may be empty.

        Returns:
            A copy carrying both records, this result's own first.
        """
        return replace(self, lookups=self.lookups.merged(record))


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
            return self._cancelled_result()

        # 2. Try Europe PMC XML
        self._emit_progress("discovery", "checking_europepmc")
        result = self._try_europepmc_xml(doc_dict, pmid, pmcid, doi)
        # The record travels even though this result may be discarded: a
        # Europe PMC we could not reach is exactly what makes the final
        # "no full text" not the article's answer (#354).
        lookups = result.lookups
        if result.success:
            return result

        if self._cancelled:
            return self._cancelled_result(lookups)

        # 2b. Try Europe PMC PDF render (when XML unavailable but free PDF exists)
        if (result.article_info
                and result.article_info.has_pdf
                and result.article_info.pdf_render_url):
            self._emit_progress("discovery", "checking_europepmc_pdf")
            pdf_result = self._try_europepmc_pdf(doc_dict, result.article_info)
            lookups = lookups.merged(pdf_result.lookups)
            if pdf_result.success:
                return pdf_result.with_lookups(result.lookups)

        if self._cancelled:
            return self._cancelled_result(lookups)

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
                        lookups=lookups,
                    )
            except Exception as e:
                logger.warning(f"Failed to extract text from cached PDF: {e}")

        if self._cancelled:
            return self._cancelled_result(lookups)

        if skip_pdf:
            # A lookup the caller chose not to make. It leaves exactly the
            # empty result an article without a PDF leaves, so it must not
            # read as one (#355).
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="No full-text available (PDF download skipped)",
                lookups=lookups,
            )

        # 4. Try PDF download as last resort
        self._emit_progress("discovery", "downloading_pdf")
        return self._try_pdf_download(
            doc_dict, pmid, pmcid, doi, title
        ).with_lookups(lookups)

    @staticmethod
    def _cancelled_result(lookups: LookupRecord | None = None) -> "FulltextResult":
        """What a cancelled discovery returns.

        We stopped asking; the article did not stop having a full text. It
        used to return ``NOT_FOUND``, which downstream is a finding about
        the study (#354).

        Args:
            lookups: What had gone unasked before the cancel, if anything.

        Returns:
            A result establishing nothing.
        """
        return FulltextResult(
            success=False,
            source_type=FulltextSourceType.NOT_ASSESSED,
            error="Cancelled",
            lookups=lookups or LookupRecord(),
        )

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
                # Europe PMC said it holds full-text XML and then served
                # none. Unreadable is not absent (#346): this establishes
                # nothing about the article.
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_ASSESSED,
                    article_info=info,
                    error="Europe PMC served no full-text XML for this article.",
                    lookups=LookupRecord(
                        failures=(
                            SourceLookupFailure(
                                SERVICE_EUROPE_PMC,
                                RequestFailure(
                                    RequestFailureKind.INCOMPLETE_RESPONSE
                                ),
                            ),
                        )
                    ),
                )

            # Convert to markdown
            self._emit_progress("download", "converting")
            markdown_content = self._europepmc.xml_to_markdown(xml_content)

            if not markdown_content.strip():
                # The XML arrived and our own conversion produced nothing.
                # That is a parse we could not make, not an article without
                # a full text (#359, one layer down).
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_ASSESSED,
                    article_info=info,
                    error=(
                        "Europe PMC's full text for this article could not "
                        "be converted to text."
                    ),
                    lookups=LookupRecord(
                        failures=(
                            SourceLookupFailure(
                                SERVICE_EUROPE_PMC,
                                RequestFailure(
                                    RequestFailureKind.MALFORMED_RESPONSE
                                ),
                            ),
                        )
                    ),
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
            # Not narrowed to RequestException: this body also runs the XML
            # conversion and the cache write, whose AttributeError or
            # OSError is just as much "we did not read the article" and
            # just as little the article's fault. Narrowing the catch would
            # move that work into the body without changing the answer
            # (the lesson of PR #349's converter).
            failure = _classify(e)
            logger.warning(
                "Europe PMC could not be read for this article (%s), so "
                "whether it holds a full text is not assessed.",
                failure.describe(),
            )
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error=(
                    f"Europe PMC could not be read ({failure.describe()})."
                ),
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_EUROPE_PMC, failure),)
                ),
            )

    def _try_europepmc_pdf(
        self,
        doc_dict: Dict[str, Any],
        article_info: ArticleInfo,
    ) -> FulltextResult:
        """Try to download PDF from Europe PMC render URL.

        Used when JATS XML is unavailable but a free PDF exists via the
        Europe PMC ``?pdf=render`` endpoint.

        Args:
            doc_dict: Document dictionary for path generation
            article_info: ArticleInfo with pdf_render_url populated

        Returns:
            FulltextResult with extracted text or failure info
        """
        try:
            pdf_url = article_info.pdf_render_url
            logger.info(f"Trying Europe PMC PDF render: {pdf_url}")
            self._emit_progress("download", "fetching_europepmc_pdf")

            pdf_path = generate_pdf_path(doc_dict)
            pdf_path.parent.mkdir(parents=True, exist_ok=True)

            response = self._europepmc._session.get(
                pdf_url,
                timeout=60,
            )
            response.raise_for_status()

            # Verify response is a PDF (check magic bytes)
            content = response.content
            if not content.startswith(b"%PDF"):
                logger.warning("Europe PMC PDF render URL did not return a PDF")
                return _europepmc_pdf_unassessed(
                    article_info,
                    "Europe PMC's PDF for this article was not a PDF.",
                    RequestFailureKind.MALFORMED_RESPONSE,
                )

            # Save the PDF
            with open(pdf_path, "wb") as f:
                f.write(content)

            # Extract text from PDF
            text = extract_pdf_text(pdf_path)
            if text.strip():
                return FulltextResult(
                    success=True,
                    source_type=FulltextSourceType.EUROPEPMC_PDF,
                    markdown_content=text,
                    file_path=pdf_path,
                    article_info=article_info,
                )

            return _europepmc_pdf_unassessed(
                article_info,
                "No text could be extracted from Europe PMC's PDF for this "
                "article.",
                RequestFailureKind.MALFORMED_RESPONSE,
            )

        except Exception as e:
            # See _try_europepmc_xml: the body does more than request.
            failure = _classify(e)
            logger.warning(
                "Europe PMC's PDF could not be read (%s).", failure.describe()
            )
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                article_info=article_info,
                error=f"Europe PMC's PDF could not be read ({failure.describe()}).",
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_EUROPE_PMC, failure),)
                ),
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
                            lookups=pdf_result.lookups,
                        )
                except Exception as e:
                    logger.warning(f"Failed to extract text from downloaded PDF: {e}")

            # A source that demanded payment answered about itself, not
            # about the article: a free copy may exist elsewhere, and
            # pdf_result.error already withholds the claim where a lookup
            # went unasked (#347).
            if pdf_result.is_paywall:
                return FulltextResult(
                    success=False,
                    source_type=FulltextSourceType.NOT_ASSESSED,
                    error=pdf_result.error,
                    is_paywall=True,
                    paywall_url=pdf_result.paywall_url,
                    lookups=pdf_result.lookups,
                )

            # Every source we could ask was asked. Whether that establishes
            # an absence is decided by the record, not here: a caller reads
            # ``absence_established``, which is false while anything went
            # unasked (#354).
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_FOUND,
                error=pdf_result.error or "PDF download failed",
                lookups=pdf_result.lookups,
            )

        except Exception as e:
            # See _try_europepmc_xml: the body also generates paths and
            # extracts text, and neither failing is the article's fault.
            failure = _classify(e)
            logger.warning(
                "PDF discovery could not be completed (%s).", failure.describe()
            )
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error=f"No PDF could be looked for ({failure.describe()}).",
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


def _classify(exc: Exception) -> RequestFailure:
    """Describe any exception as a request failure, without its text.

    A ``requests`` exception is classified by kind and HTTP status. Anything
    else -- an ``AttributeError`` from a response shape, an ``OSError`` from
    the cache -- is ``REQUEST_FAILED``: it is equally "we did not read the
    article", and its message may name a path or a URL (#196, #330).

    Args:
        exc: What went wrong.

    Returns:
        The failure, carrying no provider or filesystem text.
    """
    if isinstance(exc, requests.RequestException):
        return request_failure_from_exception(exc)
    return RequestFailure(RequestFailureKind.REQUEST_FAILED)


def _europepmc_pdf_unassessed(
    article_info: ArticleInfo, error: str, kind: RequestFailureKind
) -> FulltextResult:
    """Record that Europe PMC's PDF told us nothing about this article.

    Args:
        article_info: What Europe PMC said about the article.
        error: What to tell the reader, ending in a full stop.
        kind: How the PDF failed us.

    Returns:
        A result establishing nothing, naming Europe PMC as unread.
    """
    return FulltextResult(
        success=False,
        source_type=FulltextSourceType.NOT_ASSESSED,
        article_info=article_info,
        error=error,
        lookups=LookupRecord(
            failures=(
                SourceLookupFailure(SERVICE_EUROPE_PMC, RequestFailure(kind)),
            )
        ),
    )
