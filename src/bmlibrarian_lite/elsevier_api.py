# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Elsevier's Article Retrieval API, asked for an article's PDF (#480, stage C2).

Elsevier serves an Elsevier article's PDF to a requestor entitled to it: an
open-access article anywhere, a subscribed one from the institution's network
or with an institutional token. It is asked by DOI with the user's own key,
only for a DOI Elsevier registered (``10.1016/``). The rules are in
doc/cross_platform/fulltext_retrieval.md, "Elsevier's Article API", pinned by
doc/cross_platform/fulltext_parity/elsevier_article.json.

The key travels in ``X-ELS-APIKey`` and the token in ``X-ELS-Insttoken``, and
nowhere else: never in a URL, a log line, an exception message or a ``repr``.
No redirect is followed, as one would carry the key wherever it points.
"""

from __future__ import annotations

import logging
import os
from collections.abc import Callable, Iterator
from contextlib import closing
from dataclasses import dataclass, field
from enum import Enum
from itertools import chain
from pathlib import Path
from typing import TYPE_CHECKING
from urllib.parse import quote

import requests
from urllib3.util.retry import Retry

from .constants import (
    ELSEVIER_ACCEPT,
    ELSEVIER_API_BASE_URL,
    ELSEVIER_ARTICLE_PATH,
    ELSEVIER_BACKOFF_FACTOR,
    ELSEVIER_DOI_PREFIX,
    ELSEVIER_DOWNLOAD_CHUNK_BYTES,
    ELSEVIER_ERROR_BODY_MAX_BYTES,
    ELSEVIER_KEY_HEADER,
    ELSEVIER_KEY_REFUSED_STATUS,
    ELSEVIER_MAX_RETRIES,
    ELSEVIER_NETWORK_REFUSED_STATUS,
    ELSEVIER_NETWORK_REFUSED_TOKEN,
    ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429,
    ELSEVIER_REQUEST_TIMEOUT_SECONDS,
    ELSEVIER_STATUS_HEADER,
    ELSEVIER_TOKEN_HEADER,
    ELSEVIER_WARNING_PREFIX,
    ENV_ELSEVIER_API_KEY,
    ENV_ELSEVIER_INSTTOKEN,
    EUROPEPMC_USER_AGENT,
    HTTP_NOT_FOUND,
    HTTP_OK,
    HTTP_TOO_MANY_REQUESTS,
    PDF_MAGIC_BYTES,
    RETRYABLE_HTTP_STATUSES,
    SERVICE_ELSEVIER,
)
from .core_api import normalise_doi, strip_doi_prefix
from .data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from .keyed_service_session import KeyedServiceSession, credentials_digest, key_digest
from .pdf_download import (
    MAX_PDF_SIZE,
    discard_partial_download,
    partial_download_path,
    read_body_prefix,
)
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

if TYPE_CHECKING:
    from .config import DiscoveryConfig

logger = logging.getLogger(__name__)

#: What a path segment keeps bare besides ALPHA and DIGIT (``quote`` keeps
#: ``-._~`` bare itself): every other UTF-8 byte is percent-encoded.
_PATH_SAFE = "/"


def elsevier_eligible(doi: str) -> bool:
    """Whether a DOI is Elsevier's, and so may be asked about.

    Args:
        doi: The DOI as a source wrote it.

    Returns:
        ``True`` when the DOI, normalised as CORE's are, starts ``10.1016/``.
        Every other DOI makes no request and records nothing.
    """
    return normalise_doi(doi).startswith(ELSEVIER_DOI_PREFIX)


def elsevier_article_url(doi: str, base_url: str = ELSEVIER_API_BASE_URL) -> str:
    """The article request for one DOI. It carries neither the key nor the token.

    Args:
        doi: The DOI; trimmed, and one prefix removed, its own case kept.
        base_url: Elsevier's API root; trailing slashes are dropped.

    Returns:
        The request URL, pinned by the contract's ``article_url`` rows.
    """
    path = quote(strip_doi_prefix(doi), safe=_PATH_SAFE)
    return f"{base_url.rstrip('/')}{ELSEVIER_ARTICLE_PATH}{path}"


@dataclass(frozen=True)
class ElsevierCredentials:
    """The key and the optional institutional token, as the settings hold them.

    Both are trimmed on construction; a blank token is no token. Neither is
    ever shown by ``repr``.

    Attributes:
        api_key: The user's Elsevier API key.
        insttoken: The institutional token, or ``None``.

    Raises:
        ValueError: On construction, if the key is blank: without one nothing
            is asked, and the token is never used alone.
    """

    api_key: str = field(repr=False)
    insttoken: str | None = field(default=None, repr=False)

    def __post_init__(self) -> None:
        """Trim both; refuse a blank key."""
        key = self.api_key.strip()
        if not key:
            raise ValueError("Elsevier is asked only with a key")
        token = (self.insttoken or "").strip()
        object.__setattr__(self, "api_key", key)
        object.__setattr__(self, "insttoken", token or None)

    @classmethod
    def from_config(cls, discovery: DiscoveryConfig) -> ElsevierCredentials | None:
        """The credentials the settings configure, with the environment's fallbacks.

        Args:
            discovery: The discovery settings (``elsevier_api_key``,
                ``elsevier_insttoken``).

        Returns:
            The credentials, or ``None`` when neither the settings nor
            ``ELSEVIER_API_KEY`` hold a key: Elsevier is then not asked.
        """
        return configured_elsevier_credentials(
            discovery.elsevier_api_key, discovery.elsevier_insttoken
        )

    @property
    def key_digest(self) -> str:
        """The key's fingerprint, as a refused key is held."""
        return key_digest(self.api_key)

    @property
    def credentials_digest(self) -> str:
        """The key's and token's fingerprint, as a network refusal is held."""
        return credentials_digest(self.api_key, self.insttoken)


