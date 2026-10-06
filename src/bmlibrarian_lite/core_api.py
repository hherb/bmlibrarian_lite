# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""CORE's extracted text, asked by DOI with the user's own key (#480, stage C).

CORE aggregates open-access repositories and serves the text it extracted
from their copies. It is the poorest full-text form the chain reads, so it
is asked last, only when nothing earlier obtained the article. The rules are
in doc/cross_platform/fulltext_retrieval.md, "CORE's Extracted Text", pinned
by doc/cross_platform/fulltext_parity/core_fulltext.json.

The key travels in the ``Authorization`` header and nowhere else: never in a
URL, a log line or a ``repr``.
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import threading
from collections.abc import Mapping
from dataclasses import dataclass
from urllib.parse import quote

import requests
from urllib3.util.retry import Retry

from .constants import (
    CORE_API_BASE_URL,
    CORE_BACKOFF_FACTOR,
    CORE_ENCODING,
    CORE_KEY_REFUSED_STATUS,
    CORE_MAX_RETRIES,
    CORE_MIN_FULLTEXT_CHARS,
    CORE_PAUSE_AFTER_CONSECUTIVE_429,
    CORE_REQUEST_TIMEOUT_SECONDS,
    CORE_SEARCH_LIMIT,
    CORE_SEARCH_PATH,
    ENV_CORE_API_KEY,
    EUROPEPMC_USER_AGENT,
    HTTP_OK,
    HTTP_TOO_MANY_REQUESTS,
    RETRYABLE_HTTP_STATUSES,
    SERVICE_CORE,
)
from .data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)

#: Ways a DOI is written that name the same DOI; one is removed.
_DOI_PREFIXES = (
    "https://doi.org/",
    "http://doi.org/",
    "https://dx.doi.org/",
    "http://dx.doi.org/",
    "doi:",
)


def core_search_url(doi: str, base_url: str = CORE_API_BASE_URL) -> str:
    """CORE's search for one DOI, as a phrase query.

    Args:
        doi: The DOI; trimmed here.
        base_url: CORE's API root; trailing slashes are dropped.

    Returns:
        The request URL, pinned by the contract's ``search_url`` rows.
    """
    phrase = doi.strip().replace("\\", "\\\\").replace('"', '\\"')
    query = quote(f'doi:"{phrase}"', safe="")
    return (
        f"{base_url.rstrip('/')}{CORE_SEARCH_PATH}"
        f"?q={query}&limit={CORE_SEARCH_LIMIT}"
    )


def core_key_digest(api_key: str) -> str:
    """The fingerprint a refused key is remembered by (#498).

    A refusal is scoped to the key CORE refused, so a key corrected in the
    settings is asked again. The key itself is never held for that: only this
    digest is, and it is never logged.

    Args:
        api_key: A CORE key; trimmed here, so padding names the same key.

    Returns:
        The SHA-256 digest of the trimmed key's UTF-8 bytes, as hex.
    """
    return hashlib.sha256(api_key.strip().encode("utf-8")).hexdigest()


def normalise_doi(doi: str) -> str:
    """A DOI as compared: trimmed, lower-cased, one resolver prefix removed.

    Args:
        doi: A DOI as a source wrote it.

    Returns:
        The comparable form; empty for a DOI that cleans to nothing.
    """
    text = doi.strip().lower()
    for prefix in _DOI_PREFIXES:
        if text.startswith(prefix):
            text = text[len(prefix):]
            break
    return text.strip()


def core_full_text(
    answer: object, doi: str, min_chars: int = CORE_MIN_FULLTEXT_CHARS
) -> str | None:
    """The full text a CORE search answer serves for this DOI.

    Only a result whose own DOI is this article's counts: the request is a
    search, and serving another article's text as this one's would be worse
    than serving none.

    Args:
        answer: The parsed JSON answer.
        doi: The DOI asked about.
        min_chars: The fewest code points a full text holds, trimmed.

    Returns:
        The first matching result's ``fullText``, trimmed; ``None`` when no
        result is this article's full text.

    Raises:
        ValueError: If the answer is not an object, or its ``results`` is
            not a list: an answer we cannot read is not an absence.
    """
    if not isinstance(answer, Mapping):
        raise ValueError("CORE's answer is not an object")
    results = answer.get("results")
    if not isinstance(results, list):
        raise ValueError("CORE's answer holds no list of results")
    wanted = normalise_doi(doi)
    if not wanted:
        return None
    for result in results:
        if not isinstance(result, Mapping):
            continue
        result_doi = result.get("doi")
        if not isinstance(result_doi, str) or normalise_doi(result_doi) != wanted:
            continue
        text = result.get("fullText")
        if not isinstance(text, str):
            continue
        text = text.strip()
        if len(text) >= min_chars:
            return text
    return None


