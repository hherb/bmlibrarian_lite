# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for risk warnings integration in reporting agent."""

from unittest.mock import MagicMock, patch

import pytest

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.data_models import Citation, LiteDocument
from bmlibrarian_lite.transparency.transparency_models import (
    TransparencyResult,
    TransparencyRisk,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    ReportRiskThreshold,
    TransparencySettings,
)


@pytest.fixture
def mock_config():
    """Create mock config with transparency settings."""
    config = MagicMock()
    config.transparency = TransparencySettings(
        enabled=True,
        report_risk_threshold=ReportRiskThreshold.HIGH,
    )
    return config


@pytest.fixture
def sample_documents():
    """Create sample documents."""
    return [
        LiteDocument(
            id="pmid-12345",
            title="Industry Funded Study",
            authors=["Smith J", "Doe A"],
            year=2023,
            pmid="12345",
            journal="Test Journal",
            abstract="This is the abstract of the industry funded study.",
        ),
        LiteDocument(
            id="pmid-67890",
            title="Independent Study",
            authors=["Jones B"],
            year=2024,
            pmid="67890",
            journal="Other Journal",
            abstract="This is the abstract of the independent study.",
        ),
    ]


@pytest.fixture
def sample_citations(sample_documents):
    """Create sample citations."""
    return [
        Citation(
            document=sample_documents[0],
            passage="This study found significant results.",
            relevance_score=4,
        ),
        Citation(
            document=sample_documents[1],
            passage="Independent verification confirmed findings.",
            relevance_score=5,
        ),
    ]


@pytest.fixture
def high_risk_transparency():
    """High-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-12345",
        transparency_score=30,
        risk_level=TransparencyRisk.HIGH,
        industry_funding_detected=True,
        industry_funding_confidence=0.95,
        coi_disclosed=False,
    )


@pytest.fixture
def low_risk_transparency():
    """Low-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-67890",
        transparency_score=85,
        risk_level=TransparencyRisk.LOW,
        coi_disclosed=True,
    )


class TestReportingAgentRiskWarnings:
    """Tests for risk warning integration."""

    @patch.object(LiteReportingAgent, "_chat")
    def test_generate_report_with_transparency_results(
        self,
        mock_chat,
        mock_config,
        sample_citations,
        high_risk_transparency,
        low_risk_transparency,
    ):
        """Report includes risk warnings when transparency results provided."""
        mock_chat.return_value = (
            "The study [Smith et al., 2023](docid:pmid-12345) found results. "
            "Jones [Jones, 2024](docid:pmid-67890) confirmed."
        )

        agent = LiteReportingAgent(config=mock_config)
        transparency_results = {
            "pmid-12345": high_risk_transparency,
            "pmid-67890": low_risk_transparency,
        }

        report = agent.generate_report(
            question="Test question",
            citations=sample_citations,
            transparency_results=transparency_results,
        )

        # High-risk citation should have warning in references
        assert "HIGH RISK" in report
        # Low-risk should not have warning
        assert "pmid-67890" in report

    @patch.object(LiteReportingAgent, "_chat")
    def test_llm_prompt_includes_risk_context(
        self,
        mock_chat,
        mock_config,
        sample_citations,
        high_risk_transparency,
    ):
        """LLM prompt includes risk context section."""
        mock_chat.return_value = "Test report [Smith et al., 2023](docid:pmid-12345)."

        agent = LiteReportingAgent(config=mock_config)
        transparency_results = {"pmid-12345": high_risk_transparency}

        agent.generate_report(
            question="Test question",
            citations=sample_citations,
            transparency_results=transparency_results,
        )

        # Check that the prompt included risk context
        call_args = mock_chat.call_args
        messages = call_args[0][0]  # First positional arg
        user_message = messages[1].content  # LLMMessage has content attribute
        assert "Transparency Concerns" in user_message

    @patch.object(LiteReportingAgent, "_chat")
    def test_respects_risk_threshold_setting(
        self,
        mock_chat,
        mock_config,
        sample_citations,
    ):
        """Only warns for citations meeting threshold."""
        # Set to HIGH threshold - medium risk should not warn
        mock_config.transparency.report_risk_threshold = ReportRiskThreshold.HIGH

        medium_risk = TransparencyResult(
            document_id="pmid-12345",
            transparency_score=55,
            risk_level=TransparencyRisk.MEDIUM,
            industry_funding_detected=True,
        )

        mock_chat.return_value = "Report [Smith et al., 2023](docid:pmid-12345)."

        agent = LiteReportingAgent(config=mock_config)
        transparency_results = {"pmid-12345": medium_risk}

        report = agent.generate_report(
            question="Test question",
            citations=sample_citations,
            transparency_results=transparency_results,
        )

        # Medium risk with HIGH threshold should not show warning
        assert "HIGH RISK" not in report

    @patch.object(LiteReportingAgent, "_chat")
    def test_annotated_references_format(
        self,
        mock_chat,
        mock_config,
        sample_citations,
        high_risk_transparency,
    ):
        """References section shows structured risk details."""
        mock_chat.return_value = "Report [Smith et al., 2023](docid:pmid-12345)."

        agent = LiteReportingAgent(config=mock_config)
        transparency_results = {"pmid-12345": high_risk_transparency}

        report = agent.generate_report(
            question="Test question",
            citations=sample_citations,
            transparency_results=transparency_results,
        )

        # Check for structured annotation
        assert "HIGH RISK" in report
        assert "Funding:" in report or "Industry" in report
        assert "COI" in report
