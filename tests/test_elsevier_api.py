"""Elsevier's Article API: the shared contract and the client (#480, stage C2)."""

from __future__ import annotations

import json
import logging
from http import HTTPStatus
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite import elsevier_api
from bmlibrarian_lite.constants import (
    ELSEVIER_API_BASE_URL,
    ELSEVIER_ERROR_BODY_MAX_BYTES,
    ELSEVIER_HOST,
    ELSEVIER_KEY_REFUSED_STATUS,
    ELSEVIER_NETWORK_REFUSED_STATUS,
    ELSEVIER_NETWORK_REFUSED_TOKEN,
    ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429,
    ELSEVIER_SOURCE_LABEL,
    ELSEVIER_STATUS_HEADER,
    ELSEVIER_WARNING_PREFIX,
    EUROPEPMC_USER_AGENT,
    HTTP_TOO_MANY_REQUESTS,
    POLITE_RATE_CEILINGS,
    SERVICE_CORE,
    SERVICE_ELSEVIER,
    SERVICE_UNPAYWALL,
)
from bmlibrarian_lite.core_api import (
    normalise_doi,
    reset_core_throttle,
    session_core_throttle,
    strip_doi_prefix,
)
from bmlibrarian_lite.data_models import (
    LookupRecord,
    LookupSkipReason,
    RequestFailure,
    RequestFailureKind,
    SourceLookupFailure,
    SourceLookupSkipped,
)
from bmlibrarian_lite.elsevier_api import (
    ElsevierArticleClient,
    ElsevierCredentials,
    ElsevierFetch,
    ElsevierOutcome,
    ElsevierSession,
    default_elsevier_client,
    elsevier_article_url,
    elsevier_eligible,
    reset_elsevier_session,
    session_elsevier_state,
)
from bmlibrarian_lite.keyed_service_session import credentials_digest, key_digest

from .scripted_http_server import ScriptedAnswer, running

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc" / "cross_platform" / "fulltext_parity" / "elsevier_article.json"
    ).read_text(encoding="utf-8")
)

#: A key and a token no test ever sends anywhere real.
KEY = "test-elsevier-key-0123456789"
TOKEN = "test-elsevier-token-ABCDEF"
OTHER_KEY = "test-elsevier-key-corrected-9876"

#: An Elsevier DOI, and the one path the client asks for it.
DOI = "10.1016/j.cell.2020.02.052"
PATH = f"/content/article/doi/{DOI}"

#: What the tests serve as a PDF: the contract's ``body_pdf``.
PDF = b"%PDF-1.7\n" + b"0123456789" * 200

#: A body that holds the network refusal's token.
AUTHENTICATION_ERROR = (
    "<service-error><status><statusCode>AUTHENTICATION_ERROR</statusCode>"
    "<statusText>Requestor configuration settings insufficient for access to "
    "this resource.</statusText></status></service-error>"
)


def never() -> bool:
    """A fetch nobody cancels."""
    return False


def test_every_contract_table_is_read_here() -> None:
    """A table added to the contract must be read by a test here."""
    assert set(CONTRACT) == {
        "schema_version", "description", "service_name", "source", "source_label",
        "desktop_source_type", "base_url", "doi_prefix", "pause_after_consecutive_429",
        "key_refused_status", "key_refused_reason", "network_refused_status",
        "network_refused_token", "network_refused_reason", "first_page_header",
        "first_page_prefix", "error_body_max_bytes", "follows_redirects",
        "requests_per_second", "eligible", "article_url", "answers", "session",
    }


def test_the_names_are_the_contracts() -> None:
    """Names and numbers are the contract's, not this platform's own."""
    assert CONTRACT["service_name"] == SERVICE_ELSEVIER
    assert CONTRACT["source_label"] == ELSEVIER_SOURCE_LABEL
    assert CONTRACT["base_url"] == ELSEVIER_API_BASE_URL
    assert CONTRACT["doi_prefix"] == elsevier_api.ELSEVIER_DOI_PREFIX
    assert CONTRACT["pause_after_consecutive_429"] == ELSEVIER_PAUSE_AFTER_CONSECUTIVE_429
    assert CONTRACT["key_refused_status"] == ELSEVIER_KEY_REFUSED_STATUS
    assert CONTRACT["network_refused_status"] == ELSEVIER_NETWORK_REFUSED_STATUS
    assert CONTRACT["network_refused_token"].encode("ascii") == ELSEVIER_NETWORK_REFUSED_TOKEN
    assert CONTRACT["first_page_header"] == ELSEVIER_STATUS_HEADER
    assert CONTRACT["first_page_prefix"].lower() == ELSEVIER_WARNING_PREFIX.lower()
    assert CONTRACT["error_body_max_bytes"] == ELSEVIER_ERROR_BODY_MAX_BYTES
    assert CONTRACT["follows_redirects"] is False
    assert (
        SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.KEY_REFUSED).describe()
        == CONTRACT["key_refused_reason"]
    )
    assert (
        SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NETWORK_REFUSED).describe()
        == CONTRACT["network_refused_reason"]
    )


