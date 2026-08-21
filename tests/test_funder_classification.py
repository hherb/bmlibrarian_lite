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

"""Industry-funder name matching, measured against the shared labelled corpus (#143).

``industry_funding_detected`` feeds a HIGH-risk rule and HIGH downgrades a paper's
quality tier, so a false positive costs more than a false negative. The corpus
tests below are what keep that honest: they measure the classifier against 417
hand-labelled CrossRef and PubMed funder names in
``doc/cross_platform/transparency_parity/funder_names.json``.

This file is the Python half of a two-platform contract. Its floors, its
previous-matcher figures and its pinned true/false-positive/false-negative
composition are deliberately **identical** to Swift's
``FunderClassificationTests``, ``FunderCorpusCompositionTests`` and
``IndustryPatternStructureTests``, which read the same bytes of the same corpus.
Either platform drifting from the shared lists fails its own copy of these
assertions, naming the funder that moved.
"""

import json
import re
from pathlib import Path
from typing import Any

import pytest

from bmlibrarian_lite.study_transparency_analyzer.study_transparency_analyzer import (
    ACADEMIC_PATTERN_CONFIDENCE,
    FUNDER_NAME_STEMS,
    FUNDER_NAME_WORDS,
    GOVERNMENT_PATTERN_CONFIDENCE,
    INDUSTRY_KEYWORDS,
    INDUSTRY_NAME_CONFIDENCE,
    KNOWN_FUNDER_CONFIDENCE,
    UNKNOWN_FUNDER_CONFIDENCE,
    CrossRefClient,
    StudyTransparencyAnalyzer,
    TransparencyReport,
    classify_funder_name,
    matches_industry_funder_name,
)

#: The shared corpus, read from the parity directory by path rather than copied
#: into a per-platform fixture — Swift reads the same bytes.
CORPUS_PATH = (
    Path(__file__).resolve().parents[1]
    / "doc"
    / "cross_platform"
    / "transparency_parity"
    / "funder_names.json"
)

#: Floors, one notch below the measured figures, so an unrelated refactor does not
#: have to move them but a real regression trips. Same values as Swift's.
MIN_PRECISION = 0.90
MIN_RECALL = 0.30

#: What the substring matcher this replaced scored on the same names. The
#: canonical Python's own ``INDUSTRY_KEYWORDS[:6]`` slice scored strictly worse
#: still — precision 0.444, recall 0.133 — so clearing these figures clears both.
PREVIOUS_PRECISION = 0.455
PREVIOUS_RECALL = 0.167


def _is_industry(name: str) -> bool:
    """Whether the classifier calls this funder name industry.

    Args:
        name: Raw funder name, as it arrives from CrossRef or PubMed.

    Returns:
        True if classified as an industry funder.
    """
    is_industry, _confidence = classify_funder_name(name)
    return is_industry


@pytest.fixture(scope="module")
def corpus_entries() -> list[dict[str, Any]]:
    """The hand-labelled funder names shared with Swift and bmlib."""
    assert CORPUS_PATH.is_file(), f"missing shared funder corpus: {CORPUS_PATH}"
    entries = json.loads(CORPUS_PATH.read_text(encoding="utf-8"))["entries"]
    return [dict(entry) for entry in entries]


@pytest.fixture(scope="module")
def scored_corpus(
    corpus_entries: list[dict[str, Any]],
) -> tuple[set[str], set[str], set[str]]:
    """Run the real classifier over every non-ambiguous corpus entry.

    Ambiguous names are kept in the file with a reason and excluded from the
    numbers — scoring an undecidable name would only add noise.

    Args:
        corpus_entries: The labelled corpus.

    Returns:
        ``(true_positives, false_positives, false_negatives)`` as name sets.
    """
    true_positives: set[str] = set()
    false_positives: set[str] = set()
    false_negatives: set[str] = set()

    for entry in corpus_entries:
        if entry["label"] == "ambiguous":
            continue
        labelled_industry = entry["label"] == "industry"
        classified_industry = _is_industry(entry["name"])
        if classified_industry and labelled_industry:
            true_positives.add(entry["name"])
        elif classified_industry:
            false_positives.add(entry["name"])
        elif labelled_industry:
            false_negatives.add(entry["name"])

    return true_positives, false_positives, false_negatives


