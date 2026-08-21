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
list: the NIH, NSF and CDC patterns were inside it while six funders sat
immediately outside — FDA, VA, AHRQ, PCORI and, less obviously, Wellcome and the
Medical Research Council — so a VA-funded study reported as ``ACADEMIC``. Six,
not the four that the abbreviations alone suggest.

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
    TrialRegistration,
    classify_funder_name,
    determine_sponsor_type,
    update_sponsor_type,
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
            "NIAID",
            "NHLBI",
            "NIMH",
            "National Science Foundation",
            "Centers for Disease Control and Prevention",
        ],
    )
    def test_agencies_inside_the_old_slice_are_still_government(self, name: str) -> None:
        """The half that already worked must not regress.

        NIAID, NHLBI and NIMH are here because the manifest pins their patterns
        string-for-string but nothing used to exercise them: a string pin catches
        drift between platforms, not a pattern that never matched anything on any
        of them. These are the institute abbreviations #150 is about, so they are
        the ones worth being sure of.
        """
        assert determine_sponsor_type([_funder(name)]) == SponsorType.GOVERNMENT

    @pytest.mark.parametrize(
        "name",
        [
            "National Cancer Institute",
            "National Institute of Child Health and Human Development",
            "National Institute of General Medical Sciences",
        ],
    )
    @pytest.mark.xfail(
        strict=True,
        reason="#150: NIH institutes are matched only by abbreviation, not spelled out",
    )
    def test_a_spelled_out_nih_institute_should_be_government(self, name: str) -> None:
        r"""Individual NIH institutes are only matched by their abbreviations (#150).

        The list carries ``\bnci\b``, ``\bniaid\b``, ``\bnhlbi\b`` and
        ``\bnimh\b`` but, apart from the NIH itself, no spelled-out
        "National Institute of X" form — and CrossRef returns the spelled-out form
        routinely, including the bare "National Cancer Institute".

        Pre-existing on both platforms: these tiered ACADEMIC before #147 and
        NONPROFIT after it, both wrong for a US federal agency.

        Written as the behaviour we want and marked ``xfail(strict=True)`` rather
        than pinning the wrong answer: this way the gap reads as an open to-do in
        the CI output instead of a passing feature, and the day #150 lands the
        test XPASSes — which ``strict`` turns into a failure, forcing the marker
        off rather than inviting someone to "fix" a green test back to broken.
        """
        assert determine_sponsor_type([_funder(name)]) == SponsorType.GOVERNMENT

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

    def test_an_unrecognised_funder_warns_that_nonprofit_is_a_fallback(self) -> None:
        """NONPROFIT must not read as a positive finding of nonprofit funding.

        It is reached only by falling through both pattern lists, so it means
        "no funder name was recognised". On the shared labelled corpus that is
        the majority outcome, so leaving it unqualified would put a confident
        label on most reports.
        """
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Fondation Zzyzx", "grant_id": "G1"}]

        analyzer._fetch_funder_info(report)

        assert report.sponsor_type == SponsorType.NONPROFIT
        assert any("not recognised" in w for w in report.warnings)
        assert any("Fondation Zzyzx" in w for w in report.warnings)

    def test_a_recognised_funder_is_not_warned_about(self) -> None:
        """The warning must be specific to the fallback, not attached to every report."""
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "National Institutes of Health", "grant_id": "G1"}]

        analyzer._fetch_funder_info(report)

        assert report.sponsor_type == SponsorType.GOVERNMENT
        assert not any("not recognised" in w for w in report.warnings)

    def test_an_unrecognised_funder_is_warned_about_even_when_the_tier_is_mixed(
        self,
    ) -> None:
        """The caveat is about the funder name, so the tier must not gate it.

        Keyed off the NONPROFIT tier, this case stayed silent: an unrecognised
        name beside an industry one yields MIXED, which reads as a positive
        finding of dual funding — the case where an unverified classification is
        most consequential, not least.
        """
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [
            {"agency": "Fondation Zzyzx", "grant_id": "G1"},
            {"agency": "Pfizer Inc", "grant_id": "G2"},
        ]

        analyzer._fetch_funder_info(report)

        assert report.sponsor_type == SponsorType.MIXED
        assert any("Fondation Zzyzx" in w for w in report.warnings)

    @pytest.mark.parametrize("agency", ["", "   ", None])
    def test_a_nameless_funder_is_skipped_rather_than_classified(
        self, agency: str | None
    ) -> None:
        """A funder with no name is no evidence, so it must not produce a tier.

        PubMed grants and CrossRef entries both arrive without an agency name in
        practice. Classifying one used to yield a confident-looking NONPROFIT
        derived from nothing, plus a caveat reading "Funder names not recognised
        ()" — an empty parenthetical.
        """
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": agency, "grant_id": "G1"}]

        analyzer._fetch_funder_info(report)

        assert report.funders == []
        assert report.sponsor_type == SponsorType.UNKNOWN
        assert report.warnings == []

    def test_industry_confidence_is_the_strongest_funder_not_the_weakest(self) -> None:
        """The reported confidence must be the best evidence, not the worst.

        A registry DOI is authoritative where a name-stem match is a guess, so a
        study carrying both must report the registry's confidence.
        """
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._crossref_funders = [
            {"name": "Pfizer", "DOI": "10.13039/100004319"},
            {"name": "Genentech Inc."},
        ]

        analyzer._fetch_funder_info(report)

        confidences = [f.confidence for f in report.funders]
        assert report.industry_funding_confidence == max(confidences)
        assert report.industry_funding_confidence > min(confidences)


