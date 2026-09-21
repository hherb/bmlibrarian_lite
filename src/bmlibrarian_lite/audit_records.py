# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU Affero General Public License for more details.
#
# You should have received a copy of the GNU Affero General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

"""What became of every document the search found (#302).

The audit trail used to build its rejected list from absence -- every found
document that was not among the accepted ones -- and gave each the reason
"Score below minimum threshold". Nobody gave that reason. A document the
model could not score, and a document the quality filter removed before
scoring reached it, were both written into the durable record as judged
irrelevant.

The functions here classify instead of inferring: a document's outcome is
decided by the score it actually received, which is negative when the scoring
failed (see :class:`~bmlibrarian_lite.data_models.EvaluationErrorCode`) -- or,
from an older build, a 1 with a recognisable explanation, which is read as the
failure it was (:func:`as_recorded_failure`) -- and
a document with no score at all is recorded as not scored, in none of the
scored lists. They also build the part of the audit record that says so, so
the saved file and the dialog cannot drift apart, and read what records and
checkpoints written by older builds can and cannot tell.

The companion of :mod:`~bmlibrarian_lite.analysis_failures`, whose contract is
``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass, replace
from typing import Any

from .constants import SCORE_MAX, SCORE_MIN
from .data_models import (
    EvaluationErrorCode,
    ExtractionFailure,
    LiteDocument,
    ScoredDocument,
)

#: What a failure whose code this build cannot name is recorded as. The count
#: never degrades, only the reason (the #301 rule); the code itself is kept
#: beside it as the entry's score.
UNNAMED_FAILURE_REASON = "Scoring failed for a reason this build cannot name"

#: The error-code name of a failure this build cannot name.
UNKNOWN_FAILURE_CODE = "UNKNOWN"

#: The reason the audit trail gave every non-accepted document before #302,
#: whether the model judged it, failed on it, or never saw it.
LEGACY_REJECTION_REASON = "Score below minimum threshold"

#: Where a review checkpoint keeps the threshold its run accepted at, so a
#: report restored from it states that threshold rather than guessing one.
CHECKPOINT_MIN_SCORE_KEY = "min_score_threshold"

#: Where the audit record lists the relevant documents whose citations could
#: not be extracted (#310), and where a review checkpoint keeps them.
CITATION_EXTRACTION_FAILED_KEY = "citation_extraction_failed"
CHECKPOINT_EXTRACTION_FAILURES_KEY = CITATION_EXTRACTION_FAILED_KEY

#: The audit summary's count of those documents; None when not recorded.
EXTRACTION_FAILED_COUNT_KEY = "documents_citation_extraction_failed"

#: How older builds began the explanation of a scoring call that raised,
#: stored with a score of 1: the benchmark runner until #306, and the review
#: scorer until 2025-12-23. What followed was the raw exception text.
LEGACY_FAILURE_EXPLANATION_PREFIX = "Scoring failed: "

#: The explanation older builds stored, with a score of 1, for an answer they
#: could not read.
LEGACY_UNREADABLE_EXPLANATION = "Could not parse response"


@dataclass(frozen=True)
class DocumentOutcomes:
    """What became of each document, told apart rather than inferred.

    Attributes:
        accepted: Documents the model scored at or above the threshold.
        rejected: Documents the model read and scored below it; each carries
            the model's own explanation.
        failed: Documents the model could not score, each carrying the
            negative code of what went wrong.
        not_scored: Documents that never reached scoring -- removed by the
            quality filter, or left over when a run stopped early. Nothing is
            claimed about their relevance, because nothing was decided.
        min_score: The threshold the accepted/rejected split was made at.
    """

    accepted: tuple[ScoredDocument, ...]
    rejected: tuple[ScoredDocument, ...]
    failed: tuple[ScoredDocument, ...]
    not_scored: tuple[LiteDocument, ...]
    min_score: int

    def __post_init__(self) -> None:
        """Refuse a record that counts a document twice or files it wrongly.

        Raises:
            ValueError: If any document appears in more than one category, or
                sits in a category its score contradicts -- a failure among
                the judgements is the #302 defect itself.
        """
        ids = [
            scored.document.id
            for scored in (*self.accepted, *self.rejected, *self.failed)
        ] + [document.id for document in self.not_scored]
        if len(ids) != len(set(ids)):
            raise ValueError(
                "A document belongs to one outcome: accepted, rejected, "
                "failed or not scored"
            )
        if any(scored.score >= 0 for scored in self.failed):
            raise ValueError("A failed document carries a negative score")
        if any(not 0 <= scored.score < self.min_score for scored in self.rejected):
            raise ValueError(
                f"A rejected document scored from 0 to below {self.min_score}"
            )
        if any(scored.score < self.min_score for scored in self.accepted):
            raise ValueError(
                f"An accepted document scored at least {self.min_score}"
            )

    @property
    def documents_scored(self) -> int:
        """How many documents the model actually scored.

        A document it could not score was not scored, and one it never saw
        was not either, so this is ``accepted + rejected`` -- the identity
        ``ReportMetadata.documents_scored`` follows (#301), so for a live run
        the audit agrees with the report's Methodology section.

        Returns:
            The number of documents that received a usable score.
        """
        return len(self.accepted) + len(self.rejected)


def classify_document_outcomes(
    documents_found: Sequence[LiteDocument],
    scored_documents: Sequence[ScoredDocument],
    min_score: int,
) -> DocumentOutcomes:
    """Sort every document into what actually happened to it.

    Args:
        documents_found: Every document the search returned, including those
            a quality filter removed before scoring. A document listed twice
            is one document.
        scored_documents: Every document that received a score, accepted,
            rejected and failed alike. Repeated scores for one document are
            reduced to the first. A failure an older build stored as a 1 is
            read as the failure it was (:func:`as_recorded_failure`), so no
            caller has to remember to: missed, it was audited as rejected,
            with the raw provider text as its reason (#315).
        min_score: The threshold the run accepted at.

    Returns:
        The four outcomes, together holding each document exactly once.
    """
    accepted: list[ScoredDocument] = []
    rejected: list[ScoredDocument] = []
    failed: list[ScoredDocument] = []
    seen: set[str] = set()

    for stored in scored_documents:
        if stored.document.id in seen:
            continue
        seen.add(stored.document.id)
        scored = as_recorded_failure(stored)
        if scored.score < 0:
            failed.append(scored)
        elif scored.score >= min_score:
            accepted.append(scored)
        else:
            rejected.append(scored)

    not_scored: list[LiteDocument] = []
    for document in documents_found:
        if document.id not in seen:
            seen.add(document.id)
            not_scored.append(document)

    return DocumentOutcomes(
        accepted=tuple(accepted),
        rejected=tuple(rejected),
        failed=tuple(failed),
        not_scored=tuple(not_scored),
        min_score=min_score,
    )


def outcome_sort_key(score: int | None) -> tuple[int, int]:
    """Where a document goes when documents are listed by outcome.

    The order of the audit record's categories: documents the model judged,
    highest score first; then those it could not score; then those scoring
    never reached. A failure's negative code is not a score, so it is not
    sorted as one (#307).

    Args:
        score: The document's score as recorded -- negative when the scoring
            failed -- or None when it was never scored.

    Returns:
        A key that sorts ascending into that order.
    """
    if score is None:
        return (2, 0)
    if score < 0:
        return (1, 0)
    return (0, -score)


def score_failure_reason(score: int) -> str | None:
    """Why a scoring failed, in the reader's words, from the score it left.

    Args:
        score: A score as recorded; negative when the scoring failed.

    Returns:
        The failure's description, or None if the score is not a failure. A
        code this build cannot name degrades to :data:`UNNAMED_FAILURE_REASON`;
        the failure itself is never dropped.
    """
    if score >= 0:
        return None
    try:
        return EvaluationErrorCode(score).description
    except ValueError:
        return UNNAMED_FAILURE_REASON


def is_scoring_failure(scored: ScoredDocument) -> bool:
    """Whether a stored score records a failure rather than a judgement.

    Every build since #306 stores a failure as its negative error code. Older
    ones stored it as a 1 -- the lowest judgement there is -- with one of two
    explanations only the code ever wrote, so those rows are recognised by
    both together: a model that answers 1 gives its own reasons.

    Args:
        scored: A score as stored.

    Returns:
        True for a failure in either form.
    """
    if scored.score < 0:
        return True
    explanation = scored.explanation if isinstance(scored.explanation, str) else ""
    return scored.score == SCORE_MIN and (
        explanation.startswith(LEGACY_FAILURE_EXPLANATION_PREFIX)
        or explanation == LEGACY_UNREADABLE_EXPLANATION
    )


def scoring_failure_sql(table: str = "") -> str:
    """The SQL condition :func:`is_scoring_failure` states, for a query.

    Built from this module's constants only, never from input.

    Args:
        table: The alias of the ``scored_documents`` table, if it has one.

    Returns:
        A parenthesised condition true for a stored failure in either form.
    """
    column = f"{table}." if table else ""
    prefix = LEGACY_FAILURE_EXPLANATION_PREFIX
    # substr, not LIKE: SQLite's LIKE ignores ASCII case, and the Python rule
    # does not
    return (
        f"({column}score < 0 OR ({column}score = {SCORE_MIN} AND "
        f"(substr({column}explanation, 1, {len(prefix)}) = '{prefix}' "
        f"OR {column}explanation = '{LEGACY_UNREADABLE_EXPLANATION}')))"
    )


def as_recorded_failure(scored: ScoredDocument) -> ScoredDocument:
    """A stored score, with an older build's failure made to read as one.

    Older builds stored a failed scoring as a 1 with the raw exception text
    (#315). Read as it stands it is a rejection, whose "reason" is provider
    text that can carry the request URL. It becomes a failure whose cause
    cannot be named -- which is true: the text that named it is not shown.

    Args:
        scored: A score as stored.

    Returns:
        The score unchanged, or for an older failure a copy carrying
        ``UNKNOWN_ERROR`` in place of the score and no provider text.
    """
    if scored.score < 0 or not is_scoring_failure(scored):
        return scored
    code = EvaluationErrorCode.UNKNOWN_ERROR
    return replace(
        scored,
        score=code.value,
        explanation=f"{LEGACY_FAILURE_EXPLANATION_PREFIX}{code.description}",
    )


def scoring_failure_cause(scored: ScoredDocument) -> EvaluationErrorCode | None:
    """The classified cause a stored failed scoring names.

    The scoring agent returns a failure rather than raising one, so a pass
    that re-scores documents has no exception to classify: the cause is in the
    row it just stored. An older build's failure has none -- its cause was the
    provider text that is not shown -- and reads as ``UNKNOWN_ERROR``, which is
    what :func:`as_recorded_failure` already decided it is.

    Args:
        scored: A score as stored.

    Returns:
        The cause, or ``None`` when the score is a judgement rather than a
        failure.
    """
    if not is_scoring_failure(scored):
        return None
    return _recorded_cause(as_recorded_failure(scored).score)


def scoring_failure_reason(scored: ScoredDocument) -> str | None:
    """Why this document's scoring failed, in the reader's words.

    Args:
        scored: A document that received a score.

    Returns:
        The failure's description, or None if the scoring succeeded.
    """
    return score_failure_reason(scored.score)


def scoring_failure_code(scored: ScoredDocument) -> str | None:
    """The name of the error code the scoring recorded, if it failed.

    Args:
        scored: A document that received a score.

    Returns:
        The code's name, :data:`UNKNOWN_FAILURE_CODE` when this build cannot
        name it, or None if the scoring succeeded.
    """
    if scored.score >= 0:
        return None
    try:
        return EvaluationErrorCode(scored.score).name
    except ValueError:
        return UNKNOWN_FAILURE_CODE


def outcome_summary(
    outcomes: DocumentOutcomes, *, threshold_recorded: bool = True
) -> dict[str, int | None]:
    """The counts the audit record's summary states about the outcomes.

    Args:
        outcomes: What became of each document.
        threshold_recorded: False when the run never recorded its threshold
            (a report restored from an older checkpoint), so the split was
            made at a default nobody chose and the threshold is stated as
            unknown.

    Returns:
        The four counts, the documents actually scored, and the threshold.
    """
    return {
        "documents_scored": outcomes.documents_scored,
        "documents_scored_relevant": len(outcomes.accepted),
        "documents_rejected": len(outcomes.rejected),
        "documents_failed": len(outcomes.failed),
        "documents_not_scored": len(outcomes.not_scored),
        "min_score_threshold": outcomes.min_score if threshold_recorded else None,
    }


def outcome_entries(outcomes: DocumentOutcomes) -> dict[str, list[dict[str, Any]]]:
    """One entry per document, under the list its outcome names.

    Args:
        outcomes: What became of each document.

    Returns:
        The audit record's four document lists. ``scored_documents`` is the
        accepted ones -- an older name, kept so older builds can still read
        the file.
    """
    return {
        "scored_documents": [
            {
                "id": scored.document.id,
                "title": scored.document.title,
                "score": scored.score,
                "explanation": scored.explanation,
                # Implied by the list. ScoredDocument.is_relevant assumes a
                # threshold of 3, which this run may not have used.
                "is_relevant": True,
            }
            for scored in outcomes.accepted
        ],
        # A document the model read and scored below the threshold, with the
        # reason the model itself gave. Nothing else belongs here (#302).
        "rejected_documents": [
            {
                "id": scored.document.id,
                "title": scored.document.title,
                "score": scored.score,
                "reason": scored.explanation,
            }
            for scored in outcomes.rejected
        ],
        # A document nobody could score. It was not judged.
        "failed_documents": [
            {
                "id": scored.document.id,
                "title": scored.document.title,
                "score": scored.score,
                "error_code": scoring_failure_code(scored),
                "reason": scoring_failure_reason(scored),
            }
            for scored in outcomes.failed
        ],
        # A document scoring never reached. No reason is recorded, because
        # none was given.
        "unscored_documents": [
            {"id": document.id, "title": document.title}
            for document in outcomes.not_scored
        ],
    }


def extraction_failure_entries(
    failures: Sequence[ExtractionFailure],
) -> list[dict[str, Any]]:
    """One audit entry per relevant document that could not be read (#310).

    An accepted document with no citation is either one the model read and
    found nothing quotable in (#303), or one it could not read at all. Only
    this list tells them apart: without it the record reads a failure as
    silence, #261's harm in the file that outlives the session.

    Args:
        failures: The documents whose extraction failed.

    Returns:
        Entries shaped as a failed scoring's are: the document, the error
        code's name and its description.
    """
    return [
        {
            "id": failure.document.id,
            "title": failure.document.title,
            "error_code": failure.cause.name,
            "reason": failure.cause.description,
        }
        for failure in failures
    ]


def extraction_failure_summary(
    failures: Sequence[ExtractionFailure] | None,
) -> dict[str, int | None]:
    """The audit summary's count of relevant documents that were not read.

    Args:
        failures: The run's extraction failures, or None when the run never
            recorded them (a report restored from an older checkpoint).

    Returns:
        The count, None stating it was not recorded -- never 0, which would
        say every uncited relevant document was read and found silent.
    """
    return {EXTRACTION_FAILED_COUNT_KEY: None if failures is None else len(failures)}


def extraction_failure_record(
    failures: Sequence[ExtractionFailure] | None,
) -> dict[str, list[dict[str, Any]]]:
    """The audit record's list of relevant documents that were not read.

    Args:
        failures: The run's extraction failures, or None when not recorded.

    Returns:
        The list under its key -- empty when every document was read, which
        is a statement -- or nothing at all when the run never recorded it,
        so the record reads as one that cannot tell.
    """
    if failures is None:
        return {}
    return {CITATION_EXTRACTION_FAILED_KEY: extraction_failure_entries(failures)}


def readable_extraction_failures(
    record: Mapping[str, Any],
) -> list[Mapping[str, Any]] | None:
    """The extraction failures an audit record lists, if it can be read whole.

    Args:
        record: An audit record, as loaded -- input (golden rule 1).

    Returns:
        The entries, possibly none; or None for a record that cannot say:
        one written before the list was kept, or one whose list is not a list
        of entries. Read as empty, such a record would vouch that every
        uncited relevant document was silent.
    """
    entries = record.get(CITATION_EXTRACTION_FAILED_KEY)
    if not isinstance(entries, list):
        return None
    if not all(isinstance(entry, Mapping) for entry in entries):
        return None
    return entries


def checkpoint_metadata_with_extraction_failures(
    metadata: Mapping[str, Any],
    failures: Sequence[ExtractionFailure],
) -> dict[str, Any]:
    """A checkpoint's metadata with its run's extraction failures added.

    Updating a checkpoint replaces its metadata whole, so everything it
    already kept -- the threshold -- is carried over.

    Args:
        metadata: What the checkpoint keeps so far.
        failures: The documents whose extraction failed, possibly none.

    Returns:
        The new metadata: each failure as its document's id and the error
        code's integer value, the form the codes persist in elsewhere.
    """
    return {
        **metadata,
        CHECKPOINT_EXTRACTION_FAILURES_KEY: [
            {"document_id": failure.document.id, "error_code": failure.cause.value}
            for failure in failures
        ],
    }


def recorded_extraction_failures(
    checkpoint_metadata: object,
    documents: Mapping[str, LiteDocument],
) -> list[ExtractionFailure] | None:
    """The extraction failures a checkpoint recorded for its run.

    Args:
        checkpoint_metadata: The checkpoint's stored metadata -- JSON from
            the database, so it is read as input (golden rule 1).
        documents: The run's documents by id, to name each failure by.

    Returns:
        The failures, possibly none; or None when the checkpoint recorded
        none (a run from before they were kept) or a record that cannot be
        read whole -- skipping what it cannot read would under-count what
        failed, and a document listed twice would over-count it. A cause
        this build cannot name degrades to ``UNKNOWN_ERROR``: the reason
        degrades, the loss never does.
    """
    if not isinstance(checkpoint_metadata, Mapping):
        return None
    entries = checkpoint_metadata.get(CHECKPOINT_EXTRACTION_FAILURES_KEY)
    if not isinstance(entries, list):
        return None
    failures: list[ExtractionFailure] = []
    seen: set[str] = set()
    for entry in entries:
        if not isinstance(entry, Mapping):
            return None
        document_id = entry.get("document_id")
        document = documents.get(document_id) if isinstance(document_id, str) else None
        if document is None or document.id in seen:
            return None
        seen.add(document.id)
        failures.append(ExtractionFailure(document, _recorded_cause(entry.get("error_code"))))
    return failures


def _recorded_cause(value: object) -> EvaluationErrorCode:
    """The cause a stored error code names.

    Args:
        value: The stored code.

    Returns:
        The code, or ``UNKNOWN_ERROR`` for one this build cannot name -- or
        for ``SUCCESS``, which names no failure.
    """
    if isinstance(value, bool) or not isinstance(value, int) or value >= 0:
        return EvaluationErrorCode.UNKNOWN_ERROR
    try:
        return EvaluationErrorCode(value)
    except ValueError:
        return EvaluationErrorCode.UNKNOWN_ERROR


def predates_outcome_split(record: Mapping[str, Any]) -> bool:
    """Whether an audit record was written before failures were told apart.

    Every build since #302 writes ``failed_documents``, empty or not; a
    record without it listed failures and filtered documents as rejected.

    Args:
        record: An audit record, as loaded.

    Returns:
        True for a record whose rejected list cannot be taken at its word.
    """
    return "failed_documents" not in record


def without_invented_reason(entry: Mapping[str, Any]) -> dict[str, Any]:
    """An older record's entry, without the reason nobody gave.

    Only :data:`LEGACY_REJECTION_REASON` is dropped: it was written beside
    every non-accepted document alike. Any other reason is the model's own
    and is kept. The file itself is never changed.

    Args:
        entry: One entry of an older record's rejected list.

    Returns:
        The entry, minus that one stock reason.
    """
    if entry.get("reason") == LEGACY_REJECTION_REASON:
        return {key: value for key, value in entry.items() if key != "reason"}
    return dict(entry)


def recorded_min_score(checkpoint_metadata: object) -> int | None:
    """The threshold a checkpoint recorded for its run, if a usable one.

    Args:
        checkpoint_metadata: The checkpoint's stored metadata -- JSON from
            the database, so it is read as input (golden rule 1).

    Returns:
        The threshold, or None when the checkpoint recorded none (a run from
        before it was kept) or one that is not a score.
    """
    if not isinstance(checkpoint_metadata, Mapping):
        return None
    value = checkpoint_metadata.get(CHECKPOINT_MIN_SCORE_KEY)
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    if not SCORE_MIN <= value <= SCORE_MAX:
        return None
    return value