def test_the_sources_are_the_contracts() -> None:
    """The source the apps store is the contract's; the desktop type is the next task's."""
    assert CONTRACT["source"] == "elsevier"
    assert CONTRACT["desktop_source_type"] == "elsevier_api"


def test_elsevier_is_paced_at_the_contracts_rate() -> None:
    """Two requests a second, under Elsevier's ten."""
    assert POLITE_RATE_CEILINGS[ELSEVIER_HOST] == CONTRACT["requests_per_second"] == 2


def test_the_contract_has_rows() -> None:
    """An emptied table would pass every parametrised test below."""
    assert len(CONTRACT["eligible"]) >= 10
    assert len(CONTRACT["article_url"]) >= 12
    assert len(CONTRACT["answers"]) >= 24
    assert len(CONTRACT["session"]) >= 7


@pytest.mark.parametrize("row", CONTRACT["eligible"], ids=lambda row: repr(row["doi"]))
def test_each_eligible_row(row: dict[str, Any]) -> None:
    """Only a DOI Elsevier registered is asked."""
    assert elsevier_eligible(row["doi"]) is row["eligible"]


@pytest.mark.parametrize("row", CONTRACT["article_url"], ids=lambda row: row["name"])
def test_each_article_url(row: dict[str, Any]) -> None:
    """The request for a DOI is the contract's, byte for byte."""
    base = row["base_url"] or ELSEVIER_API_BASE_URL
    assert elsevier_article_url(row["doi"], base) == row["url"]


def _answer(row: dict[str, Any]) -> ScriptedAnswer:
    """The answer a contract row describes, as the scripted server sends it."""
    if row.get("body_pdf"):
        body = PDF
    else:
        body = b" " * row.get("body_padding_bytes", 0) + row.get("body_text", "").encode("utf-8")
    content_type = "application/octet-stream"
    headers: list[tuple[str, str]] = []
    for name, value in row.get("headers", {}).items():
        if name.lower() == "content-type":
            content_type = value
        else:
            headers.append((name, value))
    return ScriptedAnswer(HTTPStatus(row["status"]), body, content_type, tuple(headers))


def _client(
    base_url: str,
    session: ElsevierSession | None = None,
    key: str = KEY,
    token: str | None = None,
    max_retries: int = 0,
) -> ElsevierArticleClient:
    return ElsevierArticleClient(
        ElsevierCredentials(key, token),
        base_url=base_url,
        max_retries=max_retries,
        session_state=session if session is not None else ElsevierSession(),
    )


def _status_code(fetch: ElsevierFetch) -> int | None:
    return fetch.failure.status_code if fetch.failure is not None else None


