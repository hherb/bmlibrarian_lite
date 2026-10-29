"""Tests for the local Retraction Watch copy (no network: a stub session)."""

from datetime import date, timedelta

import pytest

from bmlibrarian_lite.retraction_export import (
    ExportState,
    export_copy,
    export_evidence,
    refresh_export,
)

_HEADER = (
    "Record ID,Title,Subject,Institution,Journal,Publisher,Country,Author,URLS,"
    "ArticleType,RetractionDate,RetractionDOI,RetractionPubMedID,OriginalPaperDate,"
    "OriginalPaperDOI,OriginalPaperPubMedID,RetractionNature,Reason,Paywalled,Notes,\n"
)
_ROW = (
    "1,A paper,Subject,Inst,Soft Computing,Pub,AU,Author,URL,Article,"
    "3/9/2026 0:00,10.1/notice,87654321,5/6/2023 0:00,10.1/paper,12345678,"
    "Retraction,Rogue Editor;,No,Notes,\n"
)
CSV = (_HEADER + _ROW).encode()
TODAY = date(2026, 10, 18)


class _Response:
    def __init__(self, status: int, body: bytes, headers: dict | None = None) -> None:
        self.headers = headers or {}
        self.status_code = status
        self._body = body

    def iter_content(self, size: int):
        yield self._body

    def close(self) -> None:
        pass


class _Session:
    def __init__(self, status: int = 200, body: bytes = CSV, headers: dict | None = None) -> None:
        self.status, self.body, self.headers, self.calls = status, body, headers, []

    def get(self, url, **kwargs):
        self.calls.append((url, kwargs))
        return _Response(self.status, self.body, self.headers)


def _refresh(tmp_path, session, today=TODAY):
    return refresh_export(tmp_path, session, mailto="a@b.c", today=today)


def test_refresh_builds_a_current_copy(tmp_path):
    """A refresh yields a current, queryable copy."""
    session = _Session()
    copy = _refresh(tmp_path, session, today=TODAY)
    assert copy.state is ExportState.CURRENT and copy.data_as_of == TODAY
    assert session.calls[0][1]["params"] == {"mailto": "a@b.c"}
    evidence = export_evidence(tmp_path, doi="10.1/paper", pmid=None, today=TODAY)
    assert evidence
    assert not list(tmp_path.glob("*.part")) and not list(tmp_path.glob("*.new"))


@pytest.mark.parametrize(
    "bad",
    [
        _Session(body=b"<html><body>Please wait</body></html>"),
        _Session(body=_HEADER.encode()[:40]),
        _Session(body=_HEADER.encode()),
        _Session(status=503, body=b""),
        # a renamed RetractionNature column: every notice would read "Other"
        _Session(body=(_HEADER.replace("RetractionNature", "NoticeKind") + _ROW).encode()),
        # a row cut part-way, as a truncated download leaves it
        _Session(body=(_HEADER + _ROW + _ROW.replace("1,", "2,", 1)[:60]).encode()),
    ],
)
def test_a_refused_download_keeps_the_previous_copy(tmp_path, bad):
    """A refused download leaves the earlier file byte-identical."""
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=3))
    db = tmp_path / "retraction_watch.db"
    before = db.read_bytes()
    copy = _refresh(tmp_path, bad)
    assert db.read_bytes() == before
    assert copy.state is ExportState.CURRENT and copy.data_as_of == TODAY - timedelta(days=3)
    assert sorted(p.name for p in tmp_path.iterdir()) == ["retraction_watch.db"]


def test_a_copy_older_than_35_days_is_stale_and_not_consulted(tmp_path):
    """Day 35 is current, day 36 stale and unconsulted."""
    _refresh(tmp_path, _Session(), today=TODAY)
    assert export_copy(tmp_path, today=TODAY + timedelta(days=35)).state is ExportState.CURRENT
    stale = export_copy(tmp_path, today=TODAY + timedelta(days=36))
    assert stale.state is ExportState.STALE and not stale.consulted
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=36))
    assert export_evidence(tmp_path, doi="10.1/paper", pmid=None, today=TODAY) is None


def test_missing_and_unreadable_copies_are_not_consulted(tmp_path):
    """A missing or garbage file is never consulted."""
    assert export_copy(tmp_path, today=TODAY).state is ExportState.MISSING
    assert export_evidence(tmp_path, doi="10.1/paper", pmid=None, today=TODAY) is None
    (tmp_path / "retraction_watch.db").write_bytes(b"garbage" * 100)
    copy = export_copy(tmp_path, today=TODAY)
    assert copy.state is ExportState.UNREADABLE and not copy.consulted
    assert export_evidence(tmp_path, doi="10.1/paper", pmid=None, today=TODAY) is None


def test_no_identifier_is_not_consulted(tmp_path):
    """No usable identifier reads as not consulted."""
    _refresh(tmp_path, _Session(), today=TODAY)
    assert export_evidence(tmp_path, doi=None, pmid=None, today=TODAY) is None
    assert export_evidence(tmp_path, doi=None, pmid="abc", today=TODAY) is None


def test_a_found_nothing_lookup_is_consulted(tmp_path):
    """An export that knows nothing of the paper answers an empty list."""
    _refresh(tmp_path, _Session(), today=TODAY)
    assert export_evidence(tmp_path, doi="10.9/other", pmid=None, today=TODAY) == []


