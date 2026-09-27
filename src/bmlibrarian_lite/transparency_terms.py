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

"""The words a transparency rating is qualified and explained in (#386).

Shared with the iOS/macOS and Android apps: every constant bound by
``doc/cross_platform/transparency_parity/risk_explanation_strings.json`` is
asserted against it on all three platforms
(``tests/test_risk_explanation_contract.py`` here).

A leaf module, standard library only. The analyser builds
:class:`ScoreComponent` and ``transparency_models`` stores it, and
``transparency/__init__`` imports the manager, which imports the analyser --
so the analyser importing anything under ``transparency`` would start a cycle.
"""

import math
from collections.abc import Mapping
from dataclasses import dataclass
from typing import Any

#: Shown with every rating made without the article's full text.
LIMITED_CERTAINTY_NOTE = "Limited certainty because of lack of full text access"

#: Joined, after one space, to a badge whose rating's certainty is limited.
LIMITED_CERTAINTY_BADGE_SUFFIX = "· limited"

#: A caveat on a rating a source could not be read for (``sources_unreachable``).
PROVISIONAL_RESULT_CAVEAT = (
    "A source this analysis needed could not be read, so the rating is "
    "provisional: it rests on less than the full record. Re-analyse the study "
    "before relying on it."
)

#: Desktop only, own wording (user decision, 2026-09-27): a caveat on a
#: stored High that no rule matches under the current settings. Swift and
#: Kotlin's shared sentence names a cause ("an earlier version of the
#: analysis") and a remedy ("Re-analyse the study") that do not hold here --
#: on the desktop, rows from an earlier analyser are never shown (see
#: ``is_current``) and "Re-analyse" never offers a current row -- so this
#: names the real cause (a settings change) and the real state (the stored
#: rating stands until the study is re-analysed). Bound only for Swift and
#: Kotlin in the shared contract's ``swift_kotlin_only`` section.
UNEXPLAINED_RATING_CAVEAT = (
    "None of the current high-risk rules matches this study's recorded "
    "findings, so it was probably rated under transparency settings that "
    "have since changed, or by a newer version of the app; a stored rating "
    "is not re-rated when the settings change."
)

#: Desktop only, and not in the shared contract at all: the score is a
#: reason, but its terms were never recorded (a row stored before #386) or
#: could not be read back. Swift and Kotlin always compute the breakdown
#: fresh, so this state cannot arise for them.
BREAKDOWN_UNAVAILABLE_CAVEAT = (
    "How the score was reached is not available: this analysis was stored "
    "before its terms were recorded, or they could not be read."
)

HIGH_RISK_SECTION_HEADING = "Why Studies Were Rated High Transparency Risk"
REASONS_LABEL = "Rated high risk because"
SCORE_BREAKDOWN_LABEL = "How the score was reached"
OTHER_CONCERNS_LABEL = "Other concerns recorded"
CAVEATS_LABEL = "Caveats"

# Reason sentences. The desktop charges a missing statement only against text
# it read (#352, #353, #359), so these are Swift's full-text forms and there
# are no "not searched" variants: see the parity README.
SCORE_BELOW_THRESHOLD_REASON = (
    "Its transparency score of {score}/100 is below the high-risk cut-off of "
    "{threshold}."
)
INDUSTRY_WITHHELD_DATA_REASON = (
    "Industry funding was detected, with {percent}% confidence, and "
    "{data_phrase}."
)
MISSING_COI_REASON = (
    "No conflict of interest statement was found in the full text. A missing "
    "statement is enough on its own for a high rating."
)

#: What a withheld data level says about the study's data, by stored value.
DATA_PHRASES: dict[str, str] = {
    "restricted": "its data are available only with restrictions",
    "not_available": "its data are not available",
    "not_stated": "no data availability statement was found in the full text",
}

