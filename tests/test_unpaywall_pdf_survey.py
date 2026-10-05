# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""Tests for the Unpaywall PDF survey (#480).

The survey decides whether a refused Unpaywall PDF is offered to the reader,
so what is pinned here is what would make it lie: a row filed under the
wrong family, a browser column that was never a bound, a "desktop" client
that is only a copy of the shipped one, and a committed row carrying a
signed link's credentials or the Unpaywall email.
"""

import importlib.util
import json
import sys
import threading
from collections.abc import Iterator
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from types import ModuleType
from typing import Any
from unittest.mock import MagicMock

import pytest
import requests

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT_PATH = REPO_ROOT / "scripts" / "unpaywall_pdf_survey.py"
COMMITTED_SAMPLES = sorted((REPO_ROOT / "doc/developer/unpaywall_pdf_survey").glob("*.jsonl"))


def _load_script() -> ModuleType:
    """Load unpaywall_pdf_survey.py as a module (scripts/ is not a package).

    Returns:
        The loaded module.
    """
    spec = importlib.util.spec_from_file_location("unpaywall_pdf_survey", SCRIPT_PATH)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules["unpaywall_pdf_survey"] = module
    spec.loader.exec_module(module)
    return module


survey = _load_script()

PDF: dict[str, Any] = {"status": 200, "pdf": True}
HTML: dict[str, Any] = {"status": 200, "pdf": False, "markers": []}
CHALLENGE: dict[str, Any] = {
    "status": 403,
    "pdf": False,
    "title": "Just a moment...",
    "markers": ["cloudflare"],
}
REFUSED: dict[str, Any] = {"status": 403, "pdf": False, "markers": []}
GONE: dict[str, Any] = {"status": 404, "pdf": False, "markers": []}
NO_ANSWER: dict[str, Any] = {"status": None, "error": "ConnectionError"}


def _row(url: str = "https://example.org/a.pdf", **probes: dict[str, Any]) -> dict[str, Any]:
    """A sample row whose clients got ``probes``.

    Args:
        url: The address Unpaywall named.
        **probes: Probes by client, with ``browser_headers`` for
            ``browser-headers``.

    Returns:
        The row.
    """
    return {
        "doi": "10.1/x",
        "pdf_url": url,
        "probes": {name.replace("_", "-"): probe for name, probe in probes.items()},
    }


def _ours(probe: dict[str, Any]) -> dict[str, dict[str, Any]]:
    """The same probe for every app client."""
    return {"desktop": probe, "android": probe, "apple": probe}


class TestRowsCarryNoCredentials:
    """A redirect's signed query never reaches a row, nor does the email."""

    @pytest.mark.parametrize(
        ("url", "kept"),
        [
            (
                "https://s3.amazonaws.com/b/a.pdf?X-Amz-Signature=abc&X-Amz-Credential=k",
                "https://s3.amazonaws.com/b/a.pdf",
            ),
            ("https://example.org/a.pdf#page=2", "https://example.org/a.pdf"),
            ("https://example.org/a.pdf", "https://example.org/a.pdf"),
        ],
    )
    def test_the_query_and_fragment_go(self, url: str, kept: str) -> None:
        """Only scheme, host and path survive."""
        assert survey.public_url(url) == kept

    def test_none_stays_none(self) -> None:
        """A probe with no final URL records none."""
        assert survey.public_url(None) is None

    def test_unpaywall_is_asked_with_the_email_and_never_returns_it(self) -> None:
        """The email is a parameter of the one request, not of its result."""
        session = MagicMock()
        session.get.return_value.status_code = 200
        session.get.return_value.json.return_value = {"doi": "10.1/x"}

        state, data = survey.ask_unpaywall("10.1/x", "reader@example.org", session)

        assert state == "answered"
        assert "reader@example.org" not in json.dumps(data)
        assert session.get.call_args.kwargs["params"] == {"email": "reader@example.org"}

    @pytest.mark.parametrize(
        ("status", "body", "state"),
        [(404, None, "unknown"), (500, None, "failed"), (200, ["not", "a", "dict"], "failed")],
    )
    def test_an_unpaywall_miss_is_named(self, status: int, body: Any, state: str) -> None:
        """A 404 is "unknown DOI"; anything else unanswered is a failure."""
        session = MagicMock()
        session.get.return_value.status_code = status
        session.get.return_value.json.return_value = body

        assert survey.ask_unpaywall("10.1/x", "reader@example.org", session) == (state, None)

    def test_a_transport_error_is_a_failure(self) -> None:
        """No answer is not an unknown DOI."""
        session = MagicMock()
        session.get.side_effect = requests.ConnectionError("down")

        assert survey.ask_unpaywall("10.1/x", "reader@example.org", session) == ("failed", None)


