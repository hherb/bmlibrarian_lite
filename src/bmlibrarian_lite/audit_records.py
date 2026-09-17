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
a document with no score at all is in neither list.

The companion of :mod:`~bmlibrarian_lite.analysis_failures`, whose contract is
``doc/cross_platform/analysis_failure_reporting.md``.
"""

from collections.abc import Sequence
from dataclasses import dataclass

from .data_models import EvaluationErrorCode, LiteDocument, ScoredDocument

#: What a failure whose code this build cannot name is recorded as. The count
#: never degrades, only the reason (the #301 rule).
UNNAMED_FAILURE_REASON = "Scoring failed for a reason this build cannot name"


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
    """

    accepted: tuple[ScoredDocument, ...]
    rejected: tuple[ScoredDocument, ...]
    failed: tuple[ScoredDocument, ...]
    not_scored: tuple[LiteDocument, ...]

    def __post_init__(self) -> None:
        """Refuse a record that counts one document twice.

        Raises:
            ValueError: If any document appears in more than one category.
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

    @property
    def documents_scored(self) -> int:
        """How many documents the model actually scored.

        A document it could not score was not scored, and one it never saw
        was not either, so this is ``accepted + rejected`` -- the identity the
        report's Methodology section reconciles against (#301).

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
            a quality filter removed before scoring.
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

    not_scored = tuple(
        document for document in documents_found if document.id not in seen
    )
    return DocumentOutcomes(
        accepted=tuple(accepted),
        rejected=tuple(rejected),
        failed=tuple(failed),
        not_scored=not_scored,
    )


def scoring_failure_reason(scored: ScoredDocument) -> str | None:
    """What the scoring of this document failed of, if it failed.

    Args:
        scored: A document that received a score.

    Returns:
        The failure in the reader's words, or None if the scoring succeeded.
        A code this build cannot name degrades to
        :data:`UNNAMED_FAILURE_REASON`; the failure itself is never dropped.
    """
    if scored.score >= 0:
        return None
    try:
        return EvaluationErrorCode(scored.score).description
    except ValueError:
        return UNNAMED_FAILURE_REASON


def scoring_failure_code(scored: ScoredDocument) -> str | None:
    """The name of the error code the scoring recorded, if it failed.

    Args:
        scored: A document that received a score.

    Returns:
        The code's name, ``"UNKNOWN"`` when this build cannot name it, or
        None if the scoring succeeded.
    """
    if scored.score >= 0:
        return None
    try:
        return EvaluationErrorCode(scored.score).name
    except ValueError:
        return "UNKNOWN"
