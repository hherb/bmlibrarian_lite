# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Retry Full Text: read a reviewed question's unread full texts, and write its report again.

The rules are the apps' (iOS/macOS's ``retryFullTextRetrieval``): every
paper of the question's reviewed run scored at or above the full-text score
whose citations were not read from its full text is asked for it again. A
paper whose text arrives has its citations extracted from it; they replace
its old ones only when the text yields passages, and either way it is
recorded as read. Its transparency is analysed again with that text. When
at least one full text was read the report is written again; when none was,
the report stands. Nothing here imports Qt.
"""

from __future__ import annotations

import logging
from collections.abc import Callable
from dataclasses import dataclass, replace
from datetime import datetime
from typing import TYPE_CHECKING

from .audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    checkpoint_metadata_with_extraction_failures,
    checkpoint_metadata_with_report_metadata,
    recorded_extraction_failures,
    recorded_report_metadata,
)
from .citation_full_texts import FullTextFetch, fetch_full_texts
from .citation_text import full_text_min_score, record_full_text_reads
from .data_models import AnalysisStage, CitationOutcome, ReportMetadata, ScoredDocument
from .transparency.assessment import record_transparency_counts

if TYPE_CHECKING:
    from .agents.citation_agent import LiteCitationAgent
    from .agents.reporting_agent import LiteReportingAgent
    from .config import LiteConfig
    from .data_models import LiteDocument, ReviewCheckpoint
    from .storage import LiteStorage

logger = logging.getLogger(__name__)

#: Analyses one paper's transparency again with its full text.
AssessTransparency = Callable[["LiteDocument", str], None]

RETRY_FULL_TEXT_ACTION = "Retry Full Text"
FULL_TEXT_SETTING_OFF_TEXT = (
    "Turn on reading citations from full text in Settings > Full Text first"
)
NO_REPORT_TEXT = "This question has no report to take further; run the review first."
NOT_KEPT_TEXT = (
    "This report was written before a review kept what writing it again "
    "needs. Run the review again to read its papers' full texts."
)
NO_NEW_FULL_TEXT_TEXT = "No further full text was read, so the report is unchanged."


class RetryNotPossible(Exception):
    """A retry that cannot run for this question; the message is the reader's."""


@dataclass(frozen=True)
class FullTextRetry:
    """What a retry of a question's full texts did.

    Attributes:
        asked: Papers whose full text was asked for.
        read: Of those, papers whose citations were read from it.
        replaced: Of those, papers whose citations its passages replaced.
        unavailable: Papers for which no full text was obtained.
        failed: Papers whose full text was obtained but could not be read.
        report: The report written again, or None when nothing new was read.
        cancelled: Whether a cancel stopped the retry before its end; a
            cancelled retry writes no report.
    """

    asked: int = 0
    read: int = 0
    replaced: int = 0
    unavailable: int = 0
    failed: int = 0
    report: str | None = None
    cancelled: bool = False


def retry_text(outcome: FullTextRetry) -> str:
    """What the reader is told a retry did.

    Args:
        outcome: The retry's outcome.

    Returns:
        A sentence or two.
    """
    if outcome.asked == 0:
        return "Every paper scored high enough was already read from its full text."
    parts = [
        f"Asked for {outcome.asked} full text{'s' if outcome.asked != 1 else ''}: "
        f"{outcome.read} read, {outcome.unavailable} not obtained"
        + (f", {outcome.failed} could not be read" if outcome.failed else "")
        + "."
    ]
    if outcome.cancelled:
        parts.append("Cancelled, so the report is unchanged.")
    elif outcome.report is None:
        parts.append(NO_NEW_FULL_TEXT_TEXT)
    else:
        parts.append("The report was written again.")
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
        config: The configuration, for the full-text score.
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
            keep the report's metadata.
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
    reads = storage.get_citation_reads(checkpoint.id)
    targets = [d for d in scored if d.score >= threshold and not reads.get(d.document.id)]
    if not targets:
        return FullTextRetry()

    def fetching(current: int, total: int) -> None:
        if progress:
            progress(current, total, f"Fetching full text {current}/{total}")

    texts = fetch_full_texts(fetch, [d.document for d in targets], should_stop, fetching)
    outcome = FullTextRetry(asked=len(targets), unavailable=len(targets) - len(texts))
    recovered: set[str] = set()
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
            outcome = replace(outcome, failed=outcome.failed + 1)
            continue
        if extraction.citations:
            storage.replace_document_citations(checkpoint.id, doc_id, extraction.citations)
            outcome = replace(outcome, replaced=outcome.replaced + 1)
        else:
            # Read, and nothing quotable in it: the old citations stand
            storage.record_citation_reads(checkpoint.id, {doc_id: True})
        recovered.add(doc_id)
        outcome = replace(outcome, read=outcome.read + 1)
        if assess_transparency is not None:
            try:
                assess_transparency(target.document, texts[doc_id])
            except Exception:
                # The stored assessment stands; the report counts it as it is
                logger.exception("Transparency could not be analysed again for %s", doc_id)

    if should_stop():
        return replace(outcome, cancelled=True)
    if outcome.read == 0:
        return outcome
    if progress:
        progress(0, 1, "Writing the report again")
    report = _write_report_again(
        question, storage, checkpoint, metadata, scored, min_score, threshold,
        recovered, reporting_agent,
    )
    return replace(outcome, report=report)


def _write_report_again(
    question: str,
    storage: LiteStorage,
    checkpoint: ReviewCheckpoint,
    metadata: ReportMetadata,
    scored: list[ScoredDocument],
    min_score: int,
    threshold: int,
    recovered: set[str],
    reporting_agent: LiteReportingAgent,
) -> str:
    """Write the run's report again from its stored citations, and keep it.

    Args:
        question: The research question.
        storage: The store.
        checkpoint: The run's checkpoint.
        metadata: The report metadata the run kept, updated in place.
        scored: The run's scored papers.
        min_score: The run's relevance threshold.
        threshold: The full-text score.
        recovered: Papers read now whose extraction had failed before, or
            had not been read from their full text.
        reporting_agent: Writes the report. Transparency is counted again
            when the run counted it, from the rows as they are now.

    Returns:
        The new report.
    """
    by_id = {d.document.id: d.document for d in scored}
    failures = recorded_extraction_failures(checkpoint.metadata, by_id)
    if failures is not None:
        failures = [f for f in failures if f.document.id not in recovered]
        attempted = sum(1 for d in scored if d.score >= min_score)
        shortfall = CitationOutcome(
            citations=[], documents_attempted=attempted, failed=tuple(failures)
        ).shortfall
        metadata.analysis_shortfalls = [
            s for s in metadata.analysis_shortfalls
            if s.stage is not AnalysisStage.CITATION_EXTRACTION
        ] + ([shortfall] if shortfall else [])
    failed_ids = {f.document.id for f in failures or []}
    reads = storage.get_citation_reads(checkpoint.id)
    record_full_text_reads(
        metadata,
        threshold,
        [d for d in scored if d.score >= min_score and d.document.id not in failed_ids],
        {doc_id for doc_id, read in reads.items() if read},
    )

    citations = storage.get_citations_for_question(question, checkpoint_id=checkpoint.id)
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
    kept = dict(checkpoint.metadata)
    if failures is not None:
        kept = checkpoint_metadata_with_extraction_failures(kept, failures)
    storage.update_checkpoint(
        checkpoint_id=checkpoint.id,
        report=report,
        metadata=checkpoint_metadata_with_report_metadata(kept, metadata),
    )
    return report
