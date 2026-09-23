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

from collections.abc import Mapping, Sequence

from ..transparency.transparency_models import (
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
)
from ..transparency.transparency_settings import (
    ReportRiskThreshold,
    TransparencySettings,
)

# Data availability levels that indicate risk
RISKY_DATA_AVAILABILITY_LEVELS = ("not_available", "restricted", "not_stated")

# The risk levels a current finding can be reported under. The same three
# the report's distribution counts; any other is counted as not assessed.
NAMEABLE_RISK_LEVELS = (
    TransparencyRisk.LOW,
    TransparencyRisk.MEDIUM,
    TransparencyRisk.HIGH,
)


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
    if result.coi_disclosure == COI_NOT_STATED:
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

    A result an earlier version of the analyser produced raises no warning:
    the corrections since #352 retract findings it made, and a warning in a
    clinician's report is the last place a retracted claim should survive.
    It is re-analysed on the paced path (#360); until then there is no
    finding to warn from.

    Args:
        result: Transparency analysis result
        settings: Transparency settings with threshold

    Returns:
        True if citation should be warned
    """
    if not result.is_current:
        return False

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
        if result.coi_disclosure == COI_NOT_STATED:
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


def withheld_reference_caveats(
    doc_ids: Sequence[str],
    transparency_results: Mapping[str, TransparencyResult],
    analysis_applied: bool,
) -> dict[str, str]:
    """Say which cited studies carry no finding, and why, for their references.

    The report's "Awaiting re-analysis" and "Not assessed" lines name how
    many of each are cited; every one of those has to be findable in the
    reference list, or the count points at entries that look exactly like a
    study assessed as low risk (#372). So all three kinds are annotated, not
    only the superseded one.

    Args:
        doc_ids: The cited documents, in reference order.
        transparency_results: Their stored assessments, by document id.
        analysis_applied: Whether transparency analysis was asked for. When
            it was not, a missing row is expected and says nothing.

    Returns:
        By document id, the caveat its reference is annotated with: a row an
        earlier analyser wrote, a row at no nameable risk level, or -- when
        the analysis was asked for -- no row at all.
    """
    from ..analysis_failures import (
        no_risk_level_caveat,
        not_stored_assessment_caveat,
        superseded_assessment_caveat,
    )

    caveats: dict[str, str] = {}
    for doc_id in doc_ids:
        result = transparency_results.get(doc_id)
        if result is None:
            if analysis_applied:
                caveats[doc_id] = not_stored_assessment_caveat()
        elif not result.is_current:
            caveats[doc_id] = superseded_assessment_caveat()
        elif result.risk_level not in NAMEABLE_RISK_LEVELS:
            caveats[doc_id] = no_risk_level_caveat()
    return caveats


def format_reference_withheld_annotation(reason: str | None = None) -> str:
    """Annotate a reference whose transparency finding is being withheld.

    ``should_warn_for_citation`` answers False for a superseded row, which
    silences the inline marker, this annotation and the prompt's risk block
    at once -- so the study appeared in the reference list byte-identical to
    one this build had assessed as low risk. The aggregate "Awaiting
    re-analysis" line is counted over every document the review found, while
    the annotations follow the cited ones, so it could not be mapped onto
    any reference. A caveat elsewhere in the document does not withhold a
    claim here (#360).

    Args:
        reason: Why there is no finding; the superseded caveat when omitted.

    Returns:
        The annotation's lines, indented to match the risk annotation.
    """
    from ..analysis_failures import superseded_assessment_caveat

    return "\n".join(
        [
            "    ⚠️ TRANSPARENCY NOT ASSESSED",
            f"    - {reason or superseded_assessment_caveat()}",
        ]
    )


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

    if result.coi_disclosure == COI_NOT_STATED:
        lines.append("    - COI disclosure: Not stated")

    if result.trial_registered and not result.trial_results_compliant:
        lines.append("    - Trial results: Not posted to registry")

    if result.data_availability_level in RISKY_DATA_AVAILABILITY_LEVELS:
        level_display = result.data_availability_level.replace("_", " ").title()
        lines.append(f"    - Data availability: {level_display}")

    if result.outcome_switching_detected:
        lines.append("    - Outcome switching: Detected")

    if result.sources_unreachable:
        # The badge's tooltip shows the analysis caveats; this annotation
        # never did, so a risk level established while a source was
        # unreadable read here as firmly as one established against every
        # source (#346).
        lines.append(
            "    - Assessment is provisional: a source it needed could not "
            "be read, so this level rests on less than the full record."
        )

    return "\n".join(lines)