class TestOrgSuffixesMatchAsWords:
    """Legally reserved incorporation suffixes, with or without a trailing dot."""

    def test_inc_with_a_dot(self) -> None:
        r"""``\binc\b`` needs no trailing ``\.?``: ``\b`` already sits before the dot."""
        assert _is_industry("Genentech Inc.")

    def test_inc_without_a_dot(self) -> None:
        """The bare suffix, which is how CrossRef most often reports it."""
        assert _is_industry("Pfizer Inc")

    def test_inc_uppercased(self) -> None:
        """Names are lowercased before matching, so case must not matter."""
        assert _is_industry("PFIZER INC")

    def test_lincoln_is_not_a_company(self) -> None:
        """``inc`` as a substring reaches "Lincoln", "Vincent" and "province"."""
        assert not _is_industry("Lincoln Medical Center")

    def test_spelled_out_suffixes_earned_inclusion(self) -> None:
        """"Incorporated" and "Limited" are the long forms of two kept suffixes."""
        assert _is_industry("Vertex Pharmaceuticals Incorporated")
        assert _is_industry("Takeda Limited")

    def test_llc_earned_inclusion(self) -> None:
        """Two corpus true positives carry LLC and nothing else."""
        assert _is_industry("Flatiron Health LLC")

    def test_gmbh(self) -> None:
        """The German reserved suffix, kept on the same argument as ``corp``."""
        assert _is_industry("Boehringer Ingelheim GmbH")


class TestStemsMatchInsideALongerWord:
    """Stems match as substrings; whole words must not."""

    def test_pharmaceuticals_plural(self) -> None:
        r"""``\bpharma(?:ceutical)?\b`` could not match the company-name plural.

        The word boundary lands before the "s", so "X Pharmaceuticals" — the
        standard form — was missed. Six of the nine documented Swift/bmlib
        mismatches were exactly this.
        """
        assert _is_industry("Regeneron Pharmaceuticals")

    def test_pharmaceutical_singular(self) -> None:
        """The singular form still matches the same stem."""
        assert _is_industry("Pharmaceutical Research Institute")

    def test_bare_pharma_is_still_industry(self) -> None:
        """Kept as a whole word, which is the safe residue of the wider stem."""
        assert _is_industry("Acme Pharma")

    def test_therapeutics(self) -> None:
        """1 TP / 0 FP on the corpus."""
        assert _is_industry("Moderna Therapeutics")

    def test_plural_laboratories_is_industry(self) -> None:
        """1 TP / 0 FP; the plural only."""
        assert _is_industry("Abbott Laboratories")

    def test_a_singular_key_laboratory_is_not_industry(self) -> None:
        """"Key Laboratory" is a Chinese state-lab form and must keep missing."""
        assert not _is_industry("Key Laboratory of Molecular Biology")

    def test_pharmacy_is_not_industry(self) -> None:
        """"pharma" as a substring reached "Pharmacy", which is academic."""
        assert not _is_industry("School of Pharmacy")

    def test_pharmacology_is_not_industry(self) -> None:
        """Likewise "Pharmacology" and "Pharmacogenetics"."""
        assert not _is_industry("Institute of Pharmacology")


class TestMeasuredExclusions:
    """Terms the corpus disqualified, and the narrower forms kept in their place."""

    def test_biotechnology_alone_is_not_industry(self) -> None:
        r"""The defect this issue fixes, in its two live forms.

        ``\bbiotech(?:nology)?\b`` scored 0 TP / 4 FP on the corpus, reaching
        only an Indian ministry and a UK research council. Both were classified
        industry by the canonical Python before #143, which set
        ``industry_funding_detected`` and so downgraded the quality tier of every
        paper they fund.
        """
        assert not _is_industry("Department of Biotechnology")
        assert not _is_industry("Biotechnology and Biological Sciences Research Council")

    def test_bare_biotech_is_still_industry(self) -> None:
        """As a bare word it is a company name, so that form is kept."""
        assert _is_industry("Acme Biotech")

    def test_corporation_is_not_an_org_token(self) -> None:
        """1 TP / 1 FP: US non-profits use "Corporation"."""
        assert not _is_industry("Research Corporation for Science Advancement")

    def test_corp_is_an_org_token(self) -> None:
        """The abbreviation is reserved in a way the long form is not."""
        assert _is_industry("Amgen Corp")

    def test_co_is_not_an_org_token(self) -> None:
        """4 TP / 0 FP, but it collides with the English prefix."""
        assert not _is_industry("Project co-sponsored by the province")

    def test_plc_is_an_org_token(self) -> None:
        """0 TP / 0 FP, kept on the reserved-suffix argument like ``corp``."""
        assert _is_industry("Diagnostics PLC")
        assert _is_industry("GlaxoSmithKline plc")

    def test_labs_is_not_an_org_token(self) -> None:
        """Collides with "Los Alamos National Labs"; costs "Tempus Labs"."""
        assert not _is_industry("Los Alamos National Labs")

    def test_ab_is_not_an_org_token(self) -> None:
        """Collides with a province code, and these names carry locations."""
        assert not _is_industry("University of Calgary, Calgary, AB, Canada")


