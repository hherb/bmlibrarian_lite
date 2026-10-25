# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The shared reader-facing sentences about retraction.

No provider text: a failure's cause comes from ``RequestFailure.describe()``.
"""

from __future__ import annotations

import re
from collections.abc import Iterable, Mapping, Sequence
from datetime import datetime
from typing import Any

from bmlib.publications.retraction_status import (
    RetractionLookup,
    RetractionSource,
    RetractionStatus,
    crossref_key,
)

from .retraction_checks import paper_key
from .retraction_export import ExportCopy, ExportState
from .retraction_screen import (
    RetractionRecord,
    RetractionScreen,
    as_utc,
    decided_checked_at,
    run_deciding_of,
)
from .retraction_store import PaperCheck

_NOTICE_OPENING = "> **Retraction check:** "
_NOTICE_SEPARATOR = "\n\n"
_RW = "Retraction Watch"
_CROSSREF = "Crossref"
_SOURCE_NAMES = {
    RetractionLookup.RETRACTION_WATCH_EXPORT: _RW,
    RetractionLookup.CROSSREF: _CROSSREF,
}


_EXPORT_CAUSE = "the Retraction Watch copy could not be used (run `bmll retractions-update`)"
_EXPORT_NOTICE_CAUSE = "a Retraction Watch notice could not be read"
_FAILED_CAUSE = "the check failed"
_NO_IDS_CAUSE = "no DOI or PMID"
_NO_DOI_CAUSE = "no DOI, which Crossref needs"
_CROSSREF_SILENT_CAUSE = "Crossref had no usable answer for the DOI"
_CANCELLED_CAUSE = "the check was cancelled before reaching them"


def _unchecked_causes(screen: RetractionScreen) -> list[str]:
    """Why the screen's kept papers are unchecked, each cause class once.

    In order: the check itself, the export copy or a notice in it, Crossref
    (its distinct ``RequestFailure.describe()`` causes, then papers it could
    not be asked about or gave no usable answer for), papers without
    identifiers, a cancel.

    Args:
        screen: A live screen; it knows each paper's identifiers and check.

    Returns:
        The causes, in that order; empty when no kept paper is unchecked.
    """
    found: set[str] = set()
    crossref: list[str] = []
    for doc in screen.kept:
        check = screen.checks.get(doc.id)
        if doc.id in screen.failed_ids:
            if check is None or check.verdict.status is RetractionStatus.UNCHECKED:
                found.add(_FAILED_CAUSE)
            continue
        if check is None:
            found.add(_CANCELLED_CAUSE)  # the cancelled check never reached it
            continue
        if check.verdict.status is not RetractionStatus.UNCHECKED:
            continue  # decided: no cause to give
        if paper_key(doc) is None:
            found.add(_NO_IDS_CAUSE)  # nothing could be looked up
            continue
        unanswered = check.verdict.unanswered
        if RetractionLookup.RETRACTION_WATCH_EXPORT in unanswered:
            # a consulted copy left unanswered holds a notice it cannot read
            found.add(_EXPORT_CAUSE if check.export_data_as_of is None else _EXPORT_NOTICE_CAUSE)
        if RetractionLookup.CROSSREF in unanswered:
            failure = check.crossref_failure
            if failure is not None:
                if failure.describe() not in crossref:
                    crossref.append(failure.describe())
            elif crossref_key(doc.doi) is None:
                found.add(_NO_DOI_CAUSE)
            else:
                found.add(_CROSSREF_SILENT_CAUSE)
    causes = [c for c in (_FAILED_CAUSE, _EXPORT_CAUSE, _EXPORT_NOTICE_CAUSE) if c in found]
    if crossref:
        causes.append(f"{_CROSSREF} could not be used ({', '.join(crossref)})")
    order = (_NO_DOI_CAUSE, _CROSSREF_SILENT_CAUSE, _NO_IDS_CAUSE, _CANCELLED_CAUSE)
    return causes + [c for c in order if c in found]


def run_summary_clause(screen: RetractionRecord) -> str | None:
    """Summarise a screen for a run's summary line, naming why papers are unchecked.

    A restored snapshot does not record why, so its clause gives the count only.

    Args:
        screen: A live screen or a restored snapshot.

    Returns:
        E.g. ``"2 retracted papers left out; 3 papers' retraction status could
        not be checked: no DOI or PMID"``; ``None`` when both counts are 0.
    """
    parts = []
    left_out = len(screen.excluded)
    if left_out:
        noun = "retracted paper" if left_out == 1 else "retracted papers"
        parts.append(f"{left_out:,} {noun} left out")
    unchecked = screen.unchecked_count
    if unchecked:
        owner = "1 paper's" if unchecked == 1 else f"{unchecked:,} papers'"
        clause = f"{owner} retraction status could not be checked"
        causes = _unchecked_causes(screen) if isinstance(screen, RetractionScreen) else []
        parts.append(f"{clause}: {'; '.join(causes)}" if causes else clause)
    return "; ".join(parts) or None


def format_retraction_notice(screen: RetractionRecord) -> str | None:
    """Build the notice for a report.

    Args:
        screen: A live screen or a restored snapshot.

    Returns:
        The notice line, or ``None`` when nothing was left out and every
        paper was checked.
    """
    clause = run_summary_clause(screen)
    if clause is None:
        return None
    return f"{_NOTICE_OPENING}{clause}."


def with_retraction_notice(text: str, screen: RetractionRecord) -> str:
    """Put the retraction notice in front of text; idempotent.

    Args:
        text: A report or a message standing in for one.
        screen: The run's screen.

    Returns:
        The text with the notice in front, or unchanged when there is no
        notice or it already opens with one.
    """
    notice = format_retraction_notice(screen)
    if notice is None or text.startswith(_NOTICE_OPENING):
        return text
    return f"{notice}{_NOTICE_SEPARATOR}{text}"


def without_retraction_notice(text: str) -> str:
    """Read what follows the notice, for deciding what a text is. Not for display."""
    if not text.startswith(_NOTICE_OPENING):
        return text
    _, separator, rest = text.partition(_NOTICE_SEPARATOR)
    return rest if separator else text


def checked_on_line(checked_at: datetime | None) -> str:
    """Say when the status was checked (the UTC date), or that it never was.

    Args:
        checked_at: The check time, or ``None``.

    Returns:
        The line.
    """
    if checked_at is None:
        return "Retraction status never checked"
    return f"Retraction status checked {as_utc(checked_at).date().isoformat()}"


def saved_work_line(rows: Iterable[Mapping[str, Any]]) -> str:
    """A reopened run's line: when its decided papers were checked, and how many were not.

    The date is the oldest check time among decided rows (retracted,
    concern, clear), so an unchecked answer's time never reads as a check.

    Args:
        rows: The run's snapshot rows.

    Returns:
        E.g. "Retraction status checked 2026-10-01; 2 papers could not be
        checked"; "Retraction status could not be checked" when no row is
        decided; "Retraction status never checked" without rows.
    """
    rows = list(rows)
    if not rows:
        return checked_on_line(None)
    unchecked = sum(1 for r in rows if r.get("status") == RetractionStatus.UNCHECKED.value)
    checked_at = decided_checked_at(rows)
    if checked_at is None:
        return "Retraction status could not be checked"
    line = checked_on_line(checked_at)
    if unchecked:
        line += f"; {'1 paper' if unchecked == 1 else f'{unchecked:,} papers'} could not be checked"
    return line


def retraction_methods_line(record: RetractionRecord) -> str:
    """The report's methods line: when the run's status was checked.

    A run that held papers and has no check time could not check any (the
    check failed, or was cancelled first); that is said, never a date.
    """
    if record.checked_at is None and record.to_snapshot():
        return "Retraction status could not be checked"
    return checked_on_line(record.checked_at)


_LABEL = " (PubMed's label)"

CHECK_AGAIN_LABEL = "Check again"
CHECKING_AGAIN_LINE = "Checking retraction status…"
CHECK_AGAIN_FAILED = "; it could not be checked again, so this is still the run's record"
CHECK_AGAIN_NOT_SAVED = "; the new status could not be saved with this run"
NO_AUDIT_RECORD_LINE = "Retraction status not recorded for this report"
STORED_CHECKS_UNREAD = "; later checks could not be read"


def not_checked_again_clause(count: int) -> str:
    """*Check again*'s note for decided papers no source answered this time, whose record stays; "" for none."""
    if not count:
        return ""
    return f"; {'1 paper' if count == 1 else f'{count:,} papers'} could not be checked again"


