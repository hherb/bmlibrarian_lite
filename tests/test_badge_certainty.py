"""The badge qualifies a rating made without full text, and says why it is High (#386)."""

import dataclasses
from datetime import datetime

import pytest

pytest.importorskip("PySide6")

from PySide6.QtWidgets import QApplication  # noqa: E402

from bmlibrarian_lite.gui.transparency_badge import TransparencyBadge  # noqa: E402
from bmlibrarian_lite.transparency import (  # noqa: E402
    COI_NOT_STATED,
    TransparencyResult,
    TransparencyRisk,
    get_default_settings,
)
from bmlibrarian_lite.transparency_terms import (  # noqa: E402
    LIMITED_CERTAINTY_NOTE,
    PROVISIONAL_RESULT_CAVEAT,
    UNEXPLAINED_RATING_CAVEAT,
)


@pytest.fixture(scope="module")
def qapp():
    """Create QApplication for tests."""
    app = QApplication.instance()
    if app is None:
        app = QApplication([])
    yield app


def _row(**changes) -> TransparencyResult:
    """Build a High, full-text-analysed result, overridden field by field.

    Args:
        **changes: Fields to replace on the base result, as accepted by
            ``dataclasses.replace``.

    Returns:
        The result, with ``changes`` applied.
    """
    base = TransparencyResult(
        document_id="d",
        transparency_score=65,
        risk_level=TransparencyRisk.HIGH,
        coi_disclosure=COI_NOT_STATED,
        analyzed_at=datetime(2026, 9, 27),
        full_text_analyzed=True,
    )
    return dataclasses.replace(base, **changes)


class TestTheLabel:
    """The badge's label carries the limited-certainty suffix, or not."""

    @pytest.mark.parametrize(("compact", "text"), [(True, "High"), (False, "High Risk")])
    def test_full_text_is_unqualified(self, qapp, compact, text) -> None:
        """A rating made from the full text carries no suffix."""
        assert TransparencyBadge(_row(), compact=compact).label.text() == text

    @pytest.mark.parametrize(
        ("compact", "text"), [(True, "High · limited"), (False, "High Risk · limited")]
    )
    def test_without_full_text_it_is_limited(self, qapp, compact, text) -> None:
        """A rating made without the full text says so, in both label sizes."""
        badge = TransparencyBadge(_row(full_text_analyzed=False), compact=compact)
        assert badge.label.text() == text


class TestTheTooltip:
    """The tooltip carries the certainty note, the rules and the caveats."""

    def test_carries_the_note(self, qapp) -> None:
        """The limited-certainty note appears when the full text was not read."""
        tip = TransparencyBadge(_row(full_text_analyzed=False)).toolTip()
        assert LIMITED_CERTAINTY_NOTE in tip

    def test_no_note_with_full_text(self, qapp) -> None:
        """The note is absent when the full text was read."""
        assert LIMITED_CERTAINTY_NOTE not in TransparencyBadge(_row()).toolTip()

    def test_names_the_rule(self, qapp) -> None:
        """A High rating names the rule that produced it."""
        tip = TransparencyBadge(_row()).toolTip()
        assert "<b>Rated high risk because:</b>" in tip
        assert (
            "No conflict of interest statement was found in the full text. "
            "A missing statement is enough on its own for a high rating."
        ) in tip

    def test_says_provisional(self, qapp) -> None:
        """An unreachable source makes the rating provisional."""
        tip = TransparencyBadge(_row(sources_unreachable=True)).toolTip()
        assert PROVISIONAL_RESULT_CAVEAT in tip

    def test_uses_the_settings_it_was_given(self, qapp) -> None:
        """The user's settings, not the defaults."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        tip = TransparencyBadge(_row(), settings=settings).toolTip()
        assert UNEXPLAINED_RATING_CAVEAT in tip

    def test_no_matching_rule_is_a_caveat_not_a_reason(self, qapp) -> None:
        """It says there is no reason to give, so it is not listed as one."""
        settings = dataclasses.replace(
            get_default_settings(), missing_coi_triggers_downgrade=False
        )
        tip = TransparencyBadge(_row(), settings=settings).toolTip()
        assert "Rated high risk because" not in tip
        assert f"<b>Caveats:</b><br>  • {UNEXPLAINED_RATING_CAVEAT}" in tip

    def test_a_medium_rating_meeting_a_rule_lists_none(self, qapp) -> None:
        """Its findings meet a rule under these settings, and it is not High."""
        row = _row(risk_level=TransparencyRisk.MEDIUM)
        assert "Rated high risk because" not in TransparencyBadge(row).toolTip()

    def test_a_lower_rating_lists_no_rules(self, qapp) -> None:
        """Only a High rating gets a "Rated high risk because" section."""
        row = _row(risk_level=TransparencyRisk.LOW, coi_disclosure="disclosed")
        assert "Rated high risk because" not in TransparencyBadge(row).toolTip()
