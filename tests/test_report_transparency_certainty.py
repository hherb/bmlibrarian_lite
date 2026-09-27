# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""The report qualifies limited ratings and explains each High (#386)."""

import dataclasses
from datetime import datetime
from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.agents.report_risk_helpers import (
    format_high_risk_section,
    format_reference_risk_annotation,
)
from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.data_models import Citation, LiteDocument, ReportMetadata
from bmlibrarian_lite.transparency import (
    COI_DISCLOSED,
    COI_NOT_STATED,
    LEGACY_ANALYZER_VERSION,
    TransparencyCounts,
    TransparencyResult,
    TransparencyRisk,
    count_transparency_over,
    get_default_settings,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    ReportRiskThreshold,
    TransparencySettings,
)
from bmlibrarian_lite.transparency_terms import ScoreComponent


def _row(**changes) -> TransparencyResult:
    """Build a current, full-text, high-risk stored result to vary from."""
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
    """The reference list's per-citation risk annotation (#386)."""

    def test_a_limited_rating_says_so(self) -> None:
        """A rating made without the full text carries the certainty note."""
        annotation = format_reference_risk_annotation(_row(full_text_analyzed=False))
        assert "    - Limited certainty because of lack of full text access" in annotation.split("\n")

    def test_the_provisional_line_is_the_shared_caveat(self) -> None:
        """The provisional line is the caveat shared with the badge and section."""
        annotation = format_reference_risk_annotation(_row(sources_unreachable=True))
        assert (
            "    - A source this analysis needed could not be read, so the rating is "
            "provisional: it rests on less than the full record. Re-analyse the study "
            "before relying on it."
        ) in annotation.split("\n")


class TestTheHighRiskSection:
    """The section explaining every cited study rated high risk (#386)."""

    def test_absent_when_no_study_is_high(self) -> None:
        """Review focus 5: no heading, no introduction."""
        assert format_high_risk_section([], get_default_settings()) == ""

    def test_one_study(self) -> None:
        """A single high-risk study is explained by its matching rule."""
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
        """A study rated high on score alone also shows its score breakdown."""
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
    """``TransparencyCounts`` also tracks limited and provisional ratings (#386)."""

    def test_limited_and_provisional_are_counted_among_the_assessed(self) -> None:
        """Both are a share of ``assessed``, not a separate population."""
        rows = {
            "a": _row(document_id="a", full_text_analyzed=False),
            "b": _row(document_id="b", sources_unreachable=True),
            "c": _row(document_id="c", risk_level=TransparencyRisk.LOW),
        }
        counts = count_transparency_over(rows, ["a", "b", "c"])
        assert (counts.assessed, counts.limited, counts.provisional) == (3, 1, 1)
        assert counts.considered == 3

    def test_more_limited_than_assessed_is_refused(self) -> None:
        """A count that could not have come from real rows is rejected."""
        with pytest.raises(ValueError):
            TransparencyCounts(low=1, limited=2)


def _metadata(
    *, low: int, medium: int, high: int, limited: int, provisional: int
) -> ReportMetadata:
    """Build methodology-section metadata, as ``test_methodology_total_bound.py`` does."""
    return ReportMetadata(
        transparency_analysis_applied=True,
        transparency_low_risk_count=low,
        transparency_medium_risk_count=medium,
        transparency_high_risk_count=high,
        transparency_limited_count=limited,
        transparency_provisional_count=provisional,
        transparency_documents_considered=low + medium + high,
    )


@pytest.fixture
def agent() -> LiteReportingAgent:
    """A reporting agent with a mocked config, as the methodology needs none of it."""
    return LiteReportingAgent(config=MagicMock())