class ElsevierOutcome(Enum):
    """What asking Elsevier for one article learned. Values as the contract's."""

    #: Elsevier served the article's PDF, saved at the fetch's path.
    SERVED = "served"
    #: No such article, the first page only, or a DOI not Elsevier's: the
    #: chain goes on, and nothing is recorded.
    ABSENT = "absent"
    #: Elsevier could not be asked, or its answer could not be read.
    UNREACHABLE = "unreachable"
    #: Elsevier refused the key, now or earlier this session.
    KEY_REFUSED = "key_refused"
    #: Elsevier refused these credentials from this network, now or earlier.
    NETWORK_REFUSED = "network_refused"
    #: The PDF is larger than this application downloads (desktop only).
    REFUSED_FOR_SIZE = "refused_for_size"
    #: Elsevier served the PDF and it could not be saved on this device.
    NOT_SAVED = "not_saved"
    #: The caller cancelled the fetch: nothing kept, nothing recorded.
    CANCELLED = "cancelled"


@dataclass(frozen=True)
class ElsevierFetch:
    """What asking Elsevier for one article's PDF learned.

    Attributes:
        outcome: Which of the outcomes it was.
        path: Where the PDF was saved, when served; ``None`` otherwise.
        failure: Why Elsevier could not be asked, when unreachable; ``None``
            otherwise.

    Raises:
        ValueError: On construction, for a path without a served PDF (or a
            served PDF without one), or a failure without an unreachable
            outcome (or the reverse).
    """

    outcome: ElsevierOutcome
    path: Path | None = None
    failure: RequestFailure | None = None

    def __post_init__(self) -> None:
        """Refuse a fetch in two states at once."""
        if (self.outcome is ElsevierOutcome.SERVED) != (self.path is not None):
            raise ValueError("An Elsevier fetch has a saved PDF exactly when it is served")
        if (self.outcome is ElsevierOutcome.UNREACHABLE) != (self.failure is not None):
            raise ValueError("An Elsevier fetch has a failure exactly when it is unreachable")

    @classmethod
    def served(cls, path: Path) -> ElsevierFetch:
        """Elsevier served the article's PDF, now saved at ``path``."""
        return cls(ElsevierOutcome.SERVED, path=path)

    @classmethod
    def absent(cls) -> ElsevierFetch:
        """No PDF of this article from Elsevier for this requestor; nothing recorded."""
        return cls(ElsevierOutcome.ABSENT)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> ElsevierFetch:
        """Elsevier could not be asked, or its answer could not be read."""
        return cls(ElsevierOutcome.UNREACHABLE, failure=failure)

    @classmethod
    def key_refused(cls) -> ElsevierFetch:
        """Elsevier refused the key, so it was not asked about this article."""
        return cls(ElsevierOutcome.KEY_REFUSED)

    @classmethod
    def network_refused(cls) -> ElsevierFetch:
        """Elsevier refused these credentials from this network."""
        return cls(ElsevierOutcome.NETWORK_REFUSED)

    @classmethod
    def refused_for_size(cls) -> ElsevierFetch:
        """The PDF is larger than this application downloads."""
        return cls(ElsevierOutcome.REFUSED_FOR_SIZE)

    @classmethod
    def not_saved(cls) -> ElsevierFetch:
        """Elsevier served the PDF, and it could not be saved on this device."""
        return cls(ElsevierOutcome.NOT_SAVED)

    @classmethod
    def cancelled(cls) -> ElsevierFetch:
        """The caller cancelled the fetch; nothing is kept and nothing recorded."""
        return cls(ElsevierOutcome.CANCELLED)

    @property
    def is_cancelled(self) -> bool:
        """Whether the caller cancelled the fetch."""
        return self.outcome is ElsevierOutcome.CANCELLED

    def lookups(self, url: str) -> LookupRecord:
        """What this fetch leaves unsettled, as the discovery records it.

        Args:
            url: The article URL asked (:func:`elsevier_article_url`), which
                carries no key: the address of a size or caching note.

        Returns:
            Nothing for a served PDF, an absence or a cancel; a failure of
            Elsevier when it could not be asked; a ``KEY_REFUSED`` or
            ``NETWORK_REFUSED`` skip of Elsevier, without an address, when it
            refused; an ``OVER_SIZE_LIMIT`` or ``NOT_SAVED`` skip of Elsevier
            with the article URL when the PDF was too large or not saved.
        """
        if self.failure is not None:
            return LookupRecord(failures=(SourceLookupFailure(SERVICE_ELSEVIER, self.failure),))
        skip = _SKIPS.get(self.outcome)
        if skip is None:
            return LookupRecord()
        reason, with_address = skip
        address = url if with_address else None
        return LookupRecord(skipped=(SourceLookupSkipped(SERVICE_ELSEVIER, reason, address),))


