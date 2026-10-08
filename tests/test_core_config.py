"""The CORE key in the desktop's settings (#480, stage C)."""

from __future__ import annotations

import argparse
import json
import stat
from pathlib import Path

import pytest

from bmlibrarian_lite import cli
from bmlibrarian_lite.config import LiteConfig
from bmlibrarian_lite.constants import REDACTED_SECRET_PLACEHOLDER

KEY = "test-core-key-0123456789"


def test_the_key_defaults_to_none() -> None:
    """No key until the user sets one."""
    assert LiteConfig().discovery.core_api_key is None


def test_the_key_round_trips_through_the_owner_only_file(tmp_path: Path) -> None:
    """Saved with the other secrets, readable by the owner alone."""
    config = LiteConfig()
    config.discovery.core_api_key = KEY
    path = tmp_path / "config.json"
    config.save(path)
    assert stat.S_IMODE(path.stat().st_mode) == 0o600
    assert LiteConfig.load(path).discovery.core_api_key == KEY


def test_an_export_never_carries_the_key() -> None:
    """The redacted form names that a key is set, not the key."""
    config = LiteConfig()
    config.discovery.core_api_key = KEY
    redacted = config.to_redacted_dict()
    assert redacted["discovery"]["core_api_key"] == REDACTED_SECRET_PLACEHOLDER
    assert KEY not in json.dumps(redacted)


def test_a_redacted_export_loaded_back_is_no_key(tmp_path: Path) -> None:
    """The placeholder is never sent to CORE as a key."""
    path = tmp_path / "config.json"
    path.write_text(
        json.dumps({"discovery": {"core_api_key": REDACTED_SECRET_PLACEHOLDER}})
    )
    assert LiteConfig.load(path).discovery.core_api_key is None


def test_the_unpaywall_email_survives_beside_the_key(tmp_path: Path) -> None:
    """Control: the discovery section's other field is still read."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {"unpaywall_email": "a@b.org"}}))
    loaded = LiteConfig.load(path)
    assert loaded.discovery.unpaywall_email == "a@b.org"
    assert loaded.discovery.core_api_key is None


@pytest.fixture
def qapp():
    """A QApplication for the dialog test."""
    pytest.importorskip("PySide6")
    from PySide6.QtWidgets import QApplication

    return QApplication.instance() or QApplication([])


def test_the_dialog_saves_and_clears_the_key(qapp, monkeypatch) -> None:
    """The Full Text tab's field writes the key; an empty field clears it."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    monkeypatch.setattr(LiteConfig, "save", lambda self, *a, **k: None)
    dialog = SettingsDialog(config)
    dialog.core_api_key_input.setText(f"  {KEY}  ")
    dialog._save_config()
    assert config.discovery.core_api_key == KEY
    dialog.core_api_key_input.setText("")
    dialog._save_config()
    assert config.discovery.core_api_key is None


def test_the_dialog_shows_a_saved_key(qapp) -> None:
    """Opening the dialog loads the key into its field."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    config.discovery.core_api_key = KEY
    assert SettingsDialog(config).core_api_key_input.text() == KEY


def test_the_dialog_shows_a_saved_unpaywall_email(qapp) -> None:
    """Opening the dialog loads the Unpaywall email into its field (#497)."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    config.discovery.unpaywall_email = "a@b.org"
    assert SettingsDialog(config).unpaywall_email_input.text() == "a@b.org"


def test_the_dialog_saves_the_unpaywall_email_stripped(qapp, monkeypatch) -> None:
    """Saving writes the email stripped; an empty field saves the default."""
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    config = LiteConfig()
    monkeypatch.setattr(LiteConfig, "save", lambda self, *a, **k: None)
    dialog = SettingsDialog(config)
    dialog.unpaywall_email_input.setText("  a@b.org  ")
    dialog._save_config()
    assert config.discovery.unpaywall_email == "a@b.org"
    dialog.unpaywall_email_input.setText("")
    dialog._save_config()
    assert config.discovery.unpaywall_email == ""


@pytest.mark.parametrize(
    ("key", "expected"),
    [(KEY, REDACTED_SECRET_PLACEHOLDER), (None, "(not set)")],
)
def test_the_cli_config_view_never_prints_the_key(
    monkeypatch: pytest.MonkeyPatch,
    capsys: pytest.CaptureFixture[str],
    key: str | None,
    expected: str,
) -> None:
    """The human view says whether a CORE key is set, never what it is."""
    config = LiteConfig()
    config.discovery.core_api_key = key
    monkeypatch.setattr(
        LiteConfig, "load", classmethod(lambda cls, path=None: config)
    )
    assert cli.cmd_config(argparse.Namespace(json=False)) == 0
    lines = capsys.readouterr().out.splitlines()
    assert f"  CORE API key: {expected}" in lines
    assert not any(KEY in line for line in lines)


@pytest.mark.parametrize("value", [12345, ["k"], {"k": 1}, True])
def test_a_key_that_is_not_text_is_no_key(tmp_path: Path, value: object) -> None:
    """A number or a list typed into the file is ignored, not a start-up crash."""
    path = tmp_path / "config.json"
    path.write_text(json.dumps({"discovery": {"core_api_key": value}, "pubmed": {"api_key": value}}))
    loaded = LiteConfig.load(path)
    assert loaded.discovery.core_api_key is None
    assert loaded.pubmed.api_key is None


def test_the_keys_are_never_in_the_repr() -> None:
    """Printing or logging the configuration shows neither key."""
    config = LiteConfig()
    config.discovery.core_api_key = KEY
    config.pubmed.api_key = "ncbi-secret-0123"
    assert KEY not in repr(config)
    assert "ncbi-secret-0123" not in repr(config)
    # The control: the other fields are still shown
    config.discovery.unpaywall_email = "a@b.org"
    assert "a@b.org" in repr(config)


def test_the_dialog_says_when_the_key_comes_from_the_environment(qapp, monkeypatch) -> None:
    """A refusal is told as "the key in the settings": the field says where it is."""
    from bmlibrarian_lite.constants import CORE_API_KEY_FROM_ENVIRONMENT, ENV_CORE_API_KEY
    from bmlibrarian_lite.gui.settings_dialog import SettingsDialog

    monkeypatch.setenv(ENV_CORE_API_KEY, KEY)
    field = SettingsDialog(LiteConfig()).core_api_key_input
    assert field.text() == ""
    assert field.placeholderText() == CORE_API_KEY_FROM_ENVIRONMENT
    # The control: without it the placeholder is the ordinary one
    monkeypatch.delenv(ENV_CORE_API_KEY)
    assert SettingsDialog(LiteConfig()).core_api_key_input.placeholderText() == "Optional"


def test_a_save_that_fails_is_told_and_keeps_the_dialog_open(qapp, monkeypatch) -> None:
    """The reader is told the key will not survive a restart; the dialog does not close."""
    from bmlibrarian_lite.gui import settings_dialog

    def failing_save(self: LiteConfig, *args: object, **kwargs: object) -> None:
        raise PermissionError("config.json")

    shown: list[str] = []
    monkeypatch.setattr(LiteConfig, "save", failing_save)
    monkeypatch.setattr(
        settings_dialog.QMessageBox, "critical",
        lambda parent, title, text: shown.append(text),
    )
    dialog = settings_dialog.SettingsDialog(LiteConfig())
    accepted: list[bool] = []
    monkeypatch.setattr(dialog, "accept", lambda: accepted.append(True))
    dialog.core_api_key_input.setText(KEY)
    dialog._save_config()
    assert accepted == []
    assert len(shown) == 1 and "PermissionError" in shown[0]
    assert KEY not in shown[0]
