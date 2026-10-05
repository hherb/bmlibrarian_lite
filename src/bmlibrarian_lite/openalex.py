# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""OpenAlex's locations as open-access PDF sources (#480, stage B).

OpenAlex lists, for each work, the places a copy is hosted, some with a PDF
URL Unpaywall does not name: the #480 spike recovered 6 of the 290 failed
Unpaywall PDFs this way. Every ``locations[].pdf_url`` is a candidate,
whatever the location's ``is_oa``: the spike's ``real.mtak.hu`` copy is one
OpenAlex marks closed.

The pure functions here are pinned with the Swift and Kotlin ports by
``doc/cross_platform/fulltext_parity/openalex_locations.json``.
"""

from __future__ import annotations

import json
import logging
from collections.abc import Iterable, Mapping, Sequence
from dataclasses import dataclass
from typing import Any
from urllib.parse import quote

import requests
from urllib3.util.retry import Retry

from .constants import (
    EUROPEPMC_USER_AGENT,
    HTTP_NOT_FOUND,
    OPENALEX_API_BASE_URL,
    OPENALEX_ENCODING,
    OPENALEX_MAX_RETRIES,
    OPENALEX_REQUEST_TIMEOUT_SECONDS,
    RETRYABLE_HTTP_STATUSES,
)
from .data_models import RequestFailure, RequestFailureKind
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)
_HTTP_OK = 200


def openalex_work_url(
    doi: str, mailto: str | None = None, base_url: str = OPENALEX_API_BASE_URL
) -> str:
    """The address OpenAlex is asked about one DOI at.

    The DOI is escaped whole, its ``/`` included, so it is one path segment
    whatever it holds (a SICI DOI holds ``<>;:()``); the email is escaped as
    a query value, so a ``+`` is not read as a space. Only ``locations`` is
    selected: it is all the chain reads.

    Args:
        doi: The DOI; surrounding whitespace is not part of it.
        mailto: The contact email for OpenAlex's polite pool, or ``None``.
        base_url: OpenAlex's address; tests point it at a local server.

    Returns:
        The URL.
    """
    url = (
        f"{base_url.rstrip('/')}/works/doi:{quote(doi.strip(), safe='')}"
        "?select=locations"
    )
    if mailto:
        url += f"&mailto={quote(mailto, safe='')}"
    return url


def _present(value: Any) -> str | None:
    """Return a string value trimmed, or ``None`` when it names nothing."""
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def openalex_pdf_urls(work: object) -> list[str]:
    """Every PDF URL a work's locations name, in OpenAlex's order.

    Args:
        work: OpenAlex's decoded answer for one work, untrusted.

    Returns:
        Each location's ``pdf_url`` that is a non-blank string, trimmed, kept
        once where it first appears; a location that is not an object is
        skipped. Empty when ``locations`` is missing, null or empty.

    Raises:
        ValueError: If ``work`` is not a JSON object, or its ``locations`` is
            neither a list nor null: an answer we cannot read, never an
            absence.
    """
    if not isinstance(work, Mapping):
        raise ValueError("an OpenAlex work is a JSON object")
    locations = work.get("locations")
    if locations is None:
        return []
    if not isinstance(locations, list):
        raise ValueError("an OpenAlex work's locations are a list")
    urls: list[str] = []
    for location in locations:
        if not isinstance(location, Mapping):
            continue
        url = _present(location.get("pdf_url"))
        if url and url not in urls:
            urls.append(url)
    return urls


def untried_pdf_urls(pdf_urls: Sequence[str], tried: Iterable[str]) -> list[str]:
    """The PDF URLs not already tried, in their order.

    Args:
        pdf_urls: The candidates.
        tried: Addresses an earlier source named (Unpaywall's).

    Returns:
        ``pdf_urls`` without any in ``tried``.
    """
    seen = set(tried)
    return [url for url in pdf_urls if url not in seen]


@dataclass(frozen=True)
class OpenAlexWorkFetch:
    """What asking OpenAlex for a work's PDF locations produced.

    The sibling of ``pmc_open_data.PmcOpenDataFetch``. ``absent()`` is
    OpenAlex's answer that it knows no work by this DOI; ``served([])`` is a
    work naming no PDF. Both are answers. A failure is an answer we could not
    get, which leaves any copy OpenAlex knows of unassessed.

    Attributes:
        pdf_urls: The PDF URLs, when served.
        failure: Why it could not be read. ``None`` with no ``pdf_urls`` is absent.

    Raises:
        ValueError: On construction, if both are given.
    """

    pdf_urls: tuple[str, ...] | None
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse the state that would mean two things at once."""
        if self.pdf_urls is not None and self.failure is not None:
            raise ValueError("An OpenAlex fetch is served or unreachable, never both")

    @classmethod
    def served(cls, pdf_urls: Iterable[str]) -> OpenAlexWorkFetch:
        """OpenAlex answered with the work; it may name no PDF."""
        return cls(pdf_urls=tuple(pdf_urls), failure=None)

    @classmethod
    def absent(cls) -> OpenAlexWorkFetch:
        """OpenAlex knows no work by this DOI."""
        return cls(pdf_urls=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> OpenAlexWorkFetch:
        """OpenAlex's answer is missing, of its real kind."""
        return cls(pdf_urls=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether nothing about the work was established."""
        return self.failure is not None


class OpenAlexLocationsClient:
    """Asks OpenAlex which PDFs a work's locations name, paced per host."""

    def __init__(
        self,
        mailto: str | None = None,
        base_url: str = OPENALEX_API_BASE_URL,
        max_retries: int = OPENALEX_MAX_RETRIES,
    ) -> None:
        """Create the client.

        Args:
            mailto: The contact email for OpenAlex's polite pool, the one the
                transparency analysis already sends it; ``None`` asks without.
            base_url: OpenAlex's address; tests point it at a local server.
            max_retries: Retries for a 429 or 5xx; tests pass 0.
        """
        self._mailto = mailto
        self._base_url = base_url
        session = requests.Session()
        session.headers.update(
            {"User-Agent": EUROPEPMC_USER_AGENT, "Accept": "application/json"}
        )
        retry = Retry(
            total=max_retries,
            backoff_factor=1,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    @property
    def mailto(self) -> str | None:
        """The contact email sent with each request, if any."""
        return self._mailto

    def fetch_pdf_urls(self, doi: str) -> OpenAlexWorkFetch:
        """Ask OpenAlex for the PDFs a work's locations name.

        Args:
            doi: The work's DOI, cleaned of any resolver prefix.

        Returns:
            Served URLs (possibly none); absent for a 404 or a blank DOI,
            which is never asked; or unreachable, of its real kind.
        """
        if not doi.strip():
            return OpenAlexWorkFetch.absent()
        try:
            response = self._session.get(
                openalex_work_url(doi, self._mailto, self._base_url),
                timeout=OPENALEX_REQUEST_TIMEOUT_SECONDS,
            )
        except requests.exceptions.RequestException as error:
            return OpenAlexWorkFetch.unreachable(request_failure_from_exception(error))
        except ValueError:
            # A redirect whose Location will not parse ("http://[::1/x", or
            # bytes that are not UTF-8) raises a bare ValueError from inside
            # requests, as in ``pdf_discovery._discover_doi_direct`` and
            # ``_resolve_landing_page``. Escaping, it would abort the
            # discovery chain and lose what the earlier tiers had found.
            return OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.REQUEST_FAILED)
            )
        if response.status_code == HTTP_NOT_FOUND:
            return OpenAlexWorkFetch.absent()
        if response.status_code != _HTTP_OK:
            return OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, response.status_code)
            )
        try:
            # Decoded explicitly, as JSON is UTF-8: ``.json()`` would guess
            urls = openalex_pdf_urls(
                json.loads(response.content.decode(OPENALEX_ENCODING))
            )
        except ValueError:  # includes UnicodeDecodeError, JSONDecodeError
            return OpenAlexWorkFetch.unreachable(
                RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
            )
        return OpenAlexWorkFetch.served(urls)