@pytest.mark.parametrize("row", CONTRACT["answers"], ids=lambda row: row["name"])
def test_each_answer(row: dict[str, Any], tmp_path: Path) -> None:
    """Every answer gets the contract's outcome, from a fresh session."""
    output = tmp_path / "article.pdf"
    with running({PATH: [_answer(row)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, never)
        received = list(server.received)
    # A redirect is not followed: one request, to the article
    assert [request.path for request in received] == [PATH]
    assert fetch.outcome.value == row["outcome"]
    if row["failure_kind"] is None:
        assert fetch.failure is None
    else:
        assert fetch.failure is not None
        assert fetch.failure.kind.value == row["failure_kind"]
        expected = row["status"] if row["failure_kind"] == "http_status" else None
        assert fetch.failure.status_code == expected
    if row["outcome"] == "served":
        assert fetch.path == output
        assert output.read_bytes() == PDF
    else:
        assert fetch.path is None
        assert not output.exists()
    assert list(tmp_path.iterdir()) == ([output] if row["outcome"] == "served" else [])


def _credentials(entry: dict[str, Any]) -> tuple[str, str | None]:
    return entry["credentials"]["key"], entry["credentials"]["token"]


@pytest.mark.parametrize("row", CONTRACT["session"], ids=lambda row: row["name"])
def test_each_session_row(row: dict[str, Any], tmp_path: Path) -> None:
    """What one fetch leaves for the next is the contract's."""
    session = ElsevierSession()
    with running({PATH: []}) as server:
        for entry in row["fetches"]:
            server.script[PATH] = [_answer({**entry, "headers": {}})]
            key, token = _credentials(entry)
            before = len(server.received)
            refused = session.refuses_key(key_digest(key)) or session.refuses_network(
                credentials_digest(key, token)
            )
            paused = session.paused
            _client(server.url, session, key, token).fetch_pdf(DOI, tmp_path / "a.pdf", never)
            # Already refused or paused: no request; otherwise exactly one
            expected = 0 if refused or paused else 1
            assert len(server.received) - before == expected
        for check in row["then"]:
            server.script[PATH] = [_answer({**check, "headers": {}})]
            before = len(server.received)
            key, token = _credentials(check)
            fetch = _client(server.url, session, key, token).fetch_pdf(
                DOI, tmp_path / "b.pdf", never
            )
            assert (len(server.received) > before) is check["asked"]
            assert fetch.outcome.value == check["outcome"]
            assert (fetch.failure.kind.value if fetch.failure else None) == check["failure_kind"]
            assert _status_code(fetch) == check["status_code"]


def _headers(request: Any) -> dict[str, str]:
    return {name.lower(): value for name, value in request.headers.items()}


def test_the_key_and_token_travel_in_their_headers_alone(tmp_path: Path) -> None:
    """Headers, never the URL; Accept PDF; Python's user agent."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        _client(server.url, key=f"  {KEY}\n", token=f" {TOKEN} ").fetch_pdf(
            DOI, tmp_path / "a.pdf", never
        )
        request = server.received[0]
    headers = _headers(request)
    assert headers["x-els-apikey"] == KEY
    assert headers["x-els-insttoken"] == TOKEN
    assert headers["accept"] == "application/pdf"
    assert headers["user-agent"] == EUROPEPMC_USER_AGENT
    assert KEY not in request.path and TOKEN not in request.path
    assert request.parameters == {}


@pytest.mark.parametrize("token", [None, "", "   "])
def test_no_token_sends_no_token_header(tmp_path: Path, token: str | None) -> None:
    """A blank token is no token: the header is not sent at all."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        _client(server.url, token=token).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        headers = _headers(server.received[0])
    assert headers["x-els-apikey"] == KEY
    assert "x-els-insttoken" not in headers


def test_neither_secret_is_in_a_repr_or_a_log_line(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """Every path logs, at DEBUG too (urllib3's lines included), neither secret."""
    caplog.set_level(logging.DEBUG)
    answers = [
        ScriptedAnswer(HTTPStatus.OK, PDF),
        ScriptedAnswer(HTTPStatus.OK, PDF, headers=((ELSEVIER_STATUS_HEADER, "WARNING - x"),)),
        ScriptedAnswer(HTTPStatus.OK, b"<html></html>"),
        ScriptedAnswer(HTTPStatus.FOUND, headers=(("Location", "http://localhost:1/x"),)),
        ScriptedAnswer(HTTPStatus.SERVICE_UNAVAILABLE),
        ScriptedAnswer(HTTPStatus.FORBIDDEN, AUTHENTICATION_ERROR.encode()),
        ScriptedAnswer(HTTPStatus.UNAUTHORIZED),
    ]
    session = ElsevierSession()
    with running({PATH: answers}) as server:
        client = _client(server.url, session, token=TOKEN, max_retries=1)
        for index in range(len(answers)):
            client.fetch_pdf(DOI, tmp_path / f"{index}.pdf", never)
        # The refusals are told from the session, without a request
        client.fetch_pdf(DOI, tmp_path / "again.pdf", never)
    _client("http://127.0.0.1:9", token=TOKEN).fetch_pdf(DOI, tmp_path / "n.pdf", never)
    assert caplog.records, "the control: these paths do log"
    assert any(record.name.startswith("urllib3") for record in caplog.records)
    secrets = (KEY, TOKEN, key_digest(KEY), credentials_digest(KEY, TOKEN))
    for secret in secrets:
        assert secret not in caplog.text
        assert secret not in repr(client)
        assert secret not in repr(ElsevierCredentials(KEY, TOKEN))
        assert secret not in repr(session)


def test_a_key_a_header_cannot_carry_is_unreachable_and_never_logged(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """The refusal requests raises names the header value; it is classified, never kept."""
    caplog.set_level(logging.DEBUG)
    bad = "bad-key\r\nX-Injected: 1"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url, key=bad).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        assert server.received == []
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
    assert "bad-key" not in caplog.text


def test_a_key_http_client_cannot_encode_is_unreachable_and_never_logged(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """A curly quote is no Latin-1: classified as a failed request, the key never logged."""
    caplog.set_level(logging.DEBUG)
    bad = "curly\u2019key-0123456789"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url, key=bad).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        assert server.received == []
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
    assert "curly" not in caplog.text and "0123456789" not in caplog.text
    assert list(tmp_path.iterdir()) == []


def test_the_bare_doi_is_cores_prefix_rule_with_its_case_kept() -> None:
    """One rule, shared with CORE: Elsevier's path keeps the DOI's case."""
    assert strip_doi_prefix(" HTTPS://DX.DOI.ORG/10.1016/J.X.1 ") == "10.1016/J.X.1"
    assert strip_doi_prefix("doi:10.1016/J.x") == "10.1016/J.x"
    assert strip_doi_prefix("DOI: 10.1016/J.x ") == "10.1016/J.x"
    assert normalise_doi(" HTTPS://DX.DOI.ORG/10.1016/J.X.1 ") == "10.1016/j.x.1"


def test_a_redirect_to_another_host_is_not_followed(tmp_path: Path) -> None:
    """The key would go with it: a 3xx is unreachable, the target never asked."""
    with running({}) as target, running({PATH: []}) as server:
        location = f"http://localhost:{target.server_address[1]}/elsewhere"
        server.script[PATH] = [
            ScriptedAnswer(HTTPStatus.FOUND, headers=(("Location", location),))
        ]
        fetch = _client(server.url, token=TOKEN).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        assert target.received == []
        assert len(server.received) == 1
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 302))


def test_the_first_page_writes_nothing(tmp_path: Path) -> None:
    """The first page is a valid PDF, and never the article: no file, no part."""
    output = tmp_path / "pdfs" / "a.pdf"
    warning = ((ELSEVIER_STATUS_HEADER, CONTRACT["answers"][1]["headers"]["X-ELS-Status"]),)
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF, headers=warning)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, never)
    assert fetch == ElsevierFetch.absent()
    assert not output.exists()
    assert not elsevier_api.partial_download_path(output).exists()