#: The outcomes recorded as a skip: the reason, and whether it names the URL.
_SKIPS: dict[ElsevierOutcome, tuple[LookupSkipReason, bool]] = {
    ElsevierOutcome.KEY_REFUSED: (LookupSkipReason.KEY_REFUSED, False),
    ElsevierOutcome.NETWORK_REFUSED: (LookupSkipReason.NETWORK_REFUSED, False),
    ElsevierOutcome.REFUSED_FOR_SIZE: (LookupSkipReason.OVER_SIZE_LIMIT, True),
    ElsevierOutcome.NOT_SAVED: (LookupSkipReason.NOT_SAVED, True),
}


class ElsevierSession(KeyedServiceSession):
    """Elsevier's session state: the pause after 429s, a refused key, a refused network.

    Shares nothing with CORE's: a CORE 429 never pauses Elsevier.
    """

    def __init__(self, pause_after: int = ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429) -> None:
        """Start unpaused, with nothing refused.

        Args:
            pause_after: Consecutive 429 endings that pause Elsevier.
        """
        super().__init__(SERVICE_ELSEVIER, ELSEVIER_KEY_REFUSED_STATUS, pause_after)

    def __repr__(self) -> str:
        """Name the session without the digests it holds."""
        return f"ElsevierSession(paused={self.paused})"


_session_state = ElsevierSession()


def session_elsevier_state() -> ElsevierSession:
    """The pause and refusals every Elsevier client in this process shares."""
    return _session_state


def reset_elsevier_session() -> None:
    """Forget the session's pause and refusals, and that "no key" was logged.

    For tests, as ``reset_core_throttle`` is.
    """
    global _session_state, _unconfigured_logged
    _session_state = ElsevierSession()
    _unconfigured_logged = False


