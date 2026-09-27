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
    """Build an analyzer with network and browser fallbacks disabled."""
    return StudyTransparencyAnalyzer(
        email="test@example.com", use_browser_fallback=False, auto_discover_fulltext=False
    )


#: The Europe PMC answers in which no text is read. XML *with* sections is
#: read text, and has a test of its own below.
EUROPE_PMC = {
    "no pmcid": None,
    "no open-access copy": FullTextFetch.absent(),
    "xml without sections": FullTextFetch.served("<article><front/></article>"),
}


class TestNoMissingStatementIsChargedAgainstTextNobodyRead:
    """The invariant the parity README's "no Unassessed rule" argument rests on."""

    @pytest.mark.parametrize(
        ("europe_pmc", "pubmed_read"),
        list(itertools.product(EUROPE_PMC, [False, True])),
    )
    def test_nothing_read_charges_nothing(self, analyzer, europe_pmc, pubmed_read) -> None:
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
        result = build_transparency_result("d", report, get_default_settings())

        triggers = high_risk_triggers_for(result, get_default_settings())
        assert MissingCoiStatement() not in triggers
        assert IndustryFundingWithWithheldData("not_stated") not in triggers
        assert result.full_text_analyzed is False

    def test_the_control_read_text_is_still_charged(self, analyzer) -> None:
        """Without this, the test above would pass on an analyser that never charges."""
        report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=True)
        report.industry_funding_detected = True
        sections = {"methods": "...", "funding": "NIH grant R01."}
        analyzer._analyze_conflicts(report, fulltext_sections=sections, fulltext_read=True)
        analyzer._analyze_data_availability(report, fulltext_sections=sections, fulltext_read=True)
        report.transparency_score = calculate_transparency_score(report)
        result = build_transparency_result("d", report, get_default_settings())

        triggers = high_risk_triggers_for(result, get_default_settings())
        assert MissingCoiStatement() in triggers
        assert IndustryFundingWithWithheldData("not_stated") in triggers

    def test_europe_pmc_sections_are_read_text(self, analyzer) -> None:
        """The fallback's XML is the article's own text, searched section by section.

        No full text was discovered, but Europe PMC served XML with sections
        and none of them is a data statement: that is the article's answer,
        so it is charged. It stays out of ``full_text_analyzed`` -- only the
        data statement was looked for there, and the conflict of interest
        analysis has already recorded that no full text was read -- so the
        rating keeps its limited-certainty note.
        """
        report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=True)
        report.industry_funding_detected = True
        report.industry_funding_confidence = 0.9
        report.pmcid = "PMC1"
        analyzer.europepmc.get_full_text_xml = lambda *_a, **_k: FullTextFetch.served(
            "<article><body><sec><title>Methods</title><p>We did X.</p></sec>"
            "</body></article>"
        )
        analyzer._analyze_conflicts(report, fulltext_sections={}, fulltext_read=False)
        analyzer._analyze_data_availability(report, fulltext_sections={}, fulltext_read=False)
        report.transparency_score = calculate_transparency_score(report)
        result = build_transparency_result("d", report, get_default_settings())

        triggers = high_risk_triggers_for(result, get_default_settings())
        assert IndustryFundingWithWithheldData("not_stated") in triggers
        assert MissingCoiStatement() not in triggers
        assert result.full_text_analyzed is False