class TestTheMethodology:
    """The methodology section names limited and provisional ratings (#386)."""

    def test_names_the_limited_ratings(self, agent: LiteReportingAgent) -> None:
        """A limited count is reported against the analysed total."""
        metadata = _metadata(low=1, medium=1, high=1, limited=2, provisional=0)
        text = agent.format_methodology_section(metadata)
        assert (
            "- **Limited certainty:** 2 of 3 ratings were made without the full "
            "text. Limited certainty because of lack of full text access."
        ) in text.split("\n")

    def test_names_the_provisional_ratings(self, agent: LiteReportingAgent) -> None:
        """A provisional count is reported against the analysed total."""
        metadata = _metadata(low=1, medium=1, high=1, limited=0, provisional=1)
        text = agent.format_methodology_section(metadata)
        assert (
            "- **Provisional:** 1 of 3 ratings were made while a source the "
            "analysis needed could not be read, so each rests on less than the "
            "full record. Re-analyse them before relying on them."
        ) in text.split("\n")

    def test_silent_when_every_rating_had_full_text(self, agent: LiteReportingAgent) -> None:
        """Neither line appears when nothing is limited or provisional."""
        text = agent.format_methodology_section(
            _metadata(low=1, medium=1, high=1, limited=0, provisional=0)
        )
        assert "Limited certainty" not in text
        assert "Provisional" not in text


class TestGenerateReportHighRiskSection:
    """``generate_report`` appends the high-risk section for shown Highs only (#386)."""

    @pytest.fixture
    def mock_config(self):
        """A config carrying default transparency settings, as in the risk-warning tests."""
        config = MagicMock()
        config.transparency = TransparencySettings(
            enabled=True,
            report_risk_threshold=ReportRiskThreshold.HIGH,
        )
        return config

    @patch.object(LiteReportingAgent, "_chat")
    def test_lists_the_current_high_only(self, mock_chat, mock_config) -> None:
        """The current High is explained; the superseded High and the Low are not."""
        documents = [
            LiteDocument(
                id="pmid-high",
                title="High Risk Study",
                authors=["Smith J"],
                year=2023,
                pmid="high",
                journal="Test Journal",
                abstract="Abstract of the high risk study.",
            ),
            LiteDocument(
                id="pmid-low",
                title="Low Risk Study",
                authors=["Jones B"],
                year=2024,
                pmid="low",
                journal="Test Journal",
                abstract="Abstract of the low risk study.",
            ),
            LiteDocument(
                id="pmid-superseded",
                title="Superseded High Risk Study",
                authors=["Lee C"],
                year=2020,
                pmid="superseded",
                journal="Test Journal",
                abstract="Abstract of the superseded study.",
            ),
        ]
        citations = [
            Citation(document=documents[0], passage="Passage one.", relevance_score=5),
            Citation(document=documents[1], passage="Passage two.", relevance_score=5),
            Citation(document=documents[2], passage="Passage three.", relevance_score=5),
        ]
        mock_chat.return_value = (
            "Finding one [Smith, 2023](docid:pmid-high). "
            "Finding two [Jones, 2024](docid:pmid-low). "
            "Finding three [Lee, 2020](docid:pmid-superseded)."
        )
        transparency_results = {
            "pmid-high": TransparencyResult(
                document_id="pmid-high",
                transparency_score=40,
                risk_level=TransparencyRisk.HIGH,
                coi_disclosure=COI_NOT_STATED,
                full_text_analyzed=True,
            ),
            "pmid-low": TransparencyResult(
                document_id="pmid-low",
                transparency_score=85,
                risk_level=TransparencyRisk.LOW,
                coi_disclosure=COI_DISCLOSED,
                full_text_analyzed=True,
            ),
            "pmid-superseded": TransparencyResult(
                document_id="pmid-superseded",
                transparency_score=20,
                risk_level=TransparencyRisk.HIGH,
                coi_disclosure=COI_NOT_STATED,
                full_text_analyzed=True,
                analyzer_version=LEGACY_ANALYZER_VERSION,
            ),
        }

        agent = LiteReportingAgent(config=mock_config)
        report = agent.generate_report(
            question="Test question",
            citations=citations,
            transparency_results=transparency_results,
            metadata=ReportMetadata(),
        )

        heading = "## Why Studies Were Rated High Transparency Risk"
        assert report.count(heading) == 1

        references_index = report.index("## References")
        heading_index = report.index(heading)
        methodology_index = report.index("## Methodology")
        assert references_index < heading_index < methodology_index

        # Citation order (Smith, Jones, Lee) gives Smith reference number 1.
        section = report[heading_index:methodology_index]
        assert "**1. Smith, 2023**" in section
        assert "Lee, 2020" not in section
        assert "Jones, 2024" not in section