def test_the_first_page_is_logged_at_info(
    tmp_path: Path, caplog: pytest.LogCaptureFixture
) -> None:
    """Not entitled is worth a line, not a warning."""
    caplog.set_level(logging.INFO, logger="bmlibrarian_lite.elsevier_api")
    warning = ((ELSEVIER_STATUS_HEADER, "WARNING - first page"),)
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF, headers=warning)]}) as server:
        _client(server.url).fetch_pdf(DOI, tmp_path / "a.pdf", never)
    lines = [r for r in caplog.records if r.name == "bmlibrarian_lite.elsevier_api"]
    assert lines and all(r.levelno == logging.INFO for r in lines)


def test_a_served_pdf_is_written_through_a_part_file(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The body goes to ``.part`` and is renamed into place once whole."""
    output = tmp_path / "pdfs" / "a.pdf"
    renames: list[tuple[str, str]] = []
    original = Path.replace

    def recording_replace(self: Path, target: Any) -> Any:
        renames.append((self.name, Path(target).name))
        return original(self, target)

    monkeypatch.setattr(Path, "replace", recording_replace)
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, never)
    assert fetch == ElsevierFetch.served(output)
    assert renames == [("a.pdf.part", "a.pdf")]
    assert output.read_bytes() == PDF
    assert sorted(p.name for p in output.parent.iterdir()) == ["a.pdf"]


def test_a_pdf_over_the_limit_is_refused_for_size(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """The declared length over the limit: refused before the body is streamed."""
    monkeypatch.setattr(elsevier_api, "MAX_PDF_SIZE", len(PDF) - 1)
    output = tmp_path / "pdfs" / "a.pdf"
    asked: list[int] = []

    def counting() -> bool:
        asked.append(1)
        return False

    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, counting)
    assert fetch == ElsevierFetch.refused_for_size()
    # Asked once, before the request: no chunk was streamed, no folder made
    assert len(asked) == 1
    assert list(tmp_path.iterdir()) == []


def test_a_pdf_at_the_limit_is_served(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    """Control: exactly the limit is not over it."""
    monkeypatch.setattr(elsevier_api, "MAX_PDF_SIZE", len(PDF))
    output = tmp_path / "a.pdf"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        assert _client(server.url).fetch_pdf(DOI, output, never) == ElsevierFetch.served(output)


def test_an_undeclared_length_over_the_limit_is_refused_while_streaming(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A body with no Content-Length is counted as it arrives; nothing is kept."""
    monkeypatch.setattr(elsevier_api, "MAX_PDF_SIZE", len(PDF) - 1)
    output = tmp_path / "a.pdf"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        client = _client(server.url)
        get = client._session.get

        def get_without_length(*args: Any, **kwargs: Any) -> Any:
            response = get(*args, **kwargs)
            del response.headers["Content-Length"]
            return response

        monkeypatch.setattr(client._session, "get", get_without_length)
        fetch = client.fetch_pdf(DOI, output, never)
    assert fetch == ElsevierFetch.refused_for_size()
    assert list(tmp_path.iterdir()) == []


def test_a_write_that_fails_is_not_saved(tmp_path: Path) -> None:
    """Our fault, not Elsevier's answer: the caching note, no part left."""
    blocker = tmp_path / "blocker"
    blocker.write_text("a file where the directory should be")
    output = blocker / "a.pdf"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, never)
    assert fetch == ElsevierFetch.not_saved()
    assert sorted(p.name for p in tmp_path.iterdir()) == ["blocker"]


