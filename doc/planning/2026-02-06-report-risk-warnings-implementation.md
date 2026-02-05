# Report Risk Warnings Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Enhance the report generator to surface transparency/risk concerns for high-risk citations with inline warnings and annotated references.

**Architecture:** Add configurable risk threshold settings, enhance LLM prompt with risk context, post-process narrative to inject inline warning markers, and generate annotated references with structured risk details.

**Tech Stack:** Python 3.12, dataclasses, existing TransparencyResult/TransparencyRisk models

---

## Task 1: Add Report Risk Settings to TransparencySettings

**Files:**
- Modify: `src/bmlibrarian_lite/transparency/transparency_settings.py`
- Test: `tests/test_report_risk_settings.py`

**Step 1: Write the failing test**

Create `tests/test_report_risk_settings.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for report risk warning settings."""

import pytest
from bmlibrarian_lite.transparency.transparency_settings import (
    TransparencySettings,
    ReportRiskThreshold,
    DEFAULT_INLINE_WARNING_TEMPLATES,
)


def test_report_risk_threshold_enum_values():
    """ReportRiskThreshold enum has expected values."""
    assert ReportRiskThreshold.HIGH.value == "high"
    assert ReportRiskThreshold.MEDIUM.value == "medium"
    assert ReportRiskThreshold.LOW.value == "low"


def test_default_inline_warning_templates():
    """Default warning templates contain expected keys."""
    assert "industry_funding" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "missing_coi" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "missing_results" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "data_not_available" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "multiple_risks" in DEFAULT_INLINE_WARNING_TEMPLATES


def test_transparency_settings_has_report_risk_fields():
    """TransparencySettings has report risk warning fields."""
    settings = TransparencySettings()
    assert hasattr(settings, "report_risk_threshold")
    assert hasattr(settings, "inline_warning_templates")
    assert settings.report_risk_threshold == ReportRiskThreshold.HIGH


def test_transparency_settings_serialization_with_report_risk():
    """Settings serialize and deserialize report risk fields."""
    settings = TransparencySettings(
        report_risk_threshold=ReportRiskThreshold.MEDIUM,
    )
    data = settings.to_dict()
    assert data["report_risk_threshold"] == "medium"

    restored = TransparencySettings.from_dict(data)
    assert restored.report_risk_threshold == ReportRiskThreshold.MEDIUM
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_report_risk_settings.py -v`
Expected: FAIL with "cannot import name 'ReportRiskThreshold'"

**Step 3: Write minimal implementation**

Modify `src/bmlibrarian_lite/transparency/transparency_settings.py`:

Add after line 17 (after docstring):

```python
from enum import Enum


class ReportRiskThreshold(Enum):
    """Threshold for which risk levels trigger warnings in reports."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


DEFAULT_INLINE_WARNING_TEMPLATES: dict[str, str] = {
    "industry_funding": "⚠️ funding concerns",
    "missing_coi": "⚠️ COI not disclosed",
    "missing_results": "⚠️ results not posted",
    "data_not_available": "⚠️ data not shared",
    "multiple_risks": "⚠️ transparency concerns",
}
```

Add to `TransparencySettings` dataclass (after `show_detailed_tooltip` field):

```python
    # Report risk warning settings
    report_risk_threshold: ReportRiskThreshold = ReportRiskThreshold.HIGH
    inline_warning_templates: dict[str, str] = field(
        default_factory=lambda: DEFAULT_INLINE_WARNING_TEMPLATES.copy()
    )
```

Update `to_dict()` method to add:

```python
            "report_risk_threshold": self.report_risk_threshold.value,
            "inline_warning_templates": self.inline_warning_templates,
```

Update `from_dict()` method to add:

```python
            report_risk_threshold=ReportRiskThreshold(
                data.get("report_risk_threshold", "high")
            ),
            inline_warning_templates=data.get(
                "inline_warning_templates", DEFAULT_INLINE_WARNING_TEMPLATES.copy()
            ),
```

Also add `field` import at top:

```python
from dataclasses import dataclass, field
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_report_risk_settings.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add src/bmlibrarian_lite/transparency/transparency_settings.py tests/test_report_risk_settings.py
git commit -m "feat(transparency): Add report risk warning settings

Add ReportRiskThreshold enum and inline_warning_templates to
TransparencySettings for configurable risk warnings in reports.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 2: Add Risk Warning Helper Functions

**Files:**
- Create: `src/bmlibrarian_lite/agents/report_risk_helpers.py`
- Test: `tests/test_report_risk_helpers.py`

**Step 1: Write the failing test**

Create `tests/test_report_risk_helpers.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for report risk warning helper functions."""

import pytest
from bmlibrarian_lite.transparency.transparency_models import (
    TransparencyResult,
    TransparencyRisk,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    TransparencySettings,
    ReportRiskThreshold,
    DEFAULT_INLINE_WARNING_TEMPLATES,
)
from bmlibrarian_lite.agents.report_risk_helpers import (
    select_inline_warning,
    should_warn_for_citation,
    build_risk_context_for_prompt,
    inject_risk_warnings,
    format_reference_risk_annotation,
)


@pytest.fixture
def high_risk_result():
    """Create a high-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-12345",
        transparency_score=30,
        risk_level=TransparencyRisk.HIGH,
        industry_funding_detected=True,
        industry_funding_confidence=0.95,
        coi_disclosed=False,
        trial_results_compliant=False,
        risk_indicators=["Industry funding detected", "COI not disclosed"],
    )