class TestPublicSectorPrecedence:
    """The non-industry layer runs first and wins outright.

    Shared with Swift's ``classifyFunder``, where the government and academic
    patterns are checked before the funder-name lists. Without the precedence a
    university spin-out naming convention would flag its parent institution.
    """

    def test_a_government_agency(self) -> None:
        """No industry token, and a government pattern matches."""
        assert not _is_industry("Ministry of Science and Technology")

    def test_a_charity(self) -> None:
        """Wellcome is named in the non-industry list."""
        assert not _is_industry("Wellcome Trust")

    def test_a_university_beats_a_corporate_suffix(self) -> None:
        """An academic pattern outranks an incorporation suffix in the same name."""
        assert not _is_industry("University of Basel Pharmaceutical Sciences Ltd")

    def test_an_empty_name(self) -> None:
        """Nothing matches, so the name is unknown rather than industry."""
        assert not _is_industry("")


class TestConfidences:
    """The confidence each layer reports, mirroring Swift's five constants.

    Cross-platform equality is asserted from the shared contract in
    ``tests/test_transparency_parity.py``; these pin the Python side's own
    behaviour and the ordering the ladder depends on.
    """

    def test_known_industry_funder_doi_wins(self) -> None:
        """A registry DOI is the highest-confidence signal and short-circuits."""
        assert classify_funder_name("Pfizer", "10.13039/100004319") == (
            True,
            KNOWN_FUNDER_CONFIDENCE,
        )

    def test_an_unknown_doi_falls_through_to_the_name(self) -> None:
        """An unrecognised DOI must not suppress name matching."""
        assert classify_funder_name("Genentech Inc.", "10.13039/501100000000") == (
            True,
            INDUSTRY_NAME_CONFIDENCE,
        )

    def test_a_government_name(self) -> None:
        """The government half reports the highest of the name-layer confidences."""
        assert classify_funder_name("National Institutes of Health") == (
            False,
            GOVERNMENT_PATTERN_CONFIDENCE,
        )

    def test_an_academic_name(self) -> None:
        """The academic half reports its own, lower confidence (#152).

        Python returned a flat value for both halves until #152, where Swift had
        always distinguished them. The ``is_industry`` boolean agreed throughout,
        which is why the corpus measurement never caught it.
        """
        assert classify_funder_name("University of Oxford") == (
            False,
            ACADEMIC_PATTERN_CONFIDENCE,
        )

    def test_an_unrecognised_name(self) -> None:
        """No layer matched, so the classification is a low-confidence "not industry"."""
        assert classify_funder_name("Fondation Zzyzx") == (False, UNKNOWN_FUNDER_CONFIDENCE)

    def test_a_name_matching_both_halves_reports_the_government_confidence(self) -> None:
        r"""Government is checked first, and that ordering is now observable.

        "Veterans Affairs Medical Center" carries a government pattern
        (``\bveterans? (?:affairs|administration)\b``) and an academic one
        (``\bmedical (?:center|school)\b``). While both halves returned the same
        confidence the order was inert; since #152 it decides the reported value,
        so reversing the two checks is a behaviour change rather than a tidy-up.
        """
        assert classify_funder_name("Veterans Affairs Medical Center") == (
            False,
            GOVERNMENT_PATTERN_CONFIDENCE,
        )

    def test_the_confidences_are_ordered(self) -> None:
        """The ladder descends from registry DOI to no match at all.

        A known DOI outranks a named public body, which outranks a generic
        institutional word ("university", "hospital"), which outranks a generic
        company form, which outranks nothing matching. Two layers sharing a value
        would be indistinguishable to a caller ranking funders by confidence.
        """
        assert (
            KNOWN_FUNDER_CONFIDENCE
            > GOVERNMENT_PATTERN_CONFIDENCE
            > ACADEMIC_PATTERN_CONFIDENCE
            > INDUSTRY_NAME_CONFIDENCE
            > UNKNOWN_FUNDER_CONFIDENCE
        )


