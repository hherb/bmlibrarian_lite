"""Stored retraction verdicts and the checker (stub sessions, never the network)."""

from __future__ import annotations

import json
import sqlite3
from datetime import UTC, datetime, timedelta

import pytest
import requests
from bmlib.publications.retraction_status import (
    RetractionEvidence,
    RetractionKind,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
)

from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import RETRACTION_WATCH_EXPORT_URL
from bmlibrarian_lite.data_models import LiteDocument, RequestFailure, RequestFailureKind
from bmlibrarian_lite.retraction_checks import PaperCheck, RetractionChecker, paper_key
from bmlibrarian_lite.retraction_export import ExportState, refresh_export
from bmlibrarian_lite.storage import LiteStorage

_HEADER = (
    "Record ID,Title,Subject,Institution,Journal,Publisher,Country,Author,URLS,"
    "ArticleType,RetractionDate,RetractionDOI,RetractionPubMedID,OriginalPaperDate,"
    "OriginalPaperDOI,OriginalPaperPubMedID,RetractionNature,Reason,Paywalled,Notes,\n"
)
_ROW = (
    "1,A paper,Subject,Inst,Journal,Pub,AU,Author,URL,Article,"
    "3/9/2026 0:00,10.9/notice,87654321,5/6/2023 0:00,10.9/retracted,12345678,"
    "Retraction,Reason;,No,Notes,\n"
)
_CONCERN_ROW = (
    "2,Another,Subject,Inst,Journal,Pub,AU,Author,URL,Article,"
    "3/9/2026 0:00,10.9/eoc,22222223,5/6/2023 0:00,10.9/concern,22222222,"
    "Expression of concern,Reason;,No,Notes,\n"
)
CSV = (_HEADER + _ROW + _CONCERN_ROW).encode()
START = datetime(2026, 10, 18, 12, 0, tzinfo=UTC)
MAILTO = "t@example.org"


class _Response:
    def __init__(self, status: int, body: bytes) -> None:
        self.status_code, self._body, self.headers = status, body, {}
        self.content = body

    def iter_content(self, size: int):
        yield self._body

    def close(self) -> None:
        pass


def _served(url: str) -> _Response:
    filters = url.split("filter=")[1].split("&")[0]
    items = [{"DOI": f.removeprefix("doi:")} for f in filters.split(",")]
    body = {"status": "ok", "message-type": "work-list", "message": {"items": items}}
    return _Response(200, json.dumps(body).encode())


class StubSession:
    """The export answers ``export_status``; Crossref answers by ``crossref``."""

    def __init__(self, crossref=_served, export_status: int = 200) -> None:
        """Keep the answers; count the calls."""
        self.crossref, self.export_status = crossref, export_status
        self.crossref_urls: list[str] = []
        self.export_calls = 0

    def get(self, url, **kwargs):
        """Answer the export or Crossref."""
        if url.startswith(RETRACTION_WATCH_EXPORT_URL):
            self.export_calls += 1
            return _Response(self.export_status, CSV)
        self.crossref_urls.append(url)
        result = self.crossref(url)
        if isinstance(result, Exception):
            raise result
        return result

    def close(self) -> None:
        """A checker built for one use closes its session."""


def _unreachable(url: str):
    return requests.ConnectionError("down")


class Clock:
    """A clock the test moves."""

    def __init__(self) -> None:
        """Start at START."""
        self.now = START

    def __call__(self) -> datetime:
        """The current time."""
        return self.now


