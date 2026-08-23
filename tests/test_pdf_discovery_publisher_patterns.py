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


@pytest.mark.parametrize(
    "doi",
    [
        "10.3389/fnins.2020.00123",
        "https://doi.org/10.3389/fnins.2020.00123",
        "http://doi.org/10.3389/fnins.2020.00123",
        "https://dx.doi.org/10.3389/fnins.2020.00123",
        "http://dx.doi.org/10.3389/fnins.2020.00123",
        "doi:10.3389/fnins.2020.00123",
        "DOI:10.3389/fnins.2020.00123",
        "  10.3389/fnins.2020.00123  ",
    ],
    ids=[
        "bare",
        "https-doi-org",
        "http-doi-org",
        "https-dx-doi-org",
        "http-dx-doi-org",
        "doi-prefix",
        "uppercase-doi-prefix",
        "surrounding-whitespace",
    ],
)
def test_every_accepted_doi_form_reaches_the_same_branch(
    discovery: PDFDiscoverer, doi: str
) -> None:
    """Prefix matching runs on the normalised DOI, so every input form matches.

    ``dx.doi.org`` is the form Crossref still emits; it used to survive
    normalisation intact and so matched no publisher branch at all.
    """
    assert [s.url for s in discovery._discover_publisher_specific(doi)] == [
        "https://www.frontiersin.org/articles/10.3389/fnins.2020.00123/pdf"
    ]


@pytest.mark.parametrize(
    ("doi", "expected_slug"),
    [
        ("10.7717/peerj.1234", "1234"),
        ("10.7717/peerj-cs.1234", "cs-1234"),
        ("10.7717/peerj-pchem.99", "pchem-99"),
    ],
    ids=["flagship", "computer-science", "physical-chemistry"],
)
def test_peerj_series_is_kept_in_the_article_slug(
    discovery: PDFDiscoverer, doi: str, expected_slug: str
) -> None:
    """PeerJ numbers each series separately, so the series identifies the article.

    Taking the text after the last ``.`` dropped it, so every PeerJ Computer
    Science DOI produced the URL of an unrelated article in the flagship
    journal -- a wrong PDF rather than a missing one.
    """
    assert [s.url for s in discovery._discover_publisher_specific(doi)] == [
        f"https://peerj.com/articles/{expected_slug}.pdf"
    ]


def test_a_peerj_doi_with_no_article_number_yields_nothing(
    discovery: PDFDiscoverer,
) -> None:
    """Better no source than a URL built from a DOI we could not parse."""
    assert discovery._discover_publisher_specific("10.7717/peerj-bogus") == []


def test_plos_doi_yields_the_journal_specific_pdf_url(discovery: PDFDiscoverer) -> None:
    """The PLOS branch maps the journal code into the host path."""
    doi = "10.1371/journal.pntd.0008943"

    assert [s.url for s in discovery._discover_publisher_specific(doi)] == [
        f"https://journals.plos.org/plosntds/article/file?id={doi}&type=printable"
    ]


@pytest.mark.parametrize(
    "doi",
    ["10.3390/nu12103065", "10.1186/s12916-020-01808-2", "10.1038/nature12373"],
    ids=["mdpi-unimplemented", "bmc-unimplemented", "no-branch-at-all"],
)
def test_registrants_without_a_url_pattern_yield_nothing(
    discovery: PDFDiscoverer, doi: str
) -> None:
    """A registrant we cannot build a URL for must produce no source, not a guess.

    MDPI and BMC need landing-page scraping and are deliberately unimplemented;
    this pins that they stay silent rather than start emitting a plausible but
    wrong URL.
    """
    assert discovery._discover_publisher_specific(doi) == []
