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

"""Cross-platform parity drift guard for the data-availability classifier (#105).

Python, Swift (``Packages/BioMedLit``) and Kotlin (``android/…/domain/transparency``)
each carry their own transcription of the same pattern lists and restriction
labels. Before this guard existed, parity was maintained by convention: each
platform asserted only its *own* literals, so an edit to one language could
silently diverge from the other two.

The contract now lives in two language-neutral fixtures under
``doc/cross_platform/transparency_parity/``:

* ``data_availability_patterns.json`` — the pattern lists and label map, asserted
  string-for-string. Catches an edit to one platform immediately and points at
  the exact pattern.
* ``data_availability_cases.json`` — worked ``statement -> (level, restrictions)``
  cases, asserted behaviourally. Catches divergence a string comparison cannot
  see: a regex-engine difference, a tier-ordering change, or a pattern that is
  spelled identically but compiled with different flags.

All three platforms load the same two files. See the sibling ``README.md``.
"""

import json
import re
from pathlib import Path
from typing import Any, cast

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    DATA_REPOSITORIES,
    NEGATED_OPENNESS_PATTERNS,
    RESTRICTION_LABELS,
    STRONG_REFUSAL_PATTERNS,
    DataDisclosureLevel,
    analyze_data_availability,
)

PARITY_FIXTURE_DIR = (
    Path(__file__).resolve().parents[1] / "doc" / "cross_platform" / "transparency_parity"
)

#: Pattern/label contract, asserted string-for-string.
PATTERNS_FIXTURE = "data_availability_patterns.json"

#: Worked ``statement -> (level, restrictions)`` cases, asserted behaviourally.
CASES_FIXTURE = "data_availability_cases.json"


def _load_fixture(filename: str) -> dict[str, Any]:
    """Load a parity fixture by name.

    Args:
        filename: File name within the shared parity fixture directory.

    Returns:
        The parsed JSON object.
    """
    path = PARITY_FIXTURE_DIR / filename
    assert path.is_file(), f"missing shared parity fixture: {path}"
    return cast(dict[str, Any], json.loads(path.read_text(encoding="utf-8")))


@pytest.fixture(scope="module")
def manifest() -> dict[str, Any]:
    """The shared pattern/label contract."""
    return _load_fixture(PATTERNS_FIXTURE)


@pytest.fixture(scope="module")
def manifest_patterns(manifest: dict[str, Any]) -> dict[str, list[str]]:
    """The pattern lists from the shared contract."""
    return cast(dict[str, list[str]], manifest["patterns"])


