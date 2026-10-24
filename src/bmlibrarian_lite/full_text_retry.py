# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Retry Full Text: read a reviewed question's unread full texts, and write its report again.

The rules are the apps' (iOS/macOS's ``retryFullTextRetrieval``): every
paper of the question's reviewed run scored at or above the full-text score
whose citations were not read from its full text is asked for it again,
when the full-text setting is on. A relevant paper whose uploaded full text
(``uploaded_full_texts_store``) was stored after the texts of its last read
from full text were taken, or that was never read from full text, is read
from the upload, whatever the setting or score. A paper whose text arrives
has its citations extracted from it; they replace its old ones only when
the text yields passages, and either way it is recorded as read. Its
transparency is analysed again with that text. When at least one full text
was read the report is written again; when none was, the report stands. A
retry that read a text and stopped before writing the report leaves a mark,
so the next one writes it even when it reads nothing new. Nothing here
imports Qt.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from .analysis_failures import pass_failure_detail
from .audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    checkpoint_metadata_with_extraction_failures,
    checkpoint_metadata_with_report_metadata,
    recorded_extraction_failures,
    recorded_report_metadata,
    recorded_retraction_snapshot,
)
from .chunking import analysis_windows
from .citation_full_texts import FullTextFetch, fetch_full_texts
from .citation_text import full_text_min_score, record_full_text_reads, record_uploaded_reads
from .data_models import (
    AnalysisStage,
    CitationOutcome,
    PassFailure,
    ReportMetadata,
    ScoredDocument,
)
from .retraction_screen import RetractionSnapshot
from .transparency.assessment import record_transparency_counts
from .utils import classify_analysis_exception

if TYPE_CHECKING:
    from .agents.citation_agent import LiteCitationAgent
    from .agents.reporting_agent import LiteReportingAgent
    from .config import LiteConfig
    from .data_models import LiteDocument
    from .full_text_upload import UploadedFullText
    from .storage import LiteStorage

logger = logging.getLogger(__name__)

#: Analyses one paper's transparency again with its full text.
AssessTransparency = Callable[["LiteDocument", str], None]

#: Checkpoint metadata: a retry stored citations read from a full text and
#: has not yet written the report with them.
REPORT_PENDING_KEY = "full_text_report_pending"

RETRY_FULL_TEXT_ACTION = "Retry Full Text"
UPLOADS_ONLY_TEXT = (
    "Read the full texts uploaded on the Audit Trail's cards, and write the "
    "report again. To fetch full texts too, turn on reading citations from "
    "full text in Settings > Full Text."
)
NOTHING_TO_READ_TEXT = (
    "No paper of this question scored at or above its threshold has an "
    "uploaded full text its citations have not been read from. Upload one from a paper's card in the Audit Trail, "
    "or turn on reading citations from full text in Settings > Full Text."
)
NO_REPORT_TEXT = "This question has no report to take further; run the review first."
NOT_KEPT_TEXT = (
    "This report's run did not keep, or cannot read back, what writing the "
    "report again needs. Run the review again to read its papers' full texts."
)
NO_NEW_FULL_TEXT_TEXT = "No further full text was read, so the report is unchanged."
CANCELLED_TEXT = "Cancelled, so the report is unchanged."
CANCELLED_PENDING_TEXT = (
    "Cancelled before the report was written again: the citations read are "
    "kept, and the next Retry Full Text writes the report with them."
)


class RetryNotPossible(Exception):
    """A retry that cannot run for this question; the message is the reader's."""


@dataclass(frozen=True)
class FullTextRetry:
    """What a retry of a question's full texts did.

    Attributes:
        asked: Papers whose full text was asked for, an upload's included;
            a cancel can stop before every paper due was asked.
        read: Of those, papers whose citations were read from it.
        replaced: Of those, papers whose citations its passages replaced.
        unavailable: Papers for which no full text, or none with anything
            before its references, was obtained.
        failures: Papers whose full text was obtained but could not be read,
            each with why.
        transparency_failures: Papers read whose transparency could not be
            analysed again; their stored assessment stands.
        report: The report written again, or None when it was not.
        cancelled: Whether a cancel stopped the retry before its end; a
            cancelled retry writes no report.
    """

    asked: int = 0
    read: int = 0
    replaced: int = 0
    unavailable: int = 0
    failures: tuple[PassFailure, ...] = ()
    transparency_failures: tuple[PassFailure, ...] = ()
    report: str | None = None
    cancelled: bool = False

    @property
    def failed(self) -> int:
        """How many full texts were obtained but could not be read."""
        return len(self.failures)


