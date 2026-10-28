"""The reader's retraction sentences (pure)."""

from __future__ import annotations

from datetime import UTC, date, datetime

import pytest
from bmlib.publications.retraction_status import (
    RetractionEvidence,
    RetractionKind,
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    RetractionVerdict,
)

from bmlibrarian_lite.data_models import LiteDocument, RequestFailure, RequestFailureKind
from bmlibrarian_lite.retraction_screen import (
    RetractionScreen,
    RetractionSnapshot,
    screen_documents,
    screen_with_fallback,
)
from bmlibrarian_lite.retraction_store import PaperCheck
from bmlibrarian_lite.retraction_text import (
    checked_on_line,
    format_retracted_section,
    format_retraction_notice,
    paper_status_line,
    retraction_methods_line,
    run_summary_clause,
    with_retraction_notice,
    without_retraction_notice,
)

WHEN = datetime(2026, 10, 18, 9, 30, tzinfo=UTC)
BOTH = (RetractionLookup.RETRACTION_WATCH_EXPORT, RetractionLookup.CROSSREF)
RW_CAUSE = "the Retraction Watch copy could not be used (run `bmll retractions-update`)"


def _doc(i: str) -> LiteDocument:
    """Doc."""
    return LiteDocument(id=i, title=f"Title {i}", abstract="", doi=f"10.1/{i}", pmid="1")


def _check(status, deciding=None, unanswered=(), failure=None, asof=date(2026, 10, 1), at=WHEN):
    """Check."""
    return PaperCheck(RetractionVerdict(status, deciding, unanswered), at, asof, failure)


def _evidence(notice="10.9/n", day="2026-03-09", kind=RetractionKind.RETRACTION):
    """Evidence."""
    return RetractionEvidence(
        source=RetractionSource.RETRACTION_WATCH_EXPORT, kind=kind, date=day, notice_doi=notice
    )


def _screen(retracted: int, unchecked: int) -> RetractionScreen:
    """Screen."""
    docs, checks = [], {}
    for i in range(retracted):
        docs.append(_doc(f"r{i}"))
        checks[f"r{i}"] = _check(RetractionStatus.RETRACTED, _evidence())
    for i in range(unchecked):
        docs.append(_doc(f"u{i}"))
        # the copy was not consulted, so no day is recorded; Crossref answered
        checks[f"u{i}"] = _check(
            RetractionStatus.UNCHECKED, unanswered=BOTH[:1], asof=None
        )
    return screen_documents(docs, checks)


def test_summary_clause_counts_and_singulars():
    """Test summary clause counts and singulars."""
    assert run_summary_clause(_screen(0, 0)) is None
    assert run_summary_clause(_screen(1, 0)) == "1 retracted paper left out"
    assert run_summary_clause(_screen(2, 3)) == (
        "2 retracted papers left out; 3 papers' retraction status could not be checked: "
        + RW_CAUSE
    )
    assert run_summary_clause(_screen(0, 1)) == (
        "1 paper's retraction status could not be checked: " + RW_CAUSE
    )


def test_notice_is_idempotent():
    """Test notice is idempotent."""
    screen = _screen(2, 0)
    notice = format_retraction_notice(screen)
    assert notice == "> **Retraction check:** 2 retracted papers left out."
    once = with_retraction_notice("Report", screen)
    assert once == f"{notice}\n\nReport"
    assert with_retraction_notice(once, screen) == once
    assert without_retraction_notice(once) == "Report"
    assert with_retraction_notice("Report", _screen(0, 0)) == "Report"
    assert format_retraction_notice(_screen(0, 0)) is None


def test_checked_on_line():
    """Test checked on line."""
    assert checked_on_line(WHEN) == "Retraction status checked 2026-10-18"
    assert checked_on_line(None) == "Retraction status never checked"


def test_status_lines():
    """Test status lines."""
    asof = "; Retraction Watch data as of 2026-10-01"
    assert (
        paper_status_line(_check(RetractionStatus.RETRACTED, _evidence()))
        == "Retracted on 2026-03-09 (notice 10.9/n)" + asof
    )
    label = RetractionEvidence(RetractionSource.PUBMED_LABEL, RetractionKind.RETRACTION)
    assert (
        paper_status_line(_check(RetractionStatus.RETRACTED, label, asof=None))
        == "Retracted (PubMed's label)"
    )
    concern = _evidence(kind=RetractionKind.EXPRESSION_OF_CONCERN, day="2026-03")
    assert (
        paper_status_line(_check(RetractionStatus.CONCERN, concern))
        == "Expression of concern, 2026-03 (notice 10.9/n)" + asof
    )


def test_status_lines_carry_no_provider_text():
    """Only RequestFailure.describe() speaks for a failed source."""
    failure = RequestFailure(RequestFailureKind.HTTP_STATUS, 503)
    line = paper_status_line(
        _check(
            RetractionStatus.UNCHECKED,
            unanswered=(RetractionLookup.CROSSREF,),
            failure=failure,
        )
    )
    assert line == (
        f"Retraction status not checked: Crossref ({failure.describe()}); "
        "Retraction Watch data as of 2026-10-01"
    )


