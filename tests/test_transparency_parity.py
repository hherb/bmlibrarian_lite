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
from collections import Counter
from pathlib import Path
from typing import Any, cast

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ACADEMIC_PATTERNS,
    DATA_REPOSITORIES,
    GOVERNMENT_PATTERNS,
    NEGATED_OPENNESS_PATTERNS,
    NON_INDUSTRY_PATTERNS,
    RESTRICTION_LABELS,
    STRONG_REFUSAL_PATTERNS,
    DataDisclosureLevel,
    analyze_data_availability,
    classify_funder_name,
)

PARITY_FIXTURE_DIR = (
    Path(__file__).resolve().parents[1] / "doc" / "cross_platform" / "transparency_parity"
)

#: Pattern/label contract, asserted string-for-string.
PATTERNS_FIXTURE = "data_availability_patterns.json"

#: Worked ``statement -> (level, restrictions)`` cases, asserted behaviourally.
CASES_FIXTURE = "data_availability_cases.json"

#: Government/academic sponsor-pattern contract, asserted string-for-string.
#: Binds Python and Swift only — Android carries no funder classifier.
SPONSOR_PATTERNS_FIXTURE = "sponsor_patterns.json"

#: Hand-labelled funder names, a *measurement* corpus rather than a pattern
#: contract. Scored by ``tests/test_funder_classification.py``; the class at the
#: bottom of this file checks the corpus itself.
FUNDER_CORPUS_FIXTURE = "funder_names.json"


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