class _StubClinicalTrials:
    """Minimal stand-in for the ClinicalTrials.gov client.

    Returns one study whose lead sponsor class is fixed by the constructor, so a
    test can drive :meth:`StudyTransparencyAnalyzer._fetch_trial_info` without a
    network call.
    """

    def __init__(self, sponsor_class: str | None) -> None:
        """Store the sponsor class this stub will report.

        Args:
            sponsor_class: Value to place on the returned registration, or
                ``None`` to model a registry that reported no sponsor class.
        """
        self._sponsor_class = sponsor_class

    def get_study(self, trial_id: str) -> dict:
        """Return a non-empty placeholder study.

        Args:
            trial_id: Ignored; the stub is indifferent to which trial is asked for.

        Returns:
            A truthy placeholder, since only ``extract_trial_info`` reads it.
        """
        return {"id": trial_id}

    def extract_trial_info(self, study: dict) -> TrialRegistration:
        """Build a registration carrying the configured sponsor class.

        Args:
            study: The placeholder from :meth:`get_study`.

        Returns:
            A :class:`TrialRegistration` for the stubbed study.
        """
        return TrialRegistration(
            registry="ClinicalTrials.gov",
            registration_id=study["id"],
            sponsor_class=self._sponsor_class,
        )


class _UnreachableClinicalTrials:
    """Stand-in for a ClinicalTrials.gov client that cannot reach the registry.

    ``ClinicalTrialsClient.get_study`` catches ``RequestException``, logs it and
    returns ``None``, so an outage is indistinguishable from an unregistered
    study to everything downstream. This models that return.
    """

    def get_study(self, trial_id: str) -> None:
        """Return nothing, as the real client does on a request failure.

        Args:
            trial_id: Ignored.

        Returns:
            ``None``, always.
        """
        return None