@pytest.fixture
def storage(tmp_path):
    """A fresh store under tmp_path."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path / "store"
    return LiteStorage(config)


def _current_export(tmp_path) -> None:
    copy = refresh_export(tmp_path, StubSession(), mailto=MAILTO, today=START.date())
    assert copy.state is ExportState.CURRENT


def _doc(doc_id: str, doi: str | None = None, pmid: str | None = None, types=None):
    return LiteDocument(
        id=doc_id, title="t", abstract="a", doi=doi, pmid=pmid, publication_types=types
    )


def _checker(storage, tmp_path, session, clock=None, refresh_export=True):
    return RetractionChecker(
        storage, tmp_path, session, mailto=MAILTO, now=clock or Clock(), refresh_export=refresh_export
    )


def test_documents_sharing_a_doi_are_asked_once(storage, tmp_path):
    """Two spellings of one DOI make one request, and both ids get the verdict."""
    _current_export(tmp_path)
    session = StubSession()
    docs = [_doc("a", doi="10.1/A"), _doc("b", doi="https://doi.org/10.1/a")]
    out = _checker(storage, tmp_path, session).check(docs)
    assert len(session.crossref_urls) == 1
    assert session.crossref_urls[0].count("doi:") == 1
    assert out["a"].verdict.status is RetractionStatus.CLEAR
    assert out["a"] == out["b"]


def test_a_stored_verdict_younger_than_7_days_is_reused(storage, tmp_path):
    """Reused up to 7 days; asked again at 7 days + 1 s, and always on refresh."""
    _current_export(tmp_path)
    session, clock = StubSession(), Clock()
    checker = _checker(storage, tmp_path, session, clock)
    docs = [_doc("a", doi="10.1/a")]
    first = checker.check(docs)["a"]
    clock.now = START + timedelta(days=7)
    assert checker.check(docs)["a"] == first
    assert len(session.crossref_urls) == 1
    assert len(_checker(storage, tmp_path, session, clock).check(docs, refresh=True)) == 1
    assert len(session.crossref_urls) == 2
    clock.now = START + timedelta(days=14, seconds=1)
    later = checker.check(docs)["a"]
    assert len(session.crossref_urls) == 3
    assert later.checked_at == clock.now


def test_unchecked_is_never_stored_as_clear(storage, tmp_path):
    """Crossref unreachable: a stored unchecked with its failure; served: clear."""
    _current_export(tmp_path)
    docs = [_doc("a", doi="10.1/a")]
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check(docs)
    check = out["a"]
    assert check.verdict.status is RetractionStatus.UNCHECKED
    assert check.verdict.unanswered == (RetractionLookup.CROSSREF,)
    assert check.crossref_failure == RequestFailure(RequestFailureKind.CONNECTION)
    stored = storage.retraction_checks(["doi:10.1/a"])["doi:10.1/a"]
    assert stored.verdict.status is RetractionStatus.UNCHECKED
    assert stored.crossref_failure == RequestFailure(RequestFailureKind.CONNECTION)
    # control: the served path decides clear, and the export date is kept
    served = _checker(storage, tmp_path, StubSession()).check(docs)["a"]
    assert served.verdict.status is RetractionStatus.CLEAR
    assert served.crossref_failure is None
    assert served.export_data_as_of == START.date()
    stored = storage.retraction_checks(["doi:10.1/a"])["doi:10.1/a"]
    assert stored == served


def test_an_unconsulted_export_is_never_clear(storage, tmp_path):
    """Crossref served but the export missing and its refresh refused: unchecked."""
    session = StubSession(export_status=500)
    check = _checker(storage, tmp_path, session).check([_doc("a", doi="10.1/a")])["a"]
    assert check.verdict.status is RetractionStatus.UNCHECKED
    assert check.verdict.unanswered == (RetractionLookup.RETRACTION_WATCH_EXPORT,)
    assert check.export_data_as_of is None


def test_a_stored_unchecked_row_is_asked_again_on_every_check(storage, tmp_path):
    """A failure is not knowledge: the next check, minutes later, asks again."""
    _current_export(tmp_path)
    session, clock = StubSession(_unreachable), Clock()
    checker = _checker(storage, tmp_path, session, clock)
    docs = [_doc("a", doi="10.1/a")]
    checker.check(docs)
    clock.now = START + timedelta(minutes=1)
    session.crossref = _served
    assert checker.check(docs)["a"].verdict.status is RetractionStatus.CLEAR
    assert len(session.crossref_urls) == 2
    # control: a decided row is not asked again a minute later
    clock.now = START + timedelta(minutes=2)
    checker.check(docs)
    assert len(session.crossref_urls) == 2


def test_ensure_export_downloads_once_per_checker_when_stale(storage, tmp_path):
    """A failed refresh is not retried by the same checker."""
    session = StubSession(export_status=500)
    checker = _checker(storage, tmp_path, session)
    assert checker.ensure_export().state is ExportState.MISSING
    assert checker.ensure_export().state is ExportState.MISSING
    checker.check([_doc("a", doi="10.1/a")])
    assert session.export_calls == 1
    # control: a new checker tries again, and a served download makes it current
    session.export_status = 200
    assert _checker(storage, tmp_path, session).ensure_export().state is ExportState.CURRENT
    assert session.export_calls == 2


def test_a_current_export_is_not_downloaded(storage, tmp_path):
    """A current copy is used as it is."""
    _current_export(tmp_path)
    session = StubSession()
    assert _checker(storage, tmp_path, session).ensure_export().state is ExportState.CURRENT
    assert session.export_calls == 0


def test_the_export_decides_retracted(storage, tmp_path):
    """A paper the export holds is retracted, found by DOI or by PMID alone."""
    _current_export(tmp_path)
    docs = [_doc("a", doi="10.9/retracted"), _doc("b", pmid="12345678")]
    out = _checker(storage, tmp_path, StubSession()).check(docs)
    assert out["a"].verdict.status is RetractionStatus.RETRACTED
    assert out["b"].verdict.status is RetractionStatus.RETRACTED
    assert out["b"].verdict.deciding is not None
    stored = storage.retraction_checks(["pmid:12345678"])["pmid:12345678"]
    assert stored.verdict == out["b"].verdict


def test_label_alone_retracts_with_everything_unreachable(storage, tmp_path):
    """PubMed's label retracts with no export and Crossref down."""
    session = StubSession(_unreachable, export_status=500)
    doc = _doc("a", doi="10.1/a", types=["Retracted Publication"])
    check = _checker(storage, tmp_path, session).check([doc])["a"]
    assert check.verdict.status is RetractionStatus.RETRACTED
    # control: without the label, the same failures leave it unchecked
    plain = _checker(storage, tmp_path, session).check([_doc("b", doi="10.1/b")])["b"]
    assert plain.verdict.status is RetractionStatus.UNCHECKED


