# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""PMC's open-data bucket as a JATS source (#480, stage A).

The rows are the shared contract,
``doc/cross_platform/fulltext_parity/pmc_open_data.json``, read by the Swift
and Kotlin ports too. No test here touches the network.
"""

import json
from http import HTTPStatus
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.constants import (
    PMC_OPEN_DATA_BASE_URL,
    PMC_OPEN_DATA_HOST,
    POLITE_RATE_CEILINGS,
    SERVICE_PMC_OPEN_DATA,
)
from bmlibrarian_lite.data_models import RequestFailure, RequestFailureKind
from bmlibrarian_lite.fulltext_discovery import FulltextSourceType
from bmlibrarian_lite.pmc_open_data import (
    PmcOpenDataClient,
    PmcOpenDataFetch,
    PmcOpenDataRecord,
    https_url,
    latest_metadata_key,
)
from tests.scripted_http_server import (
    ScriptedAnswer,
    json_answer,
    running,
    status_answer,
    xml_answer,
)

CONTRACT: dict[str, Any] = json.loads(
    (
        Path(__file__).resolve().parents[1]
        / "doc"
        / "cross_platform"
        / "fulltext_parity"
        / "pmc_open_data.json"
    ).read_text(encoding="utf-8")
)


def test_the_names_are_the_contracts() -> None:
    """Service name, the source value the desktop emits, and base URL, verbatim."""
    assert SERVICE_PMC_OPEN_DATA == CONTRACT["service_name"]
    assert FulltextSourceType.PMC_OPEN_DATA_XML.value == CONTRACT["desktop_source_type"]
    assert PMC_OPEN_DATA_BASE_URL == CONTRACT["base_url"]


@pytest.mark.parametrize(
    "row", CONTRACT["latest_metadata_key"], ids=lambda row: row["name"]
)
def test_latest_metadata_key(row: dict[str, Any]) -> None:
    """The numerically highest version of this PMC ID's record, or none."""
    if "error" in row:
        with pytest.raises(ValueError):
            latest_metadata_key(row["listing"], row["pmcid"])
    else:
        assert latest_metadata_key(row["listing"], row["pmcid"]) == row["key"]


@pytest.mark.parametrize("row", CONTRACT["https_url"], ids=lambda row: row["name"])
def test_https_url(row: dict[str, Any]) -> None:
    """Only this bucket's s3:// URLs map, and the query is dropped."""
    assert https_url(row["s3_url"]) == row["https_url"]


@pytest.mark.parametrize("row", CONTRACT["record"], ids=lambda row: row["name"])
def test_record(row: dict[str, Any]) -> None:
    """What a metadata record says; an unreadable xml_url is not "no XML"."""
    if "error" in row:
        with pytest.raises(ValueError):
            PmcOpenDataRecord.from_metadata(row["metadata"])
        return
    record = PmcOpenDataRecord.from_metadata(row["metadata"])

    assert record.xml_url == row["xml_url"]
    assert record.is_open_access == row["is_open_access"]
    assert record.is_manuscript == row["is_manuscript"]
    assert record.license_code == row["license_code"]


@pytest.mark.parametrize("value", [[], "text", 3, None])
def test_a_record_that_is_not_an_object_is_refused(value: object) -> None:
    """Unreadable, not empty: the caller records malformed_response."""
    with pytest.raises(ValueError):
        PmcOpenDataRecord.from_metadata(value)


def test_the_pacing_ceiling_is_pinned_to_the_host() -> None:
    """The ceiling table repeats the host as a literal; keep them in step."""
    assert POLITE_RATE_CEILINGS[PMC_OPEN_DATA_HOST] == 5.0


_PMCID = "PMC10358571"
_LISTING = CONTRACT["latest_metadata_key"][0]["listing"]
_KEY_PATH = "/metadata/PMC10358571.1.json"
_XML_PATH = "/PMC10358571.1/PMC10358571.1.xml"
_ARTICLE = "<article><body><p>The study.</p></body></article>"


def _metadata() -> ScriptedAnswer:
    """A record whose XML lives on the scripted server's XML path."""
    return json_answer(
        {
            "pmcid": _PMCID,
            "is_pmc_openaccess": True,
            "xml_url": f"s3://pmc-oa-opendata{_XML_PATH}?md5=abc",
        }
    )