def test_a_cancel_mid_stream_writes_nothing(tmp_path: Path) -> None:
    """Cancelled between chunks: no file, no part, and nothing recorded."""
    calls: list[int] = []

    def cancelled() -> bool:
        calls.append(1)
        return len(calls) > 1

    body = b"%PDF-1.7\n" + b"x" * (1024 * 1024)
    output = tmp_path / "a.pdf"
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, body)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, output, cancelled)
        assert len(server.received) == 1
    assert fetch == ElsevierFetch.cancelled()
    assert fetch.lookups(elsevier_article_url(DOI)) == LookupRecord()
    assert list(tmp_path.iterdir()) == []


def test_a_cancel_before_asking_sends_nothing(tmp_path: Path) -> None:
    """Already cancelled: no request is made."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, tmp_path / "a.pdf", lambda: True)
        assert server.received == []
    assert fetch == ElsevierFetch.cancelled()


def test_a_dropped_connection_mid_body_is_unreachable(
    tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """A body cut short is the transport's failure, and leaves no file."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        client = _client(server.url)
        get = client._session.get

        def get_then_lie(*args: Any, **kwargs: Any) -> Any:
            response = get(*args, **kwargs)
            response.raw.length_remaining = len(PDF) + 10  # expects more than comes
            response.raw.enforce_content_length = True
            return response

        monkeypatch.setattr(client._session, "get", get_then_lie)
        fetch = client.fetch_pdf(DOI, tmp_path / "a.pdf", never)
    # requests' ChunkedEncodingError: a transport failure, never "not saved"
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.REQUEST_FAILED))
    assert list(tmp_path.iterdir()) == []


def test_a_401_refuses_that_key_and_another_key_is_asked(tmp_path: Path) -> None:
    """The refusal is scoped to the key, whatever the token."""
    session = ElsevierSession()
    script = [ScriptedAnswer(HTTPStatus.UNAUTHORIZED), ScriptedAnswer(HTTPStatus.OK, PDF)]
    with running({PATH: script}) as server:
        first = _client(server.url, session).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        again = _client(server.url, session, token=TOKEN).fetch_pdf(DOI, tmp_path / "b.pdf", never)
        assert len(server.received) == 1
        other = _client(server.url, session, key=OTHER_KEY).fetch_pdf(
            DOI, tmp_path / "c.pdf", never
        )
        assert len(server.received) == 2
        assert _headers(server.received[1])["x-els-apikey"] == OTHER_KEY
    assert first == again == ElsevierFetch.key_refused()
    assert other == ElsevierFetch.served(tmp_path / "c.pdf")