def test_a_new_retracted_label_overrides_a_stored_clear(storage, tmp_path):
    """A record now labelled retracted is checked again despite a fresh clear row."""
    _current_export(tmp_path)
    session = StubSession()
    checker = _checker(storage, tmp_path, session)
    checker.check([_doc("a", doi="10.1/a")])
    labelled = _doc("a", doi="10.1/a", types=["Retracted Publication"])
    assert checker.check([labelled])["a"].verdict.status is RetractionStatus.RETRACTED
    assert len(session.crossref_urls) == 2


def test_no_key_is_computed_and_not_stored(storage, tmp_path):
    """No DOI and no canonical PMID: a verdict, unchecked, never stored."""
    _current_export(tmp_path)
    session = StubSession()
    docs = [_doc("none"), _doc("bad", pmid="PMID:123"), _doc("pmc", pmid="PMC123")]
    out = _checker(storage, tmp_path, session).check(docs)
    assert {d: c.verdict.status for d, c in out.items()} == {
        "none": RetractionStatus.UNCHECKED,
        "bad": RetractionStatus.UNCHECKED,
        "pmc": RetractionStatus.UNCHECKED,
    }
    assert [paper_key(d) for d in docs] == [None, None, None]
    assert session.crossref_urls == []
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        assert conn.execute("SELECT COUNT(*) FROM retraction_checks").fetchone()[0] == 0


def test_paper_key_prefers_the_doi_then_the_canonical_pmid():
    """The DOI's Crossref key first; else the PMID without leading zeros."""
    assert paper_key(_doc("a", doi=" https://doi.org/10.1/AB ", pmid="1")) == "doi:10.1/ab"
    assert paper_key(_doc("a", pmid="0012345")) == "pmid:12345"


def test_a_cancelled_check_stores_only_decided_rows(storage, tmp_path):
    """No row for a paper whose batch was never asked; a PMID-only paper is decided."""
    _current_export(tmp_path)
    session = StubSession()
    docs = [_doc("a", doi="10.1/a"), _doc("b", pmid="12345678")]
    out = _checker(storage, tmp_path, session).check(docs, should_cancel=lambda: True)
    assert session.crossref_urls == []
    assert set(out) == {"b"}
    assert storage.retraction_checks(["doi:10.1/a", "pmid:12345678"]).keys() == {"pmid:12345678"}


