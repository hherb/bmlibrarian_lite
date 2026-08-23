# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""Tests for publisher-specific PDF URL patterns.

Every branch of ``_discover_publisher_specific`` keys off a DOI registrant
prefix, because that is the only part of a DOI a publisher actually owns. A
host name matched anywhere inside the string is not a publisher identity:
``frontiersin.org.example.com`` contains it, and so does any DOI whose suffix
happens to spell it out.
"""

import pytest

from bmlibrarian_lite.pdf_discovery import PDFDiscoverer


@pytest.fixture
def discovery() -> PDFDiscoverer:
    """A discovery client; no branch under test performs any network I/O."""
    return PDFDiscoverer(unpaywall_email="researcher@example.org")


def test_frontiers_doi_yields_the_frontiers_pdf_url(discovery: PDFDiscoverer) -> None:
    """A real Frontiers DOI still resolves to its PDF."""
    doi = "10.3389/fnins.2020.00123"

    urls = [source.url for source in discovery._discover_publisher_specific(doi)]

    assert urls == [f"https://www.frontiersin.org/articles/{doi}/pdf"]


def test_doi_url_prefix_is_stripped_before_matching(discovery: PDFDiscoverer) -> None:
    """The canonical ``https://doi.org/...`` form matches the same branch."""
    sources = discovery._discover_publisher_specific("https://doi.org/10.3389/fnins.2020.00123")

    assert [s.url for s in sources] == [
        "https://www.frontiersin.org/articles/10.3389/fnins.2020.00123/pdf"
    ]


@pytest.mark.parametrize(
    "doi",
    [
        "https://frontiersin.org.example.com/paper",
        "10.1234/frontiersin.org.2020.5",
    ],
    ids=["lookalike-host", "host-name-inside-doi-suffix"],
)
def test_a_string_merely_containing_the_host_is_not_a_frontiers_article(
    discovery: PDFDiscoverer, doi: str
) -> None:
    """Containing ``frontiersin.org`` somewhere does not make it a Frontiers DOI.

    The old substring test accepted both of these and pasted the whole string
    into a Frontiers article path, producing a URL that could never resolve.
    """
    assert discovery._discover_publisher_specific(doi) == []