def test_an_authentication_error_refuses_those_credentials_and_a_token_is_asked(
    tmp_path: Path,
) -> None:
    """A 403 AUTHENTICATION_ERROR refuses key and token together."""
    session = ElsevierSession()
    script = [
        ScriptedAnswer(HTTPStatus.FORBIDDEN, AUTHENTICATION_ERROR.encode(), "text/xml"),
        ScriptedAnswer(HTTPStatus.OK, PDF),
    ]
    with running({PATH: script}) as server:
        first = _client(server.url, session).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        again = _client(server.url, session).fetch_pdf(DOI, tmp_path / "b.pdf", never)
        assert len(server.received) == 1
        with_token = _client(server.url, session, token=TOKEN).fetch_pdf(
            DOI, tmp_path / "c.pdf", never
        )
        assert len(server.received) == 2
        assert _headers(server.received[1])["x-els-insttoken"] == TOKEN
    assert first == again == ElsevierFetch.network_refused()
    assert with_token == ElsevierFetch.served(tmp_path / "c.pdf")


def test_the_session_is_process_wide_and_shares_nothing_with_cores(tmp_path: Path) -> None:
    """Two default clients share one session; CORE's pause never pauses Elsevier."""
    reset_core_throttle()
    reset_elsevier_session()
    core = session_core_throttle()
    for _ in range(2):
        core.record(HTTP_TOO_MANY_REQUESTS, key_digest("core-key"))
    assert core.paused
    assert not session_elsevier_state().paused
    with running({PATH: [ScriptedAnswer(HTTPStatus.TOO_MANY_REQUESTS)]}) as server:
        first = ElsevierArticleClient(ElsevierCredentials(KEY), base_url=server.url, max_retries=0)
        second = ElsevierArticleClient(ElsevierCredentials(KEY), base_url=server.url, max_retries=0)
        first.fetch_pdf(DOI, tmp_path / "a.pdf", never)
        second.fetch_pdf(DOI, tmp_path / "b.pdf", never)
        assert len(server.received) == 2
        third = ElsevierArticleClient(ElsevierCredentials(KEY), base_url=server.url, max_retries=0)
        assert third.fetch_pdf(DOI, tmp_path / "c.pdf", never) == ElsevierFetch.unreachable(
            RequestFailure(RequestFailureKind.HTTP_STATUS, HTTP_TOO_MANY_REQUESTS)
        )
        assert len(server.received) == 2
    assert session_elsevier_state().paused
    reset_elsevier_session()
    assert not session_elsevier_state().paused


def test_a_retried_status_is_asked_four_times(tmp_path: Path) -> None:
    """429/5xx are retried, four attempts in all, as CORE's."""
    with running({PATH: [ScriptedAnswer(HTTPStatus.SERVICE_UNAVAILABLE)]}) as server:
        fetch = _client(server.url, max_retries=3).fetch_pdf(DOI, tmp_path / "a.pdf", never)
        assert len(server.received) == 4
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 503))


