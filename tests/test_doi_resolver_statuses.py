# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The doi.org tier reads the status it is handed (#446).

``PoliteAdapter`` does not raise when its retries run out: it hands back the
last 429 or 5xx. ``_discover_doi_direct`` never looked at the status, so an
exhausted throttle read as "No PDF sources found. The document may require
institutional access." -- the #347 harm, on the one tier its own docstring
promised to prevent it on.

The HEAD follows redirects, so the status is not always doi.org's. A live
survey of 20 DOIs (2026-09-29): 9 ended in a publisher's 403 bot wall after
doi.org's redirect, and none of the rest content-negotiated to a PDF. The
rule, the maintainer's call:

* doi.org's own status: a 400 (not a DOI) or 404 (not registered) is about
  the identifier, an absence; any other failure is doi.org's;
* the publisher's status: an exhausted throttle, a server fault, a 408 or a
  425 is the publisher's failure, named as the publisher's rather than
  doi.org's; any other 4xx (the bot wall, 404, 405) is an answer that no PDF
  is served by content negotiation, as before, so nearly half of all DOIs
  are not caveated for it.

These tests drive the real ``head`` through the mounted ``PoliteAdapter``,
its retries and requests' redirect handling included, with
``HTTPAdapter.send`` -- urllib3 and the socket -- replaced. urllib3's own
retries are therefore not exercised here; ``tests/test_polite_session.py``
runs them against a loopback server. The one earlier test of doi.org as a
service built its failure by hand and never ran this path.
"""

import logging
from collections.abc import Iterator
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

import pytest
import requests
from requests.structures import CaseInsensitiveDict

from bmlibrarian_lite.analysis_failures import with_unestablished_access
from bmlibrarian_lite.constants import (
    POLITE_MAX_THROTTLE_RETRIES,
    SERVICE_DOI_PUBLISHER,
    SERVICE_DOI_RESOLVER,
    SERVICE_PDF_DOWNLOAD,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.pdf_discovery import (
    PDFDiscoverer,
    PDFSource,
    PDFSourceType,
    doi_lookup_service,
    doi_resolution_failure,
)
from bmlibrarian_lite.polite_session import PoliteAdapter
from bmlibrarian_lite.rate_limit import (
    RateLimiter,
    _registry,
    policy_for_host,
    reset_limiters,
)

DOI = "10.1056/NEJMoa2034577"
RESOLVER_URL = f"https://doi.org/{DOI}"
PUBLISHER_HOST = "www.publisher.example"
PUBLISHER_URL = f"https://{PUBLISHER_HOST}/doi/{DOI}"

#: One request and every retry the adapter makes of it.
ATTEMPTS = POLITE_MAX_THROTTLE_RETRIES + 1


def _no_sleep(seconds: float) -> None:
    """Stand in for ``time.sleep`` without waiting.

    Args:
        seconds: How long the caller would have waited. Ignored.
    """


@pytest.fixture(autouse=True)
def unpaced_hosts() -> Iterator[None]:
    """Seed no-sleep limiters, so a retried throttle costs no wall time.

    Yields:
        Nothing; the registry is cleared afterwards.
    """
    reset_limiters()
    for host in ("doi.org", PUBLISHER_HOST):
        _registry[host] = RateLimiter(
            policy_for_host(host), clock=lambda: 0.0, sleep=_no_sleep, host=host
        )
    yield
    reset_limiters()


def _response(
    request: requests.PreparedRequest,
    status: int,
    headers: dict[str, str] | None = None,
) -> requests.Response:
    """A real response with no body, for ``requests`` to follow or return.

    Args:
        request: The request it answers.
        status: The HTTP status.
        headers: Any headers it carries.

    Returns:
        The response.
    """
    response = requests.Response()
    response.status_code = status
    response.headers = CaseInsensitiveDict(headers or {})
    response.url = str(request.url)
    response.request = request
    response._content = b""
    response._content_consumed = True
    return response


class ScriptedHosts:
    """Answers each request by host: a status, a redirect, or an exception.

    Installed as the mounted adapter's ``_send_once``, below the adapter's
    pacing and retries, so those and requests' redirect handling are the
    real thing; ``HTTPAdapter.send`` (urllib3 and the socket) is not.
    """

    def __init__(self, **by_host: Any) -> None:
        """Record what each host answers.

        Args:
            **by_host: ``doi`` and ``publisher``, each a status, a
                ``(status, headers)`` pair, or an exception type to raise.
        """
        self.by_host = {
            "doi.org": by_host.get("doi", 302),
            PUBLISHER_HOST: by_host.get("publisher", 200),
        }
        self.sent: dict[str, int] = {}

    def __call__(
        self, request: requests.PreparedRequest, **_kwargs: Any
    ) -> requests.Response:
        """Answer one request.

        Args:
            request: The request.
            **_kwargs: Ignored.

        Returns:
            The scripted response.

        Raises:
            requests.RequestException: When the host is scripted to fail.
        """
        host = urlparse(str(request.url)).hostname or ""
        self.sent[host] = self.sent.get(host, 0) + 1
        answer = self.by_host[host]
        if isinstance(answer, type) and issubclass(
            answer, requests.RequestException
        ):
            raise answer("scripted failure", request=request)
        if host == "doi.org" and answer == 302:
            return _response(request, 302, {"Location": PUBLISHER_URL})
        if isinstance(answer, tuple):
            return _response(request, answer[0], answer[1])
        return _response(request, answer, {"Content-Type": "text/html"})


@pytest.fixture
def discoverer() -> PDFDiscoverer:
    """A discoverer whose session is the real one it builds.

    Returns:
        The discoverer.
    """
    return PDFDiscoverer(
        unpaywall_email="test@example.com", use_browser_fallback=False
    )


def _script(discoverer: PDFDiscoverer, **by_host: Any) -> ScriptedHosts:
    """Replace the socket under the discoverer's mounted adapter.

    Args:
        discoverer: The discoverer.
        **by_host: See :class:`ScriptedHosts`.

    Returns:
        The script, so a test can count what was sent.
    """
    adapter = discoverer._session.adapters["https://"]
    assert isinstance(adapter, PoliteAdapter)
    hosts = ScriptedHosts(**by_host)
    adapter._send_once = hosts
    return hosts


def _failure(service: str, status: int) -> SourceLookupFailure:
    """The failure an HTTP status leaves.

    Args:
        service: Who answered it.
        status: The status.

    Returns:
        The failure.
    """
    return SourceLookupFailure(
        service, RequestFailure(RequestFailureKind.HTTP_STATUS, status)
    )


class TestDoiOrgsOwnStatus:
    """doi.org answered, with no redirect to follow."""

    @pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
    def test_an_exhausted_throttle_or_fault_is_doi_orgs_failure(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """An exhausted 429 or 5xx from doi.org was read as no PDF (#446)."""
        hosts = _script(discoverer, doi=status)

        sources, failure = discoverer._discover_doi_direct(DOI)

        assert sources == []
        assert failure == _failure(SERVICE_DOI_RESOLVER, status)
        # Handed back only once the retries ran out: the real adapter ran.
        assert hosts.sent == {"doi.org": ATTEMPTS}

    @pytest.mark.parametrize("status", [400, 404])
    def test_a_doi_nobody_registered_is_an_absence(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """doi.org's 400 (not a DOI) and 404 (not registered) are absences.

        They are about the identifier, so they must not be caveated: a bad
        DOI field would caveat every run, and no retry would ever settle it.
        """
        _script(discoverer, doi=status)

        assert discoverer._discover_doi_direct(DOI) == ([], None)

    @pytest.mark.parametrize("status", [403, 408, 410, 499])
    def test_any_other_refusal_is_doi_orgs_failure(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """doi.org refusing our request is not the article having no copy."""
        _script(discoverer, doi=status)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == _failure(SERVICE_DOI_RESOLVER, status)

    def test_a_record_pointing_nowhere_sendable_is_doi_orgs(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """``InvalidSchema`` carries no request: the hop that sent us is named."""
        _script(discoverer, doi=(302, {"Location": "ftp://files.example/x"}))

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            SERVICE_DOI_RESOLVER, RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )

    def test_a_www_resolver_url_is_cleaned(self, discoverer: PDFDiscoverer) -> None:
        """Left on, ``https://www.doi.org/`` made doi.org answer 400."""
        assert discoverer._clean_doi(f"https://www.doi.org/{DOI}") == DOI

    def test_an_unreachable_doi_org_is_still_doi_orgs(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """The exception path keeps its name: nothing was redirected."""
        _script(discoverer, doi=requests.exceptions.ConnectTimeout)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            SERVICE_DOI_RESOLVER, RequestFailure(RequestFailureKind.TIMEOUT)
        )


class TestThePublishersStatus:
    """doi.org redirected; what came back is the publisher's."""

    @pytest.mark.parametrize("status", [429, 500, 502, 503, 504])
    def test_an_exhausted_throttle_or_fault_is_the_publishers_failure(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """Named as the publisher's: doi.org answered, with a redirect."""
        hosts = _script(discoverer, publisher=status)

        sources, failure = discoverer._discover_doi_direct(DOI)

        assert sources == []
        assert failure == _failure(SERVICE_DOI_PUBLISHER, status)
        assert hosts.sent == {"doi.org": 1, PUBLISHER_HOST: ATTEMPTS}

    @pytest.mark.parametrize("status", [501, 505, 522, 524])
    def test_a_server_fault_not_retried_is_still_the_publishers_failure(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """Any 5xx, retried or not, is the publisher's failure.

        Cloudflare's 522 and 524 are an origin that timed out. Raised by our own socket, the same timeout is recorded; handed back
        as a status it must be too, though nothing retries it.
        """
        hosts = _script(discoverer, publisher=status)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == _failure(SERVICE_DOI_PUBLISHER, status)
        assert hosts.sent == {"doi.org": 1, PUBLISHER_HOST: 1}

    @pytest.mark.parametrize("status", [408, 425])
    def test_a_not_now_is_the_publishers_failure(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """408 is the publisher timing out on us; 425 asks us to come back.

        Neither is the bot wall's "no".
        """
        _script(discoverer, publisher=status)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == _failure(SERVICE_DOI_PUBLISHER, status)

    @pytest.mark.parametrize("status", [401, 403, 404, 405, 499])
    def test_a_refusal_is_no_pdf_by_this_route(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """The control: 9 of 20 real DOIs end in a publisher's 403.

        Recording it would caveat half of all DOIs for a route that served
        no PDF to any of the other 11.
        """
        _script(discoverer, publisher=status)

        assert discoverer._discover_doi_direct(DOI) == ([], None)

    @pytest.mark.parametrize("status", [400, 403])
    def test_a_refusal_labelled_pdf_is_not_a_source(
        self, discoverer: PDFDiscoverer, status: int
    ) -> None:
        """An error page is not the article, whatever its header claims."""
        _script(
            discoverer, publisher=(status, {"Content-Type": "application/pdf"})
        )

        assert discoverer._discover_doi_direct(DOI) == ([], None)

    def test_an_unreachable_publisher_is_the_publishers_failure(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """The exception names the request it failed on, not the first."""
        _script(discoverer, publisher=requests.exceptions.ConnectionError)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            SERVICE_DOI_PUBLISHER, RequestFailure(RequestFailureKind.CONNECTION)
        )

    def test_a_redirect_loop_at_the_publisher_is_the_publishers(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """``TooManyRedirects`` names the last hop, which is the publisher's.

        Recorded, unlike the bot wall's 403: a loop leaves no status to read,
        so what it would have answered is unknown.
        """
        _script(discoverer, publisher=(302, {"Location": PUBLISHER_URL}))

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            SERVICE_DOI_PUBLISHER, RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )

    def test_a_redirect_nowhere_sendable_is_the_publishers(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """``InvalidSchema`` has no request; the publisher sent us there."""
        _script(discoverer, publisher=(302, {"Location": "ftp://files.example/x"}))

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            SERVICE_DOI_PUBLISHER, RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )

    @pytest.mark.parametrize(
        ("by_host", "service"),
        [
            ({"publisher": (302, {"Location": "http://[bad/x"})}, SERVICE_DOI_PUBLISHER),
            ({"doi": (302, {"Location": "http://[bad/x"})}, SERVICE_DOI_RESOLVER),
        ],
        ids=["publisher", "doi.org"],
    )
    def test_an_unparseable_redirect_is_recorded_not_raised(
        self, discoverer: PDFDiscoverer, by_host: dict[str, Any], service: str
    ) -> None:
        """A bare ``ValueError`` from inside requests, which escaped."""
        _script(discoverer, **by_host)

        _sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure == SourceLookupFailure(
            service, RequestFailure(RequestFailureKind.REQUEST_FAILED)
        )

    def test_a_negotiated_pdf_is_a_source(
        self, discoverer: PDFDiscoverer
    ) -> None:
        """The control for the route itself."""
        _script(
            discoverer, publisher=(200, {"Content-Type": "application/pdf"})
        )

        sources, failure = discoverer._discover_doi_direct(DOI)

        assert failure is None
        assert [(s.url, s.source_type) for s in sources] == [
            (PUBLISHER_URL, PDFSourceType.DOI_DIRECT)
        ]

    def test_a_landing_page_is_no_pdf(self, discoverer: PDFDiscoverer) -> None:
        """What 11 of the 20 surveyed DOIs answered: HTML, settled."""
        _script(discoverer, publisher=200)

        assert discoverer._discover_doi_direct(DOI) == ([], None)


class TestTheRuleIsAPureFunction:
    """Who answered, and with what, decides it; nothing else."""

    @pytest.mark.parametrize("status", [200, 204, 301, 302, 399])
    def test_a_status_below_400_is_no_failure_from_either(
        self, status: int
    ) -> None:
        """A success, or a redirect nobody followed, failed at nothing."""
        assert doi_resolution_failure(status, RESOLVER_URL) is None
        assert doi_resolution_failure(status, PUBLISHER_URL) is None

    @pytest.mark.parametrize(
        "url",
        [
            RESOLVER_URL,
            f"https://dx.doi.org/{DOI}",
            f"https://www.doi.org/{DOI}",
            f"http://doi.org/{DOI}",
        ],
    )
    def test_every_resolver_host_is_doi_org(self, url: str) -> None:
        """``dx.doi.org`` and ``www.doi.org`` are the same resolver."""
        assert doi_resolution_failure(503, url) == _failure(
            SERVICE_DOI_RESOLVER, 503
        )

    def test_a_host_ending_in_doi_org_is_not_the_resolver(self) -> None:
        """Hostname equality, not a suffix test."""
        assert doi_resolution_failure(
            503, f"https://notdoi.org/{DOI}"
        ) == _failure(SERVICE_DOI_PUBLISHER, 503)


class TestTheReaderIsTold:
    """What reaches the reader, through the whole discovery chain."""

    @pytest.fixture(autouse=True)
    def no_other_tiers(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Leave doi.org the one tier that can say anything.

        Args:
            monkeypatch: Pytest's monkeypatch.
        """
        monkeypatch.setattr(
            PDFDiscoverer, "_discover_unpaywall", lambda *_a, **_k: ([], None)
        )
        monkeypatch.setattr(
            PDFDiscoverer, "_discover_publisher_specific", lambda *_a, **_k: []
        )

    def test_a_throttled_publisher_withholds_the_access_claim(
        self, discoverer: PDFDiscoverer, tmp_path: Path
    ) -> None:
        """The #446 harm: "may require institutional access" from a 503."""
        _script(discoverer, publisher=503)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert not result.success
        assert "institutional access" not in result.error
        assert (
            f"{SERVICE_DOI_PUBLISHER} (HTTP 503 Service Unavailable) could "
            f"not be asked" in result.error
        )

    @pytest.mark.parametrize(
        ("status", "label"),
        [(500, "HTTP 500 Internal Server Error"), (502, "HTTP 502 Bad Gateway"),
         (522, "HTTP 522")],
    )
    def test_a_publishers_server_error_could_not_be_asked(
        self, discoverer: PDFDiscoverer, tmp_path: Path, status: int, label: str
    ) -> None:
        """A 5xx says nothing about the article (#445), retried or not."""
        _script(discoverer, publisher=status)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert "institutional access" not in result.error
        assert f"{SERVICE_DOI_PUBLISHER} ({label}) could not be asked" in result.error

    def test_a_publishers_recorded_4xx_did_not_serve_it(
        self, discoverer: PDFDiscoverer, tmp_path: Path
    ) -> None:
        """The control: a 408 is recorded and, being a 4xx, is an answer."""
        _script(discoverer, publisher=408)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert "institutional access" not in result.error
        assert (
            f"{SERVICE_DOI_PUBLISHER} (HTTP 408 Request Timeout) did not serve it"
            in result.error
        )

    def test_the_publishers_name_starts_its_sentence_capitalised(
        self,
        discoverer: PDFDiscoverer,
        tmp_path: Path,
        monkeypatch: pytest.MonkeyPatch,
    ) -> None:
        """After "Failed to download…", the phrase begins a sentence."""
        found = PDFSource(
            url=f"https://{PUBLISHER_HOST}/article.pdf",
            source_type=PDFSourceType.UNPAYWALL_OA,
            is_open_access=True,
        )
        monkeypatch.setattr(
            PDFDiscoverer, "_discover_unpaywall", lambda *_a, **_k: ([found], None)
        )
        _script(discoverer, publisher=503)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert not result.success
        assert (
            f"source. The {SERVICE_DOI_PUBLISHER[len('the '):]} (HTTP 503"
            in result.error
        )

    def test_an_unparseable_redirect_keeps_what_other_tiers_found(
        self, discoverer: PDFDiscoverer, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The ``ValueError`` escaped the whole discovery, found source and all."""
        found = PDFSource(
            url="https://repository.example/article.pdf",
            source_type=PDFSourceType.UNPAYWALL_OA,
            is_open_access=True,
        )
        monkeypatch.setattr(
            PDFDiscoverer, "_discover_unpaywall", lambda *_a, **_k: ([found], None)
        )
        _script(discoverer, publisher=(302, {"Location": "http://[bad/x"}))

        sources, record = discoverer._discover_sources(DOI, None, None)

        assert found in sources
        assert [f.service for f in record.failures] == [SERVICE_DOI_PUBLISHER]

    @pytest.mark.parametrize("status", [400, 404])
    def test_a_doi_nobody_registered_keeps_todays_wording(
        self, discoverer: PDFDiscoverer, tmp_path: Path, status: int
    ) -> None:
        """The control for doi.org's own answers about the identifier."""
        _script(discoverer, doi=status)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert result.lookups == LookupRecord()
        assert "institutional access" in result.error

    def test_a_bot_wall_keeps_todays_wording(
        self, discoverer: PDFDiscoverer, tmp_path: Path
    ) -> None:
        """The control: without it, recording every status passes above."""
        _script(discoverer, publisher=403)

        result = discoverer.discover_and_download(
            output_path=tmp_path / "out.pdf", doi=DOI
        )

        assert not result.success
        assert result.lookups == LookupRecord()
        assert "institutional access" in result.error


class TestALowercaseServiceStartsASentenceCapitalised:
    """``with_unestablished_access`` starts a sentence with a service name.

    "the PDF download" already read "Claim. the PDF download (not
    configured) could not be asked"; the publisher's name would too.
    """

    @pytest.mark.parametrize(
        "record",
        [
            LookupRecord(failures=(_failure(SERVICE_DOI_PUBLISHER, 503),)),
            LookupRecord(
                skipped=(
                    SourceLookupSkipped(
                        SERVICE_PDF_DOWNLOAD, LookupSkipReason.NOT_CONFIGURED
                    ),
                )
            ),
        ],
    )
    def test_the_sentence_after_the_claim_is_capitalised(
        self, record: LookupRecord
    ) -> None:
        """Only its leading "the": the rest of the name keeps its case."""
        first = record.failures[0] if record.failures else record.skipped[0]
        assert first.service.startswith("the ")

        text = with_unestablished_access("Claim.", record)

        assert text.startswith(f"Claim. The {first.service[len('the '):]} (")

    def test_a_domain_name_keeps_its_case(self) -> None:
        """The control: "doi.org" is a name, and "Doi.org" is not."""
        record = LookupRecord(failures=(_failure(SERVICE_DOI_RESOLVER, 503),))

        assert with_unestablished_access("Claim.", record).startswith(
            "Claim. doi.org (HTTP 503"
        )

    def test_a_name_merely_beginning_the_is_left_alone(self) -> None:
        """The control for the space: "thesaurus" is not "the saurus"."""
        record = LookupRecord(failures=(_failure("thesaurus.example", 503),))

        assert with_unestablished_access("Claim.", record).startswith(
            "Claim. thesaurus.example (HTTP 503"
        )


class TestTheLogSaysWhoLeftItOpen:
    """An unsettled lookup is logged at WARNING, where INFO still shows it."""

    @pytest.mark.parametrize(
        ("by_host", "service"),
        [
            ({"publisher": 503}, SERVICE_DOI_PUBLISHER),
            ({"publisher": requests.exceptions.ConnectionError}, SERVICE_DOI_PUBLISHER),
            ({"doi": 503}, SERVICE_DOI_RESOLVER),
        ],
        ids=["publisher-status", "publisher-exception", "doi.org-status"],
    )
    def test_the_warning_names_the_doi_and_who(
        self,
        discoverer: PDFDiscoverer,
        caplog: pytest.LogCaptureFixture,
        by_host: dict[str, Any],
        service: str,
    ) -> None:
        """Both paths log: the status handed back and the exception raised."""
        _script(discoverer, **by_host)

        with caplog.at_level(logging.WARNING, logger="bmlibrarian_lite.pdf_discovery"):
            discoverer._discover_doi_direct(DOI)

        warnings = [r.getMessage() for r in caplog.records if r.levelno == logging.WARNING]
        assert any(DOI in m and f"at {service} (" in m for m in warnings), warnings


class TestWhoAnswered:
    """``doi_lookup_service`` reads the URL as ``requests`` holds it."""

    def test_a_request_url_in_bytes_is_read(self) -> None:
        """A prepared request's URL may be bytes."""
        assert doi_lookup_service(PUBLISHER_URL.encode()) == SERVICE_DOI_PUBLISHER
        assert doi_lookup_service(RESOLVER_URL.encode()) == SERVICE_DOI_RESOLVER

    def test_no_url_is_doi_orgs(self) -> None:
        """Nothing was sent or answered, so nothing got past doi.org."""
        assert doi_lookup_service(None) == SERVICE_DOI_RESOLVER