def test_unchecked_export_unanswered_has_no_as_of_clause():
    """An export that was not consulted has no data date to report."""
    line = paper_status_line(
        _check(
            RetractionStatus.UNCHECKED,
            unanswered=(RetractionLookup.RETRACTION_WATCH_EXPORT,),
            asof=None,
        )
    )
    assert line == "Retraction status not checked: Retraction Watch"


def test_unchecked_both_unanswered_names_both():
    """Both sources silent and no failure recorded: names, no cause clause."""
    line = paper_status_line(_check(RetractionStatus.UNCHECKED, unanswered=BOTH, asof=None))
    assert line == "Retraction status not checked: Retraction Watch, Crossref"


def test_clear_line():
    """A clear paper says so and still dates the export."""
    assert (
        paper_status_line(_check(RetractionStatus.CLEAR))
        == "No retraction found; Retraction Watch data as of 2026-10-01"
    )


def test_retracted_with_notice_but_no_as_of():
    """The as-of clause appears only when the export was consulted."""
    assert (
        paper_status_line(_check(RetractionStatus.RETRACTED, _evidence(), asof=None))
        == "Retracted on 2026-03-09 (notice 10.9/n)"
    )


def test_concern_without_a_date():
    """A concern notice with no date omits the date part."""
    concern = _evidence(kind=RetractionKind.EXPRESSION_OF_CONCERN, day=None)
    assert (
        paper_status_line(_check(RetractionStatus.CONCERN, concern, asof=None))
        == "Expression of concern (notice 10.9/n)"
    )


def test_checked_on_line_reads_a_naive_datetime_as_utc():
    """A naive time is read as UTC, not rejected or shifted."""
    assert checked_on_line(datetime(2026, 10, 18, 23, 59)) == "Retraction status checked 2026-10-18"


def test_a_retraction_watch_retraction_without_a_notice_doi_is_not_pubmeds():
    """The export's "unavailable" notice DOI becomes None; the date still shows, PubMed is not named."""
    rw = _evidence(notice=None)
    line = paper_status_line(_check(RetractionStatus.RETRACTED, rw, asof=None))
    assert line == "Retracted on 2026-03-09"
    assert "PubMed" not in line
    crossref = RetractionEvidence(RetractionSource.CROSSREF_PUBLISHER, RetractionKind.RETRACTION)
    assert paper_status_line(_check(RetractionStatus.RETRACTED, crossref, asof=None)) == "Retracted"
    # control: the label is still the label, and a concern by label says so
    label = RetractionEvidence(RetractionSource.PUBMED_LABEL, RetractionKind.RETRACTION)
    assert (
        paper_status_line(_check(RetractionStatus.RETRACTED, label, asof=None))
        == "Retracted (PubMed's label)"
    )
    concern_label = RetractionEvidence(
        RetractionSource.PUBMED_LABEL, RetractionKind.EXPRESSION_OF_CONCERN
    )
    assert (
        paper_status_line(_check(RetractionStatus.CONCERN, concern_label, asof=None))
        == "Expression of concern (PubMed's label)"
    )


def test_the_left_out_section_names_pubmed_only_for_the_label():
    """The report's section follows the evidence's source, not the notice DOI's presence."""
    rw, label = _doc("rw"), _doc("label")
    screen = screen_documents(
        [rw, label],
        {
            "rw": _check(RetractionStatus.RETRACTED, _evidence(notice=None)),
            "label": _check(
                RetractionStatus.RETRACTED,
                RetractionEvidence(RetractionSource.PUBMED_LABEL, RetractionKind.RETRACTION),
            ),
        },
    )
    section = format_retracted_section(screen)
    assert "- Title rw. Retracted 2026-03-09\n" in section + "\n"
    assert "- Title label. Retracted (PubMed's label)" in section


def _unchecked_doc(i, doi="10.1/x", pmid=None):
    return LiteDocument(id=i, title=f"T {i}", abstract="", doi=doi, pmid=pmid)


