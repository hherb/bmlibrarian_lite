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

"""Tests for transparency analysis data models."""

from datetime import datetime

import pytest

from bmlibrarian_lite.transparency import (
    TransparencyResult,
    TransparencyRisk,
    TransparencySettings,
    calculate_risk_level,
    get_default_settings,
)


class MockTransparencySettings:
    """Mock settings for testing calculate_risk_level."""

    def __init__(
        self,
        score_threshold: int = 40,
        industry_funding_triggers_downgrade: bool = True,
        missing_coi_triggers_downgrade: bool = True,
    ):
        self.score_threshold = score_threshold
        self.industry_funding_triggers_downgrade = industry_funding_triggers_downgrade
        self.missing_coi_triggers_downgrade = missing_coi_triggers_downgrade


class TestTransparencyRisk:
    """Tests for TransparencyRisk enum."""

    def test_enum_values(self):
        """Test enum has expected values."""
        assert TransparencyRisk.LOW.value == "low"
        assert TransparencyRisk.MEDIUM.value == "medium"
        assert TransparencyRisk.HIGH.value == "high"
        assert TransparencyRisk.UNKNOWN.value == "unknown"

    def test_enum_from_string(self):
        """Test creating enum from string."""
        assert TransparencyRisk("low") == TransparencyRisk.LOW
        assert TransparencyRisk("high") == TransparencyRisk.HIGH


class TestTransparencyResult:
    """Tests for TransparencyResult dataclass."""

    def test_creation_minimal(self):
        """Test creating result with minimal fields."""
        result = TransparencyResult(
            document_id="test-doc-123",
            transparency_score=75,
            risk_level=TransparencyRisk.LOW,
        )

        assert result.document_id == "test-doc-123"
        assert result.transparency_score == 75
        assert result.risk_level == TransparencyRisk.LOW
        # Check defaults
        assert result.industry_funding_detected is False
        assert result.coi_disclosed is True
        assert result.risk_indicators == []

    def test_creation_full(self):
        """Test creating result with all fields."""
        now = datetime.now()
        result = TransparencyResult(
            document_id="test-doc-456",
            transparency_score=35,
            risk_level=TransparencyRisk.HIGH,
            industry_funding_detected=True,
            industry_funding_confidence=0.85,
            data_availability_level="restricted",
            coi_disclosed=False,
            trial_registered=True,
            trial_results_compliant=False,
            outcome_switching_detected=True,
            risk_indicators=["Industry funding detected", "Data not available"],
            tier_downgrade_applied=1,
            analyzed_at=now,
            analyzer_version="1.1",
            full_text_analyzed=True,
        )

        assert result.industry_funding_detected is True
        assert result.industry_funding_confidence == 0.85
        assert result.data_availability_level == "restricted"
        assert result.coi_disclosed is False
        assert result.trial_registered is True
        assert result.trial_results_compliant is False
        assert result.outcome_switching_detected is True
        assert len(result.risk_indicators) == 2
        assert result.tier_downgrade_applied == 1
        assert result.analyzed_at == now
        assert result.analyzer_version == "1.1"
        assert result.full_text_analyzed is True

    def test_to_dict(self):
        """Test serialization to dictionary."""
        result = TransparencyResult(
            document_id="test-doc",
            transparency_score=50,
            risk_level=TransparencyRisk.MEDIUM,
            industry_funding_detected=True,
            risk_indicators=["Risk 1", "Risk 2"],
        )

        data = result.to_dict()

        assert data["document_id"] == "test-doc"
        assert data["transparency_score"] == 50
        assert data["risk_level"] == "medium"
        assert data["industry_funding_detected"] is True
        assert data["risk_indicators"] == ["Risk 1", "Risk 2"]
        assert "analyzed_at" in data

    def test_from_dict(self):
        """Test deserialization from dictionary."""
        now = datetime.now()
        data = {
            "document_id": "test-doc-789",
            "transparency_score": 80,
            "risk_level": "low",
            "industry_funding_detected": False,
            "industry_funding_confidence": 0.1,
            "data_availability_level": "full_open",
            "coi_disclosed": True,
            "trial_registered": True,
            "trial_results_compliant": True,
            "outcome_switching_detected": False,
            "risk_indicators": [],
            "tier_downgrade_applied": 0,
            "analyzed_at": now.isoformat(),
            "analyzer_version": "1.0",
            "full_text_analyzed": False,
        }

        result = TransparencyResult.from_dict(data)

        assert result.document_id == "test-doc-789"
        assert result.transparency_score == 80
        assert result.risk_level == TransparencyRisk.LOW
        assert result.industry_funding_detected is False
        assert result.data_availability_level == "full_open"
        assert result.coi_disclosed is True

    def test_roundtrip_serialization(self):
        """Test that to_dict/from_dict roundtrips correctly."""
        original = TransparencyResult(
            document_id="roundtrip-test",
            transparency_score=65,
            risk_level=TransparencyRisk.MEDIUM,
            industry_funding_detected=True,
            industry_funding_confidence=0.75,
            data_availability_level="on_request",
            coi_disclosed=True,
            trial_registered=True,
            trial_results_compliant=False,
            outcome_switching_detected=False,
            risk_indicators=["Test indicator"],
            tier_downgrade_applied=0,
        )

        data = original.to_dict()
        restored = TransparencyResult.from_dict(data)

        assert restored.document_id == original.document_id
        assert restored.transparency_score == original.transparency_score
        assert restored.risk_level == original.risk_level
        assert restored.industry_funding_detected == original.industry_funding_detected
        assert restored.data_availability_level == original.data_availability_level
        assert restored.risk_indicators == original.risk_indicators

    def test_from_dict_with_missing_optional_fields(self):
        """Test deserialization handles missing optional fields."""
        data = {
            "document_id": "minimal-doc",
            "transparency_score": 50,
            "risk_level": "medium",
            "analyzed_at": datetime.now().isoformat(),
        }

        result = TransparencyResult.from_dict(data)

        assert result.document_id == "minimal-doc"
        assert result.industry_funding_detected is False  # Default
        assert result.coi_disclosed is True  # Default
        assert result.risk_indicators == []  # Default


