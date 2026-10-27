"""The MCP tools leave out or flag retracted papers."""

from __future__ import annotations

import dataclasses
from datetime import UTC, datetime
from unittest.mock import MagicMock

import pytest
from bmlib.publications.retraction_status import (
    RetractionEvidence,
    RetractionKind,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
)

from bmlibrarian_lite import mcp_server
from bmlibrarian_lite.fulltext_discovery import FulltextResult, FulltextSourceType
from bmlibrarian_lite.retraction_store import PaperCheck
from tests.test_mcp_server import (
    _make_citation,
    _make_context,
    _make_document,
    _make_scored_document,
    _make_session,
)

WHEN = datetime(2026, 10, 1, tzinfo=UTC)
NOTICE = "10.1/notice"


def _check(status: RetractionStatus) -> PaperCheck:
    if status in (RetractionStatus.RETRACTED, RetractionStatus.CONCERN):
        kind = (
            RetractionKind.RETRACTION
            if status is RetractionStatus.RETRACTED
            else RetractionKind.EXPRESSION_OF_CONCERN
        )
        verdict = RetractionVerdict(
            status,
            RetractionEvidence(
                RetractionSource.CROSSREF_PUBLISHER,
                kind,
                "2025-03-04",
                NOTICE,
            ),
            (),
        )
    elif status is RetractionStatus.UNCHECKED:
        verdict = RetractionVerdict(status, None, (RetractionLookup.CROSSREF,))
    else:
        verdict = RetractionVerdict(status, None, ())
    return PaperCheck(verdict, WHEN, None, None)


class FakeChecker:
    """A checker that counts calls and answers from a status table."""

    def __init__(self, by_id: dict[str, RetractionStatus]) -> None:
        """Keep the table."""
        self.by_id = by_id
        self.calls = 0
        self.closed = False

    def check(self, documents, **_kw):
        """Answer for each document."""
        self.calls += 1
        return {
            d.id: _check(self.by_id.get(d.id, RetractionStatus.CLEAR)) for d in documents
        }

    def close(self) -> None:
        """Note the close."""
        self.closed = True


@pytest.fixture
def checker(monkeypatch: pytest.MonkeyPatch) -> FakeChecker:
    """Install a fake checker, all clear until a test says otherwise."""
    fake = FakeChecker({})
    monkeypatch.setattr(mcp_server, "_build_checker", lambda ctx, **kw: fake)
    return fake


def _docs():
    good = _make_document("pmid-1", "Good paper", "1")
    bad = _make_document("pmid-2", "Bad paper", "2")
    return good, bad


def test_fact_check_excludes_retracted_and_lists_it(checker: FakeChecker) -> None:
    """Fact check excludes retracted and lists it."""
    good, bad = _docs()
    checker.by_id["pmid-2"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    ctx.scoring_agent.score_documents.return_value = MagicMock(
        accepted=[_make_scored_document(good)], shortfall=None
    )
    ctx.citation_agent.extract_all_citations.return_value = MagicMock(
        citations=[_make_citation(good)], failed=[], shortfall=None
    )
    ctx.reporting_agent.generate_report.return_value = "REPORT"
    out = mcp_server._handle_fact_check({"claim": "c"}, ctx)
    scored = ctx.scoring_agent.score_documents.call_args.kwargs["documents"]
    assert [d.id for d in scored] == ["pmid-1"]
    assert out["retraction"]["left_out"] == [
        {
            "title": "Bad paper",
            "doi": "10.1234/test",
            "pmid": "2",
            "retraction_date": "2025-03-04",
            "notice_doi": NOTICE,
        }
    ]
    assert out["retraction"]["unchecked"] == 0
    assert out["retraction"]["checked_at"] == WHEN.isoformat()
    assert out["documents_found"] == 2  # what the search found, before leaving out
    assert "Retraction check:" in out["report"]
    assert checker.closed


def test_fact_check_all_retracted_still_reports_it(checker: FakeChecker) -> None:
    """Fact check all retracted still reports it."""
    _, bad = _docs()
    checker.by_id["pmid-2"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [bad])
    out = mcp_server._handle_fact_check({"claim": "c"}, ctx)
    ctx.scoring_agent.score_documents.assert_not_called()
    assert len(out["retraction"]["left_out"]) == 1
    assert "Retraction check:" in out["report"]
    assert out["report"].count("1 retracted paper left out") == 1


def test_search_literature_excludes_and_lists(checker: FakeChecker) -> None:
    """Search literature excludes and lists."""
    good, bad = _docs()
    checker.by_id["pmid-2"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    out = mcp_server._handle_search({"query": "q"}, ctx)
    assert [d["id"] for d in out["documents"]] == ["pmid-1"]
    assert out["retraction"]["left_out"][0]["pmid"] == "2"
    assert out["documents"][0]["retraction_status"] == {
        "status": "clear",
        "line": "No retraction found",
    }


def test_search_marks_a_kept_paper_under_concern(checker: FakeChecker) -> None:
    """A concern is not left out, so the caller must be told it per paper."""
    good, _ = _docs()
    checker.by_id["pmid-1"] = RetractionStatus.CONCERN
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good])
    [doc] = mcp_server._handle_search({"query": "q"}, ctx)["documents"]
    assert doc["retraction_status"]["status"] == "concern"
    assert doc["retraction_status"]["line"].startswith("Expression of concern")


