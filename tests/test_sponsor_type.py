# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2026 Dr Horst Herb
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

"""Overall sponsor-type classification, aligned with Swift (#147).

``sponsor_type`` answers "who paid for this study?" once the individual funders
have been classified. Until #147 the government tier was selected by a positional
``GOVERNMENT_PATTERNS[:10]`` slice, which cut through the middle of the agency
list: the NIH, NSF and CDC patterns were inside it while the FDA, VA, AHRQ and
PCORI patterns sat immediately outside, so a VA-funded study reported as
``ACADEMIC``.

The lists are now split the way Swift splits them —
``IndustryPatterns.governmentPatterns`` and ``academicPatterns`` — and
:func:`determine_sponsor_type` mirrors ``FundingAnalyzer.determineSponsorType``,
including its ``NONPROFIT`` fallback for a non-industry funder that matches
neither list.
"""

import re

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ACADEMIC_PATTERNS,
    GOVERNMENT_PATTERNS,
    NON_INDUSTRY_PATTERNS,
    FunderInfo,
    SponsorType,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    classify_funder_name,
    determine_sponsor_type,
)


def _funder(name: str) -> FunderInfo:
    """Build a funder the way the analyzer does, by classifying its name.

    Deliberately not hand-setting ``is_industry``: the sponsor tier is reached
    only for funders the classifier already called non-industry, so constructing
    them through the real classifier keeps the two layers honestly connected.

    Args:
        name: Funder name.

    Returns:
        A classified :class:`FunderInfo`.
    """
    is_industry, confidence = classify_funder_name(name)
    return FunderInfo(name=name, is_industry=is_industry, confidence=confidence)


class TestTheIndustryTiers:
    """The three tiers decided before the government/academic question arises."""

    def test_no_funders_is_unknown(self) -> None:
        """Absence of funding data is not evidence of any sponsor type."""
        assert determine_sponsor_type([]) == SponsorType.UNKNOWN

    def test_only_industry_funders(self) -> None:
        """Every funder commercial."""
        assert determine_sponsor_type([_funder("Genentech Inc.")]) == SponsorType.INDUSTRY

    def test_industry_alongside_public_money_is_mixed(self) -> None:
        """Mixed funding is its own tier, not a majority vote."""
        funders = [_funder("Genentech Inc."), _funder("National Institutes of Health")]

        assert determine_sponsor_type(funders) == SponsorType.MIXED


class TestTheGovernmentTier:
    """Which public bodies count as government (#147).

    The four agencies below sat immediately outside the old positional slice and
    are the reason this issue exists.
    """

    @pytest.mark.parametrize(
        "name",
        [
            "U.S. Department of Veterans Affairs",
            "VA Office of Research and Development",
            "Food and Drug Administration",
            "FDA Office of Orphan Products Development",
            "Agency for Healthcare Research and Quality (AHRQ)",
            "PCORI",
        ],
    )
    def test_agencies_outside_the_old_slice_are_government(self, name: str) -> None:
        """Each of these reported ACADEMIC before #147."""
        assert determine_sponsor_type([_funder(name)]) == SponsorType.GOVERNMENT

    @pytest.mark.parametrize(
        "name",
        [
            "National Institutes of Health",
            "NCI",
            "National Science Foundation",
            "Centers for Disease Control and Prevention",
        ],
    )
    def test_agencies_inside_the_old_slice_are_still_government(self, name: str) -> None:
        """The half that already worked must not regress."""
        assert determine_sponsor_type([_funder(name)]) == SponsorType.GOVERNMENT

    @pytest.mark.parametrize(
        "name",
        [
            "National Cancer Institute",
            "National Institute of Child Health and Human Development",
            "National Institute of General Medical Sciences",
        ],
    )
    def test_a_spelled_out_nih_institute_is_a_known_gap(self, name: str) -> None:
        r"""Individual NIH institutes are only matched by their abbreviations (#150).

        The list carries ``\bnci\b``, ``\bniaid\b``, ``\bnhlbi\b`` and
        ``\bnimh\b`` but, apart from the NIH itself, no spelled-out
        "National Institute of X" form — and CrossRef returns the spelled-out form
        routinely, including the bare "National Cancer Institute".

        Pre-existing on both platforms: these tiered ACADEMIC before #147 and
        NONPROFIT after it, both wrong for a US federal agency. Pinned as a record
        of known cost rather than an endorsement, in the same spirit as the
        recall debt in ``TestCorpusComposition``. Fixing #150 is expected to fail
        this test, on both platforms at once.
        """
        assert determine_sponsor_type([_funder(name)]) == SponsorType.NONPROFIT

    def test_a_national_research_council_is_government(self) -> None:
        """The MRC is a publicly funded UK research council; Swift tiers it government."""
        assert determine_sponsor_type([_funder("Medical Research Council")]) == (
            SponsorType.GOVERNMENT
        )

    def test_a_charity_follows_swift_rather_than_its_legal_form(self) -> None:
        """Wellcome is a charitable foundation, yet Swift tiers it government.

        Recorded as a deliberate parity choice rather than a claim about Wellcome:
        the alternative was leaving the two platforms disagreeing about it. The
        pattern sits in the government list on both sides, so if this is ever
        revisited it must be revisited on both.
        """
        assert determine_sponsor_type([_funder("Wellcome Trust")]) == SponsorType.GOVERNMENT

    def test_government_outranks_academic_across_funders(self) -> None:
        """One public agency is enough, however many universities are alongside it."""
        funders = [_funder("University of Oxford"), _funder("National Institutes of Health")]

        assert determine_sponsor_type(funders) == SponsorType.GOVERNMENT


