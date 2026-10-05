# Full Text Through Machine Channels — Stage A Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add PMC's open-data bucket (`pmc-oa-opendata`) as a JATS full-text source on all three platforms, asked when a PMC ID is known and Europe PMC's `fullTextXML` gave no usable text.

**Architecture:** A pure parsing layer (latest metadata key from an S3 listing, `s3://` → `https://`, metadata record), pinned by one shared parity fixture, and a small client returning a typed fetch (served / absent / unreachable), as Europe PMC's `FullTextXmlFetch` does. Each platform's chain gains one tier between Europe PMC XML and Europe PMC's PDF render. The served XML goes through the platform's existing JATS converter. The result names its own source (`pmc_open_data`), and an unreachable bucket can block "no full text" exactly as an unreachable Europe PMC does.

**Tech Stack:** Python 3.12 + `requests` + `xml.etree`; Swift 5.9 + BioMedLit (`URLSession`, `XMLParser`); Kotlin + OkHttp + kotlinx.serialization + `XmlPullParser`; pytest, XCTest, JUnit4 + MockWebServer + MockK.

**Spec:** `docs/superpowers/specs/2026-10-04-fulltext-machine-channels-design.md` (stage A only). Background: `doc/developer/unpaywall_pdf_survey/spikes/README.md`.

## Global Constraints