@pytest.mark.parametrize(
    "row",
    [row for row in CONTRACT["answers"] if "body_padding_bytes" in row],
    ids=lambda row: row["name"],
)
def test_the_bound_holds_whatever_the_chunks(
    row: dict[str, Any], tmp_path: Path, monkeypatch: pytest.MonkeyPatch
) -> None:
    """Chunks that do not divide the bound still stop the read at the bound."""
    monkeypatch.setattr(elsevier_api, "ELSEVIER_DOWNLOAD_CHUNK_BYTES", 7000)
    with running({PATH: [_answer(row)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, tmp_path / "a.pdf", never)
    assert fetch.outcome.value == row["outcome"]


def test_a_403_body_is_read_no_further_than_the_bound(tmp_path: Path) -> None:
    """A huge error body is not read to its end to look for the token."""
    body = b" " * (ELSEVIER_ERROR_BODY_MAX_BYTES * 4) + ELSEVIER_NETWORK_REFUSED_TOKEN
    with running({PATH: [ScriptedAnswer(HTTPStatus.FORBIDDEN, body)]}) as server:
        fetch = _client(server.url).fetch_pdf(DOI, tmp_path / "a.pdf", never)
    assert fetch == ElsevierFetch.unreachable(RequestFailure(RequestFailureKind.HTTP_STATUS, 403))


@pytest.mark.parametrize(
    "doi", ["10.1371/journal.pone.0000217", "", "   ", "10.10160/x"]
)
def test_a_doi_not_elsevier_s_is_never_asked(tmp_path: Path, doi: str) -> None:
    """Another publisher's DOI: no request, an absence that records nothing."""
    session = ElsevierSession()
    with running({PATH: [ScriptedAnswer(HTTPStatus.OK, PDF)]}) as server:
        fetch = _client(server.url, session).fetch_pdf(doi, tmp_path / "a.pdf", never)
        assert server.received == []
    assert fetch == ElsevierFetch.absent()
    assert fetch.lookups(elsevier_article_url(DOI)) == LookupRecord()


def test_no_server_is_unreachable_by_its_kind(tmp_path: Path) -> None:
    """A refused connection is a lookup that failed, as its kind."""
    fetch = _client("http://127.0.0.1:9").fetch_pdf(DOI, tmp_path / "a.pdf", never)
    assert fetch.outcome is ElsevierOutcome.UNREACHABLE
    assert fetch.failure == RequestFailure(RequestFailureKind.CONNECTION)


# --- The typed fetch -------------------------------------------------------


URL = elsevier_article_url(DOI)


def test_each_outcome_is_recorded_as_the_reader_is_told_it(tmp_path: Path) -> None:
    """Served, absent and cancelled record nothing; the rest a failure or a skip."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    assert ElsevierFetch.served(tmp_path / "a.pdf").lookups(URL) == LookupRecord()
    assert ElsevierFetch.absent().lookups(URL) == LookupRecord()
    assert ElsevierFetch.cancelled().lookups(URL) == LookupRecord()
    assert ElsevierFetch.unreachable(failure).lookups(URL) == LookupRecord(
        failures=(SourceLookupFailure(SERVICE_ELSEVIER, failure),)
    )
    assert ElsevierFetch.key_refused().lookups(URL) == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.KEY_REFUSED),)
    )
    assert ElsevierFetch.network_refused().lookups(URL) == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NETWORK_REFUSED),)
    )
    assert ElsevierFetch.refused_for_size().lookups(URL) == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.OVER_SIZE_LIMIT, URL),)
    )
    assert ElsevierFetch.not_saved().lookups(URL) == LookupRecord(
        skipped=(SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NOT_SAVED, URL),)
    )


def test_the_article_url_recorded_carries_no_secret() -> None:
    """The address a skip keeps is the article URL alone."""
    record = ElsevierFetch.not_saved().lookups(URL)
    assert KEY not in repr(record) and TOKEN not in repr(record)
    assert "apikey" not in URL.lower() and "insttoken" not in URL.lower()


def test_impossible_fetches_are_refused(tmp_path: Path) -> None:
    """A path only when served; a failure only when unreachable."""
    failure = RequestFailure(RequestFailureKind.TIMEOUT)
    with pytest.raises(ValueError):
        ElsevierFetch(ElsevierOutcome.SERVED, path=None)
    with pytest.raises(ValueError):
        ElsevierFetch(ElsevierOutcome.UNREACHABLE, failure=None)
    with pytest.raises(ValueError):
        ElsevierFetch(ElsevierOutcome.ABSENT, path=tmp_path / "a.pdf")
    with pytest.raises(ValueError):
        ElsevierFetch(ElsevierOutcome.KEY_REFUSED, failure=failure)
    with pytest.raises(ValueError):
        ElsevierFetch(ElsevierOutcome.SERVED, path=tmp_path / "a.pdf", failure=failure)


def test_a_cancel_is_distinguishable_from_an_absence() -> None:
    """The caller returns "Cancelled" for one and goes on for the other."""
    assert ElsevierFetch.cancelled() != ElsevierFetch.absent()
    assert ElsevierFetch.cancelled().is_cancelled
    assert not ElsevierFetch.absent().is_cancelled


# --- The skip reasons --------------------------------------------------------


def test_network_refused_is_worded_and_elsevier_s_alone() -> None:
    """Only Elsevier's own lookup is refused from a network, never with an address."""
    skip = SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NETWORK_REFUSED)
    assert skip.describe() == "not available from this network"
    for service in (SERVICE_CORE, SERVICE_UNPAYWALL):
        with pytest.raises(ValueError):
            SourceLookupSkipped(service, LookupSkipReason.NETWORK_REFUSED)
    with pytest.raises(ValueError):
        SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.NETWORK_REFUSED, URL)