class TestTheAcademicAndNonprofitTiers:
    """What is left once no government funder is present."""

    @pytest.mark.parametrize(
        "name",
        [
            "University of Oxford",
            "Imperial College",
            "Massachusetts General Hospital",
            "Cedars-Sinai Medical Center",
        ],
    )
    def test_institutional_funders_are_academic(self, name: str) -> None:
        """The academic list is unchanged by #147; only its selection is."""
        assert determine_sponsor_type([_funder(name)]) == SponsorType.ACADEMIC

    def test_an_unrecognised_funder_is_nonprofit(self) -> None:
        """Swift's fallback, adopted here: unrecognised is not the same as academic.

        Before #147 every non-industry funder that was not government fell to
        ACADEMIC, so a foundation nobody had heard of was reported as a
        university. ``SponsorType.NONPROFIT`` already existed and was unreachable.
        """
        assert determine_sponsor_type([_funder("Fondation Zzyzx")]) == SponsorType.NONPROFIT

    def test_academic_outranks_nonprofit(self) -> None:
        """A recognised institution decides the tier over an unrecognised funder."""
        funders = [_funder("Fondation Zzyzx"), _funder("University of Oxford")]

        assert determine_sponsor_type(funders) == SponsorType.ACADEMIC


class TestTheAnalyzerUsesTheSharedFunction:
    """The report path must reach :func:`determine_sponsor_type`, not a copy.

    ``_fetch_funder_info`` carried its own inline transcription of the tier
    logic — which is where the ``[:10]`` slice lived. A function nothing calls
    fixes nothing, so this pins that the report gets the shared one.
    """

    CONTACT_EMAIL = "tests@example.org"

    def test_a_va_funded_report_is_government(self) -> None:
        """The user-visible half of #147, end to end."""
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [
            {"agency": "U.S. Department of Veterans Affairs", "grant_id": "G1"}
        ]

        analyzer._fetch_funder_info(report)

        assert report.sponsor_type == SponsorType.GOVERNMENT
        assert not report.industry_funding_detected

    def test_an_industry_funded_report_is_still_industry(self) -> None:
        """The industry tiers must survive the rewiring."""
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Genentech Inc.", "grant_id": "G1"}]

        analyzer._fetch_funder_info(report)

        assert report.sponsor_type == SponsorType.INDUSTRY
        assert report.industry_funding_detected


class TestThePatternSplitPreservesFunderClassification:
    """Splitting the list must not move the industry/non-industry boundary.

    ``classify_funder_name`` matched a single 25-element ``GOVERNMENT_PATTERNS``
    before #147. It now matches ``NON_INDUSTRY_PATTERNS``, and that has to be the
    same 25 patterns in the same order — otherwise the split silently changes
    which funders are called industry, which is measured against the corpus in
    ``tests/test_funder_classification.py`` and feeds a HIGH-risk rule.
    """

    def test_the_union_is_the_concatenation_in_order(self) -> None:
        """Order matters: first match wins, and both halves return non-industry."""
        assert NON_INDUSTRY_PATTERNS == GOVERNMENT_PATTERNS + ACADEMIC_PATTERNS

    def test_the_two_halves_are_disjoint(self) -> None:
        """A pattern in both lists would make the academic tier unreachable for it."""
        assert set(GOVERNMENT_PATTERNS) & set(ACADEMIC_PATTERNS) == set()

    def test_both_halves_are_non_empty(self) -> None:
        """An empty half collapses a tier without failing anything else."""
        assert GOVERNMENT_PATTERNS
        assert ACADEMIC_PATTERNS

    def test_every_pattern_compiles(self) -> None:
        """An invalid pattern raises at classification time rather than at import."""
        for pattern in NON_INDUSTRY_PATTERNS:
            re.compile(pattern)

    def test_an_academic_funder_is_still_non_industry(self) -> None:
        """The academic half must keep suppressing the industry lists.

        "University of Basel Pharmaceutical Sciences Ltd" carries both an academic
        pattern and two industry markers; the academic half has to win, and it
        only does so if it is still reached by ``classify_funder_name``.
        """
        assert not classify_funder_name("University of Basel Pharmaceutical Sciences Ltd")[0]

    def test_a_government_funder_is_still_non_industry(self) -> None:
        """Likewise the government half."""
        assert not classify_funder_name("National Institutes of Health Inc")[0]
