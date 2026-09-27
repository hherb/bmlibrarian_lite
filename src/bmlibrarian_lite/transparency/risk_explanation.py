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

"""Why a study was rated high transparency risk, and how far to trust it (#386).

The desktop port of Swift's ``TransparencyRiskExplanation``. Two things are
deliberately not ported: the "Unassessed" display and the "(full text not
searched)" qualifiers. The desktop charges a missing statement only against
text it read (#352, #353, #359), so both would be unreachable; see
``doc/cross_platform/transparency_parity/README.md``.
"""

from dataclasses import dataclass
from typing import TYPE_CHECKING

from ..transparency_terms import (
    BREAKDOWN_UNAVAILABLE_CAVEAT,
    CAVEATS_LABEL,
    DATA_PHRASES,
    INDUSTRY_WITHHELD_DATA_REASON,
    LIMITED_CERTAINTY_NOTE,
    MISSING_COI_REASON,
    OTHER_CONCERNS_LABEL,
    PROVISIONAL_RESULT_CAVEAT,
    REASONS_LABEL,
    SCORE_BELOW_THRESHOLD_REASON,
    SCORE_BREAKDOWN_LABEL,
    UNEXPLAINED_RATING_CAVEAT,
    ScoreComponent,
    confidence_percent,
)
from .transparency_models import (
    HighRiskTrigger,
    IndustryFundingWithWithheldData,
    MissingCoiStatement,
    ScoreBelowThreshold,
    TransparencyResult,
    TransparencyRisk,
    high_risk_triggers_for,
)

if TYPE_CHECKING:
    from .transparency_settings import TransparencySettings

# The analyser's indicator strings a stated reason already says. Repeated
# here rather than imported, to keep the analyser (and ``requests``) out of
# the GUI's import path; ``test_restated_indicators_are_the_analysers``
# pins them to the analyser's constants.
_MISSING_COI_INDICATOR = "No conflict of interest statement found"
_INDUSTRY_FUNDING_INDICATOR = "Industry funding detected"
_INDUSTRY_RESTRICTED_DATA_INDICATOR = "Industry-funded with restricted data access"


def certainty_note(result: TransparencyResult) -> str | None:
    """What a reader must be told alongside a rating.

    Args:
        result: A shown (current) result.

    Returns:
        The limited-certainty note when the full text was not analysed,
        else ``None``.
    """
    return None if result.full_text_analyzed else LIMITED_CERTAINTY_NOTE


def _sentence(trigger: HighRiskTrigger, result: TransparencyResult) -> str:
    """A rule, as a sentence about this study.

    Args:
        trigger: The high-risk rule that fired.
        result: The result it fired on, for the fields its sentence quotes
            (the industry-funding confidence).

    Returns:
        The reason sentence.

    Raises:
        TypeError: If ``trigger`` is not one of the known variants.
    """
    if isinstance(trigger, ScoreBelowThreshold):
        return SCORE_BELOW_THRESHOLD_REASON.format(
            score=trigger.score, threshold=trigger.threshold
        )
    if isinstance(trigger, IndustryFundingWithWithheldData):
        return INDUSTRY_WITHHELD_DATA_REASON.format(
            percent=confidence_percent(result.industry_funding_confidence),
            data_phrase=DATA_PHRASES[trigger.data_availability],
        )
    if isinstance(trigger, MissingCoiStatement):
        return MISSING_COI_REASON
    raise TypeError(f"unknown high-risk trigger {trigger!r}")


def _restated(triggers: list[HighRiskTrigger]) -> set[str]:
    """Indicator strings the stated reasons already say.

    Args:
        triggers: The rules that fired for this result.

    Returns:
        The analyser indicator strings a reason for one of ``triggers``
        already states, so they are not repeated among the other concerns.
    """
    restated: set[str] = set()
    for trigger in triggers:
        if isinstance(trigger, MissingCoiStatement):
            restated.add(_MISSING_COI_INDICATOR)
        elif isinstance(trigger, IndustryFundingWithWithheldData):
            restated.update(
                {_INDUSTRY_FUNDING_INDICATOR, _INDUSTRY_RESTRICTED_DATA_INDICATOR}
            )
    return restated


@dataclass(frozen=True)
class TransparencyRiskExplanation:
    """Why one stored result was rated high, in words a report can show.

    Attributes:
        score: The transparency score (0-100).
        reasons: Each rule that rated the study high, as a sentence. Empty
            only when no current rule explains a stored High; ``caveats``
            then says so.
        score_breakdown: The score's terms, given only when a low score is
            among ``reasons`` and the terms were recorded.
        other_concerns: Recorded indicators and caveats a reason does not
            already say.
        caveats: Reasons the rating may rest on less than it appears to.
        certainty_note: The limited-certainty note, or ``None``.
    """

    score: int
    reasons: tuple[str, ...]
    score_breakdown: tuple[ScoreComponent, ...]
    other_concerns: tuple[str, ...]
    caveats: tuple[str, ...]
    certainty_note: str | None

    @classmethod
    def of(
        cls, result: TransparencyResult, settings: "TransparencySettings"
    ) -> "TransparencyRiskExplanation":
        """Explain a stored result's rating under the user's settings.

        Args:
            result: A shown (current) result, normally one rated high.
            settings: The settings its level was judged by.

        Returns:
            The explanation.
        """
        triggers = high_risk_triggers_for(result, settings)
        scored_low = any(isinstance(t, ScoreBelowThreshold) for t in triggers)

        caveats: list[str] = []
        if not triggers and result.risk_level is TransparencyRisk.HIGH:
            caveats.append(UNEXPLAINED_RATING_CAVEAT)
        if result.sources_unreachable:
            caveats.append(PROVISIONAL_RESULT_CAVEAT)
        if scored_low and result.score_components is None:
            caveats.append(BREAKDOWN_UNAVAILABLE_CAVEAT)

        seen = _restated(triggers)
        concerns: list[str] = []
        for concern in [*result.risk_indicators, *result.warnings]:
            if concern not in seen:
                seen.add(concern)
                concerns.append(concern)

        return cls(
            score=result.transparency_score,
            reasons=tuple(_sentence(t, result) for t in triggers),
            score_breakdown=(
                tuple(result.score_components or ()) if scored_low else ()
            ),
            other_concerns=tuple(concerns),
            caveats=tuple(caveats),
            certainty_note=certainty_note(result),
        )

    def labelled_lists(self) -> list[tuple[str, list[str]]]:
        """The explanation's non-empty lists, each with its label, in order.

        Returns:
            ``(label, items)`` pairs; breakdown items read "label: +N".
        """
        lists = [
            (REASONS_LABEL, list(self.reasons)),
            (
                SCORE_BREAKDOWN_LABEL,
                [f"{c.label}: {c.signed_points()}" for c in self.score_breakdown],
            ),
            (OTHER_CONCERNS_LABEL, list(self.other_concerns)),
            (CAVEATS_LABEL, list(self.caveats)),
        ]
        return [(label, items) for label, items in lists if items]