def retry_text(outcome: FullTextRetry) -> str:
    """What the reader is told a retry did.

    Args:
        outcome: The retry's outcome.

    Returns:
        A sentence or several.
    """
    parts: list[str] = []
    if outcome.asked:
        parts.append(
            f"Asked for {outcome.asked} full text{'s' if outcome.asked != 1 else ''}: "
            f"{outcome.read} read, {outcome.unavailable} not obtained"
            + (f", {outcome.failed} could not be read" if outcome.failed else "")
            + "."
        )
    elif not outcome.cancelled and outcome.report is None:
        # Only a retry that sought full texts gets here: one that did not is refused
        parts.append("Every paper scored high enough was already read from its full text.")
    if outcome.cancelled:
        parts.append(CANCELLED_PENDING_TEXT if outcome.read else CANCELLED_TEXT)
    elif outcome.report is None:
        if outcome.asked:
            parts.append(NO_NEW_FULL_TEXT_TEXT)
    elif outcome.read:
        parts.append("The report was written again.")
    else:
        parts.append("The report was written again with the citations an earlier retry read.")
    if outcome.failures:
        parts.append(pass_failure_detail(outcome.failures))
    if outcome.transparency_failures:
        count = len(outcome.transparency_failures)
        parts.append(
            f"Transparency could not be analysed again for {count} "
            f"paper{'s' if count != 1 else ''}; the earlier assessment stands. "
            + pass_failure_detail(outcome.transparency_failures)
        )
    return " ".join(parts)


def retry_full_texts(
    question: str,
    storage: LiteStorage,
    config: LiteConfig,
    fetch: FullTextFetch,
    citation_agent: LiteCitationAgent,
    reporting_agent: LiteReportingAgent,
    assess_transparency: AssessTransparency | None,
    should_stop: Callable[[], bool],
    progress: Callable[[int, int, str], None] | None = None,
) -> FullTextRetry:
    """Read a reviewed question's unread full texts, and write its report again.

    Args:
        question: The research question.
        storage: The store the run is read from and written to.
        config: The configuration, for the full-text setting and score.
        fetch: Fetches one paper's full text.
        citation_agent: Extracts the citations.
        reporting_agent: Writes the report.
        assess_transparency: Analyses a paper's transparency with its full
            text; None when transparency analysis is off.
        should_stop: Asked between papers; true cancels the retry.
        progress: Told (current, total, message) along the way.

    Returns:
        What the retry did.

    Raises:
        RetryNotPossible: The question has no report, or its run did not
            keep the report's metadata, or it cannot be read back, or, with
            the full-text setting off, it has no unread upload to read and
            no report owed (:data:`REPORT_PENDING_KEY`).
    """
    checkpoint = storage.get_checkpoint_for_question(question)
    if checkpoint is None or not checkpoint.report:
        raise RetryNotPossible(NO_REPORT_TEXT)
    metadata = recorded_report_metadata(checkpoint.metadata)
    if metadata is None:
        raise RetryNotPossible(NOT_KEPT_TEXT)
    stored_min = checkpoint.metadata.get(CHECKPOINT_MIN_SCORE_KEY)
    min_score = (
        stored_min
        if isinstance(stored_min, int) and not isinstance(stored_min, bool)
        else metadata.min_score_threshold
    )
    threshold = full_text_min_score(min_score, config.discovery.full_text_min_score)

    scored = storage.get_scored_documents_for_question(question, checkpoint_id=checkpoint.id)
    seeking = config.discovery.citations_from_full_text
    read_at = storage.get_citation_full_text_read_at(checkpoint.id)
    # Before the uploads are read: one stored after this is read next time
    taken_at = datetime.now(UTC)
    uploads = storage.get_uploaded_full_texts([d.document.id for d in scored])
    targets = [
        d for d in scored
        if is_due(d, min_score=min_score, threshold=threshold, seeking=seeking,
                  upload=uploads.get(d.document.id), read_at=read_at.get(d.document.id))
    ]
    pending = checkpoint.metadata.get(REPORT_PENDING_KEY) is True
    if not targets and not seeking and not pending:
        raise RetryNotPossible(NOTHING_TO_READ_TEXT)
    outcome = FullTextRetry()
    if targets:
        outcome = _read_full_texts(
            question, storage, checkpoint.id, targets, min_score, fetch, uploads,
            taken_at, citation_agent, assess_transparency, should_stop, progress,
        )
    if outcome.cancelled or should_stop():
        return replace(outcome, cancelled=True)
    if outcome.read == 0 and not pending:
        return outcome
    if progress:
        progress(0, 1, "Writing the report again")
    report = write_report_again(
        question, storage, checkpoint.id, metadata, scored, min_score, threshold,
        seeking, set(uploads), reporting_agent,
    )
    return replace(outcome, report=report)