def test_checker_failure_leaves_everything_unchecked(monkeypatch) -> None:
    """Checker failure leaves everything unchecked."""
    class Boom(FakeChecker):
        def check(self, documents, **_kw):
            raise RuntimeError("secret provider text")

    fake = Boom({})
    monkeypatch.setattr(mcp_server, "_build_checker", lambda ctx, **kw: fake)
    good, bad = _docs()
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    out = mcp_server._handle_search({"query": "q"}, ctx)
    assert len(out["documents"]) == 2
    assert out["retraction"]["unchecked"] == 2
    assert "secret" not in str(out)
    assert fake.closed


def test_fulltext_of_a_retracted_paper_is_returned_with_the_status_first(
    checker: FakeChecker,
) -> None:
    """Fulltext of a retracted paper is returned with the status first."""
    checker.by_id["pmid-7"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
        success=True, source_type=FulltextSourceType.EUROPEPMC_XML, markdown_content="BODY"
    )
    ctx.interrogation_agent.load_document.return_value = "pmid-7"
    out = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert next(iter(out)) == "retraction_status"
    assert out["retraction_status"]["status"] == "retracted"
    assert out["content"].startswith(out["retraction_status"]["line"] + "\n\nBODY")
    assert out["success"] is True


def test_fulltext_clear_has_no_prefix(checker: FakeChecker) -> None:
    """Fulltext clear has no prefix."""
    ctx = _make_context()
    ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
        success=True, source_type=FulltextSourceType.EUROPEPMC_XML, markdown_content="BODY"
    )
    ctx.interrogation_agent.load_document.return_value = "pmid-7"
    out = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert out["content"] == "BODY"
    assert out["retraction_status"]["status"] == "clear"


def test_ask_document_states_unchecked(checker: FakeChecker) -> None:
    """Ask document states unchecked."""
    ctx = _make_context()
    ctx.storage.get_document.return_value = None
    ctx.interrogation_agent.ask.return_value = ("ANSWER", [])
    out = mcp_server._handle_ask_document({"question": "q", "document_id": "x"}, ctx)
    assert next(iter(out)) == "retraction_status"
    assert out["retraction_status"]["status"] == "unchecked"
    assert out["answer"].startswith(out["retraction_status"]["line"] + "\n\nANSWER")
    assert checker.calls == 0


def test_ask_document_checks_a_stored_document(checker: FakeChecker) -> None:
    """Ask document checks a stored document."""
    checker.by_id["pmid-2"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.storage.get_document.return_value = _docs()[1]
    ctx.interrogation_agent.ask.return_value = ("ANSWER", [])
    out = mcp_server._handle_ask_document({"question": "q", "document_id": "pmid-2"}, ctx)
    assert out["retraction_status"]["status"] == "retracted"
    assert out["answer"].endswith("\n\nANSWER")


def test_each_workflow_screens_once(checker: FakeChecker) -> None:
    """Each workflow screens once."""
    good, bad = _docs()
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    mcp_server._handle_search({"query": "q"}, ctx)
    assert checker.calls == 1
    ctx.scoring_agent.score_documents.return_value = MagicMock(accepted=[], shortfall=None)
    mcp_server._handle_fact_check({"claim": "c"}, ctx)
    assert checker.calls == 2
    ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
        success=True, source_type=FulltextSourceType.EUROPEPMC_XML, markdown_content="B"
    )
    ctx.interrogation_agent.load_document.return_value = "pmid-7"
    mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert checker.calls == 3
    ctx.storage.get_document.return_value = good
    ctx.interrogation_agent.ask.return_value = ("A", [])
    mcp_server._handle_ask_document({"question": "q", "document_id": "pmid-1"}, ctx)
    assert checker.calls == 4


