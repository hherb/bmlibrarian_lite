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

"""Service JSON is read as bmlib and serde_json read it (#781, bmlib#753).

``Response.json()`` accepts a BOM, ``NaN``, ``Infinity``, an overflowing
number and a lone surrogate. Each call site's test sends a body ``.json()``
reads, so putting ``.json()`` back at that site fails it.
"""

import pytest
import requests

from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind
from bmlibrarian_lite.europepmc import EuropePMCClient
from bmlibrarian_lite.exceptions import SourceRequestError
from bmlibrarian_lite.pdf_discovery import PDFDiscoverer
from bmlibrarian_lite.search_failures import (
    request_failure_from_exception,
    strict_response_json,
)
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ClinicalTrialsClient,
    CrossRefClient,
    PubMedClient,
)
from tests.http_responses import session_answering

MALFORMED = RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)

# Bodies ``.json()`` accepts and serde_json refuses.
LENIENT_BODIES = {
    "a BOM": b'\xef\xbb\xbf{"a": 1}',
    "NaN": b'{"a": NaN}',
    "Infinity": b'{"a": Infinity}',
    "-Infinity": b'{"a": -Infinity}',
    "a number past the largest float": b'{"a": 1e999}',
    "a lone surrogate": b'{"a": "\\ud800"}',
    "nesting past 127 levels": b"[" * 200 + b"]" * 200,
}

# Deep enough that the decoder itself raises ``RecursionError`` before bmlib's
# depth check runs (a 100 KB body).
DEEP_ENOUGH_TO_RECURSE = 50_000


def _answer(body: bytes, status: int = 200) -> requests.Response:
    """A real response holding ``body``.

    Args:
        body: The bytes served.
        status: The HTTP status.

    Returns:
        The response.
    """
    response = requests.Response()
    response.status_code = status
    response._content = body
    response.url = "https://example.org/answer"
    return response


@pytest.mark.parametrize("body", LENIENT_BODIES.values(), ids=LENIENT_BODIES.keys())
def test_requests_reads_what_serde_refuses(body: bytes) -> None:
    """The premise: ``.json()`` takes each of these bodies as an answer."""
    _answer(body).json()


@pytest.mark.parametrize(
    "body",
    [
        *LENIENT_BODIES.values(),
        b'{"a": "\xff"}',
        b"<html></html>",
        b"",
        b"[" * DEEP_ENOUGH_TO_RECURSE + b"]" * DEEP_ENOUGH_TO_RECURSE,
    ],
    ids=[*LENIENT_BODIES.keys(), "not UTF-8", "not JSON", "empty", "nested past the recursion limit"],
)
def test_each_refusal_is_a_malformed_response(body: bytes) -> None:
    """Every refusal is ``requests``' own error, so every handler reads it."""
    with pytest.raises(requests.exceptions.JSONDecodeError) as caught:
        strict_response_json(_answer(body))
    assert isinstance(caught.value, ValueError)
    assert request_failure_from_exception(caught.value) == MALFORMED


def test_a_well_formed_body_is_read() -> None:
    """The control: escapes, a surrogate pair and an exact integer read."""
    body = b'{"t": "\\u00e9 \\ud83d\\ude00", "n": 12345678901234567890, "x": 1.5}'
    assert strict_response_json(_answer(body)) == {
        "t": "é \U0001f600",
        "n": 12345678901234567890,
        "x": 1.5,
    }


def _europepmc(body: bytes) -> EuropePMCClient:
    """A Europe PMC client whose every request is answered with ``body``.

    Args:
        body: The bytes served.

    Returns:
        The client.
    """
    client = EuropePMCClient()
    client._session = session_answering(_answer(body))
    return client


# A well-shaped answer behind a BOM: only the decode can refuse it.
_EUROPEPMC_BOM_ANSWER = b'\xef\xbb\xbf{"hitCount": 0, "resultList": {"result": []}}'


def test_a_europe_pmc_record_answer_with_a_bom_is_unreachable() -> None:
    """The article lookup: unreadable, never read as "no such article"."""
    fetch = _europepmc(_EUROPEPMC_BOM_ANSWER).fetch_article_info(pmid="31996627")
    assert fetch.info is None
    assert fetch.failure == MALFORMED


def test_a_europe_pmc_search_page_with_a_bom_is_refused() -> None:
    """The search page: a source request error, not an empty page."""
    client = _europepmc(_EUROPEPMC_BOM_ANSWER)
    with pytest.raises(SourceRequestError) as caught:
        client._get_search_page({"query": "x"})
    assert caught.value.failure == MALFORMED


def test_an_id_converter_answer_with_a_bom_is_unreadable() -> None:
    """The ID Converter: a BOM is a failure, never the record it wraps."""
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com")
    discoverer._session = session_answering(
        _answer(b'\xef\xbb\xbf{"records": [{"pmid": "1", "pmcid": "PMC1"}]}')
    )
    pmcid, failure = discoverer._get_pmcid_from_pmid("1")
    assert pmcid is None
    assert failure is not None
    assert failure.failure == MALFORMED


def test_an_unpaywall_answer_holding_a_lone_surrogate_is_unreadable() -> None:
    """Unpaywall: the URL it names is not taken from an unreadable body."""
    discoverer = PDFDiscoverer(unpaywall_email="test@example.com")
    discoverer._session = session_answering(
        _answer(b'{"best_oa_location": {"url_for_pdf": "https://x.org/\\ud800.pdf"}}')
    )
    sources, failure = discoverer._discover_unpaywall("10.1/x")
    assert sources == []
    assert failure is not None
    assert failure.failure == MALFORMED


def test_a_crossref_work_holding_infinity_is_unreachable() -> None:
    """CrossRef: unreadable is not absent, and not a record either."""
    client = CrossRefClient(email="test@example.com")
    client.session = session_answering(_answer(b'{"message": {"is-referenced-by-count": Infinity}}'))
    fetch = client.get_work("10.1/x")
    assert fetch.record is None
    assert fetch.failure == MALFORMED


def test_a_trial_record_holding_a_huge_number_is_unreachable() -> None:
    """ClinicalTrials.gov: an overflowing number is no record."""
    client = ClinicalTrialsClient()
    client.session = session_answering(_answer(b'{"protocolSection": {"n": 1e999}}'))
    fetch = client.get_study("NCT00000001")
    assert fetch.record is None
    assert fetch.failure == MALFORMED


def test_an_id_converter_answer_holding_a_lone_surrogate_is_refused() -> None:
    """The transparency analyser's ID Converter: no PMID from an unreadable body."""
    client = PubMedClient(email="test@example.com")
    client.session = session_answering(_answer(b'{"records": [{"doi": "10.1/x", "pmid": "\\ud800"}]}'))
    with pytest.raises(requests.exceptions.JSONDecodeError):
        client.convert_ids(["10.1/x"], "doi", "pmid")


def test_an_id_converter_answer_that_is_well_formed_is_read() -> None:
    """The control: a readable answer maps the DOI to its PMID."""
    client = PubMedClient(email="test@example.com")
    client.session = session_answering(_answer(b'{"records": [{"doi": "10.1/x", "pmid": "1"}]}'))
    assert client.convert_ids(["10.1/x"], "doi", "pmid") == {"10.1/x": "1"}


def test_an_id_converter_error_status_is_refused() -> None:
    """An error status is no answer, even with a readable body (#785)."""
    client = PubMedClient(email="test@example.com")
    client.session = session_answering(_answer(b'{"records": []}', status=500))
    with pytest.raises(requests.HTTPError):
        client.convert_ids(["10.1/x"], "doi", "pmid")