@dataclass(frozen=True)
class CoreFetch:
    """What asking CORE for one DOI learned: served, absent, unreachable, or refused.

    Attributes:
        text: The article's text, when served.
        failure: Why CORE could not be asked, when unreachable.
        refused_key: Whether CORE refused the key, now or earlier this
            session (#498): CORE was not asked about this article, and the
            reader is told the key, never the article.
    """

    text: str | None
    failure: RequestFailure | None
    refused_key: bool = False

    def __post_init__(self) -> None:
        """Refuse a fetch in two states at once, or a blank text."""
        if self.text is not None and self.failure is not None:
            raise ValueError("A CORE fetch is served or unreachable, never both")
        if self.refused_key and (self.text is not None or self.failure is not None):
            raise ValueError("A refused key is neither served nor unreachable")
        if self.text is not None and not self.text.strip():
            raise ValueError("A blank text is not CORE's full text")

    @classmethod
    def served(cls, text: str) -> CoreFetch:
        """CORE holds this article's text."""
        return cls(text=text, failure=None)

    @classmethod
    def absent(cls) -> CoreFetch:
        """CORE answered, and holds no full text of this article."""
        return cls(text=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> CoreFetch:
        """CORE could not be asked, or its answer could not be read."""
        return cls(text=None, failure=failure)

    @classmethod
    def key_refused(cls) -> CoreFetch:
        """CORE refused the key, so it was not asked about this article (#498)."""
        return cls(text=None, failure=None, refused_key=True)

    @property
    def is_unreachable(self) -> bool:
        """Whether the lookup failed."""
        return self.failure is not None

    def lookups(self) -> LookupRecord:
        """What this fetch leaves unsettled, as the discovery records it.

        Returns:
            Nothing for served text or an absence; a failure of CORE when it
            could not be asked; a ``KEY_REFUSED`` skip of CORE when the key
            was refused, which blocks a settled absence and is told as the
            key, never as the article not served (#498).
        """
        if self.failure is not None:
            return LookupRecord(failures=(SourceLookupFailure(SERVICE_CORE, self.failure),))
        if self.refused_key:
            return LookupRecord(
                skipped=(SourceLookupSkipped(SERVICE_CORE, LookupSkipReason.KEY_REFUSED),)
            )
        return LookupRecord()


class CoreThrottle:
    """CORE's session state: the pause after consecutive 429s, and a refused key.

    CORE's key buys a daily token budget, which no per-second pacing can
    express. Once two fetches in a row end in 429, asking again only spends
    the reader's time, so CORE is not asked again until the process ends.

    A fetch ending in HTTP 401 means CORE refused the key (#498). Every
    article would be refused alike, so that key is marked refused for the
    rest of the process and CORE is not asked with it again. The refusal is
    the key's, held as its :func:`core_key_digest`: another key, such as one
    corrected in the settings, is asked as usual, and a 401 for it refuses
    that key instead.
    """

    def __init__(self, pause_after: int = CORE_PAUSE_AFTER_CONSECUTIVE_429) -> None:
        """Start unpaused.

        Args:
            pause_after: Consecutive 429 endings that pause CORE.
        """
        self._pause_after = pause_after
        self._consecutive = 0
        self._paused = False
        self._refused_key_digest: str | None = None
        self._lock = threading.Lock()

    @property
    def paused(self) -> bool:
        """Whether CORE is paused for the rest of the session."""
        with self._lock:
            return self._paused

    def refuses(self, key_digest: str) -> bool:
        """Whether CORE refused this key this session (#498).

        Args:
            key_digest: The key's :func:`core_key_digest`.

        Returns:
            ``True`` when a fetch with this key ended in 401: it is then not
            asked again. Any other key is asked as usual.
        """
        with self._lock:
            return self._refused_key_digest == key_digest

    def record(self, status: int | None, key_digest: str) -> None:
        """Note how one fetch ended.

        A 401 marks the key it was sent with refused, in place of any key
        refused before; like any ending but a 429, it also resets the 429
        count.

        Args:
            status: The HTTP status it ended on, or ``None`` when it got none.
            key_digest: The :func:`core_key_digest` of the key it was sent with.
        """
        with self._lock:
            if status == CORE_KEY_REFUSED_STATUS and self._refused_key_digest != key_digest:
                self._refused_key_digest = key_digest
                logger.warning(
                    "CORE refused the configured key (HTTP %d); it is not asked "
                    "with that key again this session.",
                    status,
                )
            if status != HTTP_TOO_MANY_REQUESTS:
                self._consecutive = 0
                return
            self._consecutive += 1
            if self._consecutive >= self._pause_after and not self._paused:
                self._paused = True
                logger.warning(
                    "CORE answered HTTP 429 %d times in a row; it is not asked "
                    "again this session.",
                    self._consecutive,
                )


_session_throttle = CoreThrottle()


def session_core_throttle() -> CoreThrottle:
    """The pause and refused key every CORE client in this process shares."""
    return _session_throttle


def reset_core_throttle() -> None:
    """Forget the session's pause and refused key. For tests, as ``reset_limiters`` is."""
    global _session_throttle
    _session_throttle = CoreThrottle()


class CoreTextClient:
    """Asks CORE's search for one DOI's extracted text."""

    def __init__(
        self,
        api_key: str,
        base_url: str = CORE_API_BASE_URL,
        max_retries: int = CORE_MAX_RETRIES,
        throttle: CoreThrottle | None = None,
    ) -> None:
        """Build a client that sends this key.

        Args:
            api_key: The user's CORE key.
            base_url: CORE's API root.
            max_retries: Retries for a 429, a 5xx or a transport failure.
            throttle: The session pause; the process-wide one by default.

        Raises:
            ValueError: If the key is blank: without one nothing is asked.
        """
        key = api_key.strip()
        if not key:
            raise ValueError("CORE is asked only with a key")
        self._base_url = base_url
        # The key's fingerprint, for its refusal: never in the repr or a log
        self._key_digest = core_key_digest(key)
        self._throttle = throttle if throttle is not None else session_core_throttle()
        session = requests.Session()
        session.headers.update({
            "User-Agent": EUROPEPMC_USER_AGENT,
            "Accept": "application/json",
            "Authorization": f"Bearer {key}",
        })
        retry = Retry(
            total=max_retries,
            backoff_factor=CORE_BACKOFF_FACTOR,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    def __repr__(self) -> str:
        """Name the client without its key."""
        return f"CoreTextClient(base_url={self._base_url!r})"

    def fetch_full_text(self, doi: str) -> CoreFetch:
        """Ask CORE for this DOI's extracted text.

        Args:
            doi: The article's DOI.

        Returns:
            Served text, an absence (CORE answered and holds none of this
            article, or there is no DOI), a refused key (this fetch ended in
            401, or an earlier one with this key did; then nothing is sent),
            or the failure.
        """
        if not doi.strip():
            return CoreFetch.absent()
        # The key before the pause: it is the cause the reader can act on.
        if self._throttle.refuses(self._key_digest):
            return CoreFetch.key_refused()
        if self._throttle.paused:
            return CoreFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, HTTP_TOO_MANY_REQUESTS)
            )
        try:
            response = self._session.get(
                core_search_url(doi, self._base_url),
                timeout=CORE_REQUEST_TIMEOUT_SECONDS,
            )
        except requests.exceptions.RequestException as error:
            self._throttle.record(None, self._key_digest)
            return CoreFetch.unreachable(request_failure_from_exception(error))
        except ValueError:
            # A redirect that will not parse, as OpenAlex's.
            self._throttle.record(None, self._key_digest)
            return CoreFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
        self._throttle.record(response.status_code, self._key_digest)
        if response.status_code == CORE_KEY_REFUSED_STATUS:
            return CoreFetch.key_refused()
        if response.status_code != HTTP_OK:
            return CoreFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, response.status_code)
            )
        try:
            text = core_full_text(json.loads(response.content.decode(CORE_ENCODING)), doi)
        except ValueError:
            logger.warning("CORE's answer could not be read.")
            return CoreFetch.unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))
        return CoreFetch.served(text) if text is not None else CoreFetch.absent()


def default_core_client(api_key: str | None) -> CoreTextClient | None:
    """The client discovery uses: ``None`` without a key.

    A module-level seam, as ``default_openalex_client`` is, so the test
    suite keeps every discovery off the real CORE (tests/conftest.py).

    Args:
        api_key: The configured key; the ``CORE_API_KEY`` environment
            variable is used when this is empty.

    Returns:
        A client, or ``None`` when no key is set: CORE is then not asked,
        and nothing is recorded (spec decision 4).
    """
    key = (api_key or os.environ.get(ENV_CORE_API_KEY, "")).strip()
    if not key:
        logger.debug("CORE is not asked: no CORE API key is configured.")
        return None
    return CoreTextClient(key)
