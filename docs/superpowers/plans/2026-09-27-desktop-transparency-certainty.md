# Desktop Transparency Certainty and High-Risk Explanation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The desktop app says how far each transparency rating can be relied on and why a study was rated high risk. It uses the same words as the iOS/macOS and Android apps, and those words are pinned by one shared contract.

**Architecture:**
- A new stdlib-only leaf module, `transparency_terms.py`, holds `ScoreComponent` and every contract string, so the analyser and the stored model both import it without a cycle.
- The analyser's score becomes the clamped sum of `score_components(report)`. The rating becomes "High exactly when `high_risk_triggers(...)` is non-empty". The result stores its components.
- A pure `transparency/risk_explanation.py` turns a stored result into reasons, breakdown, other concerns and caveats. The badge, the report's reference annotation, a new report section and the methodology section read it.

**Tech Stack:** Python 3.12, PySide6, SQLite (`storage.py`), pytest. Swift (XCTest, `Packages/BioMedLit`). Kotlin (JUnit, `android/MedicalFactChecker`).

**Spec:** `docs/superpowers/specs/2026-09-27-desktop-transparency-certainty-design.md`

## Global Constraints

- **Branch:** `feat/desktop-transparency-certainty-386`. It is already checked out, and the spec is committed on it.
- **No `TRANSPARENCY_ANALYZER_VERSION` bump.** Scores, levels, indicators and caveats are unchanged for the same inputs.
- **Certainty note, verbatim:** `Limited certainty because of lack of full text access`
- **Badge suffix, verbatim:** `· limited`. It is joined to the label with one space: `High · limited`.
- **Provisional caveat, verbatim:** `A source this analysis needed could not be read, so the rating is provisional: it rests on less than the full record. Re-analyse the study before relying on it.`
- **No Unassessed display rule, and no "(full text not searched)" qualifiers, on the desktop.** This was the user's decision on 2026-09-27; the reason is in the spec.
- **Confidence percentages round half away from zero** (`math.floor(x * 100 + 0.5)`), to match Swift's `.rounded()`. Never use Python's `round()`.
- **Code style** (`doc/llm/golden_rules.md`): Google-style docstrings and type hints; no inline stylesheets beyond what the badge already does; DPI through `scaled()`.
- **Import rule:** `src/bmlibrarian_lite/transparency_terms.py` imports only the standard library.
- **Test gates before each commit:**
  - The task's tests.
  - Before the final commit: `pytest tests/`, `python .github/scripts/lint_delta.py --base-ref origin/master`, `cd Packages/BioMedLit && swift test`, and `cd android/MedicalFactChecker && ./gradlew test`.
- **Commit messages** end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.
- **Never write a closing keyword** ("fixes", "closes", "resolves", "fixed:") beside an issue number that is *not* being closed. Write "Deferred: #N".

## Review Focus

1. **A user who changed the transparency settings.** They raised the score threshold, or switched off the COI trigger. A stored High must be explained by the rules under *their* settings. When none matches, the reader sees the "None of the current high-risk rules matches…" caveat, never an empty list. The badge must use the configured settings, not the defaults. Pinned in Task 5 and Task 7.
2. **A row stored before this change.** It has no `score_components`. The report must not print an empty "How the score was reached" list; it prints the breakdown-unavailable caveat instead. Pinned in Task 5 and Task 8.
3. **A damaged `score_components` column.** A non-JSON value, or JSON of the wrong shape. The row must still be shown, with the unreadable-column caveat, and must not fail the whole read. Pinned in Task 4.
4. **Existing badge tests.** They construct results with the default `full_text_analyzed=False`, and their labels now carry ` · limited`. Update each such assertion to say which it means; never loosen it to `startswith`. Task 7.
5. **The report with no High among the cited studies.** The new section must be absent entirely: no heading and no introduction. Pinned in Task 8.

---

### Task 1: Shared terms module and the contract file

**Files:**
- Create: `src/bmlibrarian_lite/transparency_terms.py`
- Create: `doc/cross_platform/transparency_parity/risk_explanation_strings.json`
- Test: `tests/test_risk_explanation_contract.py`

**Interfaces:**
- Produces, in `bmlibrarian_lite.transparency_terms`:
  - `ScoreComponent(label: str, points: int, records_missing_statement: bool = False)`, frozen, with:
    - `.signed_points() -> str`
    - `.to_dict() -> dict[str, Any]`
    - `ScoreComponent.from_dict(data: Mapping[str, Any]) -> ScoreComponent`, which raises `ValueError` on a wrong shape
  - Constants:
    - `LIMITED_CERTAINTY_NOTE`, `LIMITED_CERTAINTY_BADGE_SUFFIX`
    - `PROVISIONAL_RESULT_CAVEAT`, `UNEXPLAINED_RATING_CAVEAT`, `BREAKDOWN_UNAVAILABLE_CAVEAT`
    - `HIGH_RISK_SECTION_HEADING`, `REASONS_LABEL`, `SCORE_BREAKDOWN_LABEL`, `OTHER_CONCERNS_LABEL`, `CAVEATS_LABEL`
    - `SCORE_BELOW_THRESHOLD_REASON`, `INDUSTRY_WITHHELD_DATA_REASON`, `MISSING_COI_REASON`
    - `DATA_PHRASES: dict[str, str]`
    - `STARTING_SCORE_LABEL`, `DATA_AVAILABILITY_COMPONENT_LABEL`, `COI_PRESENT_LABEL`, `COI_INDUSTRY_TIES_LABEL`, `COI_MISSING_LABEL`, `TRIAL_REGISTERED_LABEL`, `RESULTS_POSTED_LABEL`, `RESULTS_NOT_POSTED_LABEL`, `OUTCOME_SWITCHING_LABEL`, `INDUSTRY_TIES_WITHHELD_DATA_LABEL`
    - `DATA_AVAILABILITY_DISPLAY_NAMES: dict[str, str]`
  - Functions: `high_risk_introduction(count: int) -> str | None`, `confidence_percent(confidence: float) -> int`

- [ ] **Step 1: Write the contract file**

Create `doc/cross_platform/transparency_parity/risk_explanation_strings.json`:

```json
{
  "schema_version": 1,
  "description": "How a transparency rating is qualified and a high rating explained (#386, after PR #388). 'strings' bind Python, Swift and Kotlin string-for-string; 'swift_kotlin_only' binds the two apps, which show ratings the desktop never makes (Python charges no missing statement it did not read, so it has no 'Unassessed' display and no unrecorded certainty: see README). 'cases' are platform-neutral findings each platform scores, rates and explains with its own code; every case has full_text_searched true, the only form in which the desktop can record a missing statement. score_breakdown lines are '<label>: <signed points>'.",
  "strings": {
    "limited_certainty_note": "Limited certainty because of lack of full text access",
    "limited_certainty_badge_suffix": "· limited",
    "provisional_result_caveat": "A source this analysis needed could not be read, so the rating is provisional: it rests on less than the full record. Re-analyse the study before relying on it.",
    "unexplained_rating_caveat": "None of the current high-risk rules matches this study's recorded findings, so the rating probably comes from an earlier version of the analysis. Re-analyse the study before relying on it.",
    "section_heading": "Why Studies Were Rated High Transparency Risk",
    "reasons_label": "Rated high risk because",
    "score_breakdown_label": "How the score was reached",
    "other_concerns_label": "Other concerns recorded",
    "caveats_label": "Caveats"
  },
  "introduction_examples": [
    {"count": 1, "text": "1 study was rated high transparency risk. Each rule listed below is enough on its own for that rating; the caveats say where a rating rests on less than it appears to."},
    {"count": 3, "text": "3 studies were rated high transparency risk. Each rule listed below is enough on its own for that rating; the caveats say where a rating rests on less than it appears to."}
  ],
  "swift_kotlin_only": {
    "unrecorded_certainty_note": "Certainty unknown: this analysis did not record whether the full text was accessed. Re-analyse for a rating of known certainty.",
    "unassessed_label": "Unassessed",
    "unassessed_note": "Shown as unassessed rather than high risk: every reason for a high rating depends on statements that appear only in the full text, which was not available to search."
  },
  "cases": [
    {
      "name": "missing COI statement in a full text that was read",
      "findings": {"data_availability": "full_open", "coi": "not_stated", "industry_funding": false, "industry_confidence": 0.0, "trial_registered": false, "results": "unknown", "outcome_switching": false, "sources_unreachable": false},
      "stored_risk_level": null,
      "expected": {
        "score": 65,
        "risk_level": "high",
        "reasons": ["No conflict of interest statement was found in the full text. A missing statement is enough on its own for a high rating."],
        "score_breakdown": [],
        "caveats": []
      }
    },
    {
      "name": "low score, industry funding and unavailable data",
      "findings": {"data_availability": "not_available", "coi": "disclosed", "industry_funding": true, "industry_confidence": 0.9, "trial_registered": true, "results": "missing", "outcome_switching": true, "sources_unreachable": false},
      "stored_risk_level": null,
      "expected": {
        "score": 15,
        "risk_level": "high",
        "reasons": [
          "Its transparency score of 15/100 is below the high-risk cut-off of 40.",
          "Industry funding was detected, with 90% confidence, and its data are not available."
        ],
        "score_breakdown": [
          "Starting score: +50",
          "Data availability: not available: -15",
          "Conflict of interest statement present: +5",
          "Trial registered: +10",
          "Trial results not posted: -10",
          "Outcome switching detected: -15",
          "Industry ties with restricted or unavailable data: -10"
        ],
        "caveats": []
      }
    },
    {
      "name": "low score alone",
      "findings": {"data_availability": "not_available", "coi": "disclosed", "industry_funding": false, "industry_confidence": 0.0, "trial_registered": true, "results": "missing", "outcome_switching": true, "sources_unreachable": false},
      "stored_risk_level": null,
      "expected": {
        "score": 25,
        "risk_level": "high",
        "reasons": ["Its transparency score of 25/100 is below the high-risk cut-off of 40."],
        "score_breakdown": [
          "Starting score: +50",
          "Data availability: not available: -15",
          "Conflict of interest statement present: +5",
          "Trial registered: +10",
          "Trial results not posted: -10",
          "Outcome switching detected: -15"
        ],
        "caveats": []
      }
    },
    {
      "name": "industry funding with restricted data, provisional, confidence on a half",
      "findings": {"data_availability": "restricted", "coi": "disclosed", "industry_funding": true, "industry_confidence": 0.625, "trial_registered": false, "results": "unknown", "outcome_switching": false, "sources_unreachable": true},
      "stored_risk_level": null,
      "expected": {
        "score": 40,
        "risk_level": "high",
        "reasons": ["Industry funding was detected, with 63% confidence, and its data are available only with restrictions."],
        "score_breakdown": [],
        "caveats": ["A source this analysis needed could not be read, so the rating is provisional: it rests on less than the full record. Re-analyse the study before relying on it."]
      }
    },
    {
      "name": "industry funding with no data statement in a full text that was read",
      "findings": {"data_availability": "not_stated", "coi": "disclosed", "industry_funding": true, "industry_confidence": 0.8, "trial_registered": false, "results": "unknown", "outcome_switching": false, "sources_unreachable": false},
      "stored_risk_level": null,
      "expected": {
        "score": 50,
        "risk_level": "high",
        "reasons": ["Industry funding was detected, with 80% confidence, and no data availability statement was found in the full text."],
        "score_breakdown": [],
        "caveats": []
      }
    },
    {
      "name": "a medium rating needs no explanation",
      "findings": {"data_availability": "on_request", "coi": "disclosed", "industry_funding": false, "industry_confidence": 0.0, "trial_registered": false, "results": "unknown", "outcome_switching": false, "sources_unreachable": false},
      "stored_risk_level": null,
      "expected": {"score": 60, "risk_level": "medium", "reasons": [], "score_breakdown": [], "caveats": []}
    },
    {
      "name": "a stored high rating no current rule explains",
      "findings": {"data_availability": "full_open", "coi": "disclosed", "industry_funding": false, "industry_confidence": 0.0, "trial_registered": false, "results": "unknown", "outcome_switching": false, "sources_unreachable": false},
      "stored_risk_level": "high",
      "expected": {
        "score": 75,
        "risk_level": "high",
        "reasons": [],
        "score_breakdown": [],
        "caveats": ["None of the current high-risk rules matches this study's recorded findings, so the rating probably comes from an earlier version of the analysis. Re-analyse the study before relying on it."]
      }
    }
  ]
}
```

- [ ] **Step 2: Write the failing strings test**

Create `tests/test_risk_explanation_contract.py`:

