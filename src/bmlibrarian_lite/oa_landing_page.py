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
``doc/cross_platform/fulltext_parity/unpaywall_landing_page.json``: the choice,
the tag, the character references in its value, and which error statuses
leave a page unread.
"""

import codecs
import re
from collections.abc import Mapping
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import urljoin, urlparse

from .constants import (
    CITATION_PDF_URL_META_NAME,
    DEFAULT_WEB_PAGE_CHARSET,
    LANDING_PAGE_PDF_SCHEMES,
    UNICODE_MAX_CODE_POINT,
    UNICODE_REPLACEMENT_CHARACTER,
    UNICODE_SURROGATE_FIRST,
    UNICODE_SURROGATE_LAST,
)

# One ``<meta ...>`` tag. A ``>`` inside a quoted value ends it early, which
# no URL needs: it would be percent-encoded.
_META_TAG = re.compile(r"<meta\b[^>]*>", re.IGNORECASE)

# One attribute: double-quoted, single-quoted or unquoted value.
_ATTRIBUTE = re.compile(
    r"""([^\s"'<>/=]+)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"""
)

# One character reference, its ``;`` required: ``&#38;``, ``&#x26;`` or a
# name. Without the ``;`` it is no reference. ``html.unescape`` also decodes
# HTML's legacy names written bare, which turned a URL's ``&param=`` into
# ``¶m=`` and ``&section=`` into ``§ion=``; a browser leaves those alone
# inside an attribute, and so do the apps.
_CHARACTER_REFERENCE = re.compile(r"&(#[xX][0-9a-fA-F]+|#[0-9]+|[A-Za-z][A-Za-z0-9]*);")

# The named references a URL plausibly carries. Any other name is left as
# written, matched with its case: ``&Amp;`` is not ``&amp;``.
_NAMED_REFERENCES: Mapping[str, str] = {
    "amp": "&",
    "lt": "<",
    "gt": ">",
    "quot": '"',
    "apos": "'",
}

# The radixes of a hexadecimal (``&#x26;``) and a decimal (``&#38;``) reference.
_HEX_RADIX = 16
_DECIMAL_RADIX = 10

# A Content-Type's ``charset`` parameter (group 1), quoted or not.
_CHARSET = re.compile(r"""charset\s*=\s*["']?([^\s;"']+)""", re.IGNORECASE)


@dataclass(frozen=True)
class UnpaywallChoice:
    """What an Unpaywall answer offers the PDF tier.

    At most one is set: a PDF URL is tried as it is, and a landing page is
    read for the PDF it declares only when no location offers a PDF URL.

    Attributes:
        pdf_url: The first location's ``url_for_pdf``, best location first.
        landing_page: The page to read when there is no ``url_for_pdf``.
        location: The location ``landing_page`` came from, for the host type,
            version and licence of the PDF it declares. Not part of the
            choice's identity, which is what the contract pins.

    Raises:
        ValueError: If both a PDF URL and a landing page are given.
    """

    pdf_url: str | None = None
    landing_page: str | None = None
    location: Mapping[str, Any] | None = field(
        default=None, compare=False, repr=False
    )

    def __post_init__(self) -> None:
        """Refuse a choice offering both: the landing page is never a PDF URL."""
        if self.pdf_url is not None and self.landing_page is not None:
            raise ValueError("an Unpaywall choice is a PDF URL or a landing page, not both")


def _present(value: Any) -> str | None:
    """Return a string value trimmed, or ``None`` when it names nothing."""
    if not isinstance(value, str):
        return None
    trimmed = value.strip()
    return trimmed or None


def unpaywall_locations(response: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    """The answer's locations, best first, skipping any that are not objects.

    Args:
        response: Unpaywall's decoded JSON answer for one DOI.

    Returns:
        ``best_oa_location``, then each of ``oa_locations``; a ``null`` list
        or entry is skipped rather than raised on.
    """
    candidates = [response.get("best_oa_location"), *(response.get("oa_locations") or [])]
    return [location for location in candidates if isinstance(location, Mapping)]


def location_pdf_url(location: Mapping[str, Any]) -> str | None:
    """A location's ``url_for_pdf``, trimmed; ``None`` when absent or blank.

    The one definition of "this location offers a PDF URL", shared by
    :func:`choose_unpaywall_url` and PDF discovery so the two cannot differ
    about a blank value.

    Args:
        location: One Unpaywall location.

    Returns:
        The PDF URL, or ``None``.
    """
    return _present(location.get("url_for_pdf"))


def unpaywall_pdf_urls(response: Mapping[str, Any]) -> list[str]:
    """Every PDF URL an Unpaywall answer names, best location first.

    The candidates every platform tries (#480, stage B; before it the apps
    tried only the best location's). The desktop's chain reads the locations
    itself (``pdf_discovery``); this is the shared contract's helper, pinned
    against that chain by the tests. A URL named by more
    than one location -- the best location is usually repeated in
    ``oa_locations`` -- is kept once, where it first appears.

    Args:
        response: Unpaywall's decoded JSON answer for one DOI.

    Returns:
        Each location's :func:`location_pdf_url`, in Unpaywall's order,
        without repeats; empty when no location names a PDF.
    """
    urls: list[str] = []
    for location in unpaywall_locations(response):
        url = location_pdf_url(location)
        if url and url not in urls:
            urls.append(url)
    return urls


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
    locations = unpaywall_locations(response)
    for location in locations:
        pdf_url = location_pdf_url(location)
        if pdf_url:
            return UnpaywallChoice(pdf_url=pdf_url)
    for location in locations:
        landing = _present(location.get("url_for_landing_page")) or _present(
            location.get("url")
        )
        if landing:
            return UnpaywallChoice(landing_page=landing, location=location)
    return UnpaywallChoice()


def _numeric_reference(digits: str) -> str:
    """The character a numeric reference names.

    Args:
        digits: What follows ``&#``: decimal digits, or ``x`` and hex digits.

    Returns:
        The character, or U+FFFD for a number that names none: zero, a
        surrogate, or beyond Unicode.
    """
    if digits[:1] in ("x", "X"):
        code_point = int(digits[1:], _HEX_RADIX)
    else:
        code_point = int(digits, _DECIMAL_RADIX)
    if (
        code_point == 0
        or code_point > UNICODE_MAX_CODE_POINT
        or UNICODE_SURROGATE_FIRST <= code_point <= UNICODE_SURROGATE_LAST
    ):
        return UNICODE_REPLACEMENT_CHARACTER
    return chr(code_point)


def decode_character_references(value: str) -> str:
    """Decode the character references in an attribute value.

    Numeric references and the five names in :data:`_NAMED_REFERENCES`, each
    ending in ``;``. An unknown name, or one without its ``;``, is left as
    written, so a URL's bare ``&section=`` survives.

    Args:
        value: The value as written in the page.

    Returns:
        The value with those references decoded.
    """

    def decode(match: re.Match[str]) -> str:
        """The text one matched reference stands for."""
        reference = match.group(1)
        if reference.startswith("#"):
            return _numeric_reference(reference[1:])
        return _NAMED_REFERENCES.get(reference, match.group(0))

    return _CHARACTER_REFERENCE.sub(decode, value)


def _attributes(tag: str) -> dict[str, str]:
    """A tag's attributes, names lower-cased, values decoded and trimmed."""
    attributes: dict[str, str] = {}
    for match in _ATTRIBUTE.finditer(tag):
        name = match.group(1).lower()
        raw = next(group for group in match.groups()[1:] if group is not None)
        attributes.setdefault(name, decode_character_references(raw).strip())
    return attributes


def citation_pdf_url(page_html: str, page_url: str) -> str | None:
    """Return the PDF a landing page declares, or ``None`` when it declares none.

    The first ``<meta name="citation_pdf_url">`` whose content resolves,
    against the page's own URL, to an http(s) URL. Attribute names and the
    tag name are matched without regard to case; ``property=`` is not
    ``name=``. A content that will not parse as a URL is passed over for the
    next tag rather than ending the read.

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
        try:
            resolved = urljoin(page_url, content)
            scheme = urlparse(resolved).scheme
        except ValueError:
            # ``http://[bad/a.pdf``: urllib refuses a malformed IPv6 host
            continue
        if scheme.lower() in LANDING_PAGE_PDF_SCHEMES:
            return resolved
    return None


def landing_page_text(body: bytes, content_type: str) -> str:
    """Decode a landing page's bytes as the apps do.

    By the ``charset`` its Content-Type declares, else as UTF-8. ``requests``
    would read an undeclared ``text/html`` page as ISO-8859-1, which turned a
    UTF-8 page's non-ASCII PDF path into mojibake on the desktop alone.

    Args:
        body: The page's bytes, as read.
        content_type: Its Content-Type header, or ``""``.

    Returns:
        The page as text; bytes the encoding cannot read become U+FFFD.
    """
    match = _CHARSET.search(content_type)
    encoding = DEFAULT_WEB_PAGE_CHARSET
    if match:
        try:
            encoding = codecs.lookup(match.group(1)).name
        except LookupError:
            pass  # A charset Python does not know: read it as UTF-8
    return body.decode(encoding, errors="replace")
