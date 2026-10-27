"""The report says what the retraction check left out and found."""

from __future__ import annotations

import difflib
from datetime import UTC, date, datetime
from unittest.mock import MagicMock

from bmlib.publications.retraction_status import (
    RetractionEvidence,
    RetractionKind,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
)

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.analysis_failures import describe_analysis_shortfalls
from bmlibrarian_lite.data_models import (
    AnalysisShortfall,
    AnalysisStage,
    Citation,
    LiteDocument,
    ReportMetadata,
    RequestFailure,
    RequestFailureKind,
    RetrievalShortfall,
    SearchProvider,
)
from bmlibrarian_lite.retraction_screen import RetractionSnapshot, screen_documents
from bmlibrarian_lite.retraction_store import PaperCheck
from bmlibrarian_lite.retraction_text import (
    checked_on_line,
    format_reference_concern_annotation,
    format_retracted_section,
    format_retraction_notice,
)
from bmlibrarian_lite.search_failures import describe_search_shortfalls

WHEN = datetime(2026, 10, 18, 9, 30, tzinfo=UTC)
QUESTION = "Does aspirin prevent stroke?"


def _doc(i: str) -> LiteDocument:
    """Doc."""
    return LiteDocument(id=i, title=f"Title {i}", abstract="", doi=f"10.1/{i}", pmid="1", year=2020)


def _check(status: RetractionStatus, notice: str | None = None) -> PaperCheck:
    """Check."""
    unanswered = (
        (RetractionLookup.CROSSREF,) if status is RetractionStatus.UNCHECKED else ()
    )
    evidence = None
    if notice:
        evidence = RetractionEvidence(
            source=RetractionSource.RETRACTION_WATCH_EXPORT,
            kind=(
                RetractionKind.EXPRESSION_OF_CONCERN if status is RetractionStatus.CONCERN else RetractionKind.RETRACTION
            ),
            date="2026-03-09",
            notice_doi=notice,
        )
    return PaperCheck(RetractionVerdict(status, evidence, unanswered), WHEN, date(2026, 10, 1), None)


def _screen(**statuses):
    """Screen of docs named by keyword, e.g. a=RETRACTED."""
    docs = [_doc(k) for k in statuses]
    checks = {
        k: _check(v, None if v in (RetractionStatus.CLEAR, RetractionStatus.UNCHECKED) else "10.9/n")
        for k, v in statuses.items()
    }
    return screen_documents(docs, checks)


def _report(screen, citations=None, **meta) -> str:
    """Report with a stubbed model."""
    agent = LiteReportingAgent(config=MagicMock())
    agent._chat_prose = MagicMock(return_value="Aspirin reduced stroke.")  # type: ignore[method-assign]
    if citations is None:
        citations = [Citation(document=_doc("ok"), passage="p", relevance_score=5)]
    metadata = ReportMetadata(retraction_screen=screen, **meta)
    return agent.generate_report(QUESTION, citations, metadata)


def test_report_lists_left_out_papers() -> None:
    """Report lists left out papers."""
    report = _report(_screen(ok=RetractionStatus.CLEAR, bad=RetractionStatus.RETRACTED))
    assert "## Left out as retracted" in report
    assert "- Title bad. Retracted 2026-03-09; notice 10.9/n" in report
    assert report.index("## References") < report.index("## Left out as retracted")
    assert report.index("## Left out as retracted") < report.index("## Methodology")


def _cite(i: str) -> Citation:
    """Citation of doc i."""
    return Citation(document=_doc(i), passage="p", relevance_score=5)


def test_cited_concern_paper_carries_a_caveat_at_its_reference() -> None:
    """The caveat sits under the concern paper's own reference, once, and nowhere else."""
    screen = _screen(
        conc=RetractionStatus.CONCERN,
        ok=RetractionStatus.CLEAR,
        unk=RetractionStatus.UNCHECKED,
        other=RetractionStatus.CONCERN,
    )
    report = _report(screen, citations=[_cite("ok"), _cite("conc"), _cite("unk")])
    caveat = "    ⚠️ Expression of concern (2026-03-09, notice 10.9/n)"
    assert report.count(caveat) == 1
    lines = report.splitlines()
    at = lines.index(caveat)
    assert "Title conc" in lines[at - 1]
    assert "Title other" not in report


def test_methods_carries_the_checked_on_line() -> None:
    """Methods carries the checked on line."""
    report = _report(_screen(ok=RetractionStatus.CLEAR))
    section = report.split("### Document Screening")[1].split("###")[0]
    assert "Retraction status checked 2026-10-18" in section


def test_report_without_exclusions_or_concerns_gains_only_the_checked_on_line() -> None:
    """Report without exclusions or concerns gains only the checked on line."""
    with_screen = _report(_screen(ok=RetractionStatus.CLEAR))
    without = _report(None)
    added = [
        line
        for line in difflib.ndiff(without.splitlines(), with_screen.splitlines())
        if line[0] in "+-"
    ]
    assert len(added) == 1 and "Retraction status checked 2026-10-18" in added[0]