class TestRequestable:
    """The apps' rule for an address a client can send (#474, #478)."""

    @pytest.mark.parametrize(
        "url",
        ["ftp://example.org/a.pdf", "file:///a.pdf", "/relative/a.pdf", "https://", "a.pdf", ""],
    )
    def test_not_requestable(self, url: str) -> None:
        """Not an absolute http(s) URL with a host."""
        assert not survey.requestable(url)

    @pytest.mark.parametrize("url", ["https://example.org/a.pdf", "http://example.org/a"])
    def test_requestable(self, url: str) -> None:
        """The control."""
        assert survey.requestable(url)


class TestDescribeBody:
    """A body is a PDF only by its bytes; a page is read for its defences."""

    def test_a_pdf_by_its_magic_number(self) -> None:
        """``%PDF`` decides, not a Content-Type."""
        assert survey.describe_body(b"%PDF-1.7\n...", {"content-type": "text/html"}) == {
            "pdf": True
        }

    def test_a_cloudflare_challenge(self) -> None:
        """Title, text and the defence it names."""
        page = (
            b"<html><head><title>Just a moment...</title><script>var x=1</script></head>"
            b"<body>Enable JavaScript and cookies to continue</body></html>"
        )

        described = survey.describe_body(page, {"server": "cloudflare"})

        assert described["pdf"] is False
        assert described["title"] == "Just a moment..."
        assert described["snippet"] == "Just a moment... Enable JavaScript and cookies to continue"
        assert described["markers"] == ["cloudflare"]

    def test_a_defence_named_only_in_a_header(self) -> None:
        """Cloudflare marks a challenge in ``cf-mitigated``."""
        markers = survey.wall_markers("<html></html>", {"cf-mitigated": "challenge"})
        assert markers == ["cloudflare"]

    def test_control_an_ordinary_page_names_no_defence(self) -> None:
        """A repository landing page is not a wall."""
        page = b"<html><title>Repository record</title><body>Download the full text</body></html>"
        assert survey.describe_body(page, {"server": "nginx"})["markers"] == []

    def test_markers_are_reread_from_kept_text(self) -> None:
        """A marker added after a sample was fetched still reaches it."""
        probe = {
            "status": 200,
            "pdf": False,
            "markers": [],
            "title": "Please wait",
            "snippet": "This process is protecting the site from AI crawlers",
        }
        assert survey.probe_markers(probe) == ["robot-text"]


class TestCloudflareRefusal:
    """A 403 Cloudflare served is its own answer, whatever the page shows."""

    def test_a_403_from_cloudflare(self) -> None:
        """ScienceDirect's challenge markup lies past the bytes read."""
        probe = {"status": 403, "pdf": False, "markers": [], "headers": {"server": "cloudflare"}}
        assert survey.probe_markers(probe) == ["cloudflare"]

    @pytest.mark.parametrize(
        "probe",
        [
            {"status": 200, "pdf": False, "markers": [], "headers": {"server": "cloudflare"}},
            {"status": 403, "pdf": False, "markers": [], "headers": {"server": "nginx"}},
        ],
    )
    def test_control_not_a_cloudflare_refusal(self, probe: dict[str, Any]) -> None:
        """A page Cloudflare merely relays, and another server's 403."""
        assert survey.probe_markers(probe) == []


class TestServed:
    """Served means a 200 whose body starts ``%PDF``."""

    @pytest.mark.parametrize(
        ("probe", "expected"),
        [
            (PDF, True),
            (HTML, False),
            ({"status": 403, "pdf": True}, False),
            (NO_ANSWER, False),
            (None, False),
        ],
    )
    def test_served(self, probe: dict[str, Any] | None, expected: bool) -> None:
        """Only the first is a PDF obtained."""
        assert survey.served(probe) is expected


