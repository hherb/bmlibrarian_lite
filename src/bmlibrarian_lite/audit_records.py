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
failed (see :class:`~bmlibrarian_lite.data_models.EvaluationErrorCode`), and
a document with no score at all is recorded as not scored, in none of the
scored lists. They also build the part of the audit record that says so, so
the saved file and the dialog cannot drift apart, and read what records and
checkpoints written by older builds can and cannot tell.

The companion of :mod:`~bmlibrarian_lite.analysis_failures`, whose contract is
``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections.abc import Mapping, Sequence
from dataclasses import dataclass
from typing import Any

from .constants import SCORE_MAX, SCORE_MIN
from .data_models import EvaluationErrorCode, LiteDocument, ScoredDocument

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
            reduced to the first.
        min_score: The threshold the run accepted at.

    Returns:
        The four outcomes, together holding each document exactly once.
    """
    accepted: list[ScoredDocument] = []
    rejected: list[ScoredDocument] = []
    failed: list[ScoredDocument] = []
    seen: set[str] = set()

    for scored in scored_documents:
        if scored.document.id in seen:
            continue
        seen.add(scored.document.id)
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