def _is_first_page_only(response: requests.Response) -> bool:
    """Whether a 200 carries the first page only: Elsevier's ``WARNING`` status."""
    status = response.headers.get(ELSEVIER_STATUS_HEADER, "")
    return status.strip().lower().startswith(ELSEVIER_WARNING_PREFIX.lower())


def _read_error_body(response: requests.Response) -> bytes:
    """Read at most :data:`ELSEVIER_ERROR_BODY_MAX_BYTES` of an error answer's body.

    A bounded read of a provider's error, not research content.

    Args:
        response: A streamed answer.

    Returns:
        The body's first bytes, up to the bound.

    Raises:
        requests.exceptions.RequestException: If the read fails.
    """
    body = b""
    for chunk in response.iter_content(chunk_size=ELSEVIER_DOWNLOAD_CHUNK_BYTES):
        body += chunk
        if len(body) >= ELSEVIER_ERROR_BODY_MAX_BYTES:
            break
    return body[:ELSEVIER_ERROR_BODY_MAX_BYTES]


def _declared_length(response: requests.Response) -> int | None:
    """The body's declared length; ``None`` when absent or not a number."""
    try:
        return int(response.headers.get("Content-Length", ""))
    except ValueError:
        return None


class ElsevierArticleClient:
    """Asks Elsevier's Article API for one article's PDF."""

    def __init__(
        self,
        credentials: ElsevierCredentials,
        base_url: str = ELSEVIER_API_BASE_URL,
        max_retries: int = ELSEVIER_MAX_RETRIES,
        session_state: ElsevierSession | None = None,
    ) -> None:
        """Build a client that sends these credentials.

        Args:
            credentials: The key and the optional token.
            base_url: Elsevier's API root.
            max_retries: Retries for a 429, a 5xx or a transport failure.
            session_state: The session's pause and refusals; the
                process-wide one by default.
        """
        self.credentials = credentials
        self._base_url = base_url
        self._session_state = (
            session_state if session_state is not None else session_elsevier_state()
        )
        session = requests.Session()
        headers = {
            "User-Agent": EUROPEPMC_USER_AGENT,
            "Accept": ELSEVIER_ACCEPT,
            ELSEVIER_KEY_HEADER: credentials.api_key,
        }
        if credentials.insttoken is not None:
            headers[ELSEVIER_TOKEN_HEADER] = credentials.insttoken
        session.headers.update(headers)
        retry = Retry(
            total=max_retries,
            backoff_factor=ELSEVIER_BACKOFF_FACTOR,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    def __repr__(self) -> str:
        """Name the client without its key or token."""
        return f"ElsevierArticleClient(base_url={self._base_url!r})"

    def article_url(self, doi: str) -> str:
        """The URL this client asks for a DOI; it carries neither secret.

        Args:
            doi: The article's DOI.

        Returns:
            :func:`elsevier_article_url` on this client's base: the address a
            size or caching note names.
        """
        return elsevier_article_url(doi, self._base_url)

    def fetch_pdf(
        self, doi: str, output_path: Path, cancelled: Callable[[], bool]
    ) -> ElsevierFetch:
        """Ask Elsevier for this DOI's PDF and save it at ``output_path``.

        Args:
            doi: The article's DOI. One that is not Elsevier's sends nothing
                and returns an absence, which records nothing.
            output_path: Where a served PDF is saved, through a ``.part``
                file renamed into place once whole.
            cancelled: Asked before the request and between chunks; once it
                answers ``True`` the fetch stops, keeping nothing.

        Returns:
            The fetch's outcome, as the contract's ``answers`` and ``session``
            tables classify it.
        """
        if not elsevier_eligible(doi):
            return ElsevierFetch.absent()
        # The order of the contract's session table: the key, the network,
        # then the pause. None of these makes a request or records an ending.
        if self._session_state.refuses_key(self.credentials.key_digest):
            return ElsevierFetch.key_refused()
        if self._session_state.refuses_network(self.credentials.credentials_digest):
            return ElsevierFetch.network_refused()
        if self._session_state.paused:
            return ElsevierFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, HTTP_TOO_MANY_REQUESTS)
            )
        if cancelled():
            return ElsevierFetch.cancelled()
        try:
            response = self._session.get(
                elsevier_article_url(doi, self._base_url),
                stream=True,
                timeout=ELSEVIER_REQUEST_TIMEOUT_SECONDS,
                allow_redirects=False,
            )
        except requests.exceptions.RequestException as error:
            # The exception is classified and dropped, never logged: requests'
            # refusal of a header value quotes the value, the key included.
            self._session_state.record(None, self.credentials.key_digest)
            return ElsevierFetch.unreachable(request_failure_from_exception(error))
        except ValueError:
            # A header value http.client cannot encode as Latin-1 (a key with
            # a curly quote): UnicodeEncodeError, which is no RequestException.
            # No redirect is followed, so nothing else reaches here.
            self._session_state.record(None, self.credentials.key_digest)
            return ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        with closing(response):
            return self._classify(response, output_path, cancelled)

    def _classify(
        self,
        response: requests.Response,
        output_path: Path,
        cancelled: Callable[[], bool],
    ) -> ElsevierFetch:
        """Classify an answer and record how the fetch ended."""
        status = response.status_code
        if status == ELSEVIER_NETWORK_REFUSED_STATUS:
            return self._classify_forbidden(response)
        self._session_state.record(status, self.credentials.key_digest)
        if status == ELSEVIER_KEY_REFUSED_STATUS:
            return ElsevierFetch.key_refused()
        if status == HTTP_NOT_FOUND:
            return ElsevierFetch.absent()
        if status != HTTP_OK:
            return ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, status))
        if _is_first_page_only(response):
            # Read before the body: the first page is a valid PDF, and never
            # the article's text.
            logger.info(
                "Elsevier's API served the first page only (not entitled); "
                "the article is not taken from it."
            )
            return ElsevierFetch.absent()
        return self._save(response, output_path, cancelled)

    def _classify_forbidden(self, response: requests.Response) -> ElsevierFetch:
        """A 403: refused from this network when its body holds the token."""
        try:
            body = _read_error_body(response)
        except requests.exceptions.RequestException as error:
            logger.warning(
                "Elsevier's API answered HTTP 403 and its body could not be read (%s).",
                type(error).__name__,
            )
            body = b""
        if ELSEVIER_NETWORK_REFUSED_TOKEN in body:
            self._session_state.record_network_refused(self.credentials.credentials_digest)
            return ElsevierFetch.network_refused()
        self._session_state.record(ELSEVIER_NETWORK_REFUSED_STATUS, self.credentials.key_digest)
        return ElsevierFetch.unreachable(
            RequestFailure(RequestFailureKind.HTTP_STATUS, ELSEVIER_NETWORK_REFUSED_STATUS)
        )

    def _save(
        self,
        response: requests.Response,
        output_path: Path,
        cancelled: Callable[[], bool],
    ) -> ElsevierFetch:
        """Save a 200's body as the PDF, under the desktop's PDF rules."""
        chunks: Iterator[bytes] = response.iter_content(chunk_size=ELSEVIER_DOWNLOAD_CHUNK_BYTES)
        try:
            prefix = read_body_prefix(chunks, len(PDF_MAGIC_BYTES))
        except requests.exceptions.RequestException as error:
            return ElsevierFetch.unreachable(request_failure_from_exception(error))
        if not prefix.startswith(PDF_MAGIC_BYTES):
            logger.warning(
                "Elsevier's API answered HTTP 200 with a body that is not a PDF (%s).",
                response.headers.get("Content-Type", "no content type"),
            )
            return ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
        declared = _declared_length(response)
        if declared is not None and declared > MAX_PDF_SIZE:
            logger.info("Elsevier's PDF is larger than the download limit; not downloaded.")
            return ElsevierFetch.refused_for_size()
        partial = partial_download_path(output_path)
        try:
            return self._write(prefix, chunks, output_path, partial, cancelled)
        except requests.exceptions.RequestException as error:
            # Before OSError, which requests' exceptions also are.
            return ElsevierFetch.unreachable(request_failure_from_exception(error))
        except OSError as error:
            # Ours, not Elsevier's answer: the PDF was served and not saved.
            logger.error("Could not save the PDF from Elsevier's API: %s", error)
            return ElsevierFetch.not_saved()
        finally:
            discard_partial_download(partial)

    def _write(
        self,
        prefix: bytes,
        chunks: Iterator[bytes],
        output_path: Path,
        partial: Path,
        cancelled: Callable[[], bool],
    ) -> ElsevierFetch:
        """Stream the body to ``partial`` and rename it into place once whole."""
        output_path.parent.mkdir(parents=True, exist_ok=True)
        written = 0
        with open(partial, "wb") as file:
            # The prefix sniffed is the body's start, and counts as any chunk.
            for chunk in chain((prefix,), chunks):
                if cancelled():
                    return ElsevierFetch.cancelled()
                written += len(chunk)
                if written > MAX_PDF_SIZE:
                    logger.info("Elsevier's PDF outgrew the download limit; not kept.")
                    return ElsevierFetch.refused_for_size()
                file.write(chunk)
        partial.replace(output_path)
        return ElsevierFetch.served(output_path)