def _boom_builder(monkeypatch: pytest.MonkeyPatch) -> None:
    """Make building the checker raise, with provider text in the message."""

    def boom(ctx: object, **kw: object) -> None:
        raise RuntimeError("secret provider text")

    monkeypatch.setattr(mcp_server, "_build_checker", boom)


def _ok_fulltext(ctx: MagicMock, **info: str) -> None:
    """Have discovery succeed, optionally with article info."""
    article = MagicMock(**info) if info else None
    ctx.fulltext_discoverer.discover_fulltext.return_value = FulltextResult(
        success=True,
        source_type=FulltextSourceType.EUROPEPMC_XML,
        markdown_content="BODY",
        article_info=article,
    )
    ctx.interrogation_agent.load_document.return_value = "pmc-9"


def test_a_checker_that_cannot_be_built_leaves_every_tool_unchecked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A build failure never fails a call, and no provider text leaks."""
    _boom_builder(monkeypatch)
    good, bad = _docs()
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    out = mcp_server._handle_search({"query": "q"}, ctx)
    assert len(out["documents"]) == 2 and out["retraction"]["unchecked"] == 2
    ctx.scoring_agent.score_documents.return_value = MagicMock(accepted=[], shortfall=None)
    fc = mcp_server._handle_fact_check({"claim": "c"}, ctx)
    assert fc["retraction"]["unchecked"] == 2
    _ok_fulltext(ctx)
    ft = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    ctx.storage.get_document.return_value = good
    ctx.interrogation_agent.ask.return_value = ("A", [])
    ask = mcp_server._handle_ask_document({"question": "q", "document_id": "pmid-1"}, ctx)
    for tool_out in (out, fc, ft, ask):
        assert "secret" not in str(tool_out)
    assert ft["retraction_status"]["status"] == "unchecked"
    assert ask["retraction_status"]["status"] == "unchecked"


def test_a_check_that_raises_leaves_the_single_paper_tools_unchecked(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    """A failing check never fails ask_document or get_document_fulltext."""

    class Boom(FakeChecker):
        def check(self, documents, **_kw):
            """Fail."""
            raise RuntimeError("secret provider text")

    fake = Boom({})
    monkeypatch.setattr(mcp_server, "_build_checker", lambda ctx, **kw: fake)
    ctx = _make_context()
    _ok_fulltext(ctx)
    ft = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    ctx.storage.get_document.return_value = _docs()[0]
    ctx.interrogation_agent.ask.return_value = ("A", [])
    ask = mcp_server._handle_ask_document({"question": "q", "document_id": "pmid-1"}, ctx)
    assert ft["retraction_status"]["status"] == ask["retraction_status"]["status"] == "unchecked"
    assert "secret" not in str(ft) + str(ask)
    assert fake.closed


def test_concern_is_prefixed_and_named(checker: FakeChecker) -> None:
    """A concern status prefixes the text."""
    checker.by_id["pmid-7"] = RetractionStatus.CONCERN
    ctx = _make_context()
    _ok_fulltext(ctx)
    out = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert out["retraction_status"]["status"] == "concern"
    assert out["content"] == out["retraction_status"]["line"] + "\n\nBODY"


def test_search_with_no_documents(checker: FakeChecker) -> None:
    """Nothing found means nothing screened."""
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [])
    out = mcp_server._handle_search({"query": "q"}, ctx)
    assert out["documents"] == []
    assert out["retraction"] == {"left_out": [], "unchecked": 0, "checked_at": None}
    assert checker.calls == 0


def test_pmc_only_request_is_checked_with_the_ids_discovery_learned(
    checker: FakeChecker,
) -> None:
    """A pmc_id-only request is checked by the DOI discovery found; the id is unchanged."""
    seen = []
    original = checker.check

    def spy(documents, **kw):
        seen.extend(documents)
        return original(documents, **kw)

    checker.check = spy  # type: ignore[method-assign]
    ctx = _make_context()
    _ok_fulltext(ctx, title="T", pmid="55", doi="10.9/found")
    out = mcp_server._handle_fulltext({"pmc_id": "PMC9"}, ctx)
    assert (seen[0].doi, seen[0].pmid) == ("10.9/found", "55")
    assert out["retraction_status"]["status"] == "clear"
    assert out["document_id"] == "pmc-9"


def test_fact_check_notice_order(checker: FakeChecker, monkeypatch: pytest.MonkeyPatch) -> None:
    """Text order: search notice, analysis notice, retraction notice, body."""
    monkeypatch.setattr(mcp_server, "with_search_shortfall_notice", lambda t, s: f"SEARCH\n\n{t}")
    monkeypatch.setattr(
        mcp_server, "with_analysis_shortfall_notice", lambda t, s: f"ANALYSIS\n\n{t}"
    )
    good, bad = _docs()
    checker.by_id["pmid-2"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad])
    ctx.scoring_agent.score_documents.return_value = MagicMock(
        accepted=[_make_scored_document(good)], shortfall=None
    )
    ctx.citation_agent.extract_all_citations.return_value = MagicMock(
        citations=[], failed=[], shortfall=None
    )
    ctx.reporting_agent.generate_report.return_value = "BODYTEXT"
    report = mcp_server._handle_fact_check({"claim": "c"}, ctx)["report"]
    order = [report.index(m) for m in ("SEARCH", "ANALYSIS", "Retraction check:", "BODYTEXT")]
    assert order == sorted(order)


def _real_storage(tmp_path):
    """A real store under tmp_path."""
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.storage import LiteStorage

    config = LiteConfig()
    config.storage.data_dir = tmp_path / "store"
    return LiteStorage(config)


def test_ask_document_after_fulltext_gives_the_same_status(checker: FakeChecker, tmp_path) -> None:
    """get_document_fulltext stores what it learned, so ask_document can check the paper."""
    checker.by_id["pmid-7"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    ctx.storage = _real_storage(tmp_path)
    _ok_fulltext(ctx)
    ctx.interrogation_agent.load_document.return_value = "pmid-7"
    ft = mcp_server._handle_fulltext({"pmid": "7", "doi": "10.9/x"}, ctx)
    stored = ctx.storage.get_document("pmid-7")
    assert stored is not None and (stored.pmid, stored.doi) == ("7", "10.9/x")
    ctx.interrogation_agent.ask.return_value = ("A", [])
    ask = mcp_server._handle_ask_document({"question": "q", "document_id": "pmid-7"}, ctx)
    assert ft["retraction_status"] == ask["retraction_status"]
    assert ask["retraction_status"]["status"] == "retracted"
    assert checker.calls == 2


def test_fulltext_checks_and_stores_the_records_publication_types(checker: FakeChecker) -> None:
    """The label discovery read reaches the check and the stored document."""
    seen = []
    original = checker.check

    def spy(documents, **kw):
        seen.extend(documents)
        return original(documents, **kw)

    checker.check = spy  # type: ignore[method-assign]
    ctx = _make_context()
    _ok_fulltext(ctx, title="T", pmid="55", doi="10.9/found")
    ctx.fulltext_discoverer.discover_fulltext.return_value.article_info.publication_types = [
        "Retracted Publication"
    ]
    mcp_server._handle_fulltext({"pmc_id": "PMC9"}, ctx)
    assert seen[0].publication_types == ["Retracted Publication"]
    stored = ctx.storage.add_document.call_args.args[0]
    assert stored.publication_types == ["Retracted Publication"]
    assert stored.id == "pmc-9"


def test_content_length_is_the_returned_contents(checker: FakeChecker) -> None:
    """With the status line in front, content_length still measures the content returned."""
    checker.by_id["pmid-7"] = RetractionStatus.RETRACTED
    ctx = _make_context()
    _ok_fulltext(ctx)
    ctx.interrogation_agent.load_document.return_value = "pmid-7"
    out = mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert out["content_length"] == len(out["content"])


def test_the_mcp_checker_never_downloads_the_export(tmp_path, monkeypatch) -> None:
    """A one-paper tool call uses the copy it has: a stale one is not refreshed."""
    from bmlibrarian_lite import retraction_checks
    from bmlibrarian_lite.config import LiteConfig
    from bmlibrarian_lite.retraction_export import refresh_export
    from tests.test_retraction_checks import MAILTO, START, StubSession, _doc

    refresh_export(tmp_path, StubSession(), mailto=MAILTO, today=START.date().replace(year=2020))
    session = StubSession()
    monkeypatch.setattr(retraction_checks, "crossref_session", lambda mailto: session)
    ctx = _make_context()
    ctx.config = LiteConfig()
    ctx.config.storage.data_dir = tmp_path
    ctx.storage = _real_storage(tmp_path)
    check = mcp_server._build_checker(ctx).check([_doc("a", doi="10.1/a")])["a"]
    assert session.export_calls == 0
    assert check.verdict.status is RetractionStatus.UNCHECKED


def test_fact_check_puts_each_notice_on_once_with_the_real_report(
    checker: FakeChecker,
) -> None:
    """A real report already carries the analysis and retraction notices: once each.

    They come in order, and a cited paper under a concern gets its caveat.
    """
    from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
    from bmlibrarian_lite.analysis_failures import describe_analysis_shortfalls
    from bmlibrarian_lite.data_models import AnalysisShortfall, AnalysisStage

    good, bad = _docs()
    concern = _make_document("pmid-3", "Concern paper", "3")
    checker.by_id.update(
        {"pmid-2": RetractionStatus.RETRACTED, "pmid-3": RetractionStatus.CONCERN}
    )
    loss = AnalysisShortfall(stage=AnalysisStage.SCORING, documents_failed=1, documents_attempted=3)
    ctx = _make_context()
    ctx.search_agent.search.return_value = (_make_session(), [good, bad, concern])
    ctx.scoring_agent.score_documents.return_value = MagicMock(
        accepted=[_make_scored_document(good), _make_scored_document(concern)], shortfall=loss
    )
    ctx.citation_agent.extract_all_citations.return_value = MagicMock(
        citations=[_make_citation(good), _make_citation(concern)], failed=[], shortfall=None
    )
    agent = LiteReportingAgent(config=MagicMock())
    agent._chat_prose = MagicMock(return_value="BODYTEXT")  # type: ignore[method-assign]
    ctx.reporting_agent = agent

    out = mcp_server._handle_fact_check({"claim": "c"}, ctx)
    report = out["report"]
    assert [src["retraction_status"]["status"] for src in out["sources"]] == ["clear", "concern"]

    analysis = describe_analysis_shortfalls([loss])
    assert report.count(analysis) == 1
    assert report.count("Retraction check:") == 1
    assert report.index(analysis) < report.index("Retraction check:") < report.index("BODYTEXT")
    assert "Expression of concern (2025-03-04, notice 10.1/notice)" in report


def test_a_paper_without_identifiers_still_reaches_the_checker(checker: FakeChecker) -> None:
    """Its record's label can retract it; the checker reads that, not this tool."""
    doc = dataclasses.replace(_make_document("local-1", "No ids", None), doi=None)  # type: ignore[arg-type]
    checker.by_id["local-1"] = RetractionStatus.RETRACTED
    check = mcp_server._paper_check(_make_context(), doc)
    assert check.verdict.status is RetractionStatus.RETRACTED
    assert checker.calls == 1


