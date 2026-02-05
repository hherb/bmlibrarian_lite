# BMLibrarian Lite - Biomedical Literature Research Tool
# Copyright (C) 2024-2025 Dr Horst Herb
# SPDX-License-Identifier: AGPL-3.0-or-later

"""Tests for report risk warning settings."""

from bmlibrarian_lite.transparency.transparency_settings import (
    DEFAULT_INLINE_WARNING_TEMPLATES,
    ReportRiskThreshold,
    TransparencySettings,
)


def test_report_risk_threshold_enum_values() -> None:
    """ReportRiskThreshold enum has expected values."""
    assert ReportRiskThreshold.HIGH.value == "high"
    assert ReportRiskThreshold.MEDIUM.value == "medium"
    assert ReportRiskThreshold.LOW.value == "low"


def test_default_inline_warning_templates() -> None:
    """Default warning templates contain expected keys."""
    assert "industry_funding" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "missing_coi" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "missing_results" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "data_not_available" in DEFAULT_INLINE_WARNING_TEMPLATES
    assert "multiple_risks" in DEFAULT_INLINE_WARNING_TEMPLATES


def test_transparency_settings_has_report_risk_fields() -> None:
    """TransparencySettings has report risk warning fields."""
    settings = TransparencySettings()
    assert hasattr(settings, "report_risk_threshold")
    assert hasattr(settings, "inline_warning_templates")
    assert settings.report_risk_threshold == ReportRiskThreshold.HIGH


def test_transparency_settings_serialization_with_report_risk() -> None:
    """Settings serialize and deserialize report risk fields."""
    settings = TransparencySettings(
        report_risk_threshold=ReportRiskThreshold.MEDIUM,
    )
    data = settings.to_dict()
    assert data["report_risk_threshold"] == "medium"

    restored = TransparencySettings.from_dict(data)
    assert restored.report_risk_threshold == ReportRiskThreshold.MEDIUM
