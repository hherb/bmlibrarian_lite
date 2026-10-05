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
PDF discovery and download functionality for BMLibrarian Lite.

Provides multiple methods for discovering and downloading PDF files:
- Unpaywall API for open access PDFs
- PubMed Central (PMC) for free full text
- Direct DOI resolution via CrossRef/content negotiation
- Browser-based download (Playwright) for bot-protected sites

Usage:
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    discoverer = PDFDiscoverer(unpaywall_email="user@example.com")
    result = discoverer.discover_and_download(
        doi="10.1038/nature12373",
        pmid="12345678",
        output_path=Path("/path/to/output.pdf"),
        expected_title="Some Paper Title",
    )
"""

import logging
import re
import time
import threading
from collections.abc import Iterator, Mapping
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote, urljoin, urlparse

import requests
from urllib3.util.retry import Retry

from .constants import (
    DOI_RESOLVER_ABSENCE_STATUSES,
    DOI_RESOLVER_HOSTS,
    FALLBACK_CONTACT_EMAIL,
    HTTP_ERROR_STATUS_MIN,
    HTTP_NOT_FOUND,
    HTTP_SERVER_ERROR_MIN,
    HTTP_UNSETTLED_CLIENT_STATUSES,
    LANDING_PAGE_ACCEPT,
    LANDING_PAGE_HTML_MARKER,
    LANDING_PAGE_MAX_BYTES,
    LANDING_PAGE_PDF_MARKER,
    LANDING_PAGE_READ_CHUNK_BYTES,
    PAYWALL_HTTP_STATUSES,
    PDF_MAGIC_BYTES,
    PDF_PARTIAL_SUFFIX,
    POLITE_MAX_THROTTLE_RETRIES,
    RETRYABLE_HTTP_STATUSES,
    SERVICE_DOI_PUBLISHER,
    SERVICE_DOI_RESOLVER,
    SERVICE_PDF_DOWNLOAD,
    SERVICE_PMC_ID_CONVERTER,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
)
from .analysis_failures import (
    no_pdf_sources_message,
    paywall_message,
    not_saved_note,
    with_unestablished_access,
)
from .data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from .oa_landing_page import (
    choose_unpaywall_url,
    citation_pdf_url,
    landing_page_text,
    location_pdf_url,
    unpaywall_locations,
)
from .polite_session import is_loopback_host, mount_politely
from .rate_limit import limiter_for
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)

#: How PubMed Central's ID converter reports a per-record failure. It is
#: a refusal to answer, not an article without a PMC ID (#347).
_ID_CONVERTER_ERROR_STATUS = "error"

# The lookup paths below -- ``_get_pmcid_from_pmid``, ``_discover_unpaywall``
# (with ``_resolve_landing_page``) and ``_discover_doi_direct`` -- describe every failure through
# ``request_failure_from_exception(...).describe()``, which keeps the kind and
# the HTTP status and nothing else. A local helper did the same job until #347
# gave them a typed failure to carry. The rule they follow: ``str()`` on a
# ``requests`` exception embeds the request URL, and the Unpaywall URL carries
# ``email=<the user's address>`` (the same leak as #196/#330).
#
# The download paths (``_try_download``, ``_try_browser_download``) do NOT yet
# follow it -- they still put ``str(e)`` into the reader-facing ``error`` and
# ``verification_warning`` fields. Those URLs are publisher and PMC ones
# rather than the credential-bearing lookups, so no secret leaks today, but
# the migration is unfinished: see #350 before adding another handler there.

def doi_lookup_service(url: str | bytes | None) -> str:
    """Name who answered a request made through doi.org.

    The HEAD follows redirects, so a URL is doi.org's while its host is one
    of :data:`DOI_RESOLVER_HOSTS`; any other host is the publisher's (#446).

    Args:
        url: The URL answered or failed on, as ``requests`` holds it (a
            request's may be bytes); ``None`` when nothing names one --
            the lookup failed before any request was sent or answered.
            That one is named doi.org's.

    Returns:
        :data:`SERVICE_DOI_RESOLVER` or :data:`SERVICE_DOI_PUBLISHER`.
    """
    if url is None:
        return SERVICE_DOI_RESOLVER
    if isinstance(url, bytes):
        url = url.decode("utf-8", errors="replace")
    host = urlparse(url).hostname or ""
    return (
        SERVICE_DOI_RESOLVER if host in DOI_RESOLVER_HOSTS else SERVICE_DOI_PUBLISHER
    )


def web_page_status_unsettled(status_code: int) -> bool:
    """Whether a web page's error status left the lookup unsettled.

    For a page we were pointed to -- the publisher's site a DOI resolves to
    (#446), or the landing page Unpaywall names (#464) -- rather than an API
    that answers about the article. A throttle, a server fault, a 408 or a
    425 is "not now". Any other 4xx (a bot wall, a 404) is the page's
    answer that it serves us nothing, and recording it would caveat a large
    share of lookups for a route that serves nothing to the rest (the
    maintainer's call, #446).

    Args:
        status_code: An error status (400 or above).

    Returns:
        ``True`` when the status says nothing about the page's content.
    """
    return (
        status_code >= HTTP_SERVER_ERROR_MIN
        or status_code in RETRYABLE_HTTP_STATUSES
        or status_code in HTTP_UNSETTLED_CLIENT_STATUSES
    )


def doi_resolution_failure(status_code: int, url: str) -> SourceLookupFailure | None:
    """Decide whether the status a DOI lookup ended on left it unsettled.

    ``PoliteAdapter`` hands back the last status once its retries run out,
    rather than raising, so an exhausted throttle arrives here as a status
    (#446). Who answered decides what it means:

    * doi.org's 400 (not a DOI) and 404 (not registered) are about the
      identifier, so an absence. Any other failure of doi.org's left the
      question open.
    * The publisher's throttle, server fault, 408 or 425 left it open too,
      retried or not: Cloudflare's 522 is an origin that timed out, and a
      timeout we raise ourselves is recorded. A throttle or a server fault
      reads as "could not be asked" (#445); a 408 or 425 is the publisher's
      answer, "did not serve it" (#435). Any other 4xx -- the bot wall that 9 of 20 surveyed
      DOIs ended in, a 404, a 405 to the HEAD -- answers that content
      negotiation serves no PDF, as all 11 other surveyed DOIs did, with
      HTML. Recording it would caveat nearly half of all DOIs for a route
      that served nothing to the rest (the maintainer's call, #446).

    Args:
        status_code: The status the lookup ended on.
        url: Where that status came from.

    Returns:
        The failure, or ``None`` when the lookup was answered.
    """
    if status_code < HTTP_ERROR_STATUS_MIN:
        return None
    service = doi_lookup_service(url)
    if service == SERVICE_DOI_RESOLVER:
        if status_code in DOI_RESOLVER_ABSENCE_STATUSES:
            return None
    elif not web_page_status_unsettled(status_code):
        return None
    return SourceLookupFailure(
        service, RequestFailure(RequestFailureKind.HTTP_STATUS, status_code)
    )


# Global browser session manager (singleton, persists across downloads)
_browser_session: Optional["BrowserSession"] = None
_browser_lock = threading.Lock()


class BrowserSession:
    """
    Manages a persistent browser session for PDF downloads.

    Uses Playwright with Chromium to bypass bot protection.
    The browser window can be visible to allow user interaction
    (e.g., CAPTCHA solving, cookie consent).
    """

    def __init__(self, headless: bool = False) -> None:
        """
        Initialize browser session.

        Args:
            headless: If True, run browser without visible window.
                     Default False to allow user interaction.
        """
        self.headless = headless
        self._playwright = None
        self._browser = None
        self._context = None
        self._page = None
        self._initialized = False

    def _ensure_initialized(self) -> bool:
        """Lazily initialize the browser on first use."""
        if self._initialized:
            return True

        try:
            from playwright.sync_api import sync_playwright

            logger.info("Starting browser session for PDF downloads...")
            self._playwright = sync_playwright().start()
            self._browser = self._playwright.chromium.launch(
                headless=self.headless,
                args=[
                    "--disable-blink-features=AutomationControlled",
                ]
            )
            self._context = self._browser.new_context(
                accept_downloads=True,
                user_agent=(
                    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) "
                    "AppleWebKit/537.36 (KHTML, like Gecko) "
                    "Chrome/120.0.0.0 Safari/537.36"
                ),
            )
            self._page = self._context.new_page()
            self._initialized = True
            logger.info("Browser session started successfully")
            return True

        except Exception as e:
            logger.warning(f"Failed to initialize browser session: {e}")
            return False

    def download_pdf(
        self,
        url: str,
        output_path: Path,
        timeout: int = 60000,
    ) -> Tuple[bool, Optional[str]]:
        """
        Download a PDF using the browser.

        Args:
            url: URL to download from
            output_path: Path to save the PDF
            timeout: Download timeout in milliseconds

        Returns:
            Tuple of (success, error_message)
        """
        if not self._ensure_initialized():
            return False, "Browser session not available"

        try:
            logger.info(f"Browser downloading: {url}")

            # Set up download handling
            output_path.parent.mkdir(parents=True, exist_ok=True)

            # The browser fallback reaches the same publisher hosts as the
            # requests path, so it shares their budget rather than opening a
            # second one beside it. It is invoked precisely when a host has
            # already refused us, which is the worst moment to stop being
            # polite. No mounted adapter can do this for us: Playwright does
            # not go through requests.
            browser_host = urlparse(url).hostname or ""
            if browser_host and not is_loopback_host(browser_host):
                limiter_for(browser_host).acquire()

            # Navigate and wait for potential download
            with self._page.expect_download(timeout=timeout) as download_info:
                self._page.goto(url, wait_until="domcontentloaded", timeout=timeout)

            download = download_info.value
            download.save_as(output_path)

            # Verify it's a PDF
            if output_path.exists():
                with open(output_path, 'rb') as f:
                    header = f.read(4)
                    if header == b'%PDF':
                        logger.info(f"Browser download successful: {output_path}")
                        return True, None
                    else:
                        output_path.unlink(missing_ok=True)
                        return False, "Downloaded file is not a PDF"

            return False, "Download failed - no file created"

        except Exception as e:
            error_msg = str(e)
            # Check if it's a timeout waiting for download (might be HTML page)
            if "Timeout" in error_msg:
                # Try to get the page content directly if no download started
                return self._try_direct_content(url, output_path)
            logger.warning(f"Browser download failed: {e}")
            return False, error_msg

    def _try_direct_content(
        self,
        url: str,
        output_path: Path,
    ) -> Tuple[bool, Optional[str]]:
        """
        Try to get PDF content directly from page response.

        Some sites serve PDF inline rather than as a download.
        """
        try:
            # Check if current page has PDF content
            content_type = self._page.evaluate(
                "() => document.contentType"
            )

            if content_type and 'pdf' in content_type.lower():
                # Page itself is a PDF, save it
                response = self._context.request.get(url)
                if response.ok:
                    output_path.write_bytes(response.body())
                    return True, None

            return False, "Page did not serve PDF content"

        except Exception as e:
            return False, f"Failed to get direct content: {e}"

    def close(self) -> None:
        """Close the browser session."""
        if self._page:
            try:
                self._page.close()
            except Exception:
                pass
        if self._context:
            try:
                self._context.close()
            except Exception:
                pass
        if self._browser:
            try:
                self._browser.close()
            except Exception:
                pass
        if self._playwright:
            try:
                self._playwright.stop()
            except Exception:
                pass
        self._initialized = False
        logger.info("Browser session closed")


def get_browser_session(headless: bool = False) -> Optional[BrowserSession]:
    """
    Get the global browser session, creating it if needed.

    Args:
        headless: If True, run browser without visible window

    Returns:
        BrowserSession instance or None if unavailable
    """
    global _browser_session

    with _browser_lock:
        if _browser_session is None:
            _browser_session = BrowserSession(headless=headless)
        return _browser_session


def close_browser_session() -> None:
    """Close the global browser session."""
    global _browser_session

    with _browser_lock:
        if _browser_session is not None:
            _browser_session.close()
            _browser_session = None

# User agent for HTTP requests
USER_AGENT = "BMLibrarian/1.0 (https://github.com/hherb/bmlibrarian-lite; mailto:support@bmlibrarian.org)"

# Timeout for HTTP requests (seconds)
REQUEST_TIMEOUT = 30

# Maximum PDF file size (100 MB)
MAX_PDF_SIZE = 100 * 1024 * 1024


class PDFSourceType(Enum):
    """Type of PDF source."""

    UNPAYWALL_OA = "unpaywall_oa"  # Open access via Unpaywall
    PMC = "pmc"  # PubMed Central
    DOI_DIRECT = "doi_direct"  # Direct from DOI/publisher
    OPENATHENS = "openathens"  # Via institutional access
    UNKNOWN = "unknown"


@dataclass
class PDFSource:
    """Represents a discovered PDF source."""

    url: str
    source_type: PDFSourceType
    is_open_access: bool = False
    host_type: str = ""  # e.g., "publisher", "repository"
    version: str = ""  # e.g., "publishedVersion", "acceptedVersion"
    license: str = ""

    @property
    def priority(self) -> int:
        """Get priority score for this source (higher is better)."""
        # Prefer open access, then published versions
        score = 0
        if self.is_open_access:
            score += 100
        if self.source_type == PDFSourceType.PMC:
            score += 50  # PMC is usually reliable
        elif self.source_type == PDFSourceType.UNPAYWALL_OA:
            score += 40
        if "published" in self.version.lower():
            score += 20
        if self.host_type == "publisher":
            score += 10
        return score


@dataclass
class DiscoveryResult:
    """Result of PDF discovery attempt.

    Attributes:
        success: Whether a PDF was downloaded.
        file_path: Where it was written, on success.
        source: Which source served it, on success.
        error: What to tell the reader, on failure.
        is_paywall: Whether a source answered "pay or log in".
        paywall_url: Where, so the caller can offer authentication.
        verification_warning: What the content check doubted.
        lookups: The lookups that went unanswered, whether they failed
            (#347) or were never made (#355), and an Unpaywall PDF that could
            not be obtained (#478). Empty means every lookup this discovery
            could make was made and answered. Independent of
            ``success``, which says only whether a PDF arrived: a download
            can succeed while Unpaywall was throttled, and that is worth
            knowing.

            ``error`` already carries these in words on every unsuccessful
            path, so a caller that only shows text needs nothing from this
            field; it is here so a caller can classify rather than parse a
            sentence -- which is what the transparency analyser does to tell
            an absence from a silence (#354).
        failure: Why one download attempt got no PDF, as a typed failure
            safe to show: the status, the transport failure,
            ``MALFORMED_RESPONSE`` for a body that is not the PDF, or
            ``REQUEST_FAILED`` for an address that cannot be requested or an
            unexpected fault of our own.
            ``None`` on success, on a cancel, and for a PDF refused for its
            size. Set only by :meth:`PDFDiscoverer._try_download`, so the
            discovery can record an Unpaywall PDF it could not obtain (#478).
        refused_for_size: Whether the source offered a PDF larger than
            :data:`MAX_PDF_SIZE`. Our limit rather than the source's answer,
            so it is no ``failure``; but the copy exists and went unread,
            so an Unpaywall PDF refused for its size is still recorded as
            unassessed (#478).
        not_saved: The source served the PDF and it could not be written
            here: a fault of ours, told as a caching note (#480). Not a
            ``failure``: the source answered.

    Raises:
        ValueError: On construction, if a successful result carries a
            failure, a size refusal or a not-saved flag.
    """

    success: bool
    file_path: Optional[Path] = None
    source: Optional[PDFSource] = None
    error: Optional[str] = None
    is_paywall: bool = False
    paywall_url: Optional[str] = None
    verification_warning: Optional[str] = None
    lookups: LookupRecord = LookupRecord()
    failure: RequestFailure | None = None
    refused_for_size: bool = False
    not_saved: bool = False

    def __post_init__(self) -> None:
        """Refuse a success that also says why no PDF was obtained."""
        if self.success and (
            self.failure is not None or self.refused_for_size or self.not_saved
        ):
            raise ValueError("A downloaded PDF carries no download failure")

    def with_lookups(self, record: LookupRecord) -> "DiscoveryResult":
        """Add the lookups that went unanswered to this result.

        Merges rather than replaces. A download path records no unanswered
        lookup of its own today, so ``replace()`` was harmless -- but a
        discarded one becomes, downstream, an article reported as having no
        open-access copy, which is the defect this field exists to prevent
        (#347).

        Args:
            record: What went unasked; may be empty.

        Returns:
            A copy carrying this result's own record and then ``record``,
            with nothing dropped.
        """
        return replace(self, lookups=self.lookups.merged(record))


def refused_download_failure(status_code: int) -> RequestFailure:
    """The failure a download met by a paywall or a bot wall records.

    A refusal status (401, 403) is that status, which the reader is told
    "did not serve it". A page served with a success status in place of the
    PDF -- a login form, a captcha, a challenge page -- is a body that is
    not the PDF, ``MALFORMED_RESPONSE``: that says nothing about the
    article, so the reader is told the copy could not be asked (#478, #480).

    Args:
        status_code: The status the page was served with.

    Returns:
        The failure to record.
    """
    if status_code >= HTTP_ERROR_STATUS_MIN:
        return RequestFailure(RequestFailureKind.HTTP_STATUS, status_code)
    return RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def read_body_prefix(chunks: Iterator[bytes], at_least: int) -> bytes:
    """Read the start of a streamed body, enough of it to sniff.

    A first chunk can be shorter than the bytes a sniff needs -- one HTTP
    chunk of a chunked body -- so chunks are joined until there are enough
    or the body ends. A read that fails raises: it is the transport's
    failure, not an empty body.

    Args:
        chunks: The body's chunks, consumed as far as needed.
        at_least: How many bytes the caller needs.

    Returns:
        The bytes read, which are ``at_least`` or more unless the body was
        shorter.
    """
    prefix = b""
    for chunk in chunks:
        prefix += chunk
        if len(prefix) >= at_least:
            break
    return prefix


def partial_download_path(output_path: Path) -> Path:
    """Where a PDF is written while its download is in progress.

    Args:
        output_path: Where the PDF is to end up.

    Returns:
        ``output_path`` with :data:`PDF_PARTIAL_SUFFIX` appended, beside it,
        so the rename into place stays on one filesystem.
    """
    return output_path.with_name(output_path.name + PDF_PARTIAL_SUFFIX)


def discard_partial_download(partial: Path) -> None:
    """Remove a partial download, if one is left.

    Logged rather than raised when it cannot be removed: the download's own
    outcome is what the caller reports, and a leftover partial file is never
    read as the PDF -- only the renamed file is.

    Args:
        partial: The partial file; may not exist.
    """
    try:
        partial.unlink(missing_ok=True)
    except OSError as e:
        logger.warning(f"Could not remove the partial download {partial}: {e}")


#: Whose PDF an unobtained open-access copy is recorded against (#478, #480).
_UNOBTAINED_PDF_SERVICE = {PDFSourceType.UNPAYWALL_OA: SERVICE_UNPAYWALL_PDF}


def unobtained_open_access_pdf(
    source: "PDFSource", result: "DiscoveryResult"
) -> LookupRecord:
    """Record an open-access PDF we could not obtain, with its address.

    A source answered with a copy; that we could not then obtain it is not an
    article without one (#478). It is recorded under the copy's own name, not
    the service's, which answered, and with its address, so the reader is
    told each copy tried by its host (#480). A PDF refused for its size is
    our limit, recorded as a lookup not made; a cancel records nothing.

    Args:
        source: The source the download tried.
        result: What the attempt came to.

    Returns:
        A record under the copy's service when ``source`` is a PDF an
        open-access source named and the attempt did not obtain it; empty
        otherwise.
    """
    service = _UNOBTAINED_PDF_SERVICE.get(source.source_type)
    if result.success or service is None:
        return LookupRecord()
    if result.failure is not None:
        return LookupRecord(failures=(SourceLookupFailure(service, result.failure, source.url),))
    if result.refused_for_size:
        return LookupRecord(
            skipped=(SourceLookupSkipped(service, LookupSkipReason.OVER_SIZE_LIMIT, source.url),)
        )
    return LookupRecord()


def usable_unpaywall_email(email: str | None) -> str | None:
    """The email to ask Unpaywall with, or ``None`` when there is none to use.

    The application's own placeholder is not the user's address. Unpaywall
    answers it with HTTP 422 for every article, which read to the reader as
    "Unpaywall did not serve it" -- blaming the article for our
    configuration -- and gave them no advice. Treated as no email, it is a
    ``NOT_CONFIGURED`` skip, which earns the configuration sentence (#435).

    Args:
        email: The configured email, a placeholder, blank, or ``None``.

    Returns:
        ``email`` stripped, or ``None`` when it is blank or the placeholder.
    """
    if email is None:
        return None
    stripped = email.strip()
    if not stripped or stripped == FALLBACK_CONTACT_EMAIL:
        return None
    return stripped


class PDFDiscoverer:
    """
    Discovers and downloads PDF files from various sources.

    Supports:
    - Unpaywall API for open access discovery
    - PubMed Central for free full text
    - Direct DOI resolution
    - Browser-based download for bot-protected sites
    - Content verification
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
        Initialize PDF discoverer.

        Args:
            unpaywall_email: Email for Unpaywall API (required for Unpaywall;
                the application's placeholder counts as none)
            openathens_url: OpenAthens institution URL for authenticated access
            progress_callback: Callback for progress updates (stage, status)
            use_browser_fallback: If True, use browser for bot-protected downloads
            browser_headless: If True, run browser without visible window
        """
        self.unpaywall_email = usable_unpaywall_email(unpaywall_email)
        self.openathens_url = openathens_url
        self.progress_callback = progress_callback
        self.use_browser_fallback = use_browser_fallback
        self.browser_headless = browser_headless
        self._session = self._create_session()
        self._cancelled = False

    def _create_session(self) -> requests.Session:
        """Create HTTP session with retry logic."""
        session = requests.Session()
        session.headers.update({
            "User-Agent": USER_AGENT,
            "Accept": "application/pdf,*/*",
        })

        retry_strategy = Retry(
            total=POLITE_MAX_THROTTLE_RETRIES,
            backoff_factor=1,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["HEAD", "GET"],
        )
        # Unpaywall, doi.org and publisher web servers, none of them ours
        return mount_politely(session, retry=retry_strategy)

    def _emit_progress(self, stage: str, status: str) -> None:
        """Emit progress update."""
        if self.progress_callback:
            self.progress_callback(stage, status)

    def cancel(self) -> None:
        """Cancel the current operation."""
        self._cancelled = True

    def discover_and_download(
        self,
        output_path: Path,
        doi: Optional[str] = None,
        pmid: Optional[str] = None,
        pmcid: Optional[str] = None,
        title: Optional[str] = None,
        expected_title: Optional[str] = None,
        earlier_lookups: LookupRecord | None = None,
    ) -> DiscoveryResult:
        """
        Discover and download PDF for a document.

        Tries multiple sources in order of reliability:
        1. PubMed Central (if PMID/PMCID available)
        2. Unpaywall (if DOI and email available)
        3. Direct DOI resolution

        Args:
            output_path: Path to save the PDF
            doi: Document DOI
            pmid: PubMed ID
            pmcid: PubMed Central ID
            title: Document title (for verification)
            expected_title: Expected title for content verification
            earlier_lookups: What went unasked before this step, such as a
                throttled Europe PMC. Named in every sentence this builds
                for the reader, but not added to the result's record, which
                the caller holds and merges: without it the record named
                Europe PMC and the sentence said only "No PDF sources found.
                The document may require institutional access."

        Returns:
            DiscoveryResult with success status and details
        """
        self._cancelled = False
        self._emit_progress("discovery", "starting")

        # Find all available PDF sources, and what could not be asked at all
        sources, lookups = self._discover_sources(doi, pmid, pmcid)
        # What the reader is told about: everything unasked so far.
        told = (earlier_lookups or LookupRecord()).merged(lookups)

        if self._cancelled:
            return DiscoveryResult(
                success=False,
                error="Cancelled",
                lookups=lookups,
            )

        if not sources:
            self._emit_progress("discovery", "not_found")
            return DiscoveryResult(
                success=False,
                # A lookup we did not make says nothing about the licence,
                # so the paywall claim is withheld whenever one went unasked
                # -- skipped as well as failed (#347, #355).
                error=no_pdf_sources_message(told),
                lookups=lookups,
            )

        # Unpaywall's own order, then OpenAlex's (#480), before the priority
        # sort reorders them: every copy not obtained is told, in this order.
        copy_rank = {
            s.url: rank
            for rank, s in enumerate(
                s for s in sources if s.source_type in _UNOBTAINED_PDF_SERVICE
            )
        }

        # Sort by priority
        sources.sort(key=lambda s: s.priority, reverse=True)

        logger.info(f"Found {len(sources)} PDF sources for DOI={doi}, PMID={pmid}")
        for src in sources:
            logger.debug(f"  - {src.source_type.value}: {src.url} (priority={src.priority})")

        # Try to download from each source
        last_paywall_result: Optional[DiscoveryResult] = None
        blocked_oa_sources: List[PDFSource] = []  # Track sources blocked by bot protection
        unobtained: list[tuple[int, LookupRecord]] = []

        for source in sources:
            if self._cancelled:
                return DiscoveryResult(
                    success=False,
                    error="Cancelled",
                    lookups=lookups,
                )

            self._emit_progress("discovery", "found_oa" if source.is_open_access else "found")
            result = self._try_download(source, output_path, expected_title or title)

            if result.success:
                return result.with_lookups(lookups)

            if result.not_saved:
                # Served, and not saved here: the copy exists, so nothing else
                # is asked (saving is our problem) and the open-access
                # question is settled (the maintainer's decision): the error
                # is the caching note alone. Other unsettled lookups stay in
                # ``lookups`` for the absence logic (#480).
                saved_note = LookupRecord(skipped=(SourceLookupSkipped(
                    _UNOBTAINED_PDF_SERVICE.get(source.source_type, SERVICE_PDF_DOWNLOAD),
                    LookupSkipReason.NOT_SAVED,
                    source.url,
                ),))
                return DiscoveryResult(
                    success=False,
                    error=not_saved_note(saved_note),
                    lookups=lookups.merged(saved_note),
                )

            # An open-access PDF we could not obtain leaves that copy
            # unassessed (#478). Held apart from ``lookups`` and merged only
            # where the discovery gives up: a later source that serves the
            # PDF settles the question. Every one is kept, in chain order.
            record = unobtained_open_access_pdf(source, result)
            rank = copy_rank.get(source.url)
            if record.anything_unsettled and rank is not None:
                unobtained.append((rank, record))

            if result.is_paywall:
                # For open access sources, a 403 might be bot protection, not paywall
                # Keep trying other sources first
                if source.is_open_access:
                    logger.info(f"Source {source.url} blocked (may be bot protection), trying next source")
                    blocked_oa_sources.append(source)
                    last_paywall_result = result
                    continue
                else:
                    # For non-OA sources, return paywall result so caller can
                    # offer OpenAthens auth. The refusal is this source's
                    # answer, not the document's licence: where the lookup
                    # that would have found a free copy could not be made,
                    # the claim is withheld rather than asserted (#347).
                    not_obtained = self._ranked(unobtained)
                    return replace(
                        result.with_lookups(lookups.merged(not_obtained)),
                        error=paywall_message(
                            result.error or "", told.merged(not_obtained)
                        ),
                    )

        # If we have blocked OA sources and browser fallback is enabled, try browser
        if blocked_oa_sources and self.use_browser_fallback:
            self._emit_progress("download", "browser_fallback")
            logger.info("Trying browser-based download for bot-protected sources...")

            for source in blocked_oa_sources:
                if self._cancelled:
                    return DiscoveryResult(
                        success=False,
                        error="Cancelled",
                        lookups=lookups,
                    )

                result = self._try_browser_download(source, output_path, expected_title or title)
                if result.success:
                    return result.with_lookups(lookups)

        not_obtained = self._ranked(unobtained)

        # If we had a paywall result but no success, return it for OpenAthens option
        if last_paywall_result:
            return replace(
                last_paywall_result.with_lookups(lookups.merged(not_obtained)),
                error=paywall_message(
                    last_paywall_result.error or "", told.merged(not_obtained)
                ),
            )

        return DiscoveryResult(
            success=False,
            # A claim about our own attempts, which the unasked sources
            # cannot falsify -- so it is qualified rather than withheld.
            error=with_unestablished_access(
                "Failed to download PDF from any available source.",
                told.merged(not_obtained),
            ),
            lookups=lookups.merged(not_obtained),
        )

    @staticmethod
    def _ranked(unobtained: list[tuple[int, LookupRecord]]) -> LookupRecord:
        """Every copy not obtained, in chain order whatever order they were tried in."""
        merged = LookupRecord()
        for _rank, record in sorted(unobtained, key=lambda pair: pair[0]):
            merged = merged.merged(record)
        return merged

    def _discover_sources(
        self,
        doi: Optional[str],
        pmid: Optional[str],
        pmcid: Optional[str],
    ) -> tuple[list[PDFSource], LookupRecord]:
        """Discover all available PDF sources, and what went unasked.

        A lookup that failed and a lookup that answered "nothing" both used
        to leave an empty list, so a throttled Unpaywall was reported to the
        reader as an article behind a paywall (#347). A lookup we never made
        left the same empty list for the same reader (#355). Both are
        returned alongside the sources, not only logged: a log line cannot
        reach the reader, and only the caller can.

        A skip is recorded only where it changes what can be claimed, which
        is why the two cases here are asymmetric. **Unpaywall** is what
        establishes open access on this path, so every reason it went
        unasked -- unconfigured, or no DOI to ask it by -- withholds the
        claim. **The PMC path** is not reported when no PMID or PMC ID is
        held: where Unpaywall answered the claim stands, and where it did
        not, its own entry already withholds it, so a second caveat on
        every DOI-only record would tell the reader nothing the first does
        not. That is how an honest majority gets drowned (the 404 rule, one
        dimension over).

        The no-DOI skip is further gated on having found nothing, because
        an article whose PMC ID gave us direct links had its open access
        established by PMC: Unpaywall would only have agreed.

        Args:
            doi: The article's DOI, if known.
            pmid: Its PubMed ID, if known.
            pmcid: Its PMC ID, if known.

        Returns:
            The sources found, and what went unasked. Both may be empty; one
            being empty says nothing about the other.
        """
        sources: List[PDFSource] = []
        failures: list[SourceLookupFailure] = []
        skipped: list[SourceLookupSkipped] = []

        # Try PMC first (most reliable for open access)
        if pmcid or pmid:
            pmc_sources, pmc_failure = self._discover_pmc(pmid, pmcid)
            sources.extend(pmc_sources)
            if pmc_failure is not None:
                failures.append(pmc_failure)

        # Try Unpaywall
        if doi and self.unpaywall_email:
            unpaywall_sources, unpaywall_failure = self._discover_unpaywall(doi)
            sources.extend(unpaywall_sources)
            if unpaywall_failure is not None:
                failures.append(unpaywall_failure)
        elif doi:
            # An unconfigured Unpaywall quietly costs every search its best
            # open-access route, and the reader is the only one who can
            # change that -- so it is a caveat with a nudge, not a log line.
            skipped.append(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NOT_CONFIGURED
                )
            )

        # Try publisher-specific patterns (even if Unpaywall didn't find it)
        if doi:
            publisher_sources = self._discover_publisher_specific(doi)
            for ps in publisher_sources:
                if ps.url not in [s.url for s in sources]:
                    sources.append(ps)

        # Try direct DOI resolution as last resort
        if doi:
            doi_sources, doi_failure = self._discover_doi_direct(doi)
            for ds in doi_sources:
                if ds.url not in [s.url for s in sources]:
                    sources.append(ds)
            if doi_failure is not None:
                failures.append(doi_failure)

        if not sources and not doi:
            # Unpaywall indexes the open-access copies PMC does not hold,
            # and we never resolved a DOI to ask it by -- so "no PDF
            # sources found. The document may require institutional
            # access." rests on one source having said no (#355).
            skipped.append(
                SourceLookupSkipped(
                    SERVICE_UNPAYWALL, LookupSkipReason.NO_IDENTIFIER
                )
            )

        return sources, LookupRecord(tuple(failures), tuple(skipped))

    def _discover_pmc(
        self,
        pmid: Optional[str],
        pmcid: Optional[str],
    ) -> tuple[list[PDFSource], SourceLookupFailure | None]:
        """Discover PDF from PubMed Central and Europe PMC.

        Args:
            pmid: The article's PubMed ID, if known.
            pmcid: Its PMC ID, if known. With one, no lookup is needed and
                no lookup can fail.

        Returns:
            The PMC sources, and the id-converter failure that prevented
            finding any. A failed conversion leaves this path with nothing,
            and it is the most reliable path, so it must not read as an
            article that PMC does not hold (#347).
        """
        sources: List[PDFSource] = []

        # If we have PMCID, construct direct links
        if pmcid:
            pmc_id = pmcid if pmcid.startswith("PMC") else f"PMC{pmcid}"

            # Europe PMC (more reliable, less bot protection)
            europepmc_url = f"https://europepmc.org/backend/ptpmcrender.fcgi?accid={pmc_id}&blobtype=pdf"
            sources.append(PDFSource(
                url=europepmc_url,
                source_type=PDFSourceType.PMC,
                is_open_access=True,
                host_type="repository",
                version="publishedVersion",
            ))

            # NCBI PMC as fallback
            ncbi_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmc_id}/pdf/"
            sources.append(PDFSource(
                url=ncbi_url,
                source_type=PDFSourceType.PMC,
                is_open_access=True,
                host_type="repository",
                version="publishedVersion",
            ))
            return sources, None

        # If we only have PMID, try to get PMCID via eutils
        if pmid:
            pmcid, failure = self._get_pmcid_from_pmid(pmid)
            if failure is not None:
                return sources, failure
            if pmcid:
                # Europe PMC first
                europepmc_url = f"https://europepmc.org/backend/ptpmcrender.fcgi?accid={pmcid}&blobtype=pdf"
                sources.append(PDFSource(
                    url=europepmc_url,
                    source_type=PDFSourceType.PMC,
                    is_open_access=True,
                    host_type="repository",
                    version="publishedVersion",
                ))

                # NCBI PMC as fallback
                ncbi_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmcid}/pdf/"
                sources.append(PDFSource(
                    url=ncbi_url,
                    source_type=PDFSourceType.PMC,
                    is_open_access=True,
                    host_type="repository",
                    version="publishedVersion",
                ))

        return sources, None

    def _get_pmcid_from_pmid(
        self, pmid: str
    ) -> tuple[str | None, SourceLookupFailure | None]:
        """Get PMCID from PMID using NCBI ID converter.

        Args:
            pmid: The article's PubMed ID.

        Returns:
            The PMC ID, and the failure that prevented looking it up. At
            most one is ever set, and both are ``None`` only for the two
            answers that are about the article: the converter holds no
            record for this PMID, or it holds one that names no ``pmcid``.
            Every other outcome -- unreached, unreadable body, a record
            reporting an error, a ``pmcid`` we cannot read -- is our failure
            and is returned as one, because unreachable is not absent and
            this path takes out the whole PMC route (#347).
        """
        try:
            url = (
                f"https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/"
                f"?ids={pmid}&format=json"
            )
            response = self._session.get(url, timeout=REQUEST_TIMEOUT)
            response.raise_for_status()

            # Network data, not a promise (golden rule 1): the converter's
            # body is only trusted to the depth it is actually checked. A
            # bare `except Exception` used to hide every shape error here
            # along with the request failures; narrowing it means each shape
            # is now tested for rather than caught after the fact.
            data = response.json()
            if not isinstance(data, dict):
                return None, self._unreadable_id_converter(pmid, "not an object")
            records = data.get("records", [])
            if not isinstance(records, list):
                return None, self._unreadable_id_converter(pmid, "records is not a list")
            if not records:
                # The converter answered and named no record at all. That is
                # about the article: PMC holds nothing for this PMID.
                logger.info(
                    "PubMed Central's ID converter holds no record for PMID %s.",
                    pmid,
                )
                return None, None
            first = records[0]
            if not isinstance(first, dict):
                return None, self._unreadable_id_converter(pmid, "a record is not an object")
            if first.get("status") == _ID_CONVERTER_ERROR_STATUS:
                # The converter's own per-record error shape. It declined to
                # answer, so it has told us nothing about the article.
                return None, self._unreadable_id_converter(pmid, "a record reports an error")
            if "pmcid" not in first:
                # The key is absent: the converter knows this article and
                # says PMC has no ID for it. An absence, and the article's.
                return None, None
            pmcid = first.get("pmcid")
            if isinstance(pmcid, str) and pmcid:
                return pmcid, None
            # The key is there but unreadable -- an int, a list, or empty.
            # Unreadable is not absent: a PMC ID may well exist (#347).
            return None, self._unreadable_id_converter(
                pmid, "pmcid is not a non-empty string"
            )

        except requests.exceptions.RequestException as e:
            failure = request_failure_from_exception(e)
            if failure.kind is RequestFailureKind.MALFORMED_RESPONSE:
                # It was asked, and answered something we cannot read. Say so
                # rather than blaming the reach: the two are different, and
                # the log is what a maintainer diagnoses this from.
                return None, self._unreadable_id_converter(pmid, "not JSON")
            logger.warning(
                "PubMed Central's ID converter could not be asked about PMID "
                "%s (%s), so the PMC path found nothing for reasons that are "
                "not the article's.",
                pmid,
                failure.describe(),
            )
            return None, SourceLookupFailure(SERVICE_PMC_ID_CONVERTER, failure)
        except ValueError:
            # A body that is not JSON at all. `requests`' own JSONDecodeError
            # subclasses both RequestException and ValueError, so the arm
            # above claims it; this one catches a plain `json` error from a
            # stubbed session in a test.
            return None, self._unreadable_id_converter(pmid, "not JSON")

        return None, None

    @staticmethod
    def _unreadable_id_converter(pmid: str, shape: str) -> SourceLookupFailure:
        """Record that the ID converter answered in a shape we cannot read.

        Unreadable is not absent: the converter may well know a PMC ID for
        this article, so the PMC path finding nothing is our failure and
        must not reach the reader as the article's (#347).

        Args:
            pmid: The PubMed ID being converted, for the log.
            shape: What was wrong with the body, for the log only -- never
                the body itself, which is untrusted network data.

        Returns:
            The failure to hand back with no PMC ID.
        """
        logger.warning(
            "PubMed Central's ID converter answered PMID %s unreadably (%s), "
            "so the PMC path found nothing for reasons that are not the "
            "article's.",
            pmid,
            shape,
        )
        return SourceLookupFailure(
            SERVICE_PMC_ID_CONVERTER,
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
        )

    def _discover_unpaywall(
        self, doi: str
    ) -> tuple[list[PDFSource], SourceLookupFailure | None]:
        """Discover PDF sources via Unpaywall API.

        Args:
            doi: The article's DOI.

        Returns:
            The open-access sources found, and the failure that left the
            lookup unsettled: Unpaywall itself could not be asked
            (:data:`SERVICE_UNPAYWALL`), or the landing page it named could
            not be read (:data:`SERVICE_UNPAYWALL_LANDING_PAGE`, #464). No
            failure means every request was answered, so an empty list is
            Unpaywall knowing of none; with a failure it means we never found
            out, which is not the same thing and must not reach the reader as
            one (#347).

        Raises:
            ValueError: If no Unpaywall email is configured. The caller
                records a ``NOT_CONFIGURED`` skip instead of asking, and a
                lookup that never happened has no answer to return.
        """
        sources: List[PDFSource] = []

        # Defensive: _discover_sources records a NOT_CONFIGURED skip rather
        # than calling here without an address (#355), so this is a guard
        # against a future caller, not a live path. It raises rather than
        # returning "no sources, nothing failed": that return value is the
        # silence #355 was opened for, and a log line cannot stop a future
        # caller acting on it. Unrepresentable beats documented.
        if not self.unpaywall_email:
            raise ValueError(
                "Unpaywall cannot be asked with no email configured; record "
                "a NOT_CONFIGURED skip instead of calling this"
            )

        try:
            # Clean DOI
            doi = self._clean_doi(doi)
            encoded_doi = quote(doi, safe="")

            url = f"https://api.unpaywall.org/v2/{encoded_doi}?email={self.unpaywall_email}"

            response = self._session.get(url, timeout=REQUEST_TIMEOUT)

            if response.status_code == HTTP_NOT_FOUND:
                # Unpaywall answered: it holds no record of this DOI. That is
                # about the article, so it is an absence, not a failure.
                logger.debug(f"DOI not found in Unpaywall: {doi}")
                return sources, None

            response.raise_for_status()
            data = response.json()

            # Every location's PDF URL, best location first. A location with
            # none whose ``url`` is a PMC article page yields the PMC renders
            # instead. "Has a PDF URL" is ``location_pdf_url``'s definition,
            # the one the contract pins, so a blank ``url_for_pdf`` is no PDF
            # here either.
            for location in unpaywall_locations(data):
                pdf_url = location_pdf_url(location)
                if pdf_url:
                    if pdf_url not in [s.url for s in sources]:
                        sources.append(PDFSource(
                            url=pdf_url,
                            source_type=PDFSourceType.UNPAYWALL_OA,
                            is_open_access=True,
                            host_type=location.get("host_type") or "",
                            version=location.get("version") or "",
                            license=location.get("license") or "",
                        ))
                    continue

                pmcid = self._extract_pmcid_from_url(location.get("url") or "")
                if pmcid:
                    # Europe PMC (more reliable), then NCBI PMC as fallback
                    for pmc_url in (
                        f"https://europepmc.org/backend/ptpmcrender.fcgi?accid={pmcid}&blobtype=pdf",
                        f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmcid}/pdf/",
                    ):
                        if pmc_url not in [s.url for s in sources]:
                            sources.append(PDFSource(
                                url=pmc_url,
                                source_type=PDFSourceType.PMC,
                                is_open_access=True,
                                host_type="repository",
                                version=location.get("version") or "",
                            ))

            # Neither a PDF URL nor a PMC page to derive one from. Unpaywall's
            # ``url`` is then the landing page, never the PDF, so it is read
            # for the PDF it declares rather than downloaded as one (#464). A
            # PMC render already in hand is the same article's PDF, so the
            # page is not read beside it.
            landing_failure: SourceLookupFailure | None = None
            if not sources:
                choice = choose_unpaywall_url(data)
                if choice.landing_page:
                    landing_sources, landing_failure = self._resolve_landing_page(
                        choice.landing_page, choice.location or {}
                    )
                    sources.extend(landing_sources)

            # Always try publisher-specific patterns for OA content as fallback
            if data.get("is_oa"):
                publisher_sources = self._discover_publisher_specific(doi)
                for ps in publisher_sources:
                    if ps.url not in [s.url for s in sources]:
                        sources.append(ps)

        except requests.exceptions.RequestException as e:
            # An empty source list used to be indistinguishable, to every
            # caller, from "this article genuinely has no open-access PDF",
            # so a throttled Unpaywall quietly narrowed the evidence base.
            # The failure now travels back with the (empty) list (#347).
            failure = request_failure_from_exception(e)
            logger.warning(
                f"Unpaywall could not be asked about DOI {doi} "
                f"({failure.describe()}), so any open-access copy it knows "
                f"of is not assessed."
            )
            return sources, SourceLookupFailure(SERVICE_UNPAYWALL, failure)

        return sources, landing_failure

    def _resolve_landing_page(
        self, page_url: str, location: Mapping[str, Any]
    ) -> tuple[list[PDFSource], SourceLookupFailure | None]:
        """Read the PDF a landing page Unpaywall names declares (#464).

        The body is read inside the same guard as the request: with
        ``stream=True`` a read that times out or breaks mid-body raises from
        the read, and outside the guard it reached ``_discover_unpaywall``'s
        handler and was blamed on Unpaywall, which had answered.

        Args:
            page_url: The landing page.
            location: The Unpaywall location it came from, for the source's
                host type, version and licence.

        Returns:
            The declared PDF as an Unpaywall source, or no source; and the
            failure that left the page unread, or ``None`` when the page
            answered -- with a PDF, without one, or with a refusal (see
            :func:`web_page_status_unsettled`).
        """
        try:
            response = self._session.get(
                page_url,
                headers={"Accept": LANDING_PAGE_ACCEPT},
                allow_redirects=True,
                timeout=REQUEST_TIMEOUT,
                stream=True,
            )
            with response:
                return self._landing_page_answer(response, location)
        except requests.exceptions.RequestException as e:
            return self._unread_landing_page(request_failure_from_exception(e))
        except ValueError:
            # A redirect whose Location will not parse, as in
            # ``_discover_doi_direct``.
            return self._unread_landing_page(
                RequestFailure(RequestFailureKind.REQUEST_FAILED)
            )

    @staticmethod
    def _unread_landing_page(
        failure: RequestFailure,
    ) -> tuple[list[PDFSource], SourceLookupFailure]:
        """Record a landing page we could not read.

        Args:
            failure: Why it went unread.

        Returns:
            No source, and the failure under the landing page's own name.
        """
        logger.warning(
            "The open-access copy's landing page could not be read (%s), so "
            "any PDF it declares is not assessed.",
            failure.describe(),
        )
        return [], SourceLookupFailure(SERVICE_UNPAYWALL_LANDING_PAGE, failure)

    @staticmethod
    def _landing_page_answer(
        response: requests.Response, location: Mapping[str, Any]
    ) -> tuple[list[PDFSource], SourceLookupFailure | None]:
        """Turn a landing page's answer into a PDF source.

        A page served as a PDF is the PDF (a repository bitstream link), as
        ``_discover_doi_direct`` takes one; the download's ``%PDF`` check
        still has the last word. An HTML page, or one of no stated type, is
        read up to :data:`LANDING_PAGE_MAX_BYTES` for the tag; no other body
        is read, so a large file served as the page is not downloaded here.
        Anything else is the page's answer that it declares nothing.

        Args:
            response: The page's response, its body not yet read.
            location: The Unpaywall location the page came from.

        Returns:
            As :meth:`_resolve_landing_page`.

        Raises:
            requests.exceptions.RequestException: If reading the body fails;
                the caller records it against the page.
        """
        status = response.status_code
        if status >= HTTP_ERROR_STATUS_MIN:
            if web_page_status_unsettled(status):
                return PDFDiscoverer._unread_landing_page(
                    RequestFailure(RequestFailureKind.HTTP_STATUS, status)
                )
            logger.info(
                "The open-access copy's landing page answered HTTP %d; no PDF "
                "from it.",
                status,
            )
            return [], None

        def source(url: str) -> list[PDFSource]:
            """The PDF at ``url`` as an Unpaywall source, with the location's metadata."""
            return [PDFSource(
                url=url,
                source_type=PDFSourceType.UNPAYWALL_OA,
                is_open_access=True,
                host_type=location.get("host_type") or "",
                version=location.get("version") or "",
                license=location.get("license") or "",
            )]

        content_type = response.headers.get("Content-Type", "")
        if LANDING_PAGE_PDF_MARKER in content_type.lower():
            logger.info(
                "The open-access copy's landing page is itself a PDF: %s",
                response.url,
            )
            return source(response.url), None
        if content_type and LANDING_PAGE_HTML_MARKER not in content_type.lower():
            logger.info(
                "The open-access copy's landing page is %s, not HTML; no PDF "
                "declared.",
                content_type,
            )
            return [], None

        body = bytearray()
        for chunk in response.iter_content(chunk_size=LANDING_PAGE_READ_CHUNK_BYTES):
            body.extend(chunk)
            if len(body) >= LANDING_PAGE_MAX_BYTES:
                break
        page = landing_page_text(bytes(body[:LANDING_PAGE_MAX_BYTES]), content_type)
        pdf_url = citation_pdf_url(page, response.url)
        if pdf_url is None:
            logger.info("The open-access copy's landing page declares no PDF.")
            return [], None
        logger.info("The open-access copy's landing page declares %s", pdf_url)
        return source(pdf_url), None

    def _extract_pmcid_from_url(self, url: str) -> Optional[str]:
        """Extract PMCID from a PMC URL."""
        if not url:
            return None
        # Match patterns like /pmc/articles/PMC1234567 or /pmc/articles/1234567
        match = re.search(r'/pmc/articles/(?:PMC)?(\d+)', url, re.IGNORECASE)
        if match:
            return f"PMC{match.group(1)}"
        # Also match standalone numbers in PMC URLs
        if 'pmc' in url.lower() or 'ncbi' in url.lower():
            match = re.search(r'(\d{6,})', url)
            if match:
                return f"PMC{match.group(1)}"
        return None

    def _discover_publisher_specific(self, doi: str) -> List[PDFSource]:
        """Discover PDF using publisher-specific URL patterns.

        Every branch identifies its publisher by the DOI registrant prefix, via
        ``startswith`` on the DOI normalised by :meth:`_clean_doi`. A host name
        found somewhere inside the string is not a publisher identity: matching
        that way lets an arbitrary string be pasted into an article path. Keep
        new branches prefix-anchored.

        Args:
            doi: DOI in any of the forms :meth:`_clean_doi` accepts

        Returns:
            Publisher PDF sources, empty if no branch recognises the registrant
        """
        sources: List[PDFSource] = []
        doi = self._clean_doi(doi)

        # PLOS journals (plosone, plosntds, plosmedicine, plosbiology, etc.)
        if doi.startswith("10.1371/journal."):
            # Extract journal code from DOI (e.g., pntd from journal.pntd.XXXXXXX)
            match = re.match(r"10\.1371/journal\.(\w+)\.", doi)
            if match:
                journal_code = match.group(1)
                # Map short codes to full journal names
                plos_journals = {
                    "pone": "plosone",
                    "pntd": "plosntds",
                    "pmed": "plosmedicine",
                    "pbio": "plosbiology",
                    "pcbi": "ploscompbiol",
                    "pgen": "plosgenetics",
                    "ppat": "plospathogens",
                }
                journal_name = plos_journals.get(journal_code, f"plos{journal_code}")
                pdf_url = f"https://journals.plos.org/{journal_name}/article/file?id={doi}&type=printable"
                sources.append(PDFSource(
                    url=pdf_url,
                    source_type=PDFSourceType.DOI_DIRECT,
                    is_open_access=True,
                    host_type="publisher",
                    version="publishedVersion",
                ))

        # Frontiers journals
        # Prefix-anchored, not a substring test: a string merely containing
        # "frontiersin.org" used to be pasted whole into the article path below,
        # building a URL that could never resolve.
        elif doi.startswith("10.3389/"):
            # Frontiers PDF pattern: https://www.frontiersin.org/articles/10.3389/XXX/pdf
            pdf_url = f"https://www.frontiersin.org/articles/{doi}/pdf"
            sources.append(PDFSource(
                url=pdf_url,
                source_type=PDFSourceType.DOI_DIRECT,
                is_open_access=True,
                host_type="publisher",
                version="publishedVersion",
            ))

        # MDPI journals
        elif doi.startswith("10.3390/"):
            # MDPI PDF pattern: https://www.mdpi.com/XXX-XXX/X/X/XXX/pdf
            # Need to resolve DOI first to get the article path
            pass  # More complex - needs landing page scraping

        # PeerJ
        elif doi.startswith("10.7717/peerj"):
            # PeerJ numbers each series separately, and the series is part of the
            # article slug: 10.7717/peerj.1234 is peerj.com/articles/1234, but
            # 10.7717/peerj-cs.1234 is peerj.com/articles/cs-1234. Taking the
            # text after the last "." drops the series and silently points at a
            # different, existing article in the flagship journal.
            match = re.match(r"10\.7717/peerj(?:-(\w+))?\.(\d+)$", doi)
            if match:
                series, article_number = match.group(1), match.group(2)
                slug = f"{series}-{article_number}" if series else article_number
                pdf_url = f"https://peerj.com/articles/{slug}.pdf"
                sources.append(PDFSource(
                    url=pdf_url,
                    source_type=PDFSourceType.DOI_DIRECT,
                    is_open_access=True,
                    host_type="publisher",
                    version="publishedVersion",
                ))

        # BMC/SpringerOpen (BioMed Central)
        elif doi.startswith("10.1186/"):
            # BMC PDF pattern: article URL + .pdf
            # First need to resolve the DOI to get the article path
            pass  # More complex - needs landing page scraping

        return sources

    def _discover_doi_direct(
        self, doi: str
    ) -> tuple[list[PDFSource], SourceLookupFailure | None]:
        """Try to discover PDF via direct DOI resolution.

        Args:
            doi: The article's DOI.

        Returns:
            Whatever ``doi.org`` resolved to, and the failure that left it
            unsettled. ``doi.org`` is paced at one request a second, so a
            batch will meet this, and an exhausted throttle must not read as
            an article with no copy (#347) -- whether it is raised or, as the
            polite adapter does once its retries run out, handed back as a
            status (#446). A failure after the redirect is named as the
            publisher's; see :func:`doi_resolution_failure`.
        """
        sources: List[PDFSource] = []
        # Every URL that answered, redirects included: an exception that
        # names no request is named by the hop that sent us where we could
        # not follow.
        answered: list[str] = []

        def note_hop(hop: requests.Response, **_kwargs: Any) -> None:
            """Record a hop's URL; ``requests`` calls this for each one."""
            answered.append(hop.url)

        failed_on: str | bytes | None = None
        failure: RequestFailure | None = None
        try:
            doi = self._clean_doi(doi)
            doi_url = f"https://doi.org/{doi}"

            # First, try content negotiation for PDF
            headers = {
                "Accept": "application/pdf",
                "User-Agent": USER_AGENT,
            }

            response = self._session.head(
                doi_url,
                headers=headers,
                allow_redirects=True,
                timeout=REQUEST_TIMEOUT,
                hooks={"response": note_hop},
            )
        except requests.exceptions.RequestException as e:
            # The exception names the request it failed on, which after a
            # redirect is the publisher's, not doi.org's.
            if e.request is not None:
                failed_on = e.request.url
            failure = request_failure_from_exception(e)
        except ValueError:
            # A redirect whose Location will not parse ("http://[bad/x")
            # raises a bare ValueError from inside requests. Escaping, it
            # threw away the sources the earlier tiers had found.
            failure = RequestFailure(RequestFailureKind.REQUEST_FAILED)
        if failure is not None:
            if failed_on is None and answered:
                failed_on = answered[-1]
            lookup_failure = SourceLookupFailure(
                doi_lookup_service(failed_on), failure
            )
            self._log_doi_lookup_failure(doi, lookup_failure)
            return sources, lookup_failure

        status_failure = doi_resolution_failure(response.status_code, response.url)
        if status_failure is not None:
            self._log_doi_lookup_failure(doi, status_failure)
            return sources, status_failure
        if response.status_code >= HTTP_ERROR_STATUS_MIN:
            logger.debug(
                f"DOI {doi} resolved to HTTP {response.status_code} from "
                f"{doi_lookup_service(response.url)}; no PDF by content "
                f"negotiation"
            )
            return sources, None

        # Check if we got a PDF response
        content_type = response.headers.get("Content-Type", "")
        if "pdf" in content_type.lower():
            sources.append(PDFSource(
                url=response.url,
                source_type=PDFSourceType.DOI_DIRECT,
                is_open_access=False,  # May or may not be OA
                host_type="publisher",
                version="publishedVersion",
            ))

        return sources, None

    @staticmethod
    def _log_doi_lookup_failure(doi: str, failure: SourceLookupFailure) -> None:
        """Log a DOI lookup that left the question open.

        At warning: at debug, a throttled doi.org left no trace at all under
        the default INFO configuration -- the reader saw "no full text" and
        the log said nothing had happened.

        Args:
            doi: The DOI asked about.
            failure: What stopped it being answered.
        """
        logger.warning(
            f"The lookup of DOI {doi} went unsettled at {failure.service} "
            f"({failure.failure.describe()}), so any copy it resolves to is "
            f"not assessed."
        )

    def _clean_doi(self, doi: str) -> str:
        """Clean and normalize a DOI to its bare ``10.x/...`` form.

        Accepts the resolver forms that turn up in real metadata:
        ``doi.org``, ``www.doi.org`` and ``dx.doi.org`` URLs over either
        scheme, a ``doi:``/``DOI:`` prefix, and surrounding whitespace.
        Anything else is returned as given -- publisher matching is
        prefix-anchored, so an unrecognised form simply matches no branch
        rather than being coerced into one.

        Args:
            doi: DOI in any of the above forms

        Returns:
            The DOI with any recognised resolver prefix removed
        """
        doi = doi.strip()
        # Remove common prefixes
        prefixes = [
            "https://doi.org/",
            "http://doi.org/",
            "https://www.doi.org/",
            "http://www.doi.org/",
            "https://dx.doi.org/",
            "http://dx.doi.org/",
            "doi:",
            "DOI:",
        ]
        for prefix in prefixes:
            if doi.lower().startswith(prefix.lower()):
                doi = doi[len(prefix):]
        return doi

    def _try_download(
        self,
        source: PDFSource,
        output_path: Path,
        expected_title: Optional[str],
    ) -> DiscoveryResult:
        """Try to download PDF from a source."""
        logger.info(f"Attempting download from {source.source_type.value}: {source.url}")
        self._emit_progress("download", "starting")

        try:
            response = self._session.get(
                source.url,
                stream=True,
                timeout=REQUEST_TIMEOUT,
                allow_redirects=True,
            )

            # Read the start of the body once. Sniffing it (paywall text / PDF
            # magic bytes) consumes bytes from the stream, and iter_content
            # does NOT rewind, so this prefix is reused when writing the file
            # - otherwise the saved PDF would be missing its header. A read
            # that fails here is the transport's failure and propagates to
            # the handlers below: swallowed, it left an empty prefix that a
            # PDF Content-Type let through as a 0-byte "PDF" (#478).
            content_iter = response.iter_content(chunk_size=8192)
            body_prefix = read_body_prefix(content_iter, len(PDF_MAGIC_BYTES))

            # A broken server is not a paywall. The paywall sniff below
            # treats any text/html body whose URL contains "access" as a
            # paywall, which matches every ".../openaccess/..." URL, so a
            # persistent 503 would be reported to the reader as "requires
            # institutional subscription". Until this module owned its own
            # throttle retries, urllib3's Retry raised on a persistent 503
            # and the sniff was never reached; the status is now classified
            # here instead, so any non-2xx that is not a genuine paywall
            # signal takes the error path it always took.
            if (
                response.status_code >= HTTP_ERROR_STATUS_MIN
                and response.status_code not in PAYWALL_HTTP_STATUSES
            ):
                response.raise_for_status()

            # Check for paywall indicators
            if self._is_paywall_response(response, source.url, body_prefix):
                logger.info(f"Paywall detected at {source.url}")
                return DiscoveryResult(
                    success=False,
                    is_paywall=True,
                    paywall_url=source.url,
                    error="Access requires institutional subscription or purchase.",
                    failure=refused_download_failure(response.status_code),
                )

            response.raise_for_status()

            # Verify it's actually a PDF, whatever it was served as: a login
            # or challenge page labelled application/pdf is not the PDF, and
            # saved as one it was served from the cache ever after (#478).
            content_type = response.headers.get("Content-Type", "")
            if not self._looks_like_pdf(body_prefix):
                logger.warning(f"Response is not a PDF: {content_type}")
                return DiscoveryResult(
                    success=False,
                    error=f"Server returned non-PDF content: {content_type}",
                    failure=RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                )

            # Check file size
            content_length = response.headers.get("Content-Length")
            if content_length and int(content_length) > MAX_PDF_SIZE:
                return DiscoveryResult(
                    success=False,
                    error=f"PDF too large ({int(content_length) / 1024 / 1024:.1f} MB)",
                    refused_for_size=True,
                )

            # Save the PDF, writing the already-consumed prefix first. The
            # body goes to a partial file renamed into place only once the
            # stream has ended: written straight to ``output_path``, a
            # download that broke off left a truncated file there, which the
            # cache lookup served as the whole article on every later run.
            output_path.parent.mkdir(parents=True, exist_ok=True)
            if self._cancelled:
                return DiscoveryResult(success=False, error="Cancelled")
            partial = partial_download_path(output_path)
            try:
                with open(partial, "wb") as f:
                    f.write(body_prefix)
                    for chunk in content_iter:
                        if self._cancelled:
                            return DiscoveryResult(success=False, error="Cancelled")
                        f.write(chunk)
                partial.replace(output_path)
            finally:
                discard_partial_download(partial)

            self._emit_progress("download", "success")

            # Verify the downloaded file
            verification_warning = None
            if expected_title:
                self._emit_progress("verification", "starting")
                is_valid, warning = self._verify_pdf_content(output_path, expected_title)
                if not is_valid:
                    verification_warning = warning
                    self._emit_progress("verification", "mismatch")
                else:
                    self._emit_progress("verification", "success")

            return DiscoveryResult(
                success=True,
                file_path=output_path,
                source=source,
                verification_warning=verification_warning,
            )

        except requests.exceptions.HTTPError as e:
            if (
                e.response is not None
                and e.response.status_code in PAYWALL_HTTP_STATUSES
            ):
                return DiscoveryResult(
                    success=False,
                    is_paywall=True,
                    paywall_url=source.url,
                    error="Access denied - may require institutional access.",
                    failure=refused_download_failure(e.response.status_code),
                )
            logger.warning(f"HTTP error downloading from {source.url}: {e}")
            return DiscoveryResult(
                success=False,
                error=str(e),
                failure=request_failure_from_exception(e),
            )

        except requests.exceptions.RequestException as e:
            # Includes an address ``requests`` will not send at all -- an
            # ``ftp:``, ``file:`` or relative ``url_for_pdf`` raises
            # InvalidSchema / MissingSchema / InvalidURL before any request
            # -- which reads as REQUEST_FAILED, as the apps refuse it (#478).
            logger.warning(f"Request error downloading from {source.url}: {e}")
            return DiscoveryResult(
                success=False,
                error=str(e),
                failure=request_failure_from_exception(e),
            )

        except OSError as e:
            # After the ``requests`` handlers, whose exceptions are OSErrors
            # too: what is left is ours, a file that could not be written.
            # The source served the PDF, so it is no answer about the copy.
            # It is recorded as a NOT_SAVED skip with its address, which keeps
            # the discovery from concluding there is no full text and is told
            # as a caching note (#480).
            logger.error(f"Could not save the PDF from {source.url}: {e}")
            return DiscoveryResult(
                success=False,
                error=f"The PDF could not be saved: {e}",
                not_saved=True,
            )

        except Exception as e:
            logger.exception(f"Unexpected error downloading from {source.url}")
            return DiscoveryResult(
                success=False,
                error=str(e),
                failure=RequestFailure(RequestFailureKind.REQUEST_FAILED),
            )

    def _try_browser_download(
        self,
        source: PDFSource,
        output_path: Path,
        expected_title: Optional[str],
    ) -> DiscoveryResult:
        """
        Try to download PDF using browser session.

        Used as fallback when regular HTTP requests are blocked by bot protection.

        Args:
            source: PDF source to download from
            output_path: Path to save the PDF
            expected_title: Expected document title for verification

        Returns:
            DiscoveryResult with success status
        """
        logger.info(f"Browser download attempt: {source.url}")
        self._emit_progress("download", "browser")

        try:
            browser = get_browser_session(headless=self.browser_headless)
            if browser is None:
                return DiscoveryResult(
                    success=False,
                    error="Browser session not available",
                )

            success, error = browser.download_pdf(source.url, output_path)

            if not success:
                logger.warning(f"Browser download failed: {error}")
                return DiscoveryResult(success=False, error=error)

            self._emit_progress("download", "success")

            # Verify the downloaded file
            verification_warning = None
            if expected_title:
                self._emit_progress("verification", "starting")
                is_valid, warning = self._verify_pdf_content(output_path, expected_title)
                if not is_valid:
                    verification_warning = warning
                    self._emit_progress("verification", "mismatch")
                else:
                    self._emit_progress("verification", "success")

            return DiscoveryResult(
                success=True,
                file_path=output_path,
                source=source,
                verification_warning=verification_warning,
            )

        except Exception as e:
            logger.exception(f"Browser download error for {source.url}")
            return DiscoveryResult(success=False, error=str(e))

    def _is_paywall_response(
        self,
        response: requests.Response,
        url: str,
        body_prefix: bytes = b"",
    ) -> bool:
        """Check if response indicates a paywall.

        Args:
            response: The HTTP response (used for status/headers/url only).
            url: The requested URL.
            body_prefix: The already-read start of the response body. Passed in
                by the caller so this check does not consume the stream that is
                still needed to write the file.
        """
        # Check status code
        if response.status_code in PAYWALL_HTTP_STATUSES:
            return True

        # Check content type - HTML usually means landing page
        content_type = response.headers.get("Content-Type", "")
        if "text/html" in content_type.lower():
            # Check for paywall keywords in URL or response
            paywall_indicators = [
                "login", "signin", "sign-in", "access",
                "subscribe", "purchase", "pay", "buy",
                "restricted", "authentication",
            ]
            url_lower = response.url.lower()
            if any(ind in url_lower for ind in paywall_indicators):
                return True

            # Check the already-read start of the body for paywall text
            content_text = body_prefix.decode("utf-8", errors="ignore").lower()
            paywall_texts = [
                "access denied", "not authorized", "subscription required",
                "purchase article", "buy this article", "institutional access",
                "log in to access", "sign in required",
            ]
            if any(text in content_text for text in paywall_texts):
                return True

        return False

    def _looks_like_pdf(self, body_prefix: bytes) -> bool:
        """Check if the response body starts with PDF magic bytes.

        Args:
            body_prefix: The already-read start of the response body.
        """
        return body_prefix.startswith(PDF_MAGIC_BYTES)

    def _verify_pdf_content(
        self,
        pdf_path: Path,
        expected_title: str,
    ) -> Tuple[bool, Optional[str]]:
        """
        Verify that downloaded PDF matches expected content.

        Args:
            pdf_path: Path to PDF file
            expected_title: Expected document title

        Returns:
            Tuple of (is_valid, warning_message)
        """
        try:
            import fitz  # PyMuPDF

            doc = fitz.open(str(pdf_path))
            if doc.page_count == 0:
                return False, "PDF has no pages"

            # Extract text from first page
            first_page = doc[0]
            text = first_page.get_text()
            doc.close()

            if not text.strip():
                return False, "PDF contains no extractable text"

            # Check if title appears in first page (fuzzy match)
            title_words = self._extract_title_words(expected_title)
            text_lower = text.lower()

            matched_words = sum(1 for word in title_words if word in text_lower)
            match_ratio = matched_words / len(title_words) if title_words else 0

            if match_ratio < 0.5:  # Less than 50% of title words found
                return False, f"PDF content may not match expected document. Title match: {match_ratio:.0%}"

            return True, None

        except Exception as e:
            logger.warning(f"PDF verification failed: {e}")
            return True, f"Could not verify PDF content: {e}"

    def _extract_title_words(self, title: str) -> List[str]:
        """Extract significant words from title for matching."""
        # Remove common words and punctuation
        stop_words = {
            "a", "an", "the", "and", "or", "but", "in", "on", "at", "to",
            "for", "of", "with", "by", "from", "as", "is", "was", "are",
            "were", "been", "be", "have", "has", "had", "do", "does", "did",
        }
        words = re.findall(r"\b\w+\b", title.lower())
        return [w for w in words if len(w) > 2 and w not in stop_words]