def test_retraction_notice_leads_the_report_after_the_other_notices() -> None:
    """Search notice, analysis notice, retraction notice, then the body."""
    analysis = AnalysisShortfall(
        stage=AnalysisStage.SCORING, documents_failed=1, documents_attempted=3
    )
    search = RetrievalShortfall(
        SearchProvider.PUBMED, RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    )
    report = _report(
        _screen(ok=RetractionStatus.CLEAR, bad=RetractionStatus.RETRACTED),
        analysis_shortfalls=[analysis],
        search_shortfalls=[search],
    )
    notice = "> **Retraction check:** 1 retracted paper left out."
    assert report.count(notice) == 1
    pos_search = report.index(describe_search_shortfalls([search]))
    pos_analysis = report.index(describe_analysis_shortfalls([analysis]))
    assert pos_search < pos_analysis < report.index(notice) < report.index("Aspirin reduced")


def test_no_evidence_report_carries_section_and_line() -> None:
    """No evidence report carries section and line."""
    report = _report(_screen(bad=RetractionStatus.RETRACTED), citations=[])
    assert "No relevant evidence" in report
    assert "- Title bad. Retracted 2026-03-09; notice 10.9/n" in report
    assert "Retraction status checked 2026-10-18" in report


def test_metadata_round_trips() -> None:
    """Metadata round trips."""
    screen = _screen(ok=RetractionStatus.CONCERN, bad=RetractionStatus.RETRACTED)
    metadata = ReportMetadata(retraction_screen=screen)
    back = ReportMetadata.from_dict(metadata.to_dict())
    assert back.retraction_screen.to_snapshot() == screen.to_snapshot()
    assert back.retraction_screen.checked_at == screen.checked_at
    assert len(back.retraction_screen.excluded) == 1
    assert ReportMetadata.from_dict({}).retraction_screen is None
    assert ReportMetadata().to_dict()["retraction_screen"] is None


def test_no_screen_report_has_no_retraction_text() -> None:
    """With no check run, no retraction fragment appears (chosen: absence, not a fixture)."""
    report = _report(None)
    for fragment in ("Retraction check:", "Left out as retracted", "Retraction Check",
                     "Retraction status", "Expression of concern"):
        assert fragment not in report


def _fragments(screen) -> tuple:
    """Everything the report reads of a screen."""
    return (
        format_retraction_notice(screen),
        format_retracted_section(screen),
        [format_reference_concern_annotation(r) for r in screen.to_snapshot()
         if r["status"] == RetractionStatus.CONCERN.value],
        checked_on_line(screen.checked_at),
        screen.unchecked_count,
        len(screen.excluded),
    )


def test_live_and_restored_screens_render_alike() -> None:
    """A report restored from storage says what the live run said."""
    live = _screen(
        a=RetractionStatus.CONCERN,
        b=RetractionStatus.RETRACTED,
        c=RetractionStatus.UNCHECKED,
        d=RetractionStatus.CLEAR,
    )
    restored = ReportMetadata.from_dict(ReportMetadata(retraction_screen=live).to_dict())
    live_parts, restored_parts = _fragments(live), _fragments(restored.retraction_screen)
    assert live_parts[1:] == restored_parts[1:]
    assert live_parts[4] == 1
    # a snapshot does not record why a paper went unchecked: the count only
    count_only = (
        "> **Retraction check:** 1 retracted paper left out; "
        "1 paper's retraction status could not be checked."
    )
    assert restored_parts[0] == count_only
    assert live_parts[0].startswith(count_only[:-1] + ": ")


def test_unreadable_stored_screens_read_as_absent() -> None:
    """A non-list value is None; a row with a bad time keeps its paper; neither raises."""
    assert ReportMetadata.from_dict({"retraction_screen": "oops"}).retraction_screen is None
    rows = _screen(a=RetractionStatus.RETRACTED, b=RetractionStatus.CLEAR).to_snapshot()
    rows[0]["checked_at"] = "not a time"
    restored = ReportMetadata.from_dict({"retraction_screen": rows}).retraction_screen
    assert sorted(r["document_id"] for r in restored.to_snapshot()) == ["a", "b"]
    assert [r["document_id"] for r in restored.excluded] == ["a"]  # still left out
    assert restored.checked_at is not None


def test_snapshot_rows_are_read_one_way_by_every_reader() -> None:
    """A truthy non-bool, an unknown status, a missing title: one reading for all."""
    from bmlibrarian_lite.retraction_screen import RetractionScreen

    rows = RetractionScreen.from_snapshot(
        [
            {"document_id": "a", "status": "retracted", "excluded": 1},
            {"document_id": "b", "status": "retracted_v2", "excluded": True, "deciding": "x"},
            {"document_id": "c", "status": "clear", "run_status": "retracted_v2", "run_deciding": "x"},
        ]
    )
    assert rows["a"]["excluded"] is False  # only true left a paper out
    assert rows["b"]["status"] == RetractionStatus.UNCHECKED.value
    assert rows["b"]["deciding"] is None
    assert rows["c"]["run_status"] == RetractionStatus.UNCHECKED.value
    assert rows["c"]["run_deciding"] is None
    assert "run_status" not in rows["a"]  # an older row gains no run fields
    assert rows["a"]["title"] == ""
    assert format_retracted_section(RetractionSnapshot.from_rows(rows.values())).startswith(
        "## Left out as retracted\n\n- . Retracted"
    )


def test_left_out_titles_cannot_break_the_markdown() -> None:
    """Newlines collapse and markdown specials are escaped."""
    doc = LiteDocument(id="x", title="A *bold*\n## claim [x]", abstract="")
    screen = screen_documents([doc], {"x": _check(RetractionStatus.RETRACTED, "10.9/n")})
    section = format_retracted_section(screen)
    assert section.count("\n") == 2
    assert "A \\*bold\\* ## claim \\[x\\]. Retracted" in section
