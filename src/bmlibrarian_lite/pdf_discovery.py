"""
PDF discovery and download functionality for BMLibrarian Lite.

Provides multiple methods for discovering and downloading PDF files:
- Unpaywall API for open access PDFs
- PubMed Central (PMC) for free full text
- Direct DOI resolution via CrossRef/content negotiation

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
from dataclasses import dataclass
from enum import Enum
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple
from urllib.parse import quote, urljoin, urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

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
    - Content verification
    """

    def __init__(
        self,
        unpaywall_email: Optional[str] = None,
        openathens_url: Optional[str] = None,
        progress_callback: Optional[Callable[[str, str], None]] = None,
    ) -> None:
        """
        Initialize PDF discoverer.

        Args:
            unpaywall_email: Email for Unpaywall API (required for Unpaywall)
            openathens_url: OpenAthens institution URL for authenticated access
            progress_callback: Callback for progress updates (stage, status)
        """
        self.unpaywall_email = unpaywall_email
        self.openathens_url = openathens_url
        self.progress_callback = progress_callback
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
        for source in sources:
            if self._cancelled:
                return DiscoveryResult(success=False, error="Cancelled")

            self._emit_progress("discovery", "found_oa" if source.is_open_access else "found")
            result = self._try_download(source, output_path, expected_title or title)

            if result.success:
                return result

            if result.is_paywall:
                # Return paywall result so caller can offer OpenAthens auth
                return result

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

        # Try direct DOI resolution
        if doi:
            doi_sources = self._discover_doi_direct(doi)
            sources.extend(doi_sources)

        return sources

    def _discover_pmc(
        self,
        pmid: Optional[str],
        pmcid: Optional[str],
    ) -> List[PDFSource]:
        """Discover PDF from PubMed Central."""
        sources: List[PDFSource] = []

        # If we have PMCID, construct direct link
        if pmcid:
            pmc_id = pmcid if pmcid.startswith("PMC") else f"PMC{pmcid}"
            pdf_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmc_id}/pdf/"
            sources.append(PDFSource(
                url=pdf_url,
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
                pdf_url = f"https://www.ncbi.nlm.nih.gov/pmc/articles/{pmcid}/pdf/"
                sources.append(PDFSource(
                    url=pdf_url,
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

        except requests.exceptions.RequestException as e:
            logger.warning(f"Unpaywall API error for DOI {doi}: {e}")

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