class TestTheTrialRegistryUpgrade:
    """Folding ClinicalTrials.gov's sponsor class into the funder-derived tier.

    Mirrors Swift's ``FundingAnalyzer.updateSponsorType``. The inline version this
    replaced tested ``sponsor_type in [GOVERNMENT, ACADEMIC]`` and silently omitted
    NONPROFIT — harmless while NONPROFIT was unreachable, a live defect from the
    moment #147 made it reachable. Swift never had the bug because its ``switch``
    is exhaustive; Python has no such compiler check, so it is pinned here instead.
    """

    @pytest.mark.parametrize(
        "current",
        [SponsorType.GOVERNMENT, SponsorType.ACADEMIC, SponsorType.NONPROFIT],
    )
    def test_every_non_industry_tier_upgrades_to_mixed(self, current: SponsorType) -> None:
        """An industry trial sponsor means both sides paid, whatever the funders said.

        NONPROFIT is the case that regressed: the registry says industry, the
        funder names said nothing recognisable, and the study is mixed.
        """
        assert update_sponsor_type(current, "INDUSTRY") == SponsorType.MIXED

    def test_unknown_becomes_industry(self) -> None:
        """With no funders at all the registry is the only evidence there is."""
        assert update_sponsor_type(SponsorType.UNKNOWN, "INDUSTRY") == SponsorType.INDUSTRY

    @pytest.mark.parametrize("current", [SponsorType.INDUSTRY, SponsorType.MIXED])
    def test_the_terminal_tiers_do_not_move(self, current: SponsorType) -> None:
        """INDUSTRY and MIXED already record industry involvement."""
        assert update_sponsor_type(current, "INDUSTRY") == current

    @pytest.mark.parametrize("sponsor_class", ["NIH", "OTHER", "OTHER_GOV", "NETWORK"])
    def test_a_non_industry_sponsor_class_changes_nothing(self, sponsor_class: str) -> None:
        """The funder names are the better evidence; the registry adds nothing."""
        assert update_sponsor_type(SponsorType.ACADEMIC, sponsor_class) == SponsorType.ACADEMIC

    def test_an_unregistered_study_changes_nothing(self) -> None:
        """No registration means no sponsor class to fold in."""
        assert update_sponsor_type(SponsorType.NONPROFIT, None) == SponsorType.NONPROFIT

    @pytest.mark.parametrize("sponsor_class", ["industry", "Industry", "InDuStRy"])
    def test_the_sponsor_class_is_matched_case_insensitively(self, sponsor_class: str) -> None:
        """It is external API data, so its casing is not ours to assume.

        Swift already upper-cases before comparing; Python compared the raw string.
        """
        assert update_sponsor_type(SponsorType.ACADEMIC, sponsor_class) == SponsorType.MIXED


