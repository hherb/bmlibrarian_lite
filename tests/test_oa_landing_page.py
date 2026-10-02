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

from bmlibrarian_lite.oa_landing_page import choose_unpaywall_url, citation_pdf_url

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


def test_a_landing_page_is_never_a_pdf_url() -> None:
    """Every row with a landing page offers no PDF beside it: one or the other."""
    for row in CONTRACT["unpaywall_choice"]:
        if row["landing_page"] is not None:
            assert row["pdf_url"] is None, row["name"]


def test_the_contract_has_rows() -> None:
    """Guard against an empty file making every parametrized test vanish."""
    assert len(CONTRACT["unpaywall_choice"]) >= 5
    assert len(CONTRACT["citation_pdf_url"]) >= 10