def test_fulltext_keeps_a_stored_source_and_records_europepmc_for_a_new_row(
    checker: FakeChecker, tmp_path
) -> None:
    """The upsert never overwrites a stored Europe PMC source with the default."""
    from bmlibrarian_lite.data_models import DocumentSource, LiteDocument

    ctx = _make_context()
    ctx.storage = _real_storage(tmp_path)
    _ok_fulltext(ctx)
    ctx.interrogation_agent.load_document.side_effect = lambda **kw: kw["document_id"]
    ctx.storage.add_document(
        LiteDocument(id="pmid-7", title="T", abstract="a", pmid="7", source=DocumentSource.LOCAL_TEXT)
    )
    mcp_server._handle_fulltext({"pmid": "7"}, ctx)
    assert ctx.storage.get_document("pmid-7").source is DocumentSource.LOCAL_TEXT
    mcp_server._handle_fulltext({"pmid": "8"}, ctx)
    assert ctx.storage.get_document("pmid-8").source is DocumentSource.EUROPEPMC


def test_only_the_fact_check_builds_a_refreshing_checker(monkeypatch: pytest.MonkeyPatch) -> None:
    """The review-like workflow may download the export; single-paper tools may not."""
    flags: list[tuple[str, bool]] = []
    current = ["paper"]

    def spy(ctx, *, refresh_export=False):
        flags.append((current[0], refresh_export))
        return FakeChecker({})

    monkeypatch.setattr(mcp_server, "_build_checker", spy)
    good = _docs()[0]
    ctx = _make_context()
    mcp_server._paper_check(ctx, good)
    ctx.search_agent.search.return_value = (_make_session(), [good])
    current[0] = "search"
    mcp_server._handle_search({"query": "q"}, ctx)
    current[0] = "fact"
    ctx.scoring_agent.score_documents.return_value = MagicMock(accepted=[], shortfall=None)
    mcp_server._handle_fact_check({"claim": "c"}, ctx)
    assert ("paper", False) in flags and ("fact", True) in flags
    assert all(not flag for name, flag in flags if name != "fact")