- Python is the reference; Swift and Kotlin mirror it. A behaviour change touches the shared fixture and all three platforms.
- Bucket base URL `https://pmc-oa-opendata.s3.amazonaws.com`; listing `GET /?list-type=2&prefix=metadata/{PMCID}.`; metadata keys `metadata/{PMCID}.{N}.json`; take the **numerically** highest `N`.
- Listing `KeyCount` 0, or a listing answered 404, means **absent** (an answer, no failure recorded). A 404 on the metadata JSON or the XML, after a listing named it, is **unreachable** with HTTP 404: the bucket's two answers disagree (as Europe PMC's do, #432). Any other non-200 is unreachable with its status. A body that does not parse is `malformed_response`. A blank XML body is `incomplete_response`.
- Service name, verbatim on every platform: **"PMC's open-access collection"**. Source raw value: **`pmc_open_data`**.
- Pacing: the bucket host gets a ceiling of **5.0** requests per second (Python `POLITE_RATE_CEILINGS`; Android `RequestPacer` at 200 ms; Swift has no per-host pacing in its full-text chain today, so it adds a 200 ms minimum interval between bucket requests inside the bucket fetch).
- XML only. A record without `xml_url` counts as an answer ("no XML"): the chain goes on, nothing is recorded. (The spec's PDF fallback is deferred: 24 of 24 sampled records carry XML; see "Deviation" below.)
- A preprint (`PPR…`, no PMC ID) never asks the bucket.
- No truncation of the served XML (golden rule 13). No new dependency on any platform.
- Docstrings: Google style (Python), `///` (Swift), KDoc (Kotlin). No magic numbers: constants go in `constants.py`, `BioMedLitConstants`, `Constants.kt`.
- Commits end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. No GitHub closing keyword before an issue number that stays open.

**Deviation from the spec (to confirm with the maintainer at review):** the spec's stage A downloads the bucket's PDF when a record has no XML. A sample of 24 records from the spike all carried `xml_url`, so this plan leaves the PDF branch out (YAGNI); a record without XML is recorded as an answer and the chain continues to the PDF tiers that already exist.

## Review Focus

1. **Version numbers compare as numbers.** A listing holding `.1`, `.2` and `.10` must pick `.10`, not `.2` (a lexicographic sort picks `.2`). Pinned by the fixture row "multiple versions, numeric not lexical" (Task 1) and read by every platform's contract test.
2. **A key for a longer PMC ID in the listing is not this article's.** `metadata/PMC1234.1.json` in a listing for `PMC123` must be ignored. Fixture row "longer PMC ID in listing" (Task 1).
3. **A stub that answers every URL with the same body must read as a miss, not a crash.** Swift tests serve JATS XML or a 404 to every URL (`StubURLProtocol.stubbed`); a JATS body where a listing is expected must become `malformed_response` (unreachable), and a 404 listing absent, without changing the outcome those tests assert. Pinned in Task 6 by running the whole BioMedLit suite and by `testACatchAllStubLeavesTheEuropePMCOutcomeAlone`.
4. **An unreachable bucket must not let the chain claim "no full text".** If Europe PMC answered (absent) and the bucket could not be read, the result is "not established", naming the bucket. Python: Task 3 `test_an_unreachable_bucket_unmakes_an_absence`; Swift: Task 6; Kotlin: Task 9.
5. **No test reaches the real bucket.** Existing discoverer tests that pass a PMC ID would now ask the bucket. Task 3 injects the client and Task 10 runs the suite behind a dead proxy.

---

## File Structure

| File | Responsibility |
|---|---|
| `doc/cross_platform/fulltext_parity/pmc_open_data.json` (new) | Shared contract: listing → key, `s3://` → `https://`, record fields, status → outcome, the not-established sentences |
| `src/bmlibrarian_lite/pmc_open_data.py` (new) | Python pure helpers + `PmcOpenDataFetch` + `PmcOpenDataClient` |
| `src/bmlibrarian_lite/constants.py` | Base URL, host ceiling, service name, timeout, retries, source priority |
| `src/bmlibrarian_lite/fulltext_discovery.py` | `FulltextSourceType.PMC_OPEN_DATA_XML`, `_try_pmc_open_data`, injection |
| `src/bmlibrarian_lite/gui/document_interrogation_tab.py` | Source label |
| `tests/test_pmc_open_data.py` (new) | Contract rows, client against a scripted loopback server |
| `tests/test_pmc_open_data_discovery.py` (new) | The tier inside `FulltextDiscoverer` |
| `Packages/BioMedLit/Sources/BioMedLit/Services/PMCOpenData.swift` (new) | Swift pure helpers + `PMCOpenDataFetch` |
| `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift` | The tier, the bucket fetch |
| `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift` | `.pmcOpenData` source/content, `.pmcOpenDataNotEstablished` error |
| `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift` | Bucket constants |
| `Packages/BioMedLit/Tests/BioMedLitTests/PMCOpenDataContractTests.swift`, `FullTextServicePMCOpenDataTests.swift` (new) | Swift tests |
| `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift`, `Utilities/BioMedLitAdapters.swift`, `macOS/MacConstants.swift`, `Views/Components/FullTextSourceBadge.swift` | App source case |
| `android/.../data/remote/fulltext/PmcOpenData.kt` (new) | Kotlin pure helpers + `PmcOpenDataFetch` + `PmcOpenDataService` |
| `android/.../data/remote/fulltext/FullTextService.kt`, `FullTextRecording.kt`, `ui/fulltext/FullTextViewModel.kt`, `di/NetworkModule.kt`, `util/Constants.kt` | Tier, result case, wiring |
| `android/.../test/.../fulltext/PmcOpenDataContractTest.kt`, `PmcOpenDataServiceTest.kt`, `FullTextServicePmcOpenDataTest.kt` (new) | Kotlin tests |
| `doc/cross_platform/fulltext_retrieval.md`, `doc/cross_platform/polite_request_pacing.md` | Contract and pacing table |

Android paths below abbreviate `android/MedicalFactChecker/app/src/main/java/com/bmlibrarian/factchecker/` as `MAIN/` and the matching test root as `TEST/`.

---

### Task 1: The shared contract and Python's pure helpers

**Files:**
- Create: `doc/cross_platform/fulltext_parity/pmc_open_data.json`
- Create: `src/bmlibrarian_lite/pmc_open_data.py`
- Modify: `src/bmlibrarian_lite/constants.py` (near `SERVICE_EUROPE_PMC`, line ~1058, and `POLITE_RATE_CEILINGS`, line ~930)
- Test: `tests/test_pmc_open_data.py`

**Interfaces:**
- Produces: `latest_metadata_key(listing_xml: str, pmcid: str) -> str | None` (raises `ValueError` on a body that is not an S3 listing); `https_url(s3_url: str) -> str | None`; `PmcOpenDataRecord` (frozen dataclass: `xml_url: str | None`, `is_open_access: bool | None`, `is_manuscript: bool | None`, `license_code: str | None`) with `PmcOpenDataRecord.from_metadata(obj: object) -> PmcOpenDataRecord` (raises `ValueError` when `obj` is not a JSON object); constants `PMC_OPEN_DATA_BASE_URL`, `PMC_OPEN_DATA_HOST`, `SERVICE_PMC_OPEN_DATA`, `FULLTEXT_SOURCE_PMC_OPEN_DATA = "pmc_open_data"`.

- [ ] **Step 1: Write the contract fixture**

Create `doc/cross_platform/fulltext_parity/pmc_open_data.json`:

```json
{
  "schema_version": 1,
  "description": "PMC's open-data bucket (pmc-oa-opendata) as a JATS source: which metadata key a listing names, how an s3:// URL becomes an https:// one, what a metadata record says, which statuses settle what, and the sentence an unreachable bucket earns in the apps. Read by tests/test_pmc_open_data.py, Packages/BioMedLit PMCOpenDataContractTests and Android PmcOpenDataContractTest. The rules are in doc/cross_platform/fulltext_retrieval.md, 'PMC's open-data bucket'.",
  "service_name": "PMC's open-access collection",
  "source": "pmc_open_data",
  "base_url": "https://pmc-oa-opendata.s3.amazonaws.com",
  "latest_metadata_key": [
    {
      "name": "one version",
      "pmcid": "PMC10358571",
      "listing": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>pmc-oa-opendata</Name><Prefix>metadata/PMC10358571.</Prefix><KeyCount>1</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated><Contents><Key>metadata/PMC10358571.1.json</Key><Size>900</Size></Contents></ListBucketResult>",
      "key": "metadata/PMC10358571.1.json"
    },
    {
      "name": "multiple versions, numeric not lexical",
      "pmcid": "PMC77",
      "listing": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>pmc-oa-opendata</Name><Prefix>metadata/PMC77.</Prefix><KeyCount>3</KeyCount><Contents><Key>metadata/PMC77.1.json</Key></Contents><Contents><Key>metadata/PMC77.10.json</Key></Contents><Contents><Key>metadata/PMC77.2.json</Key></Contents></ListBucketResult>",
      "key": "metadata/PMC77.10.json"
    },
    {
      "name": "no keys: not in the collection",
      "pmcid": "PMC99999999",
      "listing": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><Name>pmc-oa-opendata</Name><Prefix>metadata/PMC99999999.</Prefix><KeyCount>0</KeyCount><MaxKeys>1000</MaxKeys><IsTruncated>false</IsTruncated></ListBucketResult>",
      "key": null
    },
    {
      "name": "longer PMC ID in listing",
      "pmcid": "PMC123",
      "listing": "<?xml version=\"1.0\" encoding=\"UTF-8\"?><ListBucketResult xmlns=\"http://s3.amazonaws.com/doc/2006-03-01/\"><KeyCount>2</KeyCount><Contents><Key>metadata/PMC1234.1.json</Key></Contents><Contents><Key>metadata/PMC123.x.json</Key></Contents></ListBucketResult>",
      "key": null
    },
    {
      "name": "a JATS article where a listing should be",
      "pmcid": "PMC1",
      "listing": "<?xml version=\"1.0\"?><article><front><article-meta><title-group><article-title>T</article-title></title-group></article-meta></front></article>",
      "error": "malformed"
    },
    {
      "name": "not XML",
      "pmcid": "PMC1",
      "listing": "{\"not\": \"a listing\"}",
      "error": "malformed"
    }
  ],
  "https_url": [
    {"name": "object with md5 query", "s3_url": "s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml?md5=62ed7fe79a191f5", "https_url": "https://pmc-oa-opendata.s3.amazonaws.com/PMC10358571.1/PMC10358571.1.xml"},
    {"name": "object without query", "s3_url": "s3://pmc-oa-opendata/PMC1.2/PMC1.2.xml", "https_url": "https://pmc-oa-opendata.s3.amazonaws.com/PMC1.2/PMC1.2.xml"},
    {"name": "another bucket", "s3_url": "s3://some-other-bucket/PMC1.1/PMC1.1.xml", "https_url": null},
    {"name": "already https", "s3_url": "https://pmc-oa-opendata.s3.amazonaws.com/PMC1.1/PMC1.1.xml", "https_url": null},
    {"name": "bucket with no key", "s3_url": "s3://pmc-oa-opendata/", "https_url": null},
    {"name": "blank", "s3_url": "", "https_url": null}
  ],
  "record": [
    {
      "name": "open access",
      "metadata": {"pmcid": "PMC8593813", "version": 1, "is_pmc_openaccess": true, "is_manuscript": false, "license_code": "CC BY", "xml_url": "s3://pmc-oa-opendata/PMC8593813.1/PMC8593813.1.xml?md5=62ed", "pdf_url": "s3://pmc-oa-opendata/PMC8593813.1/PMC8593813.1.pdf?md5=7743"},
      "xml_url": "https://pmc-oa-opendata.s3.amazonaws.com/PMC8593813.1/PMC8593813.1.xml",
      "is_open_access": true,
      "is_manuscript": false,
      "license_code": "CC BY"
    },
    {
      "name": "author manuscript",
      "metadata": {"pmcid": "PMC10373475", "version": 1, "is_pmc_openaccess": false, "is_manuscript": true, "license_code": "TDM", "xml_url": "s3://pmc-oa-opendata/PMC10373475.1/PMC10373475.1.xml?md5=d332", "text_url": "s3://pmc-oa-opendata/PMC10373475.1/PMC10373475.1.txt?md5=e804"},
      "xml_url": "https://pmc-oa-opendata.s3.amazonaws.com/PMC10373475.1/PMC10373475.1.xml",
      "is_open_access": false,
      "is_manuscript": true,
      "license_code": "TDM"
    },
    {
      "name": "no XML",
      "metadata": {"pmcid": "PMC5", "version": 1, "is_pmc_openaccess": true, "pdf_url": "s3://pmc-oa-opendata/PMC5.1/PMC5.1.pdf"},
      "xml_url": null,
      "is_open_access": true,
      "is_manuscript": null,
      "license_code": null
    },
    {
      "name": "fields of the wrong type",
      "metadata": {"is_pmc_openaccess": "yes", "is_manuscript": 1, "license_code": 7, "xml_url": 42},
      "xml_url": null,
      "is_open_access": null,
      "is_manuscript": null,
      "license_code": null
    }
  ],
  "status": [
    {"step": "listing", "status": 200, "outcome": "read"},
    {"step": "listing", "status": 404, "outcome": "absent"},
    {"step": "listing", "status": 403, "outcome": "unreachable"},
    {"step": "listing", "status": 429, "outcome": "unreachable"},
    {"step": "listing", "status": 503, "outcome": "unreachable"},
    {"step": "metadata", "status": 200, "outcome": "read"},
    {"step": "metadata", "status": 404, "outcome": "unreachable"},
    {"step": "metadata", "status": 500, "outcome": "unreachable"},
    {"step": "xml", "status": 200, "outcome": "read"},
    {"step": "xml", "status": 404, "outcome": "unreachable"},
    {"step": "xml", "status": 503, "outcome": "unreachable"}
  ],
  "not_established_sentence": [
    {"service": "Europe PMC", "failure": {"kind": "http_status", "status_code": 404}, "sentence": "No source provided this article's full text. Europe PMC (HTTP 404 Not Found) did not serve it, so it may still exist. Try again later."},
    {"service": "PMC's open-access collection", "failure": {"kind": "http_status", "status_code": 403}, "sentence": "No source provided this article's full text. PMC's open-access collection (HTTP 403 Forbidden) did not serve it, so it may still exist. Try again later."},
    {"service": "PMC's open-access collection", "failure": {"kind": "http_status", "status_code": 503}, "sentence": "No source provided this article's full text. PMC's open-access collection could not be asked (HTTP 503 Service Unavailable), so it may still exist. Try again later."},
    {"service": "PMC's open-access collection", "failure": {"kind": "timeout"}, "sentence": "No source provided this article's full text. PMC's open-access collection could not be asked (the request timed out), so it may still exist. Try again later."}
  ]
}
```

- [ ] **Step 2: Write the failing contract tests**

Create `tests/test_pmc_open_data.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PMC's open-data bucket as a JATS source (#480, stage A).

The rows are the shared contract,
``doc/cross_platform/fulltext_parity/pmc_open_data.json``, read by the Swift
and Kotlin ports too. No test here touches the network.
"""

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    FULLTEXT_SOURCE_PMC_OPEN_DATA,
    PMC_OPEN_DATA_BASE_URL,
    SERVICE_PMC_OPEN_DATA,
)
from bmlibrarian_lite.pmc_open_data import (
    PmcOpenDataRecord,
    https_url,
    latest_metadata_key,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "pmc_open_data.json"
    ).read_text(encoding="utf-8")
)


def test_the_names_are_the_contracts() -> None:
    """Service name, source value and base URL, verbatim."""
    assert SERVICE_PMC_OPEN_DATA == CONTRACT["service_name"]
    assert FULLTEXT_SOURCE_PMC_OPEN_DATA == CONTRACT["source"]
    assert PMC_OPEN_DATA_BASE_URL == CONTRACT["base_url"]


@pytest.mark.parametrize(
    "row", CONTRACT["latest_metadata_key"], ids=lambda row: row["name"]
)
def test_latest_metadata_key(row: dict[str, Any]) -> None:
    """The numerically highest version of this PMC ID's record, or none."""
    if "error" in row:
        with pytest.raises(ValueError):
            latest_metadata_key(row["listing"], row["pmcid"])
    else:
        assert latest_metadata_key(row["listing"], row["pmcid"]) == row["key"]


@pytest.mark.parametrize("row", CONTRACT["https_url"], ids=lambda row: row["name"])
def test_https_url(row: dict[str, Any]) -> None:
    """Only this bucket's s3:// URLs map, and the query is dropped."""
    assert https_url(row["s3_url"]) == row["https_url"]


@pytest.mark.parametrize("row", CONTRACT["record"], ids=lambda row: row["name"])
def test_record(row: dict[str, Any]) -> None:
    """What a metadata record says; a field of the wrong type says nothing."""
    record = PmcOpenDataRecord.from_metadata(row["metadata"])

    assert record.xml_url == row["xml_url"]
    assert record.is_open_access == row["is_open_access"]
    assert record.is_manuscript == row["is_manuscript"]
    assert record.license_code == row["license_code"]


@pytest.mark.parametrize("value", [[], "text", 3, None])
def test_a_record_that_is_not_an_object_is_refused(value: object) -> None:
    """Unreadable, not empty: the caller records malformed_response."""
    with pytest.raises(ValueError):
        PmcOpenDataRecord.from_metadata(value)
```

- [ ] **Step 3: Run them to see them fail**

Run: `pytest tests/test_pmc_open_data.py -q`
Expected: collection error, `ModuleNotFoundError: No module named 'bmlibrarian_lite.pmc_open_data'`.

- [ ] **Step 4: Add the constants**

In `src/bmlibrarian_lite/constants.py`, add after `SERVICE_EUROPE_PMC = "Europe PMC"`:

```python
# PMC's open-access and author-manuscript collections, published in a public
# S3 bucket (AWS Open Data). A JATS source asked after Europe PMC's
# fullTextXML: it holds the author manuscripts Europe PMC answers 500 for
# (#432, #480). Named as the reader knows it.
SERVICE_PMC_OPEN_DATA = "PMC's open-access collection"
FULLTEXT_SOURCE_PMC_OPEN_DATA = "pmc_open_data"
PMC_OPEN_DATA_HOST = "pmc-oa-opendata.s3.amazonaws.com"
PMC_OPEN_DATA_BASE_URL = f"https://{PMC_OPEN_DATA_HOST}"
PMC_OPEN_DATA_BUCKET = "pmc-oa-opendata"
PMC_OPEN_DATA_REQUEST_TIMEOUT_SECONDS = 45
PMC_OPEN_DATA_MAX_RETRIES = 3
```

In `POLITE_RATE_CEILINGS`, add the entry (S3 publishes no limit; 5/s is conservative):

```python
    # PMC's open-data bucket on S3 (#480). S3 publishes no per-client limit;
    # three requests per article (listing, metadata, XML) at 5/s.
    "pmc-oa-opendata.s3.amazonaws.com": 5.0,
```

In `FULLTEXT_SOURCE_PRIORITY`, add `"pmc_open_data_xml": 85,  # PMC's open-data bucket (JATS)` after `"europepmc_xml": 90`.

- [ ] **Step 5: Write the pure helpers**

Create `src/bmlibrarian_lite/pmc_open_data.py`:

```python
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
    def from_metadata(cls, obj: object) -> "PmcOpenDataRecord":
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
```

- [ ] **Step 6: Run the tests to see them pass**

Run: `pytest tests/test_pmc_open_data.py -q`
Expected: all pass (≈ 22 tests).

- [ ] **Step 7: Commit**

```bash
git add doc/cross_platform/fulltext_parity/pmc_open_data.json src/bmlibrarian_lite/pmc_open_data.py src/bmlibrarian_lite/constants.py tests/test_pmc_open_data.py
git commit -m "feat(python): PMC open-data bucket contract and pure helpers (#480)"
```

---

### Task 2: Python's bucket client

**Files:**
- Modify: `src/bmlibrarian_lite/pmc_open_data.py`
- Test: `tests/test_pmc_open_data.py` (append)

**Interfaces:**
- Consumes: `latest_metadata_key`, `PmcOpenDataRecord`, constants from Task 1; `mount_politely` (`polite_session.py`), `request_failure_from_exception` (`search_failures.py`), `RequestFailure`, `RequestFailureKind` (`data_models.py`), `pmc_accession` (`europepmc.py`).
- Produces: `PmcOpenDataFetch` (frozen dataclass `xml: str | None`, `failure: RequestFailure | None`; classmethods `served(xml)`, `absent()`, `unreachable(failure)`; property `is_unreachable`); `PmcOpenDataClient(base_url: str = PMC_OPEN_DATA_BASE_URL, max_retries: int = PMC_OPEN_DATA_MAX_RETRIES)` with `fetch_xml(pmcid: str) -> PmcOpenDataFetch`.

- [ ] **Step 1: Write the failing client tests**

Append to `tests/test_pmc_open_data.py`:

```python
from http import HTTPStatus

from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind
from bmlibrarian_lite.pmc_open_data import PmcOpenDataClient, PmcOpenDataFetch
from tests.scripted_http_server import (
    ScriptedAnswer,
    json_answer,
    running,
    status_answer,
    xml_answer,
)

_PMCID = "PMC10358571"
_LISTING = CONTRACT["latest_metadata_key"][0]["listing"]
_KEY_PATH = "/metadata/PMC10358571.1.json"
_XML_PATH = "/PMC10358571.1/PMC10358571.1.xml"
_ARTICLE = "<article><body><p>The study.</p></body></article>"


def _metadata() -> ScriptedAnswer:
    """A record whose XML lives on the scripted server's XML path."""
    return json_answer(
        {
            "pmcid": _PMCID,
            "is_pmc_openaccess": True,
            "xml_url": f"s3://pmc-oa-opendata{_XML_PATH}?md5=abc",
        }
    )


def _client(url: str) -> PmcOpenDataClient:
    """A client on the scripted server, without retries, so tests do not sleep."""
    return PmcOpenDataClient(base_url=url, max_retries=0)


class TestFetchXml:
    """The three steps, each status, and what each settles."""

    def test_served(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Listing, record, XML: the article's text."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [xml_answer(_ARTICLE)]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.served(_ARTICLE)

    def test_not_in_the_collection_is_absent(self) -> None:
        """KeyCount 0 is an answer: nothing recorded."""
        empty = CONTRACT["latest_metadata_key"][2]["listing"]
        with running({"/": [xml_answer(empty)]}) as server:
            fetch = _client(server.url).fetch_xml("PMC99999999")

        assert fetch == PmcOpenDataFetch.absent()

    @pytest.mark.parametrize(
        "row",
        [r for r in CONTRACT["status"] if r["status"] != 200],
        ids=lambda r: f"{r['step']}-{r['status']}",
    )
    def test_each_status_settles_what_the_contract_says(
        self, row: dict[str, Any], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """A listing 404 is absent; every other non-200 is unreachable with its status."""
        script: dict[str, list[ScriptedAnswer]] = {
            "/": [xml_answer(_LISTING)],
            _KEY_PATH: [_metadata()],
            _XML_PATH: [xml_answer(_ARTICLE)],
        }
        path = {"listing": "/", "metadata": _KEY_PATH, "xml": _XML_PATH}[row["step"]]
        script[path] = [status_answer(HTTPStatus(row["status"]))]
        with running(script) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        if row["outcome"] == "absent":
            assert fetch == PmcOpenDataFetch.absent()
        else:
            assert fetch == PmcOpenDataFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])
            )

    def test_a_jats_body_where_a_listing_should_be_is_malformed(self) -> None:
        """A catch-all stub's article reads as an unreadable answer, not a crash."""
        with running({"/": [xml_answer(_ARTICLE)]}) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_record_without_xml_is_absent(self) -> None:
        """No XML named: an answer about this source, the chain goes on."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [json_answer({"is_pmc_openaccess": True})]}
        ) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.absent()

    def test_a_record_that_is_not_json_is_malformed(self) -> None:
        """Unreadable is not absent."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [xml_answer("<not-json/>")]}
        ) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_blank_article_is_incomplete(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An empty answer told us nothing about the article."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [xml_answer("  ")]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
        )

    def test_no_server_is_unreachable(self) -> None:
        """A refused connection is a transport failure, never an absence."""
        fetch = _client("http://127.0.0.1:9").fetch_xml(_PMCID)

        assert fetch.is_unreachable
        assert fetch.failure is not None and fetch.failure.kind is RequestFailureKind.CONNECTION

    @pytest.mark.parametrize("identifier", ["PPR1316954", "10.1/x", "", "PMC"])
    def test_not_a_pmc_id_is_never_asked(self, identifier: str) -> None:
        """A preprint or a DOI has no record in the bucket: no request at all."""
        with running({}) as server:
            fetch = _client(server.url).fetch_xml(identifier)
            assert server.received == []

        assert fetch == PmcOpenDataFetch.absent()

    def test_the_listing_asks_for_this_articles_prefix(self) -> None:
        """The request names exactly ``metadata/{PMCID}.``."""
        empty = CONTRACT["latest_metadata_key"][2]["listing"]
        with running({"/": [xml_answer(empty)]}) as server:
            _client(server.url).fetch_xml("10358571")
            parameters = server.requests_to("/")[0].parameters

        assert parameters == {"list-type": ["2"], "prefix": ["metadata/PMC10358571."]}


class TestFetchInvariants:
    """The typed fetch refuses states that mean two things."""

    def test_served_and_unreachable_at_once_is_refused(self) -> None:
        """Never both."""
        with pytest.raises(ValueError):
            PmcOpenDataFetch(xml="<a/>", failure=RequestFailure(RequestFailureKind.TIMEOUT))

    def test_blank_served_xml_is_refused(self) -> None:
        """A blank text is incomplete, not served."""
        with pytest.raises(ValueError):
            PmcOpenDataFetch.served("   ")
```

Note on `monkeypatch` of `PMC_OPEN_DATA_BASE_URL`: the record's `xml_url` maps through `https_url`, which builds an address on the production host. The tests repoint that module-level name at the scripted server so the XML request reaches it. `fetch_xml` must therefore build the XML address with `https_url` (which reads the module name at call time), not with a cached value.

- [ ] **Step 2: Run them to see them fail**

Run: `pytest tests/test_pmc_open_data.py -q -k "Fetch"`
Expected: `ImportError: cannot import name 'PmcOpenDataClient'`.

- [ ] **Step 3: Implement the fetch type and the client**

Append to `src/bmlibrarian_lite/pmc_open_data.py` (and extend its imports):

```python
import logging

import requests
from urllib3.util.retry import Retry

from .constants import (
    EUROPEPMC_USER_AGENT,
    HTTP_NOT_FOUND,
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
    def served(cls, xml: str) -> "PmcOpenDataFetch":
        """The bucket served the article's JATS."""
        return cls(xml=xml, failure=None)

    @classmethod
    def absent(cls) -> "PmcOpenDataFetch":
        """The bucket holds no XML for this article."""
        return cls(xml=None, failure=None)

    @classmethod
    def unreachable(cls, failure: RequestFailure) -> "PmcOpenDataFetch":
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
            Served XML; absent (no record, a listing 404, or a record naming
            no XML); or unreachable, of its real kind.
        """
        accession = pmc_accession(pmcid) if pmcid else None
        if accession is None:
            return PmcOpenDataFetch.absent()
        try:
            listing = self._get(
                f"{self._base_url}/", **{"list-type": "2", "prefix": f"metadata/{accession}."}
            )
            if listing.status_code == HTTP_NOT_FOUND:
                return PmcOpenDataFetch.absent()
            if listing.status_code != _HTTP_OK:
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.HTTP_STATUS, listing.status_code)
                )
            try:
                key = latest_metadata_key(listing.text, accession)
            except ValueError:
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
                record = PmcOpenDataRecord.from_metadata(metadata.json())
            except ValueError:
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
            if not article.text.strip():
                return PmcOpenDataFetch.unreachable(
                    RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
                )
            return PmcOpenDataFetch.served(article.text)
        except requests.exceptions.RequestException as error:
            failure = request_failure_from_exception(error)
            logger.warning(
                "PMC's open-access collection could not be read for %s (%s).",
                accession,
                failure.describe(),
            )
            return PmcOpenDataFetch.unreachable(failure)
```

`metadata.json()` raises `requests.exceptions.JSONDecodeError`, a subclass of `ValueError`, so it lands in the `except ValueError` branch as `MALFORMED_RESPONSE`. `PmcOpenDataRecord.from_metadata` reads `xml_url` through `https_url`, which reads the module-level `PMC_OPEN_DATA_BASE_URL` at call time: keep the import as `from .constants import PMC_OPEN_DATA_BASE_URL` at module level (as Task 1 wrote it) so the tests' `monkeypatch` of `bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL` takes effect.

- [ ] **Step 4: Run the tests to see them pass**

Run: `pytest tests/test_pmc_open_data.py -q`
Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/pmc_open_data.py tests/test_pmc_open_data.py
git commit -m "feat(python): typed PMC open-data bucket fetch, paced per host (#480)"
```

---

### Task 3: The tier in Python's chain

**Files:**
- Modify: `src/bmlibrarian_lite/fulltext_discovery.py` (`FulltextSourceType` ~line 83; `__init__` ~189; `discover_fulltext` between steps 2 and 2b, ~line 319; new method after `_try_europepmc_xml`)
- Modify: `src/bmlibrarian_lite/gui/document_interrogation_tab.py:940-945`
- Test: `tests/test_pmc_open_data_discovery.py`

**Interfaces:**
- Consumes: `PmcOpenDataClient`, `PmcOpenDataFetch` (Task 2); `SERVICE_PMC_OPEN_DATA` (Task 1); `jats_to_markdown` via `self._europepmc.xml_to_markdown`; `save_fulltext_markdown`; `LookupRecord`, `SourceLookupFailure`.
- Produces: `FulltextSourceType.PMC_OPEN_DATA_XML = "pmc_open_data_xml"`; `FulltextDiscoverer(..., pmc_open_data: PmcOpenDataClient | None = None)`; `FulltextDiscoverer._try_pmc_open_data(doc_dict: dict[str, Any], pmcid: str) -> FulltextResult`.

- [ ] **Step 1: Write the failing tier tests**

Create `tests/test_pmc_open_data_discovery.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PMC's open-data bucket inside the full-text chain (#480, stage A).

The bucket is asked only after Europe PMC's XML gave nothing usable and only
for a PMC ID. Its answer is recorded as Europe PMC's is: served text wins,
an absence adds nothing, and a failure keeps "no full text" from being
established. No test touches the network: the client is a stub.
"""

from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import SERVICE_EUROPE_PMC, SERVICE_PMC_OPEN_DATA
from bmlibrarian_lite.data_models import (
    LookupRecord,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
)
from bmlibrarian_lite.fulltext_discovery import (
    FulltextDiscoverer,
    FulltextResult,
    FulltextSourceType,
)
from bmlibrarian_lite.pmc_open_data import PmcOpenDataFetch

_JATS = (
    "<article><front><article-meta><title-group><article-title>A trial"
    "</article-title></title-group></article-meta></front><body><sec><title>Methods"
    "</title><p>We randomised 40 patients.</p></sec></body></article>"
)
_THROTTLED = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)


class _StubBucket:
    """Answers every fetch the same way and records what was asked."""

    def __init__(self, fetch: PmcOpenDataFetch) -> None:
        self.fetch = fetch
        self.asked: list[str] = []

    def fetch_xml(self, pmcid: str) -> PmcOpenDataFetch:
        self.asked.append(pmcid)
        return self.fetch


def _europepmc_absent() -> FulltextResult:
    """Europe PMC answered and served nothing: no failure recorded."""
    return FulltextResult(success=False, source_type=FulltextSourceType.NOT_ASSESSED)


def _discoverer(
    bucket: _StubBucket, monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> FulltextDiscoverer:
    """A discoverer with Europe PMC absent, empty caches and no PDF stage."""
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.find_existing_fulltext", lambda _d: None)
    monkeypatch.setattr("bmlibrarian_lite.fulltext_discovery.find_existing_pdf", lambda _d: None)
    monkeypatch.setattr(
        "bmlibrarian_lite.fulltext_discovery.save_fulltext_markdown",
        lambda _d, _m: tmp_path / "cached.md",
    )
    discoverer = FulltextDiscoverer(use_browser_fallback=False, pmc_open_data=bucket)  # type: ignore[arg-type]
    discoverer._try_europepmc_xml = lambda *_a, **_k: _europepmc_absent()  # type: ignore[method-assign]
    return discoverer


def test_served_text_is_the_result(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """The bucket's JATS, converted, under its own source."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))

    result = _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(
        pmcid="PMC123", skip_pdf=True
    )

    assert result.success
    assert result.source_type is FulltextSourceType.PMC_OPEN_DATA_XML
    assert "We randomised 40 patients." in (result.markdown_content or "")
    assert bucket.asked == ["PMC123"]


def test_absent_adds_nothing(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """An answer about this source: no lookup failure recorded."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())

    result = _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(
        pmcid="PMC123", skip_pdf=True
    )

    assert not result.success
    assert all(f.service != SERVICE_PMC_OPEN_DATA for f in result.lookups.failures)


def test_an_unreachable_bucket_unmakes_an_absence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The control for the rule: a bucket we could not read is recorded."""
    bucket = _StubBucket(PmcOpenDataFetch.unreachable(_THROTTLED))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_pdf_download = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_FOUND
    )

    result = discoverer.discover_fulltext(pmcid="PMC123")

    assert SourceLookupFailure(SERVICE_PMC_OPEN_DATA, _THROTTLED) in result.lookups.failures
    assert not result.absence_established


def test_control_a_clean_chain_still_establishes_an_absence(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Absent bucket, nothing anywhere: the absence stands."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_pdf_download = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False, source_type=FulltextSourceType.NOT_FOUND
    )

    result = discoverer.discover_fulltext(pmcid="PMC123")

    assert result.absence_established


@pytest.mark.parametrize("ids", [{"doi": "10.1/x"}, {"pmid": "123"}])
def test_without_a_pmc_id_the_bucket_is_not_asked(
    ids: dict[str, Any], monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """The bucket files by PMC ID only."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))

    _discoverer(bucket, monkeypatch, tmp_path).discover_fulltext(skip_pdf=True, **ids)

    assert bucket.asked == []


def test_a_pmc_id_europe_pmc_resolved_is_used(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """``_try_europepmc_xml`` writes a resolved PMC ID into ``doc_dict``."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)

    def europepmc_resolving(doc_dict: dict[str, Any], *_a: object) -> FulltextResult:
        doc_dict["pmcid"] = "PMC777"
        return _europepmc_absent()

    discoverer._try_europepmc_xml = europepmc_resolving  # type: ignore[method-assign]
    discoverer.discover_fulltext(doi="10.1/x", skip_pdf=True)

    assert bucket.asked == ["PMC777"]


def test_europe_pmc_served_so_the_bucket_is_not_asked(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Nothing beats Europe PMC's own text; no second request."""
    bucket = _StubBucket(PmcOpenDataFetch.served(_JATS))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=True, source_type=FulltextSourceType.EUROPEPMC_XML, markdown_content="Text."
    )

    discoverer.discover_fulltext(pmcid="PMC123")

    assert bucket.asked == []


def test_unconvertible_xml_is_recorded_not_absent(
    monkeypatch: pytest.MonkeyPatch, tmp_path: Path
) -> None:
    """Our conversion producing nothing is a parse we could not make."""
    bucket = _StubBucket(PmcOpenDataFetch.served("<not-jats/>"))
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    monkeypatch.setattr(discoverer._europepmc, "xml_to_markdown", lambda _x: "")

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert SourceLookupFailure(
        SERVICE_PMC_OPEN_DATA, RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
    ) in result.lookups.failures


def test_europe_pmcs_own_failure_still_travels(monkeypatch: pytest.MonkeyPatch, tmp_path: Path) -> None:
    """Asking the bucket does not drop what Europe PMC left unsettled."""
    bucket = _StubBucket(PmcOpenDataFetch.absent())
    discoverer = _discoverer(bucket, monkeypatch, tmp_path)
    europepmc_failure = SourceLookupFailure(SERVICE_EUROPE_PMC, _THROTTLED)
    discoverer._try_europepmc_xml = lambda *_a, **_k: FulltextResult(  # type: ignore[method-assign]
        success=False,
        source_type=FulltextSourceType.NOT_ASSESSED,
        lookups=LookupRecord(failures=(europepmc_failure,)),
    )

    result = discoverer.discover_fulltext(pmcid="PMC123", skip_pdf=True)

    assert europepmc_failure in result.lookups.failures
```

- [ ] **Step 2: Run them to see them fail**

Run: `pytest tests/test_pmc_open_data_discovery.py -q`
Expected: `TypeError: ... unexpected keyword argument 'pmc_open_data'`.

- [ ] **Step 3: Implement the tier**

In `src/bmlibrarian_lite/fulltext_discovery.py`:

1. Imports: add `from .pmc_open_data import PmcOpenDataClient` and `SERVICE_PMC_OPEN_DATA` to the constants import.
2. In `FulltextSourceType`, after `EUROPEPMC_PDF`:

```python
    PMC_OPEN_DATA_XML = "pmc_open_data_xml"  # PMC's open-data bucket (JATS)
```

3. In `__init__`, add the parameter `pmc_open_data: Optional[PmcOpenDataClient] = None` (document it: "The bucket client; tests pass a stub") and set `self._pmc_open_data = pmc_open_data or PmcOpenDataClient()`.
4. In `discover_fulltext`, directly after the block that returns on `result.success` and the `if self._cancelled: return self._cancelled_result(lookups)` that follows it (before `# 2b.`), insert:

```python
        # 2a. PMC's open-data bucket, by PMC ID (#480). After Europe PMC,
        # whose own text wins; before its PDF render, which answers 403 to
        # every client (#453). ``_try_europepmc_xml`` writes a PMC ID it
        # resolved into ``doc_dict``, so a DOI-only document gets here too.
        bucket_pmcid = doc_dict.get("pmcid") or doc_dict.get("pmc_id")
        if bucket_pmcid:
            self._emit_progress("discovery", "checking_pmc_open_data")
            bucket_result = self._try_pmc_open_data(doc_dict, bucket_pmcid)
            lookups = lookups.merged(bucket_result.lookups)
            if bucket_result.success:
                return bucket_result.with_lookups(result.lookups)
            if self._cancelled:
                return self._cancelled_result(lookups)
```

5. Add the method after `_try_europepmc_xml`:

```python
    def _try_pmc_open_data(
        self, doc_dict: Dict[str, Any], pmcid: str
    ) -> FulltextResult:
        """Try PMC's open-data bucket for the article's JATS (#480).

        Args:
            doc_dict: The document, for the cache path.
            pmcid: The PMC ID to ask by.

        Returns:
            The converted text; or a failed result whose record names the
            bucket when it could not be read or its XML not converted. An
            absence records nothing: it is the bucket's answer about itself.
        """
        fetch = self._pmc_open_data.fetch_xml(pmcid)
        if fetch.failure is not None:
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error=(
                    f"PMC's open-access collection could not be read "
                    f"({fetch.failure.describe()})."
                ),
                lookups=LookupRecord(
                    failures=(SourceLookupFailure(SERVICE_PMC_OPEN_DATA, fetch.failure),)
                ),
            )
        if fetch.xml is None:
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error="PMC's open-access collection holds no text for this article.",
            )
        markdown_content = self._europepmc.xml_to_markdown(fetch.xml)
        if not markdown_content.strip():
            return FulltextResult(
                success=False,
                source_type=FulltextSourceType.NOT_ASSESSED,
                error=(
                    "PMC's open-access collection's text for this article "
                    "could not be converted."
                ),
                lookups=LookupRecord(
                    failures=(
                        SourceLookupFailure(
                            SERVICE_PMC_OPEN_DATA,
                            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE),
                        ),
                    )
                ),
            )
        cache_path: Path | None = None
        try:
            cache_path = save_fulltext_markdown(doc_dict, markdown_content)
        except OSError as e:
            logger.warning("Could not cache the full text of %s: %s", pmcid, e)
        logger.info("Retrieved full text from PMC's open-access collection: %s", pmcid)
        return FulltextResult(
            success=True,
            source_type=FulltextSourceType.PMC_OPEN_DATA_XML,
            markdown_content=markdown_content,
            file_path=cache_path,
        )
```

6. In `src/bmlibrarian_lite/gui/document_interrogation_tab.py`, add to `source_labels`: `"pmc_open_data_xml": "Full Text (PMC open-access collection)",`.
7. Update the `discover_fulltext` docstring's "Tries sources in order" list: insert "3. PMC's open-data bucket, by PMC ID (JATS, converted to markdown)" and renumber.

- [ ] **Step 4: Run the tier tests and the whole suite**

Run: `pytest tests/test_pmc_open_data_discovery.py -q && pytest tests/ -q -p no:cacheprovider`
Expected: all pass. If an existing test now fails because it passed a PMC ID and reached the real `PmcOpenDataClient`, give that test's discoverer `pmc_open_data=_StubBucket(PmcOpenDataFetch.absent())` (copy the stub class into a shared `tests/pmc_open_data_stub.py` if more than one file needs it). Do not change any other assertion.

- [ ] **Step 5: Lint gate**

Run: `python .github/scripts/lint_delta.py --base-ref origin/master`
Expected: `No new ruff or mypy findings.`

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/fulltext_discovery.py src/bmlibrarian_lite/gui/document_interrogation_tab.py tests/test_pmc_open_data_discovery.py tests/
git commit -m "feat(python): ask PMC's open-data bucket after Europe PMC's XML (#480)"
```

---

### Task 4: The contract and pacing docs; Python acceptance

**Files:**
- Modify: `doc/cross_platform/fulltext_retrieval.md` (new section after "Europe PMC Full-Text XML" › "Parsing", before "## Unpaywall PDF", ~line 236; the chain pseudocode under "Fallback Chain Implementation", ~line 700)
- Modify: `doc/cross_platform/polite_request_pacing.md` (the ceilings table, ~lines 83-92)

- [ ] **Step 1: Add the contract section**

Insert before `## Unpaywall PDF`:

````markdown
## PMC's Open-Data Bucket (#480)

PMC publishes its open-access and author-manuscript collections in the public
S3 bucket `pmc-oa-opendata`. Asked **after Europe PMC's `fullTextXML` gave no
usable body, by PMC ID only** (a preprint has none), and before Europe PMC's
PDF render. Service name: **"PMC's open-access collection"**; source
`pmc_open_data`. Pinned by `fulltext_parity/pmc_open_data.json`.

```pseudocode
# SERVED(xml) | ABSENT | UNREACHABLE(failure of its real kind)
function fetch_pmc_open_data(pmcid) -> PmcOpenDataFetch:
    listing = GET {base}/?list-type=2&prefix=metadata/{pmcid}.
    if listing.status == 404: return ABSENT            # an answer
    if listing.status != 200: return UNREACHABLE(http_status)
    key = latest_metadata_key(listing.body, pmcid)     # numeric max of .{N}.json
    if body is not an S3 listing: return UNREACHABLE(malformed_response)
    if key == null: return ABSENT                      # KeyCount 0
    record = GET {base}/{key}                          # 404 here: UNREACHABLE(404)
    xml_url = https_url(record.xml_url)                # s3://pmc-oa-opendata/k?md5= -> https://…/k
    if xml_url == null: return ABSENT                  # no XML named
    xml = GET xml_url                                  # 404: UNREACHABLE(404); blank: incomplete_response
    return SERVED(xml)
```

The served XML goes through the platform's JATS converter, under the same
rules as Europe PMC's (Swift's abstract holdback included). An unreachable
bucket is recorded under its service name, so a chain that then finds nothing
has **not established** an absence; in the apps the sentence names the
bucket (`not_established_sentence` rows). Paced at 5 requests per second.
Only XML is read: a record without `xml_url` is an answer, and the chain goes
on to the PDF tiers.
````

In the "Fallback Chain Implementation" pseudocode, after the Europe PMC XML block (`if accession: …` ending around the `held_abstract` assignment), add:

```pseudocode
    # 2a. PMC's open-data bucket (#480), when a PMC ID is known and step 2 did
    #     not return. Its abstract-only deposit is held back as Europe PMC's is.
    if pmc_id and not returned:
        bucket = await fetch_pmc_open_data(pmc_id)
        if bucket is SERVED: (same parse and holdback as step 2, source pmc_open_data)
        if bucket is UNREACHABLE and europe_pmc_shortfall == null:
            pmc_open_data_shortfall = bucket.failure   # blocks "no full text"
```

- [ ] **Step 2: Add the pacing row**

In `polite_request_pacing.md`'s ceilings table add: `| pmc-oa-opendata.s3.amazonaws.com | 5/s | S3 publishes no per-client limit; conservative (#480) |`.

- [ ] **Step 3: Python acceptance (manual, live, paced)**

Replay the spike's 28 author-manuscript failures through the real client and count served texts:

```bash
python - <<'EOF'
import json
from bmlibrarian_lite.pmc_open_data import PmcOpenDataClient
from bmlibrarian_lite.jats_markdown import jats_to_markdown
rows = [json.loads(l) for l in open("doc/developer/unpaywall_pdf_survey/spikes/2026-10-04-channels.jsonl")]
targets = [r["pmcid"] for r in rows if r["stratum"] == "epmc-not-oa" and r["pmc_aws"].get("outcome") == "no-pdf-text"]
client, served = PmcOpenDataClient(), 0
for pmcid in targets:
    fetch = client.fetch_xml(pmcid)
    served += bool(fetch.xml and jats_to_markdown(fetch.xml).strip())
print(f"{served} of {len(targets)} served and converted")
EOF
```

Expected: `28 of 28 served and converted` (at least 28 is the spec's bar). Record the line in the PR description.

- [ ] **Step 4: Commit**

```bash
git add doc/cross_platform/fulltext_retrieval.md doc/cross_platform/polite_request_pacing.md
git commit -m "docs(contract): PMC's open-data bucket as a full-text source (#480)"
```

---

### Task 5: Swift pure helpers and contract tests

**Files:**
- Create: `Packages/BioMedLit/Sources/BioMedLit/Services/PMCOpenData.swift`
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift` (near `europePMCBaseURL`, line 24)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/PMCOpenDataContractTests.swift`

**Interfaces:**
- Produces: `enum PMCOpenData` with `static func latestMetadataKey(listing: Data, pmcid: String) throws -> String?` (throws `PMCOpenData.ListingError.notAListing`), `static func httpsURL(_ s3URL: String) -> URL?`, `struct PMCOpenDataRecord: Equatable { xmlURL: URL?; isOpenAccess: Bool?; isManuscript: Bool?; licenseCode: String? }` with `init(metadata: Data) throws`; `BioMedLitConstants.pmcOpenDataBaseURL`, `pmcOpenDataBucket`, `pmcOpenDataServiceName`, `pmcOpenDataMinimumInterval`.

- [ ] **Step 1: Constants**

In `BioMedLitConstants` add:

```swift
    /// PMC's open-access and author-manuscript collections, a public S3
    /// bucket asked after Europe PMC's `fullTextXML` (#480). Pinned by
    /// `fulltext_parity/pmc_open_data.json`.
    public static let pmcOpenDataBaseURL = "https://pmc-oa-opendata.s3.amazonaws.com"
    public static let pmcOpenDataBucket = "pmc-oa-opendata"
    /// The bucket as the reader knows it, verbatim on every platform.
    public static let pmcOpenDataServiceName = "PMC's open-access collection"
    /// Five requests per second, Python's `POLITE_RATE_CEILINGS` entry.
    public static let pmcOpenDataMinimumInterval: TimeInterval = 0.2
```

- [ ] **Step 2: Write the failing contract tests**

Create `PMCOpenDataContractTests.swift`, locating the fixture as `UnpaywallLandingPageContractTests.swift:34` does (walk up from `#filePath` to the directory holding `.git`):

```swift
import XCTest
@testable import BioMedLit

/// PMC's open-data bucket helpers against the shared contract (#480).
final class PMCOpenDataContractTests: XCTestCase {
    private static let contractFile: URL? = {
        var directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while true {
            let candidate = directory.appendingPathComponent(
                "doc/cross_platform/fulltext_parity/pmc_open_data.json")
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return nil
            }
            let parent = directory.deletingLastPathComponent()
            if parent == directory { return nil }
            directory = parent
        }
    }()

    private func contract() throws -> [String: Any] {
        let url = try XCTUnwrap(Self.contractFile, "pmc_open_data.json not found")
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
    }

    func testTheNamesAreTheContracts() throws {
        let c = try contract()
        XCTAssertEqual(BioMedLitConstants.pmcOpenDataServiceName, c["service_name"] as? String)
        XCTAssertEqual(FullTextSource.pmcOpenData.rawValue, c["source"] as? String)
        XCTAssertEqual(BioMedLitConstants.pmcOpenDataBaseURL, c["base_url"] as? String)
    }

    func testLatestMetadataKey() throws {
        for row in try XCTUnwrap(contract()["latest_metadata_key"] as? [[String: Any]]) {
            let name = row["name"] as? String ?? "?"
            let listing = Data((row["listing"] as? String ?? "").utf8)
            let pmcid = row["pmcid"] as? String ?? ""
            if row["error"] != nil {
                XCTAssertThrowsError(
                    try PMCOpenData.latestMetadataKey(listing: listing, pmcid: pmcid), name)
            } else {
                XCTAssertEqual(
                    try PMCOpenData.latestMetadataKey(listing: listing, pmcid: pmcid),
                    row["key"] as? String, name)
            }
        }
    }

    func testHTTPSURL() throws {
        for row in try XCTUnwrap(contract()["https_url"] as? [[String: Any]]) {
            XCTAssertEqual(
                PMCOpenData.httpsURL(row["s3_url"] as? String ?? "")?.absoluteString,
                row["https_url"] as? String, row["name"] as? String ?? "?")
        }
    }

    func testRecord() throws {
        for row in try XCTUnwrap(contract()["record"] as? [[String: Any]]) {
            let name = row["name"] as? String ?? "?"
            let metadata = try JSONSerialization.data(withJSONObject: row["metadata"] as Any)
            let record = try PMCOpenDataRecord(metadata: metadata)
            XCTAssertEqual(record.xmlURL?.absoluteString, row["xml_url"] as? String, name)
            XCTAssertEqual(record.isOpenAccess, row["is_open_access"] as? Bool, name)
            XCTAssertEqual(record.isManuscript, row["is_manuscript"] as? Bool, name)
            XCTAssertEqual(record.licenseCode, row["license_code"] as? String, name)
        }
    }

    func testARecordThatIsNotAnObjectIsRefused() {
        XCTAssertThrowsError(try PMCOpenDataRecord(metadata: Data("[]".utf8)))
        XCTAssertThrowsError(try PMCOpenDataRecord(metadata: Data("not json".utf8)))
    }
}
```

`testTheNamesAreTheContracts` references `FullTextSource.pmcOpenData`, added in Task 6; until then, comment out that one assertion and restore it in Task 6 Step 3.

- [ ] **Step 3: Run them to see them fail**

Run (from `Packages/BioMedLit`): `swiftc -typecheck` is not enough for tests; run `swift test --filter PMCOpenDataContractTests`
Expected: compile error, `cannot find 'PMCOpenData' in scope`. (If `swift test` stalls for minutes with no output, that is the `syspolicyd` hang in the HANDOVER's Verify section: wait it out once, do not start a second build.)

- [ ] **Step 4: Implement the helpers**

Create `PMCOpenData.swift`:

```swift
import Foundation

/// PMC's open-data bucket as a JATS full-text source (#480).
///
/// Pure helpers, pinned with Python and Kotlin by
/// `doc/cross_platform/fulltext_parity/pmc_open_data.json`.
public enum PMCOpenData {
    public enum ListingError: Error, Equatable { case notAListing }

    /// The metadata key of the newest version of `pmcid` an S3 listing names.
    ///
    /// Versions compare as numbers (`.10` beats `.2`); a key for a longer
    /// PMC ID is not this article's.
    ///
    /// - Returns: The key, or `nil` when the listing names no version.
    /// - Throws: `ListingError.notAListing` when the body is not an S3
    ///   `ListBucketResult`: an unreadable answer, never an absence.
    public static func latestMetadataKey(listing: Data, pmcid: String) throws -> String? {
        let reader = ListingReader()
        let parser = XMLParser(data: listing)
        parser.delegate = reader
        guard parser.parse(), reader.rootElement == "ListBucketResult" else {
            throw ListingError.notAListing
        }
        let prefix = "metadata/\(pmcid)."
        let suffix = ".json"
        var best: (version: Int, key: String)?
        for key in reader.keys where key.hasPrefix(prefix) && key.hasSuffix(suffix) {
            let middle = key.dropFirst(prefix.count).dropLast(suffix.count)
            guard !middle.isEmpty, middle.allSatisfy(\.isASCIIDigitCharacter),
                  let version = Int(middle) else { continue }
            if best == nil || version > best!.version { best = (version, key) }
        }
        return best?.key
    }

    /// The public HTTPS address of an object in the bucket, or `nil` for
    /// anything else. The `?md5=` query is dropped.
    public static func httpsURL(_ s3URL: String) -> URL? {
        let prefix = "s3://\(BioMedLitConstants.pmcOpenDataBucket)/"
        guard s3URL.hasPrefix(prefix) else { return nil }
        let key = s3URL.dropFirst(prefix.count).split(separator: "?", maxSplits: 1,
                                                      omittingEmptySubsequences: false).first ?? ""
        guard !key.isEmpty else { return nil }
        return URL(string: "\(BioMedLitConstants.pmcOpenDataBaseURL)/\(key)")
    }

    private final class ListingReader: NSObject, XMLParserDelegate {
        var rootElement: String?
        var keys: [String] = []
        private var inKey = false
        private var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                    qualifiedName: String?, attributes: [String: String] = [:]) {
            if rootElement == nil { rootElement = name }
            if name == "Key" { inKey = true; text = "" }
        }

        func parser(_ parser: XMLParser, foundCharacters string: String) {
            if inKey { text += string }
        }

        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                    qualifiedName: String?) {
            if name == "Key" {
                keys.append(text.trimmingCharacters(in: .whitespacesAndNewlines))
                inKey = false
            }
        }
    }
}

private extension Character {
    var isASCIIDigitCharacter: Bool { isASCII && isNumber }
}

/// What one bucket metadata record says; a field of the wrong type says nothing.
public struct PMCOpenDataRecord: Equatable, Sendable {
    public let xmlURL: URL?
    public let isOpenAccess: Bool?
    public let isManuscript: Bool?
    public let licenseCode: String?

    /// - Throws: `PMCOpenData.ListingError.notAListing` when `metadata` is
    ///   not a JSON object.
    public init(metadata: Data) throws {
        guard let object = (try? JSONSerialization.jsonObject(with: metadata)) as? [String: Any]
        else { throw PMCOpenData.ListingError.notAListing }
        xmlURL = (object["xml_url"] as? String).flatMap(PMCOpenData.httpsURL)
        isOpenAccess = Self.bool(object["is_pmc_openaccess"])
        isManuscript = Self.bool(object["is_manuscript"])
        licenseCode = object["license_code"] as? String
    }

    /// A JSON boolean only: `JSONSerialization` bridges `1` to `true`, which
    /// the contract's "fields of the wrong type" row refuses.
    private static func bool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
```

- [ ] **Step 5: Run the contract tests to see them pass**

Run: `swift test --filter PMCOpenDataContractTests`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit/Sources/BioMedLit/Services/PMCOpenData.swift Packages/BioMedLit/Sources/BioMedLit/Utilities/Constants.swift Packages/BioMedLit/Tests/BioMedLitTests/PMCOpenDataContractTests.swift
git commit -m "feat(swift): PMC open-data bucket helpers against the shared contract (#480)"
```

---

### Task 6: The tier in BioMedLit's chain

**Files:**
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Models/FullTextModels.swift` (`FullTextSource` line 20 + `displayName` 37; `FullTextResult.init` assertions 286-357; `FullTextContent` 402 + `source` 419 + `html`/`markdown`; `FullTextError` 474 + `errorDescription` ~577 + `isRetryable`)
- Modify: `Packages/BioMedLit/Sources/BioMedLit/Services/FullTextService.swift` (chain between line 357 and 359; `exhaustedChainError` 576-641; new `fetchPMCOpenDataXML`)
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/PMCOpenDataContractTests.swift` (restore the `FullTextSource.pmcOpenData` assertion; add the sentence rows)
- Test: `Packages/BioMedLit/Tests/BioMedLitTests/FullTextServicePMCOpenDataTests.swift`

**Interfaces:**
- Consumes: `PMCOpenData`, `PMCOpenDataRecord`, constants (Task 5); `renderEuropePMCXML(_:accession:)`; `StubURLProtocol` (tests).
- Produces: `FullTextSource.pmcOpenData = "pmc_open_data"` (`displayName` "PMC Open-Access Collection"); `FullTextContent.pmcOpenData(html: String, markdown: String)`; `FullTextError.pmcOpenDataNotEstablished(RequestFailure)`; `enum PMCOpenDataFetch: Equatable { case served(ServedXML), absent, unreachable(RequestFailure) }`; `FullTextService.fetchPMCOpenDataXML(pmcid: String) async throws -> PMCOpenDataFetch`; a shared `static func notEstablishedSentence(service: String, failure: RequestFailure) -> String`.

- [ ] **Step 1: Write the failing chain tests**

Create `FullTextServicePMCOpenDataTests.swift` (mirror `stubbedService` at `FullTextServiceParseWarningsTests.swift:147`; routes match by URL substring, longest wins):

```swift
import XCTest
@testable import BioMedLit

/// PMC's open-data bucket inside the chain (#480).
final class FullTextServicePMCOpenDataTests: XCTestCase {
    private let pmcid = "PMC10358571"
    private let fullJATS = """
        <article><front><article-meta><title-group><article-title>A trial</article-title>\
        </title-group></article-meta></front><body><sec><title>Methods</title>\
        <p>We randomised 40 patients.</p></sec></body></article>
        """
    private var listing: Data {
        Data("""
            <?xml version="1.0"?><ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/">\
            <KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents>\
            </ListBucketResult>
            """.utf8)
    }
    private var metadata: Data {
        Data(#"{"xml_url":"s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml?md5=a"}"#.utf8)
    }

    override func setUp() { super.setUp(); StubURLProtocol.reset() }
    override func tearDown() { StubURLProtocol.reset(); super.tearDown() }

    private func service() -> FullTextService {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubURLProtocol.self]
        let session = URLSession(configuration: config)
        return FullTextService(email: "reader@example.org", session: session,
                               europePMCService: EuropePMCService(session: session),
                               europePMCRetry: RetryConfiguration(maxAttempts: 1, initialDelay: 0,
                                                                  maxDelay: 0, backoffMultiplier: 1,
                                                                  jitterFactor: 0))
    }

    private func routeBucket() {
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes["pmc-oa-opendata.s3.amazonaws.com/?list-type"] = (200, listing)
        StubURLProtocol.routes["metadata/PMC10358571.1.json"] = (200, metadata)
        StubURLProtocol.routes["PMC10358571.1/PMC10358571.1.xml"] = (200, Data(fullJATS.utf8))
    }

    func testEuropePMCAbsentThenTheBucketServes() async throws {
        routeBucket()
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "31829877")
        XCTAssertEqual(result.source, .pmcOpenData)
        XCTAssertEqual(result.contentKind, .fulltext)
        XCTAssertTrue(result.content.markdown?.contains("We randomised 40 patients.") ?? false)
    }

    func testABucketAbsenceIsNotAFailure() async throws {
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes["pmc-oa-opendata.s3.amazonaws.com/?list-type"] = (200, Data("""
            <ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>0</KeyCount></ListBucketResult>
            """.utf8))
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "31829877")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            // Europe PMC's 404 is its shortfall; the bucket adds none.
            guard case .absenceNotEstablished = error else { return XCTFail("got \(error)") }
        }
    }

    func testAnUnreachableBucketBlocksNoFullText() async throws {
        routeBucket()
        StubURLProtocol.routes["fullTextXML"] = (404, Data())
        StubURLProtocol.routes["pmc-oa-opendata.s3.amazonaws.com/?list-type"] = (503, Data())
        // Europe PMC's shortfall is set first, so its sentence stands.
        do {
            _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "31829877")
            XCTFail("expected an error")
        } catch let error as FullTextError {
            guard case .absenceNotEstablished = error else { return XCTFail("got \(error)") }
        }
    }

    func testTheBucketsShortfallWhenEuropePMCHadNone() {
        let error = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: .httpStatus(503), openAccessShortfall: nil, articleName: "x")
        guard case .pmcOpenDataNotEstablished(let failure) = error else {
            return XCTFail("got \(error)")
        }
        XCTAssertEqual(failure, .httpStatus(503))
    }

    func testControlNoShortfallsIsNoFullText() {
        let error = FullTextService.exhaustedChainError(
            primarySlot: "1", primaryKind: .pubmed, europePMCShortfall: nil,
            pmcOpenDataShortfall: nil, openAccessShortfall: nil, articleName: "x")
        guard case .noFullTextAvailable = error else { return XCTFail("got \(error)") }
    }

    func testAPreprintNeverAsksTheBucket() async throws {
        StubURLProtocol.stubbed = (404, Data())
        _ = try? await service().fetchFullText(pmcId: "PPR1316954", doi: nil, pmid: "1")
        XCTAssertFalse(StubURLProtocol.requested("pmc-oa-opendata"))
    }

    func testEuropePMCServedSoTheBucketIsNotAsked() async throws {
        StubURLProtocol.routes["fullTextXML"] = (200, Data(fullJATS.utf8))
        _ = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "1")
        XCTAssertFalse(StubURLProtocol.requested("pmc-oa-opendata"))
    }

    func testACatchAllStubLeavesTheEuropePMCOutcomeAlone() async throws {
        // Every URL answers the same body-less JATS, as the abstract-holdback
        // tests do: the listing reads as malformed, never as a crash, and the
        // held Europe PMC abstract is still what comes back.
        let bodyless = """
            <article><front><article-meta><title-group><article-title>T</article-title>\
            </title-group><abstract><p>Abstract only.</p></abstract></article-meta></front></article>
            """
        StubURLProtocol.stubbed = (200, Data(bodyless.utf8))
        let result = try await service().fetchFullText(pmcId: pmcid, doi: nil, pmid: "1")
        XCTAssertEqual(result.source, .europePMC)
        XCTAssertEqual(result.contentKind, .abstract)
    }
}
```

Note: `testAnUnreachableBucketBlocksNoFullText` pins the precedence (Europe PMC's shortfall first, so the reader gets one sentence), and `testTheBucketsShortfallWhenEuropePMCHadNone` pins the bucket's own outcome through `exhaustedChainError` directly, since a stubbed Europe PMC cannot answer "nothing to say" without also setting its shortfall. Check `exhaustedChainError`'s real parameter list (line 576) and `ArticleIdentifierKind`'s cases (`Services/ArticleIdentifierKind.swift`) before running.

Add to `PMCOpenDataContractTests` (and restore the `FullTextSource.pmcOpenData` assertion from Task 5):

```swift
    func testNotEstablishedSentences() throws {
        for row in try XCTUnwrap(contract()["not_established_sentence"] as? [[String: Any]]) {
            let failureObject = try XCTUnwrap(row["failure"] as? [String: Any])
            let kind = try XCTUnwrap(RequestFailureKind(rawValue: failureObject["kind"] as? String ?? ""))
            let failure: RequestFailure = kind == .httpStatus
                ? .httpStatus(failureObject["status_code"] as? Int ?? 0)
                : try XCTUnwrap(RequestFailure.allNonStatusFailures.first { $0.kind == kind })
            XCTAssertEqual(
                FullTextError.notEstablishedSentence(service: row["service"] as? String ?? "",
                                                     failure: failure),
                row["sentence"] as? String)
        }
    }
