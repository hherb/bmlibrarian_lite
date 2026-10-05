# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PMC's open-data bucket as a JATS full-text source (#480, stage A).

PMC publishes its open-access and author-manuscript collections in the
public S3 bucket ``pmc-oa-opendata``. Each article version has a metadata
record, ``metadata/{PMCID}.{N}.json``, naming its JATS XML. The bucket holds
the author manuscripts that Europe PMC's ``fullTextXML`` answers 500 for, so
it recovers text the chain could not reach before (28 of 149 in the #480
spike). NCBI's older ``oa.fcgi`` service answers 404.

The pure functions here are pinned with the Swift and Kotlin ports by
``doc/cross_platform/fulltext_parity/pmc_open_data.json``.
"""

from __future__ import annotations

import json
import logging
import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass

import requests
from urllib3.util.retry import Retry

from .constants import (
    EUROPEPMC_USER_AGENT,
    PMC_OPEN_DATA_BASE_URL,
    PMC_OPEN_DATA_BUCKET,
    PMC_OPEN_DATA_ENCODING,
    PMC_OPEN_DATA_MAX_RETRIES,
    PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS,
    RETRYABLE_HTTP_STATUSES,
)
from .data_models import RequestFailure, RequestFailureKind
from .europepmc import pmc_accession
from .polite_session import mount_politely
from .search_failures import request_failure_from_exception

logger = logging.getLogger(__name__)
_HTTP_OK = 200

_S3_NAMESPACE = "{http://s3.amazonaws.com/doc/2006-03-01/}"
_LISTING_TAG = f"{_S3_NAMESPACE}ListBucketResult"
_S3_SCHEME = "s3://"


def latest_metadata_key(listing_xml: str, pmcid: str) -> str | None:
    """The metadata key of the newest version of ``pmcid`` an S3 listing names.

    Versions compare as numbers: ``.10`` is newer than ``.2``. A key for any
    other identifier (``PMC1234`` in a listing for ``PMC123``) is not this
    article's and is ignored. A key that is this article's but whose version
    is not ASCII digits is an answer we cannot read: it is ignored beside a
    version we can read, and makes the listing unreadable on its own.

    Args:
        listing_xml: A ``ListObjectsV2`` answer for the prefix
            ``metadata/{pmcid}.``.
        pmcid: The PMC ID, in ``PMC<digits>`` form.

    Returns:
        The key, or ``None`` when the listing names no version of ``pmcid``:
        the article is in neither collection.

    Raises:
        ValueError: If the body is not an S3 listing, or names this article
            only under versions we cannot read. That is an unreadable answer,
            never an absence.
    """
    try:
        root = ET.fromstring(listing_xml)
    except ET.ParseError as error:
        raise ValueError("not an S3 listing") from error
    if root.tag != _LISTING_TAG:
        raise ValueError(f"not an S3 listing: root element {root.tag!r}")
    prefix = f"metadata/{pmcid}."
    # ``[0-9]``, not ``\d``: ``\d`` also matches other scripts' digits,
    # which the Swift and Kotlin ports do not read as a version.
    pattern = re.compile(rf"{re.escape(prefix)}([0-9]+)\.json")
    versions: list[tuple[int, str]] = []
    unreadable = False
    for key in root.iter(f"{_S3_NAMESPACE}Key"):
        text = (key.text or "").strip()
        match = pattern.fullmatch(text)
        if match:
            versions.append((int(match.group(1)), match.group(0)))
        elif text.startswith(prefix):
            unreadable = True
    if versions:
        return max(versions)[1]
    if unreadable:
        raise ValueError(f"the listing names {pmcid} only under versions we cannot read")
    return None


def https_url(s3_url: str) -> str | None:
    """The public HTTPS address of an object in the bucket.

    Args:
        s3_url: A metadata URL such as
            ``s3://pmc-oa-opendata/PMC1.1/PMC1.1.xml?md5=…``.

    Returns:
        ``https://pmc-oa-opendata.s3.amazonaws.com/PMC1.1/PMC1.1.xml``, or
        ``None`` for anything that is not an object in this bucket.
    """
    prefix = f"{_S3_SCHEME}{PMC_OPEN_DATA_BUCKET}/"
    if not s3_url.startswith(prefix):
        return None
    key = s3_url[len(prefix):].split("?", 1)[0]
    return f"{PMC_OPEN_DATA_BASE_URL}/{key}" if key else None


def _bool_or_none(value: object) -> bool | None:
    """A JSON boolean, or ``None`` for anything else."""
    return value if isinstance(value, bool) else None


@dataclass(frozen=True)
class PmcOpenDataRecord:
    """What one metadata record says about an article version.

    Attributes:
        xml_url: The JATS XML's HTTPS address, or ``None`` when the record
            names none.
        is_open_access: Whether PMC lists it as open access; ``None`` when
            the record does not say.
        is_manuscript: Whether it is an author manuscript; ``None`` when the
            record does not say.
        license_code: The licence, for example ``"CC BY"`` or ``"TDM"``.
    """

    xml_url: str | None
    is_open_access: bool | None
    is_manuscript: bool | None
    license_code: str | None

    @classmethod
    def from_metadata(cls, obj: object) -> PmcOpenDataRecord:
        """Read a decoded metadata record.

        A flag of the wrong type says nothing. An ``xml_url`` that is there
        but cannot be read is different: the record named XML and we do not
        know where, so it is an unreadable answer, never "no XML" (#486).

        Args:
            obj: The decoded JSON, untrusted.

        Returns:
            The record; ``xml_url`` is ``None`` only when the record names no
            XML (the key is missing or null).

        Raises:
            ValueError: If ``obj`` is not a JSON object, or its ``xml_url``
                is not an ``s3://`` URL of an object in this bucket.
        """
        if not isinstance(obj, dict):
            raise ValueError("a metadata record is a JSON object")
        xml = obj.get("xml_url")
        xml_url = None
        if xml is not None:
            xml_url = https_url(xml) if isinstance(xml, str) else None
            if xml_url is None:
                raise ValueError("the record's xml_url names nothing in this bucket")
        licence = obj.get("license_code")
        return cls(
            xml_url=xml_url,
            is_open_access=_bool_or_none(obj.get("is_pmc_openaccess")),
            is_manuscript=_bool_or_none(obj.get("is_manuscript")),
            license_code=licence if isinstance(licence, str) else None,
        )


@dataclass(frozen=True)
class PmcOpenDataFetch:
    """What asking the bucket for an article's JATS produced.

    The sibling of ``europepmc.FullTextXmlFetch``. ``absent()`` is the
    bucket's answer that it holds no record (or none naming XML) for the
    article; a failure is an answer we could not get.

    Attributes:
        xml: The JATS XML, when served. Never blank.
        failure: Why it could not be read. ``None`` with no ``xml`` is absent.

    Raises:
        ValueError: On construction, if both are given or the XML is blank.
    """

    xml: str | None
    failure: RequestFailure | None

    def __post_init__(self) -> None:
        """Refuse the states that would mean two things at once."""
        if self.xml is not None and self.failure is not None:
            raise ValueError("A bucket fetch is served or unreachable, never both")
        if self.xml is not None and not self.xml.strip():
            raise ValueError("A blank full text is an incomplete answer, not an absence")

    @classmethod
    def served(cls, xml: str) -> PmcOpenDataFetch:
        """The bucket served the article's JATS."""
        return cls(xml=xml, failure=None)

    @classmethod
    def absent(cls) -> PmcOpenDataFetch:
        """The bucket holds no XML for this article."""
        return cls(xml=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> PmcOpenDataFetch:
        """The bucket's answer is missing, of its real kind."""
        return cls(xml=None, failure=failure)

    @property
    def is_unreachable(self) -> bool:
        """Whether nothing about the article was established."""
        return self.failure is not None


class PmcOpenDataClient:
    """Asks PMC's open-data bucket for an article's JATS, paced per host."""

    def __init__(
        self,
        base_url: str = PMC_OPEN_DATA_BASE_URL,
        max_retries: int = PMC_OPEN_DATA_MAX_RETRIES,
    ) -> None:
        """Create the client.

        Args:
            base_url: The bucket's address; tests point it at a local server.
            max_retries: Retries for a 429 or 5xx; tests pass 0.
        """
        self._base_url = base_url.rstrip("/")
        session = requests.Session()
        session.headers.update({"User-Agent": EUROPEPMC_USER_AGENT})
        retry = Retry(
            total=max_retries,
            backoff_factor=1,
            status_forcelist=list(RETRYABLE_HTTP_STATUSES),
            allowed_methods=["GET"],
            raise_on_status=False,
        )
        self._session = mount_politely(session, retry=retry)

    def _get(self, url: str, **params: str) -> requests.Response:
        """One paced GET."""
        return self._session.get(
            url, params=params or None, timeout=PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS
        )

    def fetch_xml(self, pmcid: str) -> PmcOpenDataFetch:
        """Ask the bucket for the newest version of an article's JATS.

        Args:
            pmcid: A PMC ID, with or without its ``PMC`` prefix. Anything
                else (a preprint, a DOI) is never asked: the bucket files by
                PMC ID only.

        Returns:
            Served XML; absent (a listing naming no version of the article,
            or a record naming no XML); or unreachable, of its real kind.
        """
        accession = pmc_accession(pmcid) if pmcid else None
        if accession is None:
            return PmcOpenDataFetch.absent()
        try:
            listing = self._get(
                f"{self._base_url}/", **{"list-type": "2", "prefix": f"metadata/{accession}."}
            )
            # A missing article is a 200 listing naming no version of it. A
            # listing 404 is S3's NoSuchBucket, or something in between: the
            # source is gone, which says nothing about the article.
            if listing.status_code != _HTTP_OK:
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.HTTP_STATUS, listing.status_code)
                )
            try:
                key = latest_metadata_key(
                    listing.content.decode(PMC_OPEN_DATA_ENCODING), accession
                )
            except ValueError:  # includes UnicodeDecodeError
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                )
            if key is None:
                return PmcOpenDataFetch.absent()

            metadata = self._get(f"{self._base_url}/{key}")
            if metadata.status_code != _HTTP_OK:
                # The listing named it: a 404 here is the bucket disagreeing
                # with itself, recorded as what we got (#432's rule).
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.HTTP_STATUS, metadata.status_code)
                )
            try:
                # Decoded explicitly, as the listing and the XML are:
                # ``.json()`` would guess at a charset S3 does not name.
                record = PmcOpenDataRecord.from_metadata(
                    json.loads(metadata.content.decode(PMC_OPEN_DATA_ENCODING))
                )
            except ValueError:  # includes UnicodeDecodeError, JSONDecodeError
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                )
            if record.xml_url is None:
                return PmcOpenDataFetch.absent()

            article = self._get(record.xml_url)
            if article.status_code != _HTTP_OK:
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.HTTP_STATUS, article.status_code)
                )
            # Decoded explicitly: S3 names no charset, so ``.text`` would guess.
            try:
                text = article.content.decode(PMC_OPEN_DATA_ENCODING)
            except UnicodeDecodeError:
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
                )
            if not text.strip():
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
                )
            return PmcOpenDataFetch.served(text)
        except requests.exceptions.RequestException as error:
            failure = request_failure_from_exception(error)
            logger.warning(
                "PMC's open-access collection could not be read for %s (%s).",
                accession,
                failure.describe(),
            )
            return PmcOpenDataFetch.unreachable(failure)
