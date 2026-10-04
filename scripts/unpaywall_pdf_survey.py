#!/usr/bin/env python3
r"""Why the PDFs Unpaywall names cannot be downloaded (#480).

Since #478 every platform refuses a PDF Unpaywall named that could not be
obtained: it is never offered as a link, and the open-access copy is recorded
as unsettled rather than found. That is the safe default, but it may discard
copies a browser could fetch. This script measures why each one fails,
sorting the failures into the three families #480 names:

1. **unfetchable** -- the address itself: not an http(s) URL, a dead host, a
   file the host no longer serves (404/410), or an address that leads a
   browser to no PDF either (often an abstract page once a challenge has
   cleared: the publisher's copy is not free to an anonymous reader);
2. **bot-wall** -- a defence against non-browser clients: a challenge page, a
   captcha, or a refusal a real browser passes;
3. **our-client** -- our own requests: a refusal that browser-like headers,
   sent over the same HTTP client, are enough to pass.

Each address is asked, once and without retries, by five clients:

``desktop``
    The desktop app's own headers (``pdf_discovery.USER_AGENT`` and its
    ``Accept``) on a politely mounted ``requests`` session.
``android``
    The Android app's User-Agent, and no ``Accept``, as OkHttp sends.
``apple``
    URLSession's default headers for the Apple apps (BioMedLit sets none).
    An approximation: the User-Agent's CFNetwork and Darwin versions vary.
``browser-headers``
    Chrome's navigation headers over the same ``requests`` client: what a
    header change alone would recover.
``browser``
    Headless Chromium through Playwright, launched as
    ``pdf_discovery.BrowserSession`` launches it, with a current Chrome
    User-Agent. It waits a few seconds on an HTML page for a challenge to
    clear, so a wall that only needs JavaScript is passed.

The three app clients share ``requests``' TLS stack, which neither app
uses; a wall that keys on the TLS handshake would treat the apps differently.
The ``browser`` column is the bound on what any client change could win.

Every request waits on the application's own per-host limiter, so the survey
is no more demanding of any host than the app. HTTP bodies are read to
``_PREFIX_BYTES`` and dropped: enough to see ``%PDF`` or a challenge page,
never a whole article (the browser downloads a PDF whole, as a reader's
would). Unpaywall's own ``url_for_pdf`` is kept as it gave it, public data;
the addresses a probe was redirected to lose their query string, where
signed download links carry credentials. The Unpaywall email is sent only
to Unpaywall and never written to a row.

``fetch`` writes the sample once the HTTP probes are done, then runs the
browser stage, which checkpoints every address: if it stops, ``browse``
resumes it. One browser probe is bounded at ``_BROWSER_PROBE_SECONDS``; an
overrun is the harness's failure (``browser_harness_error``), not the
host's answer.

Usage:
    # Sample DOIs, ask Unpaywall, probe every PDF address (JSON lines out);
    # 100 rows per stratum.
    python scripts/unpaywall_pdf_survey.py fetch --years 2019-2021 \\
        --target 100 --seed 1 --out tmp/unpaywall-pdf-480/dev.jsonl
    python scripts/unpaywall_pdf_survey.py fetch --years 2023-2025 \\
        --target 100 --seed 2 --out tmp/unpaywall-pdf-480/heldout.jsonl

    # Resume a browser stage that stopped.
    python scripts/unpaywall_pdf_survey.py browse tmp/unpaywall-pdf-480/dev.jsonl

    # Analyse one or more samples.
    python scripts/unpaywall_pdf_survey.py analyse doc/developer/unpaywall_pdf_survey/*.jsonl

The Unpaywall email is ``UNPAYWALL_EMAIL`` when set, else the configured
``discovery.unpaywall_email``, else ``pubmed.email``. The committed rows live
in ``doc/developer/unpaywall_pdf_survey/`` with the findings: re-analyse them
rather than re-fetch to check a figure, since hosts change their defences.
"""

from __future__ import annotations

import argparse
import asyncio
import html
import json
import os
import random
import re
import sys
import tempfile
import time
from collections import Counter, defaultdict
from collections.abc import Iterator, Mapping, Sequence
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import date, timedelta
from pathlib import Path
from typing import Any
from urllib.parse import quote, urlparse, urlunparse

from bmlibrarian_lite.constants import (
    EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
    EUROPEPMC_SEARCH_URL,
    EUROPEPMC_USER_AGENT,
    PDF_MAGIC_BYTES,
    POLITE_THROTTLE_STATUSES,
)
from bmlibrarian_lite.oa_landing_page import (
    choose_unpaywall_url,
    location_pdf_url,
    unpaywall_locations,
)
from bmlibrarian_lite.polite_session import retry_after_seconds
from bmlibrarian_lite.rate_limit import limiter_for

_UNPAYWALL_URL = "https://api.unpaywall.org/v2/{doi}"
_HTTP_OK = 200
_HTTP_NOT_FOUND = 404
_HTTP_REDIRECT_MIN = 300
_HTTP_REDIRECT_MAX = 400
_HTTP_SERVER_ERROR = 500
# Statuses that say the host no longer serves the file.
_GONE_STATUSES = frozenset({404, 410})
# Statuses that refuse the client rather than the file.
_REFUSAL_STATUSES = frozenset({401, 403, 406, 429, 451, 503})
# Statuses Cloudflare answers a challenge or a block with.
_CLOUDFLARE_REFUSALS = frozenset({403, 503})

# Bytes read from each answer: a PDF's magic number, or enough of an HTML
# page for its title and any challenge markup. The rest is never downloaded.
_PREFIX_BYTES = 64 * 1024
_CHUNK_BYTES = 8192
# Characters of a non-PDF page's visible text kept in a row.
_SNIPPET_CHARS = 160
_TITLE_CHARS = 120

# The desktop app's timeout (pdf_discovery.REQUEST_TIMEOUT), seconds.
_REQUEST_TIMEOUT_SECONDS = 30
_BROWSER_TIMEOUT_MS = 30_000
# How long the browser is left on an HTML page for a challenge to clear.
_CHALLENGE_WAIT_MS = 8_000
_CHALLENGE_POLL_MS = 500
# The bound on one whole browser probe: navigation, the challenge wait and
# a download. A probe that overruns it is the harness's failure, recorded on
# the row as one, never as the host's answer.
_BROWSER_PROBE_SECONDS = 120
_BROWSER_CLOSE_SECONDS = 15

_RECORDS_PER_DAY = 25