def configured_elsevier_credentials(
    api_key: str | None, insttoken: str | None
) -> ElsevierCredentials | None:
    """The credentials to ask with: the settings', else the environment's.

    The one place the environment fallbacks are applied, for the default
    client and :meth:`ElsevierCredentials.from_config` alike.

    Args:
        api_key: The configured key; ``ELSEVIER_API_KEY`` when this is empty.
        insttoken: The configured token; ``ELSEVIER_INSTTOKEN`` when this is
            empty. Never used without a key.

    Returns:
        The credentials, or ``None`` when no key is set: Elsevier is then not
        asked, and nothing is recorded.
    """
    key = (api_key or os.environ.get(ENV_ELSEVIER_API_KEY, "")).strip()
    if not key:
        return None
    token = (insttoken or os.environ.get(ENV_ELSEVIER_INSTTOKEN, "")).strip()
    return ElsevierCredentials(key, token or None)


#: Whether the "not configured" line was logged: once a process, not once a
#: discovery (the transparency analyser builds one per document).
_unconfigured_logged = False


def _log_unconfigured_once() -> None:
    """Log at DEBUG, once a process, that Elsevier is not asked for want of a key."""
    global _unconfigured_logged
    if not _unconfigured_logged:
        _unconfigured_logged = True
        logger.debug("Elsevier's API is not asked: no Elsevier API key is configured.")