def _client(url: str) -> PmcOpenDataClient:
    """A client on the scripted server, without retries, so tests do not sleep."""
    return PmcOpenDataClient(base_url=url, max_retries=0)


class TestFetchXml:
    """The three steps, each status, and what each settles."""

    def test_served(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """Listing, record, XML: the article's text."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [xml_answer(_ARTICLE)]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.served(_ARTICLE)

    def test_not_in_the_collection_is_absent(self) -> None:
        """KeyCount 0 is an answer: nothing recorded."""
        empty = CONTRACT["latest_metadata_key"][2]["listing"]
        with running({"/": [xml_answer(empty)]}) as server:
            fetch = _client(server.url).fetch_xml("PMC99999999")

        assert fetch == PmcOpenDataFetch.absent()

    @pytest.mark.parametrize(
        "row",
        [r for r in CONTRACT["status"] if r["status"] != 200],
        ids=lambda r: f"{r['step']}-{r['status']}",
    )
    def test_each_status_settles_what_the_contract_says(
        self, row: dict[str, Any], monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Every non-200 is unreachable with its status, a listing 404 included.

        S3 answers a prefix naming nothing with a 200 and no keys; a listing
        404 is ``NoSuchBucket``, which says nothing about the article.
        """
        script: dict[str, list[ScriptedAnswer]] = {
            "/": [xml_answer(_LISTING)],
            _KEY_PATH: [_metadata()],
            _XML_PATH: [xml_answer(_ARTICLE)],
        }
        path = {"listing": "/", "metadata": _KEY_PATH, "xml": _XML_PATH}[row["step"]]
        script[path] = [status_answer(HTTPStatus(row["status"]))]
        with running(script) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        if row["outcome"] == "absent":
            assert fetch == PmcOpenDataFetch.absent()
        else:
            assert fetch == PmcOpenDataFetch.unreachable(
                RequestFailure(RequestFailureKind.HTTP_STATUS, row["status"])
            )

    def test_a_throttle_is_asked_again(self) -> None:
        """The client's own policy: a 503 is retried, and the answer read."""
        empty = CONTRACT["latest_metadata_key"][2]["listing"]
        with running(
            {"/": [status_answer(HTTPStatus.SERVICE_UNAVAILABLE), xml_answer(empty)]}
        ) as server:
            fetch = PmcOpenDataClient(base_url=server.url, max_retries=1).fetch_xml(_PMCID)
            asked = len(server.requests_to("/"))

        assert fetch == PmcOpenDataFetch.absent()
        assert asked == 2

    def test_control_a_404_is_an_answer_and_not_asked_again(self) -> None:
        """The same client: a listing 404 is not retried, and stays unreachable."""
        with running({"/": [status_answer(HTTPStatus.NOT_FOUND)]}) as server:
            fetch = PmcOpenDataClient(base_url=server.url, max_retries=1).fetch_xml(_PMCID)
            asked = len(server.requests_to("/"))

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.HTTP_STATUS, HTTPStatus.NOT_FOUND)
        )
        assert asked == 1

    def test_a_jats_body_where_a_listing_should_be_is_malformed(self) -> None:
        """A catch-all stub's article reads as an unreadable answer, not a crash."""
        with running({"/": [xml_answer(_ARTICLE)]}) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_record_without_xml_is_absent(self) -> None:
        """No XML named: an answer about this source, the chain goes on."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [json_answer({"is_pmc_openaccess": True})]}
        ) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.absent()

    def test_a_record_naming_xml_elsewhere_is_malformed(self) -> None:
        """It named XML and we cannot read where: unreadable, not absent (#486)."""
        record = json_answer({"xml_url": "s3://some-other-bucket/PMC1.1/PMC1.1.xml"})
        with running({"/": [xml_answer(_LISTING)], _KEY_PATH: [record]}) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_listing_naming_only_unreadable_versions_is_malformed(self) -> None:
        """The article is listed and we cannot read which version: not absent."""
        listing = next(
            row["listing"]
            for row in CONTRACT["latest_metadata_key"]
            if row["name"].startswith("unparseable version")
        )
        with running({"/": [xml_answer(listing)]}) as server:
            fetch = _client(server.url).fetch_xml("PMC123")

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_record_that_is_not_utf8_is_malformed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """The record is decoded as the listing and the XML are, never guessed."""
        # The bad byte is in a field we do not need: guessing a charset
        # would read past it and serve the article.
        body = (
            f'{{"xml_url": "s3://pmc-oa-opendata{_XML_PATH}", "license_code": "'
        ).encode() + b'\xff"}'
        answer = ScriptedAnswer(HTTPStatus.OK, body, "binary/octet-stream")
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [answer], _XML_PATH: [xml_answer(_ARTICLE)]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_record_that_is_not_json_is_malformed(self) -> None:
        """Unreadable is not absent."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [xml_answer("<not-json/>")]}
        ) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_blank_article_is_incomplete(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """An empty answer told us nothing about the article."""
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [xml_answer("  ")]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.INCOMPLETE_RESPONSE)
        )

    def test_no_server_is_unreachable(self) -> None:
        """A refused connection is a transport failure, never an absence."""
        fetch = _client("http://127.0.0.1:9").fetch_xml(_PMCID)

        assert fetch.is_unreachable
        assert fetch.failure is not None and fetch.failure.kind is RequestFailureKind.CONNECTION

    @pytest.mark.parametrize("identifier", ["PPR1316954", "10.1/x", "", "PMC"])
    def test_not_a_pmc_id_is_never_asked(self, identifier: str) -> None:
        """A preprint or a DOI has no record in the bucket: no request at all."""
        with running({}) as server:
            fetch = _client(server.url).fetch_xml(identifier)
            assert server.received == []

        assert fetch == PmcOpenDataFetch.absent()

    def test_the_listing_asks_for_this_articles_prefix(self) -> None:
        """The request names exactly ``metadata/{PMCID}.``."""
        empty = CONTRACT["latest_metadata_key"][2]["listing"]
        with running({"/": [xml_answer(empty)]}) as server:
            _client(server.url).fetch_xml("10358571")
            parameters = server.requests_to("/")[0].parameters

        assert parameters == {"list-type": ["2"], "prefix": ["metadata/PMC10358571."]}

    def test_non_ascii_text_survives_an_unlabelled_body(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """S3 sends binary/octet-stream with no charset: the text is not guessed."""
        article = "<article><body><p>Müller’s cohort — 95 % CI</p></body></article>"
        answer = ScriptedAnswer(HTTPStatus.OK, article.encode("utf-8"), "binary/octet-stream")
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [answer]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.served(article)

    def test_a_body_that_is_not_utf8_is_malformed(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Unreadable is not absent, and never mojibake."""
        answer = ScriptedAnswer(
            HTTPStatus.OK, b"<article>\xff\xfe</article>", "binary/octet-stream"
        )
        with running(
            {"/": [xml_answer(_LISTING)], _KEY_PATH: [_metadata()], _XML_PATH: [answer]}
        ) as server:
            monkeypatch.setattr(
                "bmlibrarian_lite.pmc_open_data.PMC_OPEN_DATA_BASE_URL", server.url
            )
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )

    def test_a_listing_that_is_not_utf8_is_malformed(self) -> None:
        """The same rule for the listing."""
        answer = ScriptedAnswer(HTTPStatus.OK, b"\xff\xfe", "binary/octet-stream")
        with running({"/": [answer]}) as server:
            fetch = _client(server.url).fetch_xml(_PMCID)

        assert fetch == PmcOpenDataFetch.unreachable(
            RequestFailure(RequestFailureKind.MALFORMED_RESPONSE)
        )


class TestFetchInvariants:
    """The typed fetch refuses states that mean two things."""

    def test_served_and_unreachable_at_once_is_refused(self) -> None:
        """Never both."""
        with pytest.raises(ValueError):
            PmcOpenDataFetch(xml="<a/>", failure=RequestFailure(RequestFailureKind.TIMEOUT))

    def test_blank_served_xml_is_refused(self) -> None:
        """A blank text is incomplete, not served."""
        with pytest.raises(ValueError):
            PmcOpenDataFetch.served("   ")
