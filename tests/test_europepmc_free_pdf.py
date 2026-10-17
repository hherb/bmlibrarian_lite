# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Europe PMC's free-PDF allow-list (bmlib#79).

The rule is the shared contract,
``doc/cross_platform/fulltext_parity/europepmc_free_pdf.json``, which the
Swift and Kotlin ports read too. ``availability == "Free"`` alone rejected the
``Open access`` / ``OA`` entries that are about 96% of the free PDFs.
"""

import json
import logging
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    EUROPE_PMC_FREE_PDF_CODES,
    EUROPE_PMC_FREE_PDF_LABELS,
    EUROPE_PMC_UNAVAILABLE_PDF_CODES,
)
from bmlibrarian_lite.europepmc import _extract_free_pdf_url

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "europepmc_free_pdf.json"
    ).read_text(encoding="utf-8")
)

_RENDER_URL = "https://europepmc.org/articles/PMC1234567?pdf=render"


def _result(entries: list[dict[str, Any]] | None) -> dict[str, Any]:
    """Build a search result carrying ``entries``, or none at all."""
    if entries is None:
        return {"id": "1", "pmid": "1"}
    return {"id": "1", "pmid": "1", "fullTextUrlList": {"fullTextUrl": entries}}


def test_every_contract_key_is_read_here() -> None:
    """The contract holds exactly the keys this file reads."""
    assert set(CONTRACT) == {
        "schema_version",
        "description",
        "source",
        "free_codes",
        "free_labels",
        "known_unavailable_codes",
        "cases",
    }


def test_the_constants_are_the_contracts() -> None:
    """The constants are the contract's lists."""
    assert set(EUROPE_PMC_FREE_PDF_CODES) == set(CONTRACT["free_codes"])
    assert set(EUROPE_PMC_FREE_PDF_LABELS) == set(CONTRACT["free_labels"])
    assert set(EUROPE_PMC_UNAVAILABLE_PDF_CODES) == set(
        CONTRACT["known_unavailable_codes"]
    )


def test_the_contract_holds_every_swift_case() -> None:
    """The contract carries every case Swift had."""
    # An emptied table would pass the loop below vacuously.
    assert len(CONTRACT["cases"]) >= 12


@pytest.mark.parametrize("case", CONTRACT["cases"], ids=lambda c: c["name"])
def test_each_contract_case(case: dict[str, Any]) -> None:
    """Each contract case yields its expected URL."""
    assert _extract_free_pdf_url(_result(case["fullTextUrl"])) == case["expected_url"]


def _warnings(caplog: pytest.LogCaptureFixture) -> list[str]:
    return [
        r.getMessage() for r in caplog.records if r.levelno == logging.WARNING
    ]


def test_an_unrecognised_code_is_logged_at_warning_with_its_label(
    caplog: pytest.LogCaptureFixture,
) -> None:
    """A code in neither set is a WARNING naming the code and its label."""
    entry = {
        "documentStyle": "pdf",
        "availability": "Free",
        "availabilityCode": "Z",
        "url": _RENDER_URL,
    }
    with caplog.at_level(logging.DEBUG, logger="bmlibrarian_lite.europepmc"):
        assert _extract_free_pdf_url(_result([entry])) is None
    messages = _warnings(caplog)
    assert len(messages) == 1
    assert "'Z'" in messages[0] and "'Free'" in messages[0]


@pytest.mark.parametrize(
    "entry",
    [
        {"availability": "Subscription required", "availabilityCode": "S"},
        {"availability": "Open access"},
        {"availability": "Subscription required", "availabilityCode": ""},
    ],
    ids=["known_unavailable_code", "no_code", "empty_code"],
)
def test_a_routine_rejection_is_not_a_warning(
    caplog: pytest.LogCaptureFixture, entry: dict[str, Any]
) -> None:
    """A known paywall, absent or empty code is not a WARNING."""
    entry = {"documentStyle": "pdf", "url": "https://example.org/x.pdf", **entry}
    with caplog.at_level(logging.DEBUG, logger="bmlibrarian_lite.europepmc"):
        _extract_free_pdf_url(_result([entry]))
    assert _warnings(caplog) == []


def test_an_accepted_entry_is_not_a_warning(caplog: pytest.LogCaptureFixture) -> None:
    """An accepted entry logs no WARNING."""
    entry = {
        "documentStyle": "pdf",
        "availability": "Open access",
        "availabilityCode": "OA",
        "url": _RENDER_URL,
    }
    with caplog.at_level(logging.DEBUG, logger="bmlibrarian_lite.europepmc"):
        assert _extract_free_pdf_url(_result([entry])) == _RENDER_URL
    assert _warnings(caplog) == []


@pytest.mark.parametrize(
    ("entry", "expected"),
    [
        ({"availabilityCode": ["OA"], "availability": "Open access"}, _RENDER_URL),
        ({"availabilityCode": {"OA": 1}, "availability": "Free"}, _RENDER_URL),
        ({"availabilityCode": ["OA"], "availability": "Subscription required"}, None),
        ({"availabilityCode": 7, "availability": ["Free"]}, None),
        ({"availability": {"Open access": True}}, None),
    ],
    ids=[
        "list_code_falls_back_to_free_label",
        "dict_code_falls_back_to_free_label",
        "list_code_falls_back_to_paywall_label",
        "non_string_code_and_label_is_rejected",
        "dict_label_without_code_is_rejected",
    ],
)
def test_a_non_string_code_or_label_counts_as_absent(
    caplog: pytest.LogCaptureFixture, entry: dict[str, Any], expected: str | None
) -> None:
    """A non-string code or label is absent, never a TypeError or a WARNING.

    Europe PMC's JSON is untrusted: ``["OA"] in frozenset(...)`` raises
    TypeError (a list is unhashable), which took down the whole result.
    """
    entry = {"documentStyle": "pdf", "url": _RENDER_URL, **entry}
    with caplog.at_level(logging.DEBUG, logger="bmlibrarian_lite.europepmc"):
        assert _extract_free_pdf_url(_result([entry])) == expected
    assert _warnings(caplog) == []