def saved_work_warning(
    changed: Sequence[tuple[str, PaperCheck]], titles: Mapping[str, str]
) -> str | None:
    """Warn that papers a saved report cites are now retracted or under concern.

    Plain text, one paper per line. It suggests re-running the question; it
    runs nothing, and the report is not rewritten.

    Args:
        changed: (document id, check) pairs, as ``changed_since_snapshot`` gives them.
        titles: Titles by document id; a missing one is named by its id.

    Returns:
        The warning; ``None`` when nothing changed.
    """
    if not changed:
        return None
    count = len(changed)
    subject = "1 paper this report cites has" if count == 1 else f"{count:,} papers this report cites have"
    lines = [f"Since this report was written, {subject} a retraction warning:"]
    for doc_id, check in changed:
        title = " ".join(str(titles.get(doc_id) or doc_id).split())
        lines.append(f"• {title}: {paper_status_line(check)}")
    lines.append("The report has not been changed; re-run the question to bring it up to date.")
    return "\n".join(lines)


def with_pass_retraction_clause(text: str, clause: str) -> str:
    """Add a pass's retraction clause (``run_summary_clause``) to its final line."""
    return f"{text.rstrip().rstrip('.')}; {clause}." if clause else text


#: A pass's offer counts papers before its screen runs (in the worker), so it says what the screen will do
PASS_LEFT_OUT_SENTENCE = "Retracted papers are left out before the work starts."


