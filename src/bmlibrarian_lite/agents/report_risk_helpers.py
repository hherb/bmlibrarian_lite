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

from ..transparency.transparency_models import TransparencyResult, TransparencyRisk
from ..transparency.transparency_settings import (
    ReportRiskThreshold,
    TransparencySettings,
)

# Data availability levels that indicate risk
RISKY_DATA_AVAILABILITY_LEVELS = ("not_available", "restricted", "not_stated")


def select_inline_warning(
    result: TransparencyResult,
    templates: dict[str, str],
) -> str:
    """Select appropriate inline warning text based on risk factors.

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
    if result.data_availability_level in RISKY_DATA_AVAILABILITY_LEVELS:
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
    """Determine if a citation should receive a warning based on threshold.

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
    """Build risk context section for LLM prompt.

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
        if result.data_availability_level in RISKY_DATA_AVAILABILITY_LEVELS:
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
    """Inject inline warning markers at first occurrence of risky citations.

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
    """Format risk annotation for reference list entry.

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
        lines.append(f"    - Funding: Industry-funded (confidence: {confidence_pct}%)")

    if not result.coi_disclosed:
        lines.append("    - COI disclosure: Not stated")

    if result.trial_registered and not result.trial_results_compliant:
        lines.append("    - Trial results: Not posted to registry")

    if result.data_availability_level in RISKY_DATA_AVAILABILITY_LEVELS:
        level_display = result.data_availability_level.replace("_", " ").title()
        lines.append(f"    - Data availability: {level_display}")

    if result.outcome_switching_detected:
        lines.append("    - Outcome switching: Detected")

    return "\n".join(lines)