def test_an_unreadable_stored_row_is_checked_again(storage, tmp_path):
    """A row this build cannot read is no verdict: the paper is asked again."""
    _current_export(tmp_path)
    session = StubSession()
    checker = _checker(storage, tmp_path, session)
    docs = [_doc("a", doi="10.1/a")]
    checker.check(docs)
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        conn.execute("UPDATE retraction_checks SET status = 'maybe'")
    assert checker.check(docs)["a"].verdict.status is RetractionStatus.CLEAR
    assert len(session.crossref_urls) == 2


def test_schema_is_idempotent(tmp_path):
    """Opening storage twice keeps the table and its rows."""
    config = LiteConfig()
    config.storage.data_dir = tmp_path / "store"
    _current_export(tmp_path)
    _checker(LiteStorage(config), tmp_path, StubSession()).check([_doc("a", doi="10.1/a")])
    again = LiteStorage(config)
    assert again.retraction_checks(["doi:10.1/a"])["doi:10.1/a"].verdict.status is (
        RetractionStatus.CLEAR
    )


_NOTICE = RetractionEvidence(RetractionSource.CROSSREF_PUBLISHER, RetractionKind.RETRACTION, "2026-01")
_CONCERN = RetractionEvidence(
    RetractionSource.CROSSREF_PUBLISHER, RetractionKind.EXPRESSION_OF_CONCERN, "2026-01"
)
_KEY = "doi:10.1/a"


def _store(storage, status, deciding=None, unanswered=(), age=timedelta(days=8), key=_KEY):
    """Store a crafted verdict under *key*, checked *age* before START."""
    check = PaperCheck(
        RetractionVerdict(status, deciding, tuple(unanswered)), START - age, START.date(), None
    )
    storage.store_retraction_checks({key: check})
    return check


def test_an_outage_never_erases_a_stored_retraction(storage, tmp_path):
    """Crossref down on the re-check: the row is unchanged and still says retracted."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.RETRACTED, _NOTICE)
    session = StubSession(_unreachable)
    out = _checker(storage, tmp_path, session).check([_doc("a", doi="10.1/a")])
    assert out["a"] == old
    assert storage.retraction_checks([_KEY])[_KEY] == old
    assert len(session.crossref_urls) == 1


def test_an_outage_does_not_extend_a_stored_clear(storage, tmp_path):
    """An expired clear is kept as it was, but the reader is told unchecked, and why."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.CLEAR)
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check([_doc("a", doi="10.1/a")])
    assert out["a"].verdict.status is RetractionStatus.UNCHECKED
    assert out["a"].crossref_failure == RequestFailure(RequestFailureKind.CONNECTION)
    assert storage.retraction_checks([_KEY])[_KEY] == old


def test_a_new_answer_replaces_a_stored_concern(storage, tmp_path):
    """Control: an answered re-check overwrites, here a concern Crossref no longer holds."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.CONCERN, _CONCERN)
    out = _checker(storage, tmp_path, StubSession()).check([_doc("a", doi="10.1/a")])
    assert out["a"].verdict.status is RetractionStatus.CLEAR
    assert storage.retraction_checks([_KEY])[_KEY] == out["a"]


def test_a_decided_verdict_with_a_lookup_unanswered_is_asked_again(storage, tmp_path):
    """A fresh concern is reused only when every lookup answered it."""
    _current_export(tmp_path)
    session = StubSession()
    docs = [_doc("a", doi="10.1/a")]
    _store(storage, RetractionStatus.CONCERN, _CONCERN, age=timedelta(hours=1))
    _checker(storage, tmp_path, session).check(docs)
    assert session.crossref_urls == []
    _store(storage, RetractionStatus.CONCERN, _CONCERN, [RetractionLookup.CROSSREF], timedelta(hours=1))
    _checker(storage, tmp_path, session).check(docs)
    assert len(session.crossref_urls) == 1


def test_a_cancelled_check_does_not_download_the_export(storage, tmp_path):
    """A cancel never waits for the export; a check not cancelled downloads it."""
    session = StubSession()
    docs = [_doc("a", doi="10.1/a")]
    _checker(storage, tmp_path, session).check(docs, should_cancel=lambda: True)
    assert session.export_calls == 0
    _checker(storage, tmp_path, session).check(docs)
    assert session.export_calls == 1


def _recheck(storage, tmp_path, doc, refresh=False):
    """Re-check *doc* with Crossref down; return the check and the stored row."""
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check([doc], refresh=refresh)
    key = paper_key(doc)
    return out[doc.id], storage.retraction_checks([key])[key]


def test_a_fresh_retraction_replaces_a_stored_concern_during_an_outage(storage, tmp_path):
    """Crossref down, the export now says retracted: stored and returned retracted."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.CONCERN, _CONCERN, key="doi:10.9/retracted")
    check, row = _recheck(storage, tmp_path, _doc("a", doi="10.9/retracted"))
    assert check.verdict.status is RetractionStatus.RETRACTED
    assert row == check


