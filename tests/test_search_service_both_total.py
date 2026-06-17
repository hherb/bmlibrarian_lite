# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Regression tests for the "Both" mode total-count estimate.

PubMed and Europe PMC index largely the same records, so summing their hit
counts double-counts the overlap. ``SearchService._search_both`` must instead
report a conservative lower bound: ``max(pubmed_total, epmc_total)``.
"""

from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.search_service import SearchService


def _make_service(pubmed_total: int, epmc_total: int) -> SearchService:
    """Build a SearchService with both providers stubbed out.

    The injected clients return the supplied hit counts and a single
    abstract-bearing article each, so the merge step yields a non-empty
    result without touching the network.
    """
    service = SearchService(config=MagicMock())

    pubmed_article = MagicMock(abstract="pubmed abstract")
    epmc_article = MagicMock(abstract="epmc abstract")

    pubmed_client = MagicMock()
    pubmed_client.search.return_value = MagicMock(
        total_count=pubmed_total, pmids=["1"]
    )
    pubmed_client.fetch_articles.return_value = [pubmed_article]
    service._pubmed_client = pubmed_client

    epmc_client = MagicMock()
    epmc_client.search.return_value = (
        [epmc_article],
        MagicMock(total_count=epmc_total),
    )
    service._europepmc_client = epmc_client

    return service


@pytest.mark.parametrize(
    "pubmed_total, epmc_total, expected",
    [
        (100, 80, 100),   # PubMed larger
        (50, 200, 200),   # Europe PMC larger
        (75, 75, 75),     # equal
        (0, 0, 0),        # both empty
    ],
)
def test_both_mode_total_is_max_not_sum(pubmed_total, epmc_total, expected):
    """Total available is the larger provider count, never the sum."""
    service = _make_service(pubmed_total, epmc_total)

    # Keep a deterministic, abstract-bearing merged result.
    merged_article = MagicMock(abstract="merged abstract")
    merged_article.to_lite_document.return_value = MagicMock()

    with patch(
        "bmlibrarian_lite.search_service.SearchResultMerger.merge",
        return_value=[merged_article],
    ):
        result = service._search_both("cancer treatment", max_results=10)

    assert result.total_count == expected
    # The sum would be the old, double-counted behaviour we are guarding against.
    assert result.total_count <= pubmed_total + epmc_total
    if pubmed_total and epmc_total:
        assert result.total_count != pubmed_total + epmc_total