class TestClassify:
    """Each family needs the evidence that names it, and nothing less."""

    def test_served(self) -> None:
        """Our client got the PDF."""
        assert survey.classify(_row(**_ours(PDF), browser=PDF)) == survey.Verdict("served", "pdf")

    def test_an_address_no_client_can_send(self) -> None:
        """Unfetchable whatever was probed (nothing was)."""
        verdict = survey.classify({"doi": "d", "pdf_url": "ftp://example.org/a.pdf", "probes": {}})
        assert verdict == survey.Verdict("unfetchable", "address")

    def test_another_app_client_was_served(self) -> None:
        """A User-Agent difference: our-client, whatever the browser got."""
        row = _row(desktop=REFUSED, android=PDF, apple=REFUSED, browser_headers=REFUSED, browser=PDF)

        assert survey.classify(row, "desktop") == survey.Verdict("our-client", "user-agent")
        assert survey.classify(row, "android") == survey.Verdict("served", "pdf")

    def test_browser_headers_were_enough(self) -> None:
        """A header change over the same client recovers it."""
        row = _row(**_ours(REFUSED), browser_headers=PDF, browser=PDF)
        assert survey.classify(row) == survey.Verdict("our-client", "headers")

    def test_a_challenge_the_browser_passes(self) -> None:
        """The JavaScript wall #480 suspected."""
        row = _row(**_ours(CHALLENGE), browser_headers=CHALLENGE, browser=PDF)
        assert survey.classify(row) == survey.Verdict("bot-wall", "js-challenge")

    def test_a_silent_refusal_the_browser_passes(self) -> None:
        """No challenge page, but only a browser is served."""
        row = _row(**_ours(REFUSED), browser_headers=REFUSED, browser=PDF)
        assert survey.classify(row) == survey.Verdict("bot-wall", "browser-only")

    def test_a_challenge_the_browser_cannot_pass(self) -> None:
        """Walled in the browser too: still a wall, not an absence."""
        row = _row(**_ours(GONE), browser_headers=GONE, browser=CHALLENGE)
        assert survey.classify(row) == survey.Verdict("bot-wall", "challenge-in-browser")

    @pytest.mark.parametrize(
        ("browser", "verdict"),
        [
            (
                {"status": 200, "pdf": False, "title": "An article | Wiley", "markers": []},
                ("unfetchable", "no-free-pdf-behind-wall"),
            ),
            (
                {"status": 403, "pdf": False, "title": "An article | Wiley", "markers": []},
                ("unfetchable", "no-free-pdf-behind-wall"),
            ),
            (
                {"status": 301, "pdf": False, "snippet": "Click to continue", "markers": []},
                ("unclassified", "browser-stopped-mid-redirect"),
            ),
            (
                {"status": 522, "pdf": False, "title": "Please Return Soon", "markers": []},
                ("unclassified", "host-error"),
            ),
            (
                {"status": 404, "pdf": False, "title": "Not Found | IWA Publishing", "markers": []},
                ("unfetchable", "gone-behind-wall"),
            ),
            ({"status": 200, "pdf": False, "markers": []}, ("bot-wall", "challenge-unresolved")),
        ],
    )
    def test_past_our_challenge_the_browser_found(
        self, browser: dict[str, Any], verdict: tuple[str, str]
    ) -> None:
        """An article page is no free PDF; a blank page is a wall not cleared."""
        row = _row(**_ours(CHALLENGE), browser_headers=CHALLENGE, browser=browser)
        assert survey.classify(row) == survey.Verdict(*verdict)

    def test_control_an_article_page_without_our_challenge(self) -> None:
        """Without a challenge to us, a page for everyone is not "behind a wall"."""
        page = {"status": 200, "pdf": False, "title": "An article", "markers": []}
        row = _row(**_ours(page), browser_headers=page, browser=page)
        assert survey.classify(row) == survey.Verdict("unfetchable", "not-a-pdf")

    @pytest.mark.parametrize(
        ("ours", "reason"),
        [(CHALLENGE, "challenge-unverified"), (REFUSED, "no-browser-probe")],
    )
    def test_without_a_browser_nothing_is_settled(self, ours: dict[str, Any], reason: str) -> None:
        """No wall can be told from a refusal without the arbiter."""
        row = _row(**_ours(ours), browser_headers=ours)
        assert survey.classify(row) == survey.Verdict("unclassified", reason)

    def test_gone_everywhere(self) -> None:
        """404/410 to every client, the browser included."""
        row = _row(**_ours(GONE), browser_headers={"status": 410}, browser=GONE)
        assert survey.classify(row) == survey.Verdict("unfetchable", "gone")

    def test_control_gone_to_us_but_a_page_to_the_browser(self) -> None:
        """One client's 404 is not the host's answer for everyone."""
        row = _row(**_ours(GONE), browser_headers=GONE, browser=HTML)
        assert survey.classify(row).reason != "gone"

    def test_a_dead_host(self) -> None:
        """No client got an answer."""
        browser = {"status": None, "error": "ERR_NAME_NOT_RESOLVED"}
        row = _row(**_ours(NO_ANSWER), browser_headers=NO_ANSWER, browser=browser)
        assert survey.classify(row) == survey.Verdict("unfetchable", "dead-host")

    def test_html_everywhere(self) -> None:
        """Every client, the browser after waiting, got a page and no PDF."""
        row = _row(**_ours(HTML), browser_headers=HTML, browser=HTML)
        assert survey.classify(row) == survey.Verdict("unfetchable", "not-a-pdf")

    def test_refused_everywhere_is_left_open(self) -> None:
        """A 403 to the browser too could be a licence or a wall."""
        row = _row(**_ours(REFUSED), browser_headers=REFUSED, browser=REFUSED)
        assert survey.classify(row) == survey.Verdict("unclassified", "refused-everywhere")