def test_a_fresh_retraction_replaces_a_fresh_clear_on_refresh(storage, tmp_path):
    """Refresh with Crossref down: the export's or the label's retraction is stored."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.CLEAR, age=timedelta(hours=1), key="doi:10.9/retracted")
    check, row = _recheck(storage, tmp_path, _doc("a", doi="10.9/retracted"), refresh=True)
    assert check.verdict.status is RetractionStatus.RETRACTED and row == check
    _store(storage, RetractionStatus.CLEAR, age=timedelta(hours=1))
    labelled = _doc("b", doi="10.1/a", types=["Retracted Publication"])
    check, row = _recheck(storage, tmp_path, labelled, refresh=True)
    assert check.verdict.status is RetractionStatus.RETRACTED and row == check


def test_a_fresh_concern_replaces_a_stored_clear_during_an_outage(storage, tmp_path):
    """Crossref down, the export now holds a concern: stored and returned concern."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.CLEAR, key="doi:10.9/concern")
    check, row = _recheck(storage, tmp_path, _doc("a", doi="10.9/concern"))
    assert check.verdict.status is RetractionStatus.CONCERN
    assert row == check


def test_a_fresh_concern_does_not_replace_a_stored_retraction_during_an_outage(
    storage, tmp_path
):
    """Control: a concern seen while Crossref is down never downgrades a retraction."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.RETRACTED, _NOTICE, key="doi:10.9/concern")
    check, row = _recheck(storage, tmp_path, _doc("a", doi="10.9/concern"))
    assert check == old and row == old


def test_close_closes_the_session(storage, tmp_path):
    """A checker built for one run releases its session when told."""
    from unittest.mock import MagicMock

    session = MagicMock()
    _checker(storage, tmp_path, session).close()
    session.close.assert_called_once_with()


def test_a_label_retraction_survives_a_recheck_without_types(storage, tmp_path):
    """A stored record's label is read when the checked document carries no types."""
    _current_export(tmp_path)
    labelled = _doc("a", doi="10.1/a", types=["Retracted Publication"])
    storage.add_document(labelled)
    clock = Clock()
    first = _checker(storage, tmp_path, StubSession(), clock).check([labelled])["a"]
    assert first.verdict.status is RetractionStatus.RETRACTED
    clock.now = START + timedelta(days=8)
    session = StubSession()
    bare = _doc("a", doi="10.1/a")  # the MCP and typed-identifier paths carry no types
    again = _checker(storage, tmp_path, session, clock).check([bare])["a"]
    assert len(session.crossref_urls) == 1  # asked again: the row was 8 days old
    assert again.verdict.status is RetractionStatus.RETRACTED
    row = storage.retraction_checks(["doi:10.1/a"])["doi:10.1/a"]
    assert row.verdict.status is RetractionStatus.RETRACTED
    # control: a paper whose stored record has no label is clear
    storage.add_document(_doc("b", doi="10.1/b"))
    other = _checker(storage, tmp_path, StubSession(), clock).check([_doc("b", doi="10.1/b")])
    assert other["b"].verdict.status is RetractionStatus.CLEAR


def _stale_export(tmp_path) -> bytes:
    """An export copy 40 days old; its bytes."""
    stale_day = (START - timedelta(days=40)).date()
    copy = refresh_export(tmp_path, StubSession(), mailto=MAILTO, today=stale_day)
    assert copy.state is ExportState.CURRENT
    return (tmp_path / "retraction_watch.db").read_bytes()


