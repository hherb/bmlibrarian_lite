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

"""Tests for StudyTransparencyAnalyzer risk indicator identification.

The indicator strings asserted here are the canonical cross-platform set,
mirrored by the Swift implementation in
``Packages/BioMedLit/Sources/BioMedLit/Transparency/Analysis/TransparencyScorer.swift``.
"""

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ConflictOfInterest,
    DataAvailabilityInfo,
    DataDisclosureLevel,
    ResultsComplianceStatus,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    TrialRegistration,
    analyze_data_availability,
    calculate_transparency_score,
)


@pytest.fixture
def analyzer() -> StudyTransparencyAnalyzer:
    """Create an analyzer without browser fallback (no network in __init__)."""
    return StudyTransparencyAnalyzer(
        email="test@example.com",
        use_browser_fallback=False,
        auto_discover_fulltext=False,
    )


class TestIdentifyRiskIndicators:
    """Tests for _identify_risk_indicators indicator generation."""

    def test_outcome_switching_indicator(self, analyzer) -> None:
        """Outcome switching flag produces its canonical indicator."""
        report = TransparencyReport(
            pmid="12345678",
            outcome_switching_detected=True,
        )

        analyzer._identify_risk_indicators(report)

        assert "Outcome switching detected" in report.risk_of_bias_indicators

    def test_no_outcome_switching_indicator_when_not_detected(self, analyzer) -> None:
        """No outcome switching indicator when the flag is False."""
        report = TransparencyReport(
            pmid="12345678",
            outcome_switching_detected=False,
        )

        analyzer._identify_risk_indicators(report)

        assert "Outcome switching detected" not in report.risk_of_bias_indicators

    def test_canonical_indicator_set(self, analyzer) -> None:
        """A high-risk report produces the canonical cross-platform strings."""
        report = TransparencyReport(
            pmid="12345678",
            industry_funding_detected=True,
            data_availability=DataAvailabilityInfo(
                statement="Data cannot be shared",
                disclosure_level=DataDisclosureLevel.NOT_AVAILABLE,
            ),
            results_compliance=ResultsComplianceStatus.MISSING,
            coi_info=ConflictOfInterest(statement="", has_industry_ties=False),
            outcome_switching_detected=True,
        )

        analyzer._identify_risk_indicators(report)

        indicators = report.risk_of_bias_indicators
        assert "Industry funding detected" in indicators
        assert "Industry-funded with restricted data access" in indicators
        assert "Trial results not posted to ClinicalTrials.gov" in indicators
        assert "Data effectively unavailable despite sharing statement" in indicators
        assert "Outcome switching detected" in indicators
        # Empty COI statement counts as missing (mirrored by
        # COIAnalysisResult.hasStatement on the Swift side)
        assert "No conflict of interest statement found" in indicators