def is_due(
    paper: ScoredDocument,
    *,
    min_score: int,
    threshold: int,
    seeking: bool,
    upload: UploadedFullText | None,
    read_at: datetime | None,
) -> bool:
    """Whether a retry reads a paper's full text.

    Args:
        paper: The scored paper.
        min_score: The run's relevance threshold.
        threshold: The full-text score.
        seeking: Whether the full-text setting is on.
        upload: The paper's uploaded full text, if any.
        read_at: When the texts of its last read from full text were
            taken, if it was ever read from full text.

    Returns:
        True for a relevant paper with an upload that was never read from
        full text, or whose upload was stored after that read's texts were
        taken, whatever the setting or score; otherwise, with the setting
        on, for a paper at the full-text score never read from full text.
    """
    if upload is not None and paper.score >= min_score:
        return read_at is None or (
            upload.uploaded_at is not None and upload.uploaded_at > read_at
        )
    return seeking and paper.score >= threshold and read_at is None


def _read_full_texts(
    question: str,
    storage: LiteStorage,
    checkpoint_id: str,
    targets: list[ScoredDocument],
    min_score: int,
    fetch: FullTextFetch,
    uploads: dict[str, UploadedFullText],
    taken_at: datetime,
    citation_agent: LiteCitationAgent,
    assess_transparency: AssessTransparency | None,
    should_stop: Callable[[], bool],
    progress: Callable[[int, int, str], None] | None,
) -> FullTextRetry:
    """Fetch the targets' full texts, and read each one that arrives.

    A paper with an upload is read from it, never fetched.

    Each paper read is stored as it is read, after the run is marked as
    owing its report (:data:`REPORT_PENDING_KEY`).

    Args:
        question: The research question.
        storage: The store.
        checkpoint_id: The run's checkpoint.
        targets: The papers whose full text is asked for.
        min_score: The run's relevance threshold.
        fetch: Fetches one paper's full text.
        uploads: The uploaded full texts by paper id.
        taken_at: When the uploads were read; each read is recorded at it.
        citation_agent: Extracts the citations.
        assess_transparency: Analyses a paper's transparency, or None.
        should_stop: Asked between papers.
        progress: Told (current, total, message) along the way.

    Returns:
        What was read; no report.
    """
    asked: list[str] = []

    def counted(doc: LiteDocument) -> str | None:
        asked.append(doc.id)
        upload = uploads.get(doc.id)
        return upload.text if upload is not None else fetch(doc)

    def fetching(current: int, total: int) -> None:
        if progress:
            progress(current, total, f"Getting full text {current}/{total}")

    fetched = fetch_full_texts(counted, [d.document for d in targets], should_stop, fetching)
    # A text with nothing before its references has nothing to read
    texts = {doc_id: text for doc_id, text in fetched.items() if analysis_windows(text)}
    outcome = FullTextRetry(asked=len(asked), unavailable=len(asked) - len(texts))
    marked = False
    for position, target in enumerate((t for t in targets if t.document.id in texts), start=1):
        if should_stop():
            return replace(outcome, cancelled=True)
        if progress:
            progress(position, len(texts), f"Reading full text {position}/{len(texts)}")
        doc_id = target.document.id
        extraction = citation_agent.extract_all_citations(
            question, [target], min_score=min_score, full_texts={doc_id: texts[doc_id]}
        )
        if doc_id not in extraction.read_full_text:
            outcome = replace(outcome, failures=outcome.failures + tuple(
                PassFailure(document_id=f.document.id, cause=f.cause) for f in extraction.failed
            ))
            continue
        if not marked:
            _mark_report_pending(storage, checkpoint_id)
            marked = True
        if extraction.citations:
            storage.replace_document_citations(
                checkpoint_id, doc_id, extraction.citations, read_at=taken_at
            )
            outcome = replace(outcome, replaced=outcome.replaced + 1)
        else:
            # Read, and nothing quotable in it: the old citations stand
            storage.record_citation_reads(checkpoint_id, {doc_id: True}, read_at=taken_at)
        outcome = replace(outcome, read=outcome.read + 1)
        if assess_transparency is not None:
            try:
                assess_transparency(target.document, texts[doc_id])
            except Exception as e:
                # The stored assessment stands; the report counts it as it is
                logger.exception("Transparency could not be analysed again for %s", doc_id)
                outcome = replace(outcome, transparency_failures=outcome.transparency_failures
                                  + (PassFailure(document_id=doc_id,
                                                 cause=classify_analysis_exception(e)),))
    return outcome