def test_a_single_paper_checker_never_downloads_the_export(storage, tmp_path):
    """A stale copy is not refreshed by a one-paper check: export not consulted."""
    _stale_export(tmp_path)
    session = StubSession()
    check = _checker(storage, tmp_path, session, refresh_export=False).check(
        [_doc("a", doi="10.1/a")]
    )["a"]
    assert session.export_calls == 0
    assert check.verdict.status is RetractionStatus.UNCHECKED
    assert check.verdict.unanswered == (RetractionLookup.RETRACTION_WATCH_EXPORT,)
    # control: the review's checker refreshes the same stale copy
    _checker(storage, tmp_path, session, refresh_export=True).check([_doc("a", doi="10.1/a")])
    assert session.export_calls == 1


def test_build_retraction_checker_refreshes_only_when_asked(storage, tmp_path, monkeypatch):
    """The builder's default is the single-paper checker; the review asks for refresh."""
    from bmlibrarian_lite import retraction_checks

    _stale_export(tmp_path)
    session = StubSession()
    monkeypatch.setattr(retraction_checks, "crossref_session", lambda mailto: session)
    config = LiteConfig()
    config.storage.data_dir = tmp_path
    retraction_checks.build_retraction_checker(config, storage).check([_doc("a", doi="10.1/a")])
    assert session.export_calls == 0
    retraction_checks.build_retraction_checker(config, storage, refresh_export=True).check(
        [_doc("a", doi="10.1/a")]
    )
    assert session.export_calls == 1


def test_a_refused_download_over_a_stale_copy_leaves_papers_unchecked(storage, tmp_path):
    """Review Focus (2): the export is not consulted, the papers are unchecked, the old copy stays."""
    from bmlibrarian_lite.retraction_screen import screen_with_fallback
    from bmlibrarian_lite.retraction_text import run_summary_clause

    before = _stale_export(tmp_path)
    session = StubSession(export_status=500)
    checker = _checker(storage, tmp_path, session, refresh_export=True)
    screen = screen_with_fallback(checker, [_doc("a", doi="10.1/a"), _doc("b", doi="10.1/b")])
    assert session.export_calls == 1
    for check in screen.checks.values():
        assert check.verdict.status is RetractionStatus.UNCHECKED
        assert RetractionLookup.RETRACTION_WATCH_EXPORT in check.verdict.unanswered
        assert check.export_data_as_of is None  # export not consulted
    assert screen.unchecked_count == 2
    assert "Retraction Watch copy could not be used" in run_summary_clause(screen)
    assert (tmp_path / "retraction_watch.db").read_bytes() == before


def test_one_throttled_batch_of_120_leaves_exactly_50_unchecked(storage, tmp_path):
    """Review Focus (4): 120 DOIs are three batches; the second answers 429."""
    from bmlibrarian_lite.retraction_screen import screen_with_fallback
    from bmlibrarian_lite.retraction_text import run_summary_clause

    _current_export(tmp_path)
    calls = []

    def second_throttled(url):
        calls.append(url)
        return _Response(429, b"") if len(calls) == 2 else _served(url)

    docs = [_doc(f"d{i}", doi=f"10.5/{i}") for i in range(120)]
    checker = _checker(storage, tmp_path, StubSession(second_throttled))
    screen = screen_with_fallback(checker, docs)
    assert len(calls) == 3
    assert screen.unchecked_count == 50
    clause = run_summary_clause(screen)
    assert clause is not None
    assert clause.startswith("50 papers' retraction status could not be checked")
    assert "HTTP 429" in clause


def test_a_failed_store_still_returns_the_verdicts(storage, tmp_path, monkeypatch, caplog):
    """A locked database loses the cache, never the run's retraction."""
    from bmlibrarian_lite.retraction_screen import screen_with_fallback

    _current_export(tmp_path)

    def locked(*_args, **_kwargs):
        raise sqlite3.OperationalError("database is locked")

    monkeypatch.setattr(storage, "store_retraction_checks", locked)
    docs = [_doc("r", doi="10.9/retracted"), _doc("c", doi="10.1/clear")]
    screen = screen_with_fallback(_checker(storage, tmp_path, StubSession()), docs)
    assert [d.id for d in screen.excluded] == ["r"]
    assert screen.checks["c"].verdict.status is RetractionStatus.CLEAR
    assert not screen.failed
    assert "OperationalError" in caplog.text


