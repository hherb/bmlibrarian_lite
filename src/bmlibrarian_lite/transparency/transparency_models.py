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

"""Data models for transparency analysis results."""

from dataclasses import dataclass, field
from datetime import datetime
from enum import Enum
from typing import TYPE_CHECKING, Any

if TYPE_CHECKING:
    from .transparency_settings import TransparencySettings


# Threshold for medium vs low risk (score above this = low risk potential)
MEDIUM_RISK_SCORE_THRESHOLD = 70


class TransparencyRisk(Enum):
    """Risk level based on transparency analysis."""

    LOW = "low"
    MEDIUM = "medium"
    HIGH = "high"
    UNKNOWN = "unknown"


@dataclass
class TransparencyResult:
    """
    Stores transparency analysis results for a document.

    Contains the transparency score, risk level, and specific indicators
    from the study transparency analyzer. Used for display (badges),
    filtering, and quality tier adjustment.

    Attributes:
        document_id: Internal document ID
        transparency_score: Overall transparency score (0-100)
        risk_level: Computed risk level (low/medium/high/unknown)
        industry_funding_detected: Whether industry funding was detected
        industry_funding_confidence: Confidence in industry funding detection (0-1)
        data_availability_level: Data disclosure level
        coi_disclosed: Whether conflicts of interest were disclosed
        trial_registered: Whether clinical trial was registered
        trial_results_compliant: Whether trial results were posted as required
        outcome_switching_detected: Whether outcome switching was detected
        risk_indicators: List of human-readable risk indicators
        warnings: Caveats about how reliable this analysis is, as opposed to
            what it found — e.g. funder names that matched no known body. Kept
            separate from risk_indicators because they qualify the result rather
            than describing the study. Mirrors Swift's TransparencyResult.warnings.
        tier_downgrade_applied: Number of quality tiers downgraded
        analyzed_at: Timestamp of analysis
        analyzer_version: Version of the analyzer used
        full_text_analyzed: Whether full text was used (future enhancement)
    """

    document_id: str
    transparency_score: int  # 0-100
    risk_level: TransparencyRisk

    # Specific indicators
    industry_funding_detected: bool = False
    industry_funding_confidence: float = 0.0
    data_availability_level: str = "unknown"
    coi_disclosed: bool = True
    trial_registered: bool = False
    trial_results_compliant: bool = False
    outcome_switching_detected: bool = False

    # Risk indicators list (human-readable)
    risk_indicators: list[str] = field(default_factory=list)

    # Caveats about the analysis itself (human-readable)
    warnings: list[str] = field(default_factory=list)

    # Tier adjustment applied
    tier_downgrade_applied: int = 0

    # Metadata
    analyzed_at: datetime = field(default_factory=datetime.now)
    analyzer_version: str = "1.0"

    # For future full-text enhancement
    full_text_analyzed: bool = False

    def to_dict(self) -> dict[str, Any]:
        """
        Serialize to dictionary for storage.

        Returns:
            Dictionary representation suitable for JSON serialization
        """
        return {
            "document_id": self.document_id,
            "transparency_score": self.transparency_score,
            "risk_level": self.risk_level.value,
            "industry_funding_detected": self.industry_funding_detected,
            "industry_funding_confidence": self.industry_funding_confidence,
            "data_availability_level": self.data_availability_level,
            "coi_disclosed": self.coi_disclosed,
            "trial_registered": self.trial_registered,
            "trial_results_compliant": self.trial_results_compliant,
            "outcome_switching_detected": self.outcome_switching_detected,
            "risk_indicators": self.risk_indicators,
            "warnings": self.warnings,
            "tier_downgrade_applied": self.tier_downgrade_applied,
            "analyzed_at": self.analyzed_at.isoformat(),
            "analyzer_version": self.analyzer_version,
            "full_text_analyzed": self.full_text_analyzed,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TransparencyResult":
        """
        Deserialize from dictionary.

        Args:
            data: Dictionary representation

        Returns:
            TransparencyResult instance
        """
        return cls(
            document_id=data["document_id"],
            transparency_score=data["transparency_score"],
            risk_level=TransparencyRisk(data["risk_level"]),
            industry_funding_detected=data.get("industry_funding_detected", False),
            industry_funding_confidence=data.get("industry_funding_confidence", 0.0),
            data_availability_level=data.get("data_availability_level", "unknown"),
            coi_disclosed=data.get("coi_disclosed", True),
            trial_registered=data.get("trial_registered", False),
            trial_results_compliant=data.get("trial_results_compliant", False),
            outcome_switching_detected=data.get("outcome_switching_detected", False),
            risk_indicators=data.get("risk_indicators", []),
            warnings=data.get("warnings", []),
            tier_downgrade_applied=data.get("tier_downgrade_applied", 0),
            analyzed_at=datetime.fromisoformat(data["analyzed_at"]),
            analyzer_version=data.get("analyzer_version", "1.0"),
            full_text_analyzed=data.get("full_text_analyzed", False),
        )


def calculate_risk_level(
    score: int,
    industry_funding: bool,
    data_availability: str,
    coi_disclosed: bool,
    settings: "TransparencySettings",
) -> TransparencyRisk:
    """
    Determine risk level from transparency metrics.

    Risk levels:
    - High Risk: score < threshold OR (industry + restricted data) OR missing COI
    - Medium Risk: score 40-70 OR industry with disclosure
    - Low Risk: score > 70, transparent

    Args:
        score: Transparency score (0-100)
        industry_funding: Whether industry funding was detected
        data_availability: Data availability level string
        coi_disclosed: Whether conflicts of interest were disclosed
        settings: Transparency settings with thresholds

    Returns:
        TransparencyRisk enum value
    """
    # High risk conditions
    if score < settings.score_threshold:
        return TransparencyRisk.HIGH

    if settings.industry_funding_triggers_downgrade:
        restricted_data = data_availability in (
            "restricted",
            "not_available",
            "not_stated",
        )
        if industry_funding and restricted_data:
            return TransparencyRisk.HIGH

    if settings.missing_coi_triggers_downgrade and not coi_disclosed:
        return TransparencyRisk.HIGH

    # Medium risk conditions
    if score <= MEDIUM_RISK_SCORE_THRESHOLD:
        return TransparencyRisk.MEDIUM

    if industry_funding:
        return TransparencyRisk.MEDIUM

    return TransparencyRisk.LOW