def retraction_check_line(clause: str) -> str:
    """A screen's clause as a line of its own, e.g. "Retraction check: 2 retracted papers left out."."""
    return f"Retraction check: {clause}."


def pass_retraction_note(clause: str, titles: Sequence[str] = ()) -> str:
    """A pass's retraction clause as a dialog's closing paragraph, naming the papers left out; "" without one."""
    if not clause:
        return ""
    return "\n\n" + "\n".join([retraction_check_line(clause), *(f"• {' '.join(t.split())}" for t in titles)])


def paper_status_line(check: PaperCheck) -> str:
    """One paper's status, for a banner or an MCP header.

    Args:
        check: The paper's check.

    Returns:
        "Retracted" or "Expression of concern" with the deciding notice's
        date and DOI (or "(PubMed's label)"), "Retraction status not
        checked" naming the unanswered sources, or "No retraction found";
        then the export copy's day when it was consulted.
    """
    verdict = check.verdict
    evidence = verdict.deciding
    if verdict.status in (RetractionStatus.RETRACTED, RetractionStatus.CONCERN):
        retracted = verdict.status is RetractionStatus.RETRACTED
        line = "Retracted" if retracted else "Expression of concern"
        # the label, not a notice: a notice without a DOI (the export's
        # "unavailable") is still Retraction Watch's or Crossref's
        if evidence is None or evidence.source is RetractionSource.PUBMED_LABEL:
            line += _LABEL
        else:
            if evidence.date:
                line += f" on {evidence.date}" if retracted else f", {evidence.date}"
            if evidence.notice_doi:
                line += f" (notice {evidence.notice_doi})"
    elif verdict.status is RetractionStatus.UNCHECKED:
        names = []
        for lookup in verdict.unanswered:
            name = _SOURCE_NAMES[lookup]
            if lookup is RetractionLookup.CROSSREF and check.crossref_failure is not None:
                name = f"{name} ({check.crossref_failure.describe()})"
            names.append(name)
        line = "Retraction status not checked"
        if names:
            line += ": " + ", ".join(names)
    else:
        line = "No retraction found"
    if check.export_data_as_of is not None:
        line += f"; {_RW} data as of {check.export_data_as_of.isoformat()}"
    return line


LEFT_OUT_HEADING = "## Left out as retracted"
_CONCERN_INDENT = "    "