def _rows(n: int) -> bytes:
    return (_HEADER + "".join(
        _ROW.replace("10.1/paper", f"10.1/p{i}").replace("12345678", str(1000 + i)).replace("1,A", f"{i},A", 1)
        for i in range(n)
    )).encode()


def _assert_untouched(tmp_path, before):
    assert (tmp_path / "retraction_watch.db").read_bytes() == before
    assert sorted(p.name for p in tmp_path.iterdir()) == ["retraction_watch.db"]


def test_a_content_length_mismatch_is_refused(tmp_path):
    """A download shorter than it declared never replaces the copy."""
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=3))
    before = (tmp_path / "retraction_watch.db").read_bytes()
    _refresh(tmp_path, _Session(headers={"Content-Length": str(len(CSV) + 10)}))
    _assert_untouched(tmp_path, before)


@pytest.mark.parametrize("kept,accepted", [(90, False), (96, True)])
def test_a_shrunken_export_is_refused_but_a_slightly_smaller_one_is_not(tmp_path, kept, accepted):
    """Under 95% of the held notices is a partial download; 96% is accepted."""
    _refresh(tmp_path, _Session(body=_rows(100)), today=TODAY - timedelta(days=3))
    before = (tmp_path / "retraction_watch.db").read_bytes()
    copy = _refresh(tmp_path, _Session(body=_rows(kept)))
    if accepted:
        assert copy.data_as_of == TODAY
    else:
        _assert_untouched(tmp_path, before)


def test_a_failure_mid_stream_keeps_the_previous_copy(tmp_path):
    """A connection dropped mid-body leaves the old file and no temporaries."""
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=3))
    before = (tmp_path / "retraction_watch.db").read_bytes()

    class _Dropped(_Response):
        def iter_content(self, size):
            yield CSV[:50]
            raise OSError("connection reset")

    class _S(_Session):
        def get(self, url, **kw):
            return _Dropped(200, b"")

    _refresh(tmp_path, _S())
    _assert_untouched(tmp_path, before)


def test_a_store_error_keeps_the_previous_copy(tmp_path, monkeypatch):
    """An error while storing leaves the old file and no temporaries."""
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=3))
    before = (tmp_path / "retraction_watch.db").read_bytes()

    def boom(conn, source):
        raise RuntimeError("disk full")

    monkeypatch.setattr("bmlibrarian_lite.retraction_export.import_retraction_watch_export", boom)
    _refresh(tmp_path, _Session())
    _assert_untouched(tmp_path, before)


def test_a_gzip_encoded_response_is_not_judged_by_content_length(tmp_path):
    """Content-Length counts compressed bytes, so it cannot refuse a decoded body."""
    session = _Session(headers={"Content-Encoding": "gzip", "Content-Length": "7"})
    copy = _refresh(tmp_path, session)
    assert copy.state is ExportState.CURRENT and copy.data_as_of == TODAY


def test_a_cancel_during_the_download_stops_it_and_keeps_the_old_copy(tmp_path):
    """The chunk loop honours should_cancel: no more chunks read, no temporaries, old copy kept."""
    _refresh(tmp_path, _Session(), today=TODAY - timedelta(days=3))
    before = (tmp_path / "retraction_watch.db").read_bytes()
    read: list[int] = []
    cancelled = []

    class _Chunked(_Response):
        def iter_content(self, size):
            for i in range(5):
                read.append(i)
                if i == 1:
                    cancelled.append(True)  # Cancel pressed while chunk 1 arrives
                yield CSV[i * 10 : (i + 1) * 10]

    class _S(_Session):
        def get(self, url, **kw):
            return _Chunked(200, b"")

    copy = refresh_export(
        tmp_path, _S(), mailto="a@b.c", today=TODAY, should_cancel=lambda: bool(cancelled)
    )
    assert read == [0, 1]
    assert copy.data_as_of == TODAY - timedelta(days=3)
    _assert_untouched(tmp_path, before)


def test_a_refresh_leaves_another_refreshs_temporaries_alone(tmp_path):
    """Temporaries are unique to the call: a concurrent refresh's files are not touched."""
    theirs = {
        name: f"{name} in progress".encode()
        for name in ("retraction_watch.db.part", "retraction_watch.db.new")
    }
    for name, body in theirs.items():
        (tmp_path / name).write_bytes(body)
    copy = _refresh(tmp_path, _Session())
    assert copy.state is ExportState.CURRENT
    for name, body in theirs.items():
        assert (tmp_path / name).read_bytes() == body
    assert sorted(p.name for p in tmp_path.iterdir()) == sorted(["retraction_watch.db", *theirs])


def test_a_notice_row_bmlib_cannot_read_is_not_consulted_and_logged(
    tmp_path, monkeypatch, caplog
):
    """A row bmlib refuses on purpose is not absence, and not silent."""
    from bmlibrarian_lite import retraction_export

    _refresh(tmp_path, _Session())

    def unreadable(*_args, **_kwargs):
        raise ValueError("unknown retraction nature")

    monkeypatch.setattr(retraction_export, "lookup_retractions", unreadable)
    assert export_evidence(tmp_path, doi="10.1/paper", pmid=None, today=TODAY) is None
    assert "could not be read" in caplog.text
