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

import re
import xml.etree.ElementTree as ET
from dataclasses import dataclass

from .constants import PMC_OPEN_DATA_BASE_URL, PMC_OPEN_DATA_BUCKET

_S3_NAMESPACE = "{http://s3.amazonaws.com/doc/2006-03-01/}"
_LISTING_TAG = f"{_S3_NAMESPACE}ListBucketResult"
_S3_SCHEME = "s3://"


def latest_metadata_key(listing_xml: str, pmcid: str) -> str | None:
    """The metadata key of the newest version of ``pmcid`` an S3 listing names.

    Versions compare as numbers: ``.10`` is newer than ``.2``. A key for any
    other identifier (``PMC1234`` in a listing for ``PMC123``) is not this
    article's and is ignored.

    Args:
        listing_xml: A ``ListObjectsV2`` answer for the prefix
            ``metadata/{pmcid}.``.
        pmcid: The PMC ID, in ``PMC<digits>`` form.

    Returns:
        The key, or ``None`` when the listing names no version of ``pmcid``:
        the article is in neither collection.

    Raises:
        ValueError: If the body is not an S3 listing. That is an unreadable
            answer, never an absence.
    """
    try:
        root = ET.fromstring(listing_xml)
    except ET.ParseError as error:
        raise ValueError("not an S3 listing") from error
    if root.tag != _LISTING_TAG:
        raise ValueError(f"not an S3 listing: root element {root.tag!r}")
    pattern = re.compile(rf"metadata/{re.escape(pmcid)}\.(\d+)\.json")
    versions: list[tuple[int, str]] = []
    for key in root.iter(f"{_S3_NAMESPACE}Key"):
        match = pattern.fullmatch((key.text or "").strip())
        if match:
            versions.append((int(match.group(1)), match.group(0)))
    return max(versions)[1] if versions else None


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
            names none (or names one outside the bucket).
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
        """Read a decoded metadata record; a field of the wrong type says nothing.

        Args:
            obj: The decoded JSON, untrusted.

        Returns:
            The record.

        Raises:
            ValueError: If ``obj`` is not a JSON object.
        """
        if not isinstance(obj, dict):
            raise ValueError("a metadata record is a JSON object")
        xml = obj.get("xml_url")
        licence = obj.get("license_code")
        return cls(
            xml_url=https_url(xml) if isinstance(xml, str) else None,
            is_open_access=_bool_or_none(obj.get("is_pmc_openaccess")),
            is_manuscript=_bool_or_none(obj.get("is_manuscript")),
            license_code=licence if isinstance(licence, str) else None,
        )
