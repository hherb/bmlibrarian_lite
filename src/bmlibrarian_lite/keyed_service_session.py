# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Process-wide session state for a service asked with the user's own key (#480).

CORE and Elsevier share the rules: consecutive 429 endings pause the service
for the rest of the process (never lifted); an ending with the service's
key-refused status refuses that key only; and a refusal from this network
refuses those credentials only (Elsevier's alone: CORE never records one).
A fetch that makes no request records nothing. A key and its token are
remembered by SHA-256 digest alone; neither the key nor a digest is ever
logged.
"""

from __future__ import annotations

import hashlib
import logging
import threading

from .constants import HTTP_TOO_MANY_REQUESTS

logger = logging.getLogger(__name__)

_ENCODING = "utf-8"


def key_digest(api_key: str) -> str:
    """The fingerprint a refused key is remembered by (#498).

    Args:
        api_key: A key; trimmed here, so padding names the same key.

    Returns:
        The SHA-256 digest of the trimmed key's UTF-8 bytes, as hex.
    """
    return hashlib.sha256(api_key.strip().encode(_ENCODING)).hexdigest()


def credentials_digest(api_key: str, token: str | None) -> str:
    r"""The fingerprint a network refusal is remembered by.

    Args:
        api_key: A key; trimmed here.
        token: An institutional token, or ``None``; trimmed here.

    Returns:
        The SHA-256 digest (hex) of ``trim(key) + "\n" + trim(token or "")``.
    """
    text = f"{api_key.strip()}\n{(token or '').strip()}"
    return hashlib.sha256(text.encode(_ENCODING)).hexdigest()


class KeyedServiceSession:
    """What one service's fetches leave for the next, within this process."""

    def __init__(self, service: str, key_refused_status: int, pause_after: int) -> None:
        """Start unpaused, with nothing refused.

        Args:
            service: The service's name, as log lines say it.
            key_refused_status: The HTTP status that means the key is refused.
            pause_after: Consecutive 429 endings that pause the service.
        """
        self._service = service
        self._key_refused_status = key_refused_status
        self._pause_after = pause_after
        self._consecutive = 0
        self._paused = False
        self._refused_key_digest: str | None = None
        self._refused_network_digest: str | None = None
        self._lock = threading.Lock()

    @property
    def paused(self) -> bool:
        """Whether the service is paused for the rest of the session."""
        with self._lock:
            return self._paused

    def refuses_key(self, key_digest: str) -> bool:
        """Whether the service refused this key this session.

        Args:
            key_digest: The key's :func:`key_digest`.

        Returns:
            ``True`` for the refused key only; any other key is asked.
        """
        with self._lock:
            return self._refused_key_digest == key_digest

    def refuses_network(self, credentials_digest: str) -> bool:
        """Whether the service refused these credentials from this network.

        Args:
            credentials_digest: The :func:`credentials_digest` of key and token.

        Returns:
            ``True`` for the refused credentials only.
        """
        with self._lock:
            return self._refused_network_digest == credentials_digest

    def record(self, status: int | None, key_digest: str) -> None:
        """Note how one fetch that made a request ended.

        The key-refused status marks that key refused, in place of any before;
        like any ending but a 429, it resets the 429 count. A fetch that made
        no request is not recorded at all.

        Args:
            status: The HTTP status it ended on, or ``None`` when it got none.
            key_digest: The :func:`key_digest` of the key it was sent with.
        """
        with self._lock:
            if status == self._key_refused_status and self._refused_key_digest != key_digest:
                self._refused_key_digest = key_digest
                logger.warning(
                    "%s refused the configured key (HTTP %d); it is not asked "
                    "with that key again this session.",
                    self._service,
                    status,
                )
            if status != HTTP_TOO_MANY_REQUESTS:
                self._consecutive = 0
                return
            self._consecutive += 1
            if self._consecutive >= self._pause_after and not self._paused:
                self._paused = True
                logger.warning(
                    "%s answered HTTP 429 %d times in a row; it is not asked "
                    "again this session.",
                    self._service,
                    self._consecutive,
                )

    def record_network_refused(self, credentials_digest: str) -> None:
        """Note a fetch the service refused from this network (a 403 answer).

        It is an ending, so it resets the 429 count.

        Args:
            credentials_digest: The :func:`credentials_digest` it was sent with.
        """
        with self._lock:
            self._consecutive = 0
            if self._refused_network_digest != credentials_digest:
                self._refused_network_digest = credentials_digest
                logger.warning(
                    "%s refused the configured credentials from this network; "
                    "it is not asked with them again this session.",
                    self._service,
                )