class TestCalculateRiskLevel:
    """Tests for calculate_risk_level function."""

    def test_high_risk_low_score(self):
        """Test low score triggers high risk."""
        settings = MockTransparencySettings(score_threshold=40)

        risk = calculate_risk_level(
            score=30,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )

        assert risk == TransparencyRisk.HIGH

    def test_high_risk_industry_restricted_data(self):
        """Test industry funding with restricted data triggers high risk."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=75,  # Good score
            industry_funding=True,
            data_availability="restricted",
            coi_disclosed=True,
            settings=settings,
        )

        assert risk == TransparencyRisk.HIGH

    def test_high_risk_missing_coi(self):
        """Test missing COI disclosure triggers high risk."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=75,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=False,
            settings=settings,
        )

        assert risk == TransparencyRisk.HIGH

    def test_medium_risk_moderate_score(self):
        """Test moderate score (40-70) triggers medium risk."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=55,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )

        assert risk == TransparencyRisk.MEDIUM

    def test_medium_risk_industry_with_open_data(self):
        """Test industry funding with open data is medium risk."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=85,  # Good score
            industry_funding=True,
            data_availability="full_open",  # Open data
            coi_disclosed=True,
            settings=settings,
        )

        assert risk == TransparencyRisk.MEDIUM

    def test_low_risk_high_score_transparent(self):
        """Test high score with transparency is low risk."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=85,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )

        assert risk == TransparencyRisk.LOW

    def test_settings_disable_industry_downgrade(self):
        """Test disabling industry funding trigger."""
        settings = MockTransparencySettings(industry_funding_triggers_downgrade=False)

        risk = calculate_risk_level(
            score=75,
            industry_funding=True,
            data_availability="restricted",
            coi_disclosed=True,
            settings=settings,
        )

        # Should be medium (due to industry funding) not high
        assert risk == TransparencyRisk.MEDIUM

    def test_settings_disable_coi_downgrade(self):
        """Test disabling COI trigger."""
        settings = MockTransparencySettings(missing_coi_triggers_downgrade=False)

        risk = calculate_risk_level(
            score=85,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=False,  # Missing COI
            settings=settings,
        )

        # Should be low risk since COI trigger is disabled
        assert risk == TransparencyRisk.LOW

    def test_boundary_score_at_threshold(self):
        """Test score exactly at threshold."""
        settings = MockTransparencySettings(score_threshold=40)

        risk = calculate_risk_level(
            score=40,  # At threshold
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )

        # Score at threshold should NOT be high risk (only below)
        assert risk == TransparencyRisk.MEDIUM

    def test_boundary_score_at_70(self):
        """Test score exactly at 70."""
        settings = MockTransparencySettings()

        risk = calculate_risk_level(
            score=70,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )

        # Score at 70 should be medium (<=70)
        assert risk == TransparencyRisk.MEDIUM

    def test_data_availability_variants(self):
        """Test various data availability levels with industry funding."""
        settings = MockTransparencySettings()

        # not_available should trigger high risk
        risk = calculate_risk_level(
            score=75,
            industry_funding=True,
            data_availability="not_available",
            coi_disclosed=True,
            settings=settings,
        )
        assert risk == TransparencyRisk.HIGH

        # not_stated should trigger high risk
        risk = calculate_risk_level(
            score=75,
            industry_funding=True,
            data_availability="not_stated",
            coi_disclosed=True,
            settings=settings,
        )
        assert risk == TransparencyRisk.HIGH

        # on_request should NOT trigger high risk
        risk = calculate_risk_level(
            score=75,
            industry_funding=True,
            data_availability="on_request",
            coi_disclosed=True,
            settings=settings,
        )
        assert risk == TransparencyRisk.MEDIUM


class TestTransparencySettings:
    """Tests for TransparencySettings dataclass."""

    def test_default_settings(self):
        """Test get_default_settings returns expected defaults."""
        settings = get_default_settings()

        assert settings.enabled is True
        assert settings.filtering_enabled is True
        assert settings.score_threshold == 40
        assert settings.tier_downgrade_amount == 1
        assert settings.industry_funding_triggers_downgrade is True
        assert settings.missing_coi_triggers_downgrade is True
        assert settings.missing_trial_results_triggers_downgrade is False
        assert settings.analyze_in_background is True
        assert settings.max_concurrent_analyses == 3
        assert settings.cache_results is True
        assert settings.show_badge_on_cards is True
        assert settings.show_detailed_tooltip is True

    def test_custom_settings(self):
        """Test creating settings with custom values."""
        settings = TransparencySettings(
            enabled=False,
            filtering_enabled=False,
            score_threshold=50,
            tier_downgrade_amount=2,
            industry_funding_triggers_downgrade=False,
            max_concurrent_analyses=5,
        )

        assert settings.enabled is False
        assert settings.filtering_enabled is False
        assert settings.score_threshold == 50
        assert settings.tier_downgrade_amount == 2
        assert settings.industry_funding_triggers_downgrade is False
        assert settings.max_concurrent_analyses == 5

    def test_to_dict(self):
        """Test serialization to dictionary."""
        settings = TransparencySettings(
            enabled=True,
            score_threshold=45,
            tier_downgrade_amount=2,
        )

        data = settings.to_dict()

        assert data["enabled"] is True
        assert data["score_threshold"] == 45
        assert data["tier_downgrade_amount"] == 2
        assert "filtering_enabled" in data
        assert "industry_funding_triggers_downgrade" in data

    def test_from_dict(self):
        """Test deserialization from dictionary."""
        data = {
            "enabled": False,
            "filtering_enabled": False,
            "score_threshold": 60,
            "tier_downgrade_amount": 3,
            "industry_funding_triggers_downgrade": False,
            "missing_coi_triggers_downgrade": False,
            "missing_trial_results_triggers_downgrade": True,
            "analyze_in_background": False,
            "max_concurrent_analyses": 5,
            "cache_results": False,
            "show_badge_on_cards": False,
            "show_detailed_tooltip": False,
        }

        settings = TransparencySettings.from_dict(data)

        assert settings.enabled is False
        assert settings.filtering_enabled is False
        assert settings.score_threshold == 60
        assert settings.tier_downgrade_amount == 3
        assert settings.industry_funding_triggers_downgrade is False
        assert settings.missing_coi_triggers_downgrade is False
        assert settings.missing_trial_results_triggers_downgrade is True
        assert settings.analyze_in_background is False
        assert settings.max_concurrent_analyses == 5
        assert settings.cache_results is False
        assert settings.show_badge_on_cards is False
        assert settings.show_detailed_tooltip is False

    def test_from_dict_with_missing_fields(self):
        """Test deserialization handles missing fields with defaults."""
        data = {
            "enabled": False,
            "score_threshold": 50,
        }

        settings = TransparencySettings.from_dict(data)

        assert settings.enabled is False
        assert settings.score_threshold == 50
        # Check defaults for missing fields
        assert settings.filtering_enabled is True
        assert settings.tier_downgrade_amount == 1
        assert settings.max_concurrent_analyses == 3

    def test_roundtrip_serialization(self):
        """Test that to_dict/from_dict roundtrips correctly."""
        original = TransparencySettings(
            enabled=True,
            filtering_enabled=False,
            score_threshold=55,
            tier_downgrade_amount=2,
            industry_funding_triggers_downgrade=False,
            missing_coi_triggers_downgrade=True,
            missing_trial_results_triggers_downgrade=True,
            analyze_in_background=True,
            max_concurrent_analyses=7,
            cache_results=False,
            show_badge_on_cards=True,
            show_detailed_tooltip=False,
        )

        data = original.to_dict()
        restored = TransparencySettings.from_dict(data)

        assert restored.enabled == original.enabled
        assert restored.filtering_enabled == original.filtering_enabled
        assert restored.score_threshold == original.score_threshold
        assert restored.tier_downgrade_amount == original.tier_downgrade_amount
        assert restored.industry_funding_triggers_downgrade == original.industry_funding_triggers_downgrade
        assert restored.missing_coi_triggers_downgrade == original.missing_coi_triggers_downgrade
        assert restored.missing_trial_results_triggers_downgrade == original.missing_trial_results_triggers_downgrade
        assert restored.analyze_in_background == original.analyze_in_background
        assert restored.max_concurrent_analyses == original.max_concurrent_analyses
        assert restored.cache_results == original.cache_results
        assert restored.show_badge_on_cards == original.show_badge_on_cards
        assert restored.show_detailed_tooltip == original.show_detailed_tooltip

    def test_validate_valid_settings(self):
        """Test validation passes for valid settings."""
        settings = TransparencySettings()
        errors = settings.validate()
        assert errors == []

    def test_validate_score_threshold_too_low(self):
        """Test validation catches score_threshold below 0."""
        settings = TransparencySettings(score_threshold=-1)
        errors = settings.validate()
        assert "score_threshold must be 0-100" in errors

    def test_validate_score_threshold_too_high(self):
        """Test validation catches score_threshold above 100."""
        settings = TransparencySettings(score_threshold=101)
        errors = settings.validate()
        assert "score_threshold must be 0-100" in errors

    def test_validate_score_threshold_boundary(self):
        """Test validation accepts boundary values for score_threshold."""
        settings_zero = TransparencySettings(score_threshold=0)
        settings_hundred = TransparencySettings(score_threshold=100)

        assert settings_zero.validate() == []
        assert settings_hundred.validate() == []

    def test_validate_tier_downgrade_too_low(self):
        """Test validation catches tier_downgrade_amount below 1."""
        settings = TransparencySettings(tier_downgrade_amount=0)
        errors = settings.validate()
        assert "tier_downgrade_amount must be 1-4" in errors

    def test_validate_tier_downgrade_too_high(self):
        """Test validation catches tier_downgrade_amount above 4."""
        settings = TransparencySettings(tier_downgrade_amount=5)
        errors = settings.validate()
        assert "tier_downgrade_amount must be 1-4" in errors

    def test_validate_tier_downgrade_boundary(self):
        """Test validation accepts boundary values for tier_downgrade_amount."""
        settings_one = TransparencySettings(tier_downgrade_amount=1)
        settings_four = TransparencySettings(tier_downgrade_amount=4)

        assert settings_one.validate() == []
        assert settings_four.validate() == []

    def test_validate_max_concurrent_too_low(self):
        """Test validation catches max_concurrent_analyses below 1."""
        settings = TransparencySettings(max_concurrent_analyses=0)
        errors = settings.validate()
        assert "max_concurrent_analyses must be 1-10" in errors

    def test_validate_max_concurrent_too_high(self):
        """Test validation catches max_concurrent_analyses above 10."""
        settings = TransparencySettings(max_concurrent_analyses=11)
        errors = settings.validate()
        assert "max_concurrent_analyses must be 1-10" in errors

    def test_validate_multiple_errors(self):
        """Test validation reports multiple errors."""
        settings = TransparencySettings(
            score_threshold=-5,
            tier_downgrade_amount=10,
            max_concurrent_analyses=0,
        )
        errors = settings.validate()

        assert len(errors) == 3
        assert "score_threshold must be 0-100" in errors
        assert "tier_downgrade_amount must be 1-4" in errors
        assert "max_concurrent_analyses must be 1-10" in errors

    def test_works_with_calculate_risk_level(self):
        """Test TransparencySettings works with calculate_risk_level function."""
        settings = TransparencySettings(score_threshold=40)

        # High risk due to low score
        risk = calculate_risk_level(
            score=30,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )
        assert risk == TransparencyRisk.HIGH

        # Low risk with high score and transparency
        risk = calculate_risk_level(
            score=85,
            industry_funding=False,
            data_availability="full_open",
            coi_disclosed=True,
            settings=settings,
        )
        assert risk == TransparencyRisk.LOW