def _mark_report_pending(storage: LiteStorage, checkpoint_id: str) -> None:
    """Mark the run as owing a report, before its citations change.

    A cancel or a failure after this leaves citations the report does not
    hold; the mark makes the next retry write it even when it reads nothing.

    Args:
        storage: The store.
        checkpoint_id: The run's checkpoint.
    """
    current = storage.get_checkpoint(checkpoint_id)
    stored = current.metadata if current is not None else {}
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        metadata={**stored, REPORT_PENDING_KEY: True},
        touch=False,  # a note on this run, not a new latest
    )


def write_report_again(
    question: str,
    storage: LiteStorage,
    checkpoint_id: str,
    metadata: ReportMetadata,
    scored: list[ScoredDocument],
    min_score: int,
    threshold: int,
    seeking: bool,
    uploaded: set[str],
    reporting_agent: LiteReportingAgent,
) -> str:
    """Write the run's report again from its stored citations, and keep it.

    The checkpoint is read again first: a *Check again* may have saved new
    retraction answers while the texts were read, and the report states
    those, not the ones it was first written with. Transparency is counted
    again when the run counted it, from the rows as they are now.

    Args:
        question: The research question.
        storage: The store.
        checkpoint_id: The run's checkpoint.
        metadata: The report metadata the run kept, updated in place.
        scored: The run's scored papers.
        min_score: The run's relevance threshold.
        threshold: The full-text score.
        seeking: Whether the full-text setting is on.
        uploaded: The ids of the papers with an uploaded full text.
        reporting_agent: Writes the report.

    Returns:
        The new report.

    Raises:
        RetryNotPossible: The checkpoint is gone.
    """
    checkpoint = storage.get_checkpoint(checkpoint_id)
    if checkpoint is None:
        raise RetryNotPossible(NO_REPORT_TEXT)
    by_id = {d.document.id: d.document for d in scored}
    reads = storage.get_citation_reads(checkpoint_id)
    failures = recorded_extraction_failures(checkpoint.metadata, by_id)
    if failures is not None:
        # A paper read since, by this retry or an earlier one, is not lost
        failures = [f for f in failures if not reads.get(f.document.id)]
        attempted = sum(1 for d in scored if d.score >= min_score)
        shortfall = CitationOutcome(
            citations=[], documents_attempted=attempted, failed=tuple(failures)
        ).shortfall
        metadata.analysis_shortfalls = [
            s for s in metadata.analysis_shortfalls
            if s.stage is not AnalysisStage.CITATION_EXTRACTION
        ] + ([shortfall] if shortfall else [])
    failed_ids = {f.document.id for f in failures or []}
    read_papers = [d for d in scored if d.score >= min_score and d.document.id not in failed_ids]
    read_full_text = {doc_id for doc_id, read in reads.items() if read}
    if seeking or metadata.full_text_min_score is not None:
        # A run that sought no full text says nothing of texts not obtained
        record_full_text_reads(metadata, threshold, read_papers, read_full_text)
    record_uploaded_reads(metadata, read_papers, read_full_text, uploaded)

    snapshot = recorded_retraction_snapshot(checkpoint.metadata)
    if snapshot:
        metadata.retraction_screen = RetractionSnapshot(tuple(snapshot.values()))

    citations = storage.get_citations_for_question(question, checkpoint_id=checkpoint_id)
    cited = list(dict.fromkeys(c.document.id for c in citations))
    metadata.citations_extracted = len(citations)
    metadata.unique_sources_cited = len(cited)
    if metadata.transparency_analysis_applied:
        rows = record_transparency_counts(storage, metadata, list(by_id), cited_ids=cited)
        transparency_results = {doc_id: rows[doc_id] for doc_id in cited if doc_id in rows}
    else:
        transparency_results = storage.get_transparency_results_batch(cited)
    metadata.version += 1
    metadata.generated_at = datetime.now()

    report = reporting_agent.generate_report(
        question, citations, metadata, transparency_results=transparency_results
    )
    kept = {k: v for k, v in checkpoint.metadata.items() if k != REPORT_PENDING_KEY}
    if failures is not None:
        kept = checkpoint_metadata_with_extraction_failures(kept, failures)
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        report=report,
        metadata=checkpoint_metadata_with_report_metadata(kept, metadata),
    )
    return report
