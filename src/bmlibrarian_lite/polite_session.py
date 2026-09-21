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

"""Pacing mounted on a session, so no call site has to remember it.

``urllib3``'s own ``Retry`` re-sends inside one ``send()``, where the limiter
cannot see it. So the throttle statuses are taken off ``Retry`` and retried
here instead, one ``acquire()`` per attempt: a service that is shedding load
is not asked again on the same breath.

The contract is ``doc/cross_platform/polite_request_pacing.md``.
"""

import logging
from typing import Any
from urllib.parse import urlparse

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

from .constants import (
    POLITE_MAX_THROTTLE_RETRIES,
    POLITE_THROTTLE_STATUSES,
)
from .rate_limit import limiter_for

logger = logging.getLogger(__name__)


def retry_after_seconds(response: requests.Response) -> float | None:
    """How long the service asked us to wait, if it said.

    Only the numeric form is read. The HTTP-date form is valid but rare
    here, and a wrong parse would be worse than falling back to halving.

    Args:
        response: The throttled response.

    Returns:
        The seconds asked for, or ``None`` when the header is absent or is
        not a plain number.
    """
    raw = response.headers.get("Retry-After")
    if not raw:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


class PoliteAdapter(HTTPAdapter):
    """Acquires before every attempt, and yields when the host pushes back."""

    def __init__(self, *args: Any, api_key: str | None = None, **kwargs: Any) -> None:
        """Build the adapter.

        Args:
            *args: Passed to :class:`HTTPAdapter`.
            api_key: Raises the ceiling where the service offers one.
            **kwargs: Passed to :class:`HTTPAdapter`.
        """
        self._api_key = api_key
        super().__init__(*args, **kwargs)

    def _send_once(self, request: requests.PreparedRequest, **kwargs: Any) -> Any:
        """Make one underlying request.

        Overridden in tests so no socket is opened.

        Args:
            request: The prepared request.
            **kwargs: Passed to :class:`HTTPAdapter`.

        Returns:
            The response.
        """
        return super().send(request, **kwargs)

    def send(
        self,
        request: requests.PreparedRequest,
        stream: bool = False,
        timeout: float | tuple[float | None, float | None] | None = None,
        verify: bool | str = True,
        cert: str | tuple[str, str] | None = None,
        proxies: dict[str, str] | None = None,
    ) -> requests.Response:
        """Pace the request, and retry a throttle through the pacing.

        Signature matches :meth:`HTTPAdapter.send` exactly, rather than
        ``**kwargs``, so the override is type-checked against it.

        Args:
            request: The prepared request.
            stream: Passed to :class:`HTTPAdapter`.
            timeout: Passed to :class:`HTTPAdapter`.
            verify: Passed to :class:`HTTPAdapter`.
            cert: Passed to :class:`HTTPAdapter`.
            proxies: Passed to :class:`HTTPAdapter`.

        Returns:
            The last response received. A throttle that outlives the
            retries is handed back as it is, so the caller's existing
            error handling reports it exactly as before.
        """
        raw_url = request.url
        if isinstance(raw_url, bytes):
            raw_url = raw_url.decode("utf-8", errors="replace")
        host = urlparse(raw_url or "").hostname or ""
        limiter = limiter_for(host, self._api_key)
        send_kwargs: dict[str, Any] = {
            "stream": stream,
            "timeout": timeout,
            "verify": verify,
            "cert": cert,
            "proxies": proxies,
        }
        response: requests.Response | None = None
        for _attempt in range(POLITE_MAX_THROTTLE_RETRIES + 1):
            limiter.acquire()
            response = self._send_once(request, **send_kwargs)
            if response.status_code not in POLITE_THROTTLE_STATUSES:
                limiter.succeed()
                return response
            limiter.penalise(retry_after_seconds(response))
            logger.info(f"{host} is throttling; paced down and retrying")
        assert response is not None  # the loop always runs at least once
        return response


def mount_politely(
    session: requests.Session,
    retry: Retry | None = None,
    api_key: str | None = None,
) -> requests.Session:
    """Mount polite pacing on a session, for both schemes.

    Args:
        session: The session to mount on.
        retry: The retry strategy for genuine server faults. The throttle
            statuses are removed from it, because this module owns those.
        api_key: Raises the ceiling where the service offers one.

    Returns:
        The same session, for chaining.
    """
    if retry is not None:
        allowed = [
            status
            for status in (retry.status_forcelist or [])
            if status not in POLITE_THROTTLE_STATUSES
        ]
        retry = retry.new(status_forcelist=allowed)
    adapter = PoliteAdapter(max_retries=retry or 0, api_key=api_key)
    session.mount("http://", adapter)
    session.mount("https://", adapter)
    return session