```

If `RequestFailure` has no `allNonStatusFailures`, build the non-status value with a `switch kind` over the static members (`.timeout`, `.connection`, `.serviceError`, `.malformedResponse`, `.incompleteResponse`, `.requestFailed`) in a private test helper instead.

- [ ] **Step 2: Run them to see them fail**

Run: `swift test --filter "FullTextServicePMCOpenDataTests|PMCOpenDataContractTests"`
Expected: compile errors (`pmcOpenData` not a member, `exhaustedChainError` has no `pmcOpenDataShortfall`).

- [ ] **Step 3: Model changes**

In `FullTextModels.swift`:

```swift
// FullTextSource
    case pmcOpenData = "pmc_open_data"
// displayName
        case .pmcOpenData: return "PMC Open-Access Collection"
// FullTextContent
    case pmcOpenData(html: String, markdown: String)
// FullTextContent.source
        case .pmcOpenData: return .pmcOpenData
// FullTextContent.html / .markdown: match both parsed cases
        case .europePMC(let html, _), .pmcOpenData(let html, _): return html
        case .europePMC(_, let markdown), .pmcOpenData(_, let markdown): return markdown
// FullTextError
    case pmcOpenDataNotEstablished(RequestFailure)
```

Replace the two hard-coded Europe PMC sentences in `errorDescription` with one shared builder, and use it for both cases:

```swift
    /// The not-established sentence, naming the source that left it so.
    /// Pinned by `fulltext_parity/pmc_open_data.json` ("not_established_sentence").
    static func notEstablishedSentence(service: String, failure: RequestFailure) -> String {
        failure.isAnswer
            ? "No source provided this article's full text. \(service) (\(failure.describe())) did not serve it, so it may still exist. Try again later."
            : "No source provided this article's full text. \(service) could not be asked (\(failure.describe())), so it may still exist. Try again later."
    }