def default_elsevier_client(
    api_key: str | None, insttoken: str | None
) -> ElsevierArticleClient | None:
    """The client discovery uses: ``None`` without a key.

    A module-level seam, as ``default_core_client`` is, so the test suite
    keeps every discovery off the real Elsevier (tests/conftest.py). Callers
    reach it through this module (``elsevier_api.default_elsevier_client``),
    so the suite's patch covers every one of them.

    Args:
        api_key: The configured key; ``ELSEVIER_API_KEY`` when this is empty.
        insttoken: The configured token; ``ELSEVIER_INSTTOKEN`` when this is
            empty. Never used without a key.

    Returns:
        A client, or ``None`` when no key is set: Elsevier is then not asked,
        and nothing is recorded.
    """
    credentials = configured_elsevier_credentials(api_key, insttoken)
    if credentials is None:
        _log_unconfigured_once()
        return None
    return ElsevierArticleClient(credentials)


def elsevier_client_for(
    credentials: ElsevierCredentials | None,
) -> ElsevierArticleClient | None:
    """The client for these credentials, through :func:`default_elsevier_client`.

    The global is looked up at call time, so the test suite's patch of
    ``default_elsevier_client`` covers every caller of this function too.

    Args:
        credentials: The configured credentials; ``None`` falls back to the
            environment's, as ``default_elsevier_client`` does.

    Returns:
        A client, or ``None`` when no key is set.
    """
    return default_elsevier_client(
        credentials.api_key if credentials is not None else None,
        credentials.insttoken if credentials is not None else None,
    )