class TestTheAnalyzerUsesTheSharedUpgrade:
    """The report path must reach :func:`update_sponsor_type`, not a copy of it.

    The same failure mode as ``TestTheAnalyzerUsesTheSharedFunction``: the tier
    list was previously transcribed inline in ``_fetch_trial_info``, which is
    where the missing NONPROFIT lived.
    """

    CONTACT_EMAIL = "tests@example.org"

    def _analyzer_with_trial(
        self, sponsor_class: str | None
    ) -> StudyTransparencyAnalyzer:
        """Build an analyzer whose trial client is stubbed.

        Args:
            sponsor_class: Sponsor class the stubbed registry will report, or
                ``None`` for a registry that reported none.

        Returns:
            An analyzer ready for ``_fetch_trial_info``.
        """
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        analyzer.clinicaltrials = _StubClinicalTrials(sponsor_class)
        return analyzer

    def test_an_industry_trial_with_unrecognised_funders_is_mixed(self) -> None:
        """The regression #147 would otherwise have shipped, end to end.

        Before #147 this funder tiered ACADEMIC and the study reported MIXED.
        Making NONPROFIT reachable dropped it out of the upgrade list, so the
        study reported NONPROFIT while ``industry_funding_detected`` was true —
        a self-contradictory row in the batch CSV export.
        """
        analyzer = self._analyzer_with_trial("INDUSTRY")
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Fondation Zzyzx", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        assert report.sponsor_type == SponsorType.NONPROFIT  # precondition

        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.MIXED
        assert report.industry_funding_detected

    def test_the_unrecognised_funder_warning_survives_the_upgrade_intact(self) -> None:
        """The warning must not name a tier the report has since moved off.

        ``_fetch_funder_info`` raises it while the tier is NONPROFIT, and
        ``_fetch_trial_info`` can then upgrade that to MIXED. A warning reading
        "sponsor type reported as NONPROFIT" would by then be describing a tier
        the report no longer carries, which is worse than staying silent — so it
        is phrased as a statement about the funder names, which stays true.
        """
        analyzer = self._analyzer_with_trial("INDUSTRY")
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Fondation Zzyzx", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.MIXED
        assert any("Fondation Zzyzx" in w for w in report.warnings)
        assert not any("NONPROFIT" in w for w in report.warnings)

    def test_a_government_funded_industry_trial_is_still_mixed(self) -> None:
        """The tiers that already worked must survive the rewiring."""
        analyzer = self._analyzer_with_trial("INDUSTRY")
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "National Institutes of Health", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.MIXED
        assert report.industry_funding_detected

    @pytest.mark.parametrize("sponsor_class", ["INDUSTRY", "industry", "InDuStRy"])
    def test_the_analyzer_matches_the_sponsor_class_case_insensitively(
        self, sponsor_class: str
    ) -> None:
        """Both the tier and the flag must survive registry casing.

        ``_fetch_trial_info`` used to test for an industry sponsor with its own
        inline comparison, so only ``update_sponsor_type``'s copy was covered by
        a casing test. A lowercase class then produced MIXED with
        ``industry_funding_detected`` false — the contradiction
        ``test_an_industry_trial_with_unrecognised_funders_is_mixed`` exists to
        prevent, reached by the one path it did not cover. Both now call
        :func:`is_industry_trial_sponsor`.
        """
        analyzer = self._analyzer_with_trial(sponsor_class)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Fondation Zzyzx", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.MIXED
        assert report.industry_funding_detected

    def test_a_registry_that_reports_no_sponsor_class_changes_nothing(self) -> None:
        """A missing class must not read as one we read and chose not to act on.

        ``extract_trial_info`` leaves ``sponsor_class`` as ``None`` when the
        registry omits it, matching Swift's optional. It defaulted to ``''``,
        which was indistinguishable from a well-formed ``'NIH'``.
        """
        analyzer = self._analyzer_with_trial(None)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "National Institutes of Health", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.GOVERNMENT
        assert not report.industry_funding_detected

    def test_an_unreachable_registry_is_reported_rather_than_read_as_unregistered(
        self,
    ) -> None:
        """A failed fetch must not be indistinguishable from an unregistered study.

        ``get_study`` returns ``None`` on a request failure, logging server-side.
        The report then carried ``trial_registered=False`` and lost the
        registration score, so a ClinicalTrials.gov outage silently made every
        registered study look unregistered to the user.
        """
        analyzer = self._analyzer_with_trial("INDUSTRY")
        analyzer.clinicaltrials = _UnreachableClinicalTrials()
        report = TransparencyReport(pmid="1")
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_trial_info(report)

        assert report.trial_registrations == []
        assert any("NCT01234567" in w for w in report.warnings)
        assert any("not evidence" in w for w in report.warnings)

    def test_a_non_clinicaltrials_registration_is_reported_rather_than_dropped(
        self,
    ) -> None:
        """ISRCTN and EudraCT accessions are collected, then have no client.

        They were dropped with no logging and no caveat, so a study registered
        only in ISRCTN read as "Trial Registration: None found".
        """
        analyzer = self._analyzer_with_trial("INDUSTRY")
        report = TransparencyReport(pmid="1")
        report._databanks = [{"name": "ISRCTN", "accession_numbers": ["ISRCTN12345678"]}]

        analyzer._fetch_trial_info(report)

        assert report.trial_registrations == []
        assert any("ISRCTN12345678" in w for w in report.warnings)

    def test_a_non_industry_trial_leaves_the_funder_tier_alone(self) -> None:
        """An NIH-sponsored registration must not flip anything to mixed."""
        analyzer = self._analyzer_with_trial("NIH")
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "National Institutes of Health", "grant_id": "G1"}]
        report._databanks = [
            {"name": "ClinicalTrials.gov", "accession_numbers": ["NCT01234567"]}
        ]

        analyzer._fetch_funder_info(report)
        analyzer._fetch_trial_info(report)

        assert report.sponsor_type == SponsorType.GOVERNMENT
        assert not report.industry_funding_detected


