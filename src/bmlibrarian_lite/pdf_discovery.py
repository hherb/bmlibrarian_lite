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
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote, urljoin, urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

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
    """Result of PDF discovery attempt."""

    success: bool
    file_path: Optional[Path] = None
    source: Optional[PDFSource] = None
    error: Optional[str] = None
    is_paywall: bool = False
    paywall_url: Optional[str] = None
    verification_warning: Optional[str] = None


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
            unpaywall_email: Email for Unpaywall API (required for Unpaywall)
            openathens_url: OpenAthens institution URL for authenticated access
            progress_callback: Callback for progress updates (stage, status)
            use_browser_fallback: If True, use browser for bot-protected downloads
            browser_headless: If True, run browser without visible window
        """
        self.unpaywall_email = unpaywall_email
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

        # Configure retry strategy
        retry_strategy = Retry(
            total=3,
            backoff_factor=1,
            status_forcelist=[429, 500, 502, 503, 504],
            allowed_methods=["HEAD", "GET"],
        )
        adapter = HTTPAdapter(max_retries=retry_strategy)
        session.mount("http://", adapter)
        session.mount("https://", adapter)

        return session

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

        Returns:
            DiscoveryResult with success status and details
        """
        self._cancelled = False
        self._emit_progress("discovery", "starting")

        # Find all available PDF sources
        sources = self._discover_sources(doi, pmid, pmcid)

        if self._cancelled:
            return DiscoveryResult(success=False, error="Cancelled")

        if not sources:
            self._emit_progress("discovery", "not_found")
            return DiscoveryResult(
                success=False,
                error="No PDF sources found. The document may require institutional access.",
            )

        # Sort by priority
        sources.sort(key=lambda s: s.priority, reverse=True)

        logger.info(f"Found {len(sources)} PDF sources for DOI={doi}, PMID={pmid}")
        for src in sources:
            logger.debug(f"  - {src.source_type.value}: {src.url} (priority={src.priority})")

        # Try to download from each source
        last_paywall_result: Optional[DiscoveryResult] = None
        blocked_oa_sources: List[PDFSource] = []  # Track sources blocked by bot protection

        for source in sources:
            if self._cancelled:
                return DiscoveryResult(success=False, error="Cancelled")

            self._emit_progress("discovery", "found_oa" if source.is_open_access else "found")
            result = self._try_download(source, output_path, expected_title or title)

            if result.success:
                return result

            if result.is_paywall:
                # For open access sources, a 403 might be bot protection, not paywall
                # Keep trying other sources first
                if source.is_open_access:
                    logger.info(f"Source {source.url} blocked (may be bot protection), trying next source")
                    blocked_oa_sources.append(source)
                    last_paywall_result = result
                    continue
                else:
                    # For non-OA sources, return paywall result so caller can offer OpenAthens auth
                    return result

        # If we have blocked OA sources and browser fallback is enabled, try browser
        if blocked_oa_sources and self.use_browser_fallback:
            self._emit_progress("download", "browser_fallback")
            logger.info("Trying browser-based download for bot-protected sources...")

            for source in blocked_oa_sources:
                if self._cancelled:
                    return DiscoveryResult(success=False, error="Cancelled")

                result = self._try_browser_download(source, output_path, expected_title or title)
                if result.success:
                    return result

        # If we had a paywall result but no success, return it for OpenAthens option
        if last_paywall_result:
            return last_paywall_result

        return DiscoveryResult(
            success=False,
            error="Failed to download PDF from any available source.",
        )

    def _discover_sources(
        self,
        doi: Optional[str],
        pmid: Optional[str],
        pmcid: Optional[str],
    ) -> List[PDFSource]:
        """Discover all available PDF sources."""
        sources: List[PDFSource] = []

        # Try PMC first (most reliable for open access)
        if pmcid or pmid:
            pmc_sources = self._discover_pmc(pmid, pmcid)
            sources.extend(pmc_sources)

        # Try Unpaywall
        if doi and self.unpaywall_email:
            unpaywall_sources = self._discover_unpaywall(doi)
            sources.extend(unpaywall_sources)

        # Try publisher-specific patterns (even if Unpaywall didn't find it)
        if doi:
            publisher_sources = self._discover_publisher_specific(doi)
            for ps in publisher_sources:
                if ps.url not in [s.url for s in sources]:
                    sources.append(ps)

        # Try direct DOI resolution as last resort
        if doi:
            doi_sources = self._discover_doi_direct(doi)
            for ds in doi_sources:
                if ds.url not in [s.url for s in sources]:
                    sources.append(ds)

        return sources

    def _discover_pmc(
        self,
        pmid: Optional[str],
        pmcid: Optional[str],
    ) -> List[PDFSource]:
        """Discover PDF from PubMed Central and Europe PMC."""
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
            return sources

        # If we only have PMID, try to get PMCID via eutils
        if pmid:
            pmcid = self._get_pmcid_from_pmid(pmid)
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

        return sources

    def _get_pmcid_from_pmid(self, pmid: str) -> Optional[str]:
        """Get PMCID from PMID using NCBI ID converter."""
        try:
            url = (
                f"https://www.ncbi.nlm.nih.gov/pmc/utils/idconv/v1.0/"
                f"?ids={pmid}&format=json"
            )
            response = self._session.get(url, timeout=REQUEST_TIMEOUT)
            response.raise_for_status()

            data = response.json()
            records = data.get("records", [])
            if records and "pmcid" in records[0]:
                return records[0]["pmcid"]

        except Exception as e:
            logger.debug(f"Failed to convert PMID to PMCID: {e}")

        return None

    def _discover_unpaywall(self, doi: str) -> List[PDFSource]:
        """Discover PDF sources via Unpaywall API."""
        sources: List[PDFSource] = []

        if not self.unpaywall_email:
            return sources

        try:
            # Clean DOI
            doi = self._clean_doi(doi)
            encoded_doi = quote(doi, safe="")

            url = f"https://api.unpaywall.org/v2/{encoded_doi}?email={self.unpaywall_email}"

            response = self._session.get(url, timeout=REQUEST_TIMEOUT)

            if response.status_code == 404:
                logger.debug(f"DOI not found in Unpaywall: {doi}")
                return sources

            response.raise_for_status()
            data = response.json()

            # Check for best open access location
            best_oa = data.get("best_oa_location")
            if best_oa and best_oa.get("url_for_pdf"):
                sources.append(PDFSource(
                    url=best_oa["url_for_pdf"],
                    source_type=PDFSourceType.UNPAYWALL_OA,
                    is_open_access=True,
                    host_type=best_oa.get("host_type", ""),
                    version=best_oa.get("version", ""),
                    license=best_oa.get("license", ""),
                ))

            # Also check all OA locations
            for location in data.get("oa_locations", []):
                pdf_url = location.get("url_for_pdf")
                if pdf_url and pdf_url not in [s.url for s in sources]:
                    sources.append(PDFSource(
                        url=pdf_url,
                        source_type=PDFSourceType.UNPAYWALL_OA,
                        is_open_access=True,
                        host_type=location.get("host_type", ""),
                        version=location.get("version", ""),
                        license=location.get("license", ""),
                    ))

                # If no pdf_url but there's a PMC URL, extract PMCID and add PMC sources
                if not pdf_url:
                    loc_url = location.get("url", "")
                    pmcid = self._extract_pmcid_from_url(loc_url)
                    if pmcid:
                        # Europe PMC (more reliable)
                        europepmc_url = f"https://europepmc.org/backend/ptpmcrender.fcgi?accid={pmcid}&blobtype=pdf"
                        if europepmc_url not in [s.url for s in sources]:
                            sources.append(PDFSource(
                                url=europepmc_url,
                                source_type=PDFSourceType.PMC,
                                is_open_access=True,
                                host_type="repository",
                                version=location.get("version", ""),
                            ))

                        # NCBI PMC as fallback
                        ncbi_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmcid}/pdf/"
                        if ncbi_url not in [s.url for s in sources]:
                            sources.append(PDFSource(
                                url=ncbi_url,
                                source_type=PDFSourceType.PMC,
                                is_open_access=True,
                                host_type="repository",
                                version=location.get("version", ""),
                            ))

            # Always try publisher-specific patterns for OA content as fallback
            if data.get("is_oa"):
                publisher_sources = self._discover_publisher_specific(doi)
                for ps in publisher_sources:
                    if ps.url not in [s.url for s in sources]:
                        sources.append(ps)

        except requests.exceptions.RequestException as e:
            logger.warning(f"Unpaywall API error for DOI {doi}: {e}")

        return sources

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
        """Discover PDF using publisher-specific URL patterns."""
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
        elif "frontiersin.org" in doi or doi.startswith("10.3389/"):
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
            # PeerJ PDF pattern
            pdf_url = f"https://peerj.com/articles/{doi.split('.')[-1]}.pdf"
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

    def _discover_doi_direct(self, doi: str) -> List[PDFSource]:
        """Try to discover PDF via direct DOI resolution."""
        sources: List[PDFSource] = []

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
            )

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

        except requests.exceptions.RequestException as e:
            logger.debug(f"DOI direct resolution failed for {doi}: {e}")

        return sources

    def _clean_doi(self, doi: str) -> str:
        """Clean and normalize a DOI."""
        doi = doi.strip()
        # Remove common prefixes
        prefixes = ["https://doi.org/", "http://doi.org/", "doi:", "DOI:"]
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

            # Check for paywall indicators
            if self._is_paywall_response(response, source.url):
                logger.info(f"Paywall detected at {source.url}")
                return DiscoveryResult(
                    success=False,
                    is_paywall=True,
                    paywall_url=source.url,
                    error="Access requires institutional subscription or purchase.",
                )

            response.raise_for_status()

            # Verify it's actually a PDF
            content_type = response.headers.get("Content-Type", "")
            if "pdf" not in content_type.lower() and not self._looks_like_pdf(response):
                logger.warning(f"Response is not a PDF: {content_type}")
                return DiscoveryResult(
                    success=False,
                    error=f"Server returned non-PDF content: {content_type}",
                )

            # Check file size
            content_length = response.headers.get("Content-Length")
            if content_length and int(content_length) > MAX_PDF_SIZE:
                return DiscoveryResult(
                    success=False,
                    error=f"PDF too large ({int(content_length) / 1024 / 1024:.1f} MB)",
                )

            # Save the PDF
            output_path.parent.mkdir(parents=True, exist_ok=True)
            with open(output_path, "wb") as f:
                for chunk in response.iter_content(chunk_size=8192):
                    if self._cancelled:
                        output_path.unlink(missing_ok=True)
                        return DiscoveryResult(success=False, error="Cancelled")
                    f.write(chunk)

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
            if e.response is not None and e.response.status_code in [401, 403]:
                return DiscoveryResult(
                    success=False,
                    is_paywall=True,
                    paywall_url=source.url,
                    error="Access denied - may require institutional access.",
                )
            logger.warning(f"HTTP error downloading from {source.url}: {e}")
            return DiscoveryResult(success=False, error=str(e))

        except requests.exceptions.RequestException as e:
            logger.warning(f"Request error downloading from {source.url}: {e}")
            return DiscoveryResult(success=False, error=str(e))

        except Exception as e:
            logger.exception(f"Unexpected error downloading from {source.url}")
            return DiscoveryResult(success=False, error=str(e))

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

    def _is_paywall_response(self, response: requests.Response, url: str) -> bool:
        """Check if response indicates a paywall."""
        # Check status code
        if response.status_code in [401, 403]:
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

            # Check first part of response body for paywall text
            try:
                # Read just the beginning to check
                content_start = next(response.iter_content(chunk_size=4096), b"")
                content_text = content_start.decode("utf-8", errors="ignore").lower()
                paywall_texts = [
                    "access denied", "not authorized", "subscription required",
                    "purchase article", "buy this article", "institutional access",
                    "log in to access", "sign in required",
                ]
                if any(text in content_text for text in paywall_texts):
                    return True
            except Exception:
                pass

        return False

    def _looks_like_pdf(self, response: requests.Response) -> bool:
        """Check if response content starts with PDF magic bytes."""
        try:
            # Read first few bytes
            content_start = next(response.iter_content(chunk_size=8), b"")
            return content_start.startswith(b"%PDF")
        except Exception:
            return False

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