@pytest.fixture
def medium_risk_result():
    """Create a medium-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-67890",
        transparency_score=55,
        risk_level=TransparencyRisk.MEDIUM,
        industry_funding_detected=True,
        industry_funding_confidence=0.8,
        coi_disclosed=True,
        data_availability_level="on_request",
    )


@pytest.fixture
def low_risk_result():
    """Create a low-risk transparency result."""
    return TransparencyResult(
        document_id="pmid-11111",
        transparency_score=85,
        risk_level=TransparencyRisk.LOW,
        coi_disclosed=True,
        data_availability_level="full_open",
    )


class TestSelectInlineWarning:
    """Tests for select_inline_warning function."""

    def test_multiple_risk_factors_returns_generic(self, high_risk_result):
        """Multiple risk factors use generic warning."""
        warning = select_inline_warning(
            high_risk_result, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        assert warning == "⚠️ transparency concerns"

    def test_single_industry_funding(self, medium_risk_result):
        """Single industry funding risk uses specific warning."""
        # Only one major risk factor
        result = TransparencyResult(
            document_id="test",
            transparency_score=60,
            risk_level=TransparencyRisk.MEDIUM,
            industry_funding_detected=True,
            coi_disclosed=True,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ funding concerns"

    def test_single_missing_coi(self):
        """Missing COI uses specific warning."""
        result = TransparencyResult(
            document_id="test",
            transparency_score=50,
            risk_level=TransparencyRisk.HIGH,
            coi_disclosed=False,
        )
        warning = select_inline_warning(result, DEFAULT_INLINE_WARNING_TEMPLATES)
        assert warning == "⚠️ COI not disclosed"


class TestShouldWarnForCitation:
    """Tests for should_warn_for_citation function."""

    def test_high_threshold_only_warns_high(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """HIGH threshold only warns for HIGH risk."""
        settings = TransparencySettings(report_risk_threshold=ReportRiskThreshold.HIGH)
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is False
        assert should_warn_for_citation(low_risk_result, settings) is False

    def test_medium_threshold_warns_medium_and_high(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """MEDIUM threshold warns for MEDIUM and HIGH risk."""
        settings = TransparencySettings(
            report_risk_threshold=ReportRiskThreshold.MEDIUM
        )
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is True
        assert should_warn_for_citation(low_risk_result, settings) is False

    def test_low_threshold_warns_all(
        self, high_risk_result, medium_risk_result, low_risk_result
    ):
        """LOW threshold warns for all risk levels."""
        settings = TransparencySettings(report_risk_threshold=ReportRiskThreshold.LOW)
        assert should_warn_for_citation(high_risk_result, settings) is True
        assert should_warn_for_citation(medium_risk_result, settings) is True
        assert should_warn_for_citation(low_risk_result, settings) is True


class TestBuildRiskContextForPrompt:
    """Tests for build_risk_context_for_prompt function."""

    def test_builds_context_for_risky_citations(self, high_risk_result):
        """Builds risk context section for LLM prompt."""
        risky_citations = {
            1: ("Smith et al., 2023", high_risk_result),
        }
        context = build_risk_context_for_prompt(risky_citations)
        assert "Studies with Transparency Concerns" in context
        assert "Smith et al., 2023" in context
        assert "Industry funding" in context or "funding" in context.lower()

    def test_empty_context_for_no_risky_citations(self):
        """Returns empty string when no risky citations."""
        context = build_risk_context_for_prompt({})
        assert context == ""


class TestInjectRiskWarnings:
    """Tests for inject_risk_warnings function."""

    def test_injects_warning_at_first_occurrence(self, high_risk_result):
        """Injects warning only at first citation occurrence."""
        narrative = "The study [1] found significant results. Later, [1] confirmed this."
        risky_citations = {1: high_risk_result}
        result = inject_risk_warnings(
            narrative, risky_citations, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        # First occurrence should have warning
        assert "(⚠️" in result
        # Count warnings - should only be one
        assert result.count("(⚠️") == 1

    def test_does_not_modify_non_risky_citations(self, high_risk_result):
        """Does not modify citations not in risky list."""
        narrative = "Study [1] and study [2] both found results."
        risky_citations = {1: high_risk_result}
        result = inject_risk_warnings(
            narrative, risky_citations, DEFAULT_INLINE_WARNING_TEMPLATES
        )
        assert "[2]" in result
        assert "[2] (⚠️" not in result


class TestFormatReferenceRiskAnnotation:
    """Tests for format_reference_risk_annotation function."""

    def test_formats_high_risk_with_details(self, high_risk_result):
        """Formats high-risk reference with structured details."""
        annotation = format_reference_risk_annotation(high_risk_result)
        assert "⚠️ HIGH RISK" in annotation
        assert "Funding:" in annotation or "Industry" in annotation.lower()
        assert "COI" in annotation

    def test_formats_medium_risk(self, medium_risk_result):
        """Formats medium-risk reference."""
        annotation = format_reference_risk_annotation(medium_risk_result)
        assert "⚠️ MEDIUM RISK" in annotation

    def test_returns_empty_for_low_risk(self, low_risk_result):
        """Returns empty string for low-risk results."""
        annotation = format_reference_risk_annotation(low_risk_result)
        assert annotation == ""
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_report_risk_helpers.py -v`
Expected: FAIL with "No module named 'bmlibrarian_lite.agents.report_risk_helpers'"

**Step 3: Write minimal implementation**

Create `src/bmlibrarian_lite/agents/report_risk_helpers.py`:

```python
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

"""Helper functions for report risk warnings."""

import re
from typing import Optional

from ..transparency.transparency_models import TransparencyResult, TransparencyRisk
from ..transparency.transparency_settings import (
    TransparencySettings,
    ReportRiskThreshold,
)


def select_inline_warning(
    result: TransparencyResult,
    templates: dict[str, str],
) -> str:
    """
    Select appropriate inline warning text based on risk factors.

    If multiple risk factors are present, uses the generic "transparency concerns"
    warning. Otherwise uses the specific warning for the single factor.

    Args:
        result: Transparency analysis result
        templates: Warning template dictionary

    Returns:
        Inline warning text
    """
    risk_factors = []

    if result.industry_funding_detected:
        risk_factors.append("industry_funding")
    if not result.coi_disclosed:
        risk_factors.append("missing_coi")
    if result.trial_registered and not result.trial_results_compliant:
        risk_factors.append("missing_results")
    if result.data_availability_level in ("not_available", "restricted", "not_stated"):
        risk_factors.append("data_not_available")

    if len(risk_factors) > 1:
        return templates.get("multiple_risks", "⚠️ transparency concerns")
    elif len(risk_factors) == 1:
        return templates.get(risk_factors[0], "⚠️ transparency concerns")
    else:
        # Fallback for high-risk score without specific factors
        return templates.get("multiple_risks", "⚠️ transparency concerns")


def should_warn_for_citation(
    result: TransparencyResult,
    settings: TransparencySettings,
) -> bool:
    """
    Determine if a citation should receive a warning based on threshold.

    Args:
        result: Transparency analysis result
        settings: Transparency settings with threshold

    Returns:
        True if citation should be warned
    """
    threshold = settings.report_risk_threshold

    if threshold == ReportRiskThreshold.HIGH:
        return result.risk_level == TransparencyRisk.HIGH
    elif threshold == ReportRiskThreshold.MEDIUM:
        return result.risk_level in (TransparencyRisk.HIGH, TransparencyRisk.MEDIUM)
    else:  # LOW
        return result.risk_level in (
            TransparencyRisk.HIGH,
            TransparencyRisk.MEDIUM,
            TransparencyRisk.LOW,
        )


def build_risk_context_for_prompt(
    risky_citations: dict[int, tuple[str, TransparencyResult]],
) -> str:
    """
    Build risk context section for LLM prompt.

    Informs the LLM about which citations have transparency concerns
    so it can write balanced assessments.

    Args:
        risky_citations: Dict mapping citation number to (author_ref, result)

    Returns:
        Formatted risk context section, or empty string if no risky citations
    """
    if not risky_citations:
        return ""

    lines = [
        "",
        "## Studies with Transparency Concerns",
        "The following cited studies have elevated risk factors that readers "
        "should be aware of:",
    ]

    for citation_num, (author_ref, result) in risky_citations.items():
        concerns = []
        if result.industry_funding_detected:
            concerns.append("Industry funding detected")
        if not result.coi_disclosed:
            concerns.append("Conflicts of interest not disclosed")
        if result.trial_registered and not result.trial_results_compliant:
            concerns.append("Trial results not posted to registry")
        if result.data_availability_level in (
            "not_available",
            "restricted",
            "not_stated",
        ):
            concerns.append(f"Data availability: {result.data_availability_level}")

        concerns_str = ", ".join(concerns) if concerns else "Low transparency score"
        lines.append(f"- [Citation {citation_num}] {author_ref}: {concerns_str}")

    lines.extend([
        "",
        "When discussing findings from these studies, consider their limitations "
        "in context.",
        "Do not add warning markers yourself - these will be added automatically.",
        "",
    ])

    return "\n".join(lines)


def inject_risk_warnings(
    narrative: str,
    risky_citations: dict[int, TransparencyResult],
    templates: dict[str, str],
) -> str:
    """
    Inject inline warning markers at first occurrence of risky citations.

    Scans the narrative for citation markers like [1], [2] and appends
    the appropriate warning after the first occurrence only.

    Args:
        narrative: Generated report narrative
        risky_citations: Dict mapping citation number to transparency result
        templates: Warning template dictionary

    Returns:
        Narrative with injected warnings
    """
    result = narrative

    for citation_num, transparency_result in risky_citations.items():
        pattern = f"[{citation_num}]"
        if pattern in result:
            warning = select_inline_warning(transparency_result, templates)
            replacement = f"[{citation_num}] ({warning})"
            # Replace only first occurrence
            result = result.replace(pattern, replacement, 1)

    return result


def format_reference_risk_annotation(
    result: TransparencyResult,
) -> str:
    """
    Format risk annotation for reference list entry.

    Creates structured sub-items showing specific risk factors
    for HIGH and MEDIUM risk citations.

    Args:
        result: Transparency analysis result

    Returns:
        Formatted annotation string, or empty string for low risk
    """
    if result.risk_level == TransparencyRisk.LOW:
        return ""

    risk_label = result.risk_level.value.upper()
    lines = [f"    ⚠️ {risk_label} RISK"]

    if result.industry_funding_detected:
        confidence_pct = int(result.industry_funding_confidence * 100)
        lines.append(f"    • Funding: Industry-funded (confidence: {confidence_pct}%)")

    if not result.coi_disclosed:
        lines.append("    • COI disclosure: Not stated")

    if result.trial_registered and not result.trial_results_compliant:
        lines.append("    • Trial results: Not posted to registry")

    if result.data_availability_level in ("not_available", "restricted", "not_stated"):
        level_display = result.data_availability_level.replace("_", " ").title()
        lines.append(f"    • Data availability: {level_display}")

    if result.outcome_switching_detected:
        lines.append("    • Outcome switching: Detected")

    return "\n".join(lines)
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_report_risk_helpers.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add src/bmlibrarian_lite/agents/report_risk_helpers.py tests/test_report_risk_helpers.py
git commit -m "feat(reporting): Add risk warning helper functions

Add helper functions for selecting inline warnings, building LLM
prompt context, injecting warnings into narrative, and formatting
annotated references with risk details.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 3: Integrate Risk Warnings into Reporting Agent

**Files:**
- Modify: `src/bmlibrarian_lite/agents/reporting_agent.py`
- Test: `tests/test_reporting_agent_risk_warnings.py`

**Step 1: Write the failing test**

Create `tests/test_reporting_agent_risk_warnings.py`:

```python
# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for risk warnings integration in reporting agent."""