// errorDescription
        case .absenceNotEstablished(let failure):
            return Self.notEstablishedSentence(service: "Europe PMC", failure: failure)
        case .pmcOpenDataNotEstablished(let failure):
            return Self.notEstablishedSentence(
                service: BioMedLitConstants.pmcOpenDataServiceName, failure: failure)
// isRetryable
        case .pmcOpenDataNotEstablished: return false
```

Keep the existing comment on the verb (#435/#445) above `notEstablishedSentence`. Update the `FullTextResult.init` assertions that name `.europePMC` so that "parsed JATS" means either source — add near the top of `FullTextResult`:

```swift
    /// Whether the content is parsed JATS (Europe PMC's or PMC's bucket).
    private static func isParsedJATS(_ source: FullTextSource) -> Bool {
        source == .europePMC || source == .pmcOpenData
    }
```

and in each assertion replace `content.source == .europePMC` with `Self.isParsedJATS(content.source)` and `content.source != .europePMC` with `!Self.isParsedJATS(content.source)`.

- [ ] **Step 4: The fetch and the tier**

In `FullTextService.swift` add the fetch type (next to `FullTextXmlFetch` usage, top-level in this file or in `PMCOpenData.swift`):

```swift
/// What asking PMC's open-data bucket for an article's JATS produced (#480).
enum PMCOpenDataFetch: Equatable {
    case served(ServedXML)
    case absent
    case unreachable(RequestFailure)
}
```

and the fetch (modelled on `fetchEuropePMCXML`, line 716):

```swift
    /// Ask PMC's open-data bucket for the newest version of an article's JATS.
    ///
    /// Three paced requests: the listing, the metadata record, the XML. A
    /// listing 404 or no version is `.absent`; a 404 after the listing named
    /// the record is `.unreachable(.httpStatus(404))` (the bucket disagreeing
    /// with itself); a body that does not parse is `.malformedResponse`.
    func fetchPMCOpenDataXML(pmcid: String) async throws -> PMCOpenDataFetch {
        guard let normalized = FullTextAccession.normalized(pmcid),
              normalized.hasPrefix(BioMedLitConstants.pmcAccessionPrefix),
              var listingURL = URLComponents(string: BioMedLitConstants.pmcOpenDataBaseURL + "/")
        else { return .absent }
        listingURL.queryItems = [URLQueryItem(name: "list-type", value: "2"),
                                 URLQueryItem(name: "prefix", value: "metadata/\(normalized).")]
        do {
            guard let url = listingURL.url else { return .absent }
            let (listingStatus, listingBody) = try await bucketGET(url)
            if listingStatus == BioMedLitConstants.httpStatusNotFound { return .absent }
            guard listingStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.forHTTPStatus(listingStatus))
            }
            let key: String?
            do { key = try PMCOpenData.latestMetadataKey(listing: listingBody, pmcid: normalized) }
            catch { return .unreachable(.malformedResponse) }
            guard let key, let recordURL = URL(string: "\(BioMedLitConstants.pmcOpenDataBaseURL)/\(key)")
            else { return .absent }

            let (recordStatus, recordBody) = try await bucketGET(recordURL)
            guard recordStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.forHTTPStatus(recordStatus))
            }
            let record: PMCOpenDataRecord
            do { record = try PMCOpenDataRecord(metadata: recordBody) }
            catch { return .unreachable(.malformedResponse) }
            guard let xmlURL = record.xmlURL else { return .absent }

            let (xmlStatus, xmlBody) = try await bucketGET(xmlURL)
            guard xmlStatus == BioMedLitConstants.httpStatusOK else {
                return .unreachable(.forHTTPStatus(xmlStatus))
            }
            guard let served = ServedXML(xmlBody) else { return .unreachable(.incompleteResponse) }
            return .served(served)
        } catch where error.isCancellation {
            throw CancellationError()
        } catch {
            return .unreachable(SearchTransport.failure(for: error))
        }
    }

    /// One bucket request, paced to `pmcOpenDataMinimumInterval`.
    private func bucketGET(_ url: URL) async throws -> (status: Int, body: Data) {
        if let last = lastBucketRequest {
            let wait = BioMedLitConstants.pmcOpenDataMinimumInterval - Date().timeIntervalSince(last)
            if wait > 0 { try await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
        }
        lastBucketRequest = Date()
        var request = URLRequest(url: url)
        request.timeoutInterval = BioMedLitConstants.defaultRequestTimeout
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw FullTextError.invalidResponse("not HTTP") }
        return (http.statusCode, data)
    }