def test_a_failed_check_still_leaves_out_a_paper_its_label_retracts(storage, tmp_path):
    """The label needs no network or database, so it decides even then."""
    from bmlibrarian_lite.retraction_screen import UnbuiltChecker, screen_with_fallback

    docs = [_doc("r", doi="10.1/r", types=["Retracted Publication"]), _doc("k", doi="10.1/k")]
    screen = screen_with_fallback(UnbuiltChecker(), docs)
    assert screen.failed
    assert [d.id for d in screen.excluded] == ["r"]
    assert screen.checks["k"].verdict.status is RetractionStatus.UNCHECKED


def test_an_outage_never_overwrites_an_unreadable_stored_row(storage, tmp_path):
    """A row a newer build wrote may hold a retraction: an outage leaves it."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.RETRACTED, _NOTICE)
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        conn.execute("UPDATE retraction_checks SET status = 'retracted_v2'")
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check([_doc("a", doi="10.1/a")])
    assert out["a"].verdict.status is RetractionStatus.UNCHECKED
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        [(status,)] = conn.execute("SELECT status FROM retraction_checks").fetchall()
    assert status == "retracted_v2"
    # control: an answer replaces it
    _checker(storage, tmp_path, StubSession()).check([_doc("a", doi="10.1/a")])
    assert storage.retraction_checks([_KEY])[_KEY].verdict.status is RetractionStatus.CLEAR


def test_a_retraction_overwrites_an_unreadable_stored_row_during_an_outage(storage, tmp_path):
    """Crossref down: a retraction is stored over an unreadable row, a concern is not (#669)."""
    _current_export(tmp_path)
    for doi in ("10.9/retracted", "10.9/concern"):
        _store(storage, RetractionStatus.CONCERN, _CONCERN, key=f"doi:{doi}")
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        conn.execute("UPDATE retraction_checks SET status = 'concern_v2'")
    keys = ["doi:10.9/retracted", "doi:10.9/concern"]
    assert storage.retraction_checks(keys) == {}, "control: unreadable"
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check(
        [_doc("r", doi="10.9/retracted"), _doc("c", doi="10.9/concern")]
    )
    assert out["r"].verdict.status is RetractionStatus.RETRACTED and out["r"].verdict.unanswered
    assert out["c"].verdict.status is RetractionStatus.CONCERN and out["c"].verdict.unanswered
    assert storage.retraction_checks(keys) == {keys[0]: out["r"]}, "nothing warns more"
    with sqlite3.connect(storage.config.storage.sqlite_path) as conn:
        [(status,)] = conn.execute(
            "SELECT status FROM retraction_checks WHERE paper_key = ?", (keys[1],)
        ).fetchall()
    assert status == "concern_v2", "the unreadable row may hold a retraction"


def test_an_outage_never_erases_a_stored_concern(storage, tmp_path):
    """Crossref down on the re-check: the stored concern is still returned and kept."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.CONCERN, _CONCERN)
    out = _checker(storage, tmp_path, StubSession(_unreachable)).check([_doc("a", doi="10.1/a")])
    assert out["a"] == old
    assert storage.retraction_checks([_KEY])[_KEY] == old


def test_a_cancel_during_the_export_download_stops_it(storage, tmp_path):
    """The checker hands its cancel to the download: no more chunks, old copy kept."""
    refresh_export(tmp_path, StubSession(), mailto=MAILTO, today=START.date() - timedelta(days=40))
    before = (tmp_path / "retraction_watch.db").read_bytes()
    read: list[int] = []

    class _Chunked(_Response):
        def iter_content(self, size):
            for i in range(5):
                read.append(i)
                yield CSV[i * 10 : (i + 1) * 10]

    class _Session(StubSession):
        def get(self, url, **kwargs):
            if url.startswith(RETRACTION_WATCH_EXPORT_URL):
                return _Chunked(200, b"")
            return super().get(url, **kwargs)

    out = _checker(storage, tmp_path, _Session()).check(
        [_doc("a", doi="10.1/a")], should_cancel=lambda: len(read) > 1
    )
    assert read == [0, 1]
    assert (tmp_path / "retraction_watch.db").read_bytes() == before
    assert out == {}  # cancelled before Crossref was asked


def test_a_cancel_after_the_first_batch_keeps_its_answers(storage, tmp_path):
    """60 DOIs, cancel after batch one: its 50 verdicts are returned and stored."""
    _current_export(tmp_path)
    calls: list[str] = []

    def counted(url):
        calls.append(url)
        return _served(url)

    docs = [_doc(f"d{i}", doi=f"10.5/{i}") for i in range(60)]
    out = _checker(storage, tmp_path, StubSession(counted)).check(
        docs, should_cancel=lambda: bool(calls)
    )
    assert len(calls) == 1
    assert len(out) == 50
    assert len(storage.retraction_checks([f"doi:10.5/{i}" for i in range(60)])) == 50


_LABEL = RetractionEvidence(RetractionSource.PUBMED_LABEL, RetractionKind.RETRACTION)


def test_a_label_retraction_stands_when_another_id_carries_no_record(storage, tmp_path):
    """Same paper_key through a doi- id with no types: the unreadable label is not a correction."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.RETRACTED, _LABEL)
    out = _checker(storage, tmp_path, StubSession()).check([_doc("doi-10.1_a", doi="10.1/a")])
    assert out["doi-10.1_a"] == old
    assert storage.retraction_checks([_KEY])[_KEY] == old


def test_a_corrected_record_replaces_a_stored_label_retraction(storage, tmp_path):
    """Control: documents carrying types without the label give the fresh verdict."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.RETRACTED, _LABEL)
    typed = _doc("doi-10.1_a", doi="10.1/a", types=["Journal Article"])
    out = _checker(storage, tmp_path, StubSession()).check([typed])
    assert out["doi-10.1_a"].verdict.status is RetractionStatus.CLEAR
    assert storage.retraction_checks([_KEY])[_KEY].verdict.status is RetractionStatus.CLEAR


def test_a_fresh_retraction_replaces_a_stored_label_retraction_reached_without_types(storage, tmp_path):
    """Control: the unreadable-label guard never keeps a label row against a fresh notice of retraction."""
    _current_export(tmp_path)
    key = "doi:10.9/retracted"
    _store(storage, RetractionStatus.RETRACTED, _LABEL, key=key)
    out = _checker(storage, tmp_path, StubSession()).check([_doc("doi-10.9_retracted", doi="10.9/retracted")])
    check = out["doi-10.9_retracted"]
    assert check.verdict.status is RetractionStatus.RETRACTED
    assert check.verdict.deciding.source is not RetractionSource.PUBMED_LABEL
    assert check.verdict.deciding.notice_doi == "10.9/notice"
    assert storage.retraction_checks([key])[key] == check


def test_a_fresh_concern_never_downgrades_a_label_retraction_it_cannot_read(storage, tmp_path):
    """No types to read the label from: a concern the export holds does not replace the label's retraction."""
    _current_export(tmp_path)
    old = _store(storage, RetractionStatus.RETRACTED, _LABEL, key="doi:10.9/concern")
    out = _checker(storage, tmp_path, StubSession()).check([_doc("doi-10.9_concern", doi="10.9/concern")])
    assert out["doi-10.9_concern"] == old
    assert storage.retraction_checks(["doi:10.9/concern"])["doi:10.9/concern"] == old


def test_one_typed_document_reads_the_label_for_the_paper(storage, tmp_path):
    """Control: two documents of one paper, one carrying types without the label: the label was read."""
    _current_export(tmp_path)
    _store(storage, RetractionStatus.RETRACTED, _LABEL)
    docs = [_doc("doi-10.1_a", doi="10.1/a"), _doc("pmid-1", doi="10.1/a", types=["Journal Article"])]
    out = _checker(storage, tmp_path, StubSession()).check(docs)
    assert {c.verdict.status for c in out.values()} == {RetractionStatus.CLEAR}
