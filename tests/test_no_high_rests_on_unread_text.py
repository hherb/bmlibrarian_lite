"""On the desktop, no High can rest on a statement nobody looked for (#386).

Swift and Android show such a High as "Unassessed" and qualify its terms
"(full text not searched)". The desktop ports neither, because its analyser
charges a missing COI or data statement only against text it read (#352,
#353, #359). This is the property that makes leaving them out safe: if it
breaks, the explanation's full-text wording becomes false.
"""

import itertools

import pytest
import requests

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


@pytest.fixture
def no_requests(monkeypatch: pytest.MonkeyPatch) -> None:
    """Fail the test if the analysis makes any HTTP request."""

    def refuse(*_args: object, **_kwargs: object) -> None:
        raise AssertionError("no request may be made when no text is read (#421)")

    monkeypatch.setattr(requests.Session, "request", refuse)


class TestNoMissingStatementIsChargedAgainstTextNobodyRead:
    """The invariant the parity README's "no Unassessed rule" argument rests on."""

    @pytest.mark.parametrize(
        ("pmcid", "pubmed_read"),
        list(itertools.product([None, "PMC1"], [False, True])),
    )
    def test_nothing_read_charges_nothing(
        self, analyzer, no_requests, pmcid, pubmed_read
    ) -> None:
        """Industry-funded, and no text read: no missing-statement rule fires.

        A PMC ID once sent the data availability analysis to Europe PMC's
        XML on its own (#421); now it changes nothing.
        """
        report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=pubmed_read)
        report.industry_funding_detected = True
        report.industry_funding_confidence = 0.9
        report.pmcid = pmcid

        analyzer._analyze_conflicts(report, fulltext_sections={})
        analyzer._analyze_data_availability(report, fulltext_sections={})
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
        analyzer._analyze_conflicts(report, fulltext_sections=sections, fulltext="The article's full text.")
        analyzer._analyze_data_availability(report, fulltext_sections=sections, fulltext="The article's full text.")
        report.transparency_score = calculate_transparency_score(report)
        result = build_transparency_result("d", report, get_default_settings())

        triggers = high_risk_triggers_for(result, get_default_settings())
        assert MissingCoiStatement() in triggers
        assert IndustryFundingWithWithheldData("not_stated") in triggers

    def test_a_rating_never_both_limited_and_charged_from_text(
        self, analyzer, no_requests
    ) -> None:
        """#421: the note and the reason can no longer contradict each other.

        The Europe PMC fallback read an article's XML for its data statement
        alone, so one row said "limited certainty because of lack of full
        text access" beside "no data availability statement was found in
        the full text". Without a full text, neither statement is charged,
        and the data statement is recorded as not assessed with its caveat.
        """
        report = TransparencyReport(doi="10.1/x", pmid="1", pubmed_record_read=True)
        report.industry_funding_detected = True
        report.industry_funding_confidence = 0.9
        report.pmcid = "PMC1"
        analyzer._analyze_conflicts(report, fulltext_sections={})
        analyzer._analyze_data_availability(report, fulltext_sections={})
        report.transparency_score = calculate_transparency_score(report)
        result = build_transparency_result("d", report, get_default_settings())

        triggers = high_risk_triggers_for(result, get_default_settings())
        assert IndustryFundingWithWithheldData("not_stated") not in triggers
        assert result.full_text_analyzed is False
        assert result.data_availability_level == "unknown"
        assert any("data availability statement" in w for w in report.warnings)