def _evidence_parts(row: Mapping[str, Any]) -> tuple[str | None, str | None]:
    """The date and DOI of the deciding notice the run saw, from a snapshot row."""
    deciding = run_deciding_of(row) or {}
    return deciding.get("date"), deciding.get("notice_doi")


def _row_by_label(row: Mapping[str, Any]) -> bool:
    """Whether the run's verdict in a snapshot row rests on PubMed's label."""
    deciding = run_deciding_of(row) or {}
    return deciding.get("source") in (None, RetractionSource.PUBMED_LABEL.value)


_MARKDOWN_SPECIALS = re.compile(r"([\\`*_\[\]<>])")


def plain_title(title: str) -> str:
    """A title safe inside one markdown line: whitespace collapsed, specials escaped."""
    return _MARKDOWN_SPECIALS.sub(r"\\\1", " ".join(str(title).split()))


def format_retracted_section(screen: RetractionRecord) -> str:
    """List the papers a run left out, from the screen's snapshot rows.

    Returns:
        The ``LEFT_OUT_HEADING`` section, one "- " line per paper ("<title>.
        Retracted <date>; notice <doi>", or "Retracted (PubMed's label)"),
        titles escaped by :func:`plain_title`; "" when nothing was left out.
    """
    lines = []
    for row in screen.to_snapshot():
        if not row.get("excluded"):
            continue
        when, notice = _evidence_parts(row)
        line = f"- {plain_title(row['title'])}. Retracted"
        if _row_by_label(row):
            line += _LABEL
        else:
            line += f" {when}" if when else ""
            line += f"; notice {notice}" if notice else ""
        lines.append(line)
    return f"{LEFT_OUT_HEADING}\n\n" + "\n".join(lines) if lines else ""


def format_reference_concern_annotation(row: Mapping[str, Any]) -> str:
    """Caveat for a cited paper under an expression of concern (a snapshot row)."""
    when, notice = _evidence_parts(row)
    detail = ", ".join(
        part for part in (when, f"notice {notice}" if notice else None) if part
    )
    return f"{_CONCERN_INDENT}⚠️ Expression of concern" + (f" ({detail})" if detail else "")


_BADGE_TEXTS = {
    RetractionStatus.RETRACTED: "RETRACTED",
    RetractionStatus.CONCERN: "CONCERN",
    RetractionStatus.UNCHECKED: "NOT CHECKED",
}
EXCLUDED_RETRACTED_LABEL = "Excluded: retracted"


def excluded_line(run_check: PaperCheck, current: PaperCheck) -> str:
    """A left-out paper's card line: why the run left it out, then its status now when that differs.

    Args:
        run_check: The check as the run saw it.
        current: The latest check (*Check again*'s, or the run's own).
    """
    line = f"{EXCLUDED_RETRACTED_LABEL}. {paper_status_line(run_check)}"
    now = paper_status_line(current)
    return line if now == paper_status_line(run_check) else f"{line}. Checked again: {now}"


def badge_text(status: RetractionStatus) -> str | None:
    """A status badge's text; ``None`` for clear, which shows no badge."""
    return _BADGE_TEXTS.get(status)


_EXPORT_STATE_WORDS = {
    ExportState.CURRENT: "current",
    ExportState.STALE: "out of date",
    ExportState.MISSING: "missing",
    ExportState.UNREADABLE: "unreadable",
}


def export_refreshed_line(copy: ExportCopy) -> str:
    """Say that ``bmll retractions-update`` built a new copy."""
    as_of = copy.data_as_of.isoformat() if copy.data_as_of else "unknown"
    return f"Retraction Watch copy refreshed; data as of {as_of}."


def export_not_refreshed_line(copy: ExportCopy) -> str:
    """Say that a refresh built no new copy, and what is kept, in words."""
    state = _EXPORT_STATE_WORDS[copy.state]
    if copy.data_as_of is None:
        return f"Refresh did not produce a new copy; there is no copy to keep (the copy is {state})."
    return (
        f"Refresh did not produce a new copy; the kept copy is {state}, "
        f"data as of {copy.data_as_of.isoformat()}."
    )


def refresh_failed_line(error: BaseException) -> str:
    """Say a refresh failed, naming the error's type only (never its text)."""
    return f"Refresh failed: {type(error).__name__}."
