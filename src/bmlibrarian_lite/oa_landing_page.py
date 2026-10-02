# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Which URL an Unpaywall answer offers, and the PDF a landing page declares.

Unpaywall sets a location's ``url`` to ``url_for_pdf`` when it has one and
to the landing page when it does not, so ``url`` is never a PDF that
``url_for_pdf`` did not already name. Treating it as one downloaded an HTML
page as the article (#464). A landing page usually declares its PDF in a
Highwire Press tag, ``<meta name="citation_pdf_url" content="...">``, which
is what :func:`citation_pdf_url` reads.

Pure functions, pinned with the Swift and Android ports by
``doc/cross_platform/fulltext_parity/unpaywall_landing_page.json``.
"""

import html
import re
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any
from urllib.parse import urljoin, urlparse

from .constants import CITATION_PDF_URL_META_NAME, LANDING_PAGE_PDF_SCHEMES

# One ``<meta ...>`` tag. A ``>`` inside a quoted value ends it early, which
# no URL needs: it would be percent-encoded.
_META_TAG = re.compile(r"<meta\b[^>]*>", re.IGNORECASE)

# One attribute: double-quoted, single-quoted or unquoted value.
_ATTRIBUTE = re.compile(
    r"""([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"""
)


@dataclass(frozen=True)
class UnpaywallChoice:
    """What an Unpaywall answer offers the PDF tier.

    At most one is set: a PDF URL is tried as it is, and a landing page is
    read for the PDF it declares only when no location offers a PDF URL.

    Attributes:
        pdf_url: The first location's ``url_for_pdf``, best location first.
        landing_page: The page to read when there is no ``url_for_pdf``.
    """

    pdf_url: str | None = None
    landing_page: str | None = None


def _present(value: Any) -> str | None:
    """Return a string value trimmed, or ``None`` when it names nothing."""
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def _locations(response: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """The answer's locations, best first, skipping any that are not objects."""
    candidates = [response.get("best_oa_location"), *(response.get("oa_locations") or [])]
    return [location for location in candidates if isinstance(location, Mapping)]


def choose_unpaywall_url(response: Mapping[str, Any]) -> UnpaywallChoice:
    """Decide which URL an Unpaywall answer offers.

    The first ``url_for_pdf``, best location first. Failing that, the first
    landing page (``url_for_landing_page``, else ``url``): never a PDF URL
    itself, only a page that may declare one.

    Args:
        response: Unpaywall's decoded JSON answer for one DOI.

    Returns:
        The PDF URL, the landing page, or neither.
    """
    locations = _locations(response)
    for location in locations:
        pdf_url = _present(location.get("url_for_pdf"))
        if pdf_url:
            return UnpaywallChoice(pdf_url=pdf_url)
    for location in locations:
        landing = _present(location.get("url_for_landing_page")) or _present(
            location.get("url")
        )
        if landing:
            return UnpaywallChoice(landing_page=landing)
    return UnpaywallChoice()


def _attributes(tag: str) -> dict[str, str]:
    """A tag's attributes, names lower-cased, values entity-decoded and trimmed."""
    attributes: dict[str, str] = {}
    for match in _ATTRIBUTE.finditer(tag):
        name = match.group(1).lower()
        raw = next(group for group in match.groups()[1:] if group is not None)
        attributes.setdefault(name, html.unescape(raw).strip())
    return attributes


def citation_pdf_url(page_html: str, page_url: str) -> str | None:
    """Return the PDF a landing page declares, or ``None`` when it declares none.

    The first ``<meta name="citation_pdf_url">`` whose content resolves,
    against the page's own URL, to an http(s) URL. Attribute names and the
    tag name are matched without regard to case; ``property=`` is not
    ``name=``.

    Args:
        page_html: The landing page as served.
        page_url: Where it was served from, after redirects: the base a
            relative URL resolves against.

    Returns:
        The absolute PDF URL, or ``None``.
    """
    for tag in _META_TAG.findall(page_html):
        attributes = _attributes(tag)
        if attributes.get("name", "").lower() != CITATION_PDF_URL_META_NAME:
            continue
        content = attributes.get("content", "")
        if not content:
            continue
        resolved = urljoin(page_url, content)
        if urlparse(resolved).scheme.lower() in LANDING_PAGE_PDF_SCHEMES:
            return resolved
    return None