```python
"""Binds the desktop to the shared risk-explanation contract (#386).

``doc/cross_platform/transparency_parity/risk_explanation_strings.json`` is
asserted from Python here, from Swift in ``TransparencyParityTests`` and from
Kotlin in ``RiskExplanationParityTest``. The cases are appended to this file
in Task 5, once the explanation exists.
"""

import json
from pathlib import Path

import pytest

from bmlibrarian_lite import transparency_terms as terms

CONTRACT = (
    Path(__file__).resolve().parents[1]
    / "doc/cross_platform/transparency_parity/risk_explanation_strings.json"
)


@pytest.fixture(scope="module")
def contract() -> dict:
    """The shared contract, parsed."""
    return json.loads(CONTRACT.read_text(encoding="utf-8"))


class TestTheStringsMatchTheContract:
    """Each shared constant is the contract's, byte for byte."""

    @pytest.mark.parametrize(
        ("key", "constant"),
        [
            ("limited_certainty_note", "LIMITED_CERTAINTY_NOTE"),
            ("limited_certainty_badge_suffix", "LIMITED_CERTAINTY_BADGE_SUFFIX"),
            ("provisional_result_caveat", "PROVISIONAL_RESULT_CAVEAT"),
            ("unexplained_rating_caveat", "UNEXPLAINED_RATING_CAVEAT"),
            ("section_heading", "HIGH_RISK_SECTION_HEADING"),
            ("reasons_label", "REASONS_LABEL"),
            ("score_breakdown_label", "SCORE_BREAKDOWN_LABEL"),
            ("other_concerns_label", "OTHER_CONCERNS_LABEL"),
            ("caveats_label", "CAVEATS_LABEL"),
        ],
    )
    def test_constant(self, contract, key, constant) -> None:
        """A drifted constant names itself and the contract key."""
        assert getattr(terms, constant) == contract["strings"][key], constant

    def test_every_shared_string_is_bound(self, contract) -> None:
        """A key added to the contract without a Python binding fails here."""
        assert len(contract["strings"]) == 9

    def test_introduction(self, contract) -> None:
        """Singular and plural forms read as the other platforms write them."""
        for example in contract["introduction_examples"]:
            assert terms.high_risk_introduction(example["count"]) == example["text"]

    def test_no_introduction_without_studies(self) -> None:
        """Nothing to introduce is nothing, not "0 studies were..."."""
        assert terms.high_risk_introduction(0) is None


class TestScoreComponent:
    """The unit a score's breakdown is made of."""

    def test_signed_points(self) -> None:
        """Positive terms carry a plus, negative ones their minus."""
        assert terms.ScoreComponent("Trial registered", 10).signed_points() == "+10"
        assert terms.ScoreComponent("Outcome switching detected", -15).signed_points() == "-15"

    def test_round_trip(self) -> None:
        """What is stored is what is read back."""
        component = terms.ScoreComponent(
            "No conflict of interest statement found", -5, records_missing_statement=True
        )
        assert terms.ScoreComponent.from_dict(component.to_dict()) == component

    @pytest.mark.parametrize(
        "data",
        [
            {"points": 5},
            {"label": "x"},
            {"label": 3, "points": 5},
            {"label": "x", "points": "5"},
            {"label": "x", "points": True},
            {"label": "x", "points": 5, "records_missing_statement": "yes"},
        ],
    )
    def test_a_wrong_shape_is_refused(self, data) -> None:
        """A damaged value is not read as some other score term."""
        with pytest.raises(ValueError):
            terms.ScoreComponent.from_dict(data)


class TestConfidencePercent:
    """Rounded as Swift's ``.rounded()`` rounds, not as Python's ``round``."""

    @pytest.mark.parametrize(
        ("confidence", "percent"),
        [(0.625, 63), (0.125, 13), (0.9, 90), (0.8, 80), (0.0, 0), (1.0, 100)],
    )
    def test_half_rounds_away_from_zero(self, confidence, percent) -> None:
        """62.5 is 63 on every platform; ``round`` would say 62."""
        assert terms.confidence_percent(confidence) == percent
```

- [ ] **Step 3: Run it to verify it fails**

Run: `pytest tests/test_risk_explanation_contract.py -v`
Expected: FAIL with `ImportError: cannot import name 'transparency_terms'`

- [ ] **Step 4: Write the module**

Create `src/bmlibrarian_lite/transparency_terms.py`. Use the licence header from `transparency/transparency_models.py`, lines 1-15.

```python
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

#: A caveat on a stored High that no rule matches under the current settings.
UNEXPLAINED_RATING_CAVEAT = (
    "None of the current high-risk rules matches this study's recorded "
    "findings, so the rating probably comes from an earlier version of the "
    "analysis. Re-analyse the study before relying on it."
)

#: Desktop only: the score is a reason, but its terms were never recorded
#: (a row stored before #386) or could not be read back.
BREAKDOWN_UNAVAILABLE_CAVEAT = (
    "How the score was reached is not available for this analysis; "
    "re-analyse the study to see it."
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
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `pytest tests/test_risk_explanation_contract.py -v`
Expected: all PASS.

- [ ] **Step 6: Point the badge at the one display-name table**

In `src/bmlibrarian_lite/gui/transparency_badge.py`, replace the literal `DATA_AVAILABILITY_LABELS` dict (lines ~75-82) with:

```python
# Data availability level labels for tooltips: the same names the score
# breakdown uses, from the one table.
DATA_AVAILABILITY_LABELS: Dict[str, str] = DATA_AVAILABILITY_DISPLAY_NAMES
```

Add `from ..transparency_terms import DATA_AVAILABILITY_DISPLAY_NAMES` to its imports.

Run: `pytest tests/test_transparency_badge.py -q`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add src/bmlibrarian_lite/transparency_terms.py src/bmlibrarian_lite/gui/transparency_badge.py \
  doc/cross_platform/transparency_parity/risk_explanation_strings.json tests/test_risk_explanation_contract.py
git commit -m "feat(transparency): shared terms and contract for rating explanations (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: The score is the sum of its components

**Files:**
- Modify: `src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py:2587-2654` (`calculate_transparency_score`)
- Test: `tests/test_score_components.py`

**Interfaces:**
- Consumes: `ScoreComponent` and the `*_LABEL` / `DATA_AVAILABILITY_*` constants from Task 1.
- Produces: `score_components(report: TransparencyReport) -> list[ScoreComponent]` in `study_transparency_analyzer.study_transparency_analyzer`. `calculate_transparency_score(report) -> float` is unchanged in signature and values.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_score_components.py`:

```python
"""The score a study is rated by is the sum of the terms a report shows (#386)."""

import itertools

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    COIDisclosureLevel,
    ConflictOfInterest,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    TransparencyReport,
    TrialRegistration,
    calculate_transparency_score,
    score_components,
)

DISCLOSURE = "The authors declare no competing interests."
TIES = "Dr A has received consulting fees from Pfizer."


def _coi(kind: str) -> ConflictOfInterest | None:
    if kind == "none":
        return None
    if kind == "not_stated":
        return ConflictOfInterest.not_stated()
    if kind == "not_assessed":
        return ConflictOfInterest.not_assessed()
    return ConflictOfInterest(
        statement=TIES if kind == "ties" else DISCLOSURE,
        disclosure_level=COIDisclosureLevel.DISCLOSED,
        has_industry_ties=kind == "ties",
    )


def _report(data, coi, industry, trial, results, switched) -> TransparencyReport:
    report = TransparencyReport(doi="10.1/x")
    report.data_availability = (
        None if data is None else DataAvailabilityInfo(disclosure_level=data)
    )
    report.coi_info = _coi(coi)
    report.industry_funding_detected = industry
    if trial:
        report.trial_registrations = [
            TrialRegistration(registry="ClinicalTrials.gov", registration_id="NCT00000001")
        ]
    report.results_compliance = results
    report.outcome_switching_detected = switched
    return report


ALL_REPORTS = [
    _report(*combo)
    for combo in itertools.product(
        [None, *DataDisclosureLevel],
        ["none", "not_stated", "not_assessed", "disclosed", "ties"],
        [False, True],
        [False, True],
        list(ResultsComplianceStatus),
        [False, True],
    )
]


class TestTheSumIsTheScore:
    """No term is shown that did not move the score, and none is left out."""

    @pytest.mark.parametrize("report", ALL_REPORTS)
    def test_clamped_sum(self, report) -> None:
        """Every combination of findings scores as its terms add up."""
        total = sum(c.points for c in score_components(report))
        assert calculate_transparency_score(report) == max(0, min(100, total))

    @pytest.mark.parametrize("report", ALL_REPORTS)
    def test_the_base_comes_first_and_no_term_is_zero(self, report) -> None:
        """Swift's order and filtering: the base, then only terms that count."""
        components = score_components(report)
        assert components[0].label == "Starting score"
        assert components[0].points == 50
        assert all(c.points != 0 for c in components)


class TestTheLabels:
    """The labels a reader sees, verbatim from Swift's scorer."""

    def test_a_disclosed_tie_is_credit_and_penalty(self) -> None:
        """Two terms, not a net zero that looks like nothing was found."""
        report = _report(
            DataDisclosureLevel.NOT_AVAILABLE, "ties", False, True,
            ResultsComplianceStatus.MISSING, True,
        )
        assert [(c.label, c.points) for c in score_components(report)] == [
            ("Starting score", 50),
            ("Data availability: not available", -15),
            ("Conflict of interest statement present", 5),
            ("Conflict of interest statement discloses industry ties", -5),
            ("Trial registered", 10),
            ("Trial results not posted", -10),
            ("Outcome switching detected", -15),
            ("Industry ties with restricted or unavailable data", -10),
        ]

    def test_a_statement_read_to_be_missing_is_marked(self) -> None:
        """Only NOT_STATED is charged, and it records a missing statement."""
        report = _report(
            DataDisclosureLevel.NOT_STATED, "not_stated", False, False,
            ResultsComplianceStatus.UNKNOWN, False,
        )
        assert [
            (c.label, c.points, c.records_missing_statement)
            for c in score_components(report)
        ] == [
            ("Starting score", 50, False),
            ("Data availability: not stated", -5, True),
            ("No conflict of interest statement found", -5, True),
        ]

    def test_an_unread_statement_is_no_term_at_all(self) -> None:
        """NOT_ASSESSED costs nothing and so is not listed (#352)."""
        report = _report(
            None, "not_assessed", False, False, ResultsComplianceStatus.UNKNOWN, False
        )
        assert [c.label for c in score_components(report)] == ["Starting score"]

    def test_compliant_results(self) -> None:
        """A registered trial whose results were posted on time."""
        report = _report(
            DataDisclosureLevel.FULL_OPEN, "disclosed", False, True,
            ResultsComplianceStatus.COMPLIANT, False,
        )
        assert [(c.label, c.points) for c in score_components(report)] == [
            ("Starting score", 50),
            ("Data availability: fully open", 20),
            ("Conflict of interest statement present", 5),
            ("Trial registered", 10),
            ("Trial results posted on time", 5),
        ]
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_score_components.py -q`
Expected: FAIL with `ImportError: cannot import name 'score_components'`

- [ ] **Step 3: Implement**

In `study_transparency_analyzer.py`, add to the imports near the other `..` imports (around line 40):

```python
from ..transparency_terms import (
    COI_INDUSTRY_TIES_LABEL,
    COI_MISSING_LABEL,
    COI_PRESENT_LABEL,
    DATA_AVAILABILITY_COMPONENT_LABEL,
    DATA_AVAILABILITY_DISPLAY_NAMES,
    INDUSTRY_TIES_WITHHELD_DATA_LABEL,
    OUTCOME_SWITCHING_LABEL,
    RESULTS_NOT_POSTED_LABEL,
    RESULTS_POSTED_LABEL,
    STARTING_SCORE_LABEL,
    TRIAL_REGISTERED_LABEL,
    ScoreComponent,
)
```

Replace `calculate_transparency_score` (lines 2587-2654) with the following. It keeps the original docstring's scoring philosophy and the same points:

```python
BASE_TRANSPARENCY_SCORE = 50

#: Points for each data availability level (+/- 20).
DATA_AVAILABILITY_POINTS: Dict[DataDisclosureLevel, int] = {
    DataDisclosureLevel.FULL_OPEN: 20,
    DataDisclosureLevel.AVAILABLE_ON_REQUEST: 5,
    DataDisclosureLevel.RESTRICTED: -5,
    DataDisclosureLevel.NOT_AVAILABLE: -15,
    DataDisclosureLevel.NOT_STATED: -5,
    DataDisclosureLevel.UNKNOWN: 0,
}
COI_STATEMENT_POINTS = 5
COI_INDUSTRY_TIES_PENALTY = -5
COI_NOT_STATED_PENALTY = -5
TRIAL_REGISTRATION_POINTS = 10
COMPLIANT_RESULTS_POINTS = 5
MISSING_RESULTS_PENALTY = -10
OUTCOME_SWITCHING_PENALTY = -15
INDUSTRY_TIES_WITHHELD_DATA_PENALTY = -10


def score_components(report: TransparencyReport) -> List[ScoreComponent]:
    """Each term of a study's transparency score, in the order it is applied.

    :func:`calculate_transparency_score` is the clamped sum of these, so a
    report explaining a low score lists the very terms that produced it
    (#386). Terms worth zero points are omitted, and the base comes first --
    Swift's ``TransparencyScorer.scoreComponents``, label for label.

    Scoring philosophy:
    - Having a COI statement is good (disclosure is valued), but industry
      ties disclosed via COI reduce the score because the underlying
      situation carries bias risk regardless of disclosure quality.
    - Effectively unavailable data is worse than restricted access.
    - Industry ties through institutional intermediaries are scored the
      same as direct ties -- the bias risk is the same even if the money
      doesn't reach the author's personal bank account.

    Args:
        report: The analysis whose score is being explained.

    Returns:
        The base score, then every term that moved it.
    """
    terms: List[ScoreComponent] = []

    level = (
        report.data_availability.disclosure_level
        if report.data_availability
        else None
    )
    if level is not None:
        terms.append(
            ScoreComponent(
                DATA_AVAILABILITY_COMPONENT_LABEL.format(
                    level=DATA_AVAILABILITY_DISPLAY_NAMES[level.value].lower()
                ),
                DATA_AVAILABILITY_POINTS[level],
                records_missing_statement=level is DataDisclosureLevel.NOT_STATED,
            )
        )

    if report.coi_info:
        coi_level = report.coi_info.disclosure_level
        if coi_level is COIDisclosureLevel.DISCLOSED:
            terms.append(ScoreComponent(COI_PRESENT_LABEL, COI_STATEMENT_POINTS))
            if report.coi_info.has_industry_ties:
                terms.append(
                    ScoreComponent(COI_INDUSTRY_TIES_LABEL, COI_INDUSTRY_TIES_PENALTY)
                )
        elif coi_level is COIDisclosureLevel.NOT_STATED:
            # The article was read and declares nothing
            terms.append(
                ScoreComponent(
                    COI_MISSING_LABEL,
                    COI_NOT_STATED_PENALTY,
                    records_missing_statement=True,
                )
            )
        # NOT_ASSESSED scores neither way: a study is not charged for a
        # statement nobody looked for (#352).

    if report.trial_registrations:
        terms.append(ScoreComponent(TRIAL_REGISTERED_LABEL, TRIAL_REGISTRATION_POINTS))
        if report.results_compliance == ResultsComplianceStatus.COMPLIANT:
            terms.append(ScoreComponent(RESULTS_POSTED_LABEL, COMPLIANT_RESULTS_POINTS))
        elif report.results_compliance == ResultsComplianceStatus.MISSING:
            terms.append(
                ScoreComponent(RESULTS_NOT_POSTED_LABEL, MISSING_RESULTS_PENALTY)
            )

    if report.outcome_switching_detected:
        terms.append(ScoreComponent(OUTCOME_SWITCHING_LABEL, OUTCOME_SWITCHING_PENALTY))

    # Industry ties combined with restricted data is especially concerning
    has_industry_ties = report.industry_funding_detected or (
        report.coi_info is not None and report.coi_info.has_industry_ties
    )
    if has_industry_ties and level in (
        DataDisclosureLevel.NOT_AVAILABLE,
        DataDisclosureLevel.RESTRICTED,
    ):
        terms.append(
            ScoreComponent(
                INDUSTRY_TIES_WITHHELD_DATA_LABEL, INDUSTRY_TIES_WITHHELD_DATA_PENALTY
            )
        )

    return [ScoreComponent(STARTING_SCORE_LABEL, BASE_TRANSPARENCY_SCORE)] + [
        term for term in terms if term.points != 0
    ]


def calculate_transparency_score(report: TransparencyReport) -> float:
    """Calculate overall transparency score (0-100).

    Args:
        report: The analysis to score.

    Returns:
        The clamped sum of :func:`score_components`, as a float as before.
    """
    total = sum(term.points for term in score_components(report))
    return float(max(0, min(100, total)))
```

- [ ] **Step 4: Run the new and the existing scoring tests**

Run: `pytest tests/test_score_components.py tests/test_study_transparency_analyzer.py tests/test_coi_is_not_assessed.py tests/test_unreachable_is_not_absent.py -q`
Expected: all PASS. The existing tests prove the score values did not move.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py tests/test_score_components.py
git commit -m "refactor(transparency): score is the sum of named components (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: The rating is the triggers, and the result keeps its components

**Files:**
- Modify: `src/bmlibrarian_lite/transparency/transparency_models.py`:
  - `TransparencyResult` (575-776), adding the field and its serialisation
  - `calculate_risk_level` (779-834)
  - new trigger types placed before `calculate_risk_level`
- Modify: `src/bmlibrarian_lite/transparency/__init__.py` (exports)
- Modify: `src/bmlibrarian_lite/transparency/assessment.py:84-166, 199-201`
- Test: `tests/test_high_risk_triggers.py`

**Interfaces:**
- Consumes: `ScoreComponent` (Task 1); `score_components(report)` (Task 2).
- Produces, in `bmlibrarian_lite.transparency.transparency_models` and re-exported from `bmlibrarian_lite.transparency`:
  - `ScoreBelowThreshold(score: int, threshold: int)`, `IndustryFundingWithWithheldData(data_availability: str)` and `MissingCoiStatement()`, all frozen dataclasses
  - `HighRiskTrigger = Union[...]` of the three
  - `WITHHELD_DATA_LEVELS: tuple[str, ...]`
  - `high_risk_triggers(score: int, industry_funding: bool, data_availability: str, coi_disclosure: str, settings: TransparencySettings) -> list[HighRiskTrigger]`
  - `high_risk_triggers_for(result: TransparencyResult, settings: TransparencySettings) -> list[HighRiskTrigger]`
  - `TransparencyResult.score_components: tuple[ScoreComponent, ...] | None = None`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_high_risk_triggers.py`:

```python
"""A study is rated high exactly when a named rule says so (#386)."""

import dataclasses
import itertools
from datetime import datetime

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    DataAvailabilityInfo,
    DataDisclosureLevel,
    TransparencyReport,
)
from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_ASSESSED,
    COI_NOT_STATED,
    IndustryFundingWithWithheldData,
    MissingCoiStatement,
    ScoreBelowThreshold,
    TransparencyResult,
    TransparencyRisk,
    calculate_risk_level,
    get_default_settings,
    high_risk_triggers,
    high_risk_triggers_for,
)
from bmlibrarian_lite.transparency.assessment import build_transparency_result
from bmlibrarian_lite.transparency_terms import ScoreComponent

LEVELS = ["full_open", "on_request", "restricted", "not_available", "not_stated", "unknown"]
COI = [COI_DISCLOSED, COI_NOT_STATED, COI_NOT_ASSESSED]


def _settings(**changes):
    return dataclasses.replace(get_default_settings(), **changes)


SETTINGS = [
    _settings(),
    _settings(score_threshold=55),
    _settings(industry_funding_triggers_downgrade=False),
    _settings(missing_coi_triggers_downgrade=False),
]


class TestTriggersDecideTheRating:
    """The rules a report names are the rules that were applied."""

    @pytest.mark.parametrize("settings", SETTINGS)
    def test_high_exactly_when_a_rule_matches(self, settings) -> None:
        """Every combination, under default and changed settings."""
        for score, industry, level, coi in itertools.product(
            range(0, 101, 5), [False, True], LEVELS, COI
        ):
            rating = calculate_risk_level(score, industry, level, coi, settings)
            triggers = high_risk_triggers(score, industry, level, coi, settings)
            assert (rating is TransparencyRisk.HIGH) == bool(triggers), (
                score, industry, level, coi
            )

    def test_every_matching_rule_is_returned_in_order(self) -> None:
        """Not only the first: a reader weighs whether one concern decides it."""
        assert high_risk_triggers(
            20, True, "not_available", COI_NOT_STATED, _settings()
        ) == [
            ScoreBelowThreshold(score=20, threshold=40),
            IndustryFundingWithWithheldData(data_availability="not_available"),
            MissingCoiStatement(),
        ]

    def test_an_unread_statement_is_no_rule(self) -> None:
        """NOT_ASSESSED raises nothing (#352)."""
        assert high_risk_triggers(75, False, "unknown", COI_NOT_ASSESSED, _settings()) == []

    def test_a_switched_off_rule_does_not_fire(self) -> None:
        """The desktop's settings decide which rules apply."""
        off = _settings(missing_coi_triggers_downgrade=False)
        assert high_risk_triggers(75, False, "full_open", COI_NOT_STATED, off) == []

    def test_a_stored_row_is_judged_by_the_settings_given(self) -> None:
        """``high_risk_triggers_for`` reads the row's own findings."""
        row = TransparencyResult(
            document_id="d",
            transparency_score=45,
            risk_level=TransparencyRisk.HIGH,
            data_availability_level="full_open",
            coi_disclosure=COI_DISCLOSED,
        )
        assert high_risk_triggers_for(row, _settings()) == []
        assert high_risk_triggers_for(row, _settings(score_threshold=50)) == [
            ScoreBelowThreshold(score=45, threshold=50)
        ]


class TestTheResultKeepsItsTerms:
    """The breakdown is recorded when the rating is made."""

    def _report(self) -> TransparencyReport:
        report = TransparencyReport(doi="10.1/x")
        report.data_availability = DataAvailabilityInfo(
            disclosure_level=DataDisclosureLevel.FULL_OPEN
        )
        report.transparency_score = 70.0
        return report

    def test_the_built_result_carries_the_components(self) -> None:
        """The same terms the score was summed from."""
        result = build_transparency_result("d", self._report(), _settings(), "full text")
        assert result.score_components == (
            ScoreComponent("Starting score", 50),
            ScoreComponent("Data availability: fully open", 20),
        )

    def test_components_survive_the_dict(self) -> None:
        """``to_dict``/``from_dict`` keep them, and ``None`` stays ``None``."""
        result = build_transparency_result("d", self._report(), _settings(), None)
        assert TransparencyResult.from_dict(result.to_dict()) == result
        unrecorded = dataclasses.replace(result, score_components=None)
        assert TransparencyResult.from_dict(unrecorded.to_dict()).score_components is None

    @pytest.mark.parametrize("full_text", [None, "", "   \n"])
    def test_blank_full_text_is_not_full_text(self, full_text) -> None:
        """The analyser ignores blank text, so it must not count as searched."""
        result = build_transparency_result("d", self._report(), _settings(), full_text)
        assert result.full_text_analyzed is False

    def test_supplied_full_text_counts(self) -> None:
        """The control."""
        result = build_transparency_result("d", self._report(), _settings(), "Methods ...")
        assert result.full_text_analyzed is True
```

Note: the last four tests pass the full text itself as `build_transparency_result`'s fourth argument. That argument is changed from `full_text_supplied: bool` to `full_text: str | None` in Step 3, so the blank check lives in one place.

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_high_risk_triggers.py -q`
Expected: FAIL with `ImportError: cannot import name 'IndustryFundingWithWithheldData'`

- [ ] **Step 3: Implement**

In `transparency_models.py`, add `from typing import Optional` if needed and `from ..transparency_terms import ScoreComponent` to the imports. `transparency_terms` is a leaf, so this keeps the module a leaf. Before `calculate_risk_level`, add:

```python
#: Data availability levels that, with industry funding, rate a study high.
WITHHELD_DATA_LEVELS = ("restricted", "not_available", "not_stated")


@dataclass(frozen=True)
class ScoreBelowThreshold:
    """The transparency score fell below the high-risk cut-off."""

    score: int
    threshold: int


@dataclass(frozen=True)
class IndustryFundingWithWithheldData:
    """Industry funding was detected and the data are restricted,
    unavailable or covered by no statement found in text that was read."""

    data_availability: str


@dataclass(frozen=True)
class MissingCoiStatement:
    """The article was read and carries no conflict of interest statement."""


#: A rule that, on its own, rates a study high transparency risk. Swift's
#: ``HighRiskTrigger``; the desktop's rules also honour its settings toggles.
HighRiskTrigger = Union[
    ScoreBelowThreshold, IndustryFundingWithWithheldData, MissingCoiStatement
]


def high_risk_triggers(
    score: int,
    industry_funding: bool,
    data_availability: str,
    coi_disclosure: str,
    settings: "TransparencySettings",
) -> list[HighRiskTrigger]:
    """Every rule that, on its own, rates a study high risk.

    :func:`calculate_risk_level` rates a study high exactly when this is
    non-empty, so a report explaining a high rating names the rules that
    produced it rather than a second reading of them that could drift
    (#386). All matching rules are returned, in the order they are checked.

    Only ``COI_NOT_STATED`` is a rule: ``COI_NOT_ASSESSED`` is not a finding
    about the study (#352).

    Args:
        score: Transparency score (0-100).
        industry_funding: Whether industry funding was detected.
        data_availability: Data availability level string.
        coi_disclosure: One of the three ``COI_*`` constants.
        settings: Which rules apply, and the score cut-off.

    Returns:
        The rules that apply; empty when none does.
    """
    triggers: list[HighRiskTrigger] = []
    if score < settings.score_threshold:
        triggers.append(ScoreBelowThreshold(score, settings.score_threshold))
    if (
        settings.industry_funding_triggers_downgrade
        and industry_funding
        and data_availability in WITHHELD_DATA_LEVELS
    ):
        triggers.append(IndustryFundingWithWithheldData(data_availability))
    if settings.missing_coi_triggers_downgrade and coi_disclosure == COI_NOT_STATED:
        triggers.append(MissingCoiStatement())
    return triggers


def high_risk_triggers_for(
    result: "TransparencyResult", settings: "TransparencySettings"
) -> list[HighRiskTrigger]:
    """The high-risk rules a stored row's findings meet under ``settings``.

    A row rated under other settings, or by another analyser, can carry a
    High none of these explains; callers must say so rather than present an
    empty list as the reason.

    Args:
        result: A stored transparency result.
        settings: The settings to judge it by -- the user's, not defaults.

    Returns:
        The rules that apply.
    """
    return high_risk_triggers(
        result.transparency_score,
        result.industry_funding_detected,
        result.data_availability_level,
        result.coi_disclosure,
        settings,
    )
```