import pytest
from unittest.mock import MagicMock, patch
from datetime import datetime

from bmlibrarian_lite.agents.reporting_agent import LiteReportingAgent
from bmlibrarian_lite.data_models import Citation, LiteDocument, ReportMetadata
from bmlibrarian_lite.transparency.transparency_models import (
    TransparencyResult,
    TransparencyRisk,
)
from bmlibrarian_lite.transparency.transparency_settings import (
    TransparencySettings,
    ReportRiskThreshold,
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
        ),
        LiteDocument(
            id="pmid-67890",
            title="Independent Study",
            authors=["Jones B"],
            year=2024,
            pmid="67890",
            journal="Other Journal",
        ),
    ]


@pytest.fixture
def sample_citations(sample_documents):
    """Create sample citations."""
    return [
        Citation(
            document=sample_documents[0],
            passage="This study found significant results.",
            formatted_reference="Smith et al., 2023",
        ),
        Citation(
            document=sample_documents[1],
            passage="Independent verification confirmed findings.",
            formatted_reference="Jones, 2024",
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
        assert "⚠️ HIGH RISK" in report
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
        user_message = messages[1]["content"]
        assert "Transparency Concerns" in user_message

    @patch.object(LiteReportingAgent, "_chat")
    def test_respects_risk_threshold_setting(
        self,
        mock_chat,
        mock_config,
        sample_citations,
        high_risk_transparency,
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
        assert "⚠️" not in report

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
        assert "⚠️ HIGH RISK" in report
        assert "Funding:" in report or "Industry" in report
        assert "COI" in report
```

**Step 2: Run test to verify it fails**

Run: `pytest tests/test_reporting_agent_risk_warnings.py -v`
Expected: FAIL with "generate_report() got an unexpected keyword argument 'transparency_results'"

**Step 3: Write minimal implementation**

Modify `src/bmlibrarian_lite/agents/reporting_agent.py`:

Add imports after line 28:

```python
from .report_risk_helpers import (
    build_risk_context_for_prompt,
    format_reference_risk_annotation,
    should_warn_for_citation,
)
from ..transparency.transparency_models import TransparencyResult
```

Modify `generate_report` method signature (around line 74):

```python
    def generate_report(
        self,
        question: str,
        citations: list[Citation],
        metadata: Optional[ReportMetadata] = None,
        transparency_results: Optional[dict[str, TransparencyResult]] = None,
    ) -> str:
```

Update docstring:

```python
        """
        Generate a research report from citations.

        Args:
            question: Research question
            citations: List of citations to synthesize
            metadata: Optional report metadata for methodology section
            transparency_results: Optional dict mapping document_id to TransparencyResult

        Returns:
            Formatted research report as markdown
        """
```

After line 109 (`unique_doc_ids = set(c.document.id for c in citations)`), add:

```python
        # Identify risky citations based on threshold
        risky_citations: dict[int, tuple[str, TransparencyResult]] = {}
        risky_doc_ids: dict[str, TransparencyResult] = {}
        if transparency_results and self.config.transparency.enabled:
            # Build mapping of doc_id to citation number and reference
            doc_to_citation: dict[str, tuple[int, str]] = {}
            citation_num = 1
            for doc_id in doc_order:
                citation_list = doc_passages[doc_id]
                short_ref = citation_list[0].formatted_reference
                doc_to_citation[doc_id] = (citation_num, short_ref)
                citation_num += 1

            for doc_id, result in transparency_results.items():
                if doc_id in doc_to_citation and should_warn_for_citation(
                    result, self.config.transparency
                ):
                    num, ref = doc_to_citation[doc_id]
                    risky_citations[num] = (ref, result)
                    risky_doc_ids[doc_id] = result

        # Build risk context for LLM prompt
        risk_context = build_risk_context_for_prompt(risky_citations)
```

Wait - we need to look at the code more carefully. The `doc_order` and `doc_passages` are created in `_format_citations_for_prompt`. Let me revise the approach.

Actually, the better approach is to compute the doc ordering before calling `_format_citations_for_prompt` and pass the risk context into the prompt. Let me revise:

Modify `generate_report` method (replace lines 105-146):

```python
        # Format citations for the prompt
        formatted_citations = self._format_citations_for_prompt(citations)

        # Count unique documents and build doc_id to citation number mapping
        doc_order: list[str] = []
        doc_to_ref: dict[str, str] = {}
        for citation in citations:
            doc_id = citation.document.id
            if doc_id not in doc_to_ref:
                doc_order.append(doc_id)
                doc_to_ref[doc_id] = citation.formatted_reference

        # Identify risky citations based on threshold
        risky_citations: dict[int, tuple[str, TransparencyResult]] = {}
        risky_doc_results: dict[str, TransparencyResult] = {}
        if transparency_results and self.config.transparency.enabled:
            for i, doc_id in enumerate(doc_order, 1):
                if doc_id in transparency_results:
                    result = transparency_results[doc_id]
                    if should_warn_for_citation(result, self.config.transparency):
                        risky_citations[i] = (doc_to_ref[doc_id], result)
                        risky_doc_results[doc_id] = result

        # Build risk context for LLM prompt
        risk_context = build_risk_context_for_prompt(risky_citations)

        user_prompt = f"""Research Question: {question}

Evidence from {len(doc_order)} source(s) ({len(citations)} passages total):

{formatted_citations}
{risk_context}
Write a comprehensive research summary that synthesizes this evidence to answer the research question.

CITATION FORMAT - MANDATORY:
- Use this exact format: [Source](docid:Document ID)
- Copy the "Source:" value as the link text
- Copy the "Document ID:" value as the docid
- Example: [Smith et al., 2023](docid:pmid-12345678)

IMPORTANT: Use ONLY the exact Source and Document ID values provided above. Do not invent IDs."""

        messages = [
            self._create_system_message(REPORTING_SYSTEM_PROMPT),
            self._create_user_message(user_prompt),
        ]

        try:
            report = self._chat(messages, temperature=0.3, max_tokens=4096)

            # Add references section with risk annotations
            references = self._format_references_with_risk(
                citations, risky_doc_results
            )
            full_report = f"{report}\n\n## References\n\n{references}"

            # Add methodology section if metadata provided
            if metadata:
                full_report += "\n\n" + self.format_methodology_section(metadata)

            return full_report

        except Exception as e:
            logger.error(f"Failed to generate report: {e}")
            return f"Error generating report: {str(e)}"
```

Add new method `_format_references_with_risk` after `_format_references`:

```python
    def _format_references_with_risk(
        self,
        citations: list[Citation],
        risky_doc_results: dict[str, TransparencyResult],
    ) -> str:
        """
        Format reference list with risk annotations for risky citations.

        Args:
            citations: List of citations
            risky_doc_results: Dict mapping doc_id to TransparencyResult for risky docs

        Returns:
            Formatted reference list with risk annotations
        """
        # Deduplicate by document ID
        seen: set[str] = set()
        unique_citations = []
        for citation in citations:
            if citation.document.id not in seen:
                seen.add(citation.document.id)
                unique_citations.append(citation)

        references = []
        for i, citation in enumerate(unique_citations, 1):
            doc = citation.document
            ref = f"{i}. {doc.formatted_authors}"
            if doc.year:
                ref += f" ({doc.year})"
            ref += f". {doc.title}"
            if doc.journal:
                ref += f". *{doc.journal}*"
            if doc.doi:
                ref += f". DOI: {doc.doi}"
            if doc.pmid:
                ref += f". PMID: {doc.pmid}"

            # Add risk annotation if this doc is risky
            if doc.id in risky_doc_results:
                annotation = format_reference_risk_annotation(risky_doc_results[doc.id])
                if annotation:
                    ref += f"\n{annotation}"

            references.append(ref)

        return "\n\n".join(references)
```

**Step 4: Run test to verify it passes**

Run: `pytest tests/test_reporting_agent_risk_warnings.py -v`
Expected: PASS

**Step 5: Commit**

```bash
git add src/bmlibrarian_lite/agents/reporting_agent.py tests/test_reporting_agent_risk_warnings.py
git commit -m "feat(reporting): Integrate risk warnings into report generation

- Add transparency_results parameter to generate_report()
- Include risk context in LLM prompt for balanced writing
- Generate annotated references with structured risk details

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 4: Update Systematic Review Tab to Pass Transparency Results

**Files:**
- Modify: `src/bmlibrarian_lite/gui/systematic_review_tab.py`
- No new test file needed (integration tested via existing workflow)

**Step 1: Identify change location**

The change is at line 388-389 in `systematic_review_tab.py`:

```python
            reporting_agent = LiteReportingAgent(config=self.config)
            report = reporting_agent.generate_report(self.question, citations, metadata)
```

**Step 2: Make the modification**

Change to:

```python
            # Gather transparency results for cited documents
            cited_doc_ids = list(set(c.document.id for c in citations))
            transparency_results = self.storage.get_transparency_results_batch(
                cited_doc_ids
            )

            reporting_agent = LiteReportingAgent(config=self.config)
            report = reporting_agent.generate_report(
                self.question,
                citations,
                metadata,
                transparency_results=transparency_results,
            )
```

**Step 3: Run existing tests**

Run: `pytest tests/ -v -k "systematic or review"`
Expected: PASS (or skip if no specific tests exist)

**Step 4: Commit**

```bash
git add src/bmlibrarian_lite/gui/systematic_review_tab.py
git commit -m "feat(gui): Pass transparency results to report generator

Systematic review workflow now passes transparency results to the
reporting agent so risk warnings can be included in generated reports.

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Task 5: Run Full Test Suite and Verify

**Step 1: Run all tests**

Run: `pytest tests/ -v`
Expected: All tests PASS

**Step 2: Run type checking**

Run: `mypy src/bmlibrarian_lite/agents/reporting_agent.py src/bmlibrarian_lite/agents/report_risk_helpers.py src/bmlibrarian_lite/transparency/transparency_settings.py`
Expected: No errors

**Step 3: Run linting**

Run: `ruff check src/bmlibrarian_lite/agents/ src/bmlibrarian_lite/transparency/`
Expected: No errors (or fix any issues)

**Step 4: Final commit for any fixes**

If any fixes needed:
```bash
git add -A
git commit -m "fix: Address linting and type checking issues

Co-Authored-By: Claude Opus 4.5 <noreply@anthropic.com>"
```

---

## Summary

**Files created:**
- `tests/test_report_risk_settings.py`
- `tests/test_report_risk_helpers.py`
- `tests/test_reporting_agent_risk_warnings.py`
- `src/bmlibrarian_lite/agents/report_risk_helpers.py`

**Files modified:**
- `src/bmlibrarian_lite/transparency/transparency_settings.py`
- `src/bmlibrarian_lite/agents/reporting_agent.py`
- `src/bmlibrarian_lite/gui/systematic_review_tab.py`

**Total estimated lines:** ~350 new/modified
