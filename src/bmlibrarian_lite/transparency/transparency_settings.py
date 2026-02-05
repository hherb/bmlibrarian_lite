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

"""User-configurable transparency analysis settings."""

from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class ReportRiskThreshold(Enum):
    """Threshold for which risk levels trigger warnings in reports."""

    HIGH = "high"
    MEDIUM = "medium"
    LOW = "low"


DEFAULT_INLINE_WARNING_TEMPLATES: dict[str, str] = {
    "industry_funding": "Warning: funding concerns",
    "missing_coi": "Warning: COI not disclosed",
    "missing_results": "Warning: results not posted",
    "data_not_available": "Warning: data not shared",
    "multiple_risks": "Warning: transparency concerns",
}


@dataclass
class TransparencySettings:
    """
    Configuration for transparency analysis and filtering.

    Attributes:
        enabled: Master toggle for transparency analysis
        filtering_enabled: Whether to filter out high-risk papers
        score_threshold: Score below this = high risk (0-100)
        tier_downgrade_amount: How many tiers to downgrade for high risk (1-4)
        industry_funding_triggers_downgrade: Downgrade if industry funding + restricted data
        missing_coi_triggers_downgrade: Downgrade if COI not disclosed
        missing_trial_results_triggers_downgrade: Downgrade if trial results not posted
        analyze_in_background: Run analysis in background thread
        max_concurrent_analyses: Rate limiting for API calls (1-10)
        cache_results: Reuse results for same PMID/DOI
        show_badge_on_cards: Display risk badge on document cards
        show_detailed_tooltip: Show detailed tooltip on badge hover
    """

    # Master toggle
    enabled: bool = True
    filtering_enabled: bool = True

    # Threshold settings
    score_threshold: int = 40
    tier_downgrade_amount: int = 1

    # Specific risk indicator toggles
    industry_funding_triggers_downgrade: bool = True
    missing_coi_triggers_downgrade: bool = True
    missing_trial_results_triggers_downgrade: bool = False

    # Analysis settings
    analyze_in_background: bool = True
    max_concurrent_analyses: int = 3
    cache_results: bool = True

    # Display settings
    show_badge_on_cards: bool = True
    show_detailed_tooltip: bool = True

    # Report risk warning settings
    report_risk_threshold: ReportRiskThreshold = ReportRiskThreshold.HIGH
    inline_warning_templates: dict[str, str] = field(
        default_factory=lambda: DEFAULT_INLINE_WARNING_TEMPLATES.copy()
    )

    def to_dict(self) -> dict[str, Any]:
        """
        Serialize to dictionary for storage.

        Returns:
            Dictionary representation suitable for JSON serialization
        """
        return {
            "enabled": self.enabled,
            "filtering_enabled": self.filtering_enabled,
            "score_threshold": self.score_threshold,
            "tier_downgrade_amount": self.tier_downgrade_amount,
            "industry_funding_triggers_downgrade": self.industry_funding_triggers_downgrade,
            "missing_coi_triggers_downgrade": self.missing_coi_triggers_downgrade,
            "missing_trial_results_triggers_downgrade": self.missing_trial_results_triggers_downgrade,
            "analyze_in_background": self.analyze_in_background,
            "max_concurrent_analyses": self.max_concurrent_analyses,
            "cache_results": self.cache_results,
            "show_badge_on_cards": self.show_badge_on_cards,
            "show_detailed_tooltip": self.show_detailed_tooltip,
            "report_risk_threshold": self.report_risk_threshold.value,
            "inline_warning_templates": self.inline_warning_templates,
        }

    @classmethod
    def from_dict(cls, data: dict[str, Any]) -> "TransparencySettings":
        """
        Deserialize from dictionary.

        Args:
            data: Dictionary representation

        Returns:
            TransparencySettings instance
        """
        return cls(
            enabled=data.get("enabled", True),
            filtering_enabled=data.get("filtering_enabled", True),
            score_threshold=data.get("score_threshold", 40),
            tier_downgrade_amount=data.get("tier_downgrade_amount", 1),
            industry_funding_triggers_downgrade=data.get(
                "industry_funding_triggers_downgrade", True
            ),
            missing_coi_triggers_downgrade=data.get("missing_coi_triggers_downgrade", True),
            missing_trial_results_triggers_downgrade=data.get(
                "missing_trial_results_triggers_downgrade", False
            ),
            analyze_in_background=data.get("analyze_in_background", True),
            max_concurrent_analyses=data.get("max_concurrent_analyses", 3),
            cache_results=data.get("cache_results", True),
            show_badge_on_cards=data.get("show_badge_on_cards", True),
            show_detailed_tooltip=data.get("show_detailed_tooltip", True),
            report_risk_threshold=ReportRiskThreshold(
                data.get("report_risk_threshold", "high")
            ),
            inline_warning_templates=data.get(
                "inline_warning_templates", DEFAULT_INLINE_WARNING_TEMPLATES.copy()
            ),
        )

    def validate(self) -> list[str]:
        """
        Validate settings values.

        Returns:
            List of validation error messages (empty if all valid)
        """
        errors = []
        if not 0 <= self.score_threshold <= 100:
            errors.append("score_threshold must be 0-100")
        if not 1 <= self.tier_downgrade_amount <= 4:
            errors.append("tier_downgrade_amount must be 1-4")
        if not 1 <= self.max_concurrent_analyses <= 10:
            errors.append("max_concurrent_analyses must be 1-10")
        return errors


def get_default_settings() -> TransparencySettings:
    """
    Return default transparency settings.

    Returns:
        TransparencySettings with default values
    """
    return TransparencySettings()