class TestSponsorPatternManifestParity:
    """Python's sponsor lists must equal the shared contract string-for-string.

    #147 split one 25-element list into a government half and an academic half to
    match Swift, and several places assert in prose that the two platforms are
    byte-identical. Prose is not enforcement: before this fixture existed,
    either platform could edit its list and both suites stayed green. The lists
    decide the sponsor tier *and*, concatenated, the industry boundary that
    ``funder_names.json`` measures, so drift is expensive in both directions.
    """

    @pytest.fixture(scope="class")
    def sponsor_patterns(self) -> dict[str, list[str]]:
        """The sponsor-pattern lists from the shared contract."""
        manifest = _load_fixture(SPONSOR_PATTERNS_FIXTURE)
        return cast(dict[str, list[str]], manifest["patterns"])

    def test_government_patterns_match_manifest(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        """The public bodies, whose half wins outright over the academic one."""
        assert GOVERNMENT_PATTERNS == sponsor_patterns["government"]

    def test_academic_patterns_match_manifest(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        """The institutional funders, reached only when no government pattern hit."""
        assert ACADEMIC_PATTERNS == sponsor_patterns["academic"]

    def test_the_non_industry_union_is_the_manifest_halves_in_order(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        """Concatenation order is the order ``classify_funder_name`` matches in."""
        assert NON_INDUSTRY_PATTERNS == (
            sponsor_patterns["government"] + sponsor_patterns["academic"]
        )

    def test_the_manifest_halves_are_disjoint(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        """A pattern in both halves would make the academic tier unreachable for it."""
        assert set(sponsor_patterns["government"]) & set(sponsor_patterns["academic"]) == set()

    def test_every_manifest_sponsor_pattern_compiles(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        """An invalid pattern must fail here, not at classification time."""
        for half in ("government", "academic"):
            for pattern in sponsor_patterns[half]:
                re.compile(pattern)

    def test_every_manifest_sponsor_pattern_is_exercised(
        self, sponsor_patterns: dict[str, list[str]]
    ) -> None:
        r"""Every pattern matches at least one probe name from the contract.

        The string-for-string assertions above catch the platforms drifting
        apart. They cannot catch a pattern that never matched anything on any
        platform — a typo transcribed faithfully into all three copies agrees
        with itself perfectly. ``\bniaid\b``, ``\bnhlbi\b`` and ``\bnimh\b``
        were in exactly that state: pinned, and behaviourally untested
        everywhere.
        """
        probes = [name.lower() for name in _load_fixture(SPONSOR_PATTERNS_FIXTURE)["pattern_probes"]]
        unexercised = sorted(
            {
                pattern
                for patterns in sponsor_patterns.values()
                for pattern in patterns
                if not any(re.search(pattern, probe) for probe in probes)
            }
        )
        assert unexercised == [], "contract patterns with no covering probe:\n  " + "\n  ".join(
            unexercised
        )

    def test_every_sponsor_pattern_probe_is_non_industry(self) -> None:
        """A probe that classified as industry would not be exercising its half.

        Both halves exist to mean "not industry", so a probe name reaching the
        industry layer would satisfy the coverage test above while proving
        nothing about the pattern it was chosen for.
        """
        for name in _load_fixture(SPONSOR_PATTERNS_FIXTURE)["pattern_probes"]:
            is_industry, _ = classify_funder_name(name)
            assert not is_industry, f"{name!r} classified as industry"


class TestFunderConfidenceParity:
    """The confidence each classification layer reports (#152).

    Asserted **behaviourally** — classify a representative funder and compare the
    confidence — rather than by reading constants. Swift's are `private`, so a
    constant comparison is not available there, and behaviour is what reaches a
    user in any case.

    Python reported a flat 0.8 for both non-industry halves until #152, where
    Swift had always reported 0.85 for a government match and 0.80 for an
    academic one. The funder corpus scores the ``is_industry`` boolean, which
    agreed throughout, so nothing caught it.
    """

    @pytest.fixture(scope="class")
    def contract(self) -> dict[str, Any]:
        """The sponsor/confidence contract."""
        return _load_fixture(SPONSOR_PATTERNS_FIXTURE)

    def test_every_probe_reports_the_contract_confidence(
        self, contract: dict[str, Any]
    ) -> None:
        """Each layer's representative funder must classify as the contract says."""
        confidences = cast(dict[str, float], contract["confidences"])
        for probe in cast(list[dict[str, Any]], contract["confidence_probes"]):
            is_industry, confidence = classify_funder_name(probe["name"], probe["doi"])
            assert is_industry == probe["is_industry"], (
                f"{probe['name']!r} ({probe['layer']}) classified as "
                f"is_industry={is_industry}"
            )
            assert confidence == confidences[probe["layer"]], (
                f"{probe['name']!r} reported {confidence}, contract says "
                f"{confidences[probe['layer']]} for layer {probe['layer']!r}"
            )

    def test_every_layer_has_a_probe(self, contract: dict[str, Any]) -> None:
        """A confidence nothing exercises is a value no test can defend."""
        probed = {probe["layer"] for probe in contract["confidence_probes"]}
        assert probed == set(contract["confidences"])

    def test_the_ladder_is_strictly_descending(self, contract: dict[str, Any]) -> None:
        """A registry DOI outranks a named agency, which outranks a generic word.

        Order is the part that carries meaning: the absolute values are a
        calibration choice, but two layers reporting the same confidence would
        make them indistinguishable to a caller ranking funders by it — which is
        exactly the state #152 fixed.
        """
        ladder = [
            "known_industry_doi",
            "government_pattern",
            "academic_pattern",
            "industry_name",
            "unknown",
        ]
        values = [contract["confidences"][layer] for layer in ladder]
        assert values == sorted(values, reverse=True)
        assert len(set(values)) == len(values), f"two layers share a confidence: {values}"


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


class TestFunderCorpusContract:
    """The third shared fixture: the labelled funder-name corpus (#143).

    Unlike the two data-availability fixtures, ``funder_names.json`` does not pin
    strings — it pins *measured quality*, and the measurement lives in
    ``tests/test_funder_classification.py`` (Python) and
    ``FunderClassificationTests`` / ``FunderCorpusCompositionTests`` (Swift).

    What belongs here is the corpus itself. Every precision, recall and
    composition figure on both platforms is a fraction of these counts, so a
    silent edit to the file moves every published figure at once while both
    suites stay green — they would simply be measuring something else. The corpus
    is also lifted byte-identical from bmlib, so a change here means the two
    repositories have drifted.

    Until #143 this file was the one fixture in the parity directory that no
    Python test read at all.
    """

    #: The three labels the corpus uses. ``ambiguous`` names are genuinely
    #: undecidable from the string alone and are excluded from the metrics, kept
    #: with a reason rather than dropped.
    EXPECTED_LABELS = {"industry", "not_industry", "ambiguous"}

    #: Which API the name was sampled from. ``both`` means it appeared in the
    #: CrossRef and the PubMed sample.
    EXPECTED_SOURCES = {"crossref", "pubmed", "both"}

    #: Pinned composition of the labelled subset.
    EXPECTED_TOTAL = 417
    EXPECTED_INDUSTRY = 30
    EXPECTED_NOT_INDUSTRY = 382
    EXPECTED_AMBIGUOUS = 5

    @staticmethod
    def _entries() -> list[dict[str, Any]]:
        """The labelled entries from the shared funder corpus."""
        return cast(list[dict[str, Any]], _load_fixture(FUNDER_CORPUS_FIXTURE)["entries"])

    def test_the_labelled_corpus_is_unchanged(self) -> None:
        """Every figure both platforms publish is a fraction of these counts."""
        entries = self._entries()
        counts = Counter(entry["label"] for entry in entries)

        assert len(entries) == self.EXPECTED_TOTAL
        assert counts["industry"] == self.EXPECTED_INDUSTRY
        assert counts["not_industry"] == self.EXPECTED_NOT_INDUSTRY
        assert counts["ambiguous"] == self.EXPECTED_AMBIGUOUS

    def test_every_entry_carries_a_known_label(self) -> None:
        """An unknown label would be scored as ``not_industry`` by both platforms.

        Both suites test ``label == "industry"``, so a typo silently relabels the
        entry rather than failing, and precision moves with no visible cause.
        """
        assert {entry["label"] for entry in self._entries()} <= self.EXPECTED_LABELS

    def test_every_entry_carries_a_known_source(self) -> None:
        """The source records which API returns the name, and so which path it tests."""
        assert {entry["source"] for entry in self._entries()} <= self.EXPECTED_SOURCES

    def test_every_ambiguous_entry_carries_a_reason(self) -> None:
        """Ambiguity is excluded from the metrics, so it must be argued rather than assumed.

        Without the reason, an unlabelled name and a deliberately undecidable one
        are indistinguishable, and dropping a hard case would look like curation.
        """
        unreasoned = [
            entry["name"]
            for entry in self._entries()
            if entry["label"] == "ambiguous" and not entry.get("reason", "").strip()
        ]
        assert unreasoned == []

    def test_only_ambiguous_entries_carry_a_reason(self) -> None:
        """A reason on a decided entry reads as doubt the metrics do not act on."""
        misplaced = [
            entry["name"]
            for entry in self._entries()
            if entry["label"] != "ambiguous" and entry.get("reason")
        ]
        assert misplaced == []

    def test_every_name_appears_once(self) -> None:
        """A duplicated name would be weighted twice in precision and recall.

        The composition tests on both platforms compare *sets*, so a duplicate is
        invisible there while it moves every ratio.
        """
        names = [entry["name"] for entry in self._entries()]
        duplicated = sorted({name for name in names if names.count(name) > 1})
        assert duplicated == []

    def test_the_sampled_totals_are_internally_consistent(self) -> None:
        """The two samples overlap, so the unique total must sit between them and their sum.

        The header records 431 CrossRef and 402 PubMed names de-duplicated to 816
        unique. An edit that changes one number without the others would leave the
        provenance describing a corpus that cannot exist.
        """
        sampled = _load_fixture(FUNDER_CORPUS_FIXTURE)["sampled"]
        crossref, pubmed = sampled["crossref"], sampled["pubmed"]
        overlap = crossref + pubmed - sampled["unique_total"]

        assert 0 <= overlap <= min(crossref, pubmed)

    def test_the_labelled_subset_fits_inside_the_sample(self) -> None:
        """Not every sampled name is labelled, but no labelled name is unsampled."""
        sampled = _load_fixture(FUNDER_CORPUS_FIXTURE)["sampled"]

        assert len(self._entries()) <= sampled["unique_total"]