# Score component labels, verbatim from Swift's TransparencyScorer.
STARTING_SCORE_LABEL = "Starting score"
DATA_AVAILABILITY_COMPONENT_LABEL = "Data availability: {level}"
COI_PRESENT_LABEL = "Conflict of interest statement present"
COI_INDUSTRY_TIES_LABEL = "Conflict of interest statement discloses industry ties"
COI_MISSING_LABEL = "No conflict of interest statement found"
TRIAL_REGISTERED_LABEL = "Trial registered"
RESULTS_POSTED_LABEL = "Trial results posted on time"
RESULTS_NOT_POSTED_LABEL = "Trial results not posted"
OUTCOME_SWITCHING_LABEL = "Outcome switching detected"
INDUSTRY_TIES_WITHHELD_DATA_LABEL = "Industry ties with restricted or unavailable data"

#: How each stored data availability level is named to a reader.
DATA_AVAILABILITY_DISPLAY_NAMES: dict[str, str] = {
    "full_open": "Fully Open",
    "on_request": "Available on Request",
    "restricted": "Restricted",
    "not_available": "Not Available",
    "not_stated": "Not Stated",
    "unknown": "Unknown",
}


def high_risk_introduction(count: int) -> str | None:
    """The sentence introducing the high-risk section.

    Args:
        count: How many studies were rated high.

    Returns:
        The introduction, or ``None`` when there are none.
    """
    if count <= 0:
        return None
    studies = "1 study was" if count == 1 else f"{count} studies were"
    return (
        f"{studies} rated high transparency risk. Each rule listed below is "
        "enough on its own for that rating; the caveats say where a rating "
        "rests on less than it appears to."
    )


def confidence_percent(confidence: float) -> int:
    """A confidence as a whole percentage, rounded half away from zero.

    Swift's ``.rounded()`` and Kotlin's ``roundToInt`` both give 63 for
    0.625; Python's ``round`` gives 62. Confidences are never negative.

    Args:
        confidence: Between 0.0 and 1.0.

    Returns:
        The percentage.
    """
    return math.floor(confidence * 100 + 0.5)


@dataclass(frozen=True)
class ScoreComponent:
    """One addition or penalty in a transparency score.

    Attributes:
        label: What the term is for, e.g. "Trial results not posted".
        points: Points added (positive) or subtracted (negative).
        records_missing_statement: Whether the term records a COI or data
            statement as missing. Kept for parity with Swift; the desktop
            never qualifies it, since it charges only what it read.
    """

    label: str
    points: int
    records_missing_statement: bool = False

    def signed_points(self) -> str:
        """The points with an explicit sign, e.g. "+5" or "-10".

        Returns:
            The signed points.
        """
        return f"+{self.points}" if self.points > 0 else str(self.points)

    def to_dict(self) -> dict[str, Any]:
        """Serialise for storage.

        Returns:
            The component as a JSON-ready dict.
        """
        return {
            "label": self.label,
            "points": self.points,
            "records_missing_statement": self.records_missing_statement,
        }

    @classmethod
    def from_dict(cls, data: Mapping[str, Any]) -> "ScoreComponent":
        """Read a stored component, refusing any shape it was not written in.

        Args:
            data: A dict written by :meth:`to_dict`.

        Returns:
            The component.

        Raises:
            ValueError: If a field is missing or of the wrong type. A bool is
                not accepted as points, though ``bool`` subclasses ``int``.
        """
        label = data.get("label") if isinstance(data, Mapping) else None
        points = data.get("points") if isinstance(data, Mapping) else None
        missing = (
            data.get("records_missing_statement", False)
            if isinstance(data, Mapping)
            else None
        )
        if not isinstance(label, str):
            raise ValueError(f"score component label must be a string: {label!r}")
        if not isinstance(points, int) or isinstance(points, bool):
            raise ValueError(f"score component points must be an int: {points!r}")
        if not isinstance(missing, bool):
            raise ValueError(
                f"records_missing_statement must be a bool: {missing!r}"
            )
        return cls(label=label, points=points, records_missing_statement=missing)