class TestTheAlignmentTable:
    """The 17 names in ``doc/cross_platform/ios_bmlib_alignment.md`` §1.4.

    Swift pins the same table in ``FunderClassificationTests``. Pinning it on both
    platforms is what makes it a parity check rather than two independent claims.
    """

    ALIGNMENT_TABLE: list[tuple[str, bool]] = [
        ("Department of Biotechnology", False),
        ("Biotechnology and Biological Sciences Research Council", False),
        ("Research Corporation for Science Advancement", False),
        ("Vertex Pharmaceuticals Incorporated", True),
        ("Regeneron Pharmaceuticals", True),
        ("Moderna Therapeutics", True),
        ("Abbott Laboratories", True),
        ("Tempus Labs, LLC", True),
        ("Flatiron Health LLC", True),
        ("Pfizer Inc", True),
        ("Genentech, Inc.", True),
        ("Ministry of Science and Technology", False),
        ("Lincoln Medical Center", False),
        ("University of Calgary, Calgary, AB, Canada", False),
        ("Key Laboratory of Molecular Biology", False),
        ("Novo Nordisk A/S", False),
        ("Bristol-Myers Squibb Company", False),
    ]

    @pytest.mark.parametrize("name,expected", ALIGNMENT_TABLE)
    def test_agrees_with_the_documented_table(self, name: str, expected: bool) -> None:
        """Each row of the table the alignment document records."""
        assert _is_industry(name) is expected


