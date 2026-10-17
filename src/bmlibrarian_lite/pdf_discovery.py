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
- Elsevier's Article API, for an Elsevier article's PDF (with a key)
- Unpaywall API for open access PDFs
- OpenAlex's locations, for open access PDFs Unpaywall did not name
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
from collections import deque
from collections.abc import Iterable, Iterator, Mapping
from dataclasses import dataclass, replace
from enum import Enum
from pathlib import Path
from typing import Any, Callable, List, Optional, assert_never
from urllib.parse import quote, urlparse

import requests
from urllib3.util.retry import Retry

from .constants import (
    CHALLENGE_BODY_PREFIX_BYTES,
    CHALLENGE_GONE_STATUSES,
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
    POLITE_MAX_THROTTLE_RETRIES,
    RETRYABLE_HTTP_STATUSES,
    SERVICE_DOI_PUBLISHER,
    SERVICE_DOI_RESOLVER,
    SERVICE_ELSEVIER,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_PDF_DOWNLOAD,
    SERVICE_PMC_ID_CONVERTER,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
)
from .analysis_failures import (
    address_host,
    no_pdf_sources_message,
    paywall_message,
    not_saved_note,
    tried_sources_statement,
    unestablished_access_clause,
    with_unestablished_access,
)
from .bot_walls import challenge_failure, challenge_markers
from .core_api import CoreFetch
from .data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from .identifiers import is_canonical_pmid, read_caller_ids
from .elsevier_api import ElsevierArticleClient, ElsevierFetch, ElsevierOutcome, elsevier_eligible
from .oa_landing_page import (
    choose_unpaywall_url,
    citation_pdf_url,
    landing_page_text,
    location_pdf_url,
    unpaywall_locations,
)
from .openalex import OpenAlexLocationsClient, untried_pdf_urls
# Shared with the clients that download a PDF themselves (#480, stage C2).
from .pdf_download import (
    MAX_PDF_SIZE,
    discard_partial_download,
    partial_download_path,
    read_body_prefix,
    unchecked_download_path,
)
from .pdf_library_check import is_kept, set_aside
from .pdf_title_check import TitleCheck, TitleCheckOutcome, check_pdf_title
from .polite_session import mount_politely
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
# The download path (``_try_download``) does NOT yet
# follow it -- it still puts ``str(e)`` into the reader-facing ``error``
# field. Those URLs are publisher and PMC ones
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


# User agent for HTTP requests
USER_AGENT = "BMLibrarian/1.0 (https://github.com/hherb/bmlibrarian-lite; mailto:support@bmlibrarian.org)"

# Timeout for HTTP requests (seconds)
REQUEST_TIMEOUT = 30



