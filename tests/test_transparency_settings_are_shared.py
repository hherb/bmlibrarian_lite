"""One settings object rates the studies and explains their ratings (#386, #417).

The advanced settings dialog edits a copy. The panel used to keep that copy,
and hand it to the analyses alone, so a High was rated under the dialog's
rules and explained -- in the report and on every badge -- under the rules
in ``config.transparency``: a reason the user had switched off, stated as
the reason. The dialog's values are now copied into the shared object.
"""

import dataclasses
from unittest.mock import patch

import pytest

from bmlibrarian_lite.transparency.transparency_settings import (
    ReportRiskThreshold,
    TransparencySettings,
)


def _edited() -> TransparencySettings:
    """Settings that differ from the defaults in every field.

    Returns:
        The settings.
    """
    return TransparencySettings(
        enabled=False,
        filtering_enabled=False,
        score_threshold=55,
        tier_downgrade_amount=2,
        industry_funding_triggers_downgrade=False,
        missing_coi_triggers_downgrade=False,
        missing_trial_results_triggers_downgrade=True,
        analyze_in_background=False,
        max_concurrent_analyses=5,
        cache_results=False,
        show_badge_on_cards=False,
        show_detailed_tooltip=False,
        report_risk_threshold=ReportRiskThreshold.LOW,
        inline_warning_templates={"generic": "(!)"},
    )


class TestAssignFrom:
    """Every value is taken; the object itself is kept."""

    def test_takes_every_field(self) -> None:
        """A field left behind would split rating and explaining again."""
        shared = TransparencySettings()
        edited = _edited()
        for settings_field in dataclasses.fields(TransparencySettings):
            # The fixture must differ everywhere, or this test proves nothing
            assert getattr(shared, settings_field.name) != getattr(
                edited, settings_field.name
            ), settings_field.name

        shared.assign_from(edited)

        assert shared == edited

    def test_the_templates_are_not_aliased(self) -> None:
        """A later edit to the dialog's copy must not reach the shared object."""
        shared = TransparencySettings()
        edited = _edited()
        shared.assign_from(edited)
        edited.inline_warning_templates["generic"] = "changed"
        assert shared.inline_warning_templates["generic"] == "(!)"


class TestThePanel:
    """The quality filter panel keeps the app's settings object."""

    @pytest.fixture
    def panel(self):
        """A panel over a config of its own."""
        pytest.importorskip("PySide6")
        from PySide6.QtWidgets import QApplication

        from bmlibrarian_lite.config import LiteConfig
        from bmlibrarian_lite.gui.quality_filter_panel import QualityFilterPanel

        if QApplication.instance() is None:
            QApplication([])
        widget = QualityFilterPanel(config=LiteConfig())
        yield widget
        widget.deleteLater()

    def test_the_dialogs_values_reach_the_config(self, panel) -> None:
        """Accepted, the dialog's settings are the config's settings."""
        shared = panel._config.transparency
        edited = _edited()

        class AcceptingDialog:
            """Stands in for the dialog: accepted, with ``edited``."""

            def __init__(self, *_args, **_kwargs) -> None:
                pass

            def exec(self) -> bool:
                return True

            def get_settings(self) -> TransparencySettings:
                return edited

        with patch(
            "bmlibrarian_lite.gui.transparency_settings_dialog."
            "TransparencySettingsDialog",
            AcceptingDialog,
        ):
            panel._show_advanced_settings()

        assert panel.get_transparency_settings() is shared
        assert panel._config.transparency is shared
        assert shared.missing_coi_triggers_downgrade is False
        assert shared.score_threshold == 55

    def test_a_cancelled_dialog_changes_nothing(self, panel) -> None:
        """The control: the dialog works on a copy so that cancel is possible."""
        shared = panel._config.transparency
        before = dataclasses.replace(shared)

        class CancelledDialog:
            """Stands in for the dialog: cancelled."""

            def __init__(self, *_args, **_kwargs) -> None:
                pass

            def exec(self) -> bool:
                return False

            def get_settings(self) -> TransparencySettings:
                return _edited()

        with patch(
            "bmlibrarian_lite.gui.transparency_settings_dialog."
            "TransparencySettingsDialog",
            CancelledDialog,
        ):
            panel._show_advanced_settings()

        assert panel._config.transparency is shared
        assert shared == before

    def test_set_transparency_settings_keeps_the_object(self, panel) -> None:
        """The setter copies values in, as the dialog path does."""
        shared = panel._config.transparency
        panel.set_transparency_settings(_edited())
        assert panel.get_transparency_settings() is shared
        assert shared.score_threshold == 55