class TestCorpusMeasurement:
    """Measured quality against the shared corpus, expressed as floors."""

    def test_precision_meets_the_floor(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """Measured 0.909. Ties go to precision: a false positive costs more."""
        true_positives, false_positives, _ = scored_corpus
        precision = len(true_positives) / (len(true_positives) + len(false_positives))
        assert precision >= MIN_PRECISION, f"precision fell to {precision}"

    def test_recall_meets_the_floor(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """Measured 0.333."""
        true_positives, _, false_negatives = scored_corpus
        recall = len(true_positives) / (len(true_positives) + len(false_negatives))
        assert recall >= MIN_RECALL, f"recall fell to {recall}"

    def test_it_beats_the_matcher_it_replaced(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """The ship rule: gain recall without losing precision."""
        true_positives, false_positives, false_negatives = scored_corpus
        precision = len(true_positives) / (len(true_positives) + len(false_positives))
        recall = len(true_positives) / (len(true_positives) + len(false_negatives))
        assert precision > PREVIOUS_PRECISION
        assert recall > PREVIOUS_RECALL


class TestCorpusComposition:
    """Pins *which* names the classifier gets right and wrong, not just how many.

    The floors leave two gaps. The recall floor sits at 0.30 against a measured
    10/30, so losing a true positive outright still passes (9/30 = 0.30) and
    precision then reads 9/10 = 0.90 and passes too. And nothing says which ten:
    swapping one recognised funder for another leaves both metrics identical.

    All three sets are expected to change — that is the point. A change becomes a
    deliberate edit to this file with the funder's name in the diff, rather than a
    silent drift underneath an unmoved average. The same three sets are pinned in
    Swift's ``FunderCorpusCompositionTests``, so the two platforms disagreeing
    fails here as well as there.
    """

    #: The ten industry funders the matcher recognises. Every one carries a legal
    #: suffix or a company-form stem; none is recognised by brand.
    EXPECTED_TRUE_POSITIVES = {
        "Astex Pharmaceuticals, Inc.",
        "Cardinal Health, LLC",
        "Chia Tai Tianqing Pharmaceutical Group Co., Ltd.",
        "Chugai Pharmaceutical Co., Ltd",
        "Dr. Reddy's Laboratories, Hyderabad, India",
        "Geneos Therapeutics",
        "ImmVira Co., Limited",
        "NanOlogy, LLC",
        "Natera, Inc",
        "Treatment Technologies and Insights, Incorporated",
    }

    #: The one false positive, and the whole reason precision is 0.909 rather than
    #: 1.0: a Chinese state heritage studio whose name contains "Pharmaceutical".
    EXPECTED_FALSE_POSITIVES = {
        "National Inheritance Studio of Veteran Pharmaceutical Workers of Zhong Lingyun",
    }

    #: The twenty industry funders the matcher misses — the recall debt, written
    #: down. Almost all are bare brand names: CrossRef and PubMed frequently return
    #: "Pfizer" or "Roche" with no legal suffix, and the matcher recognises company
    #: *forms*, not companies. Closing this needs a brand list, which is a
    #: different mechanism with a different false-positive profile.
    EXPECTED_FALSE_NEGATIVES = {
        "AbbVie",
        "Arima Genomics",
        "AstraZeneca.",
        "Bristol Myers Squibb",
        "Diaceutics",
        "Guardant Health",
        "Invitae Corporation",
        "Janssen Scientific Affairs",
        "La Roche Posay",
        "Lockheed Martin",
        "Merck & Co.; Merck Sharp & Dohme",
        "NVIDIA",
        "Personalis",
        "Pfizer",
        "Pfizer and Jazz",
        "Roche",
        "Roche Sweden AB",
        "Tempus Labs",
        "TerumoBCT",
        "Teva",
    }

    def test_true_positive_composition_is_unchanged(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """The funders recognised, by name."""
        assert scored_corpus[0] == self.EXPECTED_TRUE_POSITIVES

    def test_false_positive_composition_is_unchanged(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """The public-sector names wrongly flagged, by name."""
        assert scored_corpus[1] == self.EXPECTED_FALSE_POSITIVES

    def test_false_negative_composition_is_unchanged(
        self, scored_corpus: tuple[set[str], set[str], set[str]]
    ) -> None:
        """The recall debt, by name."""
        assert scored_corpus[2] == self.EXPECTED_FALSE_NEGATIVES


class TestPatternStructure:
    r"""A pattern that matches *nothing* moves no metric, so the corpus cannot see it.

    Two ways to write one that fail **silently**, and both ship green without
    these tests: a ``\b``-anchored string placed in the substring list, where it
    becomes a literal search for a backslash and a "b", and an uppercase stem,
    which can never match a name that was lowercased first. Either quietly stops
    flagging the funders it was meant to catch.

    An invalid regex behaves differently on the two platforms and is worth
    separating out: Python raises ``re.error`` at classification time — a crash
    rather than a silent no-op — while Swift's ``RegexHelper`` turns it into
    ``nil`` via ``try?`` and skips it for good. The compile check below catches it
    at test time either way, which is what keeps the two platforms' lists
    interchangeable.
    """

    def test_every_stem_is_lowercased(self) -> None:
        """Funder names are lowercased before the substring comparison."""
        assert [stem for stem in FUNDER_NAME_STEMS if stem != stem.lower()] == []

    def test_no_stem_is_a_regex_source(self) -> None:
        """A stem is matched with ``in``, so regex syntax would be taken literally."""
        assert [stem for stem in FUNDER_NAME_STEMS if "\\" in stem] == []

    def test_no_stem_is_empty(self) -> None:
        """An empty stem matches every name."""
        assert [stem for stem in FUNDER_NAME_STEMS if not stem] == []

    def test_every_funder_name_word_compiles(self) -> None:
        """An invalid pattern would raise at match time rather than never fire."""
        for pattern in FUNDER_NAME_WORDS:
            re.compile(pattern)

    def test_every_industry_keyword_compiles(self) -> None:
        """The COI prose list shares the failure mode."""
        for pattern in INDUSTRY_KEYWORDS:
            re.compile(pattern)

    def test_every_funder_name_word_is_word_anchored(self) -> None:
        """The whole-word list exists to *not* match inside a longer word.

        An unanchored entry there is a stem wearing the wrong list's semantics.
        """
        unanchored = [
            pattern
            for pattern in FUNDER_NAME_WORDS
            if not (pattern.startswith(r"\b") and pattern.endswith(r"\b"))
        ]
        assert unanchored == []

    def test_coi_prose_phrases_stay_out_of_the_funder_lists(self) -> None:
        """The funder classifier reads the funder lists, not ``INDUSTRY_KEYWORDS``.

        The two are different kinds of thing and merging them is a bug: a phrase
        like "advisory board" belongs to a disclosure statement and would fire on
        an organisation name, while the generic corporate suffixes match far too
        freely in running prose.
        """
        funder_patterns = set(FUNDER_NAME_WORDS)
        prose_phrases = [phrase for phrase in INDUSTRY_KEYWORDS if " " in phrase]
        assert [phrase for phrase in prose_phrases if phrase in funder_patterns] == []


class TestMatchesIndustryFunderNameIsThePredicate:
    """The pure predicate behind the classifier, exposed for reuse and testing."""

    def test_it_ignores_the_public_sector_layer(self) -> None:
        """The predicate answers "does this name carry an industry marker?" only.

        Precedence belongs to ``classify_funder_name``. Keeping the predicate free
        of it is what lets the layer order be tested independently of the lists.
        """
        assert matches_industry_funder_name("University of Basel Pharmaceutical Sciences Ltd")
        assert not classify_funder_name("University of Basel Pharmaceutical Sciences Ltd")[0]

    def test_it_lowercases_its_own_input(self) -> None:
        """Callers must not have to remember to lowercase first."""
        assert matches_industry_funder_name("PFIZER INC")


class TestFunderExtractionWiring:
    """The two funder sources must both reach the measured classifier.

    Measuring a classifier nothing calls proves nothing, and the DOI short-circuit
    used to be written out separately at each call site — so a fix applied to one
    copy could miss the other. These tests pin that CrossRef funders and PubMed
    grant agencies alike are classified by :func:`classify_funder_name`, with the
    confidence it reports rather than a locally recomputed one.
    """

    CONTACT_EMAIL = "tests@example.org"

    def test_crossref_funders_are_classified_by_name(self) -> None:
        """A corporate suffix with no registry DOI still classifies as industry."""
        client = CrossRefClient(self.CONTACT_EMAIL)

        funders = client.extract_funders({"funder": [{"name": "Genentech Inc."}]})

        assert [(f.name, f.is_industry, f.confidence) for f in funders] == [
            ("Genentech Inc.", True, INDUSTRY_NAME_CONFIDENCE)
        ]

    def test_crossref_known_doi_still_wins(self) -> None:
        """The registry DOI short-circuits, and award numbers pass through."""
        client = CrossRefClient(self.CONTACT_EMAIL)

        funders = client.extract_funders(
            {"funder": [{"name": "Pfizer", "DOI": "10.13039/100004319", "award": ["A1"]}]}
        )

        assert len(funders) == 1
        assert funders[0].is_industry
        assert funders[0].confidence == KNOWN_FUNDER_CONFIDENCE
        assert funders[0].award_numbers == ["A1"]

    def test_a_public_research_body_is_no_longer_flagged_as_industry(self) -> None:
        r"""The user-visible half of #143, at the call site.

        "Department of Biotechnology" is India's national research funder. Before
        #143 it matched ``\bbiotech(?:nology)?\b`` and set
        ``industry_funding_detected``, which feeds a HIGH-risk rule and downgrades
        the quality tier of every paper it funds.
        """
        client = CrossRefClient(self.CONTACT_EMAIL)

        funders = client.extract_funders({"funder": [{"name": "Department of Biotechnology"}]})

        assert not funders[0].is_industry

    def test_pubmed_grant_agencies_reach_the_same_classifier(self) -> None:
        """The second funder source, which is easy to leave behind on a fix."""
        analyzer = StudyTransparencyAnalyzer(self.CONTACT_EMAIL, use_browser_fallback=False)
        report = TransparencyReport(pmid="1")
        report._pubmed_grants = [{"agency": "Department of Biotechnology", "grant_id": "G1"}]

        analyzer._fetch_funder_info(report)

        assert [(f.name, f.is_industry) for f in report.funders] == [
            ("Department of Biotechnology", False)
        ]
        assert not report.industry_funding_detected