```

Add the actor property `private var lastBucketRequest: Date?` next to the other stored properties. (`FullTextError.invalidResponse` takes a `String`; it lands in the generic `catch` as `.requestFailed` via `SearchTransport`, which is acceptable for a non-HTTP answer; if you prefer `.malformedResponse`, catch it explicitly before the generic `catch`.)

In `fetchFullText`, declare `var pmcOpenDataShortfall: RequestFailure?` beside `europePMCShortfall`, then insert between the end of the Europe PMC XML block (line 357) and the PDF render comment (line 359):

```swift
        // PMC's open-data bucket (#480), by PMC ID, when Europe PMC's XML gave
        // no body. Its abstract-only deposit is held back as Europe PMC's is.
        if abstractOnly == nil,
           let bucketPMCID = (resolvedPmcId ?? pmcId).flatMap(FullTextAccession.normalized),
           bucketPMCID.hasPrefix(BioMedLitConstants.pmcAccessionPrefix) {
            switch try await fetchPMCOpenDataXML(pmcid: bucketPMCID) {
            case .served(let xml):
                do {
                    let content = try renderEuropePMCXML(xml.data, accession: bucketPMCID)
                    let parsed = FullTextResult(
                        content: .pmcOpenData(html: content.html, markdown: content.markdown),
                        warnings: content.warnings,
                        contentKind: content.contentKind
                    )
                    if content.contentKind == .abstract {
                        abstractOnly = parsed
                    } else {
                        return parsed
                    }
                } catch FullTextError.jatsParseFailure(let parseError) {
                    BioMedLitLib.logger?.error(
                        "PMC's open-access collection's XML for \(bucketPMCID) could not be parsed "
                            + "(\(parseError)); trying the PDF tiers",
                        category: .fullText
                    )
                }
            case .absent:
                break
            case .unreachable(let failure):
                pmcOpenDataShortfall = failure
                BioMedLitLib.logger?.warning(
                    "PMC's open-access collection could not be read for \(bucketPMCID) "
                        + "(\(failure.describe())); trying the PDF tiers",
                    category: .fullText
                )
            }
        }