def test_the_summary_names_why_papers_are_unchecked():
    """Each cause class, de-duplicated, in one sentence; no provider text."""
    throttled = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    timeout = RequestFailure(RequestFailureKind.TIMEOUT)
    crossref = (RetractionLookup.CROSSREF,)
    export = (RetractionLookup.RETRACTION_WATCH_EXPORT,)
    cases = {
        "export": ([_unchecked_doc("a")], {"a": _check(RetractionStatus.UNCHECKED, unanswered=export, asof=None)}),
        "crossref": (
            [_unchecked_doc("a"), _unchecked_doc("b"), _unchecked_doc("c")],
            {
                "a": _check(RetractionStatus.UNCHECKED, unanswered=crossref, failure=throttled),
                "b": _check(RetractionStatus.UNCHECKED, unanswered=crossref, failure=throttled),
                "c": _check(RetractionStatus.UNCHECKED, unanswered=crossref, failure=timeout),
            },
        ),
        "ids": (
            [_unchecked_doc("a", doi=None)],
            {"a": _check(RetractionStatus.UNCHECKED, unanswered=BOTH, asof=None)},
        ),
    }
    clauses = {name: run_summary_clause(screen_documents(*case)) for name, case in cases.items()}
    assert clauses["export"] == "1 paper's retraction status could not be checked: " + RW_CAUSE
    assert clauses["crossref"] == (
        "3 papers' retraction status could not be checked: Crossref could not be used "
        f"({throttled.describe()}, {timeout.describe()})"
    )
    assert clauses["ids"] == "1 paper's retraction status could not be checked: no DOI or PMID"


def test_a_mixed_run_names_every_cause_once():
    """Export missing for all, Crossref throttled for one, one with no identifier."""
    throttled = RequestFailure(RequestFailureKind.HTTP_STATUS, 429)
    docs = [_unchecked_doc("a"), _unchecked_doc("b"), _unchecked_doc("n", doi=None), _doc("r")]
    checks = {
        "a": _check(RetractionStatus.UNCHECKED, unanswered=BOTH, failure=throttled, asof=None),
        "b": _check(RetractionStatus.UNCHECKED, unanswered=BOTH, failure=throttled, asof=None),
        "n": _check(RetractionStatus.UNCHECKED, unanswered=BOTH, asof=None),
        "r": _check(RetractionStatus.RETRACTED, _evidence()),
    }
    screen = screen_documents(docs, checks)
    clause = run_summary_clause(screen)
    assert clause == (
        "1 retracted paper left out; 3 papers' retraction status could not be checked: "
        f"{RW_CAUSE}; Crossref could not be used ({throttled.describe()}); no DOI or PMID"
    )
    assert format_retraction_notice(screen) == f"> **Retraction check:** {clause}."


class _Broken:
    def check(self, documents, **_kw):
        raise RuntimeError("secret provider text")

    def close(self):
        pass


def test_a_failed_check_says_so_in_the_summary_and_the_methods_line():
    """Every check stood in for a failure: no check date, and the cause is the check."""
    screen = screen_with_fallback(_Broken(), [_doc("a"), _doc("b")])
    assert run_summary_clause(screen) == (
        "2 papers' retraction status could not be checked: the check failed"
    )
    assert retraction_methods_line(screen) == "Retraction status could not be checked"
    restored = RetractionSnapshot.from_rows(screen.to_snapshot())
    assert retraction_methods_line(restored) == "Retraction status could not be checked"
    # control: a run that checked says when
    assert retraction_methods_line(_screen(1, 0)) == "Retraction status checked 2026-10-18"
    assert retraction_methods_line(screen_documents([], {})) == "Retraction status never checked"


def test_a_partly_checked_run_counts_its_unchecked_papers_in_the_methods_line():
    """#631 item 6: the methods line alone never reads as complete."""
    assert retraction_methods_line(_screen(1, 1)) == (
        "Retraction status checked 2026-10-18; 1 paper could not be checked"
    )
    assert retraction_methods_line(_screen(1, 2)).endswith("; 2 papers could not be checked")
    restored = RetractionSnapshot.from_rows(_screen(1, 2).to_snapshot())
    assert retraction_methods_line(restored) == retraction_methods_line(_screen(1, 2))


@pytest.mark.parametrize(
    ("doc", "check", "cause"),
    [
        (
            LiteDocument(id="p", title="t", abstract="", pmid="12345678"),
            _check(RetractionStatus.UNCHECKED, unanswered=BOTH[1:]),
            "no DOI, which Crossref needs",
        ),
        (
            _doc("d"),
            _check(RetractionStatus.UNCHECKED, unanswered=BOTH[1:]),
            "Crossref had no usable answer for the DOI",
        ),
        (
            _doc("n"),
            _check(RetractionStatus.UNCHECKED, unanswered=BOTH[:1]),
            "a Retraction Watch notice could not be read",
        ),
        (_doc("c"), None, "the check was cancelled before reaching them"),
    ],
    ids=["pmid-only", "crossref-silent", "unreadable-notice", "cancelled"],
)
def test_every_unchecked_paper_has_a_named_cause(doc, check, cause):
    """A count with no reason sent readers to the wrong fix."""
    screen = screen_documents([doc], {doc.id: check} if check else {})
    assert run_summary_clause(screen) == (
        f"1 paper's retraction status could not be checked: {cause}"
    )


def test_the_notice_does_not_claim_papers_were_left_out_when_none_were():
    """Only unchecked papers: the notice says what the check found, nothing more."""
    notice = format_retraction_notice(_screen(0, 1))
    assert notice is not None
    assert notice.startswith("> **Retraction check:** 1 paper's")
    assert "left out" not in notice
