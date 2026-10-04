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