class TestAnalyzeDataAvailability:
    """Reference tests for the data-availability classifier.

    These pin the canonical classification tiers mirrored by the Swift
    ``DataAvailabilityAnalyzer`` in
    ``Packages/BioMedLit/Sources/BioMedLit/Transparency/Analysis/DataAvailabilityAnalyzer.swift``.
    """

    def test_empty_statement_is_not_stated(self) -> None:
        """A nil/empty statement classifies as NOT_STATED."""
        assert (
            analyze_data_availability(None).disclosure_level
            == DataDisclosureLevel.NOT_STATED
        )
        assert (
            analyze_data_availability("").disclosure_level
            == DataDisclosureLevel.NOT_STATED
        )

    def test_public_repository_is_full_open(self) -> None:
        """A public repository deposit classifies as FULL_OPEN."""
        result = analyze_data_availability("Data deposited in Zenodo.")
        assert result.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_on_request_is_restricted(self) -> None:
        """On-request access classifies as RESTRICTED, never AVAILABLE_ON_REQUEST."""
        result = analyze_data_availability(
            "Data available upon reasonable request from the corresponding author."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions

    def test_ethics_committee_is_restricted(self) -> None:
        """Approval-gated access classifies as RESTRICTED."""
        result = analyze_data_availability(
            "Data access requires ethics committee approval."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED

    def test_strong_refusal_is_not_available(self) -> None:
        """A sharing statement amounting to a refusal escalates to NOT_AVAILABLE."""
        result = analyze_data_availability(
            "Individual patient data will not be released to others."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE
        assert result.restrictions

    def test_sponsor_confidentiality_is_not_available(self) -> None:
        """Sponsor confidentiality agreements escalate to NOT_AVAILABLE."""
        result = analyze_data_availability(
            "Confidentiality agreements with sponsors prevent data disclosure."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE

    def test_named_collaboration_lock_is_not_available(self) -> None:
        """Data locked to a named collaboration is effectively unavailable.

        Also pins the restriction ordering for a NOT_AVAILABLE result:
        effectively-unavailable labels first (in their pattern order),
        then restricted-pattern labels. The Swift
        ``DataAvailabilityAnalyzer`` mirrors this exact order.
        """
        result = analyze_data_availability(
            "Data are provided to the CORE consortium on the understanding "
            "that they are not shared."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE
        assert result.restrictions == [
            "Data restricted to named collaboration",
            "Data provided under restrictive understanding",
        ]

    def test_ambiguous_statement_is_unknown(self) -> None:
        """A statement matching no pattern classifies as UNKNOWN."""
        result = analyze_data_availability(
            "The study data is maintained by the research team."
        )
        assert result.disclosure_level == DataDisclosureLevel.UNKNOWN

    def test_geographic_word_does_not_trigger_full_open(self) -> None:
        """'geographic' must not match the bare 'geo' repository token.

        The short repository tokens (geo/ena/sra/pdb) are word-anchored so an
        unrelated word cannot produce a false FULL_OPEN that overrides a genuine
        restriction. The Swift ``DataAvailabilityAnalyzer`` mirrors this.
        """
        result = analyze_data_availability(
            "Geographic data underlying this study are not publicly available."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE

    def test_phenomena_word_does_not_trigger_full_open(self) -> None:
        """'phenomena' must not match the bare 'ena' repository token."""
        result = analyze_data_availability(
            "The phenomena studied are described; data available upon "
            "request from the corresponding author."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED

    def test_standalone_short_token_still_full_open(self) -> None:
        """A standalone short repository token still classifies as FULL_OPEN.

        Word-anchoring must not over-tighten: a genuine deposit named only by
        its short token (e.g. GEO, SRA) is still a public repository.
        """
        for token in ("GEO", "SRA", "ENA", "PDB"):
            result = analyze_data_availability(
                f"Raw data have been deposited in {token} under accession XYZ123."
            )
            assert (
                result.disclosure_level == DataDisclosureLevel.FULL_OPEN
            ), token

    @pytest.mark.parametrize("word", ["misranked", "compdb"])
    def test_short_token_embedded_in_word_is_not_full_open(self, word: str) -> None:
        """Short tokens embedded mid-word must not trigger FULL_OPEN.

        Complements the geographic/phenomena cases by exercising the two short
        tokens without common English-word collisions (sra/pdb). The carrier
        words are synthetic word-boundary probes: dropping the word-boundary
        anchors on the sra/pdb tokens would make these false-positive.
        """
        result = analyze_data_availability(
            f"The {word} results are summarized in the manuscript text."
        )
        assert result.disclosure_level != DataDisclosureLevel.FULL_OPEN

    def test_repository_named_but_access_refused_is_not_available(self) -> None:
        """A repository name is overridden by an explicit refusal.

        A repository *name* in a statement does not prove open access. When a
        strong-refusal signal co-occurs, it takes precedence over the
        repository mention. The Swift ``DataAvailabilityAnalyzer`` mirrors this.
        """
        result = analyze_data_availability(
            "Sequencing data could not be deposited in GEO for privacy reasons; "
            "the individual patient data cannot be shared."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE

    def test_repository_named_but_not_publicly_available_is_not_available(self) -> None:
        """'not publicly available' overrides a co-occurring repository name."""
        result = analyze_data_availability(
            "Although GenBank was used during analysis, the data are not "
            "publicly available."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE

    def test_repository_with_soft_request_stays_full_open(self) -> None:
        """Repository + a *soft* on-request restriction stays FULL_OPEN.

        This pins the deterministic baseline for the genuinely ambiguous case
        (public deposit plus "available upon request"): the heuristic keeps it
        FULL_OPEN. Optional LLM-assisted disambiguation is tracked in #109.
        """
        result = analyze_data_availability(
            "Processed data are available in GEO under accession GSE12345. "
            "Raw individual-level data are available from the corresponding "
            "author upon reasonable request."
        )
        assert result.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_gdpr_restriction_is_restricted(self) -> None:
        """A GDPR-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Individual patient data are restricted under GDPR."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["GDPR restrictions"]

    def test_hipaa_restriction_is_restricted(self) -> None:
        """A HIPAA-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Access to the dataset is limited by HIPAA."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["HIPAA restrictions"]

    def test_privacy_restriction_is_restricted(self) -> None:
        """A privacy-restricted statement classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Sharing is constrained by participant privacy considerations."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["Privacy restrictions"]

    def test_patient_consent_restriction_is_restricted(self) -> None:
        """A patient-consent restriction classifies as RESTRICTED (issue #104)."""
        result = analyze_data_availability(
            "Data access requires patient consent."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["Patient consent required"]

    def test_privacy_does_not_override_full_open(self) -> None:
        """A bare 'privacy' mention must not override a public repository.

        The four privacy/legal patterns are restricted-tier; full-open is
        checked first, so a deposit plus 'no privacy concerns' stays FULL_OPEN.
        """
        result = analyze_data_availability(
            "Data are deposited in Zenodo; no privacy concerns were identified."
        )
        assert result.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_gdpr_with_strong_refusal_is_not_available(self) -> None:
        """GDPR plus an explicit refusal escalates to NOT_AVAILABLE (issue #104)."""
        result = analyze_data_availability(
            "The data are not publicly available owing to GDPR."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE
        assert "Data not publicly available" in result.restrictions
        assert "GDPR restrictions" in result.restrictions

    def test_open_affirmation_without_repository_is_full_open(self) -> None:
        """Open-availability affirmations classify FULL_OPEN with no named repository (#113).

        Full-open is inferred from open-availability affirmations
        ("openly shared", "available in the supplementary materials", "freely
        available"), not only from recognized repository keywords, so a
        reassuring privacy/legal token in a genuinely-open statement no longer
        produces a false RESTRICTED.
        """
        openly_shared = analyze_data_availability(
            "De-identified data are openly shared; no HIPAA-protected "
            "identifiers remain."
        )
        assert openly_shared.disclosure_level == DataDisclosureLevel.FULL_OPEN

        supplementary = analyze_data_availability(
            "All data are available in the supplementary materials; patient "
            "privacy was protected throughout."
        )
        assert supplementary.disclosure_level == DataDisclosureLevel.FULL_OPEN

        freely = analyze_data_availability(
            "The complete dataset is freely available to all researchers."
        )
        assert freely.disclosure_level == DataDisclosureLevel.FULL_OPEN

    def test_open_affirmation_with_strong_refusal_is_not_available(self) -> None:
        """An open affirmation cannot override an explicit strong refusal (#113).

        The up-front unavailability guard must still skip the full-open step, so
        a statement that both affirms availability and refuses access
        classifies NOT_AVAILABLE.
        """
        result = analyze_data_availability(
            "Data are freely available in summary form but the individual-level "
            "data cannot be shared."
        )
        assert result.disclosure_level == DataDisclosureLevel.NOT_AVAILABLE

    def test_restricted_label_sharing_patterns_deduplicated(self) -> None:
        """Two RESTRICTED patterns sharing a label yield it once (issue #114).

        ``institutional review board`` and ``irb approval`` both map to
        "Requires IRB approval", so a statement matching both must not list the
        label twice. Pins Step 3 dedup parity with the Swift
        ``orderedRestrictionLabels`` path.
        """
        result = analyze_data_availability(
            "Access to the data requires institutional review board review "
            "and IRB approval."
        )
        assert result.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert result.restrictions == ["Requires IRB approval"]

    def test_negated_affirmation_does_not_trigger_full_open(self) -> None:
        """A negated open-availability affirmation must not classify FULL_OPEN (#113 review).

        The affirmation patterns carry a negative lookbehind, so an immediately
        negated affirmation ("not openly accessible", "not freely shared")
        falls through to the normal tiers instead of a false FULL_OPEN that
        would drop a real restriction.
        """
        irb = analyze_data_availability(
            "Raw data are not openly accessible without IRB approval."
        )
        assert irb.disclosure_level == DataDisclosureLevel.RESTRICTED
        assert irb.restrictions == ["Requires IRB approval"]

        author = analyze_data_availability(
            "Data are not freely shared; available from the corresponding author."
        )
        assert author.disclosure_level == DataDisclosureLevel.RESTRICTED

        not_open = analyze_data_availability("The data are not openly available.")
        assert not_open.disclosure_level != DataDisclosureLevel.FULL_OPEN


class TestCalculateTransparencyScore:
    """Reference tests for the transparency score.

    These pin the canonical scoring deltas mirrored by the Swift
    ``TransparencyScorer.calculateScore`` (and ``TransparencyConstants``).
    """

    def test_good_transparency(self) -> None:
        """Open data, disclosed no-conflict COI, compliant trial → 90."""
        report = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN
            ),
            coi_info=ConflictOfInterest(statement="No conflicts", has_industry_ties=False),
            trial_registrations=[
                TrialRegistration(registry="ClinicalTrials.gov", registration_id="NCT12345678")
            ],
            results_compliance=ResultsComplianceStatus.COMPLIANT,
        )
        assert calculate_transparency_score(report) == 90

    def test_on_request_scores_five(self) -> None:
        """AVAILABLE_ON_REQUEST awards +5 (not +10)."""
        report = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.AVAILABLE_ON_REQUEST
            ),
            coi_info=ConflictOfInterest(statement="None", has_industry_ties=False),
        )
        assert calculate_transparency_score(report) == 60

    def test_poor_transparency(self) -> None:
        """Unavailable data, industry, outcome switching, missing COI → 5."""
        report = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.NOT_AVAILABLE
            ),
            coi_info=ConflictOfInterest(statement="", has_industry_ties=False),
            industry_funding_detected=True,
            outcome_switching_detected=True,
        )
        assert calculate_transparency_score(report) == 5

    def test_disclosed_industry_ties_penalized(self) -> None:
        """Disclosed COI industry ties reduce the score by 5 after the +5 credit."""
        without_ties = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN
            ),
            coi_info=ConflictOfInterest(
                statement="Grants from a foundation", has_industry_ties=False
            ),
        )
        with_ties = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.FULL_OPEN
            ),
            coi_info=ConflictOfInterest(
                statement="Grants from Pfizer", has_industry_ties=True
            ),
        )
        assert calculate_transparency_score(without_ties) == 75
        assert calculate_transparency_score(with_ties) == 70

    def test_coi_ties_with_restricted_data(self) -> None:
        """COI industry ties + restricted data trigger the combined -10 penalty."""
        report = TransparencyReport(
            data_availability=DataAvailabilityInfo(
                disclosure_level=DataDisclosureLevel.RESTRICTED
            ),
            coi_info=ConflictOfInterest(
                statement="Grants from Pfizer", has_industry_ties=True
            ),
        )
        # 50 - 5 (restricted) + 5 (statement) - 5 (ties) - 10 (combined) = 35
        assert calculate_transparency_score(report) == 35