```

Pass `pmcOpenDataShortfall` to `exhaustedChainError` (add the parameter after `europePMCShortfall:`), and in its body insert after the `europePMCShortfall` check:

```swift
        if let pmcOpenDataShortfall {
            return .pmcOpenDataNotEstablished(pmcOpenDataShortfall)
        }
```

Update every existing caller of `exhaustedChainError` (tests included: `grep -rn "exhaustedChainError(" Packages/BioMedLit`) to pass `pmcOpenDataShortfall: nil`.

Note: `resolvedPmcId` / `pmcId` hold the identifiers the chain already uses; read the surrounding code (lines 207-267) and use whichever variable holds the PMC ID after resolution — the condition must be true for a caller-supplied PMC ID and for one the search resolved.

- [ ] **Step 5: Run the new tests and the whole package**

Run: `swift test --filter "FullTextServicePMCOpenDataTests|PMCOpenDataContractTests"` then `swift test` (from `Packages/BioMedLit`).
Expected: all pass, including every pre-existing test (Review Focus 3).

- [ ] **Step 6: Commit**

```bash
git add Packages/BioMedLit
git commit -m "feat(swift): ask PMC's open-data bucket after Europe PMC's XML (#480)"
```

---

### Task 7: The iOS/macOS app source case

**Files:**
- Modify: `ios/MedicalFactChecker/Sources/Models/FullTextSource.swift` (`AppFullTextSource` line 25; `displayName` 46; `iconName` 58; `canDisplayInApp` 73)
- Modify: `ios/MedicalFactChecker/Sources/Utilities/BioMedLitAdapters.swift` (`content(of:localPDFPath:)` 473; `appSource(of:)` 500)
- Modify: `ios/MedicalFactChecker/Sources/macOS/MacConstants.swift:348`; `ios/MedicalFactChecker/Sources/Views/Components/FullTextSourceBadge.swift:64`

**Interfaces:**
- Consumes: `FullTextContent.pmcOpenData(html:markdown:)`, `FullTextSource.pmcOpenData` (Task 6).
- Produces: `AppFullTextSource.pmcOpenData = "pmc_open_data"`.

- [ ] **Step 1: Add the case and let the compiler find every switch**

In `AppFullTextSource` add `case pmcOpenData = "pmc_open_data"`, then:

```swift
// displayName
        case .pmcOpenData: return "PMC Open-Access Collection"
// iconName — the same symbol Europe PMC uses (read it from the .europePMC arm)
        case .pmcOpenData: return <the .europePMC icon name>
// canDisplayInApp
        case .pmcOpenData: return true
// MacConstants.color(for:) and FullTextSourceBadge.badgeColor: the .europePMC colour
        case .pmcOpenData: return <the .europePMC colour>
```

In `BioMedLitAdapters.content(of:localPDFPath:)` map `.pmcOpenData(let html, let markdown)` to the same app content the `.europePMC` arm builds; in `appSource(of:)` map it to `.pmcOpenData`.

- [ ] **Step 2: Type-check, test, build**

Run (from `ios/MedicalFactChecker`): `swift test`, then `xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`. If `FullTextSourceBadge.swift` is behind `#if os(iOS)`, also run `xcodebuild -scheme MedicalFactChecker -destination 'platform=iOS Simulator,name=iPhone 16' build` (HANDOVER Verify: `swift test` compiles neither platform-guarded file).
Expected: tests pass; both builds succeed.

- [ ] **Step 3: Commit**

```bash
git add ios/MedicalFactChecker/Sources
git commit -m "feat(ios,macos): show PMC's open-access collection as a full-text source (#480)"
```

---

### Task 8: Kotlin helpers and the bucket service

**Files:**
- Create: `MAIN/data/remote/fulltext/PmcOpenData.kt`
- Modify: `MAIN/util/Constants.kt` (near `EUROPE_PMC_BASE_URL`, line 105; `FULLTEXT_SOURCE_*`, line ~295)
- Test: `TEST/data/remote/fulltext/PmcOpenDataContractTest.kt`, `TEST/data/remote/fulltext/PmcOpenDataServiceTest.kt`

**Interfaces:**
- Consumes: `RequestFailure`, `RequestFailureKind` (`MAIN/domain/model/RetrievalShortfall.kt`), `NetworkRetry`, `RetryableStatusException` (`FullTextService.kt:890`), `RequestPacer` (`MAIN/data/remote/transparency/TransparencyHttp.kt:87`), `FullTextAccession`.
- Produces: `object PmcOpenData { fun latestMetadataKey(listing: String, pmcid: String): String? /* throws IllegalArgumentException */; fun httpsUrl(s3Url: String): String? }`; `data class PmcOpenDataRecord(xmlUrl: String?, isOpenAccess: Boolean?, isManuscript: Boolean?, licenseCode: String?)` with `companion fun fromMetadata(json: String): PmcOpenDataRecord`; `sealed interface PmcOpenDataFetch { data class Served(val xml: String); data object Absent; data class Unreachable(val failure: RequestFailure) }`; `@Singleton class PmcOpenDataService @Inject constructor(httpClient: OkHttpClient)` with secondary-constructor seam `(httpClient, baseUrl: String, pacer: RequestPacer)` and `suspend fun fetchXml(pmcid: String): PmcOpenDataFetch`; constants `PMC_OPEN_DATA_BASE_URL`, `PMC_OPEN_DATA_BUCKET`, `PMC_OPEN_DATA_SERVICE_NAME`, `PMC_OPEN_DATA_MIN_INTERVAL_MS = 200L`, `FULLTEXT_SOURCE_PMC_OPEN_DATA = "pmc_open_data"`.

- [ ] **Step 1: Constants**

In `Constants.kt`:

```kotlin
    /** PMC's open-data bucket (#480); pinned by fulltext_parity/pmc_open_data.json. */
    const val PMC_OPEN_DATA_BASE_URL = "https://pmc-oa-opendata.s3.amazonaws.com"
    const val PMC_OPEN_DATA_BUCKET = "pmc-oa-opendata"
    /** The bucket as the reader knows it, verbatim on every platform. */
    const val PMC_OPEN_DATA_SERVICE_NAME = "PMC's open-access collection"
    /** Five requests per second, Python's POLITE_RATE_CEILINGS entry. */
    const val PMC_OPEN_DATA_MIN_INTERVAL_MS = 200L
    const val FULLTEXT_SOURCE_PMC_OPEN_DATA = "pmc_open_data"
```

- [ ] **Step 2: Write the failing contract test**

`PmcOpenDataContractTest.kt` (locate the fixture as `UnpaywallLandingPageContractTest.kt:56-65` does):

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.util.Constants
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonNull
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.booleanOrNull
import kotlinx.serialization.json.contentOrNull
import kotlinx.serialization.json.jsonArray
import kotlinx.serialization.json.jsonObject
import kotlinx.serialization.json.jsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertThrows
import org.junit.Test
import java.io.File