Replace the body of `calculate_risk_level` below its docstring with:

```python
    if high_risk_triggers(
        score, industry_funding, data_availability, coi_disclosure, settings
    ):
        return TransparencyRisk.HIGH

    # Medium risk conditions
    if score <= MEDIUM_RISK_SCORE_THRESHOLD:
        return TransparencyRisk.MEDIUM

    if industry_funding:
        return TransparencyRisk.MEDIUM

    return TransparencyRisk.LOW
```

In `TransparencyResult`:
- Replace the `full_text_analyzed` comment and its docstring entry (`"(future enhancement)"`) with: `full_text_analyzed: Whether the article's full text was analysed. False rates it with limited certainty, and every surface says so (#386).`
- Add the field after `full_text_analyzed`:

```python
    # The terms the score was summed from, in order (#386). ``None`` means
    # not recorded: a row stored before the terms were, or one whose stored
    # terms could not be read back.
    score_components: Optional[tuple[ScoreComponent, ...]] = None
```

  and add its docstring entry `score_components: The terms the score was summed from; None when not recorded.`
- In `to_dict`, add:
  `"score_components": (None if self.score_components is None else [c.to_dict() for c in self.score_components]),`
- In `from_dict`, add:

```python
            score_components=(
                None
                if data.get("score_components") is None
                else tuple(
                    ScoreComponent.from_dict(item) for item in data["score_components"]
                )
            ),
```

In `transparency/__init__.py`, import and export (in `__all__`) these names: `HighRiskTrigger`, `IndustryFundingWithWithheldData`, `MissingCoiStatement`, `ScoreBelowThreshold`, `WITHHELD_DATA_LEVELS`, `high_risk_triggers` and `high_risk_triggers_for`.

In `assessment.py`:
- Add `score_components` to the analyser import.
- Change `build_transparency_result`'s last parameter to `full_text: Optional[str]`, with the docstring "The full text the caller handed the analyser, if any. Blank text is ignored by the analyser and so is not counted as analysed."
- Replace the `full_text_analyzed=(...)` expression with:

```python
        full_text_analyzed=(
            bool(full_text and full_text.strip())
            or any("Full-text" in s for s in report.data_sources_used)
        ),
        score_components=tuple(score_components(report)),
```

- In `assess_document`, change the call to `build_transparency_result(document_id, report, settings, full_text)`.

Then grep for other callers of `build_transparency_result(` and `full_text_supplied` under `src/` and `tests/`, and update each one to pass the text (or `None`):

Run: `grep -rn "full_text_supplied\|build_transparency_result(" src tests`

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_high_risk_triggers.py tests/test_transparency_models.py tests/test_a_corrected_analyser_reaches_stored_rows.py tests/test_transparency_manager.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/transparency tests/test_high_risk_triggers.py
git commit -m "refactor(transparency): high rating is its triggers; results keep score terms (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: Store the components

**Files:**
- Modify: `src/bmlibrarian_lite/storage.py`, in these places:
  - the schema (962-982)
  - a new migration method after `_migrate_transparency_source_reachability` (535-575), called beside it at line ~300
  - `_transparency_result_from_row` (3597-3647)
  - `save_transparency_result` (3708-3750)
- Test: `tests/test_stored_score_components.py`

**Interfaces:**
- Consumes: `TransparencyResult.score_components` (Task 3); `ScoreComponent.from_dict`, which raises `ValueError` (Task 1).
- Produces: the stored and read `score_components`. When the column is NULL, the component is `None`. When it can't be read, the component is `None` and a caveat is appended to `warnings`.

- [ ] **Step 1: Write the failing tests**

Create `tests/test_stored_score_components.py`. Build the storage the way `tests/test_an_undecodable_transparency_row.py` does: read its storage fixture and copy it here, keeping the same `tmp_path`-based `LiteConfig`.

```python
"""A result's score terms survive the store, and a damaged column is named (#386)."""

import sqlite3
from datetime import datetime

import pytest

from bmlibrarian_lite.transparency import TransparencyResult, TransparencyRisk
from bmlibrarian_lite.transparency_terms import ScoreComponent

# ``storage`` fixture: copied from tests/test_an_undecodable_transparency_row.py

COMPONENTS = (
    ScoreComponent("Starting score", 50),
    ScoreComponent("No conflict of interest statement found", -5, True),
)


def _result(components=COMPONENTS) -> TransparencyResult:
    return TransparencyResult(
        document_id="doc-1",
        transparency_score=45,
        risk_level=TransparencyRisk.HIGH,
        analyzed_at=datetime(2026, 9, 27),
        score_components=components,
    )


def _set_column(storage, value) -> None:
    with storage._sqlite_connection() as conn:
        conn.execute(
            "UPDATE transparency_results SET score_components = ? WHERE document_id = ?",
            (value, "doc-1"),
        )
        conn.commit()


class TestTheTermsAreStored:
    def test_round_trip(self, storage) -> None:
        storage.save_transparency_result(_result())
        assert storage.get_transparency_result("doc-1").score_components == COMPONENTS

    def test_not_recorded_stays_not_recorded(self, storage) -> None:
        storage.save_transparency_result(_result(components=None))
        assert storage.get_transparency_result("doc-1").score_components is None

    def test_the_batch_reader_agrees(self, storage) -> None:
        storage.save_transparency_result(_result())
        rows = storage.get_transparency_results_batch(["doc-1"])
        assert rows["doc-1"].score_components == COMPONENTS


class TestADamagedColumn:
    """Unreadable is not absent: the row is shown, and says what it lost."""

    @pytest.mark.parametrize(
        "raw", ["not json", '{"label": "x"}', '[{"label": "x"}]', "[1, 2]"]
    )
    def test_is_named_not_hidden(self, storage, raw) -> None:
        storage.save_transparency_result(_result())
        _set_column(storage, raw)
        row = storage.get_transparency_result("doc-1")
        assert isinstance(row, TransparencyResult)
        assert row.score_components is None
        assert any("score breakdown could not be read" in w for w in row.warnings)

    def test_null_is_not_damage(self, storage) -> None:
        storage.save_transparency_result(_result())
        _set_column(storage, None)
        row = storage.get_transparency_result("doc-1")
        assert row.score_components is None
        assert not any("could not be read" in w for w in row.warnings)


class TestTheMigration:
    def test_an_older_table_gains_the_column(self, tmp_path) -> None:
        """A table built before #386 is given the column, NULL for old rows.

        Build the pre-#386 ``transparency_results`` table: copy the CREATE
        statement from ``storage.py`` without ``score_components``. Insert
        one row, construct ``LiteStorage`` over that directory the way the
        fixture does, and assert the read row's ``score_components`` is
        None.
        """
```