def test_key_refused_is_admitted_for_core_and_elsevier_alone() -> None:
    """A refused key is CORE's or Elsevier's own lookup, never with an address."""
    SourceLookupSkipped(SERVICE_CORE, LookupSkipReason.KEY_REFUSED)
    SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.KEY_REFUSED)
    with pytest.raises(ValueError):
        SourceLookupSkipped(SERVICE_UNPAYWALL, LookupSkipReason.KEY_REFUSED)
    with pytest.raises(ValueError):
        SourceLookupSkipped(SERVICE_ELSEVIER, LookupSkipReason.KEY_REFUSED, URL)


# --- Credentials and the default client --------------------------------------


def test_credentials_are_trimmed_and_a_blank_key_refused() -> None:
    """The settings trimmed; a blank token is none; a blank key no credentials."""
    credentials = ElsevierCredentials(f" {KEY}\n", "  ")
    assert credentials.api_key == KEY
    assert credentials.insttoken is None
    assert ElsevierCredentials(KEY, f" {TOKEN} ").insttoken == TOKEN
    for blank in ("", "   ", "\n"):
        with pytest.raises(ValueError) as caught:
            ElsevierCredentials(blank, TOKEN)
        assert TOKEN not in str(caught.value)


def test_the_digests_are_the_sessions() -> None:
    """The key's and the credentials' fingerprints, as the session holds them."""
    credentials = ElsevierCredentials(KEY, TOKEN)
    assert credentials.key_digest == key_digest(KEY)
    assert credentials.credentials_digest == credentials_digest(KEY, TOKEN)
    assert ElsevierCredentials(KEY).credentials_digest == credentials_digest(KEY, None)


@pytest.mark.real_elsevier_client
def test_no_key_means_no_client(monkeypatch: pytest.MonkeyPatch) -> None:
    """Blank and missing keys build nothing; the environment is a fallback."""
    monkeypatch.delenv("ELSEVIER_API_KEY", raising=False)
    monkeypatch.delenv("ELSEVIER_INSTTOKEN", raising=False)
    assert default_elsevier_client(None, None) is None
    assert default_elsevier_client("   ", TOKEN) is None
    monkeypatch.setenv("ELSEVIER_INSTTOKEN", TOKEN)
    assert default_elsevier_client(None, None) is None, "a token alone is never used"
    monkeypatch.setenv("ELSEVIER_API_KEY", KEY)
    client = default_elsevier_client(None, None)
    assert isinstance(client, ElsevierArticleClient)
    assert client.credentials.api_key == KEY
    assert client.credentials.insttoken == TOKEN


@pytest.mark.real_elsevier_client
def test_the_settings_win_over_the_environment(monkeypatch: pytest.MonkeyPatch) -> None:
    """A key and a token in the settings replace the environment's."""
    monkeypatch.setenv("ELSEVIER_API_KEY", "env-key")
    monkeypatch.setenv("ELSEVIER_INSTTOKEN", "env-token")
    client = default_elsevier_client(KEY, TOKEN)
    assert client is not None
    assert client.credentials.api_key == KEY
    assert client.credentials.insttoken == TOKEN


@pytest.mark.real_elsevier_client
def test_without_a_key_the_debug_line_names_no_secret(
    monkeypatch: pytest.MonkeyPatch, caplog: pytest.LogCaptureFixture
) -> None:
    """Not configured is a debug line, nothing more."""
    caplog.set_level(logging.DEBUG, logger="bmlibrarian_lite.elsevier_api")
    monkeypatch.delenv("ELSEVIER_API_KEY", raising=False)
    monkeypatch.setenv("ELSEVIER_INSTTOKEN", TOKEN)
    assert default_elsevier_client(None, None) is None
    assert [r.levelno for r in caplog.records] == [logging.DEBUG]
    assert TOKEN not in caplog.text