/** PMC's open-data bucket helpers against the shared contract (#480). */
class PmcOpenDataContractTest {
    private fun contractFile(): File {
        var candidate: File? = File("").absoluteFile
        while (candidate != null) {
            val file = File(candidate, "doc/cross_platform/fulltext_parity/pmc_open_data.json")
            if (file.isFile) return file
            candidate = candidate.parentFile
        }
        error("pmc_open_data.json not found")
    }

    private val contract: JsonObject by lazy {
        Json.parseToJsonElement(contractFile().readText()).jsonObject
    }

    private fun JsonObject.text(name: String): String? = this[name]?.takeIf { it !is JsonNull }?.jsonPrimitive?.contentOrNull

    @Test
    fun `the names are the contract's`() {
        assertEquals(contract.text("service_name"), Constants.PMC_OPEN_DATA_SERVICE_NAME)
        assertEquals(contract.text("source"), Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA)
        assertEquals(contract.text("base_url"), Constants.PMC_OPEN_DATA_BASE_URL)
    }

    @Test
    fun `latest metadata key`() {
        contract["latest_metadata_key"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val name = row.text("name")
            if (row.containsKey("error")) {
                assertThrows(name, IllegalArgumentException::class.java) {
                    PmcOpenData.latestMetadataKey(row.text("listing")!!, row.text("pmcid")!!)
                }
            } else {
                assertEquals(name, row.text("key"),
                    PmcOpenData.latestMetadataKey(row.text("listing")!!, row.text("pmcid")!!))
            }
        }
    }

    @Test
    fun `https url`() {
        contract["https_url"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            assertEquals(row.text("name"), row.text("https_url"), PmcOpenData.httpsUrl(row.text("s3_url")!!))
        }
    }

    @Test
    fun record() {
        contract["record"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val record = PmcOpenDataRecord.fromMetadata(row["metadata"].toString())
            val name = row.text("name")
            assertEquals(name, row.text("xml_url"), record.xmlUrl)
            assertEquals(name, row["is_open_access"]?.jsonPrimitive?.booleanOrNull, record.isOpenAccess)
            assertEquals(name, row["is_manuscript"]?.jsonPrimitive?.booleanOrNull, record.isManuscript)
            assertEquals(name, row.text("license_code"), record.licenseCode)
        }
    }

    @Test
    fun `not established sentences`() {
        contract["not_established_sentence"]!!.jsonArray.map { it.jsonObject }.forEach { row ->
            val f = row["failure"]!!.jsonObject
            val kind = RequestFailureKind.fromPersisted(f.text("kind")!!)!!
            val failure = RequestFailure(kind, f["status_code"]?.jsonPrimitive?.contentOrNull?.toInt())
            assertEquals(row.text("sentence"), notEstablishedMessage(row.text("service")!!, failure))
        }
    }
}
```

(Add the imports `com.bmlibrarian.factchecker.domain.model.RequestFailure` and `...RequestFailureKind`. `notEstablishedMessage` is added in Task 9; until then comment out the last test and restore it in Task 9.)

- [ ] **Step 3: Write the failing service tests**

`PmcOpenDataServiceTest.kt` (MockWebServer with a path dispatcher, as `FullTextServiceUnpaywallTest.kt:73-79`):

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import kotlinx.coroutines.runBlocking
import okhttp3.OkHttpClient
import okhttp3.mockwebserver.Dispatcher
import okhttp3.mockwebserver.MockResponse
import okhttp3.mockwebserver.MockWebServer
import okhttp3.mockwebserver.RecordedRequest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class PmcOpenDataServiceTest {
    private lateinit var server: MockWebServer
    private val routes = mutableMapOf<String, MockResponse>()
    private val listing = """<ListBucketResult xmlns="http://s3.amazonaws.com/doc/2006-03-01/"><KeyCount>1</KeyCount><Contents><Key>metadata/PMC10358571.1.json</Key></Contents></ListBucketResult>"""
    private val article = "<article><body><p>The study.</p></body></article>"

    @Before fun setUp() {
        server = MockWebServer()
        server.dispatcher = object : Dispatcher() {
            override fun dispatch(request: RecordedRequest): MockResponse =
                routes[request.requestUrl?.encodedPath ?: ""] ?: MockResponse().setResponseCode(404)
        }
        server.start()
    }

    @After fun tearDown() { server.shutdown() }

    private fun service() = PmcOpenDataService(
        OkHttpClient(), baseUrl = server.url("/").toString().trimEnd('/'), pacer = RequestPacer(0L), maxRetries = 0
    )

    private fun routeAll() {
        routes["/"] = MockResponse().setBody(listing)
        routes["/metadata/PMC10358571.1.json"] = MockResponse().setBody(
            """{"xml_url":"s3://pmc-oa-opendata/PMC10358571.1/PMC10358571.1.xml?md5=a"}""")
        routes["/PMC10358571.1/PMC10358571.1.xml"] = MockResponse().setBody(article)
    }

    @Test fun served() = runBlocking {
        routeAll()
        assertEquals(PmcOpenDataFetch.Served(article), service().fetchXml("PMC10358571"))
    }

    @Test fun `a listing 404 is absent`() = runBlocking {
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PMC10358571"))
    }

    @Test fun `a metadata 404 after the listing named it is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setBody(listing)
        assertEquals(PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(404)), service().fetchXml("PMC10358571"))
    }

    @Test fun `a throttled listing is unreachable`() = runBlocking {
        routes["/"] = MockResponse().setResponseCode(503)
        assertEquals(PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503)), service().fetchXml("PMC10358571"))
    }

    @Test fun `a JATS body where a listing should be is malformed`() = runBlocking {
        routes["/"] = MockResponse().setBody(article)
        assertEquals(PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)),
            service().fetchXml("PMC10358571"))
    }

    @Test fun `a blank article is incomplete`() = runBlocking {
        routeAll()
        routes["/PMC10358571.1/PMC10358571.1.xml"] = MockResponse().setBody("  ")
        assertEquals(PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)),
            service().fetchXml("PMC10358571"))
    }

    @Test fun `a preprint is never asked`() = runBlocking {
        assertEquals(PmcOpenDataFetch.Absent, service().fetchXml("PPR1316954"))
        assertEquals(0, server.requestCount)
    }

    @Test fun `the listing asks for this article's prefix`() = runBlocking {
        service().fetchXml("PMC10358571")
        val url = server.takeRequest().requestUrl!!
        assertEquals("2", url.queryParameter("list-type"))
        assertEquals("metadata/PMC10358571.", url.queryParameter("prefix"))
    }
}
```

The service's `https` XML address comes from `PmcOpenData.httpsUrl`, which builds on the production host; the service therefore rewrites the production base to its own `baseUrl` before requesting (see Step 4: `xmlUrl.replaceFirst(Constants.PMC_OPEN_DATA_BASE_URL, baseUrl)`), which is what makes `served()` reach the mock server.

- [ ] **Step 4: Implement**

Create `PmcOpenData.kt`:

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextAccession
import com.bmlibrarian.factchecker.data.remote.transparency.RequestPacer
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.domain.model.RequestFailureKind
import com.bmlibrarian.factchecker.util.Constants
import com.bmlibrarian.factchecker.util.NetworkRetry
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import kotlinx.serialization.json.Json
import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.booleanOrNull
import okhttp3.HttpUrl.Companion.toHttpUrl
import okhttp3.OkHttpClient
import okhttp3.Request
import org.xmlpull.v1.XmlPullParser
import org.xmlpull.v1.XmlPullParserFactory
import java.io.IOException
import java.io.StringReader
import javax.inject.Inject
import javax.inject.Singleton

/** PMC's open-data bucket as a JATS source (#480); pinned by fulltext_parity/pmc_open_data.json. */
object PmcOpenData {
    /**
     * The metadata key of the newest version of [pmcid] an S3 listing names, or null.
     * Versions compare as numbers; a key for a longer PMC ID is ignored.
     * @throws IllegalArgumentException when the body is not an S3 listing.
     */
    fun latestMetadataKey(listing: String, pmcid: String): String? {
        val keys = mutableListOf<String>()
        var root: String? = null
        try {
            val parser = XmlPullParserFactory.newInstance().apply { isNamespaceAware = true }.newPullParser()
            parser.setInput(StringReader(listing))
            var inKey = false
            while (parser.next() != XmlPullParser.END_DOCUMENT) {
                when (parser.eventType) {
                    XmlPullParser.START_TAG -> {
                        if (root == null) root = parser.name
                        inKey = parser.name == "Key"
                    }
                    XmlPullParser.TEXT -> if (inKey) keys.add(parser.text.trim())
                    XmlPullParser.END_TAG -> inKey = false
                }
            }
        } catch (e: org.xmlpull.v1.XmlPullParserException) {
            throw IllegalArgumentException("not an S3 listing", e)
        }
        require(root == "ListBucketResult") { "not an S3 listing: root $root" }
        val pattern = Regex("metadata/${Regex.escape(pmcid)}\\.(\\d+)\\.json")
        return keys.mapNotNull { key -> pattern.matchEntire(key)?.let { it.groupValues[1].toInt() to key } }
            .maxByOrNull { it.first }?.second
    }

    /** The public HTTPS address of an object in the bucket, or null; the ?md5= query is dropped. */
    fun httpsUrl(s3Url: String): String? {
        val prefix = "s3://${Constants.PMC_OPEN_DATA_BUCKET}/"
        if (!s3Url.startsWith(prefix)) return null
        val key = s3Url.removePrefix(prefix).substringBefore('?')
        return if (key.isEmpty()) null else "${Constants.PMC_OPEN_DATA_BASE_URL}/$key"
    }
}

/** What one bucket metadata record says; a field of the wrong type says nothing. */
data class PmcOpenDataRecord(
    val xmlUrl: String?,
    val isOpenAccess: Boolean?,
    val isManuscript: Boolean?,
    val licenseCode: String?
) {
    companion object {
        /** @throws IllegalArgumentException when [json] is not a JSON object. */
        fun fromMetadata(json: String): PmcOpenDataRecord {
            val obj = runCatching { Json.parseToJsonElement(json) }.getOrNull() as? JsonObject
                ?: throw IllegalArgumentException("a metadata record is a JSON object")
            fun string(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { it.isString }?.content
            fun bool(name: String) = (obj[name] as? JsonPrimitive)?.takeIf { !it.isString }?.booleanOrNull
            return PmcOpenDataRecord(
                xmlUrl = string("xml_url")?.let(PmcOpenData::httpsUrl),
                isOpenAccess = bool("is_pmc_openaccess"),
                isManuscript = bool("is_manuscript"),
                licenseCode = string("license_code")
            )
        }
    }
}

/** What asking the bucket for an article's JATS produced. */
sealed interface PmcOpenDataFetch {
    data class Served(val xml: String) : PmcOpenDataFetch
    data object Absent : PmcOpenDataFetch
    data class Unreachable(val failure: RequestFailure) : PmcOpenDataFetch
}

/** Asks PMC's open-data bucket for an article's JATS, paced to 5 requests a second. */
@Singleton
class PmcOpenDataService(
    private val httpClient: OkHttpClient,
    private val baseUrl: String,
    private val pacer: RequestPacer,
    private val maxRetries: Int
) {
    @Inject constructor(httpClient: OkHttpClient) : this(
        httpClient, Constants.PMC_OPEN_DATA_BASE_URL, RequestPacer(Constants.PMC_OPEN_DATA_MIN_INTERVAL_MS),
        Constants.NETWORK_MAX_RETRIES
    )

    private class Answer(val code: Int, val body: String)

    private suspend fun get(url: String): Answer {
        pacer.awaitTurn()
        val request = Request.Builder().url(url).build()
        return NetworkRetry.withExponentialBackoff(
            maxRetries = maxRetries, shouldRetry = { NetworkRetry.isRetryableException(it) }
        ) {
            withContext(Dispatchers.IO) {
                httpClient.newCall(request).execute().use { response ->
                    if (NetworkRetry.isRetryableStatusCode(response.code)) throw RetryableStatusException(response.code)
                    Answer(response.code, response.body?.string() ?: "")
                }
            }
        }
    }

    /** Ask for the newest version of an article's JATS; see the contract for what each status settles. */
    suspend fun fetchXml(pmcid: String): PmcOpenDataFetch {
        val accession = FullTextAccession.normalized(pmcid)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) } ?: return PmcOpenDataFetch.Absent
        return try {
            val listingUrl = "$baseUrl/".toHttpUrl().newBuilder()
                .addQueryParameter("list-type", "2")
                .addQueryParameter("prefix", "metadata/$accession.")
                .build().toString()
            val listing = get(listingUrl)
            if (listing.code == Constants.HTTP_NOT_FOUND) return PmcOpenDataFetch.Absent
            if (listing.code != HTTP_OK) return PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(listing.code))
            val key = try { PmcOpenData.latestMetadataKey(listing.body, accession) }
                catch (e: IllegalArgumentException) { return malformed() } ?: return PmcOpenDataFetch.Absent

            val record = get("$baseUrl/$key")
            if (record.code != HTTP_OK) return PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(record.code))
            val xmlUrl = try { PmcOpenDataRecord.fromMetadata(record.body).xmlUrl }
                catch (e: IllegalArgumentException) { return malformed() } ?: return PmcOpenDataFetch.Absent

            val xml = get(xmlUrl.replaceFirst(Constants.PMC_OPEN_DATA_BASE_URL, baseUrl))
            if (xml.code != HTTP_OK) return PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(xml.code))
            if (xml.body.isBlank()) return PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE))
            PmcOpenDataFetch.Served(xml.body)
        } catch (e: RetryableStatusException) {
            PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(e.statusCode))
        } catch (e: IOException) {
            PmcOpenDataFetch.Unreachable(RequestFailure.fromException(e))
        }
    }

    private fun malformed() = PmcOpenDataFetch.Unreachable(RequestFailure(RequestFailureKind.MALFORMED_RESPONSE))

    private companion object { const val HTTP_OK = 200 }
}
```