class TestBrowserControl:
    """The browser is a bound only where it got what our clients got."""

    def test_an_app_served_and_the_browser_not(self) -> None:
        """Named, so the browser column is not read as a bound there."""
        rows = [
            _row(**_ours(PDF), browser=HTML),
            _row(**_ours(PDF), browser=PDF),
            _row(**_ours(REFUSED), browser=HTML),
        ]
        assert survey.browser_control(rows) == ["10.1/x"]


class TestReadPrefix:
    """A probe reads the start of a body and never the article."""

    def test_stops_at_the_limit(self) -> None:
        """No chunk after the one that reaches the limit is pulled."""
        pulled: list[int] = []

        def chunks() -> Iterator[bytes]:
            for index in range(100):
                pulled.append(index)
                yield b"x" * 10

        assert survey.read_prefix(chunks(), limit=25) == b"x" * 25
        assert pulled == [0, 1, 2]


class TestTheDesktopClientIsTheShippedOne:
    """The survey measures the app's own headers, not a copy of them."""

    def test_follows_the_module(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Changing the app's User-Agent changes what the survey sends."""
        from bmlibrarian_lite import pdf_discovery

        monkeypatch.setattr(pdf_discovery, "USER_AGENT", "Changed/9.9")

        assert survey.client_headers()["desktop"]["User-Agent"] == "Changed/9.9"


class _Handler(BaseHTTPRequestHandler):
    """A redirect to a PDF, and a Cloudflare-style challenge."""

    def do_GET(self) -> None:  # noqa: N802 - the http.server hook
        """Answer by path."""
        if self.path.startswith("/start"):
            self.send_response(302)
            self.send_header("Location", "/file.pdf?X-Amz-Signature=secret")
            self.end_headers()
        elif self.path.startswith("/file.pdf"):
            self.send_response(200)
            self.send_header("Content-Type", "application/pdf")
            self.end_headers()
            self.wfile.write(b"%PDF-1.7\n" + b"0" * 200_000)
        else:
            self.send_response(403)
            self.send_header("Content-Type", "text/html")
            self.send_header("cf-mitigated", "challenge")
            self.end_headers()
            self.wfile.write(b"<html><title>Just a moment...</title></html>")

    def log_message(self, *_args: Any) -> None:
        """Keep the test output quiet."""


@pytest.fixture
def server() -> Iterator[str]:
    """A loopback server (never paced), yielding its base URL."""
    httpd = HTTPServer(("127.0.0.1", 0), _Handler)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    try:
        yield f"http://127.0.0.1:{httpd.server_address[1]}"
    finally:
        httpd.shutdown()
        httpd.server_close()


class TestProbeHttp:
    """One request, described as the client received it."""

    def test_a_redirect_to_a_pdf(self, server: str) -> None:
        """Hops recorded; the final URL without its signature."""
        probe = survey.probe_http(f"{server}/start", survey.client_headers()["desktop"])

        assert probe["status"] == 200
        assert probe["pdf"] is True
        assert probe["hops"] == [[302, "127.0.0.1"]]
        assert probe["final_url"] == f"{server}/file.pdf"
        assert "secret" not in json.dumps(probe)

    def test_a_challenge(self, server: str) -> None:
        """The status and the defence its header names."""
        probe = survey.probe_http(f"{server}/wall", survey.client_headers()["android"])

        assert probe["status"] == 403
        assert probe["markers"] == ["cloudflare"]

    def test_no_answer(self) -> None:
        """A refused connection is no status, with its kind."""
        probe = survey.probe_http("http://127.0.0.1:9/", survey.client_headers()["apple"])

        assert probe["status"] is None
        assert probe["error"] == "ConnectionError"


class TestLoadSamples:
    """The sampling header is kept apart from the rows."""

    def test_header_and_rows(self, tmp_path: Path) -> None:
        """The first line is the header; every other line a row."""
        sample = tmp_path / "s.jsonl"
        sample.write_text(
            json.dumps({"sampling": {"epmc-oa": {"pdf-url": 1}}, "years": [2020, 2020], "seed": 1})
            + "\n"
            + json.dumps(_row(**_ours(PDF)))
            + "\n\n",
            encoding="utf-8",
        )

        rows, headers = survey.load_samples([sample])

        assert len(rows) == 1 and rows[0]["doi"] == "10.1/x"
        assert headers[0]["seed"] == 1


class TestBrowserCheckpoint:
    """A stopped browser stage resumes, and a harness failure is never a probe."""

    def test_a_cut_off_last_line_is_probed_again(self, tmp_path: Path) -> None:
        """A stop mid-write loses that address only."""
        checkpoint = tmp_path / "s.jsonl.browser"
        checkpoint.write_text(
            json.dumps({"doi": "10.1/a", "probe": PDF}) + "\n" + '{"doi": "10.1/b", "pro',
            encoding="utf-8",
        )

        assert list(survey.read_checkpoint(checkpoint)) == ["10.1/a"]

    def test_no_checkpoint_is_nothing_done(self, tmp_path: Path) -> None:
        """A first run starts from the top."""
        assert survey.read_checkpoint(tmp_path / "absent.browser") == {}

    def test_a_harness_failure_leaves_no_browser_probe(self) -> None:
        """So classify cannot read the harness's timeout as the host's answer."""
        rows = [
            {**_row(**_ours(REFUSED)), "doi": "10.1/a"},
            {**_row(**_ours(REFUSED)), "doi": "10.1/b"},
            {**_row(**_ours(REFUSED)), "doi": "10.1/c"},
        ]
        done = {"10.1/a": {"doi": "10.1/a", "probe": PDF}, "10.1/b": {"doi": "10.1/b", "harness_error": "timeout"}}

        merged = survey.merge_browser_probes(rows, done)

        assert merged[0]["probes"]["browser"] == PDF
        assert "browser" not in merged[1]["probes"]
        assert merged[1]["browser_harness_error"] == "timeout"
        assert survey.classify(merged[1]) == survey.Verdict("unclassified", "no-browser-probe")
        assert "browser" not in merged[2]["probes"] and "browser_harness_error" not in merged[2]

    def test_a_rerun_replaces_an_earlier_browser_probe(self) -> None:
        """Merging is from the checkpoint alone, and leaves the input rows alone."""
        row = {**_row(**_ours(REFUSED), browser=HTML), "browser_harness_error": "old"}
        merged = survey.merge_browser_probes([row], {"10.1/x": {"doi": "10.1/x", "probe": PDF}})

        assert merged[0]["probes"]["browser"] == PDF
        assert "browser_harness_error" not in merged[0]
        assert row["probes"]["browser"] == HTML

    def test_a_sample_is_written_whole_or_not_at_all(self, tmp_path: Path) -> None:
        """The previous file stays until the new one is complete."""
        sample = tmp_path / "s.jsonl"
        survey.write_sample(sample, {"sampling": {}, "seed": 1}, [_row(**_ours(PDF))])

        rows, headers = survey.load_samples([sample])

        assert headers == [{"sampling": {}, "seed": 1}] and len(rows) == 1
        assert not (tmp_path / "s.jsonl.partial").exists()

    def test_browse_on_a_finished_sample_reprobes_only_the_gaps(
        self, tmp_path: Path, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Probes already taken are kept, never re-asked of the host."""
        sample = tmp_path / "s.jsonl"
        probed = {**_row(**_ours(REFUSED), browser=HTML), "doi": "10.1/kept"}
        gap = {**_row(**_ours(REFUSED)), "doi": "10.1/gap", "browser_harness_error": "timeout"}
        survey.write_sample(sample, {"sampling": {}, "seed": 1}, [probed, gap])
        asked: list[str] = []

        async def fake_browse(rows: list[dict[str, Any]], checkpoint: Path) -> None:
            asked.extend(row["doi"] for row in rows)
            with checkpoint.open("a", encoding="utf-8") as sink:
                for row in rows:
                    sink.write(json.dumps({"doi": row["doi"], "probe": PDF}) + "\n")

        monkeypatch.setattr(survey, "_browse", fake_browse)
        survey.browse_sample(sample)

        rows, _ = survey.load_samples([sample])
        assert asked == ["10.1/gap"]
        assert rows[0]["probes"]["browser"] == HTML
        assert rows[1]["probes"]["browser"] == PDF and "browser_harness_error" not in rows[1]
        assert not survey.browser_checkpoint(sample).exists()


class TestCommittedSamples:
    """The figures in doc/developer/unpaywall_pdf_survey/README.md are these rows'."""

    @pytest.fixture(scope="class")
    def rows(self) -> list[dict[str, Any]]:
        """Both committed samples' rows.

        Returns:
            The rows.
        """
        assert [path.name for path in COMMITTED_SAMPLES] == [
            "2026-10-04-dev.jsonl",
            "2026-10-04-heldout.jsonl",
        ]
        return survey.load_samples(COMMITTED_SAMPLES)[0]

    def test_no_row_holds_a_credential_or_the_email(self) -> None:
        """Signed redirects lose their query; Unpaywall's request is never kept."""
        from urllib.parse import urlparse

        for path in COMMITTED_SAMPLES:
            text = path.read_text(encoding="utf-8")
            assert "email=" not in text and "api.unpaywall.org" not in text
            for line in text.splitlines():
                for probe in (json.loads(line).get("probes") or {}).values():
                    assert not urlparse(probe.get("final_url") or "").query

    def test_four_hundred_addresses(self, rows: list[dict[str, Any]]) -> None:
        """100 per stratum per sample."""
        strata = [(tuple(row["years"]), row["stratum"]) for row in rows]
        assert {key: strata.count(key) for key in set(strata)} == {
            ((2019, 2021), "epmc-oa"): 100,
            ((2019, 2021), "epmc-not-oa"): 100,
            ((2023, 2025), "epmc-oa"): 100,
            ((2023, 2025), "epmc-not-oa"): 100,
        }

    def test_served_by_client(self, rows: list[dict[str, Any]]) -> None:
        """The served table."""
        served = {
            client: sum(survey.served(row["probes"].get(client)) for row in rows)
            for client in survey.CLIENTS
        }
        assert served == {
            "desktop": 110,
            "android": 111,
            "apple": 116,
            "browser-headers": 88,
            "browser": 223,
        }
        assert sum("browser" in row["probes"] for row in rows) == 399

    def test_the_browser_control_holds(self, rows: list[dict[str, Any]]) -> None:
        """No address an app was served was refused to the browser."""
        assert survey.browser_control(rows) == []

    def test_the_desktops_families(self, rows: list[dict[str, Any]]) -> None:
        """The family table."""
        table = survey.family_table(rows, "desktop")
        families: dict[str, int] = {}
        for (family, _reason), count in table.items():
            families[family] = families.get(family, 0) + count
        assert families == {
            "served": 110,
            "bot-wall": 234,
            "unfetchable": 34,
            "our-client": 11,
            "unclassified": 11,
        }
        assert table[("bot-wall", "challenge-in-browser")] == 115
        assert table[("bot-wall", "js-challenge")] == 103
        assert table[("unfetchable", "no-free-pdf-behind-wall")] == 14

    def test_what_the_app_can_see(self, rows: list[dict[str, Any]]) -> None:
        """The run-time signal: challenged failures are walls 89% of the time."""
        table = survey.signal_table(rows, "desktop")
        challenged, plain = table["challenged"], table["not challenged"]

        assert sum(challenged.values()) == 264
        assert sum(n for verdict, n in challenged.items() if verdict.startswith("bot-wall/")) == 234
        assert sum(plain.values()) == 26
        assert sum(n for verdict, n in plain.items() if verdict.startswith("unfetchable/")) == 19