# Europe PMC serves an open-access PMC article before the chain reaches
# Unpaywall, so the Unpaywall PDF matters most where Europe PMC's record says
# the article is not open access. Each stratum is sampled to its own target.
STRATA: dict[str, str] = {
    "epmc-oa": "OPEN_ACCESS:Y",
    "epmc-not-oa": "OPEN_ACCESS:N",
}
_WORKERS = 6
# Most DOIs offer no PDF URL; days are drawn generously and the draw stops
# once ``target`` rows are found.
_DAY_DRAW_FACTOR = 16
_SPARE_DAYS = 4

_CURRENT_CHROME_UA = (
    "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/153.0.0.0 Safari/537.36"
)
# The desktop app's headers, from pdf_discovery.PDFDiscoverer._create_session.
# Read from the module at probe time (``_desktop_headers``) so the survey
# measures the shipped client rather than a copy of it.
_ANDROID_UA = "BMLibrarian/1.0 (Medical Fact Checker)"
_APPLE_UA = "Medical%20Fact%20Checker/1 CFNetwork/3860.100.1 Darwin/27.0.0"

CLIENTS: tuple[str, ...] = ("desktop", "android", "apple", "browser-headers", "browser")
# The clients that are one of ours; ``analyse`` classifies relative to each.
APP_CLIENTS: tuple[str, ...] = ("desktop", "android", "apple")

# Markup and headers that name a defence against automated clients. Matched
# on the lowercased start of a non-PDF body, and on header names and values.
WALL_MARKERS: dict[str, tuple[str, ...]] = {
    "cloudflare": ("just a moment", "cf-chl", "challenge-platform", "cf-mitigated", "attention required! | cloudflare"),
    "akamai": ("akamaighost", "errors.edgesuite.net", "you don't have permission to access"),
    "imperva": ("incapsula", "_incapsula_resource", "visid_incap"),
    "datadome": ("datadome", "captcha-delivery.com"),
    "perimeterx": ("px-captcha", "perimeterx", "_pxhd"),
    "aws-waf": ("awswaf", "aws-waf-token", "x-amzn-waf-action"),
    "anubis": ("anubis", "making sure you're not a bot"),
    "captcha": ("g-recaptcha", "hcaptcha", "turnstile", "captcha"),
    "proof-of-work": ("proof of work", "pow-challenge", "checking your browser", "preparing to download"),
    "robot-text": (
        "verify you are human",
        "are you a robot",
        "unusual traffic",
        "not a robot",
        "automated access",
        "bot detection",
        "ai crawlers",
        "hostile web agent",
    ),
}


# --------------------------------------------------------------------------
# Pure helpers: what a row says


def public_url(url: str | None) -> str | None:
    """``url`` without its query string or fragment, for a row.

    Signed download links (S3, CloudFront, repository tokens) carry their
    credentials in the query, and a committed row must not.

    Args:
        url: Any URL, or ``None``.

    Returns:
        The URL's scheme, host and path; ``None`` for ``None``.
    """
    if url is None:
        return None
    parts = urlparse(url)
    return urlunparse((parts.scheme, parts.netloc, parts.path, "", "", ""))


def requestable(url: str) -> bool:
    """Whether ``url`` is an absolute http(s) URL with a host.

    The rule the apps apply before asking (#474, #478); ``requests`` raises
    on anything else.

    Args:
        url: The address Unpaywall named.

    Returns:
        ``True`` when a client could send it.
    """
    parts = urlparse(url)
    return parts.scheme in ("http", "https") and bool(parts.hostname)


def wall_markers(text: str, headers: Mapping[str, str] | None = None) -> list[str]:
    """The defences named in a page's start and its headers.

    Args:
        text: The start of a non-PDF body, any case.
        headers: The answer's headers, when there are any.

    Returns:
        The sorted names in ``WALL_MARKERS`` that matched.
    """
    haystack = text.lower()
    if headers:
        haystack += "\n" + "\n".join(f"{k}: {v}" for k, v in headers.items()).lower()
    return sorted(
        name for name, needles in WALL_MARKERS.items() if any(n in haystack for n in needles)
    )


_TITLE = re.compile(r"<title[^>]*>(.*?)</title>", re.IGNORECASE | re.DOTALL)
_SCRIPT_OR_STYLE = re.compile(r"<(script|style)[^>]*>.*?</\1>", re.IGNORECASE | re.DOTALL)
_TAG = re.compile(r"<[^>]+>")
_SPACE = re.compile(r"\s+")


def page_title(text: str) -> str | None:
    """A page's ``<title>``, unescaped and collapsed.

    Args:
        text: The start of an HTML body.

    Returns:
        The title, at most ``_TITLE_CHARS`` long; ``None`` when there is none.
    """
    match = _TITLE.search(text)
    if not match:
        return None
    title = _SPACE.sub(" ", html.unescape(match.group(1))).strip()
    return title[:_TITLE_CHARS] or None


def visible_snippet(text: str) -> str | None:
    """The first visible words of a page, for reading a row by eye.

    Args:
        text: The start of a non-PDF body.

    Returns:
        At most ``_SNIPPET_CHARS`` of text outside tags, scripts and styles;
        ``None`` when there is none.
    """
    stripped = _TAG.sub(" ", _SCRIPT_OR_STYLE.sub(" ", text))
    snippet = _SPACE.sub(" ", html.unescape(stripped)).strip()
    return snippet[:_SNIPPET_CHARS] or None


def describe_body(prefix: bytes, headers: Mapping[str, str] | None) -> dict[str, Any]:
    """What a body's start says: a PDF, or a page and its defences.

    Args:
        prefix: The first bytes read.
        headers: The answer's headers, when there are any.

    Returns:
        ``pdf``; and for a body that is not one, ``title``, ``snippet`` and
        ``markers``.
    """
    if prefix.startswith(PDF_MAGIC_BYTES):
        return {"pdf": True}
    text = prefix.decode("utf-8", errors="ignore")
    return {
        "pdf": False,
        "title": page_title(text),
        "snippet": visible_snippet(text),
        "markers": wall_markers(text, headers),
    }


def served(probe: Mapping[str, Any] | None) -> bool:
    """Whether a probe got the PDF: a 200 whose body starts ``%PDF``.

    Args:
        probe: One client's probe, or ``None`` when that client was not run.

    Returns:
        ``True`` only for a served PDF.
    """
    return probe is not None and probe.get("status") == _HTTP_OK and bool(probe.get("pdf"))


@dataclass(frozen=True)
class Verdict:
    """Why one client could not obtain one address.

    Attributes:
        family: ``served``, ``unfetchable``, ``bot-wall``, ``our-client`` or
            ``unclassified``.
        reason: The evidence within the family, for example ``gone``.
    """

    family: str
    reason: str