Notes: `RequestPacer` and `RetryableStatusException` must be visible from this package — if `RequestPacer` is `internal` in the same module it already is; `RetryableStatusException` lives in `FullTextService.kt` in the same package. XmlPullParser on the JVM test path uses kxml2 (already a test dependency since PR #405; see HANDOVER "#121"). If `XmlPullParserFactory` cannot instantiate in unit tests, use `android.util.Xml.newPullParser()` in main and keep kxml2 for tests, as `JATSXMLParser.kt` does — read how it creates its parser and copy that.

- [ ] **Step 5: Run the tests**

Run (from `android/MedicalFactChecker`): `./gradlew test --tests '*PmcOpenData*'`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add android/MedicalFactChecker/app/src
git commit -m "feat(android): PMC open-data bucket service against the shared contract (#480)"
```

---

### Task 9: The tier in Android's chain

**Files:**
- Modify: `MAIN/data/remote/fulltext/FullTextService.kt` (constructor 62-68; tier between lines 335 and 337; `FullTextResult` 96-196; `NotEstablished` 191; `absenceNotEstablishedMessage` 904-911; `getSourceConstant` 852-861)
- Modify: `MAIN/data/remote/fulltext/FullTextRecording.kt:84`; `MAIN/ui/fulltext/FullTextViewModel.kt:300`; `MAIN/di/NetworkModule.kt:339-348`
- Modify: tests constructing `FullTextService` (`TEST/.../FullTextServiceEuropePmcTest.kt:61`, `FullTextServiceUnpaywallTest.kt:~101`, `FullTextServicePdfDownloadTest.kt:~65`)
- Test: `TEST/data/remote/fulltext/FullTextServicePmcOpenDataTest.kt`; restore the sentence test in `PmcOpenDataContractTest.kt`

**Interfaces:**
- Consumes: `PmcOpenDataService`, `PmcOpenDataFetch` (Task 8); `parseEuropePmcXml` (private, 392-421).
- Produces: `FullTextResult.PmcOpenDataXml(xml: String, markdown: String, html: String)`; `FullTextResult.NotEstablished(failure: RequestFailure, service: String = EUROPE_PMC_SERVICE_NAME)`; top-level `fun notEstablishedMessage(service: String, failure: RequestFailure): String` (and `absenceNotEstablishedMessage(failure)` kept as `notEstablishedMessage("Europe PMC", failure)`).

- [ ] **Step 1: Write the failing chain tests**

`FullTextServicePmcOpenDataTest.kt` (MockK, as `FullTextServiceEuropePmcTest.kt`):

```kotlin
package com.bmlibrarian.factchecker.data.remote.fulltext

import com.bmlibrarian.factchecker.data.remote.europepmc.EuropePMCService
import com.bmlibrarian.factchecker.data.remote.europepmc.FullTextXmlFetch
import com.bmlibrarian.factchecker.data.remote.unpaywall.UnpaywallApi
import com.bmlibrarian.factchecker.domain.model.RequestFailure
import com.bmlibrarian.factchecker.util.Constants
import io.mockk.coEvery
import io.mockk.coVerify
import io.mockk.mockk
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class FullTextServicePmcOpenDataTest {
    private val europePmc: EuropePMCService = mockk()
    private val bucket: PmcOpenDataService = mockk()
    private val jats = "<article><front><article-meta><title-group><article-title>A trial</article-title></title-group></article-meta></front><body><sec><title>Methods</title><p>We randomised 40 patients.</p></sec></body></article>"

    private fun service() = FullTextService(
        context = mockk(relaxed = true), europePmcService = europePmc,
        unpaywallApi = mockk<UnpaywallApi>(), httpClient = mockk(relaxed = true), pmcOpenData = bucket
    )

    @Test fun `Europe PMC absent, then the bucket serves`() = runBlocking {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Served(jats)
        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()
        assertTrue(result is FullTextResult.PmcOpenDataXml)
        assertTrue((result as FullTextResult.PmcOpenDataXml).markdown.contains("We randomised 40 patients."))
    }

    @Test fun `Europe PMC served, so the bucket is not asked`() = runBlocking {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served(jats)
        service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null)
        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }

    @Test fun `Europe PMC's shortfall comes first`() = runBlocking {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Absent
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503))
        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()
        assertEquals(FullTextResult.NotEstablished(RequestFailure.forHttpStatus(404)), result)
    }

    @Test fun `the bucket's shortfall when Europe PMC had none`() = runBlocking {
        // Europe PMC served XML that would not parse: no shortfall of its own.
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served("<not-jats/>")
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Unreachable(RequestFailure.forHttpStatus(503))
        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()
        assertEquals(
            FullTextResult.NotEstablished(RequestFailure.forHttpStatus(503), Constants.PMC_OPEN_DATA_SERVICE_NAME),
            result
        )
    }

    @Test fun `control: a bucket absence leaves the chain unavailable`() = runBlocking {
        coEvery { europePmc.fetchFullTextXml("PMC1") } returns FullTextXmlFetch.Served("<not-jats/>")
        coEvery { bucket.fetchXml("PMC1") } returns PmcOpenDataFetch.Absent
        val result = service().fetchFullText(pmcId = "PMC1", doi = null, pmid = null).getOrThrow()
        assertTrue(result is FullTextResult.Unavailable)
    }

    @Test fun `a preprint never asks the bucket`() = runBlocking {
        coEvery { europePmc.fetchFullTextXml(any()) } returns FullTextXmlFetch.Absent
        service().fetchFullText(pmcId = "PPR1316954", doi = null, pmid = null)
        coVerify(exactly = 0) { bucket.fetchXml(any()) }
    }
}
```

If `fetchFullText` with a `PPR` passed as `pmcId` does not route that way in practice, construct the preprint case through `resolvePmcIdAndPdfUrl` as the existing preprint tests do (search `FullTextServiceEuropePmcTest.kt` for `PPR`).

- [ ] **Step 2: Run them to see them fail**

Run: `./gradlew test --tests '*FullTextServicePmcOpenData*'`
Expected: compile error (no `pmcOpenData` constructor parameter, no `PmcOpenDataXml`).

- [ ] **Step 3: Implement**

1. Constructor: add `private val pmcOpenData: PmcOpenDataService` as the last parameter; update `NetworkModule.provideFullTextService` to take and pass `pmcOpenDataService: PmcOpenDataService` (Hilt constructs it through its `@Inject` constructor), and the three existing tests to pass `pmcOpenData = mockk(relaxed = true)` — a relaxed mock returns `null`-ish defaults, so instead stub it: `mockk<PmcOpenDataService> { coEvery { fetchXml(any()) } returns PmcOpenDataFetch.Absent }`.
2. `FullTextResult`: add

```kotlin
        /** JATS from PMC's open-data bucket (#480), parsed like Europe PMC's. */
        data class PmcOpenDataXml(val xml: String, val markdown: String, val html: String) : FullTextResult(true)
```

   and change `NotEstablished` to `data class NotEstablished(val failure: RequestFailure, val service: String = Constants.EUROPE_PMC_SERVICE_NAME)` with `val reason get() = notEstablishedMessage(service, failure)`. Add `const val EUROPE_PMC_SERVICE_NAME = "Europe PMC"` to `Constants.kt` if absent.
3. Replace `absenceNotEstablishedMessage` with:

```kotlin
/**
 * The not-established sentence, naming the source that left it so (#480).
 * Pinned by fulltext_parity/pmc_open_data.json ("not_established_sentence");
 * worded as BioMedLit's `FullTextError.notEstablishedSentence`.
 */
fun notEstablishedMessage(service: String, failure: RequestFailure): String =
    if (failure.isAnswer) {
        "No source provided this article's full text. $service (${failure.describe()}) " +
            "did not serve it, so it may still exist. Try again later."
    } else {
        "No source provided this article's full text. $service could not be asked " +
            "(${failure.describe()}), so it may still exist. Try again later."
    }

/** Europe PMC's sentence; kept for existing callers. */
fun absenceNotEstablishedMessage(failure: RequestFailure): String =
    notEstablishedMessage(Constants.EUROPE_PMC_SERVICE_NAME, failure)
```

4. Generalise the parse: rename `parseEuropePmcXml` to `parseJats(xml: String, accession: String): ParsedJats?` returning a small private `data class ParsedJats(val markdown: String, val html: String)`, and build `EuropePmcXml` / `PmcOpenDataXml` at the two call sites. (Keep its error handling unchanged.)
5. The tier, between line 335 and 337, with `var pmcOpenDataShortfall: RequestFailure? = null` declared beside `europePmcShortfall`:

```kotlin
        // PMC's open-data bucket (#480), by PMC ID, when Europe PMC's XML gave no text.
        val bucketPmcId = resolvedPmcId?.let(FullTextAccession::normalized)
            ?.takeIf { it.startsWith(FullTextAccession.PMC_PREFIX) }
        if (bucketPmcId != null) {
            when (val fetch = pmcOpenData.fetchXml(bucketPmcId)) {
                is PmcOpenDataFetch.Served -> parseJats(fetch.xml, bucketPmcId)?.let {
                    return@withContext Result.success(FullTextResult.PmcOpenDataXml(fetch.xml, it.markdown, it.html))
                }
                PmcOpenDataFetch.Absent -> Unit
                is PmcOpenDataFetch.Unreachable -> {
                    Log.w(TAG, "PMC's open-access collection could not be read for $bucketPmcId (${fetch.failure.describe()})")
                    pmcOpenDataShortfall = fetch.failure
                }
            }
        }
```

   and at the NotEstablished site (lines 371-374):

```kotlin
        europePmcShortfall?.let { return@withContext Result.success(FullTextResult.NotEstablished(it)) }
        pmcOpenDataShortfall?.let {
            return@withContext Result.success(
                FullTextResult.NotEstablished(it, Constants.PMC_OPEN_DATA_SERVICE_NAME)
            )
        }
```

6. Exhaustive `when`s: `getSourceConstant` → `is FullTextResult.PmcOpenDataXml -> Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA`; `FullTextRecording.recording` → record it exactly as the `EuropePmcXml` arm does but with `fullTextSource = Constants.FULLTEXT_SOURCE_PMC_OPEN_DATA`; `FullTextViewModel.handleFullTextResult` → the same UI state the `EuropePmcXml` arm builds.
7. Restore the commented-out `not established sentences` test in `PmcOpenDataContractTest.kt`.

- [ ] **Step 4: Run all Android tests**

Run: `./gradlew test`
Expected: all pass (including the UI tests that mock `fetchFullText`).

- [ ] **Step 5: Commit**

```bash
git add android/MedicalFactChecker/app/src
git commit -m "feat(android): ask PMC's open-data bucket after Europe PMC's XML (#480)"
```

---

### Task 10: Verification, HANDOVER and the PR

- [ ] **Step 1: Every suite**

Run: `pytest tests/ -q`, `ruff check .`, `python .github/scripts/lint_delta.py --base-ref origin/master`; `cd Packages/BioMedLit && swift test`; `cd ios/MedicalFactChecker && swift test && xcodebuild -scheme MedicalFactChecker -destination 'platform=macOS' build`; `cd android/MedicalFactChecker && ./gradlew test`.
Expected: 0 failures; no new lint findings; the macOS app builds.

- [ ] **Step 2: No test touches the network (Review Focus 5)**

Run: `HTTPS_PROXY=http://127.0.0.1:9 HTTP_PROXY=http://127.0.0.1:9 NO_PROXY=127.0.0.1,localhost pytest tests/ -q -p no:cacheprovider`
Expected: the same pass count as Step 1. A test that fails only here reaches a live host: stub its bucket client.

- [ ] **Step 3: Mutation check of the Python rules**

Back up `src/bmlibrarian_lite/pmc_open_data.py` with `cp`, then from a Python driver (never `git checkout`; verify the restore byte-for-byte; `PYTHONDONTWRITEBYTECODE=1`; assert a passing baseline first) apply each mutation and run `pytest tests/test_pmc_open_data.py tests/test_pmc_open_data_discovery.py -x -q`:
1. `max(versions)` → `max(versions, key=lambda v: v[1])` (lexical) — must be CAUGHT.
2. `if listing.status_code == HTTP_NOT_FOUND:` → `if False:` — CAUGHT.
3. `if record.xml_url is None:\n                return PmcOpenDataFetch.absent()` → return `unreachable(MALFORMED)` — CAUGHT.
4. In `fulltext_discovery.py` (separate backup), drop `failures=(SourceLookupFailure(SERVICE_PMC_OPEN_DATA, fetch.failure),)` → `failures=()` — CAUGHT.

Expected: all four CAUGHT; file restored and equal to its backup.

- [ ] **Step 4: HANDOVER and PR**

Update `HANDOVER.md`'s in-flight section (stage A landed in this PR; stages B and C next), keep it under 500 lines, then commit, push and open a PR to `master` titled `feat(all): PMC's open-data bucket as a full-text source (#480, stage A)`. The body states the acceptance line from Task 4 Step 3, the deviation (no PDF fallback), and "Refs #480" (no closing keyword: #480 stays open for stages B and C). End it with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