class PDFSourceType(Enum):
    """Type of PDF source."""

    UNPAYWALL_OA = "unpaywall_oa"  # Open access via Unpaywall
    PMC = "pmc"  # PubMed Central
    DOI_DIRECT = "doi_direct"  # Direct from DOI/publisher
    OPENATHENS = "openathens"  # Via institutional access
    OPENALEX_OA = "openalex_oa"  # A PDF an OpenAlex location names (#480)
    ELSEVIER_API = "elsevier_api"  # Elsevier's Article API, by DOI (#480, stage C2)
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
            (#347) or were never made (#355), every open-access PDF
            (Unpaywall's or OpenAlex's) that could not be obtained (#478,
            #480), and a PDF served but not saved (a ``NOT_SAVED`` caching
            note, #480). Empty means every lookup this discovery could make
            was made and answered, and every copy tried was saved.
            Independent of
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
            discovery can record an open-access PDF it could not obtain
            (#478, #480).
        refused_for_size: Whether the source offered a PDF larger than
            :data:`MAX_PDF_SIZE`. Our limit rather than the source's answer,
            so it is no ``failure``; but the copy exists and went unread,
            so an open-access PDF refused for its size is still recorded as
            unassessed (#478).
        not_saved: The source served the PDF and it could not be written
            here: a fault of ours, told as a caching note (#480). Not a
            ``failure``: the source answered.
        text: CORE's extracted text, when no PDF was obtained and CORE
            served the article (#480, stage C); only with ``success`` and
            no ``file_path``, and never blank.
        wrong_article: The source served a PDF whose first page with text
            does not carry the title: another article's, set aside unread
            (#541). Not a ``failure``: the source answered, about another
            article, so the right PDF may exist elsewhere.
        set_aside: Where the discovery set aside each downloaded PDF that is
            another article's, whatever its outcome (#541), so the reader
            can be told and keep one the check misjudged.

    Raises:
        ValueError: On construction, if a successful result carries a
            failure, a size refusal, a not-saved flag or a wrong article, or
            if more than one of those four is set: each is a different
            answer to why no PDF was obtained, and only one is recorded. Also if CORE's ``text`` is carried by anything but a
            success without a file.
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
    text: str | None = None
    wrong_article: bool = False
    set_aside: tuple[Path, ...] = ()

    def __post_init__(self) -> None:
        """Refuse a success that says why no PDF was obtained, or two whys."""
        if self.text is not None and (not self.success or self.file_path is not None):
            raise ValueError("CORE's text is a success without a file")
        if self.text is not None and not self.text.strip():
            raise ValueError("A blank text is not CORE's full text")
        whys = sum(
            (self.failure is not None, self.refused_for_size, self.not_saved, self.wrong_article)
        )
        if self.success and whys:
            raise ValueError("A downloaded PDF carries no download failure")
        if whys > 1:
            raise ValueError(
                "A download failure, a size refusal, a copy not saved and "
                "another article's PDF exclude one another"
            )

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
    """The failure a download met by a paywall records, when no wall was recognised.

    A refusal status (401, 403) is that status, which the reader is told
    "did not serve it". A page served with a success status in place of the
    PDF -- a login form, say -- is a body that is not the PDF,
    ``MALFORMED_RESPONSE``: that says nothing about the article, so the
    reader is told the copy could not be asked (#478). An open-access copy's
    page that :func:`~bmlibrarian_lite.bot_walls.challenge_failure`
    recognises as a bot wall's challenge never reaches here: it is recorded
    as ``CHALLENGED`` and is no paywall (#480).

    Args:
        status_code: The status the page was served with.

    Returns:
        The failure to record.
    """
    if status_code >= HTTP_ERROR_STATUS_MIN:
        return RequestFailure(RequestFailureKind.HTTP_STATUS, status_code)
    return RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)


def read_more_of_prefix(chunks: Iterator[bytes], prefix: bytes, up_to: int) -> bytes:
    """Read on from an answer's prefix, as far as ``up_to`` bytes in all.

    For a non-PDF answer, whose page is read to recognise a challenge
    (#480). A stream that breaks here ends the read: what was already
    read still decides, so a challenge page is not lost to its own
    connection closing.

    Args:
        chunks: The rest of the body.
        prefix: What was read already.
        up_to: The most bytes to hold in all.

    Returns:
        ``prefix`` and what followed it, up to ``up_to`` bytes.
    """
    more = bytearray(prefix)
    try:
        for chunk in chunks:
            more += chunk
            if len(more) >= up_to:
                break
    except requests.exceptions.RequestException as e:
        logger.debug(f"An answer's stream broke after {len(more)} bytes of its page: {e!r}")
    return bytes(more[:up_to])


#: Whose PDF an unobtained open-access copy is recorded against (#478, #480);
#: also the sources whose non-PDF answers are read for a bot wall's challenge.
_UNOBTAINED_PDF_SERVICE = {
    PDFSourceType.UNPAYWALL_OA: SERVICE_UNPAYWALL_PDF,
    PDFSourceType.OPENALEX_OA: SERVICE_OPENALEX_PDF,
}


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


def wrong_article_pdf(source: "PDFSource") -> LookupRecord:
    """Record a PDF a source served that is another article's (#541).

    Any source's, open access or not: another article's PDF says nothing
    about this one, so the question stays open. Recorded with its address,
    under the copy's own name when an open-access source named it and under
    the download otherwise, as a copy not saved is.

    Args:
        source: The source whose PDF was set aside.

    Returns:
        A ``WRONG_ARTICLE`` skip with the PDF's address.
    """
    service = _UNOBTAINED_PDF_SERVICE.get(source.source_type, SERVICE_PDF_DOWNLOAD)
    return LookupRecord(
        skipped=(SourceLookupSkipped(service, LookupSkipReason.WRONG_ARTICLE, source.url),)
    )


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


def default_openalex_client(mailto: str | None) -> OpenAlexLocationsClient:
    """The OpenAlex client a discoverer asks when none is injected.

    A module-level seam so ``tests/conftest.py`` can keep every discovery in
    the test suite off the real OpenAlex.

    Args:
        mailto: The contact email, already checked usable, or ``None``.

    Returns:
        A client on OpenAlex itself.
    """
    return OpenAlexLocationsClient(mailto=mailto)


class _CoreFallback:
    """CORE's text, asked at most once, at the first exit that obtained no PDF.

    Asked inside the discovery rather than after it, so a failure is in the
    record before the reader's sentence is built from it (#480, stage C).
    """

    def __init__(self, fetch: Callable[[str], CoreFetch] | None, doi: str | None) -> None:
        """Hold CORE's fetch for this DOI.

        Args:
            fetch: Asks CORE for one DOI's text; ``None`` when no CORE is
                configured.
            doi: The cleaned DOI; without one CORE is not asked.
        """
        self._fetch = fetch if doi else None
        self._doi = doi or ""

    def ask(self) -> tuple[str | None, LookupRecord]:
        """Ask CORE, once.

        Returns:
            The text when CORE served it, and what to record otherwise: a
            failure when CORE could not be asked, a ``KEY_REFUSED`` skip when
            it refused the key (#498), nothing for an absence, a second ask
            or no CORE at all.
        """
        if self._fetch is None:
            return None, LookupRecord()
        fetch, self._fetch = self._fetch, None
        outcome = fetch(self._doi)
        return outcome.text, outcome.lookups()


def verification_status(check: TitleCheck) -> str:
    """A downloaded PDF's title check as the discovery's progress reports it.

    Args:
        check: The check.

    Returns:
        ``"success"`` for a match, ``"mismatch"`` for a mismatch, and
        ``"unchecked"`` when nothing could be judged or the file could not
        be read: never called a mismatch, nor a success.
    """
    match check.outcome:
        case TitleCheckOutcome.MATCHES:
            return "success"
        case TitleCheckOutcome.MISMATCH:
            return "mismatch"
        case (
            TitleCheckOutcome.NO_TITLE
            | TitleCheckOutcome.NO_TEXT
            | TitleCheckOutcome.TRANSLATED_TITLE
            | TitleCheckOutcome.UNREADABLE
        ):
            return "unchecked"
        case unknown:
            assert_never(unknown)


def verification_warning(check: TitleCheck) -> str | None:
    """What a downloaded PDF's title check doubted, for the reader.

    Args:
        check: The check.

    Returns:
        ``None`` for a match, and where nothing in the title could be
        judged against the PDF (no title words, a translated title); a
        sentence for a mismatch, with its share, a PDF with no text, and
        one that could not be read.
    """
    match check.outcome:
        case TitleCheckOutcome.MATCHES | TitleCheckOutcome.NO_TITLE | TitleCheckOutcome.TRANSLATED_TITLE:
            return None
        case TitleCheckOutcome.MISMATCH:
            return f"PDF content may not match expected document. Title match: {check.share:.0%}"
        case TitleCheckOutcome.NO_TEXT:
            return "PDF contains no extractable text"
        case TitleCheckOutcome.UNREADABLE:
            return "The PDF could not be read to check it against the title"
        case unknown:
            assert_never(unknown)


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
        openalex_email: str | None = None,
        openalex: OpenAlexLocationsClient | None = None,
        elsevier: ElsevierArticleClient | None = None,
    ) -> None:
        """
        Initialize PDF discoverer.

        Args:
            unpaywall_email: Email for Unpaywall API (required for Unpaywall;
                the application's placeholder counts as none)
            openathens_url: OpenAthens institution URL for authenticated access
            progress_callback: Callback for progress updates (stage, status)
            openalex_email: The contact email sent to OpenAlex, the one the
                transparency analysis already sends it; the application's
                placeholder counts as none, and OpenAlex is then asked
                without one (#480)
            openalex: The OpenAlex client; tests pass a stub
            elsevier: Elsevier's Article API client, built with the user's
                key (#480, stage C2); ``None`` when no key is configured,
                and Elsevier is then not asked and nothing is recorded
        """
        self.unpaywall_email = usable_unpaywall_email(unpaywall_email)
        # The placeholder test is Unpaywall's: a blank or placeholder address
        # is no contact, and OpenAlex is asked without one rather than skipped
        self._openalex = (
            openalex
            if openalex is not None
            else default_openalex_client(usable_unpaywall_email(openalex_email))
        )
        self._elsevier = elsevier
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
        doi: str | None = None,
        pmid: str | None = None,
        pmcid: str | None = None,
        title: str | None = None,
        expected_title: str | None = None,
        earlier_lookups: LookupRecord | None = None,
        core_text: Callable[[str], CoreFetch] | None = None,
    ) -> DiscoveryResult:
        """Discover and download the PDF for a document; see :meth:`_discover_and_download`.

        Args:
            output_path: Path to save the PDF.
            doi: Document DOI.
            pmid: PubMed ID.
            pmcid: PubMed Central ID.
            title: Document title (for verification).
            expected_title: Expected title for content verification.
            earlier_lookups: What went unasked before this step.
            core_text: Asks CORE for its extracted text, by the cleaned DOI.

        Returns:
            The discovery's result, carrying every downloaded PDF set aside
            as another article's on the way (``set_aside``), whatever the
            outcome (#541).
        """
        # Held by this call, never on the discoverer, so a discoverer used
        # for two discoveries at once never mixes their PDFs
        set_aside_paths: list[Path] = []
        # Read here, at the entry, so every caller is covered: the GUI's
        # download worker calls this directly with a stored PMID
        # (bmlib#470, bmlib#472, bmlib#478)
        pmid, pmcid = read_caller_ids(pmid, pmcid)
        result = self._discover_and_download(
            output_path, doi, pmid, pmcid, title, expected_title, earlier_lookups,
            core_text, set_aside_paths=set_aside_paths,
        )
        return replace(result, set_aside=tuple(dict.fromkeys(set_aside_paths)))

    def _discover_and_download(
        self,
        output_path: Path,
        doi: Optional[str] = None,
        pmid: Optional[str] = None,
        pmcid: Optional[str] = None,
        title: Optional[str] = None,
        expected_title: Optional[str] = None,
        earlier_lookups: LookupRecord | None = None,
        core_text: Callable[[str], CoreFetch] | None = None,
        *,
        set_aside_paths: list[Path],
    ) -> DiscoveryResult:
        """
        Discover and download PDF for a document.

        Tries multiple sources in order of reliability:
        0. Elsevier's Article API (if an Elsevier DOI and a key), once,
           before any other lookup (#480, stage C2)
        1. PubMed Central (if PMID/PMCID available)
        2. Unpaywall (if DOI and email available)
        2a. OpenAlex's locations not already found (if DOI), before any
            source that is not open access
        3. Direct DOI resolution
        4. CORE's extracted text (if DOI and ``core_text``), at the first
           exit that obtained no PDF and served no copy

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
            core_text: Asks CORE for its extracted text, by the cleaned
                DOI, at the first exit that obtained no PDF and served no
                copy (#480, stage C). Its text is a success without a file
                (``text``); a CORE that could not be asked is recorded under
                ``SERVICE_CORE``; ``None`` asks nothing and records nothing.
            set_aside_paths: This call's list, given where each download of
                another article was set aside (#541).

        Returns:
            DiscoveryResult with success status and details
        """
        self._cancelled = False
        self._emit_progress("discovery", "starting")

        # A DOI that cleans to nothing ("doi:", a bare resolver URL) is no
        # DOI: asked with it, Unpaywall and OpenAlex answer nothing, which
        # read as an absence where no lookup was made, and the NO_IDENTIFIER
        # skip below never recorded (#480 review).
        doi = (self._clean_doi(doi) or None) if doi else None
        core = _CoreFallback(core_text, doi)

        # Elsevier's Article API first, before any Unpaywall lookup (#480,
        # stage C2). A PDF it served, a cancel, or a PDF it served that could
        # not be saved ends the discovery; anything it left unsettled is
        # recorded, and the walk goes on. A PDF it offered over the size
        # limit, or one of another article (set aside, #541), is a copy not
        # obtained, held with the refused copies, ranked first (-1), and
        # dropped with them when a later copy is obtained.
        if self._cancelled:
            return DiscoveryResult(success=False, error="Cancelled")
        elsevier_lookups = LookupRecord()
        elsevier_copy = LookupRecord()
        if doi and self._elsevier is not None and elsevier_eligible(doi):
            ended, elsevier_lookups, elsevier_copy = self._ask_elsevier(
                self._elsevier, doi, output_path, expected_title or title, set_aside_paths
            )
            if ended is not None:
                return ended

        # Find all available PDF sources, and what could not be asked at all
        sources, found_lookups = self._discover_sources(doi, pmid, pmcid)
        lookups = elsevier_lookups.merged(found_lookups)
        # What the reader is told about: everything unasked so far.
        told = (earlier_lookups or LookupRecord()).merged(lookups)

        if self._cancelled:
            return DiscoveryResult(
                success=False,
                error="Cancelled",
                lookups=lookups,
            )

        # OpenAlex is asked once, for the PDFs Unpaywall did not name (#480,
        # stage B): at once when nothing else was found, otherwise when the
        # next source to try is not an open-access copy (below).
        openalex_doi = doi
        if not sources and openalex_doi:
            found, openalex_lookups = self._discover_openalex(openalex_doi, ())
            openalex_doi = None
            sources = found
            lookups = lookups.merged(openalex_lookups)
            told = told.merged(openalex_lookups)

        if not sources:
            core_text_found, core_lookups = self._ask_core(core)
            if self._cancelled:
                return DiscoveryResult(success=False, error="Cancelled", lookups=lookups)
            if core_text_found is not None:
                return DiscoveryResult(success=True, text=core_text_found, lookups=lookups)
            lookups = lookups.merged(core_lookups)
            told = told.merged(core_lookups)
            self._emit_progress("discovery", "not_found")
            return DiscoveryResult(
                success=False,
                # A lookup we did not make says nothing about the licence,
                # so the paywall claim is withheld whenever one went unasked
                # -- skipped as well as failed (#347, #355).
                error=no_pdf_sources_message(told.merged(elsevier_copy)),
                lookups=lookups.merged(elsevier_copy),
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
        # Elsevier's copy first, before every copy tried below (rank -1)
        unobtained: list[tuple[int, LookupRecord]] = (
            [(-1, elsevier_copy)] if elsevier_copy.anything_unsettled else []
        )

        pending = deque(sources)
        while pending or openalex_doi:
            if self._cancelled:
                return DiscoveryResult(
                    success=False,
                    error="Cancelled",
                    lookups=lookups,
                )

            if openalex_doi and (not pending or not pending[0].is_open_access):
                found, openalex_lookups = self._discover_openalex(
                    openalex_doi, [s.url for s in sources]
                )
                openalex_doi = None
                lookups = lookups.merged(openalex_lookups)
                told = told.merged(openalex_lookups)
                # After every earlier copy's rank: OpenAlex's PDFs are told
                # after Unpaywall's, whatever order they were tried in
                first_rank = max(copy_rank.values(), default=-1) + 1
                for offset, found_source in enumerate(found):
                    copy_rank[found_source.url] = first_rank + offset
                sources.extend(found)
                pending.extendleft(reversed(found))
                continue

            source = pending.popleft()
            self._emit_progress("discovery", "found_oa" if source.is_open_access else "found")
            result = self._try_download(source, output_path, expected_title or title)
            set_aside_paths.extend(result.set_aside)

            if result.success:
                return result.with_lookups(lookups)

            if result.not_saved:
                # Served, and not saved here: the copy exists, so nothing else
                # is asked (saving is our problem) and the open-access
                # question is settled (the maintainer's decision): the error
                # is the caching note alone. Other unsettled service lookups
                # stay in ``lookups`` for the absence logic; the refused
                # copies held in ``unobtained`` are dropped on purpose, as a
                # served copy answers what they left open (#480).
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
            if result.wrong_article:
                # Any source's, held as the open-access copies are: a later
                # source serving the article's own PDF settles it (#541). One
                # no open-access source named is held after theirs; the
                # reader's sentence orders entries by the chain itself.
                record = wrong_article_pdf(source)
                if rank is None:
                    rank = max(copy_rank.values(), default=-1) + 1
            if record.anything_unsettled and rank is not None:
                unobtained.append((rank, record))

            if result.is_paywall:
                if source.is_open_access:
                    # A refusal of an open-access copy is held, and the other
                    # sources are tried first
                    logger.info(f"Source {source.url} refused us; trying the next source")
                    last_paywall_result = result
                    continue
                else:
                    # For non-OA sources, return paywall result so caller can
                    # offer OpenAthens auth. The refusal is this source's
                    # answer, not the document's licence: where the lookup
                    # that would have found a free copy could not be made,
                    # the claim is withheld rather than asserted (#347).
                    # CORE's text, asked first, is served instead (#480).
                    core_text_found, core_lookups = self._ask_core(core)
                    if self._cancelled:
                        return DiscoveryResult(success=False, error="Cancelled", lookups=lookups)
                    if core_text_found is not None:
                        return DiscoveryResult(
                            success=True, text=core_text_found, lookups=lookups
                        )
                    lookups = lookups.merged(core_lookups)
                    told = told.merged(core_lookups)
                    not_obtained = self._ranked(unobtained)
                    return replace(
                        result.with_lookups(lookups.merged(not_obtained)),
                        error=paywall_message(
                            result.error or "", told.merged(not_obtained)
                        ),
                    )

        not_obtained = self._ranked(unobtained)
        # CORE last, after every copy tried: its text settles the question
        # as a downloaded PDF does, so the refused copies are dropped (#480).
        core_text_found, core_lookups = self._ask_core(core)
        if self._cancelled:
            return DiscoveryResult(success=False, error="Cancelled", lookups=lookups)
        if core_text_found is not None:
            return DiscoveryResult(success=True, text=core_text_found, lookups=lookups)
        lookups = lookups.merged(core_lookups)
        told = told.merged(core_lookups)

        # If we had a paywall result but no success, return it for OpenAthens option
        if last_paywall_result:
            return replace(
                last_paywall_result.with_lookups(lookups.merged(not_obtained)),
                error=paywall_message(
                    last_paywall_result.error or "", told.merged(not_obtained)
                ),
            )

        unsettled = told.merged(not_obtained)
        return DiscoveryResult(
            success=False,
            # With tried PDFs the tried-sources statement says it all and
            # opens "Failed to obtain a PDF ..."; the claim beside it would
            # say "Failed" twice. Otherwise the claim about our own attempts,
            # which the unasked sources cannot falsify, is qualified rather
            # than withheld.
            error=(
                unestablished_access_clause(unsettled)
                if tried_sources_statement(unsettled)
                else with_unestablished_access(
                    "Failed to download PDF from any available source.", unsettled
                )
            ),
            lookups=lookups.merged(not_obtained),
        )

    def _ask_elsevier(
        self,
        elsevier: ElsevierArticleClient,
        doi: str,
        output_path: Path,
        expected_title: str | None,
        set_aside_paths: list[Path],
    ) -> tuple[DiscoveryResult | None, LookupRecord, LookupRecord]:
        """Ask Elsevier's Article API for this DOI's PDF, once (#480, stage C2).

        Args:
            elsevier: The client, built with the user's key.
            doi: The cleaned DOI, already found to be Elsevier's.
            output_path: Where a served PDF is saved: the discovery's own
                path, so the PDF cache and text extraction apply unchanged.
            expected_title: The title a served PDF is checked against.
            set_aside_paths: The discovery's list, given where a served PDF
                of another article was set aside (#541).

        Returns:
            The result that ends the discovery -- a served PDF, a cancel, or
            the caching note for a PDF served and not saved -- or ``None`` to
            go on. Then, when the discovery goes on, what Elsevier left
            unasked (a failure when it could not be asked, a skip when it
            refused the key or the network) and the copy it offered that was
            not obtained (an ``OVER_SIZE_LIMIT`` skip with the article URL,
            or a ``WRONG_ARTICLE`` skip for a PDF of another article).
            Both are empty for an absence (a 404, the first page only).
        """
        url = elsevier.article_url(doi)
        # Fetched beside the cache path and checked before it replaces
        # anything there (#541)
        staged = unchecked_download_path(output_path)
        try:
            fetch = elsevier.fetch_pdf(doi, staged, lambda: self._cancelled)
            if fetch.path is not None:
                # Whole: a success, checked as any download is, even if a
                # cancel came after the last chunk (as ``_try_download``).
                self._emit_progress("download", "success")
                check = self._check_download(fetch.path, expected_title)
                if self._refused(output_path, fetch.path, check):
                    # Another article's: set aside, recorded as a copy
                    # offered and not obtained, and the walk goes on
                    assert check is not None
                    set_aside_paths.extend(
                        self._set_aside_download(output_path, fetch.path, url, check)
                    )
                    return None, LookupRecord(), LookupRecord(skipped=(SourceLookupSkipped(
                        SERVICE_ELSEVIER, LookupSkipReason.WRONG_ARTICLE, url
                    ),))
                try:
                    fetch.path.replace(output_path)
                except OSError:
                    logger.error("Elsevier's PDF could not be saved in the library", exc_info=True)
                    fetch = ElsevierFetch.not_saved()
                else:
                    return DiscoveryResult(
                        success=True,
                        file_path=output_path,
                        source=PDFSource(url=url, source_type=PDFSourceType.ELSEVIER_API),
                        verification_warning=(
                            verification_warning(check) if check is not None else None
                        ),
                    ), LookupRecord(), LookupRecord()
        finally:
            discard_partial_download(staged)
        return self._elsevier_unserved(fetch, doi, url)

    def _elsevier_unserved(
        self, fetch: ElsevierFetch, doi: str, url: str
    ) -> tuple[DiscoveryResult | None, LookupRecord, LookupRecord]:
        """What an Elsevier fetch that saved no PDF here comes to (#480, stage C2).

        Args:
            fetch: The fetch, which served no PDF that was kept.
            doi: The cleaned DOI, for the log.
            url: The article URL, which carries no key.

        Returns:
            As :meth:`_ask_elsevier`.
        """
        if fetch.is_cancelled or self._cancelled:
            # Nothing recorded for Elsevier: we stopped asking.
            return (
                DiscoveryResult(success=False, error="Cancelled"), LookupRecord(), LookupRecord()
            )
        record = fetch.lookups(url)
        if fetch.failure is not None:
            # describe() names the kind and status alone: never a key or token.
            logger.warning(
                "Elsevier's API could not be asked about %s (%s)",
                doi, fetch.failure.describe(),
            )
        if fetch.outcome is ElsevierOutcome.NOT_SAVED:
            # Served, and not saved here: as for any copy served and not
            # saved, nothing else is asked and the error is the caching note
            # alone, its address the article URL, which carries no key.
            return DiscoveryResult(
                success=False, error=not_saved_note(record), lookups=record
            ), LookupRecord(), LookupRecord()
        if fetch.outcome is ElsevierOutcome.REFUSED_FOR_SIZE:
            return None, LookupRecord(), record
        return None, record, LookupRecord()

    def _check_download(
        self, pdf_path: Path, expected_title: str | None
    ) -> TitleCheck | None:
        """Check a saved PDF against the title expected, as every download is.

        Args:
            pdf_path: The PDF saved.
            expected_title: The document's title; ``None`` checks nothing.

        Returns:
            The check, or ``None`` when there was no title to check.
        """
        if not expected_title:
            return None
        self._emit_progress("verification", "starting")
        check = self._verify_pdf_content(pdf_path, expected_title)
        self._emit_progress("verification", verification_status(check))
        return check

    @staticmethod
    def _refused(output_path: Path, staged: Path, check: TitleCheck | None) -> bool:
        """Whether a whole download is refused as another article's (#541).

        Args:
            output_path: The cache path it would replace.
            staged: Where it waits for its check.
            check: Its title check; ``None`` when there was no title.

        Returns:
            ``True`` for a mismatch, unless a person kept these very bytes
            at the cache path (their marker names them).
        """
        return (
            check is not None
            and check.outcome is TitleCheckOutcome.MISMATCH
            and not is_kept(output_path, contents=staged)
        )

    @staticmethod
    def _set_aside_download(
        output_path: Path, staged: Path, url: str, check: TitleCheck
    ) -> tuple[Path, ...]:
        """Set aside a downloaded PDF that is another article's (#541).

        Kept beside the cache path and told to the reader
        (``DiscoveryResult.set_aside``): the check can be wrong, and the
        reader can keep it (``bmll keep-pdf``). The same wrong PDF
        downloaded again is kept once.

        Args:
            output_path: The cache path, which the set-aside name follows.
            staged: Where the download waits; discarded by the caller if it
                could not be set aside.
            url: Where it was downloaded from, for the log.
            check: Its mismatching title check.

        Returns:
            Where it was set aside; empty when it could not be (logged).
        """
        try:
            moved = set_aside(output_path, contents=staged)
        except OSError:
            # Discarded by the caller: never at the cache path, so never read
            logger.error(
                "The PDF from %s is another article's and could not be set aside",
                address_host(url), exc_info=True,
            )
            return ()
        logger.warning(
            "The PDF from %s does not carry the article's title (%.0f%% of its "
            "word pairs); set aside as %s",
            address_host(url), (check.share or 0.0) * 100, moved.name,
        )
        return (moved,)

    def _ask_core(self, core: _CoreFallback) -> tuple[str | None, LookupRecord]:
        """Ask CORE at a no-PDF exit, unless the discovery was cancelled.

        A cancelled discovery asks nothing, and its caller returns the
        ``"Cancelled"`` result rather than the exit's ordinary one: a CORE
        never asked must not read as a search that found nothing.

        Args:
            core: This discovery's CORE, asked at most once.

        Returns:
            CORE's text when it served the article, and what to record.
        """
        if self._cancelled:
            return None, LookupRecord()
        return core.ask()

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
        if not is_canonical_pmid(pmid):
            # The entries canonicalise a caller's PMID (bmlib#470, bmlib#472,
            # bmlib#478); one that gets here unread is a programming error, and
            # the converter would read "1,2" as two records. Not asking is
            # our failure, never the converter holding no record.
            logger.error(
                "Programming error: the ID converter was given a PMID that "
                "is not canonical, so it was not asked: %r",
                pmid,
            )
            return None, SourceLookupFailure(
                SERVICE_PMC_ID_CONVERTER,
                RequestFailure(RequestFailureKind.REQUEST_FAILED),
            )
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

    def _discover_openalex(
        self, doi: str, known_urls: Iterable[str]
    ) -> tuple[list[PDFSource], LookupRecord]:
        """The PDFs OpenAlex's locations name that no earlier source did (#480).

        Args:
            doi: The article's DOI.
            known_urls: Every address already found, tried or still to try.

        Returns:
            The new open-access sources, in OpenAlex's order, and the failure
            that left OpenAlex unasked, if any. No work, or a work naming no
            new PDF, is an answer: no source and nothing recorded.
        """
        fetch = self._openalex.fetch_pdf_urls(self._clean_doi(doi))
        if fetch.failure is not None:
            logger.warning(
                "OpenAlex could not be asked about DOI %s (%s), so any open-access "
                "copy it knows of is not assessed.",
                doi,
                fetch.failure.describe(),
            )
            return [], LookupRecord(
                failures=(SourceLookupFailure(SERVICE_OPENALEX, fetch.failure),)
            )
        urls = untried_pdf_urls(fetch.pdf_urls or (), known_urls)
        return [
            PDFSource(url=url, source_type=PDFSourceType.OPENALEX_OA, is_open_access=True)
            for url in urls
        ], LookupRecord()

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
        match = re.search(r'/pmc/articles/(?:PMC)?([0-9]+)', url, re.IGNORECASE)
        if match:
            return f"PMC{match.group(1)}"
        # Also match standalone numbers in PMC URLs
        if 'pmc' in url.lower() or 'ncbi' in url.lower():
            match = re.search(r'([0-9]{6,})', url)
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

            # An open-access copy whose answer is not a PDF is read further,
            # to recognise a bot wall's challenge page: that is no answer
            # about the article, and is recorded as its own kind (#480). A
            # gone answer (404, 410) is discarded whatever its page says, so
            # its page is not read. The longer read is its own copy: the
            # paywall sniff and the write keep ``body_prefix``. A challenge
            # ends the attempt just below.
            challenge = None
            if (
                source.source_type in _UNOBTAINED_PDF_SERVICE
                and response.status_code not in CHALLENGE_GONE_STATUSES
                and not self._looks_like_pdf(body_prefix)
            ):
                page = read_more_of_prefix(
                    content_iter, body_prefix, CHALLENGE_BODY_PREFIX_BYTES
                )
                challenge = challenge_failure(
                    response.status_code, response.headers, page
                )
                if challenge is not None:
                    defences = challenge_markers(response.status_code, response.headers, page)
                    logger.warning(
                        f"A bot wall's challenge answered {source.url} "
                        f"(HTTP {response.status_code}): {', '.join(defences)}"
                    )

            # A bot wall's challenge is no paywall: the copy is free, and the
            # browser queue takes it (#480, stage 2). Returned before the
            # paywall sniff, which matched it by its status (401, 403) or by
            # a word in its address ("access", "pay"), and told the reader "A
            # source refused access" with an OpenAthens offer.
            if challenge is not None:
                return DiscoveryResult(
                    success=False,
                    error=challenge.describe(),
                    failure=challenge,
                )

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
                self._emit_progress("download", "success")
                # Checked whole, before it replaces anything: another
                # article's PDF never overwrites the one in the library (#541)
                check = self._check_download(partial, expected_title)
                if self._refused(output_path, partial, check):
                    # No answer about this article: set aside, and the next
                    # source is tried
                    assert check is not None
                    moved = self._set_aside_download(output_path, partial, source.url, check)
                    return DiscoveryResult(
                        success=False,
                        error=(
                            f"The PDF from {address_host(source.url)} is another "
                            f"article's ({check.share or 0.0:.0%} of the title's word pairs)."
                        ),
                        wrong_article=True,
                        set_aside=moved,
                    )
                partial.replace(output_path)
            finally:
                discard_partial_download(partial)

            return DiscoveryResult(
                success=True,
                file_path=output_path,
                source=source,
                verification_warning=verification_warning(check) if check is not None else None,
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

    def _verify_pdf_content(self, pdf_path: Path, expected_title: str) -> TitleCheck:
        """Check that a downloaded PDF's first page with text carries the expected title (#532).

        Args:
            pdf_path: Path to PDF file
            expected_title: Expected document title

        Returns:
            The check (``verification_warning`` says what it doubted).
        """
        return check_pdf_title(pdf_path, expected_title)