class TestPatternManifestParity:
    """Python's constants must equal the shared contract string-for-string."""

    def test_full_open_patterns_match_manifest(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The repository names and #113 open-availability affirmations."""
        assert DATA_REPOSITORIES["full_open"] == manifest_patterns["full_open"]

    def test_negated_openness_patterns_match_manifest(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The #117/#125 negated open-availability affirmations."""
        assert NEGATED_OPENNESS_PATTERNS == manifest_patterns["negated_openness"]

    def test_restricted_patterns_match_manifest(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The restricted tier, whose order fixes the restriction label order."""
        assert DATA_REPOSITORIES["restricted"] == manifest_patterns["restricted"]

    def test_strong_refusal_patterns_match_manifest(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The refusals that escalate a statement to NOT_AVAILABLE."""
        assert STRONG_REFUSAL_PATTERNS == manifest_patterns["strong_refusal"]

    def test_effectively_unavailable_patterns_match_manifest(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The policy-shaped statements that amount to a refusal."""
        assert (
            DATA_REPOSITORIES["effectively_unavailable"]
            == manifest_patterns["effectively_unavailable"]
        )

    def test_restriction_labels_match_manifest(self, manifest: dict[str, Any]) -> None:
        """The pattern-to-label map shown to the user."""
        expected = {entry["pattern"]: entry["label"] for entry in manifest["restriction_labels"]}
        assert RESTRICTION_LABELS == expected

    def test_manifest_label_patterns_are_unique(self, manifest: dict[str, Any]) -> None:
        """A duplicated key would silently drop an entry on every platform."""
        patterns = [entry["pattern"] for entry in manifest["restriction_labels"]]
        assert len(patterns) == len(set(patterns))


class TestManifestSelfConsistency:
    """Structural invariants of the contract, independent of any one platform.

    These encode the traps documented in ``HANDOVER.md``, so a future edit to the
    shared fixture cannot reintroduce them on all three platforms at once.
    """

    def test_strong_refusal_is_a_subset_of_restricted(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """Escalation to NOT_AVAILABLE must not bypass the restricted tier's labels."""
        assert set(manifest_patterns["strong_refusal"]) <= set(manifest_patterns["restricted"])

    def test_negated_openness_is_appended_to_restricted(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """Pins the #117 tail, and with it Kotlin's declaration-order trap.

        ``negatedOpennessPatterns`` must be declared before ``restrictedPatterns``
        in the Kotlin object or the forward reference appends nothing. Requiring
        the patterns as an ordered *suffix* — not merely as members — makes that
        omission fail here as well as on Android.
        """
        negated = manifest_patterns["negated_openness"]
        assert manifest_patterns["restricted"][-len(negated) :] == negated

    def test_every_unavailability_signal_pattern_is_reachable_from_a_later_tier(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """The ``has_unavailability_signal`` invariant, as an executable check.

        Every pattern joined into the up-front unavailability probe suppresses
        Step 1 (full open). If such a pattern is not also reachable from Step 2
        (effectively-unavailable / strong-refusal) or Step 3 (restricted), a
        matching statement silently lands in UNKNOWN instead of FULL_OPEN.
        """
        probe = (
            manifest_patterns["effectively_unavailable"]
            + manifest_patterns["strong_refusal"]
            + manifest_patterns["negated_openness"]
        )
        reachable = set(manifest_patterns["effectively_unavailable"]) | set(
            manifest_patterns["restricted"]
        )
        assert set(probe) <= reachable

    def test_every_labelled_pattern_belongs_to_a_tier(
        self, manifest: dict[str, Any], manifest_patterns: dict[str, list[str]]
    ) -> None:
        """An orphaned label is dead weight that reads as live behaviour."""
        known = set(manifest_patterns["restricted"]) | set(
            manifest_patterns["effectively_unavailable"]
        )
        labelled = {entry["pattern"] for entry in manifest["restriction_labels"]}
        assert labelled <= known

    def test_every_restriction_tier_pattern_has_a_label(
        self, manifest: dict[str, Any], manifest_patterns: dict[str, list[str]]
    ) -> None:
        """An unlabelled pattern surfaces its raw regex to the user."""
        labelled = {entry["pattern"] for entry in manifest["restriction_labels"]}
        tiered = set(manifest_patterns["restricted"]) | set(
            manifest_patterns["effectively_unavailable"]
        )
        assert tiered <= labelled

    def test_every_manifest_pattern_compiles(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """An uncompilable pattern would raise at import time on every platform."""
        for tier, patterns in manifest_patterns.items():
            for pattern in patterns:
                try:
                    re.compile(pattern)
                except re.error as exc:  # pragma: no cover - only on a bad edit
                    pytest.fail(f"{tier} pattern does not compile: {pattern!r} ({exc})")


class TestBehaviouralCaseParity:
    """The worked cases must classify identically on every platform."""

    @pytest.mark.parametrize("case", _load_fixture(CASES_FIXTURE)["cases"])
    def test_case_classifies_as_specified(self, case: dict[str, Any]) -> None:
        """One worked statement classifies to the contracted level and labels."""
        info = analyze_data_availability(case["statement"])

        assert info.disclosure_level == DataDisclosureLevel(case["disclosure_level"]), (
            f"[{case['id']}] {case.get('why', '')}"
        )
        assert info.restrictions == case["restrictions"], f"[{case['id']}] {case.get('why', '')}"

    def test_every_case_id_is_unique(self) -> None:
        """Ids name the case in every platform's failure message, so they must be distinct."""
        cases = _load_fixture(CASES_FIXTURE)["cases"]
        ids = [case["id"] for case in cases]
        assert len(ids) == len(set(ids))

    def test_every_reachable_disclosure_level_is_exercised(self) -> None:
        """A tier with no case would drift unnoticed on the other platforms.

        ``AVAILABLE_ON_REQUEST`` is excluded deliberately: on-request phrasing maps
        to ``RESTRICTED``, so the classifier never emits it. It exists for scoring
        and externally-constructed results, and all three platforms agree on that.
        """
        cases = _load_fixture(CASES_FIXTURE)["cases"]
        covered = {case["disclosure_level"] for case in cases}
        reachable = {
            level.value
            for level in DataDisclosureLevel
            if level is not DataDisclosureLevel.AVAILABLE_ON_REQUEST
        }
        assert covered == reachable

    def test_every_restriction_label_is_exercised(self, manifest: dict[str, Any]) -> None:
        """Every label the classifier can emit is pinned by at least one case.

        Without this, a pattern could diverge across platforms in a way the
        string comparison catches but the behavioural fixture does not — leaving
        the behavioural half of the guard with a blind spot that grows silently
        every time a pattern is added.
        """
        cases = _load_fixture(CASES_FIXTURE)["cases"]
        emitted = {label for case in cases for label in case["restrictions"]}
        expected = {entry["label"] for entry in manifest["restriction_labels"]}
        assert expected - emitted == set()

    def test_every_contract_pattern_is_exercised(
        self, manifest_patterns: dict[str, list[str]]
    ) -> None:
        """Every pattern in every tier is matched by at least one case statement.

        Label coverage alone leaves a blind spot wherever patterns share a label:
        the four negated-openness patterns all emit "Data not openly available",
        so a case exercising any one of them satisfies a label-keyed guard while
        the other three stay behaviourally untested on all three platforms.
        Keying the guard on the pattern rather than the label closes that, and
        keeps it closed as patterns are added under existing labels.

        Matching mirrors the classifier: ``re.search`` against the lowercased
        statement.
        """
        statements = [
            (case["statement"] or "").lower()
            for case in _load_fixture(CASES_FIXTURE)["cases"]
        ]
        unexercised = sorted(
            {
                pattern
                for patterns in manifest_patterns.values()
                for pattern in patterns
                if not any(re.search(pattern, statement) for statement in statements)
            }
        )
        assert unexercised == [], "contract patterns with no covering case:\n  " + "\n  ".join(
            unexercised
        )
