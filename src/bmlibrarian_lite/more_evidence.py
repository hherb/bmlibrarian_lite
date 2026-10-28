# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Find More Evidence: more documents for a reviewed question, and its report written again.

The rules are the apps' (iOS/macOS's ``fetchMoreEvidence``), on the run whose
report the question shows:

- The documents come from paging further through the question's own query
  (the caller's ``IncrementalSearchWorker``). When that finds nothing new, a
  round of alternative queries runs (``smart_search``), told of every one
  already run; a round that finds nothing new leaves the report as it is and
  says so. Documents an earlier run found and a stop left unscored are
  scored first, and while there are any, or papers it scored are still to be
  read, or its report is owed, no paid round runs on top of them (a paper
  whose citations could not be extracted is not owed: it is extracted again
  with the next run's, never in place of a search). A document the run
  already holds (scored, screened or left out by its quality filter) is
  never new.
- The new documents are screened for retractions, scored into the run, and
  the relevant ones have their citations extracted (from a full text as the
  review would: an upload whatever the setting, a fetched one with it on).
  A relevant paper of the run whose citations were never read (a cancelled
  run's) is extracted with them. Transparency is analysed for the documents
  scored now (held over and new) that have a PMID or DOI and no stored
  result. The report is then written again from every citation of the run.
- What the run learns is kept as it is learnt: the scores and the report's
  counts after scoring, marked as owing a report, so a stop or a failure
  before the report leaves the next *Find More Evidence* or *Retry Full
  Text* to write it.

Nothing here imports Qt.
"""

from __future__ import annotations

import logging
import threading
from collections.abc import Callable, Collection, Sequence
from dataclasses import dataclass, replace
from datetime import UTC, datetime
from typing import TYPE_CHECKING

from .analysis_failures import pass_failure_detail
from .audit_records import (
    CHECKPOINT_MIN_SCORE_KEY,
    CHECKPOINT_QUALITY_FILTERED_KEY,
    CHECKPOINT_RETRACTION_SNAPSHOT_KEY,
    checkpoint_metadata_with_extraction_failures,
    checkpoint_metadata_with_report_metadata,
    recorded_extraction_failures,
    recorded_report_metadata,
    recorded_retraction_snapshot,
)
from .citation_full_texts import FullTextFetch, fetch_full_texts
from .citation_text import full_text_min_score
from .data_models import (
    AnalysisShortfall,
    AnalysisStage,
    EvaluationErrorCode,
    PassFailure,
    ReportMetadata,
    ScoredDocument,
)
from .full_text_retry import (
    NO_REPORT_TEXT,
    NOT_KEPT_TEXT,
    REPORT_PENDING_KEY,
    RetryNotPossible,
    write_report_again,
)
from .quality.data_models import QualityFilter
from .search_failures import combined_shortfalls
from .smart_search import NO_NEW_EVIDENCE_TEXT, SmartSearchContext, SmartSearchRound
from .utils import classify_analysis_exception

if TYPE_CHECKING:
    from .agents.citation_agent import LiteCitationAgent
    from .agents.reporting_agent import LiteReportingAgent
    from .agents.scoring_agent import LiteScoringAgent
    from .config import LiteConfig
    from .data_models import LiteDocument, RetrievalShortfall
    from .retraction_screen import RetractionScreen
    from .storage import LiteStorage

logger = logging.getLogger(__name__)

FIND_MORE_EVIDENCE_ACTION = "Find More Evidence"

#: Runs a round of alternative queries, given the documents already found.
SmartSearch = Callable[[SmartSearchContext, Collection[str]], SmartSearchRound]
#: Analyses one document's transparency, with its full text when one was read.
AssessTransparency = Callable[["LiteDocument", "str | None"], None]

#: Applies a quality filter to documents, returning those that pass.
QualityGate = Callable[[list["LiteDocument"], "QualityFilter"], list["LiteDocument"]]

QUALITY_FILTER_UNREADABLE_TEXT = (
    "This report's review applied a quality filter that cannot be read back, so "
    "documents found now could not be filtered alike. Run the review again."
)

#: Checkpoint metadata: the ids of documents found for the run that a stop
#: left unscored, scored first by the next run.
UNSCORED_KEY = "more_evidence_unscored"

CANCELLED_UNCHANGED_TEXT = "Cancelled, so the report is unchanged."
CANCELLED_TEXT = (
    "Cancelled. What was found and scored is kept; the next Find More Evidence "
    "carries on from it and writes the report."
)
CAUGHT_UP_TEXT = (
    "No alternative search was run: this finished what an earlier stop left. "
    "The next Find More Evidence searches further."
)


@dataclass(frozen=True)
class MoreEvidence:
    """What a *Find More Evidence* did.

    Attributes:
        found: Documents new to the question.
        resumed: Documents an earlier stop left unscored, taken up again.
        caught_up: Whether no alternative search ran because the run first
            finished what an earlier stop left (documents to score, papers to
            read, a report owed).
        left_out: Of the documents screened (held over and new), papers left
            out as retracted.
        filtered_out: Of those, documents the run's quality filter left out.
        scored: Documents the model scored.
        relevant: Of those, documents scored at or above the run's threshold.
        scoring_failures: Documents the model could not score.
        extraction_failures: Relevant papers whose citations could not be
            extracted.
        queries: The alternative queries smart search searched, if it ran.
        cut_off_notice: That the model's answer for them was cut off, so it
            may have proposed more (#637); None when it was not.
        search_shortfalls: What the search lost.
        transparency_failures: Documents whose transparency could not be
            analysed.
        notice: Why the report is unchanged, when nothing new was found.
        report: The report written again, or None when it was not.
        cancelled: Whether a cancel stopped it before its end.
    """

    found: int = 0
    resumed: int = 0
    caught_up: bool = False
    left_out: int = 0
    filtered_out: int = 0
    scored: int = 0
    relevant: int = 0
    scoring_failures: tuple[PassFailure, ...] = ()
    extraction_failures: tuple[PassFailure, ...] = ()
    queries: tuple[str, ...] = ()
    cut_off_notice: str | None = None
    search_shortfalls: tuple[RetrievalShortfall, ...] = ()
    transparency_failures: tuple[PassFailure, ...] = ()
    notice: str | None = None
    report: str | None = None
    cancelled: bool = False


def more_evidence_text(outcome: MoreEvidence) -> str:
    """What the reader is told a *Find More Evidence* did.

    Args:
        outcome: What it did.

    Returns:
        A sentence or several.
    """
    from .search_failures import describe_search_shortfalls

    parts: list[str] = []
    if outcome.queries:
        count = len(outcome.queries)
        parts.append(f"Ran {count} alternative search{'es' if count != 1 else ''}.")
    if outcome.cut_off_notice:
        parts.append(outcome.cut_off_notice)
    if outcome.found:
        parts.append(f"Found {outcome.found} new document{'s' if outcome.found != 1 else ''}.")
    if outcome.resumed:
        parts.append(
            f"Carried on with {outcome.resumed} document{'s' if outcome.resumed != 1 else ''} "
            "an earlier stop left unscored."
        )
    if outcome.left_out:
        parts.append(f"{outcome.left_out} left out as retracted.")
    if outcome.filtered_out:
        parts.append(f"{outcome.filtered_out} left out by the review's quality filter.")
    if outcome.scored:
        parts.append(f"Scored {outcome.scored}: {outcome.relevant} relevant.")
    if outcome.search_shortfalls:
        parts.append(f"Incomplete search: {describe_search_shortfalls(outcome.search_shortfalls)}.")
    if outcome.notice:
        parts.append(outcome.notice)
    elif outcome.cancelled:
        parts.append(
            CANCELLED_TEXT if outcome.found or outcome.resumed or outcome.scored
            else CANCELLED_UNCHANGED_TEXT
        )
    elif outcome.report is not None:
        parts.append("The report was written again.")
        if outcome.caught_up:
            parts.append(CAUGHT_UP_TEXT)
    if outcome.scoring_failures:
        count = len(outcome.scoring_failures)
        parts.append(
            f"{count} document{'s' if count != 1 else ''} could not be scored. "
            + pass_failure_detail(outcome.scoring_failures)
        )
    if outcome.extraction_failures:
        count = len(outcome.extraction_failures)
        parts.append(
            f"Citations could not be extracted from {count} relevant "
            f"paper{'s' if count != 1 else ''}. "
            + pass_failure_detail(outcome.extraction_failures)
        )
    if outcome.transparency_failures:
        count = len(outcome.transparency_failures)
        parts.append(
            f"Transparency could not be analysed for {count} "
            f"document{'s' if count != 1 else ''}. "
            + pass_failure_detail(outcome.transparency_failures)
        )
    return " ".join(parts)


def find_more_evidence(
    question: str,
    storage: LiteStorage,
    config: LiteConfig,
    documents: Sequence[LiteDocument],
    search_shortfalls: Sequence[RetrievalShortfall],
    *,
    smart_search: SmartSearch,
    screen: Callable[[list[LiteDocument]], RetractionScreen] | None,
    quality_filter: QualityGate,
    scoring_agent: LiteScoringAgent,
    citation_agent: LiteCitationAgent,
    reporting_agent: LiteReportingAgent,
    fetch: FullTextFetch,
    assess_transparency: AssessTransparency | None,
    should_stop: Callable[[], bool],
    progress: Callable[[int, int, str], None] | None = None,
) -> MoreEvidence:
    """Take a reviewed question further, and write its report again.

    Args:
        question: The research question.
        storage: The store the run is read from and written to.
        config: The configuration, for the full-text setting and score.
        documents: The new documents paging the question's own query found,
            stored and linked to it. When none is new and nothing is held
            over or owed, a round of alternative queries runs.
        search_shortfalls: What that paging lost.
        smart_search: Runs a round of alternative queries.
        screen: Leaves retracted papers out; None screens nothing.
        quality_filter: Applies the run's quality filter, when it applied
            one, to the documents to score (held over and new).
        scoring_agent: Scores the new documents.
        citation_agent: Extracts the citations.
        reporting_agent: Writes the report.
        fetch: Fetches one paper's full text.
        assess_transparency: Analyses a document's transparency; None when
            transparency analysis is off.
        should_stop: Asked between steps and documents; true cancels.
        progress: Told (current, total, message) along the way.

    Returns:
        What it did.

    Raises:
        RetryNotPossible: The question has no report, or its run did not keep
            the report's metadata, or its quality filter cannot be read back.
        SmartSearchError: No alternative search could run.
        SearchFailedError: Failures left the alternative searches with nothing.
    """
    tell = progress or (lambda _current, _total, _message: None)
    checkpoint = storage.get_checkpoint_for_question(question)
    if checkpoint is None or not checkpoint.report:
        raise RetryNotPossible(NO_REPORT_TEXT)
    metadata = recorded_report_metadata(checkpoint.metadata)
    if metadata is None:
        raise RetryNotPossible(NOT_KEPT_TEXT)
    settings: QualityFilter | None = None
    if metadata.quality_filter_applied:
        # Before anything is searched or kept: a refusal changes nothing
        try:
            settings = QualityFilter.from_report_settings(metadata.quality_filter_settings)
        except ValueError as e:
            raise RetryNotPossible(QUALITY_FILTER_UNREADABLE_TEXT) from e
    stored_min = checkpoint.metadata.get(CHECKPOINT_MIN_SCORE_KEY)
    min_score = (
        stored_min
        if isinstance(stored_min, int) and not isinstance(stored_min, bool)
        else metadata.min_score_threshold
    )
    before = storage.get_scored_documents_for_question(question, checkpoint_id=checkpoint.id)

    outcome = MoreEvidence()
    scored_ids = {d.document.id for d in before}
    unscored = [
        d for d in storage.get_documents(_stored_ids(checkpoint.metadata.get(UNSCORED_KEY)))
        if d.id not in scored_ids
    ]
    known = known_document_ids(storage, question)
    found = [d for d in documents if d.id not in known and d.id not in {u.id for u in unscored}]
    lost = list(search_shortfalls)
    reads = storage.get_citation_reads(checkpoint.id)
    cited = {c.document.id for c in storage.get_citations_for_question(
        question, checkpoint_id=checkpoint.id)}
    # A paper whose extraction failed is extracted again with the next run's,
    # never in place of a search: one that always fails would block every round
    failed_extraction = {
        f.document.id for f in recorded_extraction_failures(
            checkpoint.metadata, {d.document.id: d.document for d in before}) or []
    }
    owed = checkpoint.metadata.get(REPORT_PENDING_KEY) is True or any(
        d.score >= min_score and d.document.id not in reads and d.document.id not in cited
        and d.document.id not in failed_extraction
        for d in before
    )
    if not found and not unscored and not owed:
        context = SmartSearchContext(
            question=question,
            initial_query=metadata.pubmed_query,
            total_results=metadata.total_results_available,
            relevant_count=sum(1 for d in before if d.score >= min_score),
            checkpoint_id=checkpoint.id,
        )
        round_ = smart_search(context, known | scored_ids)
        found, lost = list(round_.documents), [*lost, *round_.shortfalls]
        outcome = replace(outcome, queries=round_.queries, cut_off_notice=round_.notice)
        if not found:
            return replace(outcome, cancelled=round_.stopped,
                           notice=None if round_.stopped else NO_NEW_EVIDENCE_TEXT)
        metadata.alternative_queries = [*metadata.alternative_queries, *round_.queries]
        # This round found documents, so the report is written again with this
        # round's notice (None unless its answer was cut off), not the review's
        metadata.smart_search_notice = round_.notice
    outcome = replace(outcome, found=len(found), resumed=len(unscored),
                      caught_up=not found and (bool(unscored) or owed),
                      search_shortfalls=tuple(combined_shortfalls(lost)))
    metadata.documents_retrieved += len(found)
    metadata.search_shortfalls = combined_shortfalls([*metadata.search_shortfalls, *lost])
    # Kept before anything else can stop the run, so the next one scores them
    held = [*unscored, *found]
    _keep_metadata(storage, checkpoint.id, metadata, [d.id for d in held])
    if should_stop():
        return replace(outcome, cancelled=True)

    kept = held
    if screen is not None and held:
        tell(0, 1, "Checking for retractions...")
        screened = screen(held)
        kept = list(screened.kept)
        outcome = replace(outcome, left_out=len(screened.excluded))
        _merge_retraction_snapshot(storage, checkpoint.id, screened)
        _keep_metadata(storage, checkpoint.id, metadata, [d.id for d in kept])
    if should_stop():
        return replace(outcome, cancelled=True)

    if settings is not None and kept:
        tell(0, len(kept), "Assessing quality...")
        passed = quality_filter(kept, settings)
        if should_stop():
            return replace(outcome, cancelled=True)
        metadata.documents_filtered_by_quality += len(kept) - len(passed)
        outcome = replace(outcome, filtered_out=len(kept) - len(passed))
        _record_quality_filtered(storage, checkpoint.id,
                                 [d.id for d in kept if d.id not in {p.id for p in passed}])
        kept = passed
        _keep_metadata(storage, checkpoint.id, metadata, [d.id for d in kept])

    new_scores, outcome = _score(
        question, storage, checkpoint.id, kept, min_score, metadata, outcome,
        scoring_agent, should_stop, tell,
    )
    if outcome.cancelled or should_stop():
        return replace(outcome, cancelled=True)

    scored = storage.get_scored_documents_for_question(question, checkpoint_id=checkpoint.id)
    new_ids = {d.document.id for d in new_scores}
    # New relevant papers, and relevant ones a stopped run never read
    targets = [
        d for d in scored
        if d.score >= min_score and d.document.id not in reads
        and (d.document.id in new_ids or d.document.id not in cited)
    ]
    extracted = _extract(question, storage, config, checkpoint.id, targets, scored, min_score,
                         fetch, citation_agent, should_stop, tell)
    if extracted is None:
        return replace(outcome, cancelled=True)
    texts, extraction_failures = extracted
    outcome = replace(outcome, extraction_failures=extraction_failures)

    if assess_transparency is not None:
        outcome = _assess(storage, kept, texts, assess_transparency, outcome, should_stop, tell)
        if outcome.cancelled:
            return outcome

    if should_stop():
        return replace(outcome, cancelled=True)
    tell(0, 1, "Writing the report again")
    seeking = config.discovery.citations_from_full_text
    uploaded = set(storage.get_uploaded_full_texts([d.document.id for d in scored]))
    report = write_report_again(
        question, storage, checkpoint.id, metadata, scored, min_score,
        full_text_min_score(min_score, config.discovery.full_text_min_score),
        seeking, uploaded, reporting_agent,
    )
    return replace(outcome, report=report)


def known_document_ids(storage: LiteStorage, question: str) -> set[str]:
    """The documents a search for more must not count as new.

    Every document scored for the question, and those its reviewed run
    screened or whose quality filter left them out: found again, they would
    be counted again.

    Args:
        storage: The store.
        question: The research question.

    Returns:
        Their ids.
    """
    judged, failed = storage.get_rerun_document_ids_for_question(question)
    checkpoint = storage.get_checkpoint_for_question(question)
    stored = checkpoint.metadata if checkpoint is not None else {}
    return (
        judged | failed
        | set(recorded_retraction_snapshot(stored))
        | set(_stored_ids(stored.get(CHECKPOINT_QUALITY_FILTERED_KEY)))
    )


def _record_quality_filtered(storage: LiteStorage, checkpoint_id: str, ids: list[str]) -> None:
    """Add documents the run's quality filter left out to its record of them."""
    if not ids:
        return
    current = storage.get_checkpoint(checkpoint_id)
    stored = current.metadata if current is not None else {}
    earlier = _stored_ids(stored.get(CHECKPOINT_QUALITY_FILTERED_KEY))
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        metadata={**stored, CHECKPOINT_QUALITY_FILTERED_KEY: [*earlier, *ids]},
        touch=False,
    )


def _score(
    question: str,
    storage: LiteStorage,
    checkpoint_id: str,
    documents: list[LiteDocument],
    min_score: int,
    metadata: ReportMetadata,
    outcome: MoreEvidence,
    scoring_agent: LiteScoringAgent,
    should_stop: Callable[[], bool],
    tell: Callable[[int, int, str], None],
) -> tuple[list[ScoredDocument], MoreEvidence]:
    """Score the documents into the run, and keep the report's counts with them.

    Each score is stored as it arrives; the counts are kept once scoring
    ends, however it ends, so they always describe the scores stored.

    Returns:
        The new scores, and the outcome with them counted (and cancelled when
        a stop ended scoring).
    """
    new_scores: list[ScoredDocument] = []
    stopped = False
    # A document the review scored meanwhile is not scored twice
    documents = [d for d in documents if d.id not in {
        s.document.id for s in storage.get_scored_documents_for_question(
            question, checkpoint_id=checkpoint_id)
    }]
    try:
        for index, doc in enumerate(documents, start=1):
            if should_stop():
                stopped = True
                break
            tell(index, len(documents), f"Scoring {index}/{len(documents)}: {doc.title[:50]}...")
            scored = scoring_agent.score_document(question, doc)
            storage.save_scored_document(scored, checkpoint_id)
            new_scores.append(scored)
    finally:
        failures = [d for d in new_scores if d.score < 0]
        judged = [d for d in new_scores if d.score >= 0]
        metadata.documents_scored += len(judged)
        metadata.documents_accepted += sum(1 for d in judged if d.score >= min_score)
        metadata.documents_rejected += sum(1 for d in judged if d.score < min_score)
        for d in new_scores:
            metadata.score_distribution[d.score] = metadata.score_distribution.get(d.score, 0) + 1
        metadata.analysis_shortfalls = _with_scoring_failures(metadata, failures, len(new_scores))
        done = {d.document.id for d in new_scores}
        _keep_metadata(storage, checkpoint_id, metadata, [d.id for d in documents if d.id not in done])
    return new_scores, replace(
        outcome,
        scored=len(judged),
        relevant=sum(1 for d in judged if d.score >= min_score),
        scoring_failures=tuple(
            PassFailure(document_id=d.document.id, cause=_cause(d.score)) for d in failures
        ),
        cancelled=stopped,
    )


def _extract(
    question: str,
    storage: LiteStorage,
    config: LiteConfig,
    checkpoint_id: str,
    targets: list[ScoredDocument],
    scored: list[ScoredDocument],
    min_score: int,
    fetch: FullTextFetch,
    citation_agent: LiteCitationAgent,
    should_stop: Callable[[], bool],
    tell: Callable[[int, int, str], None],
) -> tuple[dict[str, str], tuple[PassFailure, ...]] | None:
    """Extract the targets' citations as the review would, and keep them.

    A stopped extraction keeps nothing: what it read is not known paper by
    paper, and its papers stay unread, so the next run extracts them.

    Returns:
        The full texts read by paper id and the papers whose extraction
        failed, or None when a stop came first.
    """
    if not targets:
        return {}, ()
    # Before the uploads are read: one stored after this is read next time
    taken_at = datetime.now(UTC)
    uploads = storage.get_uploaded_full_texts([d.document.id for d in targets])
    texts = {doc_id: upload.text for doc_id, upload in uploads.items()}
    if config.discovery.citations_from_full_text:
        threshold = full_text_min_score(min_score, config.discovery.full_text_min_score)
        texts.update(fetch_full_texts(
            fetch,
            [d.document for d in targets if d.score >= threshold and d.document.id not in uploads],
            should_stop,
            lambda current, total: tell(current, total, f"Getting full text {current}/{total}"),
        ))
    if should_stop():
        return None
    stop = _StopEvent(should_stop)
    extraction = citation_agent.extract_all_citations(
        question,
        targets,
        min_score=min_score,
        progress_callback=lambda current, total: tell(
            current, total, f"Extracting citations {current}/{total}"
        ),
        cancelled=stop,
        full_texts=texts,
    )
    if should_stop():
        return None
    for citation in extraction.citations:
        storage.save_citation(citation, checkpoint_id)
    failed_ids = {f.document.id for f in extraction.failed}
    storage.record_citation_reads(
        checkpoint_id,
        {
            d.document.id: d.document.id in extraction.read_full_text
            for d in targets if d.document.id not in failed_ids
        },
        read_at=taken_at,
    )
    current = storage.get_checkpoint(checkpoint_id)
    stored = current.metadata if current is not None else {}
    by_id = {d.document.id: d.document for d in scored}
    target_ids = {d.document.id for d in targets}
    earlier = [
        f for f in recorded_extraction_failures(stored, by_id) or []
        if f.document.id not in target_ids
    ]
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        metadata=checkpoint_metadata_with_extraction_failures(
            stored, [*earlier, *extraction.failed]
        ),
        touch=False,
    )
    read = {doc_id: text for doc_id, text in texts.items() if doc_id in extraction.read_full_text}
    return read, tuple(
        PassFailure(document_id=f.document.id, cause=f.cause) for f in extraction.failed
    )


def _assess(
    storage: LiteStorage,
    documents: list[LiteDocument],
    texts: dict[str, str],
    assess: AssessTransparency,
    outcome: MoreEvidence,
    should_stop: Callable[[], bool],
    tell: Callable[[int, int, str], None],
) -> MoreEvidence:
    """Analyse the transparency of the documents scored now without a stored result.

    A document with neither a PMID nor a DOI is not analysed: nothing
    identifies it to the sources the analysis reads.

    Returns:
        The outcome with the documents that could not be analysed.
    """
    stored = storage.get_transparency_results_batch([d.id for d in documents])
    due = [d for d in documents if d.id not in stored and (d.pmid or d.doi)]
    failures: list[PassFailure] = []
    for index, doc in enumerate(due, start=1):
        if should_stop():
            return replace(outcome, transparency_failures=tuple(failures), cancelled=True)
        tell(index, len(due), f"Analysing transparency {index}/{len(due)}")
        try:
            assess(doc, texts.get(doc.id))
        except Exception as e:
            # The report counts it as unassessed; the cause, never the provider's words (#330)
            logger.exception("Transparency could not be analysed for %s", doc.id)
            failures.append(PassFailure(document_id=doc.id, cause=classify_analysis_exception(e)))
    return replace(outcome, transparency_failures=tuple(failures))


def _with_scoring_failures(
    metadata: ReportMetadata, failures: list[ScoredDocument], attempted: int
) -> list[AnalysisShortfall]:
    """The report's analysis shortfalls with the new scoring failures added to its own."""
    others = [s for s in metadata.analysis_shortfalls if s.stage is not AnalysisStage.SCORING]
    earlier = next(
        (s for s in metadata.analysis_shortfalls if s.stage is AnalysisStage.SCORING), None
    )
    if not failures:
        if earlier is None:
            return others
        return [*others, replace(earlier, documents_attempted=earlier.documents_attempted + attempted)]
    failed = len(failures) + (earlier.documents_failed if earlier else 0)
    # With no earlier scoring shortfall, every document scored before this run
    # was attempted and none failed; documents_scored already includes this
    # run's judged ones, so they are taken off
    attempted_before = earlier.documents_attempted if earlier else metadata.documents_scored - (
        attempted - len(failures)
    )
    causes = (*(earlier.causes if earlier else ()), *(_cause(d.score) for d in failures))
    return [*others, AnalysisShortfall(
        stage=AnalysisStage.SCORING,
        documents_failed=failed,
        documents_attempted=attempted_before + attempted,
        causes=causes,
    )]


def _cause(score: int) -> EvaluationErrorCode:
    """The error code a failed score holds."""
    try:
        return EvaluationErrorCode(score)
    except ValueError:
        return EvaluationErrorCode.UNKNOWN_ERROR


def _keep_metadata(
    storage: LiteStorage, checkpoint_id: str, metadata: ReportMetadata, unscored: list[str]
) -> None:
    """Keep the report's counts and the documents still to score, and mark the run as owing its report."""
    current = storage.get_checkpoint(checkpoint_id)
    stored = {k: v for k, v in (current.metadata if current is not None else {}).items()
              if k != UNSCORED_KEY}
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        metadata={
            **checkpoint_metadata_with_report_metadata(stored, metadata),
            REPORT_PENDING_KEY: True,
            **({UNSCORED_KEY: unscored} if unscored else {}),
        },
        touch=False,  # a note on this run, not a new latest
    )


def _stored_ids(value: object) -> list[str]:
    """The document ids a checkpoint kept, read as input: nothing for anything but a list of strings."""
    if not isinstance(value, list):
        return []
    return [v for v in value if isinstance(v, str)]


def _merge_retraction_snapshot(
    storage: LiteStorage, checkpoint_id: str, screen: RetractionScreen
) -> None:
    """Put the screened documents' rows in the run's retraction snapshot.

    A run checked for retractions keeps a row per document it held; a run
    from before the check keeps none, so it gains only these. A screened
    document's row replaces any it had: only documents held over from an
    earlier *Find More Evidence* have one, written by a screen a stop may
    have cut short, never by the review.
    """
    current = storage.get_checkpoint(checkpoint_id)
    stored = current.metadata if current is not None else {}
    rows = recorded_retraction_snapshot(stored)
    for row in screen.to_snapshot():
        rows[row["document_id"]] = row
    storage.update_checkpoint(
        checkpoint_id=checkpoint_id,
        metadata={**stored, CHECKPOINT_RETRACTION_SNAPSHOT_KEY: list(rows.values())},
        touch=False,
    )


class _StopEvent(threading.Event):
    """A ``threading.Event`` that is set when a stop is asked for."""

    def __init__(self, should_stop: Callable[[], bool]) -> None:
        super().__init__()
        self._should_stop = should_stop

    def is_set(self) -> bool:
        """Whether a stop was asked for."""
        return self._should_stop() or super().is_set()