def probe_markers(probe: Mapping[str, Any] | None) -> list[str]:
    """The defences a probe names, at fetch time or in its kept text now.

    Those found at fetch time, those its stored title and snippet name
    under the current ``WALL_MARKERS``, and Cloudflare for a 403 or 503 it
    served itself. Re-reading the stored text lets a marker added after a sample was
    fetched reach it, as far as the kept text allows.

    Args:
        probe: One client's probe, or ``None``.

    Returns:
        The sorted marker names.
    """
    if not probe:
        return []
    kept = f"{probe.get('title') or ''}\n{probe.get('snippet') or ''}"
    found = set(probe.get("markers") or ()) | set(wall_markers(kept))
    server = str((probe.get("headers") or {}).get("server", "")).lower()
    if probe.get("status") in _CLOUDFLARE_REFUSALS and server == "cloudflare":
        # Cloudflare's own refusal, whatever the page says: ScienceDirect's
        # opens with a large inline font, and the challenge markup lies
        # beyond the bytes a probe reads.
        found.add("cloudflare")
    return sorted(found)


def _all_probes(row: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """Every probe a row carries, in ``CLIENTS`` order."""
    probes = row.get("probes") or {}
    return [probes[name] for name in CLIENTS if name in probes]


def _transport_failed(probe: Mapping[str, Any]) -> bool:
    """Whether a probe got no HTTP answer at all."""
    return probe.get("status") is None


def classify(row: Mapping[str, Any], client: str = "desktop") -> Verdict:
    """Sort one address into a #480 family, as seen by one of our clients.

    In order: another of our clients, or browser headers over the same
    HTTP client, being served makes it ``our-client``; the browser being
    served makes it a ``bot-wall`` (``js-challenge`` when our client was
    shown a challenge page, ``browser-only`` when it was refused without
    one). A browser still shown a challenge is a wall too. Where our client
    was challenged and the browser got past it without being served, what
    the browser found decides (:func:`_behind_the_challenge`). Only then
    does the address itself come into question. Without a browser probe no
    wall can be told from a genuine refusal, so such a row is
    ``unclassified``.

    Args:
        row: A sample row.
        client: The app client to judge, one of ``APP_CLIENTS``.

    Returns:
        The verdict.
    """
    probes = row.get("probes") or {}
    ours = probes.get(client)
    if served(ours):
        return Verdict("served", "pdf")
    if not requestable(row.get("pdf_url") or ""):
        return Verdict("unfetchable", "address")
    challenged = bool(probe_markers(ours))

    if any(served(probes.get(other)) for other in APP_CLIENTS if other != client):
        return Verdict("our-client", "user-agent")
    if served(probes.get("browser-headers")):
        return Verdict("our-client", "headers")

    browser = probes.get("browser")
    if served(browser):
        return Verdict("bot-wall", "js-challenge" if challenged else "browser-only")
    if browser is None:
        return Verdict("unclassified", "challenge-unverified" if challenged else "no-browser-probe")
    if probe_markers(browser):
        return Verdict("bot-wall", "challenge-in-browser")
    if challenged:
        return _behind_the_challenge(browser)

    everyone = _all_probes(row)
    if all(probe.get("status") in _GONE_STATUSES for probe in everyone):
        return Verdict("unfetchable", "gone")
    if all(_transport_failed(probe) for probe in everyone):
        return Verdict("unfetchable", "dead-host")
    if all(probe.get("status") == _HTTP_OK for probe in everyone):
        return Verdict("unfetchable", "not-a-pdf")
    if all(probe.get("status") in _REFUSAL_STATUSES for probe in everyone):
        return Verdict("unclassified", "refused-everywhere")
    return Verdict("unclassified", f"mixed:{outcome(ours)}")


def _behind_the_challenge(browser: Mapping[str, Any]) -> Verdict:
    """What the browser found where our client was shown a challenge.

    Publishers behind Cloudflare send a reader with no access from the PDF
    address to the article's page; the browser then lands on a titled page
    with no challenge on it, whatever its status (Wiley answers 403 there).
    That address offers no free PDF, wall or no wall. A blank page means
    the challenge never cleared, so it is still a wall; a server error says
    nothing about the article.

    Args:
        browser: The browser's probe, not served and naming no defence.

    Returns:
        The verdict.
    """
    status = browser.get("status")
    if status is not None and status >= _HTTP_SERVER_ERROR:
        return Verdict("unclassified", "host-error")
    if status in _GONE_STATUSES:
        return Verdict("unfetchable", "gone-behind-wall")
    if browser.get("title") or browser.get("snippet"):
        if status is not None and _HTTP_REDIRECT_MIN <= status < _HTTP_REDIRECT_MAX:
            # The browser's last navigation was itself a redirect: it stopped
            # on the way, so where it was going is unknown.
            return Verdict("unclassified", "browser-stopped-mid-redirect")
        return Verdict("unfetchable", "no-free-pdf-behind-wall")
    return Verdict("bot-wall", "challenge-unresolved")


def outcome(probe: Mapping[str, Any] | None) -> str:
    """Name what one probe got, for tables.

    Args:
        probe: One client's probe, or ``None``.

    Returns:
        ``pdf``, ``html-200``, ``http-<status>``, ``error:<kind>`` or
        ``not-run``.
    """
    if probe is None:
        return "not-run"
    status = probe.get("status")
    if status is None:
        return f"error:{probe.get('error') or 'unknown'}"
    if status == _HTTP_OK:
        return "pdf" if probe.get("pdf") else "html-200"
    return f"http-{status}"


def host_of(row: Mapping[str, Any]) -> str:
    """The host Unpaywall's PDF address names, ``?`` when it has none."""
    return urlparse(row.get("pdf_url") or "").hostname or "?"


# --------------------------------------------------------------------------
# Sampling: Europe PMC for DOIs, Unpaywall for the PDF it names


def _requests() -> Any:
    """Import ``requests``, or explain how to get it.

    Returns:
        The ``requests`` module.

    Raises:
        SystemExit: If ``requests`` is not installed.
    """
    try:
        import requests
    except ImportError as error:  # pragma: no cover - depends on the environment
        raise SystemExit("this script needs `requests`: pip install requests") from error
    return requests


def unpaywall_email() -> str:
    """The address to ask Unpaywall with.

    Returns:
        ``UNPAYWALL_EMAIL``, else the configured Unpaywall email, else the
        configured PubMed email.

    Raises:
        SystemExit: If none is usable; Unpaywall refuses every request
            without one.
    """
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.pdf_discovery import usable_unpaywall_email

    config = LiteConfig.load()
    for candidate in (
        os.environ.get("UNPAYWALL_EMAIL"),
        config.discovery.unpaywall_email,
        config.pubmed.email,
    ):
        email: str | None = usable_unpaywall_email(candidate)
        if email:
            return email
    raise SystemExit("no Unpaywall email: set UNPAYWALL_EMAIL or configure one")


def _random_days(years: tuple[int, int], count: int, rng: random.Random) -> list[date]:
    """Distinct random days within an inclusive year range.

    Args:
        years: First and last year.
        count: How many days to draw.
        rng: The seeded source of randomness.

    Returns:
        The days, in drawing order.
    """
    first = date(years[0], 1, 1)
    span = (date(years[1], 12, 31) - first).days + 1
    offsets = rng.sample(range(span), min(count, span))
    return [first + timedelta(days=offset) for offset in offsets]


def _search_results(data: object) -> list[dict[str, Any]]:
    """The records of a Europe PMC search answer, ignoring anything else."""
    result_list = data.get("resultList") if isinstance(data, dict) else None
    results = result_list.get("result") if isinstance(result_list, dict) else None
    if not isinstance(results, list):
        return []
    return [result for result in results if isinstance(result, dict)]


def records_with_doi(day: date, query: str, session: Any) -> list[dict[str, Any]]:
    """PubMed records first published on ``day`` that match and carry a DOI.

    Args:
        day: The publication day.
        query: The stratum's Europe PMC expression.
        session: A ``requests`` session.

    Returns:
        Europe PMC ``lite`` results with a ``doi``.

    Raises:
        requests.HTTPError: If the search fails; a sample with a day missing
            would not be the sample asked for.
    """
    limiter_for(urlparse(EUROPEPMC_SEARCH_URL).hostname or "").acquire()
    response = session.get(
        EUROPEPMC_SEARCH_URL,
        params={
            "query": f"SRC:MED AND ({query}) AND FIRST_PDATE:{day.isoformat()}",
            "format": "json",
            "resultType": "lite",
            "pageSize": _RECORDS_PER_DAY,
        },
        headers={"User-Agent": EUROPEPMC_USER_AGENT},
        timeout=EUROPEPMC_REQUEST_TIMEOUT_SECONDS,
    )
    response.raise_for_status()
    return [r for r in _search_results(response.json()) if isinstance(r.get("doi"), str)]


def ask_unpaywall(doi: str, email: str, session: Any) -> tuple[str, dict[str, Any] | None]:
    """Unpaywall's answer for one DOI, once.

    Args:
        doi: The DOI.
        email: The contact address Unpaywall requires.
        session: A ``requests`` session.

    Returns:
        ``("answered", data)``, ``("unknown", None)`` for a 404, or
        ``("failed", None)``. The request URL carries ``email``, so it is
        never logged or returned.
    """
    requests = _requests()
    limiter = limiter_for("api.unpaywall.org")
    limiter.acquire()
    try:
        response = session.get(
            _UNPAYWALL_URL.format(doi=quote(doi, safe="")),
            params={"email": email},
            timeout=_REQUEST_TIMEOUT_SECONDS,
        )
    except requests.RequestException:
        return "failed", None
    if response.status_code in POLITE_THROTTLE_STATUSES:
        limiter.penalise(retry_after_seconds(response))
    if response.status_code == _HTTP_NOT_FOUND:
        return "unknown", None
    if response.status_code != _HTTP_OK:
        return "failed", None
    try:
        data = response.json()
    except ValueError:
        return "failed", None
    return ("answered", data) if isinstance(data, dict) else ("failed", None)


def unpaywall_features(data: Mapping[str, Any], pdf_url: str) -> dict[str, Any]:
    """What Unpaywall says about the article and the location it chose.

    Args:
        data: Unpaywall's answer.
        pdf_url: The ``url_for_pdf`` ``choose_unpaywall_url`` picked.

    Returns:
        The article's OA status and publisher, the chosen location's host
        type, version, licence and repository, and how many locations offer
        a PDF (the desktop tries every one; the apps only the first).
    """
    locations = unpaywall_locations(data)
    chosen: Mapping[str, Any] = next(
        (loc for loc in locations if location_pdf_url(loc) == pdf_url), {}
    )
    return {
        "oa_status": data.get("oa_status"),
        "publisher": data.get("publisher"),
        "journal": data.get("journal_name"),
        "host_type": chosen.get("host_type"),
        "version": chosen.get("version"),
        "license": chosen.get("license"),
        "repository": chosen.get("repository_institution"),
        "evidence": chosen.get("evidence"),
        "pdf_locations": sum(1 for loc in locations if location_pdf_url(loc)),
    }


# --------------------------------------------------------------------------
# Probing


def _desktop_headers() -> dict[str, str | None]:
    """The desktop app's download headers, read from the shipped session."""
    from bmlibrarian_lite.pdf_discovery import PDFDiscoverer

    session = PDFDiscoverer(unpaywall_email=None, use_browser_fallback=False)._session
    return {
        "User-Agent": session.headers["User-Agent"],
        "Accept": session.headers["Accept"],
    }


def client_headers() -> dict[str, dict[str, str | None]]:
    """The headers each ``requests`` client sends. ``None`` removes one."""
    return {
        "desktop": _desktop_headers(),
        # OkHttp sends no Accept of its own.
        "android": {"User-Agent": _ANDROID_UA, "Accept": None},
        "apple": {
            "User-Agent": _APPLE_UA,
            "Accept": "*/*",
            "Accept-Language": "en-AU,en;q=0.9",
        },
        "browser-headers": {
            "User-Agent": _CURRENT_CHROME_UA,
            "Accept": (
                "text/html,application/xhtml+xml,application/xml;q=0.9,"
                "image/avif,image/webp,image/apng,*/*;q=0.8"
            ),
            "Accept-Language": "en-AU,en;q=0.9",
            "Sec-Ch-Ua": '"Chromium";v="153", "Google Chrome";v="153", "Not.A/Brand";v="99"',
            "Sec-Ch-Ua-Mobile": "?0",
            "Sec-Ch-Ua-Platform": '"macOS"',
            "Sec-Fetch-Dest": "document",
            "Sec-Fetch-Mode": "navigate",
            "Sec-Fetch-Site": "none",
            "Sec-Fetch-User": "?1",
            "Upgrade-Insecure-Requests": "1",
        },
    }


def _polite_session() -> Any:
    """A ``requests`` session paced per host, every hop, with no retries."""
    from urllib3.util.retry import Retry

    from bmlibrarian_lite.polite_session import mount_politely

    requests = _requests()
    return mount_politely(requests.Session(), retry=Retry(total=0, redirect=10, raise_on_redirect=False))


def read_prefix(chunks: Iterator[bytes], limit: int = _PREFIX_BYTES) -> bytes:
    """Up to ``limit`` bytes from a body's chunks; the rest is left unread.

    Args:
        chunks: The body, in chunks.
        limit: How many bytes to keep at most.

    Returns:
        The start of the body.
    """
    prefix = b""
    for chunk in chunks:
        prefix += chunk
        if len(prefix) >= limit:
            break
    return prefix[:limit]


_KEPT_HEADERS = ("content-type", "server", "content-length")


def probe_http(url: str, headers: Mapping[str, str | None]) -> dict[str, Any]:
    """Ask for ``url`` once with ``headers`` and describe the answer.

    Args:
        url: The PDF address.
        headers: The client's headers; ``None`` removes a session default.

    Returns:
        ``status`` (``None`` with ``error`` when no answer came), the final
        URL and redirect hops, kept headers, and :func:`describe_body`.
    """
    requests = _requests()
    started = time.monotonic()
    session = _polite_session()
    try:
        response = session.get(
            url,
            headers=dict(headers),
            stream=True,
            timeout=_REQUEST_TIMEOUT_SECONDS,
            allow_redirects=True,
        )
        try:
            prefix = read_prefix(response.iter_content(chunk_size=_CHUNK_BYTES))
        finally:
            response.close()
    except requests.RequestException as error:
        return {
            "status": None,
            "error": type(error).__name__,
            "seconds": round(time.monotonic() - started, 2),
        }
    finally:
        session.close()
    kept = {name: response.headers[name] for name in _KEPT_HEADERS if name in response.headers}
    return {
        "status": response.status_code,
        "final_url": public_url(response.url),
        "hops": [[hop.status_code, urlparse(hop.url).hostname] for hop in response.history],
        "headers": kept,
        **describe_body(prefix, response.headers),
        "seconds": round(time.monotonic() - started, 2),
    }


class BrowserProbe:
    """Headless Chromium, with cookies cleared between addresses.

    Launched as ``pdf_discovery.BrowserSession`` launches it (automation
    flag off, downloads accepted), with a current Chrome User-Agent rather
    than its ``HeadlessChrome`` default, which every wall reads. The profile
    sets Chrome's "download PDFs instead of opening them" preference: the
    built-in viewer takes a PDF's body, so a PDF it displayed could not be
    checked for ``%PDF``, and the control (:func:`browser_control`) failed
    on four of seven pilot addresses. A downloaded PDF is read whole, as a
    reader's browser would read it.

    Async, so that :meth:`probe` can be bounded: a stalled download blocks
    Playwright's ``download.path()`` indefinitely, and the first full run
    hung on one for good.
    """

    def __init__(self) -> None:
        """Nothing runs until :meth:`start`."""
        self._profile: tempfile.TemporaryDirectory[str] | None = None
        self._playwright: Any = None
        self._context: Any = None

    async def start(self) -> None:
        """Start Playwright and the browser.

        Raises:
            SystemExit: If Playwright is not installed.
        """
        try:
            from playwright.async_api import async_playwright
        except ImportError as error:  # pragma: no cover - depends on the environment
            raise SystemExit(
                "the browser probe needs Playwright: pip install playwright && "
                "playwright install chromium (or pass --no-browser)"
            ) from error
        self._playwright = await async_playwright().start()
        await self._launch()

    async def _launch(self) -> None:
        """Open a persistent context on a fresh throwaway profile.

        Fresh on every launch: a context replaced after a timeout may still
        hold its profile while it closes, and a relaunch on the same one
        failed every probe after it (11 in a row in the first held-out run).
        """
        self._discard_profile()
        self._profile = tempfile.TemporaryDirectory(prefix="unpaywall-pdf-survey-")
        preferences = Path(self._profile.name) / "Default" / "Preferences"
        preferences.parent.mkdir(parents=True)
        preferences.write_text(
            json.dumps({"plugins": {"always_open_pdf_externally": True}}), encoding="utf-8"
        )
        self._context = await self._playwright.chromium.launch_persistent_context(
            self._profile.name,
            headless=True,
            channel="chromium",
            accept_downloads=True,
            user_agent=_CURRENT_CHROME_UA,
            args=["--disable-blink-features=AutomationControlled"],
        )

    async def restart(self) -> None:
        """Replace a context a timed-out probe may have left wedged."""
        try:
            await asyncio.wait_for(self._context.close(), _BROWSER_CLOSE_SECONDS)
        except Exception:  # noqa: BLE001 - a wedged context is replaced regardless
            pass
        await self._launch()

    async def close(self) -> None:
        """Stop the browser and Playwright, and delete the profile."""
        try:
            try:
                await asyncio.wait_for(self._context.close(), _BROWSER_CLOSE_SECONDS)
            finally:
                await self._playwright.stop()
        finally:
            self._discard_profile()

    def _discard_profile(self) -> None:
        """Delete the current profile, if any; a locked file is left behind."""
        if self._profile is not None:
            self._profile.cleanup()
            self._profile = None

    async def probe(self, url: str) -> dict[str, Any]:
        """Open ``url`` and describe what the browser ended up with.

        A PDF arrives as a download. An HTML page is given
        ``_CHALLENGE_WAIT_MS`` to clear a challenge (reload, redirect, or
        start the download). The caller bounds the whole probe.

        Args:
            url: The PDF address.

        Returns:
            The same fields as :func:`probe_http`, with ``download`` when the
            PDF came as one.
        """
        from playwright.async_api import Error as PlaywrightError

        host = urlparse(url).hostname or ""
        limiter_for(host).acquire()
        started = time.monotonic()
        await self._context.clear_cookies()
        page = await self._context.new_page()
        downloads: list[Any] = []
        navigations: list[Any] = []
        page.on("download", lambda download: downloads.append(download))
        page.on(
            "response",
            lambda r: navigations.append(r)
            if r.request.is_navigation_request() and r.frame == page.main_frame
            else None,
        )
        error: str | None = None
        try:
            try:
                await page.goto(url, wait_until="domcontentloaded", timeout=_BROWSER_TIMEOUT_MS)
            except PlaywrightError as failure:
                # "Download is starting" is how every PDF ends a navigation
                # under this profile; anything else is the browser's error.
                if "Download is starting" not in str(failure):
                    error = _browser_error(str(failure))
            waited = 0
            while not downloads and waited < _CHALLENGE_WAIT_MS and error is None:
                await page.wait_for_timeout(_CHALLENGE_POLL_MS)
                waited += _CHALLENGE_POLL_MS
            return await self._describe(page, navigations, downloads, error, started)
        finally:
            await page.close()

    @staticmethod
    async def _describe(
        page: Any,
        navigations: list[Any],
        downloads: list[Any],
        error: str | None,
        started: float,
    ) -> dict[str, Any]:
        """Turn what the browser saw into a probe row."""
        last = navigations[-1] if navigations else None
        hops = [[r.status, urlparse(r.url).hostname] for r in navigations[:-1]]
        if downloads:
            download = downloads[0]
            failure = await download.failure()
            path = None if failure else await download.path()
            if path is None:
                return {
                    "status": None,
                    "error": f"download:{failure or 'no-file'}",
                    "seconds": round(time.monotonic() - started, 2),
                }
            return {
                "status": _HTTP_OK,
                "download": True,
                "final_url": public_url(download.url),
                "hops": hops,
                **describe_body(Path(path).read_bytes()[:_PREFIX_BYTES], None),
                "seconds": round(time.monotonic() - started, 2),
            }
        seconds = round(time.monotonic() - started, 2)
        if last is None:
            return {"status": None, "error": error or "no-navigation", "seconds": seconds}
        headers = last.headers
        try:
            text = await page.content()
        except Exception:  # noqa: BLE001 - a page mid-navigation has no content yet
            text = ""
        return {
            "status": last.status,
            "final_url": public_url(last.url),
            "hops": hops,
            "headers": {k: headers[k] for k in _KEPT_HEADERS if k in headers},
            **describe_body(text.encode("utf-8")[:_PREFIX_BYTES], headers),
            "seconds": seconds,
        }


_NET_ERROR = re.compile(r"net::(ERR_[A-Z_]+)")


def _browser_error(message: str) -> str:
    """A browser failure reduced to its ``net::ERR_*`` code or kind."""
    match = _NET_ERROR.search(message)
    if match:
        return match.group(1)
    return "timeout" if "Timeout" in message else "browser-error"


def probe_row(row: dict[str, Any], headers: Mapping[str, Mapping[str, str | None]]) -> dict[str, Any]:
    """Probe one row's address with every ``requests`` client.

    Args:
        row: A sample row with ``pdf_url``.
        headers: :func:`client_headers`.

    Returns:
        The row, with ``probes`` holding one entry per client. An address no
        client could send gets no probes: :func:`classify` settles it.
    """
    url = row["pdf_url"]
    probes: dict[str, Any] = {}
    if requestable(url):
        for client, sent in headers.items():
            probes[client] = probe_http(url, sent)
    return {**row, "probes": probes}


def sample_stratum(
    stratum: str,
    years: tuple[int, int],
    target: int,
    rng: random.Random,
    email: str,
    session: Any,
    seen: set[str],
) -> tuple[list[dict[str, Any]], Counter[str]]:
    """Draw DOIs from random days until ``target`` name a PDF in Unpaywall.

    Args:
        stratum: A name in ``STRATA``.
        years: First and last publication year.
        target: How many rows (DOIs whose Unpaywall answer names a PDF) to
            collect.
        rng: The seeded source of randomness.
        email: The Unpaywall contact address.
        session: A ``requests`` session.
        seen: DOIs already drawn, by any stratum; updated.

    Returns:
        The rows, and what Unpaywall answered for every DOI asked.
    """
    tally: Counter[str] = Counter()
    rows: list[dict[str, Any]] = []
    days = _DAY_DRAW_FACTOR * target // _RECORDS_PER_DAY + _SPARE_DAYS
    for day in _random_days(years, days, rng):
        if len(rows) >= target:
            break
        for record in records_with_doi(day, STRATA[stratum], session):
            doi = record["doi"].strip().lower()
            if len(rows) >= target or doi in seen:
                continue
            seen.add(doi)
            state, data = ask_unpaywall(doi, email, session)
            tally[f"unpaywall-{state}"] += 1
            if data is None:
                continue
            choice = choose_unpaywall_url(data)
            if choice.pdf_url is None:
                tally["landing-page-only" if choice.landing_page else "no-oa-location"] += 1
                continue
            tally["pdf-url"] += 1
            rows.append(
                {
                    "stratum": stratum,
                    "years": list(years),
                    "doi": doi,
                    "pmid": record.get("pmid"),
                    "europepmc": {
                        flag: record.get(flag, "?")
                        for flag in ("isOpenAccess", "inEPMC", "inPMC", "hasPDF")
                    },
                    "unpaywall": unpaywall_features(data, choice.pdf_url),
                    # Unpaywall's address as it gave it, query and all: public
                    # data, and a repository link (``?sequence=1``) needs it.
                    "pdf_url": choice.pdf_url,
                }
            )
        print(f"  [{stratum}] {day}: {len(rows)}/{target} rows, {dict(tally)}", file=sys.stderr)
    return rows, tally


def fetch_sample(
    years: tuple[int, int],
    target: int,
    seed: int,
    out: Path,
    use_browser: bool = True,
    strata: Sequence[str] = tuple(STRATA),
) -> None:
    """Sample DOIs, find the PDFs Unpaywall names, probe each, write JSON lines.

    The rows go to a ``.partial`` file beside ``out``, which replaces
    ``out`` only once every row is written. The file's first line is the
    sampling header: what Unpaywall answered, per stratum.

    Args:
        years: First and last publication year.
        target: Rows to collect per stratum.
        seed: Seed for the day draw, so a run can be repeated.
        out: The JSON-lines file to write.
        use_browser: Whether to run the browser probe.
        strata: Names from ``STRATA`` to sample.
    """
    requests = _requests()
    email = unpaywall_email()
    rng = random.Random(seed)
    session = requests.Session()
    seen: set[str] = set()
    rows: list[dict[str, Any]] = []
    sampling: dict[str, dict[str, int]] = {}
    for stratum in strata:
        found, tally = sample_stratum(stratum, years, target, rng, email, session, seen)
        rows.extend(found)
        sampling[stratum] = dict(tally)

    headers = client_headers()
    with ThreadPoolExecutor(_WORKERS) as pool:
        probed = list(pool.map(lambda r: probe_row(r, headers), rows))
    print(f"  probed {len(probed)} addresses over HTTP", file=sys.stderr)
    write_sample(out, {"sampling": sampling, "years": list(years), "seed": seed}, probed)
    if use_browser:
        browse_sample(out)


def write_sample(path: Path, header: Mapping[str, Any], rows: Sequence[Mapping[str, Any]]) -> None:
    """Write a sample through a ``.partial`` file.

    A stopped write leaves the previous file as it was.

    Args:
        path: The JSON-lines file.
        header: The sampling header, written first.
        rows: The rows.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    partial = path.with_name(path.name + ".partial")
    with partial.open("w", encoding="utf-8") as sink:
        sink.write(json.dumps(header) + "\n")
        for row in rows:
            sink.write(json.dumps(row) + "\n")
    partial.replace(path)


def browser_checkpoint(path: Path) -> Path:
    """Where :func:`browse_sample` keeps the probes it has finished."""
    return path.with_name(path.name + ".browser")


def read_checkpoint(checkpoint: Path) -> dict[str, dict[str, Any]]:
    """The finished browser probes, by DOI.

    Args:
        checkpoint: The file :func:`browse_sample` appends to.

    Returns:
        Each DOI's entry: ``{"probe": ...}`` or ``{"harness_error": ...}``.
        A last line cut off by a stop is ignored and probed again.
    """
    done: dict[str, dict[str, Any]] = {}
    if not checkpoint.exists():
        return done
    for line in checkpoint.read_text(encoding="utf-8").splitlines():
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        done[entry["doi"]] = entry
    return done


def merge_browser_probes(
    rows: Sequence[dict[str, Any]], done: Mapping[str, Mapping[str, Any]]
) -> list[dict[str, Any]]:
    """Put each finished browser probe on its row.

    A harness failure becomes ``browser_harness_error`` and no probe, so
    :func:`classify` cannot read it as the host's answer.

    Args:
        rows: The sample rows.
        done: :func:`read_checkpoint`.

    Returns:
        New rows.
    """
    merged: list[dict[str, Any]] = []
    for row in rows:
        entry = done.get(row["doi"])
        row = {**row, "probes": dict(row.get("probes") or {})}
        row.pop("browser_harness_error", None)
        row["probes"].pop("browser", None)
        if entry and "probe" in entry:
            row["probes"]["browser"] = entry["probe"]
        elif entry:
            row["browser_harness_error"] = entry["harness_error"]
        merged.append(row)
    return merged


def browse_sample(path: Path) -> None:
    """Add the browser probe to every row of a sample, resumably.

    Each finished probe is appended to :func:`browser_checkpoint`, so a
    stopped run picks up where it left off; the sample is rewritten once
    every row is done, and the checkpoint removed. Run on a finished sample,
    it probes again only the rows a harness failure left without a probe.

    Args:
        path: A sample written by ``fetch``.
    """
    rows, headers = load_samples([path])
    checkpoint = browser_checkpoint(path)
    done = read_checkpoint(checkpoint)
    # A finished sample keeps the probes it has; only the rows without one
    # (a harness failure) are probed again.
    kept = [
        {"doi": r["doi"], "probe": r["probes"]["browser"]}
        for r in rows
        if "browser" in (r.get("probes") or {}) and r["doi"] not in done
    ]
    if kept:
        with checkpoint.open("a", encoding="utf-8") as sink:
            sink.writelines(json.dumps(entry) + "\n" for entry in kept)
        done = read_checkpoint(checkpoint)
    pending = [r for r in rows if requestable(r["pdf_url"]) and r["doi"] not in done]
    print(f"  browser: {len(done)} done, {len(pending)} to go", file=sys.stderr)
    asyncio.run(_browse(pending, checkpoint))
    write_sample(path, headers[0], merge_browser_probes(rows, read_checkpoint(checkpoint)))
    checkpoint.unlink()


async def _browse(rows: Sequence[Mapping[str, Any]], checkpoint: Path) -> None:
    """Probe ``rows`` in the browser, one at a time, appending each result."""
    browser = BrowserProbe()
    await browser.start()
    try:
        with checkpoint.open("a", encoding="utf-8") as sink:
            for index, row in enumerate(rows, 1):
                entry: dict[str, Any] = {"doi": row["doi"]}
                try:
                    entry["probe"] = await asyncio.wait_for(
                        browser.probe(row["pdf_url"]), _BROWSER_PROBE_SECONDS
                    )
                except TimeoutError:
                    entry["harness_error"] = "timeout"
                    await browser.restart()
                except Exception as failure:  # noqa: BLE001 - recorded on the row
                    entry["harness_error"] = type(failure).__name__
                    await browser.restart()
                sink.write(json.dumps(entry) + "\n")
                sink.flush()
                if index % 25 == 0:
                    print(f"  browser: {index}/{len(rows)}", file=sys.stderr)
    finally:
        await browser.close()


# --------------------------------------------------------------------------
# Analysis


def load_samples(paths: Sequence[Path]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """Read the rows and the sampling headers of one or more samples.

    Args:
        paths: Files written by ``fetch``.

    Returns:
        The rows, and each file's sampling header (its first line).
    """
    rows: list[dict[str, Any]] = []
    headers: list[dict[str, Any]] = []
    for path in paths:
        with path.open(encoding="utf-8") as source:
            for line in source:
                if not line.strip():
                    continue
                item = json.loads(line)
                (headers if "sampling" in item else rows).append(item)
    return rows, headers


def reaches_unpaywall_tier(row: Mapping[str, Any]) -> bool:
    """Whether an app would get as far as the Unpaywall PDF for this article.

    The chain asks Europe PMC first, and an open-access PMC article is
    served there; a row whose search record says ``isOpenAccess=N`` is one
    for which the Unpaywall PDF is the copy that matters.

    Args:
        row: A sample row.

    Returns:
        ``True`` unless Europe PMC states the article is open access.
    """
    return (row.get("europepmc") or {}).get("isOpenAccess") != "Y"


def family_table(rows: Sequence[Mapping[str, Any]], client: str) -> Counter[tuple[str, str]]:
    """Count verdicts for one client.

    Args:
        rows: Sample rows.
        client: One of ``APP_CLIENTS``.

    Returns:
        ``(family, reason)`` counts.
    """
    return Counter(
        (verdict.family, verdict.reason) for verdict in (classify(row, client) for row in rows)
    )


def browser_control(rows: Sequence[Mapping[str, Any]]) -> list[str]:
    """Addresses an app client was served and the browser was not.

    Each one is a defect in the browser harness, or a host that answers a
    browser worse than a script: either way the browser column cannot be
    read as a bound for that row.

    Args:
        rows: Sample rows.

    Returns:
        Their DOIs.
    """
    return [
        row["doi"]
        for row in rows
        if "browser" in (row.get("probes") or {})
        and any(served(row["probes"].get(c)) for c in APP_CLIENTS)
        and not served(row["probes"]["browser"])
    ]


def signal_table(rows: Sequence[Mapping[str, Any]], client: str) -> dict[str, Counter[str]]:
    """A client's failures, split by the one signal it has at run time.

    The app cannot run a browser to decide; it has its own answer. Whether
    that answer was a challenge page (:func:`probe_markers`) is the
    candidate rule for "offer the link to open in a browser", and this
    table is what the rule would get right and wrong.

    Args:
        rows: Sample rows.
        client: One of ``APP_CLIENTS``.

    Returns:
        ``family/reason`` counts for the failures shown a challenge and for
        those that were not.
    """
    table: dict[str, Counter[str]] = {"challenged": Counter(), "not challenged": Counter()}
    for row in rows:
        verdict = classify(row, client)
        if verdict.family == "served":
            continue
        label = "challenged" if probe_markers((row.get("probes") or {}).get(client)) else "not challenged"
        table[label][f"{verdict.family}/{verdict.reason}"] += 1
    return table


def _share(part: int, whole: int) -> str:
    """``part/whole (pct%)``."""
    return f"{part}/{whole} ({100 * part / whole:.0f}%)" if whole else f"{part}/0"


def analyse(rows: Sequence[Mapping[str, Any]], headers: Sequence[Mapping[str, Any]] = ()) -> str:
    """Render the survey's tables.

    Args:
        rows: Sample rows.
        headers: The samples' sampling headers.

    Returns:
        A plain-text report.
    """
    lines: list[str] = [f"{len(rows)} addresses"]
    for header in headers:
        lines.append(f"  sampling {header.get('years')} seed {header.get('seed')}: {header.get('sampling')}")

    lines.append("\n== Served, by client")
    for client in CLIENTS:
        probed = [row for row in rows if client in (row.get("probes") or {})]
        hits = sum(served(row["probes"][client]) for row in probed)
        lines.append(f"  {client:16s} {_share(hits, len(probed))}")

    control = browser_control(rows)
    lines.append(f"\n== Browser control: served to an app, not the browser: {len(control)}")
    for doi in control:
        lines.append(f"  {doi}")

    for label, subset in (
        ("every address", rows),
        ("articles Europe PMC does not serve (isOpenAccess != Y)", [r for r in rows if reaches_unpaywall_tier(r)]),
    ):
        lines.append(f"\n== Families for {label}: {len(subset)}")
        for client in APP_CLIENTS:
            table = family_table(subset, client)
            failed = sum(n for (family, _), n in table.items() if family != "served")
            lines.append(f"  [{client}] not obtained: {_share(failed, len(subset))}")
            families: Counter[str] = Counter()
            for (family, _), count in table.items():
                families[family] += count
            for family, count in families.most_common():
                if family == "served":
                    continue
                lines.append(f"    {family:13s} {_share(count, failed)}")
                for (fam, reason), n in sorted(table.items(), key=lambda item: -item[1]):
                    if fam == family:
                        lines.append(f"      {reason:24s} {n}")

    lines.append("\n== What the app can see: the desktop's failures, by whether it was shown a challenge")
    for label, signal in signal_table(rows, "desktop").items():
        total = sum(signal.values())
        lines.append(f"  {label}: {total}")
        for verdict, count in signal.most_common():
            lines.append(f"    {verdict:40s} {_share(count, total)}")

    lines.append("\n== Desktop served, by Unpaywall host type")
    by_type: dict[str, list[bool]] = defaultdict(list)
    for row in rows:
        by_type[str((row.get("unpaywall") or {}).get("host_type"))].append(
            served((row.get("probes") or {}).get("desktop"))
        )
    for host_type, hits in sorted(by_type.items()):
        lines.append(f"  {host_type:12s} {_share(sum(hits), len(hits))}")
    unobtained = [r for r in rows if classify(r, "desktop").family != "served"]
    others = sum(1 for r in unobtained if ((r.get("unpaywall") or {}).get("pdf_locations") or 0) > 1)
    lines.append(
        f"  desktop failures with another PDF location (tried by the desktop only, not probed): "
        f"{_share(others, len(unobtained))}"
    )

    lines.append("\n== Desktop failures by host (top 20)")
    by_host: dict[str, Counter[str]] = defaultdict(Counter)
    for row in rows:
        verdict = classify(row, "desktop")
        if verdict.family != "served":
            by_host[host_of(row)][f"{verdict.family}/{verdict.reason}"] += 1
    for host, counts in sorted(by_host.items(), key=lambda item: -sum(item[1].values()))[:20]:
        lines.append(f"  {sum(counts.values()):4d}  {host:40s} {dict(counts.most_common())}")

    lines.append("\n== Desktop outcome x browser outcome")
    pairs = Counter(
        (outcome(row["probes"].get("desktop")), outcome(row["probes"].get("browser")))
        for row in rows
        if row.get("probes")
    )
    for (ours, theirs), count in pairs.most_common():
        lines.append(f"  {count:4d}  desktop {ours:24s} browser {theirs}")

    lines.append("\n== Defences named in any probe")
    markers: Counter[str] = Counter()
    for row in rows:
        for marker in {m for p in _all_probes(row) for m in probe_markers(p)}:
            markers[marker] += 1
    for marker, count in markers.most_common():
        lines.append(f"  {count:4d}  {marker}")
    return "\n".join(lines)


def _year_range(text: str) -> tuple[int, int]:
    """Parse ``2019-2021`` (or ``2019``) into an inclusive year range.

    Args:
        text: The command-line value.

    Returns:
        First and last year.

    Raises:
        argparse.ArgumentTypeError: If the value is not one or two years.
    """
    try:
        parts = [int(part) for part in text.split("-")]
    except ValueError as error:
        raise argparse.ArgumentTypeError(f"not a year range: {text!r}") from error
    if len(parts) == 1:
        return parts[0], parts[0]
    if len(parts) == 2 and parts[0] <= parts[1]:
        return parts[0], parts[1]
    raise argparse.ArgumentTypeError(f"not a year range: {text!r}")


def main(argv: Sequence[str] | None = None) -> int:
    """Run the survey from the command line.

    Args:
        argv: Arguments, without the program name.

    Returns:
        The exit status.
    """
    parser = argparse.ArgumentParser(description=(__doc__ or "").splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    fetch_cmd = commands.add_parser("fetch", help="sample DOIs and probe the PDFs Unpaywall names")
    fetch_cmd.add_argument("--years", type=_year_range, required=True)
    fetch_cmd.add_argument("--target", type=int, default=100, help="rows per stratum")
    fetch_cmd.add_argument("--seed", type=int, default=1)
    fetch_cmd.add_argument("--out", type=Path, required=True)
    fetch_cmd.add_argument("--no-browser", action="store_true")
    fetch_cmd.add_argument("--strata", nargs="+", choices=sorted(STRATA), default=list(STRATA))
    browse_cmd = commands.add_parser("browse", help="add (or resume) the browser probes")
    browse_cmd.add_argument("sample", type=Path)
    analyse_cmd = commands.add_parser("analyse", help="classify the failures in samples")
    analyse_cmd.add_argument("samples", type=Path, nargs="+")
    args = parser.parse_args(argv)

    if args.command == "fetch":
        fetch_sample(args.years, args.target, args.seed, args.out, not args.no_browser, args.strata)
    elif args.command == "browse":
        browse_sample(args.sample)
    else:
        print(analyse(*load_samples(args.samples)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
