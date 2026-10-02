# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Which URL the Unpaywall tier tries, and the PDF a landing page declares (#464).

PMID 40608933 has one open-access copy, in a university repository, and
Unpaywall gives no ``url_for_pdf`` for it: ``url`` is the repository's
landing page. The apps took ``url_for_pdf ?? url``, downloaded that HTML
page as the PDF, failed, and stored the page as an "Unpaywall" full text
with no text in it. Python took ``url_for_pdf`` only and never reached the
PDF the page declares in ``<meta name="citation_pdf_url">``.

The rows are the shared contract,
``doc/cross_platform/fulltext_parity/unpaywall_landing_page.json``. No test
here touches the network.
"""

import json
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.oa_landing_page import (
    UnpaywallChoice,
    choose_unpaywall_url,
    citation_pdf_url,
    decode_character_references,
    landing_page_text,
)
from bmlibrarian_lite.pdf_discovery import web_page_status_unsettled

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "unpaywall_landing_page.json"
    ).read_text(encoding="utf-8")
)


@pytest.mark.parametrize(
    "row", CONTRACT["unpaywall_choice"], ids=lambda row: row["name"]
)
def test_unpaywall_choice_matches_the_contract(row: dict[str, Any]) -> None:
    """Each row's answer offers the PDF URL or landing page the contract names."""
    choice = choose_unpaywall_url(row["response"])

    assert (choice.pdf_url, choice.landing_page) == (
        row["pdf_url"],
        row["landing_page"],
    )


@pytest.mark.parametrize(
    "row", CONTRACT["citation_pdf_url"], ids=lambda row: row["name"]
)
def test_citation_pdf_url_matches_the_contract(row: dict[str, Any]) -> None:
    """Each row's page declares the PDF the contract names, or none."""
    assert citation_pdf_url(row["html"], row["page_url"]) == row["expected"]


@pytest.mark.parametrize(
    "row", CONTRACT["character_references"], ids=lambda row: row["name"]
)
def test_character_references_match_the_contract(row: dict[str, Any]) -> None:
    """Only ``;``-terminated numeric references and the five names decode."""
    assert decode_character_references(row["raw"]) == row["expected"]


@pytest.mark.parametrize(
    "row", CONTRACT["landing_page_status"], ids=lambda row: str(row["status"])
)
def test_landing_page_status_matches_the_contract(row: dict[str, Any]) -> None:
    """Which error statuses leave a landing page unread rather than answered."""
    assert web_page_status_unsettled(row["status"]) is row["unsettled"]


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract and asserted nowhere would pin nothing."""
    assert set(CONTRACT) == {
        "schema_version",
        "description",
        "unpaywall_choice",
        "citation_pdf_url",
        "character_references",
        "landing_page_status",
    }


def test_a_choice_cannot_offer_both_a_pdf_and_a_landing_page() -> None:
    """The landing page is never a PDF URL, so the type refuses both at once."""
    with pytest.raises(ValueError):
        UnpaywallChoice(pdf_url="https://r.org/a.pdf", landing_page="https://r.org/a")


def test_the_chosen_landing_page_carries_its_location() -> None:
    """Discovery reads the PDF's host type, version and licence from it."""
    second = {"url": "https://repo.example.org/2", "host_type": "repository"}
    choice = choose_unpaywall_url(
        {"best_oa_location": {"url": None}, "oa_locations": [None, second]}
    )

    assert choice.landing_page == "https://repo.example.org/2"
    assert choice.location is second


@pytest.mark.parametrize(
    ("body", "content_type", "expected"),
    [
        ("/論文.pdf".encode(), "text/html", "/論文.pdf"),
        ("/論文.pdf".encode(), "", "/論文.pdf"),
        ("/caf\u00e9.pdf".encode("latin-1"), "text/html; charset=ISO-8859-1", "/caf\u00e9.pdf"),
        ("/論文.pdf".encode("shift_jis"), 'text/html; charset="Shift_JIS"', "/論文.pdf"),
        ("/論文.pdf".encode(), "text/html; charset=no-such-charset", "/論文.pdf"),
    ],
    ids=["undeclared", "no type", "declared latin-1", "declared quoted", "unknown charset"],
)
def test_a_landing_page_is_read_by_its_charset_else_as_utf8(
    body: bytes, content_type: str, expected: str
) -> None:
    """Not ISO-8859-1 by default, as ``requests`` reads an undeclared page."""
    assert landing_page_text(body, content_type) == expected


def test_a_landing_page_is_never_a_pdf_url() -> None:
    """Every row with a landing page offers no PDF beside it: one or the other."""
    for row in CONTRACT["unpaywall_choice"]:
        if row["landing_page"] is not None:
            assert row["pdf_url"] is None, row["name"]


def test_the_contract_has_rows() -> None:
    """Guard against an empty file making every parametrized test vanish."""
    assert len(CONTRACT["unpaywall_choice"]) >= 5
    assert len(CONTRACT["citation_pdf_url"]) >= 10
    assert len(CONTRACT["character_references"]) >= 5
    assert len(CONTRACT["landing_page_status"]) >= 10