class TestKnownPatternCollisions:
    """Patterns that match more than they mean, pinned so the cost stays visible.

    Same purpose as the #150 pin: a two-letter pattern that over-matches is a
    real cost, and recording it in a test is what stops it being rediscovered
    from scratch. Unlike #150 these are not marked ``xfail`` — the behaviour is
    Swift's too, so "fixing" it unilaterally would break parity, and the tests
    are here to make a future joint change deliberate.
    """

    @pytest.mark.parametrize(
        "name",
        [
            "Virginia Commonwealth University, Richmond VA",
            "Some Foundation, Arlington VA",
        ],
    )
    def test_a_us_postal_address_can_trigger_the_va_pattern(self, name: str) -> None:
        r"""``\bva\b`` also matches the USPS abbreviation for Virginia.

        Recorded in ``doc/cross_platform/ios_bmlib_alignment.md`` alongside the
        ``labs``/``ab`` collisions that were rejected from the industry lists on
        the same grounds. #147 raised the stakes: the pattern used only to
        suppress industry classification, and now decides the GOVERNMENT tier,
        outranking the university pattern in the first of these names.
        """
        assert determine_sponsor_type([_funder(name)]) == SponsorType.GOVERNMENT

    def test_the_word_boundary_still_protects_virginia_itself(self) -> None:
        r"""``\bva\b`` does not fire inside "Virginia", which is the saving grace."""
        assert determine_sponsor_type([_funder("University of Virginia")]) == (
            SponsorType.ACADEMIC
        )


class TestThePatternSplitPreservesFunderClassification:
    """Splitting the list must not move the industry/non-industry boundary.

    ``classify_funder_name`` matched a single 25-element ``GOVERNMENT_PATTERNS``
    before #147. It now walks ``GOVERNMENT_PATTERNS`` then ``ACADEMIC_PATTERNS``,
    which covers exactly their concatenation in order, and that has to remain the
    same 25 patterns in the same order — otherwise the split silently changes
    which funders are called industry, which is measured against the corpus in
    ``tests/test_funder_classification.py`` and feeds a HIGH-risk rule.
    """

    #: The 25 patterns as they stood before the #147 split, frozen here so one
    #: cannot be added, dropped or reordered without this test failing. Asserting
    #: against ``GOVERNMENT_PATTERNS + ACADEMIC_PATTERNS`` instead would restate
    #: the production line and pass even if both halves lost the same pattern.
    #:
    #: To change the vocabulary deliberately: edit ``sponsor_patterns.json``, both
    #: platform sources, and this baseline in the same commit. Updating this
    #: literal is meant to be the step that makes you confirm the corpus scores in
    #: ``tests/test_funder_classification.py`` still hold.
    FROZEN_PATTERN_BASELINE = [
        r'\bnih\b',
        r'\bnational institutes? of health\b',
        r'\bniaid\b',
        r'\bnci\b',
        r'\bnhlbi\b',
        r'\bnimh\b',
        r'\bnsf\b',
        r'\bnational science foundation\b',
        r'\bcdc\b',
        r'\bcenters? for disease control\b',
        r'\bfda\b',
        r'\bfood and drug administration\b',
        r'\bva\b',
        r'\bveterans? (?:affairs|administration)\b',
        r'\bahrq\b',
        r'\bpcori\b',
        r'\bwellcome\b',
        r'\bmedical research council\b',
        r'\buniversit(?:y|ies)\b',
        r'\bcollege\b',
        r'\bhospital\b',
        r'\bmedical (?:center|school)\b',
        r'\bgovernment\b',
        r'\bfederal\b',
        r'\bstate\b',
    ]

    def test_the_union_is_exactly_the_pre_split_list(self) -> None:
        """The patterns and their order must survive the split unchanged.

        This is the test that would catch a pattern being dropped: the corpus
        measurement in ``tests/test_funder_classification.py`` would shift, but
        only for names carrying that one pattern, so it can move a long way
        before a precision or recall floor notices.
        """
        assert NON_INDUSTRY_PATTERNS == self.FROZEN_PATTERN_BASELINE

    def test_the_halves_together_are_the_frozen_baseline(self) -> None:
        """Neither half may lose a pattern the baseline still expects.

        Deliberately not ``NON_INDUSTRY_PATTERNS == GOVERNMENT_PATTERNS +
        ACADEMIC_PATTERNS``: the production constant is *defined* as that
        concatenation, so such an assertion restates the source and cannot fail.
        Comparing each half against its slice of the frozen baseline is what
        localises a drop to the half that caused it.
        """
        boundary = len(GOVERNMENT_PATTERNS)
        assert GOVERNMENT_PATTERNS == self.FROZEN_PATTERN_BASELINE[:boundary]
        assert ACADEMIC_PATTERNS == self.FROZEN_PATTERN_BASELINE[boundary:]

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