The migration test's body is left as a description on purpose. Write it with the same `LiteStorage` construction the copied fixture uses, and the exact pre-#386 CREATE statement: `storage.py:962-982` minus the new line.

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_stored_score_components.py -q`
Expected: FAIL. `score_components` is `None` after the round trip, or there's an `sqlite3.OperationalError: no such column`.

- [ ] **Step 3: Implement**

Schema: add `score_components TEXT,  -- JSON array; NULL = not recorded (#386)` after `full_text_analyzed`.

Add a migration method mirroring `_migrate_transparency_source_reachability`, and call it right after that one:

```python
    def _migrate_transparency_score_components(self) -> None:
        """Give older tables the column a score's terms are stored in (#386).

        Rows written before it read NULL, which is "not recorded": the
        report then says the breakdown is not available rather than listing
        none.

        Raises:
            SQLiteError: If the column cannot be added. Runs from
                ``_init_sqlite``, so it aborts construction.
        """
        try:
            with self._sqlite_connection() as conn:
                cursor = conn.execute("PRAGMA table_info(transparency_results)")
                columns = [row["name"] for row in cursor.fetchall()]
                if "score_components" not in columns:
                    conn.execute(
                        "ALTER TABLE transparency_results "
                        "ADD COLUMN score_components TEXT"
                    )
                    logger.info("Added score_components to transparency_results.")
                conn.commit()
        except sqlite3.Error as e:
            raise SQLiteError(
                f"Could not add transparency_results.score_components: {e}"
            ) from e
```

Add a reader beside `_stored_transparency_lists`:

```python
    @classmethod
    def _stored_score_components(
        cls, row: sqlite3.Row
    ) -> tuple[Optional[tuple["ScoreComponent", ...]], Optional[str]]:
        """Read a row's score terms, or say they were lost.

        Args:
            row: The ``transparency_results`` row being rebuilt.

        Returns:
            The terms (``None`` when NULL or unreadable), and the caveat to
            append when they could not be read.
        """
        from .transparency_terms import ScoreComponent

        raw = row["score_components"]
        if raw is None:
            return None, None
        try:
            items = json.loads(raw)
            if not isinstance(items, list):
                raise ValueError("score_components is not a list")
            return tuple(ScoreComponent.from_dict(item) for item in items), None
        except (ValueError, TypeError) as error:
            logger.warning(
                "Document %s has unreadable score_components (%s); "
                "showing it without a breakdown.",
                row["document_id"],
                type(error).__name__,
            )
            return None, cls._unreadable_column_caveat("score breakdown")
```

`json.JSONDecodeError` is a `ValueError`. Bytes (non-UTF-8, via `_text_or_bytes`) fail in `json.loads` with a `ValueError` or `TypeError`, and are covered by the same branch.

In `_transparency_result_from_row`, before `return`:

```python
        components, lost = self._stored_score_components(row)
        if lost:
            caveats.append(lost)
```

and pass `score_components=components` to the constructor.

In `save_transparency_result`, add `score_components` to the column list, one more `?`, and the value:

```python
                    None
                    if result.score_components is None
                    else json.dumps([c.to_dict() for c in result.score_components]),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_stored_score_components.py tests/test_an_undecodable_transparency_row.py tests/test_storage*.py -q`
Expected: all PASS.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/storage.py tests/test_stored_score_components.py
git commit -m "feat(storage): store each transparency score's terms (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: The explanation, and the contract's cases

**Files:**
- Create: `src/bmlibrarian_lite/transparency/risk_explanation.py`
- Modify: `tests/test_risk_explanation_contract.py` (append cases)
- Test: `tests/test_risk_explanation.py`

**Interfaces:**
- Consumes: the Task 1 constants, `high_risk_triggers_for` and the trigger types (Task 3), `TransparencyResult.score_components`.
- Produces, in `bmlibrarian_lite.transparency.risk_explanation`:
  - `certainty_note(result: TransparencyResult) -> str | None`
  - `TransparencyRiskExplanation`, frozen, with fields `score: int`, `reasons: tuple[str, ...]`, `score_breakdown: tuple[ScoreComponent, ...]`, `other_concerns: tuple[str, ...]`, `caveats: tuple[str, ...]` and `certainty_note: str | None`
  - `TransparencyRiskExplanation.of(result, settings) -> TransparencyRiskExplanation`
  - `.labelled_lists() -> list[tuple[str, list[str]]]`, which returns only the non-empty lists, in the order reasons, breakdown (as `"label: +N"`), other concerns, caveats

- [ ] **Step 1: Write the failing tests**

Append to `tests/test_risk_explanation_contract.py`:

```python
import dataclasses

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    COIDisclosureLevel,
    ConflictOfInterest,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    TransparencyReport,
    TrialRegistration,
    calculate_transparency_score,
)
from bmlibrarian_lite.transparency import TransparencyRisk, get_default_settings
from bmlibrarian_lite.transparency.assessment import build_transparency_result
from bmlibrarian_lite.transparency.risk_explanation import TransparencyRiskExplanation


def _case_ids(contract_path=CONTRACT):
    return [c["name"] for c in json.loads(contract_path.read_text())["cases"]]


def _report(findings: dict) -> TransparencyReport:
    report = TransparencyReport(doi="10.1000/test", pmid="123")
    report.data_availability = DataAvailabilityInfo(
        disclosure_level=DataDisclosureLevel(findings["data_availability"])
    )
    report.coi_info = (
        ConflictOfInterest(
            statement="The authors declare no competing interests.",
            disclosure_level=COIDisclosureLevel.DISCLOSED,
        )
        if findings["coi"] == "disclosed"
        else ConflictOfInterest.not_stated()
    )
    report.industry_funding_detected = findings["industry_funding"]
    report.industry_funding_confidence = findings["industry_confidence"]
    if findings["trial_registered"]:
        report.trial_registrations = [
            TrialRegistration(registry="ClinicalTrials.gov", registration_id="NCT00000001")
        ]
    report.results_compliance = ResultsComplianceStatus(findings["results"])
    report.outcome_switching_detected = findings["outcome_switching"]
    report.crossref_record_unreachable = findings["sources_unreachable"]
    report.transparency_score = calculate_transparency_score(report)
    return report


@pytest.mark.parametrize("name", _case_ids())
def test_case(contract, name) -> None:
    """Python scores, rates and explains each case as the contract says."""
    case = next(c for c in contract["cases"] if c["name"] == name)
    settings = get_default_settings()
    result = build_transparency_result(
        "doc", _report(case["findings"]), settings, "full text"
    )
    if case["stored_risk_level"]:
        result = dataclasses.replace(
            result, risk_level=TransparencyRisk(case["stored_risk_level"])
        )
    explanation = TransparencyRiskExplanation.of(result, settings)
    expected = case["expected"]
    assert result.transparency_score == expected["score"]
    assert result.risk_level.value == expected["risk_level"]
    assert list(explanation.reasons) == expected["reasons"]
    assert [
        f"{c.label}: {c.signed_points()}" for c in explanation.score_breakdown
    ] == expected["score_breakdown"]
    assert list(explanation.caveats) == expected["caveats"]
```

Create `tests/test_risk_explanation.py` for the desktop-only behaviour:

```python
"""Why a stored High is high, in words a reader can weigh (#386)."""

import dataclasses
from datetime import datetime

from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
    get_default_settings,
)
from bmlibrarian_lite.transparency.risk_explanation import (
    TransparencyRiskExplanation,
    certainty_note,
)
from bmlibrarian_lite.transparency_terms import (
    BREAKDOWN_UNAVAILABLE_CAVEAT,
    LIMITED_CERTAINTY_NOTE,
    UNEXPLAINED_RATING_CAVEAT,
    ScoreComponent,
)


def _row(**changes) -> TransparencyResult:
    base = TransparencyResult(
        document_id="d",
        transparency_score=65,
        risk_level=TransparencyRisk.HIGH,
        data_availability_level="full_open",
        coi_disclosure=COI_NOT_STATED,
        risk_indicators=[
            "No conflict of interest statement found",
            "Outcome switching detected",
        ],
        warnings=["Funder 'Acme Trust' matched no known body."],
        analyzed_at=datetime(2026, 9, 27),
        full_text_analyzed=True,
        score_components=(ScoreComponent("Starting score", 50),),
    )
    return dataclasses.replace(base, **changes)


class TestCertainty:
    def test_without_full_text_the_note_is_given(self) -> None:
        assert certainty_note(_row(full_text_analyzed=False)) == LIMITED_CERTAINTY_NOTE

    def test_with_full_text_there_is_none(self) -> None:
        assert certainty_note(_row()) is None


class TestOtherConcerns:
    def test_a_stated_reason_is_not_repeated(self) -> None:
        """The COI reason already says it; the rest of the record stays."""
        explanation = TransparencyRiskExplanation.of(_row(), get_default_settings())
        assert explanation.other_concerns == (
            "Outcome switching detected",
            "Funder 'Acme Trust' matched no known body.",
        )


class TestTheUsersSettings:
    def test_a_rule_switched_off_since_is_caveated(self) -> None:
        """Review focus 1: a stored High no current rule explains says so."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        explanation = TransparencyRiskExplanation.of(_row(), settings)
        assert explanation.reasons == ()
        assert explanation.caveats == (UNEXPLAINED_RATING_CAVEAT,)

    def test_a_raised_threshold_is_the_reason(self) -> None:
        settings = dataclasses.replace(get_default_settings(), score_threshold=70)
        row = _row(coi_disclosure=COI_DISCLOSED, risk_indicators=[])
        explanation = TransparencyRiskExplanation.of(row, settings)
        assert explanation.reasons == (
            "Its transparency score of 65/100 is below the high-risk cut-off of 70.",
        )


class TestAnUnrecordedBreakdown:
    def test_is_said_not_listed(self) -> None:
        """Review focus 2: no empty list, and the reader is told why."""
        row = _row(
            transparency_score=30,
            coi_disclosure=COI_DISCLOSED,
            risk_indicators=[],
            score_components=None,
        )
        explanation = TransparencyRiskExplanation.of(row, get_default_settings())
        assert explanation.score_breakdown == ()
        assert BREAKDOWN_UNAVAILABLE_CAVEAT in explanation.caveats
        assert [label for label, _ in explanation.labelled_lists()] == [
            "Rated high risk because",
            "Other concerns recorded",
            "Caveats",
        ]

    def test_not_needed_when_the_score_is_no_reason(self) -> None:
        explanation = TransparencyRiskExplanation.of(
            _row(score_components=None), get_default_settings()
        )
        assert BREAKDOWN_UNAVAILABLE_CAVEAT not in explanation.caveats
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_risk_explanation_contract.py tests/test_risk_explanation.py -q`
Expected: FAIL with `ModuleNotFoundError: ... risk_explanation`

- [ ] **Step 3: Implement**

Create `src/bmlibrarian_lite/transparency/risk_explanation.py`, with the licence header:

```python
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
    """A rule, as a sentence about this study."""
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
    """Indicator strings the stated reasons already say."""
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
```

Add to `tests/test_risk_explanation.py` the pin mentioned in the module:

```python
def test_restated_indicators_are_the_analysers() -> None:
    """The repeated strings cannot drift from the analyser's constants."""
    from bmlibrarian_lite.study_transparency_analyzer import study_transparency_analyzer as sta
    from bmlibrarian_lite.transparency import risk_explanation as rx

    assert rx._MISSING_COI_INDICATOR == sta.RISK_INDICATOR_MISSING_COI_STATEMENT
    assert rx._INDUSTRY_FUNDING_INDICATOR == sta.RISK_INDICATOR_INDUSTRY_FUNDING
    assert (
        rx._INDUSTRY_RESTRICTED_DATA_INDICATOR
        == sta.RISK_INDICATOR_INDUSTRY_RESTRICTED_DATA
    )
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `pytest tests/test_risk_explanation_contract.py tests/test_risk_explanation.py -q`
Expected: all PASS, including all 7 contract cases.

- [ ] **Step 5: Commit**

```bash
git add src/bmlibrarian_lite/transparency/risk_explanation.py tests/test_risk_explanation_contract.py tests/test_risk_explanation.py
git commit -m "feat(transparency): explain a high rating from its rules (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: Pin the invariant that makes the port's omissions safe

**Files:**
- Test: `tests/test_no_high_rests_on_unread_text.py`

**Interfaces:**
- Consumes: `StudyTransparencyAnalyzer._analyze_conflicts(report, fulltext_sections, fulltext_read)` and `_analyze_data_availability(report, fulltext_sections, fulltext_read)`; `build_transparency_result`, `high_risk_triggers_for` and the trigger types.

- [ ] **Step 1: Write the test**

```python
"""On the desktop, no High can rest on a statement nobody looked for (#386).

Swift and Android show such a High as "Unassessed" and qualify its terms
"(full text not searched)". The desktop ports neither, because its analyser
charges a missing COI or data statement only against text it read (#352,
#353, #359). This is the property that makes leaving them out safe: if it
breaks, the explanation's full-text wording becomes false.
"""

import itertools

import pytest

from bmlibrarian_lite.data_models import FullTextFetch
from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    StudyTransparencyAnalyzer,
    TransparencyReport,
    calculate_transparency_score,
)
from bmlibrarian_lite.transparency import (
    IndustryFundingWithWithheldData,
    MissingCoiStatement,
    get_default_settings,
    high_risk_triggers_for,
)
from bmlibrarian_lite.transparency.assessment import build_transparency_result


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    return StudyTransparencyAnalyzer(
        email="test@example.com", use_browser_fallback=False, auto_discover_fulltext=False
    )


EUROPE_PMC = {
    "no pmcid": None,
    "no open-access copy": FullTextFetch.absent(),
    "xml without sections": FullTextFetch.served("<article><front/></article>"),
}


@pytest.mark.parametrize(
    ("europe_pmc", "pubmed_read"),
    list(itertools.product(EUROPE_PMC, [False, True])),
)
def test_nothing_read_charges_nothing(analyzer, europe_pmc, pubmed_read) -> None:
    """Industry-funded, and no text read: no missing-statement rule fires."""
    report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=pubmed_read)
    report.industry_funding_detected = True
    report.industry_funding_confidence = 0.9
    fetch = EUROPE_PMC[europe_pmc]
    if fetch is not None:
        report.pmcid = "PMC1"
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: fetch

    analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)
    analyzer._analyze_data_availability(report, fulltext_sections={}, fulltext_read=False)
    report.transparency_score = calculate_transparency_score(report)
    result = build_transparency_result("d", report, get_default_settings(), None)

    triggers = high_risk_triggers_for(result, get_default_settings())
    assert MissingCoiStatement() not in triggers
    assert IndustryFundingWithWithheldData("not_stated") not in triggers
    assert result.full_text_analyzed is False


def test_the_control_read_text_is_still_charged(analyzer) -> None:
    """Without this, the test above would pass on an analyser that never charges."""
    report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=True)
    report.industry_funding_detected = True
    sections = {"methods": "...", "funding": "NIH grant R01."}
    analyzer._analyze_conflicts(report, fulltext_sections=sections, fulltext_read=True)
    analyzer._analyze_data_availability(report, fulltext_sections=sections, fulltext_read=True)
    report.transparency_score = calculate_transparency_score(report)
    result = build_transparency_result("d", report, get_default_settings(), "text")

    triggers = high_risk_triggers_for(result, get_default_settings())
    assert MissingCoiStatement() in triggers
    assert IndustryFundingWithWithheldData("not_stated") in triggers
```

- [ ] **Step 2: Run it**

Run: `pytest tests/test_no_high_rests_on_unread_text.py -v`
Expected: PASS. This is a pin, not new behaviour. If a case fails, stop and report it: the invariant is false, and the spec's decision needs revisiting with the user.

- [ ] **Step 3: Mutation-check it**

Back up the analyser with `cp`, never `git checkout`. Then mutate the no-full-text branch of `_analyze_conflicts` (the `else` after `elif fulltext_read:`, around line 3330) to assign `ConflictOfInterest.not_stated()`. Run with bytecode off:

```bash
cp src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py /tmp/sta.bak
# apply the mutation with the Edit tool
PYTHONDONTWRITEBYTECODE=1 pytest tests/test_no_high_rests_on_unread_text.py -q -p no:cacheprovider
cp /tmp/sta.bak src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py
cmp /tmp/sta.bak src/bmlibrarian_lite/study_transparency_analyzer/study_transparency_analyzer.py && echo RESTORED
```

Expected: the mutated run FAILS, and `RESTORED` prints. Repeat once for `_analyze_data_availability`'s final `else` branch, mutated to `report.data_availability = analyze_data_availability(None)`.

- [ ] **Step 4: Commit**

```bash
git add tests/test_no_high_rests_on_unread_text.py
git commit -m "test(transparency): pin that no desktop High rests on unread text (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: The badge says limited, why, and provisional

**Files:**
- Modify: `src/bmlibrarian_lite/gui/transparency_badge.py`, in these places:
  - the `TransparencyBadge.__init__` signature
  - `_render` (167-218)
  - `_set_tooltip` (220-294)
- Modify: `src/bmlibrarian_lite/gui/document_card.py`, in these places:
  - the `__init__` signature (280-320)
  - the two `TransparencyBadge(` constructions (~373, ~768)
- Modify: `src/bmlibrarian_lite/gui/audit_literature_tab.py`, in the `__init__` and the `DocumentCard(` call (~206)
- Modify: `src/bmlibrarian_lite/gui/audit_trail_tab.py:128`
- Test: `tests/test_transparency_badge.py`, plus a new `tests/test_badge_certainty.py`

**Interfaces:**
- Consumes: `certainty_note` and `TransparencyRiskExplanation` (Task 5); `LIMITED_CERTAINTY_BADGE_SUFFIX`, `PROVISIONAL_RESULT_CAVEAT` and `REASONS_LABEL` (Task 1); `get_default_settings` from `bmlibrarian_lite.transparency`.
- Produces: new keyword parameters, each defaulting to `None`:
  - `TransparencyBadge(outcome, compact=False, parent=None, settings=None)`
  - `DocumentCard(..., transparency_settings=None)`
  - `AuditLiteratureTab(parent=None, transparency_settings=None)`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_badge_certainty.py`, with the `qapp` fixture copied from `tests/test_transparency_badge.py:45-51`:

```python
"""The badge qualifies a rating made without full text, and says why it is High (#386)."""

import dataclasses
from datetime import datetime

import pytest

pytest.importorskip("PySide6")

from bmlibrarian_lite.gui.transparency_badge import TransparencyBadge  # noqa: E402
from bmlibrarian_lite.transparency import (  # noqa: E402
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
    get_default_settings,
)
from bmlibrarian_lite.transparency_terms import (  # noqa: E402
    LIMITED_CERTAINTY_NOTE,
    PROVISIONAL_RESULT_CAVEAT,
    UNEXPLAINED_RATING_CAVEAT,
)


def _row(**changes) -> TransparencyResult:
    base = TransparencyResult(
        document_id="d",
        transparency_score=65,
        risk_level=TransparencyRisk.HIGH,
        coi_disclosure=COI_NOT_STATED,
        analyzed_at=datetime(2026, 9, 27),
        full_text_analyzed=True,
    )
    return dataclasses.replace(base, **changes)


class TestTheLabel:
    @pytest.mark.parametrize(("compact", "text"), [(True, "High"), (False, "High Risk")])
    def test_full_text_is_unqualified(self, qapp, compact, text) -> None:
        assert TransparencyBadge(_row(), compact=compact).label.text() == text

    @pytest.mark.parametrize(
        ("compact", "text"), [(True, "High · limited"), (False, "High Risk · limited")]
    )
    def test_without_full_text_it_is_limited(self, qapp, compact, text) -> None:
        badge = TransparencyBadge(_row(full_text_analyzed=False), compact=compact)
        assert badge.label.text() == text


class TestTheTooltip:
    def test_carries_the_note(self, qapp) -> None:
        tip = TransparencyBadge(_row(full_text_analyzed=False)).toolTip()
        assert LIMITED_CERTAINTY_NOTE in tip

    def test_no_note_with_full_text(self, qapp) -> None:
        assert LIMITED_CERTAINTY_NOTE not in TransparencyBadge(_row()).toolTip()

    def test_names_the_rule(self, qapp) -> None:
        tip = TransparencyBadge(_row()).toolTip()
        assert "<b>Rated high risk because:</b>" in tip
        assert (
            "No conflict of interest statement was found in the full text. "
            "A missing statement is enough on its own for a high rating."
        ) in tip

    def test_says_provisional(self, qapp) -> None:
        tip = TransparencyBadge(_row(sources_unreachable=True)).toolTip()
        assert PROVISIONAL_RESULT_CAVEAT in tip

    def test_uses_the_settings_it_was_given(self, qapp) -> None:
        """Review focus 1: the user's settings, not the defaults."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        tip = TransparencyBadge(_row(), settings=settings).toolTip()
        assert UNEXPLAINED_RATING_CAVEAT in tip

    def test_a_lower_rating_lists_no_rules(self, qapp) -> None:
        row = _row(risk_level=TransparencyRisk.LOW, coi_disclosure="disclosed")
        assert "Rated high risk because" not in TransparencyBadge(row).toolTip()
```

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_badge_certainty.py -q`
Expected: FAIL. The label lacks ` · limited`, and there is an `unexpected keyword argument 'settings'`.

- [ ] **Step 3: Implement the badge**

In `transparency_badge.py`, add these imports:

```python
from ..transparency import get_default_settings
from ..transparency.risk_explanation import TransparencyRiskExplanation, certainty_note
from ..transparency.transparency_settings import TransparencySettings
from ..transparency_terms import (
    LIMITED_CERTAINTY_BADGE_SUFFIX,
    PROVISIONAL_RESULT_CAVEAT,
    REASONS_LABEL,
    UNEXPLAINED_RATING_CAVEAT,
)
```

`__init__` gains `settings: Optional[TransparencySettings] = None`, documented as: "The transparency settings the rating was judged by. The tooltip names the rules under these; defaults when omitted." Before `_render()`, store it as `self._settings = settings or get_default_settings()`.

In `_render`, after `label_text` is chosen for a `TransparencyResult`:

```python
            # Every rating made without the article's full text says so,
            # wherever it is shown (user decision, PR #388; #386)
            if certainty_note(self.outcome) is not None:
                label_text = f"{label_text} {LIMITED_CERTAINTY_BADGE_SUFFIX}"
```

In `_set_tooltip`, replace the Header block with:

```python
        # Header
        lines.append(f"<b>Transparency Score:</b> {r.transparency_score}/100")
        lines.append(f"<b>Risk Level:</b> {RISK_LABELS[r.risk_level]}")
        note = certainty_note(r)
        if note:
            lines.append(f"<i>{note}</i>")
        if r.sources_unreachable:
            lines.append(f"<b>Provisional:</b> {PROVISIONAL_RESULT_CAVEAT}")
        if r.risk_level is TransparencyRisk.HIGH:
            explanation = TransparencyRiskExplanation.of(r, self._settings)
            lines.append("")
            lines.append(f"<b>{REASONS_LABEL}:</b>")
            for reason in explanation.reasons:
                lines.append(f"  • {reason}")
            if UNEXPLAINED_RATING_CAVEAT in explanation.caveats:
                lines.append(f"  • {UNEXPLAINED_RATING_CAVEAT}")
        lines.append("")
```

Delete the trailing `# Full text analysis status` block ("Analysis includes full text"). Its absence is now the absence of the note.

- [ ] **Step 4: Thread the settings through**

- `DocumentCard.__init__` gains `transparency_settings: Optional[TransparencySettings] = None`, stored as `self._transparency_settings`. It is passed as `settings=self._transparency_settings` to both `TransparencyBadge(` constructions.
- `AuditLiteratureTab.__init__(self, parent=None, transparency_settings=None)` stores it and passes `transparency_settings=self._transparency_settings` to `DocumentCard(`.
- In `audit_trail_tab.py:128`: `self.literature_tab = AuditLiteratureTab(transparency_settings=config.transparency)`.

Then check that the settings dialog mutates `config.transparency` in place rather than replacing it:

Run: `grep -n "config.transparency =" -r src/bmlibrarian_lite`

If anything assigns a new object, pass a zero-argument callable (`lambda: config.transparency`) instead, and resolve it at tooltip time. Record which you did in the commit message.

- [ ] **Step 5: Update the existing badge tests**

Run: `pytest tests/test_transparency_badge.py tests/test_a_failed_transparency_analysis_reaches_the_reader.py tests/test_document_card.py -q`

For each failure caused by the new ` · limited` suffix, decide what that test means. Set `full_text_analyzed=True` in its result when it is about the level, or expect the suffixed label when it is about a rating without full text. Never loosen an assertion to `startswith`/`in`. Delete or rewrite any test asserting "Analysis includes full text", to assert that the note is absent instead.

Expected after the edits: all PASS.

- [ ] **Step 6: Commit**

```bash
git add src/bmlibrarian_lite/gui tests/test_badge_certainty.py tests/test_transparency_badge.py tests/test_a_failed_transparency_analysis_reaches_the_reader.py tests/test_document_card.py
git commit -m "feat(gui): badge says limited, why a study is High, and provisional (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: The report: annotation, high-risk section, methodology

**Files:**
- Modify: `src/bmlibrarian_lite/agents/report_risk_helpers.py`:
  - `format_reference_risk_annotation` (265-312)
  - a new `format_high_risk_section`
- Modify: `src/bmlibrarian_lite/agents/reporting_agent.py`:
  - `generate_report` (~340-363), to append the section
  - `format_methodology_section` (transparency part ~778-841)
- Modify: `src/bmlibrarian_lite/transparency/transparency_models.py`, in `TransparencyCounts` (236-325) and `_count_rows` (328-366)
- Modify: `src/bmlibrarian_lite/data_models.py`, in the `ReportMetadata` fields (~2412), `to_dict` (~2454) and `from_dict` (~2475)
- Modify: `src/bmlibrarian_lite/gui/systematic_review_tab.py:262-270` (`_record_transparency_counts`)
- Test: `tests/test_report_transparency_certainty.py`

**Interfaces:**
- Consumes: `TransparencyRiskExplanation` and `certainty_note` (Task 5); `high_risk_introduction`, `HIGH_RISK_SECTION_HEADING`, `LIMITED_CERTAINTY_NOTE` and `PROVISIONAL_RESULT_CAVEAT` (Task 1).
- Produces:
  - `format_high_risk_section(entries: Sequence[tuple[int, str, TransparencyResult]], settings: TransparencySettings) -> str`, which returns `""` when `entries` is empty
  - `TransparencyCounts.limited: int` and `.provisional: int`
  - `ReportMetadata.transparency_limited_count: int = 0` and `transparency_provisional_count: int = 0`

- [ ] **Step 1: Write the failing tests**

Create `tests/test_report_transparency_certainty.py`:

```python
"""The report qualifies limited ratings and explains each High (#386)."""

import dataclasses
from datetime import datetime

import pytest

from bmlibrarian_lite.agents.report_risk_helpers import (
    format_high_risk_section,
    format_reference_risk_annotation,
)
from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_STATED,
    TransparencyCounts,
    TransparencyResult,
    TransparencyRisk,
    count_transparency_over,
    get_default_settings,
)
from bmlibrarian_lite.transparency_terms import ScoreComponent


def _row(**changes) -> TransparencyResult:
    base = TransparencyResult(
        document_id="d1",
        transparency_score=65,
        risk_level=TransparencyRisk.HIGH,
        data_availability_level="full_open",
        coi_disclosure=COI_NOT_STATED,
        analyzed_at=datetime(2026, 9, 27),
        full_text_analyzed=True,
        score_components=(
            ScoreComponent("Starting score", 50),
            ScoreComponent("Data availability: fully open", 20),
            ScoreComponent("No conflict of interest statement found", -5, True),
        ),
    )
    return dataclasses.replace(base, **changes)


class TestTheReferenceAnnotation:
    def test_a_limited_rating_says_so(self) -> None:
        annotation = format_reference_risk_annotation(_row(full_text_analyzed=False))
        assert "    - Limited certainty because of lack of full text access" in annotation.split("\n")

    def test_the_provisional_line_is_the_shared_caveat(self) -> None:
        annotation = format_reference_risk_annotation(_row(sources_unreachable=True))
        assert (
            "    - A source this analysis needed could not be read, so the rating is "
            "provisional: it rests on less than the full record. Re-analyse the study "
            "before relying on it."
        ) in annotation.split("\n")


class TestTheHighRiskSection:
    def test_absent_when_no_study_is_high(self) -> None:
        """Review focus 5: no heading, no introduction."""
        assert format_high_risk_section([], get_default_settings()) == ""

    def test_one_study(self) -> None:
        section = format_high_risk_section(
            [(3, "Smith et al., 2023", _row(full_text_analyzed=False))],
            get_default_settings(),
        )
        assert section == "\n".join(
            [
                "## Why Studies Were Rated High Transparency Risk",
                "",
                "1 study was rated high transparency risk. Each rule listed below is "
                "enough on its own for that rating; the caveats say where a rating "
                "rests on less than it appears to.",
                "",
                "**3. Smith et al., 2023**",
                "",
                "Transparency score: 65/100",
                "",
                "*Limited certainty because of lack of full text access*",
                "",
                "Rated high risk because:",
                "- No conflict of interest statement was found in the full text. "
                "A missing statement is enough on its own for a high rating.",
            ]
        )

    def test_a_low_score_lists_its_terms(self) -> None:
        row = _row(
            transparency_score=30,
            coi_disclosure=COI_DISCLOSED,
            score_components=(
                ScoreComponent("Starting score", 50),
                ScoreComponent("Outcome switching detected", -15),
                ScoreComponent("Data availability: not available", -15),
                ScoreComponent("Conflict of interest statement present", 10),
            ),
        )
        section = format_high_risk_section([(1, "Lee, 2021", row)], get_default_settings())
        assert "\nHow the score was reached:\n- Starting score: +50\n- Outcome switching detected: -15\n" in section


class TestTheCounts:
    def test_limited_and_provisional_are_counted_among_the_assessed(self) -> None:
        rows = {
            "a": _row(document_id="a", full_text_analyzed=False),
            "b": _row(document_id="b", sources_unreachable=True),
            "c": _row(document_id="c", risk_level=TransparencyRisk.LOW),
        }
        counts = count_transparency_over(rows, ["a", "b", "c"])
        assert (counts.assessed, counts.limited, counts.provisional) == (3, 1, 1)
        assert counts.considered == 3

    def test_more_limited_than_assessed_is_refused(self) -> None:
        with pytest.raises(ValueError):
            TransparencyCounts(low=1, limited=2)
```

Then add methodology assertions. Find how `tests/test_methodology_total_bound.py` builds a `ReportMetadata` and calls `format_methodology_section`, and add to the new file:

```python
class TestTheMethodology:
    def test_names_the_limited_ratings(self, agent) -> None:
        # ``agent`` / metadata construction: as in tests/test_methodology_total_bound.py
        metadata = _metadata(low=1, medium=1, high=1, limited=2, provisional=0)
        text = agent.format_methodology_section(metadata)
        assert (
            "- **Limited certainty:** 2 of 3 ratings were made without the full "
            "text. Limited certainty because of lack of full text access."
        ) in text.split("\n")

    def test_names_the_provisional_ratings(self, agent) -> None:
        metadata = _metadata(low=1, medium=1, high=1, limited=0, provisional=1)
        text = agent.format_methodology_section(metadata)
        assert (
            "- **Provisional:** 1 of 3 ratings were made while a source the "
            "analysis needed could not be read, so each rests on less than the "
            "full record. Re-analyse them before relying on them."
        ) in text.split("\n")

    def test_silent_when_every_rating_had_full_text(self, agent) -> None:
        text = agent.format_methodology_section(
            _metadata(low=1, medium=1, high=1, limited=0, provisional=0)
        )
        assert "Limited certainty" not in text
        assert "Provisional" not in text
```

`_metadata(...)` is a local helper building a `ReportMetadata`, with `transparency_analysis_applied=True`, the three risk counts, `transparency_limited_count`, `transparency_provisional_count` and `transparency_documents_considered` set to the sum. Write it next to the tests, following `test_methodology_total_bound.py`.

Also add a `generate_report` test: a report whose cited documents include one current High row, one Low row, and one withheld (superseded) High row. Mock the LLM the way `tests/test_reporting_agent_risk_warnings.py` does. Assert:
- `"## Why Studies Were Rated High Transparency Risk"` appears exactly once, after `"## References"` and before the methodology heading.
- It contains `"**N. <ref>**"` for the current High only, with N its reference number.
- The superseded row is not listed.

- [ ] **Step 2: Run them to verify they fail**

Run: `pytest tests/test_report_transparency_certainty.py -q`
Expected: FAIL with `ImportError: cannot import name 'format_high_risk_section'`

- [ ] **Step 3: Implement the counts and metadata**

`TransparencyCounts` changes:
- Add the fields `limited: int = 0` and `provisional: int = 0`, each with an Attributes entry: "Of the assessed, how many were rated without the full text" and "...while a source could not be read".
- At the end of `__post_init__`:

```python
        for part in ("limited", "provisional"):
            if getattr(self, part) > self.assessed:
                raise ValueError(
                    f"TransparencyCounts.{part} ({getattr(self, part)}) cannot "
                    f"exceed the assessed documents ({self.assessed})"
                )
```

`_count_rows` changes:
- Initialise `limited = provisional = 0`.
- In the `elif result.risk_level in counts:` branch, also count those two:

```python
        elif result.risk_level in counts:
            counts[result.risk_level] += 1
            limited += not result.full_text_analyzed
            provisional += result.sources_unreachable
```

- Pass `limited=limited, provisional=provisional` to the constructor.

`ReportMetadata`:
- Add the fields `transparency_limited_count: int = 0` and `transparency_provisional_count: int = 0`, with docstring entries.
- Add both keys to `to_dict`.
- Read them in `from_dict` with `data.get("…", 0)`.

`_record_transparency_counts` (`systematic_review_tab.py`), after the high count:

```python
        metadata.transparency_limited_count = counts.limited
        metadata.transparency_provisional_count = counts.provisional
```

- [ ] **Step 4: Implement the helpers**

In `report_risk_helpers.py`, add these imports:

```python
from ..transparency.risk_explanation import TransparencyRiskExplanation, certainty_note
from ..transparency_terms import (
    HIGH_RISK_SECTION_HEADING,
    PROVISIONAL_RESULT_CAVEAT,
    high_risk_introduction,
)
```

Also import `Sequence` from `collections.abc` and `TransparencySettings` under `TYPE_CHECKING`.

In `format_reference_risk_annotation`:
- After the `lines = [f"    ⚠️ {risk_label} RISK"]` line, add:

```python
    note = certainty_note(result)
    if note:
        lines.append(f"    - {note}")
```

- Replace the provisional `lines.append(...)` body with `lines.append(f"    - {PROVISIONAL_RESULT_CAVEAT}")`, keeping its comment.
- The function returns `""` for LOW. A LOW rating made without full text is qualified in the badge and the methodology; the reference list annotates only risky citations, as before.

Add:

```python
def format_high_risk_section(
    entries: Sequence[tuple[int, str, TransparencyResult]],
    settings: "TransparencySettings",
) -> str:
    """The section explaining every cited study rated high risk (#386).

    Args:
        entries: ``(reference number, author reference, result)`` for each
            cited study whose shown rating is High, in reference order.
        settings: The transparency settings its level was judged by.

    Returns:
        The Markdown section, or ``""`` when there is none to explain.
    """
    introduction = high_risk_introduction(len(entries))
    if introduction is None:
        return ""
    lines = [f"## {HIGH_RISK_SECTION_HEADING}", "", introduction]
    for number, reference, result in entries:
        explanation = TransparencyRiskExplanation.of(result, settings)
        lines += ["", f"**{number}. {reference}**", "", f"Transparency score: {explanation.score}/100"]
        if explanation.certainty_note:
            lines += ["", f"*{explanation.certainty_note}*"]
        for label, items in explanation.labelled_lists():
            lines += ["", f"{label}:", *(f"- {item}" for item in items)]
    return "\n".join(lines)
```

- [ ] **Step 5: Wire the section and the methodology lines**

In `generate_report`, after `full_report = f"{report}\n\n## References\n\n{references}"`:

```python
            # Why each cited High is high: every shown row rated High, not
            # only those past ``report_risk_threshold``, which governs
            # warnings rather than what a High means (#386)
            if hasattr(self.config, "transparency"):
                high_entries = [
                    (number, doc_to_ref[doc_id], results[doc_id])
                    for number, doc_id in enumerate(doc_order, 1)
                    if isinstance(results.get(doc_id), TransparencyResult)
                    and doc_id not in withheld
                    and results[doc_id].risk_level is TransparencyRisk.HIGH
                ]
                section = format_high_risk_section(
                    high_entries, self.config.transparency
                )
                if section:
                    full_report += "\n\n" + section
```

Import `format_high_risk_section` and `TransparencyRisk` if they aren't already. `enumerate(doc_order, 1)` numbers match the reference list, because `_format_references_with_risk` dedups citations in the same first-seen order.

In `format_methodology_section`, after the High table row (before the `superseded` block):

```python
            if metadata.transparency_limited_count:
                lines.append("")
                lines.append(
                    f"- **Limited certainty:** {metadata.transparency_limited_count} "
                    f"of {total_analyzed} ratings were made without the full text. "
                    f"{LIMITED_CERTAINTY_NOTE}."
                )
            if metadata.transparency_provisional_count:
                lines.append("")
                lines.append(
                    f"- **Provisional:** {metadata.transparency_provisional_count} "
                    f"of {total_analyzed} ratings were made while a source the "
                    "analysis needed could not be read, so each rests on less "
                    "than the full record. Re-analyse them before relying on them."
                )
```

Import `LIMITED_CERTAINTY_NOTE` from `..transparency_terms`.

- [ ] **Step 6: Run the report tests**

Run: `pytest tests/test_report_transparency_certainty.py tests/test_report_risk_helpers.py tests/test_reporting_agent_risk_warnings.py tests/test_methodology_total_bound.py tests/test_analysis_failure_reporting.py tests/test_an_undecodable_transparency_row.py tests/test_a_corrected_analyser_reaches_stored_rows.py -q`

Expected: all PASS. If an existing test asserted the old provisional wording ("Assessment is provisional"), update it to the shared caveat. If one asserted an exact annotation for a result with the default `full_text_analyzed=False`, set `full_text_analyzed=True` or expect the note line, whichever that test is about.

- [ ] **Step 7: Commit**

```bash
git add src/bmlibrarian_lite tests
git commit -m "feat(report): limited-certainty notes and a high-risk section (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 9: Swift binds the contract

**Files:**
- Modify: `Packages/BioMedLit/Tests/BioMedLitTests/Transparency/TransparencyParityTests.swift`
- Modify (only if a string differs): `Packages/BioMedLit/Sources/BioMedLit/Transparency/Models/TransparencyConstants.swift` or `Analysis/TransparencyRiskExplanation.swift`

**Interfaces:**
- Consumes: `risk_explanation_strings.json` (Task 1); `TransparencyParityTests.decodeFixture(_:)` (existing, line ~226); `TransparencyResultBuilder`, `TransparencyRiskExplanation(result:)`, `HighRiskTransparencySection` and `TransparencyConstants`.

- [ ] **Step 1: Write the tests**

Add to `TransparencyParityTests`:

```swift
    /// How a rating is qualified and a high rating explained (#386);
    /// binds Python, Swift and Kotlin.
    private static let riskExplanationFixture = "risk_explanation_strings.json"

    private struct RiskExplanationContract: Decodable {
        struct Strings: Decodable {
            let limitedCertaintyNote, limitedCertaintyBadgeSuffix, provisionalResultCaveat,
                unexplainedRatingCaveat, sectionHeading, reasonsLabel, scoreBreakdownLabel,
                otherConcernsLabel, caveatsLabel: String
            enum CodingKeys: String, CodingKey {
                case limitedCertaintyNote = "limited_certainty_note"
                case limitedCertaintyBadgeSuffix = "limited_certainty_badge_suffix"
                case provisionalResultCaveat = "provisional_result_caveat"
                case unexplainedRatingCaveat = "unexplained_rating_caveat"
                case sectionHeading = "section_heading"
                case reasonsLabel = "reasons_label"
                case scoreBreakdownLabel = "score_breakdown_label"
                case otherConcernsLabel = "other_concerns_label"
                case caveatsLabel = "caveats_label"
            }
        }
        struct Introduction: Decodable { let count: Int; let text: String }
        struct AppOnly: Decodable {
            let unrecordedCertaintyNote, unassessedLabel, unassessedNote: String
            enum CodingKeys: String, CodingKey {
                case unrecordedCertaintyNote = "unrecorded_certainty_note"
                case unassessedLabel = "unassessed_label"
                case unassessedNote = "unassessed_note"
            }
        }
        struct Findings: Decodable {
            let dataAvailability, coi, results: String
            let industryFunding, trialRegistered, outcomeSwitching, sourcesUnreachable: Bool
            let industryConfidence: Double
            enum CodingKeys: String, CodingKey {
                case dataAvailability = "data_availability", coi, results
                case industryFunding = "industry_funding", trialRegistered = "trial_registered"
                case outcomeSwitching = "outcome_switching", sourcesUnreachable = "sources_unreachable"
                case industryConfidence = "industry_confidence"
            }
        }
        struct Expected: Decodable {
            let score: Int
            let riskLevel: String
            let reasons, scoreBreakdown, caveats: [String]
            enum CodingKeys: String, CodingKey {
                case score, reasons, caveats
                case riskLevel = "risk_level", scoreBreakdown = "score_breakdown"
            }
        }
        struct Case: Decodable {
            let name: String
            let findings: Findings
            let storedRiskLevel: String?
            let expected: Expected
            enum CodingKeys: String, CodingKey {
                case name, findings, expected
                case storedRiskLevel = "stored_risk_level"
            }
        }
        let strings: Strings
        let introductionExamples: [Introduction]
        let swiftKotlinOnly: AppOnly
        let cases: [Case]
        enum CodingKeys: String, CodingKey {
            case strings, cases
            case introductionExamples = "introduction_examples"
            case swiftKotlinOnly = "swift_kotlin_only"
        }
    }

    func testRiskExplanationStringsMatchTheContract() throws {
        let contract: RiskExplanationContract = try Self.decodeFixture(Self.riskExplanationFixture)
        let s = contract.strings
        XCTAssertEqual(TransparencyConstants.limitedCertaintyNote, s.limitedCertaintyNote)
        XCTAssertEqual(TransparencyConstants.limitedCertaintyBadgeSuffix, s.limitedCertaintyBadgeSuffix)
        XCTAssertEqual(TransparencyConstants.provisionalResultCaveat, s.provisionalResultCaveat)
        XCTAssertEqual(HighRiskTransparencySection.heading, s.sectionHeading)
        XCTAssertEqual(HighRiskTransparencySection.reasonsLabel, s.reasonsLabel)
        XCTAssertEqual(HighRiskTransparencySection.scoreBreakdownLabel, s.scoreBreakdownLabel)
        XCTAssertEqual(HighRiskTransparencySection.otherConcernsLabel, s.otherConcernsLabel)
        XCTAssertEqual(HighRiskTransparencySection.caveatsLabel, s.caveatsLabel)
        for example in contract.introductionExamples {
            XCTAssertEqual(HighRiskTransparencySection.introduction(count: example.count), example.text)
        }
        XCTAssertEqual(TransparencyConstants.unrecordedCertaintyNote, contract.swiftKotlinOnly.unrecordedCertaintyNote)
        XCTAssertEqual(TransparencyConstants.unassessedLabel, contract.swiftKotlinOnly.unassessedLabel)
        XCTAssertEqual(TransparencyConstants.unassessedNote, contract.swiftKotlinOnly.unassessedNote)
    }

    func testRiskExplanationCasesMatchTheContract() throws {
        let contract: RiskExplanationContract = try Self.decodeFixture(Self.riskExplanationFixture)
        XCTAssertFalse(contract.cases.isEmpty)
        for c in contract.cases {
            let result = riskExplanationResult(for: c)
            let explanation = TransparencyRiskExplanation(result: result)
            XCTAssertEqual(result.transparencyScore, c.expected.score, c.name)
            XCTAssertEqual(result.riskLevel.rawValue, c.expected.riskLevel, c.name)
            XCTAssertEqual(explanation.reasons, c.expected.reasons, c.name)
            XCTAssertEqual(
                explanation.scoreBreakdown.map { "\($0.label): \($0.signedPoints)" },
                c.expected.scoreBreakdown, c.name
            )
            XCTAssertEqual(explanation.caveats, c.expected.caveats, c.name)
        }
    }

    private func riskExplanationResult(for c: RiskExplanationContract.Case) -> TransparencyResult {
        let f = c.findings
        let level: DataDisclosureLevel
        switch f.dataAvailability {
        case "full_open": level = .fullOpen
        case "on_request": level = .availableOnRequest
        case "restricted": level = .restricted
        case "not_available": level = .notAvailable
        case "not_stated": level = .notStated
        default: level = .unknown
        }
        let compliance: ResultsComplianceStatus
        switch f.results {
        case "compliant": compliance = .compliant
        case "missing": compliance = .missing
        default: compliance = .unknown
        }
        var builder = TransparencyResultBuilder(doi: "10.1000/test", pmid: "123")
        builder.coiAnalysis = f.coi == "disclosed"
            ? COIAnalysisResult(statement: "The authors declare no competing interests.")
            : .notAvailable
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel: level)
        builder.industryFundingDetected = f.industryFunding
        builder.industryFundingConfidence = f.industryConfidence
        if f.trialRegistered {
            builder.trialRegistrations = [TrialRegistration(
                registry: TransparencyConstants.clinicalTrialsRegistryName,
                registrationId: "NCT00000001",
                resultsPosted: f.results == "compliant"
            )]
        }
        builder.resultsCompliance = compliance
        builder.outcomeSwitchingDetected = f.outcomeSwitching
        builder.sourcesUnreachable = f.sourcesUnreachable
        builder.fullTextSearched = true
        builder.dataSourcesUsed = [TransparencyConstants.pubMedSourceName, TransparencyConstants.crossRefSourceName]
        let built = builder.build()
        guard let stored = c.storedRiskLevel, let level = TransparencyRiskLevel(rawValue: stored) else {
            return built
        }
        return TransparencyResult(
            coiAnalysis: built.coiAnalysis,
            dataAvailability: built.dataAvailability,
            transparencyScore: built.transparencyScore,
            riskLevel: level,
            dataSourcesUsed: built.dataSourcesUsed,
            fullTextSearched: true
        )
    }
```

If the builder has no `outcomeSwitchingDetected` or `sourcesUnreachable` property, set them as `TransparencySourcesUnreachableTests` / `TransparencyScorer` tests do. If `TransparencyRiskLevel`'s raw values are not `"low"`/`"medium"`/`"high"`, map them with a switch as for the data level. Do not change sources to make the test compile.

- [ ] **Step 2: Type-check, then run**

Run: `cd Packages/BioMedLit && swift build --build-tests 2>&1 | tail -20` (if this hangs, see the swift-build-lock memory: check for a second `swift-build` process first)
Then: `swift test --filter TransparencyParityTests 2>&1 | tail -30`
Expected: PASS. If a string or case differs, that is drift. Decide which side is right against the spec: the contract is Swift's strings, so a difference is most likely in the fixture. Fix it there and re-run Python's contract test too. Change a Swift source only if Swift is the one that is wrong, and say so in the commit.

- [ ] **Step 3: Run the whole package**

Run: `swift test 2>&1 | tail -5`
Expected: `Executed N tests, with 0 failures`.

- [ ] **Step 4: Commit**

```bash
git add Packages/BioMedLit
git commit -m "test(swift): bind the risk-explanation contract (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 10: Kotlin binds the contract

**Files:**
- Create: `android/MedicalFactChecker/app/src/test/java/com/bmlibrarian/factchecker/domain/transparency/RiskExplanationParityTest.kt`

**Interfaces:**
- Consumes: `ParityFixtures.json` and `ParityFixtures.read(name)`; `TransparencyResultBuilder`, `TransparencyRiskExplanation.of(result)`, `HighRiskTransparencySection` and `TransparencyConstants`.

- [ ] **Step 1: Write the test**

```kotlin
package com.bmlibrarian.factchecker.domain.transparency

import kotlinx.serialization.SerialName
import kotlinx.serialization.Serializable
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

/**
 * Binds Android to the risk-explanation contract, `risk_explanation_strings.json` (#386), as
 * `TransparencyParityTests` binds Swift and `tests/test_risk_explanation_contract.py` binds
 * Python. Strings are asserted string-for-string; each case is scored, rated and explained by
 * Kotlin's own code.
 */
class RiskExplanationParityTest {

    @Serializable
    private data class Strings(
        @SerialName("limited_certainty_note") val limitedCertaintyNote: String,
        @SerialName("limited_certainty_badge_suffix") val limitedCertaintyBadgeSuffix: String,
        @SerialName("provisional_result_caveat") val provisionalResultCaveat: String,
        @SerialName("unexplained_rating_caveat") val unexplainedRatingCaveat: String,
        @SerialName("section_heading") val sectionHeading: String,
        @SerialName("reasons_label") val reasonsLabel: String,
        @SerialName("score_breakdown_label") val scoreBreakdownLabel: String,
        @SerialName("other_concerns_label") val otherConcernsLabel: String,
        @SerialName("caveats_label") val caveatsLabel: String,
    )

    @Serializable
    private data class Introduction(val count: Int, val text: String)

    @Serializable
    private data class AppOnly(
        @SerialName("unrecorded_certainty_note") val unrecordedCertaintyNote: String,
        @SerialName("unassessed_label") val unassessedLabel: String,
        @SerialName("unassessed_note") val unassessedNote: String,
    )

    @Serializable
    private data class Findings(
        @SerialName("data_availability") val dataAvailability: String,
        val coi: String,
        @SerialName("industry_funding") val industryFunding: Boolean,
        @SerialName("industry_confidence") val industryConfidence: Double,
        @SerialName("trial_registered") val trialRegistered: Boolean,
        val results: String,
        @SerialName("outcome_switching") val outcomeSwitching: Boolean,
        @SerialName("sources_unreachable") val sourcesUnreachable: Boolean,
    )

    @Serializable
    private data class Expected(
        val score: Int,
        @SerialName("risk_level") val riskLevel: String,
        val reasons: List<String>,
        @SerialName("score_breakdown") val scoreBreakdown: List<String>,
        val caveats: List<String>,
    )

    @Serializable
    private data class Case(
        val name: String,
        val findings: Findings,
        @SerialName("stored_risk_level") val storedRiskLevel: String? = null,
        val expected: Expected,
    )

    @Serializable
    private data class Contract(
        val strings: Strings,
        @SerialName("introduction_examples") val introductionExamples: List<Introduction>,
        @SerialName("swift_kotlin_only") val swiftKotlinOnly: AppOnly,
        val cases: List<Case>,
    )

    private val contract: Contract =
        ParityFixtures.json.decodeFromString(Contract.serializer(), ParityFixtures.read("risk_explanation_strings.json"))

    @Test
    fun `strings match the shared contract`() {
        val s = contract.strings
        assertEquals(s.limitedCertaintyNote, TransparencyConstants.LIMITED_CERTAINTY_NOTE)
        assertEquals(s.limitedCertaintyBadgeSuffix, TransparencyConstants.LIMITED_CERTAINTY_BADGE_SUFFIX)
        assertEquals(s.provisionalResultCaveat, TransparencyConstants.PROVISIONAL_RESULT_CAVEAT)
        assertEquals(s.unexplainedRatingCaveat, TransparencyRiskExplanation.UNEXPLAINED_RATING_CAVEAT)
        assertEquals(s.sectionHeading, HighRiskTransparencySection.HEADING)
        assertEquals(s.reasonsLabel, HighRiskTransparencySection.REASONS_LABEL)
        assertEquals(s.scoreBreakdownLabel, HighRiskTransparencySection.SCORE_BREAKDOWN_LABEL)
        assertEquals(s.otherConcernsLabel, HighRiskTransparencySection.OTHER_CONCERNS_LABEL)
        assertEquals(s.caveatsLabel, HighRiskTransparencySection.CAVEATS_LABEL)
        for (example in contract.introductionExamples) {
            assertEquals(example.text, HighRiskTransparencySection.introduction(example.count))
        }
        assertEquals(contract.swiftKotlinOnly.unrecordedCertaintyNote, TransparencyConstants.UNRECORDED_CERTAINTY_NOTE)
    }

    @Test
    fun `every case is explained as the contract says`() {
        assertFalse("risk-explanation cases are empty", contract.cases.isEmpty())
        for (case in contract.cases) {
            val result = resultFor(case)
            val explanation = TransparencyRiskExplanation.of(result)
            assertEquals(case.name, case.expected.score, result.transparencyScore)
            assertEquals(case.name, case.expected.riskLevel, result.riskLevel.name.lowercase())
            assertEquals(case.name, case.expected.reasons, explanation.reasons)
            assertEquals(
                case.name,
                case.expected.scoreBreakdown,
                explanation.scoreBreakdown.map { "${it.label}: ${it.signedPoints}" },
            )
            assertEquals(case.name, case.expected.caveats, explanation.caveats)
        }
    }

    private fun resultFor(case: Case): TransparencyResult {
        val f = case.findings
        val level = when (f.dataAvailability) {
            "full_open" -> DataDisclosureLevel.FULL_OPEN
            "on_request" -> DataDisclosureLevel.AVAILABLE_ON_REQUEST
            "restricted" -> DataDisclosureLevel.RESTRICTED
            "not_available" -> DataDisclosureLevel.NOT_AVAILABLE
            "not_stated" -> DataDisclosureLevel.NOT_STATED
            else -> DataDisclosureLevel.UNKNOWN
        }
        val builder = TransparencyResultBuilder(doi = "10.1000/test", pmid = "123")
        builder.coiAnalysis = if (f.coi == "disclosed") {
            COIAnalysisResult(statement = "The authors declare no competing interests.")
        } else {
            COIAnalysisResult.NOT_AVAILABLE
        }
        builder.dataAvailability = DataAvailabilityResult(disclosureLevel = level)
        builder.industryFundingDetected = f.industryFunding
        builder.industryFundingConfidence = f.industryConfidence
        if (f.trialRegistered) {
            builder.trialRegistrations = listOf(
                TrialRegistration(
                    registry = TransparencyConstants.CLINICAL_TRIALS_REGISTRY_NAME,
                    registrationId = "NCT00000001",
                    resultsPosted = f.results == "compliant",
                ),
            )
        }
        builder.resultsCompliance = when (f.results) {
            "compliant" -> ResultsComplianceStatus.COMPLIANT
            "missing" -> ResultsComplianceStatus.MISSING
            else -> ResultsComplianceStatus.UNKNOWN
        }
        builder.outcomeSwitchingDetected = f.outcomeSwitching
        builder.sourcesUnreachable = f.sourcesUnreachable
        builder.fullTextSearched = true
        builder.dataSourcesUsed = listOf(TransparencyConstants.PUBMED_SOURCE_NAME, TransparencyConstants.CROSSREF_SOURCE_NAME)
        val built = builder.build()
        val stored = case.storedRiskLevel ?: return built
        return built.copy(riskLevel = TransparencyRiskLevel.valueOf(stored.uppercase()))
    }
}
```

If a builder property or the `copy` signature differs, adapt the test to Kotlin's actual API (read `TransparencyResult.kt` / `TransparencyResultBuilder`). Do not change main sources to fit the test.

- [ ] **Step 2: Run it**

Run: `cd android/MedicalFactChecker && ./gradlew test --tests '*RiskExplanationParityTest*' 2>&1 | tail -20`
Expected: PASS. Handle drift as in Task 9, Step 2.

- [ ] **Step 3: Run the whole suite**

Run: `./gradlew test 2>&1 | tail -5`
Expected: `BUILD SUCCESSFUL`.

- [ ] **Step 4: Commit**

```bash
git add android/MedicalFactChecker/app/src/test
git commit -m "test(android): bind the risk-explanation contract (#386)

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: Documentation, gates, handover, PR

**Files:**
- Modify: `doc/cross_platform/transparency_parity/README.md`
- Modify: `HANDOVER.md`

- [ ] **Step 1: README**

Add a section for `risk_explanation_strings.json`. It should cover:
- what the file binds (`strings`: all three platforms; `swift_kotlin_only`: the two apps; `cases`: behavioural, all three);
- which test binds each platform;
- a paragraph titled "Why the desktop has no Unassessed rule". Python records COI `not_stated` only from a full text it read and segmented, and data `not_stated` only from a read full text or Europe PMC XML with sections (#352, #353, #359). So no desktop High rests on text nobody searched. `tests/test_no_high_rests_on_unread_text.py` pins this. If it ever fails, the desktop needs the Unassessed rule and the "not searched" wording after all.

- [ ] **Step 2: Full gates**

```bash
pytest tests/ -q 2>&1 | tail -5
python .github/scripts/lint_delta.py --base-ref origin/master
(cd Packages/BioMedLit && swift test 2>&1 | tail -3)
(cd android/MedicalFactChecker && ./gradlew test 2>&1 | tail -3)
```

Expected:
- pytest: 0 failures.
- `lint_delta.py`: no new ruff/mypy findings.
- `swift test`: 0 failures.
- `gradlew test`: `BUILD SUCCESSFUL`.

No iOS/macOS app source changed, so neither `xcodebuild` nor the app's `swift test` is required. Confirm with `git diff --stat origin/master -- ios/`, which should be empty.

- [ ] **Step 3: HANDOVER**

Move #386 into "In flight", with the PR number once it is known. List what landed. Record the lodged or deferred items:
- #411's remaining Python items: the batch CSV `sources_unreachable` column, and `industry_funding_percent` over unread CrossRef.
- The Swift "ratings made" vs Android "ratings were made" summary drift, lodged as an issue.
- Swift's no-CrossRef caveat has no desktop counterpart; add a note to #391.

In "Potential follow-ups", remove the #386 bullet. Keep the file under 500 lines.

- [ ] **Step 4: Lodge the follow-ups**

```bash
gh issue create --title "Swift and Android word the limited-certainty summary differently" --body "..."
gh issue comment 391 --body "The desktop (PR for #386) has no counterpart to Swift's 'No CrossRef record was retrieved' caveat: its stored row does not record which sources answered. ..."
```

Write the bodies in full, stating file:line for each platform.

- [ ] **Step 5: Commit, push, PR**

```bash
git add -A doc docs HANDOVER.md
git commit -m "docs: risk-explanation contract, handover for #386

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
git push -u origin feat/desktop-transparency-certainty-386
gh pr create --base master --title "Desktop: transparency certainty and high-risk explanation (#386)" --body "..."
```

The PR body:
- starts with `Closes #386.`;
- summarises the design decisions (no Unassessed rule, and why; stored components; a shared contract);
- lists the surfaces changed;
- names deferred items with "Deferred: #411 (batch CSV), #391 (no-CrossRef caveat)", never with a closing keyword;
- ends with `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.
