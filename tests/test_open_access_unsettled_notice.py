# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The sentence for an open-access copy that went unassessed (#466).

When Unpaywall, or the landing page it named, could not answer, Python
records a :class:`SourceLookupFailure` and tells the reader what that leaves
open. The apps tell the reader the same thing beside a document whose full
text ended on a fallback, and they word it exactly as Python does. An
Unpaywall with no usable email is never asked; Python records that as a
:class:`SourceLookupSkipped`, and the apps word it the same way too. The rows
are the shared contract,
``doc/cross_platform/fulltext_parity/open_access_unsettled_notice.json``;
Python reads only its ``sources`` and ``notices`` (the persisted form is the
apps' alone).
"""

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.analysis_failures import unestablished_access_clause
from bmlibrarian_lite.constants import (
    SERVICE_CORE,
    SERVICE_ELSEVIER,
    SERVICE_OPENALEX,
    SERVICE_OPENALEX_PDF,
    SERVICE_UNPAYWALL,
    SERVICE_UNPAYWALL_LANDING_PAGE,
    SERVICE_UNPAYWALL_PDF,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "open_access_unsettled_notice.json"
    ).read_text(encoding="utf-8")
)

#: The contract's source keys, mapped to the service names Python records.
SERVICES = {
    "unpaywall": SERVICE_UNPAYWALL,
    "unpaywall_landing_page": SERVICE_UNPAYWALL_LANDING_PAGE,
    "unpaywall_pdf": SERVICE_UNPAYWALL_PDF,
    "openalex": SERVICE_OPENALEX,
    "openalex_pdf": SERVICE_OPENALEX_PDF,
    "core": SERVICE_CORE,
    "elsevier": SERVICE_ELSEVIER,
}


def test_the_contract_names_the_services_python_records() -> None:
    """Each source key is named in the sentence by Python's own service name."""
    assert CONTRACT["sources"] == SERVICES


def _record(row: dict[str, Any]) -> LookupRecord:
    """The record of the one lookup a contract row names.

    Args:
        row: A row naming a failed lookup by ``kind`` and ``status_code``, or
            one never made by ``skipped``.

    Returns:
        A record holding that one failure or skip.
    """
    service = SERVICES[row["source"]]
    if row.get("skipped") is not None:
        return LookupRecord(
            skipped=(SourceLookupSkipped(service, LookupSkipReason(row["skipped"])),)
        )
    failure = RequestFailure(RequestFailureKind(row["kind"]), row["status_code"])
    return LookupRecord(failures=(SourceLookupFailure(service, failure),))


@pytest.mark.parametrize(
    "row",
    CONTRACT["notices"],
    ids=lambda row: (
        f"{row['source']}-{row.get('skipped') or row['kind']}-{row['status_code']}"
    ),
)
def test_notice_matches_the_contract(row: dict[str, Any]) -> None:
    """One unsettled lookup reads exactly as the contract's sentence."""
    assert unestablished_access_clause(_record(row)) == row["notice"]


def test_the_notices_reach_both_verbs_and_both_sources() -> None:
    """A row set that lost a verb or a source would stop pinning it."""
    notices = CONTRACT["notices"]

    assert {row["source"] for row in notices} == set(SERVICES)
    assert any("could not be asked" in row["notice"] for row in notices)
    assert any("did not serve it" in row["notice"] for row in notices)
    assert any(row.get("skipped") for row in notices)
